#include <cerrno>
#include <cstdint>
#include <cstring>
#include <dirent.h>
#include <fcntl.h>
#include <sys/stat.h>
#include <sys/syscall.h>
#include <sys/types.h>
#include <unistd.h>

#include <algorithm>
#include <array>
#include <cctype>
#include <cstdlib>
#include <limits>
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

 private:
  int value_;
};

#ifdef ATTACHMENT_CUSTODY_TESTING
struct TestHooks {
  std::string crash_point;
  std::string failure_point;
};
thread_local TestHooks g_test_hooks;
void test_crash_at(const std::string& point) { g_test_hooks.crash_point = point; }
void test_fail_at(const std::string& point) { g_test_hooks.failure_point = point; }
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
#else
bool crash_at(const char*) { return false; }
bool fail_at(const char*) { return false; }
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
    if (!create || errno != ENOENT || mkdirat(parent, name.c_str(), 0700) != 0) return Fd();
    if (!sync_fd(parent, sync_point) ||
        fstatat(parent, name.c_str(), &before, AT_SYMLINK_NOFOLLOW) != 0) {
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

bool empty_directory(int fd) {
  std::vector<std::string> names;
  return list_names(fd, &names) && names.empty();
}

Result unsafe_or_io(const char* detail) {
  return result(errno == ELOOP || errno == ENOTDIR || errno == EMLINK ? "unsafeNode" : "ioFailure", detail);
}

struct TargetDirs {
  Fd root;
  Fd artworks;
  Fd artwork;
  Fd attachments;
  Fd attachment;
};

Result open_attachment_root(const std::string& platform_root, bool create, Fd* root) {
  Fd platform = open_root(platform_root);
  if (!platform.valid()) return unsafe_or_io("The app-private root is unsafe or unavailable.");
  *root = open_dir_at(platform.get(), kAttachments, create, "attachments.parentFsync");
  return root->valid() ? result("available")
                       : unsafe_or_io("The app-private attachment root is unsafe or unavailable.");
}

Result open_target(const std::string& platform_root, const std::string& artwork_id,
                   const std::string& attachment_id, bool create, TargetDirs* dirs) {
  Result opened = open_attachment_root(platform_root, create, &dirs->root);
  if (opened.outcome != "available") return opened;
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

bool read_regular_at(int parent, const std::string& name, size_t limit, int min_links, int max_links,
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

bool inspect_payload_at(int parent, const std::string& name, const PublicationState& descriptor,
                        struct stat* status_out) {
  struct stat named {};
  errno = 0;
  if (fstatat(parent, name.c_str(), &named, AT_SYMLINK_NOFOLLOW) != 0 ||
      !S_ISREG(named.st_mode) || named.st_nlink < 1 || named.st_nlink > 2) {
    if (errno == 0) errno = ELOOP;
    return false;
  }
  Fd file(openat(parent, name.c_str(), O_RDONLY | O_CLOEXEC | O_NOFOLLOW));
  if (!file.valid()) return false;
  struct stat opened {};
  uint64_t size = 0;
  std::string digest;
  if (fstat(file.get(), &opened) != 0 || !same_inode(named, opened) ||
      !hash_fd(file.get(), &size, &digest) || size != descriptor.size || digest != descriptor.sha256) {
    errno = ELOOP;
    return false;
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

Result write_publication_descriptor(int staging, const PublicationState& descriptor) {
  const std::string temp = publication_temp_name(descriptor.operation_id);
  const std::string intent = publication_intent_name(descriptor.operation_id);
  Fd file(openat(staging, temp.c_str(), O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0600));
  if (!file.valid()) return errno == EEXIST ? result("publicationPending")
                                            : unsafe_or_io("Could not create the publication descriptor staging file.");
  const std::string content = publication_json(descriptor);
  if (!write_all(file.get(), content) || !sync_fd(file.get(), "publish.intentFileFsync")) {
    return result("ioFailure", "Could not durably write the publication descriptor.");
  }
  if (crash_at("publish.afterIntentFileFsync")) return result("ioFailure", "Injected publication crash.");
  if (linkat(staging, temp.c_str(), staging, intent.c_str(), 0) != 0) {
    return errno == EEXIST ? result("publicationPending")
                           : unsafe_or_io("Could not atomically publish the publication descriptor.");
  }
  if (!sync_fd(staging, "publish.intentDirectoryFsync")) {
    return result("ioFailure", "Could not sync the publication descriptor entry.");
  }
  if (crash_at("publish.afterIntentLink")) return result("ioFailure", "Injected publication crash.");
  if (!unlink_entry(staging, temp, 0, "publish.intentTempUnlink") ||
      !sync_fd(staging, "publish.intentTempDirectoryFsync")) {
    return result("ioFailure", "Could not clean the publication descriptor staging entry.");
  }
  return result("publicationPending");
}

Result validate_attachment_geometry(int fd, const PublicationState& descriptor, bool allow_claim) {
  std::vector<std::string> names;
  if (!list_names(fd, &names)) return result("ioFailure", "Could not inspect the attachment directory.");
  for (const std::string& name : names) {
    if (allow_claim && name == kPublicationClaim) continue;
    if (canonical_name(name)) {
      if (name != descriptor.canonical_name) {
        return result("publicationConflict", "Another canonical payload already owns the attachment directory.");
      }
      continue;
    }
    return result("unsafeNode", "The attachment directory contains an unexpected node.");
  }
  return result("available");
}

Result continue_publication(const std::string& platform_root, const PublicationState& descriptor,
                            bool recovered) {
  TargetDirs target;
  Result opened = open_target(platform_root, descriptor.artwork_id, descriptor.attachment_id, true, &target);
  if (opened.outcome != "available") return opened;
  Fd staging = open_dir_at(target.root.get(), kStaging, true, "staging.parentFsync");
  if (!staging.valid()) return unsafe_or_io("The publication staging directory is unsafe.");

  const std::string intent_name = publication_intent_name(descriptor.operation_id);
  const std::string data_name = publication_data_name(descriptor.operation_id);
  PublicationState staged_descriptor;
  struct stat staged_intent {};
  Result staged = read_publication_descriptor(staging.get(), intent_name, &staged_descriptor, &staged_intent);
  PublicationState claimed_descriptor;
  struct stat claimed_intent {};
  Result claimed = read_publication_descriptor(target.attachment.get(), kPublicationClaim,
                                                &claimed_descriptor, &claimed_intent);

  const bool has_staged = staged.outcome == "publicationPending";
  const bool has_claim = claimed.outcome == "publicationPending";
  if (!has_staged && !has_claim) {
    return result("publicationAbsent", "No recoverable publication intent exists.");
  }
  if ((has_staged && !descriptor_matches(staged_descriptor, descriptor.operation_id, descriptor.artwork_id,
                                          descriptor.attachment_id, descriptor.canonical_name)) ||
      (has_claim && !descriptor_matches(claimed_descriptor, descriptor.operation_id, descriptor.artwork_id,
                                         descriptor.attachment_id, descriptor.canonical_name))) {
    return result("publicationConflict", "A different publication intent owns this state.");
  }
  if ((staged.outcome == "unsafeNode") || (claimed.outcome == "unsafeNode")) return result("unsafeNode", "Publication state is unsafe.");
  if (has_staged && has_claim && !same_inode(staged_intent, claimed_intent)) {
    return result("publicationConflict", "The staged and claimed publication descriptors do not share identity.");
  }
  const PublicationState active = has_staged ? staged_descriptor : claimed_descriptor;

  struct stat staged_payload {};
  bool has_staged_payload = inspect_payload_at(staging.get(), data_name, active, &staged_payload);
  if (!has_staged_payload && errno != ENOENT) return result("unsafeNode", "The staged publication payload is unsafe or corrupt.");
  struct stat target_payload {};
  bool has_target_payload = inspect_payload_at(target.attachment.get(), active.canonical_name, active, &target_payload);
  if (!has_target_payload && errno != ENOENT) return result("unsafeNode", "The canonical publication payload is unsafe or corrupt.");
  if (!has_staged_payload && !has_target_payload) return result("publicationPartial", "The publication payload is missing.");
  if (has_staged_payload && has_target_payload && !same_inode(staged_payload, target_payload)) {
    return result("publicationConflict", "The staged and canonical payloads do not share identity.");
  }

  Result geometry = validate_attachment_geometry(target.attachment.get(), active, true);
  if (geometry.outcome != "available") return geometry;

  if (!has_claim) {
    if (!has_staged) return result("publicationPartial", "The publication claim cannot be reconstructed.");
    if (linkat(staging.get(), intent_name.c_str(), target.attachment.get(), kPublicationClaim, 0) != 0) {
      return errno == EEXIST ? result("publicationConflict", "Another publication owns this attachment.")
                             : unsafe_or_io("Could not claim the attachment directory.");
    }
    if (!sync_fd(target.attachment.get(), "publish.claimDirectoryFsync")) {
      return result("ioFailure", "Could not durably claim the attachment directory.");
    }
    if (crash_at("publish.afterClaim")) return result("ioFailure", "Injected publication crash.");
  }

  geometry = validate_attachment_geometry(target.attachment.get(), active, true);
  if (geometry.outcome != "available") return geometry;

  if (!has_target_payload) {
    if (!has_staged_payload) return result("publicationPartial", "The staged payload is unavailable.");
    if (linkat(staging.get(), data_name.c_str(), target.attachment.get(), active.canonical_name.c_str(), 0) != 0) {
      return errno == EEXIST ? result("publicationConflict", "A canonical payload appeared during publication.")
                             : unsafe_or_io("Exclusive publication failed.");
    }
    if (!sync_fd(target.attachment.get(), "publish.payloadDirectoryFsync")) {
      return result("ioFailure", "Could not sync the canonical payload entry.");
    }
    if (crash_at("publish.afterPayloadLink")) return result("ioFailure", "Injected publication crash.");
    if (!inspect_payload_at(target.attachment.get(), active.canonical_name, active, &target_payload) ||
        !same_inode(staged_payload, target_payload)) {
      return result("unsafeNode", "The published payload failed identity or checksum verification.");
    }
  }

  if (!unlink_entry(target.attachment.get(), kPublicationClaim, 0, "publish.claimUnlink") ||
      !sync_fd(target.attachment.get(), "publish.commitDirectoryFsync")) {
    return result("ioFailure", "Could not durably commit the attachment publication.");
  }
  if (crash_at("publish.afterCommit")) return result("ioFailure", "Injected publication crash.");

  if (has_staged_payload &&
      (!unlink_entry(staging.get(), data_name, 0, "publish.dataUnlink") ||
       !sync_fd(staging.get(), "publish.dataCleanupFsync"))) {
    return result("ioFailure", "Could not clean the staged publication payload.");
  }
  if (crash_at("publish.afterDataCleanup")) return result("ioFailure", "Injected publication crash.");
  if (has_staged &&
      (!unlink_entry(staging.get(), intent_name, 0, "publish.intentUnlink") ||
       !sync_fd(staging.get(), "publish.intentCleanupFsync"))) {
    return result("ioFailure", "Could not clean the staged publication descriptor.");
  }
  const std::string temp = publication_temp_name(active.operation_id);
  struct stat temp_status {};
  if (fstatat(staging.get(), temp.c_str(), &temp_status, AT_SYMLINK_NOFOLLOW) == 0) {
    if (!S_ISREG(temp_status.st_mode) || temp_status.st_nlink != 1 ||
        !unlink_entry(staging.get(), temp, 0, "publish.tempRecoveryUnlink") ||
        !sync_fd(staging.get(), "publish.tempRecoveryFsync")) {
      return result("ioFailure", "Could not clean the temporary publication descriptor.");
    }
  } else if (errno != ENOENT) {
    return unsafe_or_io("Could not inspect the temporary publication descriptor.");
  }
  if (!inspect_payload_at(target.attachment.get(), active.canonical_name, active, &target_payload) ||
      target_payload.st_nlink != 1) {
    return result("unsafeNode", "The recovered payload failed final size, checksum, or link verification.");
  }
  Result output = result(recovered ? "publicationRecovered" : "published");
  output.publications.push_back(active);
  return output;
}

Result publish(const std::string& platform_root, const std::string& source_path,
               const std::string& operation_id, const std::string& artwork_id,
               const std::string& attachment_id, const std::string& name) {
  if (!target_valid(operation_id, artwork_id, attachment_id, name) || source_path.empty()) {
    return result("invalidRequest", "Invalid custody publication request.");
  }
  Fd source(open(source_path.c_str(), O_RDONLY | O_CLOEXEC | O_NOFOLLOW));
  if (!source.valid()) return result(errno == ENOENT ? "sourceMissing" : "unsafeNode", "The import source is unavailable or unsafe.");
  struct stat source_status {};
  if (fstat(source.get(), &source_status) != 0 || !S_ISREG(source_status.st_mode) || source_status.st_nlink != 1) {
    return result("unsafeNode", "The import source is not a safe single-link regular file.");
  }

  TargetDirs target;
  Result opened = open_target(platform_root, artwork_id, attachment_id, true, &target);
  if (opened.outcome != "available") return opened;
  PublicationState requested{operation_id, artwork_id, attachment_id, name, "staged", "", 0};
  Result geometry = validate_attachment_geometry(target.attachment.get(), requested, true);
  if (geometry.outcome != "available") return geometry;
  std::vector<std::string> target_names;
  if (!list_names(target.attachment.get(), &target_names)) return result("ioFailure", "Could not inspect publication target.");
  if (!target_names.empty()) return result("alreadyExists", "The attachment directory is already owned.");

  Fd staging = open_dir_at(target.root.get(), kStaging, true, "staging.parentFsync");
  if (!staging.valid()) return unsafe_or_io("The publication staging directory is unsafe.");
  const std::string data_name = publication_data_name(operation_id);
  const std::string intent_name = publication_intent_name(operation_id);
  struct stat existing {};
  if (fstatat(staging.get(), data_name.c_str(), &existing, AT_SYMLINK_NOFOLLOW) == 0 ||
      fstatat(staging.get(), intent_name.c_str(), &existing, AT_SYMLINK_NOFOLLOW) == 0) {
    return result("publicationPending", "This publication intent already has recoverable state.");
  }
  Fd staged(openat(staging.get(), data_name.c_str(), O_RDWR | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0600));
  if (!staged.valid()) return unsafe_or_io("Could not create the staged publication payload.");
  if (!copy_and_hash(source.get(), staged.get(), &requested.size, &requested.sha256) ||
      !sync_fd(staged.get(), "publish.dataFileFsync") ||
      !sync_fd(staging.get(), "publish.dataDirectoryFsync")) {
    return result("ioFailure", "Could not durably stage the publication payload.");
  }
  if (crash_at("publish.afterDataFsync")) return result("ioFailure", "Injected publication crash.");
  uint64_t verified_size = 0;
  std::string verified_hash;
  if (!hash_fd(staged.get(), &verified_size, &verified_hash) ||
      verified_size != requested.size || verified_hash != requested.sha256) {
    return result("ioFailure", "The staged payload failed checksum verification.");
  }
  Result descriptor = write_publication_descriptor(staging.get(), requested);
  if (descriptor.outcome != "publicationPending") return descriptor;
  return continue_publication(platform_root, requested, false);
}

Result recover_publication(const std::string& platform_root, const std::string& operation_id,
                           const std::string& artwork_id, const std::string& attachment_id,
                           const std::string& canonical) {
  if (!target_valid(operation_id, artwork_id, attachment_id, canonical)) return result("invalidRequest");
  TargetDirs target;
  Result opened = open_target(platform_root, artwork_id, attachment_id, false, &target);
  if (opened.outcome != "available") return errno == ENOENT ? result("publicationAbsent") : opened;
  Fd staging = open_dir_at(target.root.get(), kStaging, false);
  PublicationState descriptor;
  Result state = staging.valid()
      ? read_publication_descriptor(staging.get(), publication_intent_name(operation_id), &descriptor)
      : result("publicationAbsent");
  if (state.outcome == "publicationAbsent" && staging.valid()) {
    struct stat temporary {};
    Result pending = read_publication_descriptor(
        staging.get(), publication_temp_name(operation_id), &descriptor, &temporary);
    if (pending.outcome == "publicationPending") {
      if (!descriptor_matches(descriptor, operation_id, artwork_id, attachment_id, canonical)) {
        return result("publicationConflict", "A different publication owns the temporary intent.");
      }
      const std::string temporary_name = publication_temp_name(operation_id);
      const std::string intent_name = publication_intent_name(operation_id);
      if (linkat(staging.get(), temporary_name.c_str(), staging.get(), intent_name.c_str(), 0) != 0 ||
          !sync_fd(staging.get(), "recover.intentDirectoryFsync") ||
          !unlink_entry(staging.get(), temporary_name, 0, "recover.intentTempUnlink") ||
          !sync_fd(staging.get(), "recover.intentTempFsync")) {
        return result("ioFailure", "Could not recover the atomic publication descriptor.");
      }
      state = read_publication_descriptor(staging.get(), intent_name, &descriptor);
    } else if (pending.outcome == "unsafeNode") {
      return pending;
    }
  }
  if (state.outcome != "publicationPending") {
    state = read_publication_descriptor(target.attachment.get(), kPublicationClaim, &descriptor);
  }
  if (state.outcome != "publicationPending") {
    struct stat payload {};
    if (fstatat(target.attachment.get(), canonical.c_str(), &payload, AT_SYMLINK_NOFOLLOW) == 0 &&
        S_ISREG(payload.st_mode) && payload.st_nlink == 1) return result("published");
    return state;
  }
  if (!descriptor_matches(descriptor, operation_id, artwork_id, attachment_id, canonical)) {
    return result("publicationConflict", "A different publication owns the recoverable state.");
  }
  return continue_publication(platform_root, descriptor, true);
}

bool remove_if_present(int parent, const std::string& name, int max_links,
                       const char* unlink_point, const char* fsync_point, Result* failure) {
  struct stat status {};
  if (fstatat(parent, name.c_str(), &status, AT_SYMLINK_NOFOLLOW) != 0) {
    if (errno == ENOENT) return true;
    *failure = unsafe_or_io("Could not inspect a recoverable staging entry.");
    return false;
  }
  if (!S_ISREG(status.st_mode) || status.st_nlink < 1 || status.st_nlink > max_links) {
    *failure = result("unsafeNode", "A recoverable staging entry is unsafe.");
    return false;
  }
  if (!unlink_entry(parent, name, 0, unlink_point) || !sync_fd(parent, fsync_point)) {
    *failure = result("ioFailure", "Could not durably remove a recoverable staging entry.");
    return false;
  }
  return true;
}

Result rollback_publication(const std::string& platform_root, const std::string& operation_id,
                            const std::string& artwork_id, const std::string& attachment_id,
                            const std::string& canonical, bool cleanup_only) {
  if (!target_valid(operation_id, artwork_id, attachment_id, canonical)) return result("invalidRequest");
  TargetDirs target;
  Result opened = open_target(platform_root, artwork_id, attachment_id, false, &target);
  if (opened.outcome != "available") return errno == ENOENT ? result(cleanup_only ? "cleanupComplete" : "publicationRolledBack") : opened;
  Fd staging = open_dir_at(target.root.get(), kStaging, false);
  PublicationState staged_descriptor;
  struct stat staged_intent {};
  Result staged_state = staging.valid()
      ? read_publication_descriptor(staging.get(), publication_intent_name(operation_id), &staged_descriptor, &staged_intent)
      : result("publicationAbsent");
  PublicationState claim_descriptor;
  struct stat claim_intent {};
  Result claim_state = read_publication_descriptor(target.attachment.get(), kPublicationClaim,
                                                   &claim_descriptor, &claim_intent);
  if (staged_state.outcome == "unsafeNode" || claim_state.outcome == "unsafeNode") return result("unsafeNode", "Publication rollback state is unsafe.");
  const bool has_stage = staged_state.outcome == "publicationPending";
  const bool has_claim = claim_state.outcome == "publicationPending";
  if ((has_stage && !descriptor_matches(staged_descriptor, operation_id, artwork_id, attachment_id, canonical)) ||
      (has_claim && !descriptor_matches(claim_descriptor, operation_id, artwork_id, attachment_id, canonical))) {
    return result("publicationConflict", "A different publication owns the rollback state.");
  }
  if (has_stage && has_claim && !same_inode(staged_intent, claim_intent)) {
    return result("publicationConflict", "Publication rollback identities do not match.");
  }
  const PublicationState* descriptor = has_stage ? &staged_descriptor : (has_claim ? &claim_descriptor : nullptr);
  if (has_claim) {
    struct stat payload {};
    if (fstatat(target.attachment.get(), canonical.c_str(), &payload, AT_SYMLINK_NOFOLLOW) == 0) {
      if (descriptor == nullptr || !inspect_payload_at(target.attachment.get(), canonical, *descriptor, &payload)) {
        return result("unsafeNode", "The claimed payload is unsafe or does not match its intent.");
      }
      if (!unlink_entry(target.attachment.get(), canonical, 0, "rollback.payloadUnlink") ||
          !sync_fd(target.attachment.get(), "rollback.payloadFsync")) {
        return result("ioFailure", "Could not roll back the claimed payload.");
      }
    } else if (errno != ENOENT) {
      return unsafe_or_io("Could not inspect the claimed payload.");
    }
    if (!unlink_entry(target.attachment.get(), kPublicationClaim, 0, "rollback.claimUnlink") ||
        !sync_fd(target.attachment.get(), "rollback.claimFsync")) {
      return result("ioFailure", "Could not roll back the publication claim.");
    }
  }
  Result failure;
  if (staging.valid()) {
    if (!remove_if_present(staging.get(), publication_data_name(operation_id), 2,
                           "rollback.dataUnlink", "rollback.dataFsync", &failure) ||
        !remove_if_present(staging.get(), publication_intent_name(operation_id), 2,
                           "rollback.intentUnlink", "rollback.intentFsync", &failure) ||
        !remove_if_present(staging.get(), publication_temp_name(operation_id), 1,
                           "rollback.tempUnlink", "rollback.tempFsync", &failure)) return failure;
  }

  if (empty_directory(target.attachment.get())) {
    if (!unlink_entry(target.attachments.get(), attachment_id, AT_REMOVEDIR, "cleanup.attachmentRmdir") ||
        !sync_fd(target.attachments.get(), "cleanup.attachmentsFsync")) return result("ioFailure", "Could not prune the empty attachment directory.");
    if (empty_directory(target.attachments.get())) {
      if (!unlink_entry(target.artwork.get(), "attachments", AT_REMOVEDIR, "cleanup.attachmentsRmdir") ||
          !sync_fd(target.artwork.get(), "cleanup.artworkFsync")) return result("ioFailure", "Could not prune the empty attachments directory.");
      if (empty_directory(target.artwork.get())) {
        if (!unlink_entry(target.artworks.get(), artwork_id, AT_REMOVEDIR, "cleanup.artworkRmdir") ||
            !sync_fd(target.artworks.get(), "cleanup.artworksFsync")) return result("ioFailure", "Could not prune the empty artwork directory.");
      }
    }
  }
  return result(cleanup_only ? "cleanupComplete" : "publicationRolledBack");
}

Result publication_status(const std::string& platform_root, const std::string& operation_id,
                          const std::string& artwork_id, const std::string& attachment_id,
                          const std::string& canonical) {
  if (!target_valid(operation_id, artwork_id, attachment_id, canonical)) return result("invalidRequest");
  TargetDirs target;
  Result opened = open_target(platform_root, artwork_id, attachment_id, false, &target);
  if (opened.outcome != "available") return errno == ENOENT ? result("publicationAbsent") : opened;
  Fd staging = open_dir_at(target.root.get(), kStaging, false);
  PublicationState descriptor;
  Result state = staging.valid()
      ? read_publication_descriptor(staging.get(), publication_intent_name(operation_id), &descriptor)
      : result("publicationAbsent");
  if (state.outcome != "publicationPending") state = read_publication_descriptor(target.attachment.get(), kPublicationClaim, &descriptor);
  if (state.outcome == "publicationPending") {
    if (!descriptor_matches(descriptor, operation_id, artwork_id, attachment_id, canonical)) return result("publicationConflict");
    state.publications.push_back(descriptor);
    return state;
  }
  struct stat payload {};
  if (fstatat(target.attachment.get(), canonical.c_str(), &payload, AT_SYMLINK_NOFOLLOW) == 0) {
    return S_ISREG(payload.st_mode) && payload.st_nlink == 1 ? result("published") : result("unsafeNode");
  }
  if (errno != ENOENT) return unsafe_or_io("Could not inspect publication status.");
  if (staging.valid()) {
    for (const std::string& partial : {publication_data_name(operation_id), publication_temp_name(operation_id)}) {
      if (fstatat(staging.get(), partial.c_str(), &payload, AT_SYMLINK_NOFOLLOW) == 0) return result("publicationPartial");
      if (errno != ENOENT) return unsafe_or_io("Could not inspect partial publication state.");
    }
  }
  return result("publicationAbsent");
}

Result remove_payload(const std::string& platform_root, const std::string& artwork_id,
                      const std::string& attachment_id, const std::string& name) {
  if (!opaque_id(artwork_id) || !opaque_id(attachment_id) || !canonical_name(name)) return result("invalidRequest");
  TargetDirs target;
  Result opened = open_target(platform_root, artwork_id, attachment_id, false, &target);
  if (opened.outcome != "available") return errno == ENOENT ? result("missing") : opened;
  struct stat claim {};
  if (fstatat(target.attachment.get(), kPublicationClaim, &claim, AT_SYMLINK_NOFOLLOW) == 0) {
    return result("publicationPending", "The attachment is owned by an unfinished publication.");
  }
  if (errno != ENOENT) return unsafe_or_io("Could not inspect publication ownership.");
  struct stat status {};
  if (fstatat(target.attachment.get(), name.c_str(), &status, AT_SYMLINK_NOFOLLOW) != 0) {
    return errno == ENOENT ? result("missing") : unsafe_or_io("Could not inspect the canonical payload.");
  }
  if (!S_ISREG(status.st_mode) || status.st_nlink != 1) return result("unsafeNode", "The canonical payload is not a safe single-link file.");
  if (!unlink_entry(target.attachment.get(), name, 0, "remove.payloadUnlink") ||
      !sync_fd(target.attachment.get(), "remove.payloadFsync")) return result("ioFailure", "Could not durably remove the payload.");
  if (!empty_directory(target.attachment.get())) return result("removed");
  if (!unlink_entry(target.attachments.get(), attachment_id, AT_REMOVEDIR, "remove.attachmentRmdir") ||
      !sync_fd(target.attachments.get(), "remove.attachmentsFsync")) return result("ioFailure", "Could not prune the attachment directory.");
  if (empty_directory(target.attachments.get())) {
    if (!unlink_entry(target.artwork.get(), "attachments", AT_REMOVEDIR, "remove.attachmentsRmdir") ||
        !sync_fd(target.artwork.get(), "remove.artworkFsync")) return result("ioFailure", "Could not prune the attachments directory.");
    if (empty_directory(target.artwork.get()) &&
        (!unlink_entry(target.artworks.get(), artwork_id, AT_REMOVEDIR, "remove.artworkRmdir") ||
         !sync_fd(target.artworks.get(), "remove.artworksFsync"))) return result("ioFailure", "Could not prune the artwork directory.");
  }
  return result("removed");
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

Result read_erasure_at(int control, const std::string& name, const std::string& expected_owner,
                       struct stat* status = nullptr) {
  std::string content;
  if (!read_regular_at(control, name, 256, 1, 2, &content, status)) {
    return errno == ENOENT ? result("erasureAbsent") : result("erasureUnsafe", "Erasure control is unsafe.");
  }
  std::string owner;
  std::string phase;
  if (!parse_erasure(content, &owner, &phase)) return result("erasureUnsafe", "Erasure control is invalid.");
  Result output = result(expected_owner.empty() || owner == expected_owner ? "erasureOwned" : "erasureConflict");
  output.owner = owner;
  output.phase = phase;
  return output;
}

Result read_current_erasure(int control, const std::string& expected_owner) {
  struct stat current_status {};
  Result current = read_erasure_at(control, kErasureCurrent, expected_owner, &current_status);
  if ((current.outcome != "erasureOwned" && current.outcome != "erasureConflict") ||
      current_status.st_nlink == 1) return current;
  struct stat temp_status {};
  const std::string temp = erasure_temp_name(current.owner);
  if (current_status.st_nlink != 2 ||
      fstatat(control, temp.c_str(), &temp_status, AT_SYMLINK_NOFOLLOW) != 0 ||
      !S_ISREG(temp_status.st_mode) || !same_inode(current_status, temp_status)) {
    return result("erasureUnsafe", "Erasure control has an unowned hard link.");
  }
  return current;
}

Result erasure_status(const std::string& platform_root, const std::string& expected_owner) {
  if (!expected_owner.empty() && !opaque_id(expected_owner)) return result("invalidRequest");
  Fd root = open_root(platform_root);
  if (!root.valid()) return unsafe_or_io("The erasure-control parent is unsafe.");
  Fd control = open_dir_at(root.get(), kErasureControl, false);
  if (!control.valid()) return errno == ENOENT ? result("erasureAbsent") : result("erasureUnsafe");
  return read_current_erasure(control.get(), expected_owner);
}

Result write_erasure(const std::string& platform_root, const std::string& owner) {
  if (!opaque_id(owner)) return result("invalidRequest");
  Fd root = open_root(platform_root);
  if (!root.valid()) return unsafe_or_io("The erasure-control parent is unsafe.");
  Fd control = open_dir_at(root.get(), kErasureControl, true, "erasure.parentFsync");
  if (!control.valid()) return result("erasureUnsafe", "The erasure-control directory is unsafe.");
  Result current = read_current_erasure(control.get(), owner);
  if (current.outcome == "erasureOwned" || current.outcome == "erasureConflict" || current.outcome == "erasureUnsafe") return current;

  const std::string temp = erasure_temp_name(owner);
  Fd file(openat(control.get(), temp.c_str(), O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0600));
  if (!file.valid()) {
    Result pending = read_erasure_at(control.get(), temp, owner);
    if (pending.outcome != "erasureOwned") return pending;
  } else {
    const std::string content = erasure_json(owner);
    if (!write_all(file.get(), content) || !sync_fd(file.get(), "erasure.tempFileFsync")) return result("ioFailure", "Could not write erasure control.");
    if (crash_at("erasure.afterTempFsync")) return result("ioFailure", "Injected erasure crash.");
  }
  if (linkat(control.get(), temp.c_str(), control.get(), kErasureCurrent, 0) != 0) {
    current = read_current_erasure(control.get(), owner);
    if (current.outcome != "erasureOwned") return current;
  } else {
    if (!sync_fd(control.get(), "erasure.currentDirectoryFsync")) return result("ioFailure", "Could not sync erasure control.");
    if (crash_at("erasure.afterCurrentLink")) return result("ioFailure", "Injected erasure crash.");
  }
  if (!unlink_entry(control.get(), temp, 0, "erasure.tempUnlink") ||
      !sync_fd(control.get(), "erasure.tempCleanupFsync")) return result("ioFailure", "Could not clean erasure-control staging.");
  if (crash_at("erasure.afterTempCleanup")) return result("ioFailure", "Injected erasure crash.");
  return read_current_erasure(control.get(), owner);
}

Result recover_erasure(const std::string& platform_root, const std::string& owner) {
  if (!opaque_id(owner)) return result("invalidRequest");
  Fd root = open_root(platform_root);
  if (!root.valid()) return unsafe_or_io("The erasure-control parent is unsafe.");
  Fd control = open_dir_at(root.get(), kErasureControl, false);
  if (!control.valid()) return errno == ENOENT ? result("erasureAbsent") : result("erasureUnsafe");
  Result current = read_current_erasure(control.get(), owner);
  const std::string temp = erasure_temp_name(owner);
  Result pending = read_erasure_at(control.get(), temp, owner);
  if (current.outcome == "erasureConflict" || current.outcome == "erasureUnsafe") return current;
  if (pending.outcome == "erasureUnsafe" || pending.outcome == "erasureConflict") return pending;
  if (current.outcome == "erasureAbsent") {
    if (pending.outcome != "erasureOwned") return current;
    if (linkat(control.get(), temp.c_str(), control.get(), kErasureCurrent, 0) != 0 ||
        !sync_fd(control.get(), "erasure.recoverCurrentFsync")) return result("ioFailure", "Could not recover erasure control.");
  } else if (pending.outcome == "erasureOwned") {
    struct stat current_status {};
    struct stat temp_status {};
    if (fstatat(control.get(), kErasureCurrent, &current_status, AT_SYMLINK_NOFOLLOW) != 0 ||
        fstatat(control.get(), temp.c_str(), &temp_status, AT_SYMLINK_NOFOLLOW) != 0 ||
        !same_inode(current_status, temp_status)) return result("erasureConflict", "Erasure-control identities do not match.");
  }
  if (pending.outcome == "erasureOwned" &&
      (!unlink_entry(control.get(), temp, 0, "erasure.recoverTempUnlink") ||
       !sync_fd(control.get(), "erasure.recoverTempFsync"))) return result("ioFailure", "Could not clean recovered erasure control.");
  return read_current_erasure(control.get(), owner);
}

Result clear_erasure(const std::string& platform_root, const std::string& owner, bool cleanup_only) {
  if (!opaque_id(owner)) return result("invalidRequest");
  Fd root = open_root(platform_root);
  if (!root.valid()) return unsafe_or_io("The erasure-control parent is unsafe.");
  Fd control = open_dir_at(root.get(), kErasureControl, false);
  if (!control.valid()) return errno == ENOENT ? result("erasureAbsent") : result("erasureUnsafe");
  Result current = read_current_erasure(control.get(), owner);
  if (current.outcome == "erasureConflict" || current.outcome == "erasureUnsafe") return current;
  if (!cleanup_only && current.outcome == "erasureOwned" &&
      (!unlink_entry(control.get(), kErasureCurrent, 0, "erasure.currentUnlink") ||
       !sync_fd(control.get(), "erasure.currentClearFsync"))) return result("ioFailure", "Could not clear erasure control.");
  Result failure;
  if (!remove_if_present(control.get(), erasure_temp_name(owner), 2,
                         "erasure.cleanupTempUnlink", "erasure.cleanupTempFsync", &failure)) return failure;
  if (empty_directory(control.get())) {
    if (!unlink_entry(root.get(), kErasureControl, AT_REMOVEDIR, "erasure.controlRmdir") ||
        !sync_fd(root.get(), "erasure.rootFsync")) return result("ioFailure", "Could not prune erasure-control ancestry.");
  }
  return result(cleanup_only && current.outcome == "erasureOwned" ? "erasureOwned" : "erasureAbsent");
}

Result scan(const std::string& platform_root) {
  Fd root;
  Result opened = open_attachment_root(platform_root, false, &root);
  if (opened.outcome != "available") return errno == ENOENT ? result("scanComplete") : opened;
  std::vector<std::string> root_names;
  if (!list_names(root.get(), &root_names)) return result("ioFailure", "Could not scan attachment root.");
  Result output = result("scanComplete");
  for (const std::string& root_name : root_names) {
    if (root_name == kStaging) {
      Fd staging = open_dir_at(root.get(), kStaging, false);
      if (!staging.valid()) return result("unsafeNode", "Staging is unsafe.");
      std::vector<std::string> stages;
      if (!list_names(staging.get(), &stages)) return result("ioFailure", "Could not scan staging.");
      for (const std::string& stage : stages) {
        if (stage.rfind("publication-", 0) != 0) return result("unsafeNode", "Staging contains an unexpected node.");
        struct stat status {};
        if (fstatat(staging.get(), stage.c_str(), &status, AT_SYMLINK_NOFOLLOW) != 0 ||
            !S_ISREG(status.st_mode) || status.st_nlink < 1 || status.st_nlink > 2) return result("unsafeNode", "Staging contains an unsafe node.");
        if (stage.size() > 5 && stage.substr(stage.size() - 5) == ".json") {
          PublicationState descriptor;
          Result state = read_publication_descriptor(staging.get(), stage, &descriptor);
          if (state.outcome != "publicationPending") return state;
          output.publications.push_back(descriptor);
        }
      }
      continue;
    }
    if (root_name != kArtworks) return result("unsafeNode", "Attachment root contains an unexpected node.");
    Fd artworks = open_dir_at(root.get(), kArtworks, false);
    if (!artworks.valid()) return result("unsafeNode", "Artworks is unsafe.");
    std::vector<std::string> artwork_names;
    if (!list_names(artworks.get(), &artwork_names)) return result("ioFailure", "Could not scan artworks.");
    for (const std::string& artwork_id : artwork_names) {
      if (!opaque_id(artwork_id)) return result("unsafeNode", "Artwork identifier is invalid.");
      Fd artwork = open_dir_at(artworks.get(), artwork_id, false);
      if (!artwork.valid()) return result("unsafeNode", "Artwork directory is unsafe.");
      std::vector<std::string> children;
      if (!list_names(artwork.get(), &children) || children.size() != 1 || children.front() != "attachments") return result("unsafeNode", "Artwork geometry is invalid.");
      Fd attachments = open_dir_at(artwork.get(), "attachments", false);
      if (!attachments.valid()) return result("unsafeNode", "Attachments directory is unsafe.");
      std::vector<std::string> attachment_names;
      if (!list_names(attachments.get(), &attachment_names)) return result("ioFailure", "Could not scan attachments.");
      for (const std::string& attachment_id : attachment_names) {
        if (!opaque_id(attachment_id)) return result("unsafeNode", "Attachment identifier is invalid.");
        Fd attachment = open_dir_at(attachments.get(), attachment_id, false);
        if (!attachment.valid()) return result("unsafeNode", "Attachment directory is unsafe.");
        std::vector<std::string> payloads;
        if (!list_names(attachment.get(), &payloads)) return result("ioFailure", "Could not scan payloads.");
        PublicationState claim;
        bool has_claim = false;
        for (const std::string& payload : payloads) {
          if (payload == kPublicationClaim) {
            Result state = read_publication_descriptor(attachment.get(), payload, &claim);
            if (state.outcome != "publicationPending" || claim.artwork_id != artwork_id || claim.attachment_id != attachment_id) return result("unsafeNode", "Publication claim is invalid.");
            output.publications.push_back(claim);
            has_claim = true;
            continue;
          }
          if (!canonical_name(payload)) return result("unsafeNode", "Attachment geometry is invalid.");
          struct stat status {};
          if (fstatat(attachment.get(), payload.c_str(), &status, AT_SYMLINK_NOFOLLOW) != 0 ||
              !S_ISREG(status.st_mode) || status.st_nlink != (has_claim ? 2 : 1)) return result("unsafeNode", "Canonical payload is unsafe.");
          output.entries.push_back({artwork_id, attachment_id, payload});
        }
        if (!has_claim && payloads.size() != 1) return result("unsafeNode", "Attachment geometry is not canonical.");
      }
    }
  }
  return output;
}

Result self_test(const std::string& platform_root) {
  Fd root;
  Result opened = open_attachment_root(platform_root, true, &root);
  if (opened.outcome != "available") return opened;
  const std::string suffix = random_name("probe-");
  if (suffix.empty()) return result("unsupported", "Secure random staging identifiers are unavailable.");
  const std::string file_name = suffix + ".file";
  const std::string link_name = suffix + ".link";
  const std::string symlink_name = suffix + ".symlink";
  Fd file(openat(root.get(), file_name.c_str(), O_RDWR | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0600));
  if (!file.valid() || !write_all(file.get(), "probe") || !sync_fd(file.get(), "selfTest.fileFsync") ||
      linkat(root.get(), file_name.c_str(), root.get(), link_name.c_str(), 0) != 0 ||
      !sync_fd(root.get(), "selfTest.linkFsync")) return result("unsupported", "Required descriptor-relative durability primitives are unavailable.");
  struct stat linked {};
  if (fstat(file.get(), &linked) != 0 || linked.st_nlink != 2 ||
      symlinkat(".", root.get(), symlink_name.c_str()) != 0) return result("unsupported", "Required link primitives are unavailable.");
  Fd followed = open_dir_at(root.get(), symlink_name, false);
  const int nofollow_error = errno;
  if (followed.valid() || nofollow_error != ELOOP) return result("unsupported", "No-follow traversal is unavailable.");
  if (!unlink_entry(root.get(), symlink_name, 0, "selfTest.symlinkUnlink") ||
      !unlink_entry(root.get(), link_name, 0, "selfTest.linkUnlink") ||
      !unlink_entry(root.get(), file_name, 0, "selfTest.fileUnlink") ||
      !sync_fd(root.get(), "selfTest.cleanupFsync")) return result("unsupported", "Required cleanup durability primitives are unavailable.");
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
  if (operation == "capabilities" || operation == "selfTest") return self_test(platform_root);
  if (operation == "publish") return publish(platform_root, source_path, operation_id, artwork_id, attachment_id, canonical);
  if (operation == "publicationStatus") return publication_status(platform_root, operation_id, artwork_id, attachment_id, canonical);
  if (operation == "recoverPublication") return recover_publication(platform_root, operation_id, artwork_id, attachment_id, canonical);
  if (operation == "rollbackPublication") return rollback_publication(platform_root, operation_id, artwork_id, attachment_id, canonical, false);
  if (operation == "cleanupPublication") return rollback_publication(platform_root, operation_id, artwork_id, attachment_id, canonical, true);
  if (operation == "remove") return remove_payload(platform_root, artwork_id, attachment_id, canonical);
  if (operation == "scan") return scan(platform_root);
  if (operation == "writeErasureControl") return write_erasure(platform_root, operation_id);
  if (operation == "readErasureControl") return erasure_status(platform_root, operation_id);
  if (operation == "recoverErasureControl") return recover_erasure(platform_root, operation_id);
  if (operation == "clearErasureControl") return clear_erasure(platform_root, operation_id, false);
  if (operation == "cleanupErasureControl") return clear_erasure(platform_root, operation_id, true);
  return result("invalidRequest", "Unknown custody operation.");
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
#endif
