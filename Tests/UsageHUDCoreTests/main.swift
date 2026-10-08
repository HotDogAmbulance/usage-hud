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
    ("testLiteLLMModelBudgetsRequireReportedUsage", test.testLiteLLMModelBudgetsRequireReportedUsage),
    ("testModelListChangesReplaceCachedModels", test.testModelListChangesReplaceCachedModels),
    ("testCachedReadingsRecoverWithoutInventingQuota", test.testCachedReadingsRecoverWithoutInventingQuota),
    ("testOpenAICreditFreshnessAndManualRecovery", test.testOpenAICreditFreshnessAndManualRecovery),
    ("testKeyPeriodsAndCachedWarnings", test.testKeyPeriodsAndCachedWarnings),
    ("testAntigravityModelQuotaAndPrivateCache", test.testAntigravityModelQuotaAndPrivateCache),
    ("testAntigravityUnavailableKeepsLastReading", test.testAntigravityUnavailableKeepsLastReading),
    ("testAntigravityRejectsInvalidQuotaAndParsesFlags", test.testAntigravityRejectsInvalidQuotaAndParsesFlags),
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
    ("testClaude429BacksOffInsteadOfAskingAgain", test.testClaude429BacksOffInsteadOfAskingAgain),
    ("testCodexSelectsOnlyCodexBucket", test.testCodexSelectsOnlyCodexBucket),
    ("testWrongCodexBucketFailsClosed", test.testWrongCodexBucketFailsClosed),
    ("testProUsesWeeklyWindowInsteadOfOldFiveHour", test.testProUsesWeeklyWindowInsteadOfOldFiveHour),
    ("testWeeklyPrimaryIsNotMislabelledFiveHour", test.testWeeklyPrimaryIsNotMislabelledFiveHour),
    ("testPurchasedCodexCreditsAreNotDollars", test.testPurchasedCodexCreditsAreNotDollars),
    ("testCreditOnlyCodexResponseDoesNotInventQuota", test.testCreditOnlyCodexResponseDoesNotInventQuota),
    ("testRouterRejectsDuplicateSlots", test.testRouterRejectsDuplicateSlots),
    ("testRouterSourceChangeResetsDailyBaseline", test.testRouterSourceChangeResetsDailyBaseline),
    ("testRouterSameSourceKeepsDailyBaseline", test.testRouterSameSourceKeepsDailyBaseline),
    ("testRouterFallbackAndBalance", test.testRouterFallbackAndBalance),
    ("testStatuslinePreservesBurnGuardContext", test.testStatuslinePreservesBurnGuardContext),
    ("testClaudeCodeConnectsAndDisconnectsCleanly", test.testClaudeCodeConnectsAndDisconnectsCleanly),
    ("testFreeResetsAndPrepaidBalance", test.testFreeResetsAndPrepaidBalance),
    ("testMalformedSignInAndExtremeProviderNumbers", test.testMalformedSignInAndExtremeProviderNumbers),
    ("testHTTPRejectsRedirectAndBoundsStreamingBody", test.testHTTPRejectsRedirectAndBoundsStreamingBody),
    ("testOutageDoesNotPulseCachedLowBalance", test.testOutageDoesNotPulseCachedLowBalance),
    ("testLiteLLMCredentialsStayWithTheirSource", test.testLiteLLMCredentialsStayWithTheirSource),
    ("testRPCFramingAndEOF", test.testRPCFramingAndEOF),
    ("testProcessTimeoutIsBounded", test.testProcessTimeoutIsBounded),
    ("testRetainedTariffUsesUncachedAndOutput", test.testRetainedTariffUsesUncachedAndOutput),
    ("testCachedInputIsNotChargedTwice", test.testCachedInputIsNotChargedTwice),
    ("testBatchAndFlexDiscount", test.testBatchAndFlexDiscount),
    ("testLongContextConservativeAggregation", test.testLongContextConservativeAggregation),
    ("testUnsupportedAccountingFailsClosed", test.testUnsupportedAccountingFailsClosed),
    ("testCreditReconciliationUsesGreaterSpendAndMemoizesCredential", test.testCreditReconciliationUsesGreaterSpendAndMemoizesCredential),
    ("testPaginationCycleRejected", test.testPaginationCycleRejected),
    ("testGLMCreditWindowsBecomeFiveHourAndWeek", test.testGLMCreditWindowsBecomeFiveHourAndWeek),
    ("testGLMLegacyTokensLimitIsFiveHour", test.testGLMLegacyTokensLimitIsFiveHour),
    ("testGLMSendsRawKeyAndTriesMainlandHost", test.testGLMSendsRawKeyAndTriesMainlandHost),
    ("testGrokCreditsFromTheCLISignIn", test.testGrokCreditsFromTheCLISignIn),
    ("testGrokBotUsageFromItsSavedReading", test.testGrokBotUsageFromItsSavedReading),
    ("testKeysAreNamedAfterTheirBootAndChangesAreAnnounced", test.testKeysAreNamedAfterTheirBootAndChangesAreAnnounced),
    ("testRenamedBootsAreFollowedAndRenamesStayQuiet", test.testRenamedBootsAreFollowedAndRenamesStayQuiet),
    ("testKimiCodeWindowsAndPlan", test.testKimiCodeWindowsAndPlan),
    ("testKimiCodeFindsKimiCLIKey", test.testKimiCodeFindsKimiCLIKey),
    ("testXAIBillingFromAManagementKey", test.testXAIBillingFromAManagementKey),
    ("testFireworksSpendAgainstTheMonthlyLimit", test.testFireworksSpendAgainstTheMonthlyLimit),
    ("testLiteLLMBudgetAndOtherGateways", test.testLiteLLMBudgetAndOtherGateways),
    ("testReviewFixesForNewReaders", test.testReviewFixesForNewReaders),
    ("testOpenRouterBalanceLevelsAndGauge", test.testOpenRouterBalanceLevelsAndGauge),
    ("testAntigravityBatteryFollowsTheLastUsedPool", test.testAntigravityBatteryFollowsTheLastUsedPool),
    ("testUnusedPlansStayOutOfMenuBar", test.testUnusedPlansStayOutOfMenuBar),
    ("testBalanceParsers", test.testBalanceParsers),
    ("testKeyProviderFallsBackToSecondHostAndShowsMoney", test.testKeyProviderFallsBackToSecondHostAndShowsMoney),
    ("testShelfKeepsMostRecentlyUsedBatteries", test.testShelfKeepsMostRecentlyUsedBatteries),
    ("testClaudeExtraUsageInMinorUnits", test.testClaudeExtraUsageInMinorUnits),
    ("testUpdateTagsCompareNumerically", test.testUpdateTagsCompareNumerically),
    ("testAlertsForRejectedKeysAndLowBalanceOnly", test.testAlertsForRejectedKeysAndLowBalanceOnly),
    ("testRouterKeyCapUsesOpenRouterNumbersAndAlerts", test.testRouterKeyCapUsesOpenRouterNumbersAndAlerts),
    ("testRouterCapsResetOnUTCBoundaries", test.testRouterCapsResetOnUTCBoundaries),
    ("testRouterTeamListsEveryKeyWithoutPulsing", test.testRouterTeamListsEveryKeyWithoutPulsing),
    ("testKeysAlreadyOnTheMacNeedNoSetup", test.testKeysAlreadyOnTheMacNeedNoSetup),
    ("testKeychainPromptNeverReturnsOnItsOwn", test.testKeychainPromptNeverReturnsOnItsOwn),
    ("testCLIsFoundOutsideTheAppsBarePATH", test.testCLIsFoundOutsideTheAppsBarePATH),
    ("testGLMKeyComesFromClaudeCodeSettings", test.testGLMKeyComesFromClaudeCodeSettings),
    ("testManagementKeyOnTheMacListsTheTeam", test.testManagementKeyOnTheMacListsTheTeam),
    ("testRevokedFoundKeyStaysQuiet", test.testRevokedFoundKeyStaysQuiet),
    ("testAntigravityPoolsModelsThatShareAQuota", test.testAntigravityPoolsModelsThatShareAQuota),
    ("testAntigravityFoldsUntouchedModelsByFamily", test.testAntigravityFoldsUntouchedModelsByFamily),
    ("testSignInProblemsOfferTheirFix", test.testSignInProblemsOfferTheirFix),
    ("testShelfLearnsEachPersonsMainTools", test.testShelfLearnsEachPersonsMainTools),
    ("testExpiredClaudeSignInRenewsRarelyAndLeavesNothing", test.testExpiredClaudeSignInRenewsRarelyAndLeavesNothing),
    ("testHooksCountAsUseAndThePauseSaysSo", test.testHooksCountAsUseAndThePauseSaysSo),
    ("testAttentionNeverMakesAFourthBatteryAndTheirChoiceWins", test.testAttentionNeverMakesAFourthBatteryAndTheirChoiceWins),
    ("testPinnedBatteriesTakeAPlaceInTheBar", test.testPinnedBatteriesTakeAPlaceInTheBar),
    ("testChosenFoldersAreReadEvenWhenHiddenAndKeepNoKeys", test.testChosenFoldersAreReadEvenWhenHiddenAndKeepNoKeys),
    ("testBalanceKeysAlreadyOnTheMac", test.testBalanceKeysAlreadyOnTheMac),
    ("testKeychainAsksForASecretOnlyWhenItChanges", test.testKeychainAsksForASecretOnlyWhenItChanges),
    ("testClaudeLeavesTheKeychainAloneWhileItsStatuslineReports", test.testClaudeLeavesTheKeychainAloneWhileItsStatuslineReports),
    ("testProvidersInUseRefreshBetweenPasses", test.testProvidersInUseRefreshBetweenPasses),
    ("testBatteriesLeaveWithTheirSource", test.testBatteriesLeaveWithTheirSource),
    ("testSourceNoticesStartQuietAndDeduplicate", test.testSourceNoticesStartQuietAndDeduplicate),
    ("testSourceNoticeNeedsFreshSuccessfulData", test.testSourceNoticeNeedsFreshSuccessfulData),
    ("testOutagesAndOverflowAreNotSourceRemovals", test.testOutagesAndOverflowAreNotSourceRemovals),
    ("testSourceChangesGroupAndDescribeActualRoutes", test.testSourceChangesGroupAndDescribeActualRoutes),
    ("testStatuslineReceiptsIgnoreContextAndMalformedQuota", test.testStatuslineReceiptsIgnoreContextAndMalformedQuota),
    ("testClaudeFreshStatuslineClearsFailureWithoutOAuth", test.testClaudeFreshStatuslineClearsFailureWithoutOAuth),
    ("testGoneEvidenceUsesProviderCacheAndExpiresOnFreshRead", test.testGoneEvidenceUsesProviderCacheAndExpiresOnFreshRead),
    ("testSourceReceiptsPreservePartialWindowProvenance", test.testSourceReceiptsPreservePartialWindowProvenance),
    ("testAntigravityPaletteFollowsUsageAndModelRemoval", test.testAntigravityPaletteFollowsUsageAndModelRemoval),
    ("testQuotaPalettesKeepUnknownAndLegacyRowsNeutral", test.testQuotaPalettesKeepUnknownAndLegacyRowsNeutral),
    ("testSituationMatrix", test.testSituationMatrix),
    ("testNeverWorkedStaysHiddenUnlessTheKeyNeedsYou", test.testNeverWorkedStaysHiddenUnlessTheKeyNeedsYou),
    ("testVanishedWindowsExpireWithTheirReset", test.testVanishedWindowsExpireWithTheirReset),
    ("testARevokedKeyThatWorkedIsAnnouncedOnceThenGoes", test.testARevokedKeyThatWorkedIsAnnouncedOnceThenGoes),
    ("testEmptyBalancesAndFullQuotasAreShownNotHidden", test.testEmptyBalancesAndFullQuotasAreShownNotHidden),
    ("testAnEarlyResetReadsFreshNotStale", test.testAnEarlyResetReadsFreshNotStale),
    ("testRecordedAnswersStillParse", test.testRecordedAnswersStillParse)
]
for (name, action) in cases {
    do { try test.setUpWithError(); try action() } catch { fail(name + ": " + error.localizedDescription) }
    do { try test.tearDownWithError() } catch { fail(name + ": cleanup failed") }
}
if !failures.isEmpty { for message in failures { print(message) }; exit(1) }
print("\(cases.count) native Swift core checks passed")
