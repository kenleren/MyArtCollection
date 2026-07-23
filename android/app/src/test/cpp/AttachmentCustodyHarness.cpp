#define ATTACHMENT_CUSTODY_TESTING
#include "../../main/cpp/AttachmentCustody.cpp"
#include "AttachmentCustodyTestSuite.hpp"

#include <iostream>

int main(int argc, char** argv) {
  if (argc != 3 || std::string(argv[1]) != "--suite") return 1;
  const std::string suite = argv[2];
  const std::string failure = suite == "contract" ? custody_test::run_contract_suite()
                              : suite == "race" ? custody_test::race_tests()
                                                : "invalid suite";
  if (!failure.empty()) {
    std::cerr << failure << '\n';
    return 1;
  }
  return 0;
}
