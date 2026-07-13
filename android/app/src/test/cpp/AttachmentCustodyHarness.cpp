#include "../../main/cpp/AttachmentCustody.cpp"

#include <cassert>
#include <filesystem>
#include <fstream>

int main() {
  const auto root = std::filesystem::temp_directory_path() / "archivale-custody-harness";
  std::filesystem::remove_all(root);
  std::filesystem::create_directories(root);
  const auto source = root / "import.pdf";
  std::ofstream(source) << "%PDF-1.4\nfixture\n%%EOF\n";
  const auto sentinel = root.parent_path() / "archivale-custody-sentinel";
  std::ofstream(sentinel) << "unchanged";

  auto published = custody::execute(root.string(), "publish", source.string(), "artwork-001", "attachment-001", "payload.pdf");
  assert(published.outcome == "published");
  auto scanned = custody::execute(root.string(), "scan", "", "", "", "");
  assert(scanned.outcome == "scanComplete" && scanned.entries.size() == 1);

  const auto attachment_dir = root / "attachments/artworks/artwork-001/attachments/attachment-001";
  std::filesystem::remove(attachment_dir / "payload.pdf");
  std::filesystem::create_symlink(sentinel, attachment_dir / "payload.pdf");
  auto raced = custody::execute(root.string(), "remove", "", "artwork-001", "attachment-001", "payload.pdf");
  assert(raced.outcome == "unsafeNode");
  std::ifstream sentinel_input(sentinel);
  std::string sentinel_contents;
  sentinel_input >> sentinel_contents;
  assert(sentinel_contents == "unchanged");

  auto marked = custody::execute(root.string(), "writeWholeStoreMarker", "", "erase-001", "", "");
  assert(marked.outcome == "markerPresent");
  auto cleared = custody::execute(root.string(), "clearWholeStoreMarker", "", "erase-001", "", "");
  assert(cleared.outcome == "markerAbsent");
  std::filesystem::remove_all(root);
  std::filesystem::remove(sentinel);
}
