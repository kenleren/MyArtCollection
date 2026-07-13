#include <cerrno>
#include <cstring>
#include <dirent.h>
#include <fcntl.h>
#include <sys/stat.h>
#include <sys/syscall.h>
#include <sys/types.h>
#include <unistd.h>

#include <array>
#include <cctype>
#include <cstdlib>
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
constexpr char kMarker[] = ".attachment-custody-erasure.marker";

struct Entry {
  std::string artwork_id;
  std::string attachment_id;
  std::string canonical_name;
};

struct Result {
  std::string outcome;
  std::string detail;
  std::vector<Entry> entries;
};

class Fd {
 public:
  explicit Fd(int value = -1) : value_(value) {}
  ~Fd() { if (value_ >= 0) close(value_); }
  Fd(const Fd&) = delete;
  Fd& operator=(const Fd&) = delete;
  Fd(Fd&& other) noexcept : value_(std::exchange(other.value_, -1)) {}
  Fd& operator=(Fd&& other) noexcept {
    if (this != &other) { if (value_ >= 0) close(value_); value_ = std::exchange(other.value_, -1); }
    return *this;
  }
  int get() const { return value_; }
  bool valid() const { return value_ >= 0; }
 private:
  int value_;
};

bool opaque_id(const std::string& value) {
  if (value.empty() || value.size() > 128) return false;
  const auto first = static_cast<unsigned char>(value.front());
  if (!std::isalnum(first)) return false;
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

Result result(std::string outcome, std::string detail = {}) {
  return Result{std::move(outcome), std::move(detail), {}};
}

bool regular_single_link_at(int parent, const std::string& name) {
  struct stat status {};
  if (fstatat(parent, name.c_str(), &status, AT_SYMLINK_NOFOLLOW) != 0) return false;
  return S_ISREG(status.st_mode) && status.st_nlink == 1;
}

Fd open_dir_at(int parent, const std::string& name, bool create) {
  struct stat status {};
  if (fstatat(parent, name.c_str(), &status, AT_SYMLINK_NOFOLLOW) != 0) {
    if (!create || errno != ENOENT || mkdirat(parent, name.c_str(), 0700) != 0) return Fd();
    if (fstatat(parent, name.c_str(), &status, AT_SYMLINK_NOFOLLOW) != 0) return Fd();
  }
  if (!S_ISDIR(status.st_mode)) { errno = ELOOP; return Fd(); }
  const int child = openat(parent, name.c_str(), O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW);
  if (child < 0) return Fd();
  struct stat opened {};
  if (fstat(child, &opened) != 0 || !S_ISDIR(opened.st_mode)) { close(child); errno = ELOOP; return Fd(); }
  return Fd(child);
}

Fd open_platform_root(const std::string& flutter_root, bool create_attachments) {
  const int root = open(flutter_root.c_str(), O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW);
  if (root < 0) return Fd();
  Fd flutter(root);
  return open_dir_at(flutter.get(), kAttachments, create_attachments);
}

bool fsync_dir(int fd) { return fsync(fd) == 0; }

bool empty_directory(int fd) {
  const int copy = dup(fd);
  if (copy < 0) return false;
  DIR* dir = fdopendir(copy);
  if (dir == nullptr) { close(copy); return false; }
  bool empty = true;
  while (dirent* entry = readdir(dir)) {
    if (std::strcmp(entry->d_name, ".") != 0 && std::strcmp(entry->d_name, "..") != 0) { empty = false; break; }
  }
  closedir(dir);
  return empty;
}

bool list_names(int fd, std::vector<std::string>* names) {
  const int copy = dup(fd);
  if (copy < 0) return false;
  DIR* dir = fdopendir(copy);
  if (dir == nullptr) { close(copy); return false; }
  errno = 0;
  while (dirent* entry = readdir(dir)) {
    if (std::strcmp(entry->d_name, ".") != 0 && std::strcmp(entry->d_name, "..") != 0) names->emplace_back(entry->d_name);
  }
  const bool ok = errno == 0;
  closedir(dir);
  return ok;
}

Result unsafe_or_io(const char* detail) {
  return result(errno == ELOOP || errno == ENOTDIR || errno == EMLINK ? "unsafeNode" : "ioFailure", detail);
}

bool target_valid(const std::string& artwork, const std::string& attachment, const std::string& name) {
  return opaque_id(artwork) && opaque_id(attachment) && canonical_name(name);
}

struct TargetDirs { Fd root; Fd artworks; Fd artwork; Fd attachments; Fd attachment; };

Result open_target(const std::string& flutter_root, const std::string& artwork_id,
                   const std::string& attachment_id, bool create, TargetDirs* dirs) {
  dirs->root = open_platform_root(flutter_root, create);
  if (!dirs->root.valid()) return unsafe_or_io("The app-private attachment root is unsafe or unavailable.");
  dirs->artworks = open_dir_at(dirs->root.get(), kArtworks, create);
  if (!dirs->artworks.valid()) return unsafe_or_io("The canonical artworks directory is unsafe.");
  dirs->artwork = open_dir_at(dirs->artworks.get(), artwork_id, create);
  if (!dirs->artwork.valid()) return unsafe_or_io("The canonical artwork directory is unsafe.");
  dirs->attachments = open_dir_at(dirs->artwork.get(), "attachments", create);
  if (!dirs->attachments.valid()) return unsafe_or_io("The canonical attachments directory is unsafe.");
  dirs->attachment = open_dir_at(dirs->attachments.get(), attachment_id, create);
  if (!dirs->attachment.valid()) return unsafe_or_io("The canonical attachment directory is unsafe.");
  return result("available");
}

std::string stage_name() {
  std::array<unsigned char, 16> bytes{};
#if defined(__APPLE__)
  arc4random_buf(bytes.data(), bytes.size());
#elif defined(SYS_getrandom)
  if (syscall(SYS_getrandom, bytes.data(), bytes.size(), 0) != static_cast<long>(bytes.size())) {
    return {};
  }
#else
  return {};
#endif
  static constexpr char hex[] = "0123456789abcdef";
  std::string name = "stage-";
  for (unsigned char byte : bytes) { name.push_back(hex[byte >> 4]); name.push_back(hex[byte & 0x0f]); }
  return name;
}

bool copy_to_fd(int source, int destination) {
  std::array<char, 65536> buffer{};
  while (true) {
    const ssize_t read_count = read(source, buffer.data(), buffer.size());
    if (read_count == 0) return true;
    if (read_count < 0) return false;
    for (ssize_t offset = 0; offset < read_count;) {
      const ssize_t written = write(destination, buffer.data() + offset, static_cast<size_t>(read_count - offset));
      if (written <= 0) return false;
      offset += written;
    }
  }
}

Result publish(const std::string& flutter_root, const std::string& source_path,
               const std::string& artwork_id, const std::string& attachment_id, const std::string& name) {
  if (!target_valid(artwork_id, attachment_id, name) || source_path.empty()) return result("invalidRequest", "Invalid custody publication request.");
  const int source_raw = open(source_path.c_str(), O_RDONLY | O_CLOEXEC | O_NOFOLLOW);
  if (source_raw < 0) return result(errno == ENOENT ? "sourceMissing" : "unsafeNode", "The import source is unavailable or unsafe.");
  Fd source(source_raw);
  struct stat source_status {};
  if (fstat(source.get(), &source_status) != 0 || !S_ISREG(source_status.st_mode) || source_status.st_nlink != 1) return result("unsafeNode", "The import source is not a safe regular file.");

  TargetDirs target;
  Result opened = open_target(flutter_root, artwork_id, attachment_id, true, &target);
  if (opened.outcome != "available") return opened;
  if (!empty_directory(target.attachment.get())) return result("alreadyExists", "The canonical attachment directory is not empty.");
  Fd staging = open_dir_at(target.root.get(), kStaging, true);
  if (!staging.valid()) return unsafe_or_io("The staging directory is unsafe.");
  const std::string staged = stage_name();
  if (staged.empty()) return result("unsupported", "Secure native staging names are unavailable.");
  const int staged_raw = openat(staging.get(), staged.c_str(), O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0600);
  if (staged_raw < 0) return unsafe_or_io("Could not create the private staging file.");
  Fd staged_fd(staged_raw);
  if (!copy_to_fd(source.get(), staged_fd.get()) || fsync(staged_fd.get()) != 0 || !fsync_dir(staging.get())) {
    unlinkat(staging.get(), staged.c_str(), 0); fsync_dir(staging.get());
    return result("ioFailure", "Could not durably stage the attachment.");
  }
#if defined(SYS_renameat2)
  const long renamed = syscall(SYS_renameat2, staging.get(), staged.c_str(), target.attachment.get(), name.c_str(), 1 /* RENAME_NOREPLACE */);
  if (renamed != 0) {
    const int error = errno;
    if (error == EEXIST) return result("alreadyExists", "The canonical payload already exists.");
    if (error == ENOSYS || error == EINVAL) {
      if (linkat(staging.get(), staged.c_str(), target.attachment.get(), name.c_str(), 0) != 0) {
        const int link_error = errno;
        unlinkat(staging.get(), staged.c_str(), 0); fsync_dir(staging.get());
        return link_error == EEXIST ? result("alreadyExists", "The canonical payload already exists.") : result("ioFailure", "Exclusive no-replace publication failed.");
      }
      if (!fsync_dir(target.attachment.get()) || unlinkat(staging.get(), staged.c_str(), 0) != 0 || !fsync_dir(staging.get())) return result("ioFailure", "The attachment publication was not durably confirmed.");
      return result("published");
    }
    unlinkat(staging.get(), staged.c_str(), 0); fsync_dir(staging.get());
    errno = error; return unsafe_or_io("Could not publish the attachment.");
  }
#else
  if (linkat(staging.get(), staged.c_str(), target.attachment.get(), name.c_str(), 0) != 0) {
    const int error = errno;
    unlinkat(staging.get(), staged.c_str(), 0); fsync_dir(staging.get());
    return error == EEXIST ? result("alreadyExists", "The canonical payload already exists.") : result("ioFailure", "Exclusive no-replace publication failed.");
  }
  if (!fsync_dir(target.attachment.get()) || unlinkat(staging.get(), staged.c_str(), 0) != 0 || !fsync_dir(staging.get())) return result("ioFailure", "The attachment publication was not durably confirmed.");
  return result("published");
#endif
  if (!fsync_dir(target.attachment.get()) || !fsync_dir(staging.get())) return result("ioFailure", "The attachment publication was not durably confirmed.");
  return result("published");
}

Result remove_payload(const std::string& flutter_root, const std::string& artwork_id,
                      const std::string& attachment_id, const std::string& name) {
  if (!target_valid(artwork_id, attachment_id, name)) return result("invalidRequest", "Invalid custody removal request.");
  TargetDirs target;
  Result opened = open_target(flutter_root, artwork_id, attachment_id, false, &target);
  if (opened.outcome != "available") {
    return errno == ENOENT ? result("missing") : opened;
  }
  struct stat status {};
  if (fstatat(target.attachment.get(), name.c_str(), &status, AT_SYMLINK_NOFOLLOW) != 0) {
    return errno == ENOENT ? result("missing") : unsafe_or_io("Could not inspect the canonical payload.");
  }
  if (!S_ISREG(status.st_mode) || status.st_nlink != 1) return result("unsafeNode", "The canonical payload is not a safe regular file.");
  if (unlinkat(target.attachment.get(), name.c_str(), 0) != 0 || !fsync_dir(target.attachment.get())) return unsafe_or_io("Could not remove the canonical payload.");
  if (empty_directory(target.attachment.get())) { unlinkat(target.attachments.get(), attachment_id.c_str(), AT_REMOVEDIR); fsync_dir(target.attachments.get()); }
  return result("removed");
}

Result scan(const std::string& flutter_root) {
  Fd root = open_platform_root(flutter_root, false);
  if (!root.valid()) return errno == ENOENT ? result("scanComplete") : unsafe_or_io("The attachment root is unsafe or unavailable.");
  std::vector<std::string> root_names;
  if (!list_names(root.get(), &root_names)) return result("ioFailure", "Could not scan attachment root.");
  Result output = result("scanComplete");
  for (const std::string& root_name : root_names) {
    if (root_name == kStaging) {
      Fd staging = open_dir_at(root.get(), kStaging, false);
      if (!staging.valid()) return result("unsafeNode", "Staging is not a safe directory.");
      std::vector<std::string> stages;
      if (!list_names(staging.get(), &stages)) return result("ioFailure", "Could not scan staging.");
      for (const auto& stage : stages) {
        struct stat status {};
        if (stage.rfind("stage-", 0) != 0 || fstatat(staging.get(), stage.c_str(), &status, AT_SYMLINK_NOFOLLOW) != 0 || !S_ISREG(status.st_mode) || status.st_nlink < 1 || status.st_nlink > 2) return result("unsafeNode", "Staging contains an unsafe node.");
      }
      continue;
    }
    if (root_name != kArtworks) return result("unsafeNode", "Attachment root contains an unexpected node.");
    Fd artworks = open_dir_at(root.get(), kArtworks, false);
    if (!artworks.valid()) return result("unsafeNode", "Artworks is not a safe directory.");
    std::vector<std::string> artwork_names;
    if (!list_names(artworks.get(), &artwork_names)) return result("ioFailure", "Could not scan artworks.");
    for (const auto& artwork_id : artwork_names) {
      if (!opaque_id(artwork_id)) return result("unsafeNode", "Artworks contains an invalid node.");
      Fd artwork = open_dir_at(artworks.get(), artwork_id, false);
      if (!artwork.valid()) return result("unsafeNode", "Artwork node is unsafe.");
      std::vector<std::string> artwork_children;
      if (!list_names(artwork.get(), &artwork_children) || artwork_children.size() != 1 || artwork_children.front() != "attachments") return result("unsafeNode", "Artwork geometry is not canonical.");
      Fd attachments = open_dir_at(artwork.get(), "attachments", false);
      if (!attachments.valid()) return result("unsafeNode", "Attachments directory is unsafe.");
      std::vector<std::string> attachment_names;
      if (!list_names(attachments.get(), &attachment_names)) return result("ioFailure", "Could not scan attachments.");
      for (const auto& attachment_id : attachment_names) {
        if (!opaque_id(attachment_id)) return result("unsafeNode", "Attachment node is invalid.");
        Fd attachment = open_dir_at(attachments.get(), attachment_id, false);
        if (!attachment.valid()) return result("unsafeNode", "Attachment node is unsafe.");
        std::vector<std::string> payloads;
        if (!list_names(attachment.get(), &payloads) || payloads.size() != 1 || !canonical_name(payloads.front())) return result("unsafeNode", "Attachment geometry is not canonical.");
        if (!regular_single_link_at(attachment.get(), payloads.front())) return result("unsafeNode", "Canonical payload is unsafe.");
        output.entries.push_back({artwork_id, attachment_id, payloads.front()});
      }
    }
  }
  return output;
}

Result marker(const std::string& flutter_root, const std::string& operation, const std::string& operation_id) {
  if ((operation == "write" || operation == "clear") && !opaque_id(operation_id)) return result("invalidRequest", "Invalid whole-store operation identifier.");
  const int raw = open(flutter_root.c_str(), O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW);
  if (raw < 0) return unsafe_or_io("The marker parent is unsafe or unavailable.");
  Fd root(raw);
  if (operation == "read") {
    struct stat status {};
    if (fstatat(root.get(), kMarker, &status, AT_SYMLINK_NOFOLLOW) != 0) return errno == ENOENT ? result("markerAbsent") : unsafe_or_io("Could not inspect the whole-store marker.");
    return (S_ISREG(status.st_mode) && status.st_nlink == 1) ? result("markerPresent") : result("unsafeNode", "The whole-store marker is unsafe.");
  }
  if (operation == "write") {
    const int marker_fd = openat(root.get(), kMarker, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0600);
    if (marker_fd < 0) return errno == EEXIST ? result("markerPresent") : unsafe_or_io("Could not create the whole-store marker.");
    Fd file(marker_fd);
    const std::string content = operation_id + "\n";
    if (write(file.get(), content.data(), content.size()) != static_cast<ssize_t>(content.size()) || fsync(file.get()) != 0 || !fsync_dir(root.get())) return result("ioFailure", "Could not durably persist the whole-store marker.");
    return result("markerPresent");
  }
  const int marker_fd = openat(root.get(), kMarker, O_RDONLY | O_CLOEXEC | O_NOFOLLOW);
  if (marker_fd < 0) return errno == ENOENT ? result("markerAbsent") : unsafe_or_io("Could not open the whole-store marker.");
  Fd file(marker_fd);
  struct stat status {};
  if (fstat(file.get(), &status) != 0 || !S_ISREG(status.st_mode) || status.st_nlink != 1 || status.st_size > 130) return result("unsafeNode", "The whole-store marker is unsafe.");
  std::array<char, 131> bytes{};
  const ssize_t count = read(file.get(), bytes.data(), bytes.size());
  if (count < 0 || std::string(bytes.data(), static_cast<size_t>(count)) != operation_id + "\n") return result("markerPresent", "A different whole-store operation owns the marker.");
  if (unlinkat(root.get(), kMarker, 0) != 0 || !fsync_dir(root.get())) return unsafe_or_io("Could not clear the whole-store marker.");
  return result("markerAbsent");
}

Result self_test(const std::string& flutter_root) {
  Fd root = open_platform_root(flutter_root, true);
  if (!root.valid()) return unsafe_or_io("The attachment root is unsafe or unavailable.");
  const std::string probe = ".custody-selftest-link";
  unlinkat(root.get(), probe.c_str(), 0);
  if (symlinkat(".", root.get(), probe.c_str()) != 0) return result("ioFailure", "Could not create the native no-follow self-test.");
  Fd followed = open_dir_at(root.get(), probe, false);
  const int error = errno;
  unlinkat(root.get(), probe.c_str(), 0);
  if (followed.valid() || error != ELOOP) return result("unsupported", "Descriptor-relative no-follow traversal is unavailable.");
  const std::string probe_stage = stage_name();
  if (probe_stage.empty()) return result("unsupported", "Secure native staging names are unavailable.");
  return result("available");
}

std::string json_escape(const std::string& value) {
  std::string output;
  for (char ch : value) { if (ch == '"' || ch == '\\') output.push_back('\\'); if (ch >= 0x20) output.push_back(ch); }
  return output;
}

std::string to_json(const Result& value) {
  std::ostringstream out;
  out << "{\"outcome\":\"" << json_escape(value.outcome) << "\"";
  if (!value.detail.empty()) out << ",\"detail\":\"" << json_escape(value.detail) << "\"";
  if (!value.entries.empty()) {
    out << ",\"entries\":[";
    for (size_t i = 0; i < value.entries.size(); ++i) { const auto& entry = value.entries[i]; if (i) out << ','; out << "{\"artworkId\":\"" << json_escape(entry.artwork_id) << "\",\"attachmentId\":\"" << json_escape(entry.attachment_id) << "\",\"canonicalName\":\"" << json_escape(entry.canonical_name) << "\"}"; }
    out << ']';
  }
  out << '}';
  return out.str();
}

Result execute(const std::string& flutter_root, const std::string& operation, const std::string& source_path,
               const std::string& artwork_id, const std::string& attachment_id, const std::string& canonical) {
  if (operation == "capabilities") return self_test(flutter_root);
  if (operation == "selfTest") return self_test(flutter_root);
  if (operation == "publish") return publish(flutter_root, source_path, artwork_id, attachment_id, canonical);
  if (operation == "remove") return remove_payload(flutter_root, artwork_id, attachment_id, canonical);
  if (operation == "scan") return scan(flutter_root);
  if (operation == "writeWholeStoreMarker") return marker(flutter_root, "write", artwork_id);
  if (operation == "readWholeStoreMarker") return marker(flutter_root, "read", "");
  if (operation == "clearWholeStoreMarker") return marker(flutter_root, "clear", artwork_id);
  return result("invalidRequest", "Unknown custody operation.");
}

}  // namespace custody

#ifdef __ANDROID__
namespace {
std::string from_jstring(JNIEnv* env, jstring value) {
  if (value == nullptr) return {};
  const char* chars = env->GetStringUTFChars(value, nullptr);
  if (chars == nullptr) return {};
  std::string result(chars);
  env->ReleaseStringUTFChars(value, chars);
  return result;
}
}

extern "C" JNIEXPORT jstring JNICALL
Java_app_archivale_AttachmentCustodyNative_execute(JNIEnv* env, jobject, jstring root, jstring operation,
                                                    jstring source, jstring artwork, jstring attachment, jstring name) {
  const auto output = custody::to_json(custody::execute(from_jstring(env, root), from_jstring(env, operation),
      from_jstring(env, source), from_jstring(env, artwork), from_jstring(env, attachment), from_jstring(env, name)));
  return env->NewStringUTF(output.c_str());
}
#endif
