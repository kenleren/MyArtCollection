#import <XCTest/XCTest.h>

#define ATTACHMENT_CUSTODY_TESTING
#include "../../android/app/src/main/cpp/AttachmentCustody.cpp"
#include "../../android/app/src/test/cpp/AttachmentCustodyTestSuite.hpp"

@interface AttachmentCustodyRaceHarness : XCTestCase
@end

@implementation AttachmentCustodyRaceHarness

- (void)testCrashRecoveryRetryConcurrencyAndNegativeContracts {
  const std::string failure = custody_test::run_contract_suite();
  XCTAssertTrue(failure.empty(), @"%s", failure.c_str());
}

- (void)testRepeatedLeafAndIntermediateSwapRacesPreserveSentinel {
  const std::string failure = custody_test::race_tests();
  XCTAssertTrue(failure.empty(), @"%s", failure.c_str());
}

@end
