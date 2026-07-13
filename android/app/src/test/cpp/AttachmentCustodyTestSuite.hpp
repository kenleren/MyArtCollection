#pragma once

#include <atomic>
#include <chrono>
#include <filesystem>
#include <fstream>
#include <string>
#include <thread>
#include <vector>

namespace custody_test {

namespace fs = std::filesystem;

struct Fingerprint {
  dev_t device = 0;
  ino_t inode = 0;
  std::string bytes;
  std::string sha256;
};

inline std::string unique_path(const char* label) {
  return (fs::temp_directory_path() / custody::random_name(label)).string();
}

inline void write_file(const fs::path& path, const std::string& bytes) {
  std::ofstream output(path, std::ios::binary | std::ios::trunc);
  output << bytes;
}

inline Fingerprint fingerprint(const fs::path& path) {
  struct stat status {};
  Fingerprint output;
  if (lstat(path.c_str(), &status) != 0) return output;
  output.device = status.st_dev;
  output.inode = status.st_ino;
  std::ifstream input(path, std::ios::binary);
  output.bytes.assign(std::istreambuf_iterator<char>(input), std::istreambuf_iterator<char>());
  custody::Sha256 hash;
  hash.update(reinterpret_cast<const unsigned char*>(output.bytes.data()), output.bytes.size());
  output.sha256 = hash.finish();
  return output;
}

inline bool same_fingerprint(const Fingerprint& left, const Fingerprint& right) {
  return left.device == right.device && left.inode == right.inode &&
         left.bytes == right.bytes && left.sha256 == right.sha256;
}

inline custody::Result call(const fs::path& root, const std::string& operation,
                            const std::string& source = {}, const std::string& operation_id = {},
                            const std::string& artwork = {}, const std::string& attachment = {},
                            const std::string& canonical = {}) {
  return custody::execute(root.string(), operation, source, operation_id, artwork, attachment, canonical);
}

inline std::string require(bool condition, const std::string& message) {
  return condition ? std::string() : message;
}

inline std::string publication_crash_tests() {
  const std::vector<std::string> recoverable_points = {
      "publish.afterIntentFileFsync", "publish.afterIntentLink", "publish.afterClaim",
      "publish.afterPayloadLink", "publish.afterCommit", "publish.afterDataCleanup"};
  for (const std::string& point : recoverable_points) {
    const fs::path root = unique_path("archivale-publish-crash-");
    fs::create_directories(root);
    const fs::path source = root / "source.pdf";
    const std::string expected = "%PDF-1.4\ncrash-boundary-" + point + "\n%%EOF\n";
    write_file(source, expected);
    custody::test_crash_at(point);
    const auto interrupted = call(root, "publish", source.string(), "intent-001", "artwork-001",
                                  "attachment-001", "payload.pdf");
    custody::test_reset_hooks();
    if (interrupted.outcome != "ioFailure") return "publication crash point did not interrupt: " + point;
    const auto recovered = call(root, "recoverPublication", {}, "intent-001", "artwork-001",
                                "attachment-001", "payload.pdf");
    if (recovered.outcome != "publicationRecovered") return "publication did not recover: " + point + " -> " + recovered.outcome;
    const fs::path payload = root / "attachments/artworks/artwork-001/attachments/attachment-001/payload.pdf";
    if (!fs::exists(payload) || fingerprint(payload).bytes != expected) return "recovered payload bytes differ: " + point;
    struct stat status {};
    if (lstat(payload.c_str(), &status) != 0 || status.st_nlink != 1) return "recovered payload link count differs: " + point;
    fs::remove_all(root);
  }

  const fs::path root = unique_path("archivale-publish-partial-");
  fs::create_directories(root);
  const fs::path source = root / "source.pdf";
  write_file(source, "%PDF-1.4\npartial\n%%EOF\n");
  custody::test_crash_at("publish.afterDataFsync");
  const auto interrupted = call(root, "publish", source.string(), "intent-001", "artwork-001",
                                "attachment-001", "payload.pdf");
  custody::test_reset_hooks();
  if (interrupted.outcome != "ioFailure") return "data-stage crash did not interrupt";
  if (call(root, "publicationStatus", {}, "intent-001", "artwork-001", "attachment-001", "payload.pdf").outcome != "publicationPartial") {
    return "partial staged publication was not reported";
  }
  if (call(root, "rollbackPublication", {}, "intent-001", "artwork-001", "attachment-001", "payload.pdf").outcome != "publicationRolledBack") {
    return "partial staged publication did not roll back";
  }
  fs::remove_all(root);
  return {};
}

inline std::string publication_retry_and_concurrency_tests() {
  const fs::path root = unique_path("archivale-publish-concurrent-");
  fs::create_directories(root);
  const fs::path pdf = root / "source.pdf";
  const fs::path jpg = root / "source.jpg";
  write_file(pdf, "%PDF-1.4\npdf\n%%EOF\n");
  write_file(jpg, "jpeg-fixture");
  custody::Result left;
  custody::Result right;
  std::thread first([&] {
    left = call(root, "publish", pdf.string(), "intent-pdf", "artwork-001", "attachment-001", "payload.pdf");
  });
  std::thread second([&] {
    right = call(root, "publish", jpg.string(), "intent-jpg", "artwork-001", "attachment-001", "payload.jpg");
  });
  first.join();
  second.join();
  const int published = (left.outcome == "published" ? 1 : 0) + (right.outcome == "published" ? 1 : 0);
  if (published != 1) return "different-extension publication was not attachment-wide exclusive";
  const std::string loser_operation = left.outcome == "published" ? "intent-jpg" : "intent-pdf";
  const std::string loser_name = left.outcome == "published" ? "payload.jpg" : "payload.pdf";
  const auto cleanup = call(root, "cleanupPublication", {}, loser_operation, "artwork-001", "attachment-001", loser_name);
  if (cleanup.outcome != "cleanupComplete" && cleanup.outcome != "publicationConflict") {
    return "losing concurrent publication was not cleanable: " + cleanup.outcome;
  }
  const auto scan = call(root, "scan");
  if (scan.outcome != "scanComplete" || scan.entries.size() != 1) return "concurrent publication left noncanonical geometry";

  const bool pdf_won = scan.entries.front().canonical_name == "payload.pdf";
  const std::string winner_operation = pdf_won ? "intent-pdf" : "intent-jpg";
  const std::string winner_name = pdf_won ? "payload.pdf" : "payload.jpg";
  const fs::path winner_source = pdf_won ? pdf : jpg;
  const auto retry = call(root, "publish", winner_source.string(), winner_operation,
                          "artwork-001", "attachment-001", winner_name);
  if (retry.outcome != "alreadyExists" && retry.outcome != "publicationConflict") {
    return "completed publication retry did not preserve no-replace semantics: " + retry.outcome;
  }

  custody::test_fail_at("rollback.dataUnlink");
  const fs::path partial_root = unique_path("archivale-cleanup-failure-");
  fs::create_directories(partial_root);
  const fs::path partial_source = partial_root / "source.pdf";
  write_file(partial_source, "%PDF-1.4\ncleanup\n%%EOF\n");
  custody::test_crash_at("publish.afterDataFsync");
  call(partial_root, "publish", partial_source.string(), "intent-cleanup", "artwork-001", "attachment-001", "payload.pdf");
  custody::g_test_hooks.crash_point.clear();
  const auto failed_cleanup = call(partial_root, "rollbackPublication", {}, "intent-cleanup", "artwork-001", "attachment-001", "payload.pdf");
  custody::test_reset_hooks();
  if (failed_cleanup.outcome != "ioFailure") return "injected cleanup unlink failure was swallowed";
  if (call(partial_root, "rollbackPublication", {}, "intent-cleanup", "artwork-001", "attachment-001", "payload.pdf").outcome != "publicationRolledBack") {
    return "cleanup retry did not converge";
  }
  fs::remove_all(partial_root);
  fs::remove_all(root);
  return {};
}

inline std::string erasure_control_tests() {
  const std::vector<std::string> points = {
      "erasure.afterTempFsync", "erasure.afterCurrentLink", "erasure.afterTempCleanup"};
  for (const std::string& point : points) {
    const fs::path root = unique_path("archivale-erasure-crash-");
    fs::create_directories(root);
    custody::test_crash_at(point);
    const auto interrupted = call(root, "writeErasureControl", {}, "erase-001");
    custody::test_reset_hooks();
    if (interrupted.outcome != "ioFailure") return "erasure crash point did not interrupt: " + point;
    const auto recovered = call(root, "recoverErasureControl", {}, "erase-001");
    if (recovered.outcome != "erasureOwned" || recovered.owner != "erase-001" || recovered.phase != "erasing") {
      return "erasure control did not recover: " + point + " -> " + recovered.outcome;
    }
    if (call(root, "clearErasureControl", {}, "erase-001").outcome != "erasureAbsent") return "owned erasure control did not clear";
    fs::remove_all(root);
  }

  const fs::path root = unique_path("archivale-erasure-negative-");
  fs::create_directories(root);
  if (call(root, "writeErasureControl", {}, "erase-owner").outcome != "erasureOwned") return "erasure owner write failed";
  if (call(root, "readErasureControl", {}, "erase-foreign").outcome != "erasureConflict") return "foreign owner was not distinguished";
  if (call(root, "clearErasureControl", {}, "erase-foreign").outcome != "erasureConflict") return "foreign owner cleared erasure control";
  if (call(root, "clearErasureControl", {}, "erase-owner").outcome != "erasureAbsent") return "exact owner clear failed";

  const fs::path control = root / "erasure-control";
  fs::create_directories(control);
  write_file(control / "current.json", "{\"version\":1");
  if (call(root, "readErasureControl").outcome != "erasureUnsafe") return "partial erasure control was not unsafe";
  fs::remove(control / "current.json");
  const fs::path sentinel = root.parent_path() / custody::random_name("erasure-sentinel-");
  write_file(sentinel, "sentinel");
  fs::create_symlink(sentinel, control / "current.json");
  if (call(root, "readErasureControl").outcome != "erasureUnsafe") return "symlink erasure control was not unsafe";
  fs::remove(control / "current.json");
  write_file(control / "current.json", custody::erasure_json("erase-owner"));
  fs::create_hard_link(control / "current.json", control / "foreign-link");
  if (call(root, "readErasureControl", {}, "erase-owner").outcome != "erasureUnsafe") return "unowned marker hard link was not unsafe";
  const Fingerprint before = fingerprint(sentinel);
  if (!same_fingerprint(before, fingerprint(sentinel))) return "erasure negative tests changed sentinel";
  fs::remove_all(root);
  fs::remove(sentinel);
  return {};
}

inline std::string fail_closed_capability_test() {
  const fs::path root = unique_path("archivale-capability-");
  fs::create_directories(root);
  if (call(root, "selfTest").outcome != "available") return "native capability self-test did not pass";
  custody::test_fail_at("selfTest.linkFsync");
  const auto failed = call(root, "selfTest");
  custody::test_reset_hooks();
  fs::remove_all(root);
  return require(failed.outcome == "unsupported", "capability probe did not fail closed");
}

inline std::string race_tests(int repetitions = 40) {
  const fs::path sentinel = unique_path("archivale-custody-sentinel-");
  const std::string sentinel_bytes = "outside-root-sentinel-with-stable-identity";
  write_file(sentinel, sentinel_bytes);
  const Fingerprint expected = fingerprint(sentinel);

  for (int iteration = 0; iteration < repetitions; ++iteration) {
    const fs::path root = unique_path("archivale-leaf-race-");
    fs::create_directories(root);
    const fs::path source = root / "source.pdf";
    write_file(source, "%PDF-1.4\nrace\n%%EOF\n");
    if (call(root, "publish", source.string(), "intent-race", "artwork-001", "attachment-001", "payload.pdf").outcome != "published") {
      return "race setup publication failed";
    }
    const fs::path directory = root / "attachments/artworks/artwork-001/attachments/attachment-001";
    const fs::path leaf = directory / "payload.pdf";
    const fs::path held = directory / ".held";
    std::atomic<bool> stop{false};
    std::thread attacker([&] {
      while (!stop.load()) {
        rename(leaf.c_str(), held.c_str());
        symlink(sentinel.c_str(), leaf.c_str());
        unlink(leaf.c_str());
        link(sentinel.c_str(), leaf.c_str());
        unlink(leaf.c_str());
        rename(held.c_str(), leaf.c_str());
      }
    });
    for (int attempt = 0; attempt < 20; ++attempt) {
      call(root, "remove", {}, {}, "artwork-001", "attachment-001", "payload.pdf");
      if (!same_fingerprint(expected, fingerprint(sentinel))) {
        stop.store(true);
        attacker.join();
        return "leaf symlink/hard-link/rename race changed sentinel identity, bytes, or hash";
      }
    }
    stop.store(true);
    attacker.join();
    if (!same_fingerprint(expected, fingerprint(sentinel))) return "leaf race changed sentinel after join";
    fs::remove_all(root);
  }

  for (int iteration = 0; iteration < repetitions; ++iteration) {
    const fs::path root = unique_path("archivale-intermediate-race-");
    fs::create_directories(root);
    const fs::path source = root / "source.pdf";
    write_file(source, "%PDF-1.4\nintermediate\n%%EOF\n");
    if (call(root, "publish", source.string(), "intent-race", "artwork-001", "attachment-001", "payload.pdf").outcome != "published") {
      return "intermediate race setup publication failed";
    }
    const fs::path parent = root / "attachments/artworks/artwork-001/attachments";
    const fs::path attachment = parent / "attachment-001";
    const fs::path held = parent / "attachment-held";
    const fs::path outside = root.parent_path() / custody::random_name("outside-directory-");
    fs::create_directories(outside);
    fs::create_hard_link(sentinel, outside / "payload.pdf");
    std::atomic<bool> stop{false};
    std::thread attacker([&] {
      while (!stop.load()) {
        rename(attachment.c_str(), held.c_str());
        symlink(outside.c_str(), attachment.c_str());
        unlink(attachment.c_str());
        rename(held.c_str(), attachment.c_str());
      }
    });
    for (int attempt = 0; attempt < 20; ++attempt) {
      call(root, "remove", {}, {}, "artwork-001", "attachment-001", "payload.pdf");
      if (!same_fingerprint(expected, fingerprint(sentinel))) {
        stop.store(true);
        attacker.join();
        return "intermediate swap race changed sentinel identity, bytes, or hash";
      }
    }
    stop.store(true);
    attacker.join();
    if (!same_fingerprint(expected, fingerprint(sentinel))) return "intermediate race changed sentinel after join";
    fs::remove_all(root);
    fs::remove_all(outside);
  }
  fs::remove(sentinel);
  return {};
}

inline std::string run_contract_suite() {
  for (const auto& test : {publication_crash_tests, publication_retry_and_concurrency_tests,
                           erasure_control_tests, fail_closed_capability_test}) {
    const std::string failure = test();
    if (!failure.empty()) return failure;
  }
  return {};
}

}  // namespace custody_test
