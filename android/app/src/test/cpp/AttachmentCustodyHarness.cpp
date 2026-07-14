#define ATTACHMENT_CUSTODY_TESTING
#include "../../main/cpp/AttachmentCustody.cpp"
#include "AttachmentCustodyTestSuite.hpp"

#include <iostream>

int main() {
  const std::string contract_failure = custody_test::run_contract_suite();
  if (!contract_failure.empty()) {
    std::cerr << contract_failure << '\n';
    return 1;
  }
  const std::string race_failure = custody_test::race_tests();
  if (!race_failure.empty()) {
    std::cerr << race_failure << '\n';
    return 1;
  }
  return 0;
}
