import Foundation
var failures: [String] = []
func fail(_ message: String, file: StaticString = #file, line: UInt = #line) { failures.append("\(file):\(line): " + message) }
func expectEqual<T: Equatable>(_ a: T, _ b: T, file: StaticString = #file, line: UInt = #line) {
    if a != b { fail("Values differ", file: file, line: line) }
}
func expectEqual(_ a: Double, _ b: Double, accuracy: Double, file: StaticString = #file, line: UInt = #line) {
    if abs(a-b) > accuracy { fail("Values differ", file: file, line: line) }
}
func expectTrue(_ value: Bool, file: StaticString = #file, line: UInt = #line) { if !value { fail("Expected true", file: file, line: line) } }
func expectFalse(_ value: Bool, file: StaticString = #file, line: UInt = #line) { expectTrue(!value, file: file, line: line) }
func expectNil(_ value: Any?, file: StaticString = #file, line: UInt = #line) { expectTrue(value == nil, file: file, line: line) }
func expectNotNil(_ value: Any?, file: StaticString = #file, line: UInt = #line) { expectTrue(value != nil, file: file, line: line) }
func expectLess(_ a: Double, _ b: Double, file: StaticString = #file, line: UInt = #line) { expectTrue(a < b, file: file, line: line) }
func expectError(_ action: @autoclosure () throws -> Any, file: StaticString = #file, line: UInt = #line) {
    do { _ = try action(); fail("Expected an error", file: file, line: line) } catch {}
}
let test = CoreTests()
let cases: [(String, () throws -> Void)] = [
    ("testCachePrivatePermissions", test.testCachePrivatePermissions),
    ("testPartialQuotaPreservesPreviousWeekAndContext", test.testPartialQuotaPreservesPreviousWeekAndContext),
    ("testMissingFiveHourCannotBecomeFresh", test.testMissingFiveHourCannotBecomeFresh),
    ("testConcurrentMergesDoNotLoseFields", test.testConcurrentMergesDoNotLoseFields),
    ("testMalformedCacheDoesNotCrash", test.testMalformedCacheDoesNotCrash),
    ("testFiniteNumbersOnly", test.testFiniteNumbersOnly),
    ("testWindowNormalizationAndReset", test.testWindowNormalizationAndReset),
    ("testFiveHourPreferredWhenFresh", test.testFiveHourPreferredWhenFresh),
    ("testCachedWeekReplacesExpiredFiveHour", test.testCachedWeekReplacesExpiredFiveHour),
    ("testUnknownQuotaNeverAppearsAsFull", test.testUnknownQuotaNeverAppearsAsFull),
    ("testCacheOnlyReadNeverReadsCredentialsOrNetwork", test.testCacheOnlyReadNeverReadsCredentialsOrNetwork),
    ("testProviderFailureIsIsolated", test.testProviderFailureIsIsolated),
    ("testExpiredClaudeNeverMakesHTTPRequestOrChangesCredential", test.testExpiredClaudeNeverMakesHTTPRequestOrChangesCredential),
    ("testClaudeGETPreservesContextAndCredits", test.testClaudeGETPreservesContextAndCredits),
    ("testClaude429DoesNotInventExhaustedQuota", test.testClaude429DoesNotInventExhaustedQuota),
    ("testCodexSelectsOnlyCodexBucket", test.testCodexSelectsOnlyCodexBucket),
    ("testWrongCodexBucketFailsClosed", test.testWrongCodexBucketFailsClosed),
    ("testRouterRejectsDuplicateSlots", test.testRouterRejectsDuplicateSlots),
    ("testRouterSourceChangeResetsDailyBaseline", test.testRouterSourceChangeResetsDailyBaseline),
    ("testRouterSameSourceKeepsDailyBaseline", test.testRouterSameSourceKeepsDailyBaseline),
    ("testRouterFallbackAndBalance", test.testRouterFallbackAndBalance),
    ("testStatuslinePreservesBurnGuardContext", test.testStatuslinePreservesBurnGuardContext),
    ("testHookMigrationPreservesUnrelatedCommands", test.testHookMigrationPreservesUnrelatedCommands),
    ("testRPCFramingAndEOF", test.testRPCFramingAndEOF),
    ("testProcessTimeoutIsBounded", test.testProcessTimeoutIsBounded),
    ("testRetainedTariffUsesUncachedAndOutput", test.testRetainedTariffUsesUncachedAndOutput),
    ("testCachedInputIsNotChargedTwice", test.testCachedInputIsNotChargedTwice),
    ("testBatchAndFlexDiscount", test.testBatchAndFlexDiscount),
    ("testLongContextConservativeAggregation", test.testLongContextConservativeAggregation),
    ("testUnsupportedAccountingFailsClosed", test.testUnsupportedAccountingFailsClosed),
    ("testCreditReconciliationUsesGreaterSpendAndMemoizesCredential", test.testCreditReconciliationUsesGreaterSpendAndMemoizesCredential),
    ("testPaginationCycleRejected", test.testPaginationCycleRejected)
]
for (name, action) in cases {
    do { try test.setUpWithError(); try action() } catch { fail(name + ": " + error.localizedDescription) }
    do { try test.tearDownWithError() } catch { fail(name + ": cleanup failed") }
}
if !failures.isEmpty { for message in failures { print(message) }; exit(1) }
print("\(cases.count) native Swift core checks passed")
