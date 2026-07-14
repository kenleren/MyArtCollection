#include <cerrno>
#include <cstdint>
#include <cstring>
#include <dirent.h>
#include <fcntl.h>
#include <stdio.h>
#include <sys/file.h>
#include <sys/stat.h>
#include <sys/syscall.h>
#include <sys/types.h>
#include <unistd.h>

#if !defined(__APPLE__)
#include <linux/fs.h>
#endif

#include <algorithm>
#include <array>
#include <cctype>
#include <cstdlib>
#include <functional>
#include <limits>
#include <map>
#include <set>
#include <sstream>
#include <string>
#include <utility>
#include <vector>

#ifdef __ANDROID__
#include <jni.h>
#endif

namespace custody {

constexpr char kAttachments[] = "attachments";
constexpr char kArtworks[] = "artworks";
constexpr char kStaging[] = ".staging";
constexpr char kPublicationClaim[] = ".publication.json";
constexpr char kErasureControl[] = "erasure-control";
constexpr char kErasureCurrent[] = "current.json";
constexpr char kErasurePhase[] = "erasing";

struct Entry {
  std::string artwork_id;
  std::string attachment_id;
  std::string canonical_name;
};

struct PublicationState {
  std::string operation_id;
  std::string artwork_id;
  std::string attachment_id;
  std::string canonical_name;
  std::string phase;
  std::string sha256;
  uint64_t size = 0;
};

struct Result {
  std::string outcome;
  std::string detail;
  std::vector<Entry> entries;
  std::vector<PublicationState> publications;
  std::string owner;
  std::string phase;
};

class Fd {
 public:
  explicit Fd(int value = -1) : value_(value) {}
  ~Fd() {
    if (value_ >= 0) close(value_);
  }
  Fd(const Fd&) = delete;
  Fd& operator=(const Fd&) = delete;
  Fd(Fd&& other) noexcept : value_(std::exchange(other.value_, -1)) {}
  Fd& operator=(Fd&& other) noexcept {
    if (this != &other) {
      if (value_ >= 0) close(value_);
      value_ = std::exchange(other.value_, -1);
    }
    return *this;
  }
  int get() const { return value_; }
  bool valid() const { return value_ >= 0; }
  int release() { return std::exchange(value_, -1); }

 private:
  int value_;
};

class FileLock {
 public:
  explicit FileLock(int fd) : fd_(fd), locked_(flock(fd_, LOCK_EX) == 0) {}
  ~FileLock() {
    if (locked_) flock(fd_, LOCK_UN);
  }
  FileLock(const FileLock&) = delete;
  FileLock& operator=(const FileLock&) = delete;
  bool valid() const { return locked_; }

 private:
  int fd_;
  bool locked_;
};

#ifdef ATTACHMENT_CUSTODY_TESTING
struct TestHooks {
  std::string crash_point;
  std::string failure_point;
  std::function<void(const char*)> boundary;
};
thread_local TestHooks g_test_hooks;
void test_crash_at(const std::string& point) { g_test_hooks.crash_point = point; }
void test_fail_at(const std::string& point) { g_test_hooks.failure_point = point; }
void test_at_boundary(std::function<void(const char*)> callback) { g_test_hooks.boundary = std::move(callback); }
void test_reset_hooks() { g_test_hooks = {}; }
bool crash_at(const char* point) {
  if (g_test_hooks.crash_point != point) return false;
  g_test_hooks.crash_point.clear();
  return true;
}
bool fail_at(const char* point) {
  if (g_test_hooks.failure_point != point) return false;
  g_test_hooks.failure_point.clear();
  errno = EIO;
  return true;
}
void run_boundary(const char* point) {
  if (g_test_hooks.boundary) g_test_hooks.boundary(point);
}
#else
bool crash_at(const char*) { return false; }
bool fail_at(const char*) { return false; }
void run_boundary(const char*) {}
#endif

Result result(std::string outcome, std::string detail = {}) {
  return Result{std::move(outcome), std::move(detail), {}, {}, {}, {}};
}

bool opaque_id(const std::string& value) {
  if (value.empty() || value.size() > 128) return false;
  if (!std::isalnum(static_cast<unsigned char>(value.front()))) return false;
  for (unsigned char ch : value) {
    if (!(std::isalnum(ch) || ch == '_' || ch == '-')) return false;
  }
  return true;
}

bool canonical_name(const std::string& value) {
  static const std::set<std::string> allowed = {
      "payload.jpg", "payload.jpeg", "payload.png", "payload.heic", "payload.heif", "payload.pdf"};
  return allowed.count(value) != 0;
}

bool same_inode(const struct stat& left, const struct stat& right) {
  return left.st_dev == right.st_dev && left.st_ino == right.st_ino;
}

bool sync_fd(int fd, const char* point) {
  return !fail_at(point) && fsync(fd) == 0;
}

bool unlink_entry(int parent, const std::string& name, int flags, const char* point) {
  return !fail_at(point) && unlinkat(parent, name.c_str(), flags) == 0;
}

bool write_all(int fd, const std::string& value) {
  size_t offset = 0;
  while (offset < value.size()) {
    const ssize_t count = write(fd, value.data() + offset, value.size() - offset);
    if (count <= 0) return false;
    offset += static_cast<size_t>(count);
  }
  return true;
}

Fd open_root(const std::string& path) {
  const int raw = open(path.c_str(), O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW);
  if (raw < 0) return Fd();
  struct stat status {};
  if (fstat(raw, &status) != 0 || !S_ISDIR(status.st_mode)) {
    close(raw);
    errno = ELOOP;
    return Fd();
  }
  return Fd(raw);
}

Fd open_dir_at(int parent, const std::string& name, bool create, const char* sync_point = "directory.parentFsync") {
  struct stat before {};
  if (fstatat(parent, name.c_str(), &before, AT_SYMLINK_NOFOLLOW) != 0) {
    if (!create || errno != ENOENT) return Fd();
    if (mkdirat(parent, name.c_str(), 0700) != 0 && errno != EEXIST) return Fd();
    if (fstatat(parent, name.c_str(), &before, AT_SYMLINK_NOFOLLOW) != 0 ||
        !S_ISDIR(before.st_mode) || !sync_fd(parent, sync_point)) {
      return Fd();
    }
    struct stat durable {};
    if (fstatat(parent, name.c_str(), &durable, AT_SYMLINK_NOFOLLOW) != 0 ||
        !S_ISDIR(durable.st_mode) || !same_inode(before, durable)) {
      return Fd();
    }
  }
  if (!S_ISDIR(before.st_mode)) {
    errno = ELOOP;
    return Fd();
  }
  const int child = openat(parent, name.c_str(), O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW);
  if (child < 0) return Fd();
  struct stat opened {};
  if (fstat(child, &opened) != 0 || !S_ISDIR(opened.st_mode) || !same_inode(before, opened)) {
    close(child);
    errno = ELOOP;
    return Fd();
  }
  return Fd(child);
}

struct ExportPair {
  Fd payload;
  Fd metadata;
  ExportPair() : payload(-1), metadata(-1) {}
  ExportPair(Fd payload_value, Fd metadata_value)
      : payload(std::move(payload_value)), metadata(std::move(metadata_value)) {}
  bool valid() const { return payload.valid() && metadata.valid(); }
};

bool directory_identity_matches(int parent, const std::string& name, int opened);
bool entry_identity_matches(int parent, const std::string& name, const struct stat& expected);

Fd open_export_file_at(int parent, const std::string& name, struct stat* opened_status) {
  struct stat named {};
  if (fstatat(parent, name.c_str(), &named, AT_SYMLINK_NOFOLLOW) != 0 ||
      !S_ISREG(named.st_mode) || named.st_nlink != 1) {
    if (errno == 0) errno = ELOOP;
    return Fd();
  }
  Fd file(openat(parent, name.c_str(), O_RDONLY | O_CLOEXEC | O_NOFOLLOW));
  struct stat opened {};
  if (!file.valid() || fstat(file.get(), &opened) != 0 ||
      !S_ISREG(opened.st_mode) || opened.st_nlink != 1 || !same_inode(named, opened)) {
    if (errno == 0) errno = ELOOP;
    return Fd();
  }
  *opened_status = opened;
  return file;
}

ExportPair open_export_pair(const std::string& platform_root, const std::string& source_path) {
  const std::string prefix = platform_root + "/generated_exports/";
  if (platform_root.empty() || source_path.rfind(prefix, 0) != 0) return {};
  const std::string relative = source_path.substr(prefix.size());
  const size_t separator = relative.find('/');
  if (separator == std::string::npos || relative.find('/', separator + 1) != std::string::npos) return {};
  const std::string kind = relative.substr(0, separator);
  const std::string payload_name = relative.substr(separator + 1);
  const bool report = kind == "reports" && payload_name.ends_with(".pdf");
  const bool archive = kind == "archives" && payload_name.ends_with(".zip");
  if ((!report && !archive) || payload_name.empty() || payload_name.size() > 160 ||
      payload_name == "." || payload_name == "..") {
    return {};
  }
  for (unsigned char ch : payload_name) {
    if (ch < 0x20 || ch == 0x7f || ch == '/' || ch == '\\') return {};
  }

  Fd root = open_root(platform_root);
  if (!root.valid()) return {};
  run_boundary("export.afterRootOpen");
  Fd exports = open_dir_at(root.get(), "generated_exports", false);
  if (!exports.valid()) return {};
  run_boundary("export.afterExportsOpen");
  Fd kind_directory = open_dir_at(exports.get(), kind, false);
  if (!kind_directory.valid()) return {};
  run_boundary("export.afterKindOpen");

  struct stat payload_status {};
  struct stat metadata_status {};
  Fd payload = open_export_file_at(kind_directory.get(), payload_name, &payload_status);
  Fd metadata = open_export_file_at(
      kind_directory.get(), payload_name + ".json", &metadata_status);
  if (!payload.valid() || !metadata.valid()) return {};
  run_boundary("export.afterPairOpen");

  struct stat final_payload {};
  struct stat final_metadata {};

  if (!directory_identity_matches(root.get(), "generated_exports", exports.get()) ||
      !directory_identity_matches(exports.get(), kind, kind_directory.get()) ||
      fstat(payload.get(), &final_payload) != 0 || final_payload.st_nlink != 1 ||
      fstat(metadata.get(), &final_metadata) != 0 || final_metadata.st_nlink != 1 ||
      !entry_identity_matches(kind_directory.get(), payload_name, payload_status) ||
      !entry_identity_matches(kind_directory.get(), payload_name + ".json", metadata_status)) {
    errno = ELOOP;
    return {};
  }
  return ExportPair(std::move(payload), std::move(metadata));
}

bool list_names(int fd, std::vector<std::string>* names) {
  const int copy = dup(fd);
  if (copy < 0) return false;
  DIR* dir = fdopendir(copy);
  if (dir == nullptr) {
    close(copy);
    return false;
  }
  errno = 0;
  while (dirent* entry = readdir(dir)) {
    if (std::strcmp(entry->d_name, ".") != 0 && std::strcmp(entry->d_name, "..") != 0) {
      names->emplace_back(entry->d_name);
    }
  }
  const bool ok = errno == 0;
  closedir(dir);
  std::sort(names->begin(), names->end());
  return ok;
}

bool inspect_empty_directory(int fd, bool* empty) {
  if (fail_at("directory.emptyInspect")) return false;
  std::vector<std::string> names;
  if (!list_names(fd, &names)) return false;
  *empty = names.empty();
  return true;
}

bool directory_identity_matches(int parent, const std::string& name, int opened) {
  struct stat named_status {};
  struct stat opened_status {};
  return fstatat(parent, name.c_str(), &named_status, AT_SYMLINK_NOFOLLOW) == 0 &&
         fstat(opened, &opened_status) == 0 && S_ISDIR(named_status.st_mode) &&
         S_ISDIR(opened_status.st_mode) && same_inode(named_status, opened_status);
}

bool entry_identity_matches(int parent, const std::string& name, const struct stat& expected) {
  struct stat current {};
  return fstatat(parent, name.c_str(), &current, AT_SYMLINK_NOFOLLOW) == 0 &&
         S_ISREG(current.st_mode) && same_inode(current, expected);
}

Result unsafe_or_io(const char* detail) {
  return result(errno == ELOOP || errno == ENOTDIR || errno == EMLINK ? "unsafeNode" : "ioFailure", detail);
}

struct TargetDirs {
  std::string artwork_id;
  std::string attachment_id;
  int platform = -1;
  Fd root;
  Fd artworks;
  Fd artwork;
  Fd attachments;
  Fd attachment;
};

Result open_attachment_root(int platform_root, bool create, Fd* root) {
  if (platform_root < 0) return result("unsafeNode", "The app-private root is unsafe or unavailable.");
  *root = open_dir_at(platform_root, kAttachments, create, "attachments.parentFsync");
  return root->valid() ? result("available")
                       : unsafe_or_io("The app-private attachment root is unsafe or unavailable.");
}

Result open_target(int platform_root, const std::string& artwork_id,
                   const std::string& attachment_id, bool create, TargetDirs* dirs) {
  dirs->artwork_id = artwork_id;
  dirs->attachment_id = attachment_id;
  dirs->platform = platform_root;
  if (dirs->platform < 0) return result("unsafeNode", "The app-private root is unsafe or unavailable.");
  dirs->root = open_dir_at(dirs->platform, kAttachments, create, "attachments.parentFsync");
  if (!dirs->root.valid()) return unsafe_or_io("The app-private attachment root is unsafe or unavailable.");
  dirs->artworks = open_dir_at(dirs->root.get(), kArtworks, create, "artworks.parentFsync");
  if (!dirs->artworks.valid()) return unsafe_or_io("The canonical artworks directory is unsafe.");
  dirs->artwork = open_dir_at(dirs->artworks.get(), artwork_id, create, "artwork.parentFsync");
  if (!dirs->artwork.valid()) return unsafe_or_io("The canonical artwork directory is unsafe.");
  dirs->attachments = open_dir_at(dirs->artwork.get(), "attachments", create, "attachmentList.parentFsync");
  if (!dirs->attachments.valid()) return unsafe_or_io("The canonical attachments directory is unsafe.");
  dirs->attachment = open_dir_at(dirs->attachments.get(), attachment_id, create, "attachment.parentFsync");
  if (!dirs->attachment.valid()) return unsafe_or_io("The canonical attachment directory is unsafe.");
  return result("available");
}

bool target_chain_matches(const TargetDirs& dirs) {
  return dirs.platform >= 0 && dirs.root.valid() && dirs.artworks.valid() &&
         dirs.artwork.valid() && dirs.attachments.valid() && dirs.attachment.valid() &&
         directory_identity_matches(dirs.platform, kAttachments, dirs.root.get()) &&
         directory_identity_matches(dirs.root.get(), kArtworks, dirs.artworks.get()) &&
         directory_identity_matches(dirs.artworks.get(), dirs.artwork_id, dirs.artwork.get()) &&
         directory_identity_matches(dirs.artwork.get(), "attachments", dirs.attachments.get()) &&
         directory_identity_matches(dirs.attachments.get(), dirs.attachment_id, dirs.attachment.get());
}

bool staging_chain_matches(const TargetDirs& dirs, int staging) {
  return target_chain_matches(dirs) &&
         directory_identity_matches(dirs.root.get(), kStaging, staging);
}

bool entry_absent(int parent, const std::string& name) {
  struct stat status {};
  if (fstatat(parent, name.c_str(), &status, AT_SYMLINK_NOFOLLOW) == 0) return false;
  return errno == ENOENT;
}

bool unsupported_rename_error(int error) {
  return error == ENOSYS || error == EOPNOTSUPP || error == ENOTSUP ||
         error == EINVAL || error == EXDEV;
}

int rename_exclusive_at(int source_parent, const std::string& source,
                        int destination_parent, const std::string& destination) {
#if defined(__APPLE__)
  return renameatx_np(source_parent, source.c_str(), destination_parent,
                      destination.c_str(), RENAME_EXCL);
#elif defined(SYS_renameat2)
  return static_cast<int>(syscall(SYS_renameat2, source_parent, source.c_str(),
                                  destination_parent, destination.c_str(),
                                  RENAME_NOREPLACE));
#else
  errno = ENOSYS;
  return -1;
#endif
}

Result mutation_failure(const char* detail, const char* unsafe_outcome) {
  if (unsupported_rename_error(errno)) return result("unsupported", detail);
  if (errno == ELOOP || errno == ENOTDIR || errno == EMLINK) {
    return result(unsafe_outcome, detail);
  }
  return result("ioFailure", detail);
}

using EntryValidator =
    std::function<bool(int, const std::string&, const struct stat&)>;

Result checked_exclusive_rename(
    int source_parent, const std::string& source, const struct stat& expected,
    int destination_parent, const std::string& destination,
    const std::function<bool()>& anchors, const char* rename_point,
    const char* source_fsync_point, const char* destination_fsync_point,
    const char* unsafe_outcome = "unsafeNode",
    const EntryValidator& entry_validator = {}) {
  const auto entry_matches = [&](int parent, const std::string& name) {
    return entry_validator ? entry_validator(parent, name, expected)
                           : entry_identity_matches(parent, name, expected);
  };
  run_boundary(rename_point);
  if (!anchors() || !entry_matches(source_parent, source) ||
      !entry_absent(destination_parent, destination)) {
    return result(unsafe_outcome, "Exclusive-rename prevalidation failed.");
  }
  if (fail_at(rename_point) ||
      rename_exclusive_at(source_parent, source, destination_parent, destination) != 0) {
    if (errno == EEXIST) return result("publicationConflict", "Exclusive destination already exists.");
    return mutation_failure("Exclusive rename failed without fallback.", unsafe_outcome);
  }
  if (!entry_absent(source_parent, source) ||
      !entry_matches(destination_parent, destination)) {
    return result(unsafe_outcome, "Exclusive-rename immediate validation failed.");
  }
  if (!sync_fd(source_parent, source_fsync_point) ||
      (source_parent != destination_parent &&
       !sync_fd(destination_parent, destination_fsync_point))) {
    return result("ioFailure", "Exclusive-rename directory durability failed.");
  }
  if (!anchors() || !entry_absent(source_parent, source) ||
      !entry_matches(destination_parent, destination)) {
    return result(unsafe_outcome, "Exclusive-rename final anchored validation failed.");
  }
  return result("available");
}

Result checked_unlink(int parent, const std::string& name,
                      const struct stat& expected,
                      const std::function<bool()>& anchors,
                      const char* unlink_point, const char* fsync_point,
                      const char* unsafe_outcome = "unsafeNode",
                      const EntryValidator& entry_validator = {}) {
  run_boundary(unlink_point);
  if (!anchors() ||
      !(entry_validator ? entry_validator(parent, name, expected)
                        : entry_identity_matches(parent, name, expected))) {
    return result(unsafe_outcome, "Unlink prevalidation failed.");
  }
  if (!unlink_entry(parent, name, 0, unlink_point)) {
    return mutation_failure("Unlink failed.", unsafe_outcome);
  }
  if (!entry_absent(parent, name)) {
    return result(unsafe_outcome, "Unlink immediate validation failed.");
  }
  if (!sync_fd(parent, fsync_point)) return result("ioFailure", "Unlink directory durability failed.");
  if (!anchors() || !entry_absent(parent, name)) {
    return result(unsafe_outcome, "Unlink final anchored validation failed.");
  }
  return result("available");
}

Result checked_rmdir(int parent, const std::string& name, int opened,
                     const std::function<bool()>& parent_anchor,
                     const char* rmdir_point, const char* fsync_point,
                     const char* unsafe_outcome = "unsafeNode") {
  bool empty = false;
  if (!inspect_empty_directory(opened, &empty)) {
    return result("ioFailure", "Could not inspect directory before pruning.");
  }
  if (!empty) return result("available");
  run_boundary(rmdir_point);
  if (!parent_anchor() || !directory_identity_matches(parent, name, opened)) {
    return result(unsafe_outcome, "Directory-prune prevalidation failed.");
  }
  if (!unlink_entry(parent, name, AT_REMOVEDIR, rmdir_point)) {
    if (errno == ENOTEMPTY || errno == EEXIST) return result("available");
    return mutation_failure("Directory prune failed.", unsafe_outcome);
  }
  if (!entry_absent(parent, name)) {
    return result(unsafe_outcome, "Directory-prune immediate validation failed.");
  }
  if (!sync_fd(parent, fsync_point)) return result("ioFailure", "Directory-prune durability failed.");
  if (!parent_anchor() || !entry_absent(parent, name)) {
    return result(unsafe_outcome, "Directory-prune final anchored validation failed.");
  }
  return result("available");
}

bool target_valid(const std::string& operation_id, const std::string& artwork_id,
                  const std::string& attachment_id, const std::string& name) {
  return opaque_id(operation_id) && opaque_id(artwork_id) && opaque_id(attachment_id) && canonical_name(name);
}

std::string random_name(const char* prefix) {
  std::array<unsigned char, 16> bytes{};
#if defined(__APPLE__)
  arc4random_buf(bytes.data(), bytes.size());
#elif defined(SYS_getrandom)
  if (syscall(SYS_getrandom, bytes.data(), bytes.size(), 0) != static_cast<long>(bytes.size())) return {};
#else
  return {};
#endif
  static constexpr char hex[] = "0123456789abcdef";
  std::string name(prefix);
  for (unsigned char byte : bytes) {
    name.push_back(hex[byte >> 4]);
    name.push_back(hex[byte & 0x0f]);
  }
  return name;
}

class Sha256 {
 public:
  Sha256() { reset(); }
  void update(const unsigned char* data, size_t length) {
    total_ += length;
    while (length > 0) {
      const size_t count = std::min(length, block_.size() - used_);
      std::memcpy(block_.data() + used_, data, count);
      used_ += count;
      data += count;
      length -= count;
      if (used_ == block_.size()) {
        transform(block_.data());
        used_ = 0;
      }
    }
  }
  std::string finish() {
    const uint64_t bits = static_cast<uint64_t>(total_) * 8;
    block_[used_++] = 0x80;
    if (used_ > 56) {
      while (used_ < 64) block_[used_++] = 0;
      transform(block_.data());
      used_ = 0;
    }
    while (used_ < 56) block_[used_++] = 0;
    for (int shift = 56; shift >= 0; shift -= 8) block_[used_++] = static_cast<unsigned char>(bits >> shift);
    transform(block_.data());
    static constexpr char hex[] = "0123456789abcdef";
    std::string output;
    output.reserve(64);
    for (uint32_t word : state_) {
      for (int shift = 28; shift >= 0; shift -= 4) output.push_back(hex[(word >> shift) & 0x0f]);
    }
    return output;
  }

 private:
  static uint32_t rotate(uint32_t value, int bits) { return (value >> bits) | (value << (32 - bits)); }
  void reset() {
    state_ = {0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a,
              0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19};
    used_ = 0;
    total_ = 0;
  }
  void transform(const unsigned char* data) {
    static constexpr std::array<uint32_t, 64> k = {
        0x428a2f98,0x71374491,0xb5c0fbcf,0xe9b5dba5,0x3956c25b,0x59f111f1,0x923f82a4,0xab1c5ed5,
        0xd807aa98,0x12835b01,0x243185be,0x550c7dc3,0x72be5d74,0x80deb1fe,0x9bdc06a7,0xc19bf174,
        0xe49b69c1,0xefbe4786,0x0fc19dc6,0x240ca1cc,0x2de92c6f,0x4a7484aa,0x5cb0a9dc,0x76f988da,
        0x983e5152,0xa831c66d,0xb00327c8,0xbf597fc7,0xc6e00bf3,0xd5a79147,0x06ca6351,0x14292967,
        0x27b70a85,0x2e1b2138,0x4d2c6dfc,0x53380d13,0x650a7354,0x766a0abb,0x81c2c92e,0x92722c85,
        0xa2bfe8a1,0xa81a664b,0xc24b8b70,0xc76c51a3,0xd192e819,0xd6990624,0xf40e3585,0x106aa070,
        0x19a4c116,0x1e376c08,0x2748774c,0x34b0bcb5,0x391c0cb3,0x4ed8aa4a,0x5b9cca4f,0x682e6ff3,
        0x748f82ee,0x78a5636f,0x84c87814,0x8cc70208,0x90befffa,0xa4506ceb,0xbef9a3f7,0xc67178f2};
    std::array<uint32_t, 64> w{};
    for (size_t i = 0; i < 16; ++i) {
      w[i] = (static_cast<uint32_t>(data[i * 4]) << 24) |
             (static_cast<uint32_t>(data[i * 4 + 1]) << 16) |
             (static_cast<uint32_t>(data[i * 4 + 2]) << 8) |
             static_cast<uint32_t>(data[i * 4 + 3]);
    }
    for (size_t i = 16; i < 64; ++i) {
      const uint32_t s0 = rotate(w[i - 15], 7) ^ rotate(w[i - 15], 18) ^ (w[i - 15] >> 3);
      const uint32_t s1 = rotate(w[i - 2], 17) ^ rotate(w[i - 2], 19) ^ (w[i - 2] >> 10);
      w[i] = w[i - 16] + s0 + w[i - 7] + s1;
    }
    uint32_t a=state_[0], b=state_[1], c=state_[2], d=state_[3];
    uint32_t e=state_[4], f=state_[5], g=state_[6], h=state_[7];
    for (size_t i = 0; i < 64; ++i) {
      const uint32_t s1 = rotate(e, 6) ^ rotate(e, 11) ^ rotate(e, 25);
      const uint32_t choice = (e & f) ^ (~e & g);
      const uint32_t temp1 = h + s1 + choice + k[i] + w[i];
      const uint32_t s0 = rotate(a, 2) ^ rotate(a, 13) ^ rotate(a, 22);
      const uint32_t majority = (a & b) ^ (a & c) ^ (b & c);
      const uint32_t temp2 = s0 + majority;
      h=g; g=f; f=e; e=d+temp1; d=c; c=b; b=a; a=temp1+temp2;
    }
    state_[0]+=a; state_[1]+=b; state_[2]+=c; state_[3]+=d;
    state_[4]+=e; state_[5]+=f; state_[6]+=g; state_[7]+=h;
  }
  std::array<uint32_t, 8> state_{};
  std::array<unsigned char, 64> block_{};
  size_t used_ = 0;
  size_t total_ = 0;
};

bool hash_fd(int fd, uint64_t* size, std::string* digest) {
  if (lseek(fd, 0, SEEK_SET) < 0) return false;
  Sha256 hash;
  std::array<unsigned char, 65536> buffer{};
  uint64_t total = 0;
  while (true) {
    const ssize_t count = read(fd, buffer.data(), buffer.size());
    if (count == 0) break;
    if (count < 0) return false;
    total += static_cast<uint64_t>(count);
    hash.update(buffer.data(), static_cast<size_t>(count));
  }
  *size = total;
  *digest = hash.finish();
  return lseek(fd, 0, SEEK_SET) >= 0;
}

bool copy_and_hash(int source, int destination, uint64_t* size, std::string* digest) {
  Sha256 hash;
  std::array<unsigned char, 65536> buffer{};
  uint64_t total = 0;
  while (true) {
    const ssize_t count = read(source, buffer.data(), buffer.size());
    if (count == 0) break;
    if (count < 0) return false;
    size_t offset = 0;
    while (offset < static_cast<size_t>(count)) {
      const ssize_t written = write(destination, buffer.data() + offset, static_cast<size_t>(count) - offset);
      if (written <= 0) return false;
      offset += static_cast<size_t>(written);
    }
    total += static_cast<uint64_t>(count);
    hash.update(buffer.data(), static_cast<size_t>(count));
  }
  *size = total;
  *digest = hash.finish();
  return true;
}

std::string publication_data_name(const std::string& operation_id) {
  return "publication-" + operation_id + ".data";
}
std::string publication_intent_name(const std::string& operation_id) {
  return "publication-" + operation_id + ".json";
}
std::string publication_temp_name(const std::string& operation_id) {
  return "publication-" + operation_id + ".tmp";
}

std::string publication_json(const PublicationState& value) {
  std::ostringstream out;
  out << "{\"version\":1,\"operationId\":\"" << value.operation_id
      << "\",\"artworkId\":\"" << value.artwork_id
      << "\",\"attachmentId\":\"" << value.attachment_id
      << "\",\"canonicalName\":\"" << value.canonical_name
      << "\",\"size\":" << value.size
      << ",\"sha256\":\"" << value.sha256
      << "\",\"phase\":\"staged\"}\n";
  return out.str();
}

bool take(std::string::const_iterator* cursor, const std::string::const_iterator& end, const char* literal) {
  while (*literal != '\0') {
    if (*cursor == end || **cursor != *literal) return false;
    ++(*cursor);
    ++literal;
  }
  return true;
}

bool take_quoted(std::string::const_iterator* cursor, const std::string::const_iterator& end,
                 std::string* output) {
  if (cursor == nullptr || *cursor == end || **cursor != '"') return false;
  ++(*cursor);
  while (*cursor != end && **cursor != '"') {
    const unsigned char ch = static_cast<unsigned char>(**cursor);
    if (!(std::isalnum(ch) || ch == '_' || ch == '-' || ch == '.')) return false;
    output->push_back(static_cast<char>(ch));
    ++(*cursor);
  }
  if (*cursor == end) return false;
  ++(*cursor);
  return true;
}

bool take_uint(std::string::const_iterator* cursor, const std::string::const_iterator& end, uint64_t* value) {
  if (*cursor == end || !std::isdigit(static_cast<unsigned char>(**cursor))) return false;
  uint64_t parsed = 0;
  while (*cursor != end && std::isdigit(static_cast<unsigned char>(**cursor))) {
    const unsigned digit = static_cast<unsigned>(**cursor - '0');
    if (parsed > (std::numeric_limits<uint64_t>::max() - digit) / 10) return false;
    parsed = parsed * 10 + digit;
    ++(*cursor);
  }
  *value = parsed;
  return true;
}

bool parse_publication(const std::string& json, PublicationState* value) {
  *value = {};
  auto cursor = json.begin();
  const auto end = json.end();
  uint64_t version = 0;
  if (!take(&cursor, end, "{\"version\":") || !take_uint(&cursor, end, &version) || version != 1 ||
      !take(&cursor, end, ",\"operationId\":") || !take_quoted(&cursor, end, &value->operation_id) ||
      !take(&cursor, end, ",\"artworkId\":") || !take_quoted(&cursor, end, &value->artwork_id) ||
      !take(&cursor, end, ",\"attachmentId\":") || !take_quoted(&cursor, end, &value->attachment_id) ||
      !take(&cursor, end, ",\"canonicalName\":") || !take_quoted(&cursor, end, &value->canonical_name) ||
      !take(&cursor, end, ",\"size\":") || !take_uint(&cursor, end, &value->size) ||
      !take(&cursor, end, ",\"sha256\":") || !take_quoted(&cursor, end, &value->sha256) ||
      !take(&cursor, end, ",\"phase\":") || !take_quoted(&cursor, end, &value->phase) ||
      !take(&cursor, end, "}\n") || cursor != end) {
    return false;
  }
  return opaque_id(value->operation_id) && opaque_id(value->artwork_id) &&
         opaque_id(value->attachment_id) && canonical_name(value->canonical_name) &&
         value->sha256.size() == 64 &&
         std::all_of(value->sha256.begin(), value->sha256.end(), [](unsigned char ch) {
           return std::isdigit(ch) || (ch >= 'a' && ch <= 'f');
         }) && value->phase == "staged";
}

bool read_regular_at(int parent, const std::string& name, size_t limit, nlink_t min_links, nlink_t max_links,
                     std::string* content, struct stat* status_out = nullptr) {
  struct stat named {};
  errno = 0;
  if (fstatat(parent, name.c_str(), &named, AT_SYMLINK_NOFOLLOW) != 0 ||
      !S_ISREG(named.st_mode) || named.st_nlink < min_links || named.st_nlink > max_links ||
      named.st_size < 0 || static_cast<uint64_t>(named.st_size) > limit) {
    if (errno == 0) errno = ELOOP;
    return false;
  }
  Fd file(openat(parent, name.c_str(), O_RDONLY | O_CLOEXEC | O_NOFOLLOW));
  if (!file.valid()) return false;
  struct stat opened {};
  if (fstat(file.get(), &opened) != 0 || !same_inode(named, opened)) {
    errno = ELOOP;
    return false;
  }
  content->resize(static_cast<size_t>(opened.st_size));
  size_t offset = 0;
  while (offset < content->size()) {
    const ssize_t count = read(file.get(), content->data() + offset, content->size() - offset);
    if (count <= 0) return false;
    offset += static_cast<size_t>(count);
  }
  if (status_out != nullptr) *status_out = opened;
  return true;
}


bool descriptor_matches(const PublicationState& value, const std::string& operation_id,
                        const std::string& artwork_id, const std::string& attachment_id,
                        const std::string& canonical) {
  return value.operation_id == operation_id && value.artwork_id == artwork_id &&
         value.attachment_id == attachment_id && value.canonical_name == canonical;
}

Result read_publication_descriptor(int parent, const std::string& name, PublicationState* value,
                                   struct stat* status = nullptr) {
  std::string content;
  if (!read_regular_at(parent, name, 1024, 1, 2, &content, status)) {
    return errno == ENOENT ? result("publicationAbsent")
                           : result("unsafeNode", "The publication descriptor is unsafe.");
  }
  if (!parse_publication(content, value)) {
    return result("unsafeNode", "The publication descriptor is invalid.");
  }
  return result("publicationPending");
}


// Exclusive-rename publication protocol. The v1 wire contract is unchanged;
// these types are internal geometry classifiers shared by every publication
// operation and by scan.
enum class PublicationGeometry {
  kNone,
  kDataOnly,
  kDataTemp,
  kTempOnly,
  kIntentOnly,
  kDataIntent,
  kClaimOnly,
  kClaimData,
  kClaimPayload,
  kLegacyDataTempIntent,
  kLegacyDataIntentClaim,
  kLegacyClaimDataPayload,
  kPayloadOnly,
  kPostCommit,
  kConflict,
  kUnsafe,
};

struct PublicationNode {
  bool exists = false;
  bool is_descriptor = false;
  struct stat status {};
  PublicationState descriptor;
  std::string content;
  uint64_t size = 0;
  std::string digest;
};

struct PublicationSnapshot {
  PublicationGeometry geometry = PublicationGeometry::kNone;
  PublicationState requested;
  PublicationState descriptor;
  bool has_descriptor = false;
  PublicationNode data;
  PublicationNode temporary;
  PublicationNode intent;
  PublicationNode claim;
  PublicationNode payload;
  int platform = -1;
  Fd root;
  Fd staging;
  TargetDirs target;
  bool target_exists = false;
  Result failure = result("available");
};

bool same_descriptor(const PublicationState& left, const PublicationState& right) {
  return left.operation_id == right.operation_id && left.artwork_id == right.artwork_id &&
         left.attachment_id == right.attachment_id && left.canonical_name == right.canonical_name &&
         left.phase == right.phase && left.sha256 == right.sha256 && left.size == right.size;
}

Result inspect_publication_node(int parent, const std::string& name, bool descriptor,
                                const PublicationState& requested, PublicationNode* node) {
  if (parent < 0) return result("available");
  node->is_descriptor = descriptor;
  struct stat named {};
  if (fstatat(parent, name.c_str(), &named, AT_SYMLINK_NOFOLLOW) != 0) {
    return errno == ENOENT ? result("available")
                           : unsafe_or_io("Could not inspect publication state.");
  }
  node->exists = true;
  if (!S_ISREG(named.st_mode) || named.st_nlink < 1 || named.st_nlink > 2) {
    return result("unsafeNode", "Publication state contains an unsafe node or link count.");
  }
  Fd file(openat(parent, name.c_str(), O_RDONLY | O_CLOEXEC | O_NOFOLLOW));
  struct stat opened {};
  if (!file.valid() || fstat(file.get(), &opened) != 0 || !same_inode(named, opened)) {
    return result("unsafeNode", "Publication state changed during inspection.");
  }
  node->status = opened;
  if (descriptor) {
    if (opened.st_size < 0 || opened.st_size > 1024) {
      return result("unsafeNode", "Publication descriptor size is unsafe.");
    }
    node->content.resize(static_cast<size_t>(opened.st_size));
    size_t offset = 0;
    while (offset < node->content.size()) {
      const ssize_t count = read(file.get(), node->content.data() + offset,
                                 node->content.size() - offset);
      if (count <= 0) return result("ioFailure", "Could not read publication descriptor.");
      offset += static_cast<size_t>(count);
    }
    if (!parse_publication(node->content, &node->descriptor)) {
      return result("unsafeNode", "Publication descriptor is malformed.");
    }
    if (!descriptor_matches(node->descriptor, requested.operation_id, requested.artwork_id,
                            requested.attachment_id, requested.canonical_name)) {
      return result("publicationConflict", "A different operation owns publication state.");
    }
  } else if (!hash_fd(file.get(), &node->size, &node->digest)) {
    return result("ioFailure", "Could not hash publication payload.");
  }
  return result("available");
}

bool publication_root_chain_matches(const PublicationSnapshot& snapshot) {
  return snapshot.platform >= 0 && snapshot.root.valid() &&
         directory_identity_matches(snapshot.platform, kAttachments, snapshot.root.get());
}

bool publication_staging_chain_matches(const PublicationSnapshot& snapshot) {
  return publication_root_chain_matches(snapshot) && snapshot.staging.valid() &&
         directory_identity_matches(snapshot.root.get(), kStaging, snapshot.staging.get());
}

bool publication_target_chain_matches(const PublicationSnapshot& snapshot) {
  return snapshot.target_exists && target_chain_matches(snapshot.target);
}

bool publication_all_chains_match(const PublicationSnapshot& snapshot) {
  return publication_staging_chain_matches(snapshot) && publication_target_chain_matches(snapshot);
}

bool publication_node_matches(int parent, const std::string& name,
                              const PublicationNode& node,
                              bool require_link_count = false) {
  if (!node.exists) return entry_absent(parent, name);
  struct stat named {};
  if (fstatat(parent, name.c_str(), &named, AT_SYMLINK_NOFOLLOW) != 0 ||
      !S_ISREG(named.st_mode) || !same_inode(named, node.status) ||
      (require_link_count && named.st_nlink != node.status.st_nlink)) {
    return false;
  }
  Fd file(openat(parent, name.c_str(), O_RDONLY | O_CLOEXEC | O_NOFOLLOW));
  struct stat opened {};
  if (!file.valid() || fstat(file.get(), &opened) != 0 ||
      !same_inode(named, opened) || !same_inode(opened, node.status)) {
    return false;
  }
  if (node.is_descriptor) {
    if (opened.st_size < 0 ||
        static_cast<uint64_t>(opened.st_size) != node.content.size()) {
      return false;
    }
    std::string content(node.content.size(), '\0');
    size_t offset = 0;
    while (offset < content.size()) {
      const ssize_t count = read(file.get(), content.data() + offset,
                                 content.size() - offset);
      if (count <= 0) return false;
      offset += static_cast<size_t>(count);
    }
    return content == node.content;
  }
  uint64_t size = 0;
  std::string digest;
  return hash_fd(file.get(), &size, &digest) && size == node.size &&
         digest == node.digest;
}

bool publication_snapshot_entries_match(
    const PublicationSnapshot& snapshot,
    const PublicationNode* excluded_first = nullptr,
    const PublicationNode* excluded_second = nullptr) {
  const auto matches = [&](int parent, const std::string& name,
                           const PublicationNode& node) {
    if (&node == excluded_first || &node == excluded_second) return true;
    return publication_node_matches(parent, name, node);
  };
  return (!snapshot.staging.valid() ||
          (matches(snapshot.staging.get(), publication_data_name(snapshot.requested.operation_id), snapshot.data) &&
           matches(snapshot.staging.get(), publication_temp_name(snapshot.requested.operation_id), snapshot.temporary) &&
           matches(snapshot.staging.get(), publication_intent_name(snapshot.requested.operation_id), snapshot.intent))) &&
         (!snapshot.target_exists ||
          (matches(snapshot.target.attachment.get(), kPublicationClaim, snapshot.claim) &&
           matches(snapshot.target.attachment.get(), snapshot.requested.canonical_name, snapshot.payload)));
}

Result reestablish_publication_durability(PublicationSnapshot& snapshot) {
  if (snapshot.staging.valid() &&
      !sync_fd(snapshot.staging.get(), "recover.inferredStagingFsync")) {
    return result("ioFailure", "Staging durability could not be re-established.");
  }
  if (snapshot.target_exists &&
      !sync_fd(snapshot.target.attachment.get(), "recover.inferredTargetFsync")) {
    return result("ioFailure", "Target durability could not be re-established.");
  }
  if (!publication_root_chain_matches(snapshot) ||
      (snapshot.staging.valid() && !publication_staging_chain_matches(snapshot)) ||
      (snapshot.target_exists && !publication_target_chain_matches(snapshot)) ||
      !publication_snapshot_entries_match(snapshot)) {
    return result("unsafeNode", "Publication changed during inferred durability recovery.");
  }
  return result("available");
}

void classify_publication_snapshot(PublicationSnapshot* snapshot) {
  const auto& d = snapshot->data;
  const auto& t = snapshot->temporary;
  const auto& i = snapshot->intent;
  const auto& c = snapshot->claim;
  const auto& p = snapshot->payload;
  const int present = static_cast<int>(d.exists) + static_cast<int>(t.exists) +
                      static_cast<int>(i.exists) + static_cast<int>(c.exists) +
                      static_cast<int>(p.exists);
  if (present == 0) {
    snapshot->geometry = PublicationGeometry::kNone;
    return;
  }

  for (const PublicationNode* node : {&t, &i, &c}) {
    if (!node->exists) continue;
    if (!snapshot->has_descriptor) {
      snapshot->descriptor = node->descriptor;
      snapshot->has_descriptor = true;
    } else if (!same_descriptor(snapshot->descriptor, node->descriptor)) {
      snapshot->geometry = PublicationGeometry::kConflict;
      return;
    }
  }
  if (snapshot->has_descriptor) {
    for (const PublicationNode* node : {&d, &p}) {
      if (node->exists &&
          (node->size != snapshot->descriptor.size || node->digest != snapshot->descriptor.sha256)) {
        snapshot->geometry = PublicationGeometry::kUnsafe;
        return;
      }
    }
  }

  const auto one = [](const PublicationNode& node) { return node.exists && node.status.st_nlink == 1; };
  const auto alias = [](const PublicationNode& left, const PublicationNode& right) {
    return left.exists && right.exists && left.status.st_nlink == 2 &&
           right.status.st_nlink == 2 && same_inode(left.status, right.status);
  };

  if (d.exists && !t.exists && !i.exists && !c.exists && !p.exists && one(d)) {
    snapshot->geometry = PublicationGeometry::kDataOnly;
  } else if (d.exists && t.exists && !i.exists && !c.exists && !p.exists && one(d) && one(t)) {
    snapshot->geometry = PublicationGeometry::kDataTemp;
  } else if (!d.exists && t.exists && !i.exists && !c.exists && !p.exists && one(t)) {
    snapshot->geometry = PublicationGeometry::kTempOnly;
  } else if (!d.exists && !t.exists && i.exists && !c.exists && !p.exists && one(i)) {
    snapshot->geometry = PublicationGeometry::kIntentOnly;
  } else if (d.exists && !t.exists && i.exists && !c.exists && !p.exists && one(d) && one(i)) {
    snapshot->geometry = PublicationGeometry::kDataIntent;
  } else if (!d.exists && !t.exists && !i.exists && c.exists && !p.exists && one(c)) {
    snapshot->geometry = PublicationGeometry::kClaimOnly;
  } else if (d.exists && !t.exists && !i.exists && c.exists && !p.exists && one(d) && one(c)) {
    snapshot->geometry = PublicationGeometry::kClaimData;
  } else if (!d.exists && !t.exists && !i.exists && c.exists && p.exists && one(c) && one(p)) {
    snapshot->geometry = PublicationGeometry::kClaimPayload;
  } else if (d.exists && t.exists && i.exists && !c.exists && !p.exists && one(d) && alias(t, i)) {
    snapshot->geometry = PublicationGeometry::kLegacyDataTempIntent;
  } else if (d.exists && !t.exists && i.exists && c.exists && !p.exists && one(d) && alias(i, c)) {
    snapshot->geometry = PublicationGeometry::kLegacyDataIntentClaim;
  } else if (d.exists && !t.exists && !i.exists && c.exists && p.exists && one(c) && alias(d, p)) {
    snapshot->geometry = PublicationGeometry::kLegacyClaimDataPayload;
  } else if (!d.exists && !t.exists && !i.exists && !c.exists && p.exists && one(p)) {
    snapshot->geometry = PublicationGeometry::kPayloadOnly;
  } else if (!c.exists && p.exists && (i.exists || t.exists || d.exists) &&
             (!d.exists ? one(p) : alias(d, p)) &&
             ((!t.exists && i.exists && one(i)) ||
              (t.exists && i.exists && alias(t, i))) &&
             snapshot->has_descriptor) {
    snapshot->geometry = PublicationGeometry::kPostCommit;
  } else {
    snapshot->geometry = PublicationGeometry::kUnsafe;
  }
}

Result build_publication_snapshot(int platform_root,
                                  const PublicationState& requested,
                                  PublicationSnapshot* snapshot) {
  snapshot->requested = requested;
  snapshot->platform = platform_root;
  if (snapshot->platform < 0) return result("unsafeNode", "The app-private root is unsafe or unavailable.");
  snapshot->root = open_dir_at(snapshot->platform, kAttachments, false);
  if (!snapshot->root.valid()) {
    if (errno == ENOENT) {
      snapshot->geometry = PublicationGeometry::kNone;
      return result("available");
    }
    return unsafe_or_io("The app-private attachment root is unsafe.");
  }
  snapshot->staging = open_dir_at(snapshot->root.get(), kStaging, false);
  if (!snapshot->staging.valid() && errno != ENOENT) {
    return unsafe_or_io("The publication staging directory is unsafe.");
  }
  TargetDirs target;
  Result target_opened = open_target(platform_root, requested.artwork_id,
                                     requested.attachment_id, false, &target);
  if (target_opened.outcome == "available") {
    snapshot->target = std::move(target);
    snapshot->target_exists = true;
    std::vector<std::string> names;
    if (!list_names(snapshot->target.attachment.get(), &names)) {
      return result("ioFailure", "Could not inspect attachment geometry.");
    }
    for (const std::string& name : names) {
      if (name == kPublicationClaim || name == requested.canonical_name) continue;
      return canonical_name(name)
          ? result("publicationConflict", "Another canonical payload owns the attachment.")
          : result("unsafeNode", "Attachment geometry contains an unexpected node.");
    }
  } else if (errno != ENOENT) {
    return target_opened;
  }

  Result inspected = inspect_publication_node(
      snapshot->staging.valid() ? snapshot->staging.get() : -1,
      publication_data_name(requested.operation_id), false, requested, &snapshot->data);
  if (inspected.outcome != "available") return inspected;
  inspected = inspect_publication_node(
      snapshot->staging.valid() ? snapshot->staging.get() : -1,
      publication_temp_name(requested.operation_id), true, requested, &snapshot->temporary);
  if (inspected.outcome != "available") return inspected;
  inspected = inspect_publication_node(
      snapshot->staging.valid() ? snapshot->staging.get() : -1,
      publication_intent_name(requested.operation_id), true, requested, &snapshot->intent);
  if (inspected.outcome != "available") return inspected;
  inspected = inspect_publication_node(
      snapshot->target_exists ? snapshot->target.attachment.get() : -1,
      kPublicationClaim, true, requested, &snapshot->claim);
  if (inspected.outcome != "available") return inspected;
  inspected = inspect_publication_node(
      snapshot->target_exists ? snapshot->target.attachment.get() : -1,
      requested.canonical_name, false, requested, &snapshot->payload);
  if (inspected.outcome != "available") return inspected;
  classify_publication_snapshot(snapshot);
  return snapshot->geometry == PublicationGeometry::kConflict
      ? result("publicationConflict", "Publication descriptor identities conflict.")
      : snapshot->geometry == PublicationGeometry::kUnsafe
          ? result("unsafeNode", "Publication geometry is not an allowed v1 state.")
          : result("available");
}

Result exclusive_publication_status(int platform_root,
                                    const std::string& operation_id,
                                    const std::string& artwork_id,
                                    const std::string& attachment_id,
                                    const std::string& canonical) {
  if (!target_valid(operation_id, artwork_id, attachment_id, canonical)) return result("invalidRequest");
  PublicationSnapshot snapshot;
  Result built = build_publication_snapshot(
      platform_root, {operation_id, artwork_id, attachment_id, canonical, "staged", "", 0},
      &snapshot);
  if (built.outcome != "available") return built;
  Result output;
  switch (snapshot.geometry) {
    case PublicationGeometry::kNone: output = result("publicationAbsent"); break;
    case PublicationGeometry::kDataOnly:
    case PublicationGeometry::kTempOnly:
    case PublicationGeometry::kIntentOnly:
    case PublicationGeometry::kClaimOnly: output = result("publicationPartial"); break;
    case PublicationGeometry::kPayloadOnly: output = result("published"); break;
    default: output = result("publicationPending"); break;
  }
  if (snapshot.has_descriptor) output.publications.push_back(snapshot.descriptor);
  return output;
}

Result remove_snapshot_node(PublicationSnapshot& snapshot, int parent,
                            const std::string& name, const PublicationNode& node,
                            bool needs_target, const char* point, const char* fsync_point) {
  const auto anchors = [&]() {
    if (!publication_staging_chain_matches(snapshot)) return false;
    if (needs_target && !publication_target_chain_matches(snapshot)) return false;
    return publication_snapshot_entries_match(snapshot, &node);
  };
  const EntryValidator validator = [&](int candidate_parent,
                                       const std::string& candidate_name,
                                       const struct stat&) {
    return publication_node_matches(candidate_parent, candidate_name, node, true);
  };
  return checked_unlink(parent, name, node.status, anchors, point, fsync_point,
                        "unsafeNode", validator);
}

Result exclusive_recover_publication(int platform_root,
                                     const PublicationState& requested,
                                     bool fresh_publish) {
  bool changed = false;
  for (int step = 0; step < 16; ++step) {
    PublicationSnapshot snapshot;
    Result built = build_publication_snapshot(platform_root, requested, &snapshot);
    if (built.outcome != "available") return built;
    if (snapshot.geometry != PublicationGeometry::kNone) {
      built = reestablish_publication_durability(snapshot);
      if (built.outcome != "available") return built;
    }
    Result mutation;
    switch (snapshot.geometry) {
      case PublicationGeometry::kNone:
        return result("publicationAbsent");
      case PublicationGeometry::kDataOnly:
      case PublicationGeometry::kTempOnly:
      case PublicationGeometry::kIntentOnly:
      case PublicationGeometry::kClaimOnly:
        return result("publicationPartial", "Publication state is incomplete and cannot commit.");
      case PublicationGeometry::kDataTemp: {
        const auto anchors = [&]() {
          return publication_staging_chain_matches(snapshot) &&
                 publication_snapshot_entries_match(snapshot, &snapshot.temporary,
                                                    &snapshot.intent);
        };
        const EntryValidator validator = [&](int parent, const std::string& name,
                                             const struct stat&) {
          return publication_node_matches(parent, name, snapshot.temporary, true);
        };
        mutation = checked_exclusive_rename(
            snapshot.staging.get(), publication_temp_name(requested.operation_id),
            snapshot.temporary.status, snapshot.staging.get(),
            publication_intent_name(requested.operation_id), anchors,
            "publish.intentRename", "publish.intentDirectoryFsync",
            "publish.intentDirectoryFsync", "unsafeNode", validator);
        if (mutation.outcome == "publicationConflict") continue;
        if (mutation.outcome != "available") return mutation;
        changed = true;
        if (crash_at("publish.afterIntentLink")) return result("ioFailure", "Injected publication crash.");
        break;
      }
      case PublicationGeometry::kLegacyDataTempIntent:
        mutation = remove_snapshot_node(snapshot, snapshot.staging.get(),
                                        publication_temp_name(requested.operation_id),
                                        snapshot.temporary, false,
                                        "recover.legacyTempUnlink", "recover.legacyTempFsync");
        if (mutation.outcome != "available") return mutation;
        changed = true;
        break;
      case PublicationGeometry::kDataIntent: {
        if (!snapshot.target_exists) {
          TargetDirs created;
          Result opened = open_target(platform_root, requested.artwork_id,
                                      requested.attachment_id, true, &created);
          if (opened.outcome != "available" || !target_chain_matches(created)) return opened;
          changed = true;
          break;
        }
        const auto anchors = [&]() {
          return publication_all_chains_match(snapshot) &&
                 publication_snapshot_entries_match(snapshot, &snapshot.intent,
                                                    &snapshot.claim);
        };
        const EntryValidator validator = [&](int parent, const std::string& name,
                                             const struct stat&) {
          return publication_node_matches(parent, name, snapshot.intent, true);
        };
        mutation = checked_exclusive_rename(
            snapshot.staging.get(), publication_intent_name(requested.operation_id),
            snapshot.intent.status, snapshot.target.attachment.get(), kPublicationClaim,
            anchors, "publish.claimRename", "publish.claimSourceFsync",
            "publish.claimDirectoryFsync", "unsafeNode", validator);
        if (mutation.outcome == "publicationConflict") continue;
        if (mutation.outcome != "available") return mutation;
        changed = true;
        if (crash_at("publish.afterClaim")) return result("ioFailure", "Injected publication crash.");
        break;
      }
      case PublicationGeometry::kLegacyDataIntentClaim:
        mutation = remove_snapshot_node(snapshot, snapshot.staging.get(),
                                        publication_intent_name(requested.operation_id),
                                        snapshot.intent, true,
                                        "recover.legacyIntentUnlink", "recover.legacyIntentFsync");
        if (mutation.outcome != "available") return mutation;
        changed = true;
        break;
      case PublicationGeometry::kClaimData: {
        const auto anchors = [&]() {
          return publication_all_chains_match(snapshot) &&
                 publication_snapshot_entries_match(snapshot, &snapshot.data,
                                                    &snapshot.payload);
        };
        const EntryValidator validator = [&](int parent, const std::string& name,
                                             const struct stat&) {
          return publication_node_matches(parent, name, snapshot.data, true);
        };
        mutation = checked_exclusive_rename(
            snapshot.staging.get(), publication_data_name(requested.operation_id),
            snapshot.data.status, snapshot.target.attachment.get(),
            requested.canonical_name, anchors, "publish.payloadRename",
            "publish.payloadSourceFsync", "publish.payloadDirectoryFsync",
            "unsafeNode", validator);
        if (mutation.outcome == "publicationConflict") continue;
        if (mutation.outcome != "available") return mutation;
        changed = true;
        if (crash_at("publish.afterPayloadLink")) return result("ioFailure", "Injected publication crash.");
        break;
      }
      case PublicationGeometry::kLegacyClaimDataPayload:
        mutation = remove_snapshot_node(snapshot, snapshot.staging.get(),
                                        publication_data_name(requested.operation_id),
                                        snapshot.data, true,
                                        "recover.legacyDataUnlink", "recover.legacyDataFsync");
        if (mutation.outcome != "available") return mutation;
        changed = true;
        break;
      case PublicationGeometry::kClaimPayload: {
        Fd payload(openat(snapshot.target.attachment.get(), requested.canonical_name.c_str(),
                          O_RDONLY | O_CLOEXEC | O_NOFOLLOW));
        struct stat payload_status {};
        uint64_t size = 0;
        std::string digest;
        if (!payload.valid() || fstat(payload.get(), &payload_status) != 0 ||
            !same_inode(payload_status, snapshot.payload.status) ||
            !hash_fd(payload.get(), &size, &digest) ||
            size != snapshot.descriptor.size || digest != snapshot.descriptor.sha256) {
          return result("unsafeNode", "Call-local payload identity could not be proven for commit.");
        }
        const auto anchors = [&]() {
          return publication_all_chains_match(snapshot) &&
                 publication_snapshot_entries_match(snapshot, &snapshot.claim) &&
                 publication_node_matches(snapshot.target.attachment.get(),
                                          requested.canonical_name,
                                          snapshot.payload, true);
        };
        const EntryValidator validator = [&](int parent, const std::string& name,
                                             const struct stat&) {
          return publication_node_matches(parent, name, snapshot.claim, true);
        };
        mutation = checked_unlink(snapshot.target.attachment.get(), kPublicationClaim,
                                  snapshot.claim.status, anchors, "publish.claimUnlink",
                                  "publish.commitDirectoryFsync", "unsafeNode",
                                  validator);
        if (mutation.outcome != "available") return mutation;
        changed = true;
        if (crash_at("publish.afterCommit") || crash_at("publish.afterDataCleanup")) {
          return result("ioFailure", "Injected publication crash.");
        }
        break;
      }
      case PublicationGeometry::kPostCommit: {
        if (snapshot.data.exists) {
          mutation = remove_snapshot_node(snapshot, snapshot.staging.get(),
                                          publication_data_name(requested.operation_id),
                                          snapshot.data, true,
                                          "recover.postCommitDataUnlink", "recover.postCommitDataFsync");
        } else if (snapshot.temporary.exists) {
          mutation = remove_snapshot_node(snapshot, snapshot.staging.get(),
                                          publication_temp_name(requested.operation_id),
                                          snapshot.temporary, true,
                                          "recover.postCommitTempUnlink", "recover.postCommitTempFsync");
        } else {
          mutation = remove_snapshot_node(snapshot, snapshot.staging.get(),
                                          publication_intent_name(requested.operation_id),
                                          snapshot.intent, true,
                                          "recover.postCommitIntentUnlink", "recover.postCommitIntentFsync");
        }
        if (mutation.outcome != "available") return mutation;
        changed = true;
        break;
      }
      case PublicationGeometry::kPayloadOnly: {
        if (!publication_target_chain_matches(snapshot) ||
            !sync_fd(snapshot.target.attachment.get(), "recover.committedDirectoryFsync") ||
            !publication_target_chain_matches(snapshot) ||
            !publication_node_matches(snapshot.target.attachment.get(),
                                      requested.canonical_name,
                                      snapshot.payload, true)) {
          return result("ioFailure", "Committed publication durability could not be re-established.");
        }
        Result output = result(changed ? (fresh_publish ? "published" : "publicationRecovered")
                                       : "alreadyExists");
        if (snapshot.has_descriptor) output.publications.push_back(snapshot.descriptor);
        return output;
      }
      case PublicationGeometry::kConflict:
        return result("publicationConflict");
      case PublicationGeometry::kUnsafe:
        return result("unsafeNode");
    }
  }
  return result("ioFailure", "Publication recovery did not converge within its bounded state table.");
}

Result create_staged_payload(int staging, const std::string& name, int source,
                             const std::function<bool()>& anchors,
                             PublicationState* descriptor) {
  if (!anchors() || !entry_absent(staging, name)) {
    return result("publicationPending", "Publication staging already exists.");
  }
  Fd staged(openat(staging, name.c_str(), O_RDWR | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0600));
  if (!staged.valid()) {
    return errno == EEXIST ? result("publicationPending")
                           : unsafe_or_io("Could not create staged publication payload.");
  }
  if (!copy_and_hash(source, staged.get(), &descriptor->size, &descriptor->sha256) ||
      !sync_fd(staged.get(), "publish.dataFileFsync")) {
    return result("ioFailure", "Could not durably write staged publication payload.");
  }
  struct stat expected {};
  uint64_t size = 0;
  std::string digest;
  if (fstat(staged.get(), &expected) != 0 || expected.st_nlink != 1 ||
      !hash_fd(staged.get(), &size, &digest) || size != descriptor->size ||
      digest != descriptor->sha256 || !sync_fd(staging, "publish.dataDirectoryFsync")) {
    return result("ioFailure", "Staged payload final validation or durability failed.");
  }
  PublicationNode expected_node;
  expected_node.exists = true;
  expected_node.status = expected;
  expected_node.size = descriptor->size;
  expected_node.digest = descriptor->sha256;
  if (!anchors() || !publication_node_matches(staging, name, expected_node, true)) {
    return result("ioFailure", "Staged payload final validation or durability failed.");
  }
  if (crash_at("publish.afterDataFsync")) return result("ioFailure", "Injected publication crash.");
  return result("available");
}

Result create_staged_descriptor(int staging, const std::string& name,
                                const PublicationState& descriptor,
                                const std::function<bool()>& anchors) {
  if (!anchors() || !entry_absent(staging, name)) return result("publicationPending");
  Fd file(openat(staging, name.c_str(), O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0600));
  if (!file.valid()) return errno == EEXIST ? result("publicationPending")
                                            : unsafe_or_io("Could not create publication descriptor.");
  const std::string content = publication_json(descriptor);
  if (!write_all(file.get(), content) || !sync_fd(file.get(), "publish.intentFileFsync")) {
    return result("ioFailure", "Could not durably write publication descriptor.");
  }
  struct stat expected {};
  if (fstat(file.get(), &expected) != 0 || expected.st_nlink != 1 ||
      !sync_fd(staging, "publish.intentCreateDirectoryFsync") || !anchors() ||
      !entry_identity_matches(staging, name, expected)) {
    return result("ioFailure", "Publication descriptor final validation or durability failed.");
  }
  PublicationState verified;
  struct stat verified_status {};
  Result read = read_publication_descriptor(staging, name, &verified, &verified_status);
  if (read.outcome != "publicationPending" || !same_descriptor(descriptor, verified) ||
      !same_inode(expected, verified_status)) {
    return result("unsafeNode", "Publication descriptor changed after durable creation.");
  }
  if (crash_at("publish.afterIntentFileFsync")) return result("ioFailure", "Injected publication crash.");
  return result("available");
}

Result exclusive_publish(int platform_root, const std::string& source_path,
                         const std::string& operation_id, const std::string& artwork_id,
                         const std::string& attachment_id, const std::string& canonical) {
  if (!target_valid(operation_id, artwork_id, attachment_id, canonical) || source_path.empty()) {
    return result("invalidRequest", "Invalid custody publication request.");
  }
  Fd source(open(source_path.c_str(), O_RDONLY | O_CLOEXEC | O_NOFOLLOW));
  struct stat source_status {};
  if (!source.valid()) return result(errno == ENOENT ? "sourceMissing" : "unsafeNode");
  if (fstat(source.get(), &source_status) != 0 || !S_ISREG(source_status.st_mode) ||
      source_status.st_nlink != 1) {
    return result("unsafeNode", "The import source is not a safe single-link regular file.");
  }

  TargetDirs target;
  Result opened = open_target(platform_root, artwork_id, attachment_id, true, &target);
  if (opened.outcome != "available" || !target_chain_matches(target)) return opened;
  Fd staging = open_dir_at(target.root.get(), kStaging, true, "staging.parentFsync");
  if (!staging.valid() || !staging_chain_matches(target, staging.get())) {
    return result("unsafeNode", "Publication staging ancestry is unsafe.");
  }
  PublicationState requested{operation_id, artwork_id, attachment_id, canonical, "staged", "", 0};
  PublicationSnapshot initial;
  Result built = build_publication_snapshot(platform_root, requested, &initial);
  if (built.outcome != "available") return built;
  if (initial.geometry == PublicationGeometry::kPayloadOnly) return result("alreadyExists");
  if (initial.geometry != PublicationGeometry::kNone) return result("publicationPending");
  const auto anchors = [&]() { return staging_chain_matches(target, staging.get()); };
  Result staged = create_staged_payload(staging.get(), publication_data_name(operation_id),
                                        source.get(), anchors, &requested);
  if (staged.outcome != "available") return staged;
  staged = create_staged_descriptor(staging.get(), publication_temp_name(operation_id),
                                    requested, anchors);
  if (staged.outcome != "available") return staged;
  return exclusive_recover_publication(platform_root, requested, true);
}

Result exclusive_recover(int platform_root, const std::string& operation_id,
                         const std::string& artwork_id, const std::string& attachment_id,
                         const std::string& canonical) {
  if (!target_valid(operation_id, artwork_id, attachment_id, canonical)) return result("invalidRequest");
  return exclusive_recover_publication(
      platform_root, {operation_id, artwork_id, attachment_id, canonical, "staged", "", 0}, false);
}

Result exclusive_cleanup_empty_ancestry(int platform_root,
                                        const std::string& artwork_id,
                                        const std::string& attachment_id);

Result exclusive_rollback(int platform_root, const std::string& operation_id,
                          const std::string& artwork_id, const std::string& attachment_id,
                          const std::string& canonical, bool cleanup_only) {
  if (!target_valid(operation_id, artwork_id, attachment_id, canonical)) return result("invalidRequest");
  const PublicationState requested{operation_id, artwork_id, attachment_id, canonical, "staged", "", 0};
  for (int step = 0; step < 16; ++step) {
    PublicationSnapshot snapshot;
    Result built = build_publication_snapshot(platform_root, requested, &snapshot);
    if (built.outcome != "available") return built;
    if (snapshot.geometry != PublicationGeometry::kNone) {
      built = reestablish_publication_durability(snapshot);
      if (built.outcome != "available") return built;
    }
    Result mutation;
    switch (snapshot.geometry) {
      case PublicationGeometry::kNone: {
        if (snapshot.staging.valid()) {
          Result staging_cleanup = checked_rmdir(
              snapshot.root.get(), kStaging, snapshot.staging.get(),
              [&]() { return publication_root_chain_matches(snapshot); },
              "cleanup.stagingRmdir", "cleanup.rootFsync");
          if (staging_cleanup.outcome != "available") return staging_cleanup;
        }
        Result ancestry = exclusive_cleanup_empty_ancestry(platform_root, artwork_id, attachment_id);
        if (ancestry.outcome != "cleanupComplete") return ancestry;
        return result(cleanup_only ? "cleanupComplete" : "publicationRolledBack");
      }
      case PublicationGeometry::kClaimPayload:
        // The descriptor has no persisted payload inode identity. Rollback and
        // cleanup are therefore deliberately non-mutating and non-success.
        return result("publicationPending", "Commit-only publication state requires recovery.");
      case PublicationGeometry::kPayloadOnly:
        return result(cleanup_only ? "cleanupComplete" : "publicationRolledBack");
      case PublicationGeometry::kPostCommit:
        if (!cleanup_only) return result("alreadyExists", "Committed payload is preserved.");
        if (snapshot.data.exists) {
          mutation = remove_snapshot_node(snapshot, snapshot.staging.get(),
                                          publication_data_name(operation_id), snapshot.data,
                                          true, "cleanup.postCommitDataUnlink",
                                          "cleanup.postCommitDataFsync");
        } else if (snapshot.temporary.exists) {
          mutation = remove_snapshot_node(snapshot, snapshot.staging.get(),
                                          publication_temp_name(operation_id), snapshot.temporary,
                                          true, "cleanup.postCommitTempUnlink",
                                          "cleanup.postCommitTempFsync");
        } else {
          mutation = remove_snapshot_node(snapshot, snapshot.staging.get(),
                                          publication_intent_name(operation_id), snapshot.intent,
                                          true, "cleanup.postCommitIntentUnlink",
                                          "cleanup.postCommitIntentFsync");
        }
        break;
      case PublicationGeometry::kLegacyClaimDataPayload:
        // P is removable only while the exact call-local D alias and C
        // descriptor still prove ownership. Removing P leaves the safer C+D row.
        mutation = remove_snapshot_node(snapshot, snapshot.target.attachment.get(),
                                        canonical, snapshot.payload, true,
                                        "rollback.legacyPayloadUnlink",
                                        "rollback.legacyPayloadFsync");
        break;
      case PublicationGeometry::kLegacyDataTempIntent:
      case PublicationGeometry::kDataTemp:
      case PublicationGeometry::kTempOnly:
        mutation = remove_snapshot_node(snapshot, snapshot.staging.get(),
                                        publication_temp_name(operation_id), snapshot.temporary,
                                        false, "rollback.tempUnlink", "rollback.tempFsync");
        break;
      case PublicationGeometry::kLegacyDataIntentClaim:
      case PublicationGeometry::kDataIntent:
      case PublicationGeometry::kIntentOnly:
        mutation = remove_snapshot_node(snapshot, snapshot.staging.get(),
                                        publication_intent_name(operation_id), snapshot.intent,
                                        snapshot.claim.exists, "rollback.intentUnlink",
                                        "rollback.intentFsync");
        break;
      case PublicationGeometry::kClaimData:
      case PublicationGeometry::kDataOnly:
        mutation = remove_snapshot_node(snapshot, snapshot.staging.get(),
                                        publication_data_name(operation_id), snapshot.data,
                                        snapshot.claim.exists, "rollback.dataUnlink",
                                        "rollback.dataFsync");
        break;
      case PublicationGeometry::kClaimOnly:
        {
        const EntryValidator validator = [&](int parent, const std::string& name,
                                             const struct stat&) {
          return publication_node_matches(parent, name, snapshot.claim, true);
        };
        mutation = checked_unlink(
            snapshot.target.attachment.get(), kPublicationClaim, snapshot.claim.status,
            [&]() {
              return publication_target_chain_matches(snapshot) &&
                     publication_snapshot_entries_match(snapshot, &snapshot.claim);
            },
            "rollback.claimUnlink", "rollback.claimFsync", "unsafeNode",
            validator);
        break;
        }
      case PublicationGeometry::kConflict:
        return result("publicationConflict");
      case PublicationGeometry::kUnsafe:
        return result("unsafeNode");
    }
    if (mutation.outcome != "available") return mutation;
  }
  return result("ioFailure", "Publication rollback did not converge within its bounded state table.");
}

Result exclusive_remove_payload(int platform_root,
                                const std::string& artwork_id,
                                const std::string& attachment_id,
                                const std::string& canonical) {
  if (!opaque_id(artwork_id) || !opaque_id(attachment_id) || !canonical_name(canonical)) {
    return result("invalidRequest");
  }
  TargetDirs target;
  Result opened = open_target(platform_root, artwork_id, attachment_id, false, &target);
  if (opened.outcome != "available") return errno == ENOENT ? result("missing") : opened;
  if (!target_chain_matches(target)) return result("unsafeNode", "Attachment ancestry changed.");
  struct stat claim {};
  if (fstatat(target.attachment.get(), kPublicationClaim, &claim, AT_SYMLINK_NOFOLLOW) == 0) {
    return result("publicationPending", "An unfinished publication owns the attachment.");
  }
  if (errno != ENOENT) return unsafe_or_io("Could not inspect publication ownership.");
  PublicationNode payload;
  const PublicationState requested{"remove", artwork_id, attachment_id,
                                   canonical, "staged", "", 0};
  Result inspected = inspect_publication_node(target.attachment.get(), canonical,
                                              false, requested, &payload);
  if (inspected.outcome != "available") return inspected;
  if (!payload.exists) {
    if (errno != ENOENT) return unsafe_or_io("Could not inspect canonical payload.");
    if (!sync_fd(target.attachment.get(), "remove.missingDirectoryFsync") ||
        !target_chain_matches(target) || !entry_absent(target.attachment.get(), canonical) ||
        !entry_absent(target.attachment.get(), kPublicationClaim)) {
      return result("ioFailure", "Payload absence durability could not be re-established.");
    }
    return result("missing");
  }
  if (payload.status.st_nlink != 1) {
    return result("unsafeNode", "Canonical payload is not a safe single-link file.");
  }
  const EntryValidator validator = [&](int parent, const std::string& name,
                                       const struct stat&) {
    return publication_node_matches(parent, name, payload, true);
  };
  Result removed = checked_unlink(
      target.attachment.get(), canonical, payload.status,
      [&]() {
        return target_chain_matches(target) &&
               entry_absent(target.attachment.get(), kPublicationClaim);
      },
      "remove.payloadUnlink", "remove.payloadFsync", "unsafeNode", validator);
  return removed.outcome == "available" ? result("removed") : removed;
}

Result exclusive_cleanup_empty_ancestry(int platform_root,
                                        const std::string& artwork_id,
                                        const std::string& attachment_id) {
  if (platform_root < 0) return result("unsafeNode", "Cleanup root is unsafe.");
  Fd root = open_dir_at(platform_root, kAttachments, false);
  if (!root.valid()) return errno == ENOENT ? result("cleanupComplete") : result("unsafeNode");
  const auto root_chain = [&]() {
    return directory_identity_matches(platform_root, kAttachments, root.get());
  };
  Fd artworks = open_dir_at(root.get(), kArtworks, false);
  if (!artworks.valid()) return errno == ENOENT ? result("cleanupComplete") : result("unsafeNode");
  const auto artworks_chain = [&]() {
    return root_chain() && directory_identity_matches(root.get(), kArtworks, artworks.get());
  };
  Fd artwork = open_dir_at(artworks.get(), artwork_id, false);
  if (!artwork.valid()) {
    if (errno != ENOENT) return result("unsafeNode");
    Result pruned = checked_rmdir(root.get(), kArtworks, artworks.get(), root_chain,
                                  "cleanup.artworksRmdir", "cleanup.rootFsync");
    return pruned.outcome == "available" ? result("cleanupComplete") : pruned;
  }
  const auto artwork_chain = [&]() {
    return artworks_chain() && directory_identity_matches(artworks.get(), artwork_id, artwork.get());
  };
  Fd attachments = open_dir_at(artwork.get(), "attachments", false);
  if (attachments.valid()) {
    const auto attachments_chain = [&]() {
      return artwork_chain() && directory_identity_matches(artwork.get(), "attachments", attachments.get());
    };
    Fd attachment = open_dir_at(attachments.get(), attachment_id, false);
    if (attachment.valid()) {
      Result pruned = checked_rmdir(attachments.get(), attachment_id, attachment.get(),
                                    attachments_chain, "cleanup.attachmentRmdir",
                                    "cleanup.attachmentsFsync");
      if (pruned.outcome != "available") return pruned;
    } else if (errno != ENOENT) {
      return result("unsafeNode");
    }
    Result pruned = checked_rmdir(artwork.get(), "attachments", attachments.get(),
                                  artwork_chain, "cleanup.attachmentsRmdir",
                                  "cleanup.artworkFsync");
    if (pruned.outcome != "available") return pruned;
  } else if (errno != ENOENT) {
    return result("unsafeNode");
  }
  Result pruned = checked_rmdir(artworks.get(), artwork_id, artwork.get(),
                                artworks_chain, "cleanup.artworkRmdir",
                                "cleanup.artworksFsync");
  if (pruned.outcome != "available") return pruned;
  pruned = checked_rmdir(root.get(), kArtworks, artworks.get(), root_chain,
                         "cleanup.artworksRmdir", "cleanup.rootFsync");
  return pruned.outcome == "available" ? result("cleanupComplete") : pruned;
}

std::string erasure_temp_name(const std::string& owner) { return "current-" + owner + ".tmp"; }
std::string erasure_json(const std::string& owner) {
  return "{\"version\":1,\"owner\":\"" + owner + "\",\"phase\":\"" + kErasurePhase + "\"}\n";
}

bool parse_erasure(const std::string& json, std::string* owner, std::string* phase) {
  auto cursor = json.begin();
  const auto end = json.end();
  uint64_t version = 0;
  return take(&cursor, end, "{\"version\":") && take_uint(&cursor, end, &version) && version == 1 &&
         take(&cursor, end, ",\"owner\":") && take_quoted(&cursor, end, owner) && opaque_id(*owner) &&
         take(&cursor, end, ",\"phase\":") && take_quoted(&cursor, end, phase) && *phase == kErasurePhase &&
         take(&cursor, end, "}\n") && cursor == end;
}


enum class ErasureGeometry { kAbsent, kTemp, kCurrent, kLegacyAlias, kConflict, kUnsafe };

struct ErasureNode {
  bool exists = false;
  struct stat status {};
  std::string owner;
  std::string phase;
  std::string content;
};

struct ErasureSnapshot {
  ErasureGeometry geometry = ErasureGeometry::kAbsent;
  int root = -1;
  Fd control;
  ErasureNode temp;
  ErasureNode current;
  std::string temp_name;
  std::string owner;
};

Result inspect_erasure_node(int control, const std::string& name, ErasureNode* node) {
  struct stat named {};
  if (fstatat(control, name.c_str(), &named, AT_SYMLINK_NOFOLLOW) != 0) {
    return errno == ENOENT ? result("available") : result("erasureUnsafe");
  }
  node->exists = true;
  if (!S_ISREG(named.st_mode) || named.st_nlink < 1 || named.st_nlink > 2) {
    return result("erasureUnsafe", "Erasure-control node or link count is unsafe.");
  }
  Fd file(openat(control, name.c_str(), O_RDONLY | O_CLOEXEC | O_NOFOLLOW));
  struct stat opened {};
  if (!file.valid() || fstat(file.get(), &opened) != 0 || !same_inode(named, opened) ||
      opened.st_size < 0 || opened.st_size > 256) {
    return result("erasureUnsafe", "Erasure-control identity changed during inspection.");
  }
  node->content.assign(static_cast<size_t>(opened.st_size), '\0');
  size_t offset = 0;
  while (offset < node->content.size()) {
    const ssize_t count = read(file.get(), node->content.data() + offset,
                               node->content.size() - offset);
    if (count <= 0) return result("ioFailure", "Could not read erasure control.");
    offset += static_cast<size_t>(count);
  }
  if (!parse_erasure(node->content, &node->owner, &node->phase)) {
    return result("erasureUnsafe", "Erasure control is malformed.");
  }
  node->status = opened;
  return result("available");
}

bool erasure_node_matches(int control, const std::string& name,
                          const ErasureNode& node,
                          bool require_link_count = false) {
  if (!node.exists) return entry_absent(control, name);
  std::string content;
  struct stat status {};
  if (!read_regular_at(control, name, 256, 1, 2, &content, &status) ||
      !same_inode(status, node.status) || content != node.content ||
      (require_link_count && status.st_nlink != node.status.st_nlink)) {
    return false;
  }
  return true;
}

bool erasure_control_chain_matches(const ErasureSnapshot& snapshot) {
  return snapshot.root >= 0 && snapshot.control.valid() &&
         directory_identity_matches(snapshot.root, kErasureControl, snapshot.control.get());
}

bool erasure_snapshot_entries_match(const ErasureSnapshot& snapshot,
                                    const ErasureNode* excluded_first = nullptr,
                                    const ErasureNode* excluded_second = nullptr) {
  if (!snapshot.control.valid()) return true;
  if (&snapshot.current != excluded_first && &snapshot.current != excluded_second &&
      !erasure_node_matches(snapshot.control.get(), kErasureCurrent,
                            snapshot.current)) {
    return false;
  }
  if (snapshot.temp.exists && &snapshot.temp != excluded_first &&
      &snapshot.temp != excluded_second &&
      !erasure_node_matches(snapshot.control.get(), snapshot.temp_name,
                            snapshot.temp)) {
    return false;
  }
  return true;
}

Result build_erasure_snapshot(int platform_root,
                              const std::string& expected_owner,
                              bool create_control, ErasureSnapshot* snapshot) {
  snapshot->root = platform_root;
  if (snapshot->root < 0) return result("erasureUnsafe", "The erasure-control parent is unsafe.");
  snapshot->control = open_dir_at(snapshot->root, kErasureControl, create_control,
                                  "erasure.parentFsync");
  if (!snapshot->control.valid()) {
    if (errno == ENOENT) return result("available");
    return result("erasureUnsafe", "The erasure-control directory is unsafe.");
  }
  if (!erasure_control_chain_matches(*snapshot)) {
    return result("erasureUnsafe", "Erasure-control directory identity changed.");
  }
  std::vector<std::string> names;
  if (!list_names(snapshot->control.get(), &names)) return result("ioFailure");
  std::string discovered_temp;
  for (const std::string& name : names) {
    if (name == kErasureCurrent) continue;
    if (name.rfind("current-", 0) != 0 || name.size() <= 12 ||
        name.substr(name.size() - 4) != ".tmp" || !discovered_temp.empty()) {
      snapshot->geometry = ErasureGeometry::kUnsafe;
      return result("erasureUnsafe", "Erasure-control contains an unexpected node.");
    }
    discovered_temp = name;
  }
  Result inspected = inspect_erasure_node(snapshot->control.get(), kErasureCurrent,
                                          &snapshot->current);
  if (inspected.outcome != "available") return inspected;
  if (!discovered_temp.empty()) {
    inspected = inspect_erasure_node(snapshot->control.get(), discovered_temp, &snapshot->temp);
    if (inspected.outcome != "available") return inspected;
    if (discovered_temp != erasure_temp_name(snapshot->temp.owner)) {
      return result("erasureUnsafe", "Erasure-control temp name does not match its owner.");
    }
    snapshot->temp_name = discovered_temp;
  }
  if (snapshot->current.exists && snapshot->temp.exists) {
    if (snapshot->current.owner != snapshot->temp.owner) {
      snapshot->geometry = ErasureGeometry::kConflict;
    } else if (snapshot->current.status.st_nlink == 2 && snapshot->temp.status.st_nlink == 2 &&
               same_inode(snapshot->current.status, snapshot->temp.status)) {
      snapshot->geometry = ErasureGeometry::kLegacyAlias;
      snapshot->owner = snapshot->current.owner;
    } else {
      snapshot->geometry = ErasureGeometry::kUnsafe;
      return result("erasureUnsafe", "Erasure-control dual-entry geometry is unsafe.");
    }
  } else if (snapshot->current.exists) {
    if (snapshot->current.status.st_nlink != 1) return result("erasureUnsafe");
    snapshot->geometry = ErasureGeometry::kCurrent;
    snapshot->owner = snapshot->current.owner;
  } else if (snapshot->temp.exists) {
    if (snapshot->temp.status.st_nlink != 1) return result("erasureUnsafe");
    snapshot->geometry = ErasureGeometry::kTemp;
    snapshot->owner = snapshot->temp.owner;
  }
  if (!expected_owner.empty() && !snapshot->owner.empty() && snapshot->owner != expected_owner) {
    snapshot->geometry = ErasureGeometry::kConflict;
  }
  return result("available");
}

Result exclusive_erasure_status(int platform_root,
                                const std::string& expected_owner) {
  if (!expected_owner.empty() && !opaque_id(expected_owner)) return result("invalidRequest");
  ErasureSnapshot snapshot;
  Result built = build_erasure_snapshot(platform_root, expected_owner, false, &snapshot);
  if (built.outcome != "available") return built;
  Result output;
  switch (snapshot.geometry) {
    case ErasureGeometry::kAbsent: output = result("erasureAbsent"); break;
    case ErasureGeometry::kTemp: output = result("erasurePending"); break;
    case ErasureGeometry::kCurrent:
    case ErasureGeometry::kLegacyAlias: output = result("erasureOwned"); break;
    case ErasureGeometry::kConflict: output = result("erasureConflict"); break;
    case ErasureGeometry::kUnsafe: output = result("erasureUnsafe"); break;
  }
  output.owner = snapshot.owner;
  output.phase = snapshot.owner.empty() ? std::string() : kErasurePhase;
  return output;
}

Result create_erasure_temp(ErasureSnapshot& snapshot, const std::string& owner) {
  const std::string name = erasure_temp_name(owner);
  const auto anchors = [&]() { return erasure_control_chain_matches(snapshot); };
  if (!anchors() || !entry_absent(snapshot.control.get(), name)) return result("erasureConflict");
  Fd file(openat(snapshot.control.get(), name.c_str(),
                 O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0600));
  if (!file.valid()) return errno == EEXIST ? result("erasureConflict") : result("ioFailure");
  const std::string content = erasure_json(owner);
  if (!write_all(file.get(), content) || !sync_fd(file.get(), "erasure.tempFileFsync")) {
    return result("ioFailure", "Could not durably write erasure control.");
  }
  struct stat expected {};
  if (fstat(file.get(), &expected) != 0 || expected.st_nlink != 1 ||
      !sync_fd(snapshot.control.get(), "erasure.tempCreateDirectoryFsync")) {
    return result("ioFailure", "Erasure temp final validation or durability failed.");
  }
  ErasureNode expected_node;
  expected_node.exists = true;
  expected_node.status = expected;
  expected_node.owner = owner;
  expected_node.phase = kErasurePhase;
  expected_node.content = content;
  if (!anchors() ||
      !erasure_node_matches(snapshot.control.get(), name, expected_node, true)) {
    return result("ioFailure", "Erasure temp final validation or durability failed.");
  }
  if (crash_at("erasure.afterTempFsync")) return result("ioFailure", "Injected erasure crash.");
  return result("available");
}

Result exclusive_write_or_recover_erasure(int platform_root,
                                          const std::string& owner,
                                          bool allow_create) {
  if (!opaque_id(owner)) return result("invalidRequest");
  for (int step = 0; step < 6; ++step) {
    ErasureSnapshot snapshot;
    Result built = build_erasure_snapshot(platform_root, owner, allow_create, &snapshot);
    if (built.outcome != "available") return built;
    switch (snapshot.geometry) {
      case ErasureGeometry::kAbsent:
        if (!allow_create || !snapshot.control.valid()) return result("erasureAbsent");
        built = create_erasure_temp(snapshot, owner);
        if (built.outcome != "available") return built;
        break;
      case ErasureGeometry::kTemp: {
        const auto anchors = [&]() {
          return erasure_control_chain_matches(snapshot) &&
                 erasure_snapshot_entries_match(snapshot, &snapshot.temp,
                                                &snapshot.current);
        };
        const EntryValidator validator = [&](int parent, const std::string& name,
                                             const struct stat&) {
          return erasure_node_matches(parent, name, snapshot.temp, true);
        };
        built = checked_exclusive_rename(
            snapshot.control.get(), snapshot.temp_name, snapshot.temp.status,
            snapshot.control.get(), kErasureCurrent, anchors,
            "erasure.currentRename", "erasure.currentDirectoryFsync",
            "erasure.currentDirectoryFsync", "erasureUnsafe", validator);
        if (built.outcome == "publicationConflict") continue;
        if (built.outcome != "available") return built;
        if (crash_at("erasure.afterCurrentLink")) return result("ioFailure", "Injected erasure crash.");
        break;
      }
      case ErasureGeometry::kLegacyAlias:
        {
        const EntryValidator validator = [&](int parent, const std::string& name,
                                             const struct stat&) {
          return erasure_node_matches(parent, name, snapshot.temp, true);
        };
        built = checked_unlink(snapshot.control.get(), snapshot.temp_name,
                               snapshot.temp.status,
                               [&]() {
                                 return erasure_control_chain_matches(snapshot) &&
                                        erasure_snapshot_entries_match(snapshot,
                                                                       &snapshot.temp);
                               },
                               "erasure.legacyTempUnlink", "erasure.legacyTempFsync",
                               "erasureUnsafe", validator);
        if (built.outcome != "available") return built;
        break;
        }
      case ErasureGeometry::kCurrent: {
        if (!sync_fd(snapshot.control.get(), "erasure.ownedDirectoryFsync") ||
            !erasure_control_chain_matches(snapshot) ||
            !erasure_snapshot_entries_match(snapshot) ||
            !erasure_node_matches(snapshot.control.get(), kErasureCurrent,
                                  snapshot.current, true)) {
          return result("ioFailure", "Erasure ownership durability could not be re-established.");
        }
        if (crash_at("erasure.afterTempCleanup")) return result("ioFailure", "Injected erasure crash.");
        Result output = result("erasureOwned");
        output.owner = owner;
        output.phase = kErasurePhase;
        return output;
      }
      case ErasureGeometry::kConflict:
        return result("erasureConflict");
      case ErasureGeometry::kUnsafe:
        return result("erasureUnsafe");
    }
  }
  return result("ioFailure", "Erasure recovery did not converge.");
}

Result exclusive_clear_erasure(int platform_root, const std::string& owner,
                               bool cleanup_only) {
  if (!opaque_id(owner)) return result("invalidRequest");
  for (int step = 0; step < 6; ++step) {
    ErasureSnapshot snapshot;
    Result built = build_erasure_snapshot(platform_root, owner, false, &snapshot);
    if (built.outcome != "available") return built;
    if (snapshot.geometry == ErasureGeometry::kConflict) return result("erasureConflict");
    if (snapshot.geometry == ErasureGeometry::kUnsafe) return result("erasureUnsafe");
    if (snapshot.geometry == ErasureGeometry::kAbsent) {
      if (snapshot.control.valid()) {
        if (!sync_fd(snapshot.control.get(), "erasure.absentDirectoryFsync") ||
            !erasure_control_chain_matches(snapshot)) {
          return result("ioFailure", "Erasure absence durability could not be re-established.");
        }
        built = checked_rmdir(snapshot.root, kErasureControl,
                              snapshot.control.get(),
                              [&]() { return snapshot.root >= 0; },
                              "erasure.beforeControlRmdir", "erasure.rootFsync",
                              "erasureUnsafe");
        if (built.outcome != "available") return built;
      } else if (!sync_fd(snapshot.root, "erasure.absentRootFsync") ||
                 !entry_absent(snapshot.root, kErasureControl)) {
        return result("ioFailure", "Erasure-control absence could not be re-established.");
      }
      return result("erasureAbsent");
    }
    if (snapshot.geometry == ErasureGeometry::kCurrent && cleanup_only) {
      if (!sync_fd(snapshot.control.get(), "erasure.cleanupOwnedDirectoryFsync") ||
          !erasure_control_chain_matches(snapshot) ||
          !erasure_snapshot_entries_match(snapshot) ||
          !erasure_node_matches(snapshot.control.get(), kErasureCurrent,
                                snapshot.current, true)) {
        return result("ioFailure", "Owned erasure control durability could not be re-established.");
      }
      Result output = result("erasureOwned");
      output.owner = owner;
      output.phase = kErasurePhase;
      return output;
    }
    const bool remove_temp = snapshot.geometry == ErasureGeometry::kTemp ||
                             snapshot.geometry == ErasureGeometry::kLegacyAlias;
    const bool remove_current = !cleanup_only &&
        (snapshot.geometry == ErasureGeometry::kCurrent ||
         snapshot.geometry == ErasureGeometry::kLegacyAlias);
    if (remove_temp) {
      const EntryValidator validator = [&](int parent, const std::string& name,
                                           const struct stat&) {
        return erasure_node_matches(parent, name, snapshot.temp, true);
      };
      built = checked_unlink(snapshot.control.get(), snapshot.temp_name,
                             snapshot.temp.status,
                             [&]() {
                               return erasure_control_chain_matches(snapshot) &&
                                      erasure_snapshot_entries_match(snapshot,
                                                                     &snapshot.temp);
                             },
                             "erasure.beforeClearTempUnlink", "erasure.cleanupTempFsync",
                             "erasureUnsafe", validator);
    } else if (remove_current) {
      const EntryValidator validator = [&](int parent, const std::string& name,
                                           const struct stat&) {
        return erasure_node_matches(parent, name, snapshot.current, true);
      };
      built = checked_unlink(snapshot.control.get(), kErasureCurrent,
                             snapshot.current.status,
                             [&]() {
                               return erasure_control_chain_matches(snapshot) &&
                                      erasure_snapshot_entries_match(snapshot,
                                                                     &snapshot.current);
                             },
                             "erasure.beforeCurrentUnlink", "erasure.currentClearFsync",
                             "erasureUnsafe", validator);
    } else {
      continue;
    }
    if (built.outcome != "available") return built;
  }
  return result("ioFailure", "Erasure cleanup did not converge.");
}

bool staged_operation(const std::string& name, const char* suffix, std::string* operation_id) {
  constexpr char prefix[] = "publication-";
  const size_t suffix_size = std::strlen(suffix);
  if (name.rfind(prefix, 0) != 0 || name.size() <= sizeof(prefix) - 1 + suffix_size ||
      name.substr(name.size() - suffix_size) != suffix) return false;
  *operation_id = name.substr(sizeof(prefix) - 1, name.size() - (sizeof(prefix) - 1) - suffix_size);
  return opaque_id(*operation_id);
}

Result exclusive_scan(int platform_root) {
  Fd root;
  Result opened = open_attachment_root(platform_root, false, &root);
  if (opened.outcome != "available") return errno == ENOENT ? result("scanComplete") : opened;
  std::map<std::string, PublicationState> descriptors;
  std::set<std::string> staged_operations;
  Fd staging = open_dir_at(root.get(), kStaging, false);
  if (!staging.valid() && errno != ENOENT) return result("unsafeNode", "Staging is unsafe.");
  if (staging.valid()) {
    std::vector<std::string> names;
    if (!list_names(staging.get(), &names)) return result("ioFailure", "Could not scan staging.");
    for (const std::string& name : names) {
      std::string operation_id;
      const bool data = staged_operation(name, ".data", &operation_id);
      const bool intent = !data && staged_operation(name, ".json", &operation_id);
      const bool temporary = !data && !intent && staged_operation(name, ".tmp", &operation_id);
      if (!data && !intent && !temporary) return result("unsafeNode", "Staging contains an unexpected node.");
      staged_operations.insert(operation_id);
      struct stat status {};
      if (fstatat(staging.get(), name.c_str(), &status, AT_SYMLINK_NOFOLLOW) != 0 ||
          !S_ISREG(status.st_mode) || status.st_nlink < 1 || status.st_nlink > 2) {
        return result("unsafeNode", "Staging contains an unsafe node.");
      }
      if (intent || temporary) {
        PublicationState descriptor;
        Result read = read_publication_descriptor(staging.get(), name, &descriptor);
        if (read.outcome != "publicationPending" || descriptor.operation_id != operation_id) {
          return result("unsafeNode", "Staging descriptor does not match its filename.");
        }
        auto existing = descriptors.find(operation_id);
        if (existing != descriptors.end() && !same_descriptor(existing->second, descriptor)) {
          return result("unsafeNode", "Staging descriptors disagree.");
        }
        descriptors[operation_id] = descriptor;
      }
    }
  }

  Result output = result("scanComplete");
  Fd artworks = open_dir_at(root.get(), kArtworks, false);
  if (!artworks.valid()) {
    if (errno != ENOENT) return result("unsafeNode", "Artworks is unsafe.");
  } else {
    std::vector<std::string> artwork_names;
    if (!list_names(artworks.get(), &artwork_names)) return result("ioFailure");
    for (const std::string& artwork_id : artwork_names) {
      if (!opaque_id(artwork_id)) return result("unsafeNode", "Artwork identifier is invalid.");
      Fd artwork = open_dir_at(artworks.get(), artwork_id, false);
      if (!artwork.valid()) return result("unsafeNode", "Artwork directory is unsafe.");
      std::vector<std::string> children;
      if (!list_names(artwork.get(), &children) || children.size() != 1 || children.front() != "attachments") {
        return result("unsafeNode", "Artwork geometry is invalid.");
      }
      Fd attachments = open_dir_at(artwork.get(), "attachments", false);
      if (!attachments.valid()) return result("unsafeNode", "Attachments directory is unsafe.");
      std::vector<std::string> attachment_names;
      if (!list_names(attachments.get(), &attachment_names)) return result("ioFailure");
      for (const std::string& attachment_id : attachment_names) {
        if (!opaque_id(attachment_id)) return result("unsafeNode", "Attachment identifier is invalid.");
        Fd attachment = open_dir_at(attachments.get(), attachment_id, false);
        if (!attachment.valid()) return result("unsafeNode", "Attachment directory is unsafe.");
        std::vector<std::string> names;
        if (!list_names(attachment.get(), &names)) return result("ioFailure");
        if (names.empty()) continue;
        const bool has_claim = std::find(names.begin(), names.end(), kPublicationClaim) != names.end();
        if (!has_claim) {
          if (names.size() != 1 || !canonical_name(names.front())) {
            return result("unsafeNode", "Committed attachment geometry is invalid.");
          }
          struct stat payload {};
          if (fstatat(attachment.get(), names.front().c_str(), &payload, AT_SYMLINK_NOFOLLOW) != 0 ||
              !S_ISREG(payload.st_mode) || payload.st_nlink != 1) {
            return result("unsafeNode", "Committed payload is unsafe.");
          }
          output.entries.push_back({artwork_id, attachment_id, names.front()});
          continue;
        }
        PublicationState claim;
        Result read = read_publication_descriptor(attachment.get(), kPublicationClaim, &claim);
        if (read.outcome != "publicationPending" || claim.artwork_id != artwork_id ||
            claim.attachment_id != attachment_id) {
          return result("unsafeNode", "Publication claim is invalid.");
        }
        for (const std::string& name : names) {
          if (name != kPublicationClaim && name != claim.canonical_name) {
            return result("unsafeNode", "Claimed attachment geometry is invalid.");
          }
        }
        auto existing = descriptors.find(claim.operation_id);
        if (existing != descriptors.end() && !same_descriptor(existing->second, claim)) {
          return result("unsafeNode", "Claim and staging descriptors disagree.");
        }
        descriptors[claim.operation_id] = claim;
      }
    }
  }

  std::set<std::string> operations = staged_operations;
  for (const auto& entry : descriptors) operations.insert(entry.first);
  for (const std::string& operation_id : operations) {
    const auto found = descriptors.find(operation_id);
    if (found == descriptors.end()) {
      struct stat data {};
      if (!staging.valid() ||
          fstatat(staging.get(), publication_data_name(operation_id).c_str(), &data,
                  AT_SYMLINK_NOFOLLOW) != 0 ||
          !S_ISREG(data.st_mode) || data.st_nlink != 1) {
        return result("unsafeNode", "Descriptor-free staging is not one bounded orphan.");
      }
      continue;
    }
    PublicationSnapshot snapshot;
    Result built = build_publication_snapshot(platform_root, found->second, &snapshot);
    if (built.outcome != "available") return built.outcome == "publicationConflict"
        ? result("unsafeNode", "Scan found conflicting publication ownership.") : built;
    switch (snapshot.geometry) {
      case PublicationGeometry::kDataTemp:
      case PublicationGeometry::kDataIntent:
      case PublicationGeometry::kClaimData:
      case PublicationGeometry::kClaimPayload:
      case PublicationGeometry::kLegacyDataTempIntent:
      case PublicationGeometry::kLegacyDataIntentClaim:
      case PublicationGeometry::kLegacyClaimDataPayload:
      case PublicationGeometry::kPostCommit:
        output.publications.push_back(found->second);
        break;
      case PublicationGeometry::kPayloadOnly:
        break;
      case PublicationGeometry::kDataOnly:
        break;
      case PublicationGeometry::kNone:
      case PublicationGeometry::kTempOnly:
      case PublicationGeometry::kIntentOnly:
      case PublicationGeometry::kClaimOnly:
      case PublicationGeometry::kConflict:
      case PublicationGeometry::kUnsafe:
        return result("unsafeNode", "Scan found a non-recoverable publication geometry.");
    }
  }
  return output;
}


Result exclusive_self_test(int platform_root) {
  if (platform_root < 0) return result("unsafeNode", "The app-private root is unsafe or unavailable.");
  Fd root;
  Result opened = open_attachment_root(platform_root, true, &root);
  if (opened.outcome != "available") return opened;
  const std::string suffix = random_name("rename-probe-");
  if (suffix.empty()) return result("unsupported", "Secure random staging identifiers are unavailable.");
  const std::string left_name = suffix + "-left";
  const std::string right_name = suffix + "-right";
  const std::string source_name = suffix + ".source";
  const std::string same_name = suffix + ".same";
  const std::string moved_name = suffix + ".moved";
  const std::string collision_name = suffix + ".collision";
  const std::string symlink_name = suffix + ".symlink";

  const auto raw_cleanup = [&]() {
    Fd left = open_dir_at(root.get(), left_name, false);
    Fd right = open_dir_at(root.get(), right_name, false);
    if (left.valid()) {
      for (const std::string& name : {source_name, same_name, moved_name, collision_name}) {
        if (unlinkat(left.get(), name.c_str(), 0) != 0 && errno != ENOENT) return false;
      }
      if (fsync(left.get()) != 0) return false;
    }
    if (right.valid()) {
      for (const std::string& name : {source_name, same_name, moved_name, collision_name}) {
        if (unlinkat(right.get(), name.c_str(), 0) != 0 && errno != ENOENT) return false;
      }
      if (fsync(right.get()) != 0) return false;
    }
    if (unlinkat(root.get(), symlink_name.c_str(), 0) != 0 && errno != ENOENT) return false;
    if (unlinkat(root.get(), left_name.c_str(), AT_REMOVEDIR) != 0 && errno != ENOENT) return false;
    if (unlinkat(root.get(), right_name.c_str(), AT_REMOVEDIR) != 0 && errno != ENOENT) return false;
    return fsync(root.get()) == 0;
  };
  const auto unavailable = [&](const char* detail) {
    return raw_cleanup() ? result("unsupported", detail)
                         : result("ioFailure", "Capability-probe cleanup could not be confirmed.");
  };

  Fd left = open_dir_at(root.get(), left_name, true, "selfTest.leftCreateFsync");
  Fd right = open_dir_at(root.get(), right_name, true, "selfTest.rightCreateFsync");
  if (!left.valid() || !right.valid()) return unavailable("Probe directories are unavailable.");
  Fd source(openat(left.get(), source_name.c_str(),
                   O_RDWR | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0600));
  if (!source.valid() || !write_all(source.get(), "source") ||
      !sync_fd(source.get(), "selfTest.fileFsync") ||
      !sync_fd(left.get(), "selfTest.fileDirectoryFsync")) {
    return unavailable("Descriptor-relative file durability is unavailable.");
  }
  struct stat source_status {};
  if (fstat(source.get(), &source_status) != 0 || source_status.st_nlink != 1) {
    return unavailable("Probe source identity is unavailable.");
  }
  Result moved = checked_exclusive_rename(
      left.get(), source_name, source_status, left.get(), same_name,
      [&]() {
        return directory_identity_matches(root.get(), left_name, left.get()) &&
               directory_identity_matches(root.get(), right_name, right.get());
      }, "selfTest.sameDirectoryRename", "selfTest.sameDirectoryFsync",
      "selfTest.sameDirectoryFsync");
  if (moved.outcome != "available") return unavailable("Same-directory exclusive rename is unavailable.");
  moved = checked_exclusive_rename(
      left.get(), same_name, source_status, right.get(), moved_name,
      [&]() {
        return directory_identity_matches(root.get(), left_name, left.get()) &&
               directory_identity_matches(root.get(), right_name, right.get());
      }, "selfTest.crossDirectoryRename", "selfTest.crossSourceFsync",
      "selfTest.crossDestinationFsync");
  if (moved.outcome != "available") return unavailable("Cross-directory exclusive rename is unavailable.");

  Fd collision(openat(left.get(), collision_name.c_str(),
                      O_RDWR | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0600));
  if (!collision.valid() || !write_all(collision.get(), "collision") ||
      !sync_fd(collision.get(), "selfTest.collisionFileFsync") ||
      !sync_fd(left.get(), "selfTest.collisionDirectoryFsync")) {
    return unavailable("Collision probe creation is unavailable.");
  }
  struct stat collision_source {};
  struct stat collision_destination {};
  if (fstat(collision.get(), &collision_source) != 0 ||
      fstatat(right.get(), moved_name.c_str(), &collision_destination, AT_SYMLINK_NOFOLLOW) != 0) {
    return unavailable("Collision probe identities are unavailable.");
  }
  errno = 0;
  if (fail_at("selfTest.noReplaceCollision") ||
      rename_exclusive_at(left.get(), collision_name, right.get(), moved_name) == 0 ||
      errno != EEXIST || !entry_identity_matches(left.get(), collision_name, collision_source) ||
      !entry_identity_matches(right.get(), moved_name, collision_destination)) {
    return unavailable("No-overwrite exclusive-rename collision semantics are unavailable.");
  }
  if (symlinkat(".", root.get(), symlink_name.c_str()) != 0) {
    return unavailable("Symlink probe creation is unavailable.");
  }
  Fd followed = open_dir_at(root.get(), symlink_name, false);
  const int nofollow_error = errno;
  if (followed.valid() || nofollow_error != ELOOP) {
    return unavailable("No-follow traversal is unavailable.");
  }
  if (!raw_cleanup()) return result("unsupported", "Required cleanup durability primitives are unavailable.");
  return result("available");
}

std::string json_escape(const std::string& value) {
  std::string output;
  for (char ch : value) {
    if (ch == '"' || ch == '\\') output.push_back('\\');
    if (static_cast<unsigned char>(ch) >= 0x20) output.push_back(ch);
  }
  return output;
}

std::string to_json(const Result& value) {
  std::ostringstream out;
  out << "{\"outcome\":\"" << json_escape(value.outcome) << "\"";
  if (!value.detail.empty()) out << ",\"detail\":\"" << json_escape(value.detail) << "\"";
  if (!value.owner.empty()) out << ",\"owner\":\"" << json_escape(value.owner) << "\"";
  if (!value.phase.empty()) out << ",\"phase\":\"" << json_escape(value.phase) << "\"";
  if (!value.entries.empty()) {
    out << ",\"entries\":[";
    for (size_t index = 0; index < value.entries.size(); ++index) {
      const Entry& entry = value.entries[index];
      if (index) out << ',';
      out << "{\"artworkId\":\"" << entry.artwork_id << "\",\"attachmentId\":\""
          << entry.attachment_id << "\",\"canonicalName\":\"" << entry.canonical_name << "\"}";
    }
    out << ']';
  }
  if (!value.publications.empty()) {
    out << ",\"publications\":[";
    for (size_t index = 0; index < value.publications.size(); ++index) {
      const PublicationState& state = value.publications[index];
      if (index) out << ',';
      out << "{\"operationId\":\"" << state.operation_id << "\",\"artworkId\":\"" << state.artwork_id
          << "\",\"attachmentId\":\"" << state.attachment_id << "\",\"canonicalName\":\""
          << state.canonical_name << "\",\"phase\":\"" << state.phase << "\",\"size\":" << state.size
          << ",\"sha256\":\"" << state.sha256 << "\"}";
    }
    out << ']';
  }
  out << '}';
  return out.str();
}

Result execute(const std::string& platform_root, const std::string& operation,
               const std::string& source_path, const std::string& operation_id,
               const std::string& artwork_id, const std::string& attachment_id,
               const std::string& canonical) {
  const bool known = operation == "capabilities" || operation == "selfTest" ||
      operation == "publish" || operation == "publicationStatus" ||
      operation == "recoverPublication" || operation == "rollbackPublication" ||
      operation == "cleanupPublication" || operation == "remove" ||
      operation == "scan" || operation == "writeErasureControl" ||
      operation == "readErasureControl" || operation == "recoverErasureControl" ||
      operation == "clearErasureControl" || operation == "cleanupErasureControl";
  if (!known) return result("invalidRequest", "Unknown custody operation.");
  const bool erasure_read = operation == "readErasureControl";
  const bool erasure_mutation = operation == "writeErasureControl" ||
      operation == "recoverErasureControl" || operation == "clearErasureControl" ||
      operation == "cleanupErasureControl";
  if ((erasure_read && !operation_id.empty() && !opaque_id(operation_id)) ||
      (erasure_mutation && !opaque_id(operation_id))) {
    return result("invalidRequest");
  }

  Fd operation_root = open_root(platform_root);
  if (!operation_root.valid()) return unsafe_or_io("The app-private root is unsafe or unavailable.");
  FileLock operation_lock(operation_root.get());
  if (!operation_lock.valid()) return result("unsupported", "Custody serialization is unavailable.");
  run_boundary("operation.afterRootLock");
  const int root = operation_root.get();
  if (operation == "capabilities" || operation == "selfTest") return exclusive_self_test(root);
  if (operation == "publish") return exclusive_publish(root, source_path, operation_id, artwork_id, attachment_id, canonical);
  if (operation == "publicationStatus") return exclusive_publication_status(root, operation_id, artwork_id, attachment_id, canonical);
  if (operation == "recoverPublication") return exclusive_recover(root, operation_id, artwork_id, attachment_id, canonical);
  if (operation == "rollbackPublication") return exclusive_rollback(root, operation_id, artwork_id, attachment_id, canonical, false);
  if (operation == "cleanupPublication") return exclusive_rollback(root, operation_id, artwork_id, attachment_id, canonical, true);
  if (operation == "remove") return exclusive_remove_payload(root, artwork_id, attachment_id, canonical);
  if (operation == "scan") return exclusive_scan(root);
  if (operation == "writeErasureControl") return exclusive_write_or_recover_erasure(root, operation_id, true);
  if (operation == "readErasureControl") return exclusive_erasure_status(root, operation_id);
  if (operation == "recoverErasureControl") return exclusive_write_or_recover_erasure(root, operation_id, false);
  if (operation == "clearErasureControl") return exclusive_clear_erasure(root, operation_id, false);
  return exclusive_clear_erasure(root, operation_id, true);
}

}  // namespace custody

#ifdef __ANDROID__
namespace {
std::string from_jstring(JNIEnv* env, jstring value) {
  if (value == nullptr) return {};
  const char* chars = env->GetStringUTFChars(value, nullptr);
  if (chars == nullptr) return {};
  std::string output(chars);
  env->ReleaseStringUTFChars(value, chars);
  return output;
}
}  // namespace

extern "C" JNIEXPORT jstring JNICALL
Java_app_archivale_AttachmentCustodyNative_execute(
    JNIEnv* env, jobject, jstring root, jstring operation, jstring source,
    jstring operation_id, jstring artwork, jstring attachment, jstring name) {
  const auto output = custody::to_json(custody::execute(
      from_jstring(env, root), from_jstring(env, operation), from_jstring(env, source),
      from_jstring(env, operation_id), from_jstring(env, artwork),
      from_jstring(env, attachment), from_jstring(env, name)));
  return env->NewStringUTF(output.c_str());
}

extern "C" JNIEXPORT jintArray JNICALL
Java_app_archivale_AttachmentCustodyNative_openExportPair(
    JNIEnv* env, jobject, jstring root, jstring source) {
  auto pair = custody::open_export_pair(from_jstring(env, root), from_jstring(env, source));
  const jsize size = pair.valid() ? 2 : 0;
  jintArray output = env->NewIntArray(size);
  if (output == nullptr || size == 0) return output;
  const jint descriptors[] = {pair.payload.release(), pair.metadata.release()};
  env->SetIntArrayRegion(output, 0, size, descriptors);
  if (env->ExceptionCheck()) {
    close(descriptors[0]);
    close(descriptors[1]);
  }
  return output;
}

#ifdef ATTACHMENT_CUSTODY_TESTING
extern "C" JNIEXPORT void JNICALL
Java_app_archivale_AttachmentCustodyTestNative_crashAt(
    JNIEnv* env, jobject, jstring point) {
  custody::test_crash_at(from_jstring(env, point));
}

extern "C" JNIEXPORT void JNICALL
Java_app_archivale_AttachmentCustodyTestNative_resetHooks(
    JNIEnv*, jobject) {
  custody::test_reset_hooks();
}
#endif
#endif
