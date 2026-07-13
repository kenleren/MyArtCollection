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

  const fs::path ancestry_root = unique_path("archivale-ancestry-failure-");
  fs::create_directories(ancestry_root);
  const fs::path ancestry_source = ancestry_root / "source.pdf";
  write_file(ancestry_source, "%PDF-1.4\nancestry\n%%EOF\n");
  custody::test_fail_at("attachmentList.parentFsync");
  const auto ancestry_failure = call(ancestry_root, "publish", ancestry_source.string(),
                                     "intent-ancestry", "artwork-001", "attachment-001", "payload.pdf");
  custody::test_reset_hooks();
  if (ancestry_failure.outcome != "ioFailure") return "created-ancestry fsync failure was swallowed";
  if (call(ancestry_root, "cleanupPublication", {}, "intent-ancestry", "artwork-001",
           "attachment-001", "payload.pdf").outcome != "cleanupComplete") {
    return "partial publication ancestry did not clean up";
  }
  if (fs::exists(ancestry_root / "attachments/artworks")) return "empty partial publication ancestry remained";
  fs::remove_all(ancestry_root);
  fs::remove_all(root);
  return {};
}

inline std::string publication_scan_negative_tests() {
  for (const std::string& suffix : {std::string(".json"), std::string(".tmp")}) {
    for (const bool target_present : {false, true}) {
      const fs::path root = unique_path("archivale-malformed-staging-");
      const fs::path target =
          root / "attachments/artworks/artwork-001/attachments/attachment-001";
      const fs::path staging = root / "attachments/.staging";
      if (target_present) fs::create_directories(target);
      fs::create_directories(staging);
      write_file(staging / ("publication-intent-malformed" + suffix), "{\"version\":1");
      const auto status = call(root, "publicationStatus", {}, "intent-malformed",
                               "artwork-001", "attachment-001", "payload.pdf");
      const auto recovery = call(root, "recoverPublication", {}, "intent-malformed",
                                 "artwork-001", "attachment-001", "payload.pdf");
      const std::string geometry = target_present ? " with target" : " without target";
      if (status.outcome != "unsafeNode") {
        return "malformed owned staging " + suffix + geometry +
               " was not unsafe in status";
      }
      if (recovery.outcome != "unsafeNode") {
        return "malformed owned staging " + suffix + geometry +
               " was not unsafe in recovery";
      }
      if (call(root, "scan").outcome != "unsafeNode") {
        return "malformed owned staging " + suffix + geometry +
               " was not unsafe in scan";
      }
      fs::remove_all(root);
    }
  }

  {
    const fs::path root = unique_path("archivale-valid-temp-scan-");
    fs::create_directories(root);
    const fs::path source = root / "source.pdf";
    write_file(source, "%PDF-1.4\nvalid temporary descriptor\n%%EOF\n");
    custody::test_crash_at("publish.afterIntentFileFsync");
    const auto interrupted = call(root, "publish", source.string(), "intent-temp", "artwork-001",
                                  "attachment-001", "payload.pdf");
    custody::test_reset_hooks();
    if (interrupted.outcome != "ioFailure") return "temporary descriptor fixture did not interrupt";
    const auto scanned = call(root, "scan");
    if (scanned.outcome != "scanComplete" || scanned.publications.size() != 1 ||
        scanned.publications.front().operation_id != "intent-temp") {
      return "valid temporary descriptor was not fully exposed by scan";
    }
    fs::remove_all(root);
  }

  {
    const fs::path root = unique_path("archivale-mismatched-temp-scan-");
    fs::create_directories(root);
    const fs::path source = root / "source.pdf";
    write_file(source, "%PDF-1.4\nfilename mismatch\n%%EOF\n");
    custody::test_crash_at("publish.afterIntentFileFsync");
    call(root, "publish", source.string(), "intent-source", "artwork-001", "attachment-001", "payload.pdf");
    custody::test_reset_hooks();
    fs::rename(root / "attachments/.staging/publication-intent-source.tmp",
               root / "attachments/.staging/publication-intent-other.tmp");
    if (call(root, "scan").outcome != "unsafeNode") {
      return "staging filename and descriptor operation mismatch was accepted";
    }
    fs::remove_all(root);
  }

  for (const std::string& point : {std::string("publish.afterClaim"),
                                   std::string("publish.afterDataCleanup")}) {
    const fs::path root = unique_path("archivale-recoverable-scan-");
    fs::create_directories(root);
    const fs::path source = root / "source.pdf";
    write_file(source, "%PDF-1.4\nrecoverable scan geometry\n%%EOF\n");
    custody::test_crash_at(point);
    const auto interrupted = call(root, "publish", source.string(), "intent-recoverable",
                                  "artwork-001", "attachment-001", "payload.pdf");
    custody::test_reset_hooks();
    if (interrupted.outcome != "ioFailure") {
      return "recoverable scan fixture did not interrupt at " + point;
    }
    const auto scanned = call(root, "scan");
    const size_t expected_entries = point == "publish.afterClaim" ? 0 : 1;
    if (scanned.outcome != "scanComplete" || scanned.publications.size() != 1 ||
        scanned.entries.size() != expected_entries ||
        scanned.publications.front().operation_id != "intent-recoverable") {
      return "recoverable scan geometry was rejected at " + point;
    }
    if (call(root, "recoverPublication", {}, "intent-recoverable", "artwork-001",
             "attachment-001", "payload.pdf").outcome != "publicationRecovered") {
      return "recoverable scan fixture did not converge at " + point;
    }
    fs::remove_all(root);
  }

  for (const bool add_second_payload : {false, true}) {
    const fs::path root = unique_path(add_second_payload ? "archivale-multiple-claim-payload-"
                                                         : "archivale-claim-name-mismatch-");
    fs::create_directories(root);
    const fs::path source = root / "source.pdf";
    write_file(source, "%PDF-1.4\nclaimed payload geometry\n%%EOF\n");
    custody::test_crash_at("publish.afterPayloadLink");
    call(root, "publish", source.string(), "intent-claim", "artwork-001", "attachment-001", "payload.pdf");
    custody::test_reset_hooks();
    const fs::path attachment = root / "attachments/artworks/artwork-001/attachments/attachment-001";
    if (add_second_payload) {
      fs::create_hard_link(attachment / "payload.pdf", attachment / "payload.jpg");
    } else {
      fs::rename(attachment / "payload.pdf", attachment / "payload.jpg");
    }
    if (call(root, "scan").outcome != "unsafeNode") {
      return add_second_payload ? "multiple claimed payloads were accepted"
                                : "claim and payload canonical-name mismatch was accepted";
    }
    fs::remove_all(root);
  }

  {
    const fs::path root = unique_path("archivale-claim-payload-identity-");
    fs::create_directories(root);
    const fs::path source = root / "source.pdf";
    const std::string bytes = "%PDF-1.4\nclaimed payload identity\n%%EOF\n";
    write_file(source, bytes);
    custody::test_crash_at("publish.afterPayloadLink");
    call(root, "publish", source.string(), "intent-claim", "artwork-001",
         "attachment-001", "payload.pdf");
    custody::test_reset_hooks();
    const fs::path attachment =
        root / "attachments/artworks/artwork-001/attachments/attachment-001";
    fs::rename(attachment / "payload.pdf", attachment / "held-payload.pdf");
    write_file(attachment / "payload.pdf", bytes);
    if (call(root, "scan").outcome != "unsafeNode") {
      return "claim and same-name payload inode mismatch was accepted";
    }
    fs::remove_all(root);
  }
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

  if (call(root, "writeErasureControl", {}, "erase-inspection").outcome != "erasureOwned") {
    return "erasure inspection fixture write failed";
  }
  custody::test_fail_at("directory.emptyInspect");
  const auto inspection_failure = call(root, "clearErasureControl", {}, "erase-inspection");
  custody::test_reset_hooks();
  if (inspection_failure.outcome != "ioFailure") return "erasure cleanup inspection failure was swallowed";
  if (call(root, "clearErasureControl", {}, "erase-inspection").outcome != "erasureAbsent") {
    return "erasure cleanup inspection retry did not converge";
  }

  if (call(root, "writeErasureControl", {}, "erase-fsync").outcome != "erasureOwned") return "erasure fsync fixture write failed";
  custody::test_fail_at("erasure.currentClearFsync");
  const auto clear_failure = call(root, "clearErasureControl", {}, "erase-fsync");
  custody::test_reset_hooks();
  if (clear_failure.outcome != "ioFailure") return "erasure clear fsync failure was swallowed";
  if (call(root, "clearErasureControl", {}, "erase-fsync").outcome != "erasureAbsent") return "erasure clear retry did not converge";

  custody::test_crash_at("erasure.afterTempFsync");
  call(root, "writeErasureControl", {}, "erase-pending");
  custody::test_reset_hooks();
  const auto pending = call(root, "readErasureControl", {}, "erase-pending");
  if (pending.outcome != "erasurePending" || pending.owner != "erase-pending") return "partial erasure control was not reported as pending";
  if (call(root, "readErasureControl", {}, "erase-foreign").outcome != "erasureConflict") return "foreign pending erasure owner was not distinguished";
  if (call(root, "cleanupErasureControl", {}, "erase-pending").outcome != "erasureAbsent") return "pending erasure cleanup failed";

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

inline std::string erasure_race_and_exclusivity_tests() {
  {
    const fs::path root = unique_path("archivale-erasure-concurrent-");
    fs::create_directories(root);
    custody::Result left;
    custody::Result right;
    std::thread first([&] { left = call(root, "writeErasureControl", {}, "erase-left"); });
    std::thread second([&] { right = call(root, "writeErasureControl", {}, "erase-right"); });
    first.join();
    second.join();
    const int owned = (left.outcome == "erasureOwned" ? 1 : 0) +
                      (right.outcome == "erasureOwned" ? 1 : 0);
    const int conflicts = (left.outcome == "erasureConflict" ? 1 : 0) +
                          (right.outcome == "erasureConflict" ? 1 : 0);
    if (owned != 1 || conflicts != 1) return "concurrent erasure owners were not serialized exactly";
    fs::remove_all(root);
  }

  {
    const fs::path root = unique_path("archivale-erasure-current-swap-");
    fs::create_directories(root);
    if (call(root, "writeErasureControl", {}, "erase-owner").outcome != "erasureOwned") {
      return "erasure current-swap fixture write failed";
    }
    const fs::path control = root / "erasure-control";
    const fs::path replacement = control / "current.json";
    custody::test_at_boundary([&](const char* point) {
      if (std::string(point) != "erasure.beforeCurrentUnlink") return;
      fs::rename(replacement, control / "held-current.json");
      write_file(replacement, custody::erasure_json("erase-foreign"));
    });
    const auto cleared = call(root, "clearErasureControl", {}, "erase-owner");
    custody::test_reset_hooks();
    if (cleared.outcome != "erasureUnsafe") return "current inode replacement was not rejected before clear";
    if (fingerprint(replacement).bytes != custody::erasure_json("erase-foreign")) {
      return "current inode replacement was mutated by exact-owner clear";
    }
    fs::remove_all(root);
  }

  {
    const fs::path root = unique_path("archivale-erasure-directory-swap-");
    fs::create_directories(root);
    if (call(root, "writeErasureControl", {}, "erase-owner").outcome != "erasureOwned") {
      return "erasure directory-swap fixture write failed";
    }
    const fs::path control = root / "erasure-control";
    const fs::path held = root / "held-erasure-control";
    custody::test_at_boundary([&](const char* point) {
      if (std::string(point) != "erasure.beforeCurrentUnlink") return;
      fs::rename(control, held);
      fs::create_directories(control);
      write_file(control / "current.json", custody::erasure_json("erase-foreign"));
    });
    const auto cleared = call(root, "clearErasureControl", {}, "erase-owner");
    custody::test_reset_hooks();
    if (cleared.outcome != "erasureUnsafe") return "control-directory replacement was not rejected before clear";
    if (fingerprint(control / "current.json").bytes != custody::erasure_json("erase-foreign")) {
      return "replacement control directory was mutated by exact-owner clear";
    }
    fs::remove_all(root);
  }

  {
    const fs::path root = unique_path("archivale-erasure-temp-swap-");
    fs::create_directories(root);
    custody::test_crash_at("erasure.afterCurrentLink");
    const auto interrupted = call(root, "writeErasureControl", {}, "erase-owner");
    custody::test_reset_hooks();
    if (interrupted.outcome != "ioFailure") return "erasure temp-swap fixture did not interrupt";
    const fs::path control = root / "erasure-control";
    const fs::path temp = control / "current-erase-owner.tmp";
    custody::test_at_boundary([&](const char* point) {
      if (std::string(point) != "erasure.beforeClearTempUnlink") return;
      fs::rename(temp, control / "held-owner.tmp");
      write_file(temp, custody::erasure_json("erase-foreign"));
    });
    const auto cleared = call(root, "clearErasureControl", {}, "erase-owner");
    custody::test_reset_hooks();
    if (cleared.outcome != "erasureUnsafe") return "temporary owner replacement was not rejected before cleanup";
    if (fingerprint(temp).bytes != custody::erasure_json("erase-foreign")) {
      return "replacement temporary owner was mutated by clear cleanup";
    }
    fs::remove_all(root);
  }
  return {};
}

inline std::string fail_closed_capability_test() {
  const fs::path root = unique_path("archivale-capability-");
  fs::create_directories(root);
  if (call(root, "selfTest").outcome != "available") return "native capability self-test did not pass";
  custody::test_fail_at("selfTest.linkFsync");
  const auto failed = call(root, "selfTest");
  custody::test_reset_hooks();
  if (failed.outcome != "unsupported") return "capability probe did not fail closed";
  for (const std::string& point : {"selfTest.noReplaceCollision", "selfTest.directoryRmdir"}) {
    custody::test_fail_at(point);
    const auto negative = call(root, "selfTest");
    custody::test_reset_hooks();
    if (negative.outcome != "unsupported") return "capability probe did not fail closed at " + point;
  }
  const auto scan = call(root, "scan");
  fs::remove_all(root);
  return require(scan.outcome == "scanComplete", "failed capability probe left unsafe nodes");
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
                           publication_scan_negative_tests, erasure_control_tests,
                           erasure_race_and_exclusivity_tests, fail_closed_capability_test}) {
    const std::string failure = test();
    if (!failure.empty()) return failure;
  }
  return {};
}

}  // namespace custody_test
