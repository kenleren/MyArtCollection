#import <XCTest/XCTest.h>

#include "../../android/app/src/main/cpp/AttachmentCustody.cpp"

#include <filesystem>
#include <fstream>

@interface AttachmentCustodyRaceHarness : XCTestCase
@end

@implementation AttachmentCustodyRaceHarness

- (void)testLeafSymlinkSwapCannotChangeOutsideSentinel {
  const auto root = std::filesystem::temp_directory_path() / "archivale-ios-custody-race";
  const auto sentinel = root.parent_path() / "archivale-ios-custody-sentinel";
  std::filesystem::remove_all(root);
  std::filesystem::create_directories(root);
  const auto source = root / "source.pdf";
  std::ofstream(source) << "%PDF-1.4\nfixture\n%%EOF\n";
  std::ofstream(sentinel) << "unchanged";

  auto published = custody::execute(root.string(), "publish", source.string(), "artwork-001", "attachment-001", "payload.pdf");
  XCTAssertEqual(std::string("published"), published.outcome);
  const auto leaf = root / "attachments/artworks/artwork-001/attachments/attachment-001/payload.pdf";
  std::filesystem::remove(leaf);
  std::filesystem::create_symlink(sentinel, leaf);
  auto removed = custody::execute(root.string(), "remove", "", "artwork-001", "attachment-001", "payload.pdf");
  XCTAssertEqual(std::string("unsafeNode"), removed.outcome);
  std::ifstream input(sentinel);
  std::string contents;
  input >> contents;
  XCTAssertEqual(std::string("unchanged"), contents);
  std::filesystem::remove_all(root);
  std::filesystem::remove(sentinel);
}

@end
