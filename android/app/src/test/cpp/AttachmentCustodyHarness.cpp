#define ATTACHMENT_CUSTODY_TESTING
#include "../../main/cpp/AttachmentCustody.cpp"
#include "AttachmentCustodyTestSuite.hpp"

#include <iostream>
#include <string_view>

// Fixed exit codes expose the failed synthetic assertion without printing paths,
// file contents, sanitizer output, or other diagnostic text in CI.
constexpr int race_failure_code(std::string_view failure) {
  constexpr std::array<std::string_view, 12> failures = {
      "race setup publication failed",
      "leaf symlink/hard-link/rename race changed sentinel identity, bytes, or hash",
      "leaf race changed sentinel after join",
      "intermediate race setup publication failed",
      "intermediate swap race changed sentinel identity, bytes, or hash",
      "intermediate race changed sentinel after join",
      "export leaf swap race opened outside payload",
      "export leaf swap race changed outside sentinel",
      "export leaf swap race changed outside sentinel after join",
      "export intermediate swap race opened outside payload",
      "export intermediate swap race changed outside sentinel",
      "export intermediate swap race changed outside sentinel after join",
  };
  for (size_t index = 0; index < failures.size(); ++index) {
    if (failure == failures[index]) return 80 + static_cast<int>(index);
  }
  return 65;
}
static_assert(race_failure_code("export leaf swap race opened outside payload") == 86);
static_assert(race_failure_code("export intermediate swap race opened outside payload") == 89);
static_assert(race_failure_code("unrecognized assertion") == 65);

int main(int argc, char** argv) {
  if (argc != 3 || std::string(argv[1]) != "--suite") return 64;
  const std::string suite = argv[2];
  const std::string failure = suite == "contract" ? custody_test::run_contract_suite()
                              : suite == "race" ? custody_test::race_tests()
                              : "invalid suite";
  if (!failure.empty()) {
    std::cerr << failure << '\n';
    if (suite == "race") return race_failure_code(failure);
    return suite == "contract" ? 65 : 64;
  }
  return 0;
}
