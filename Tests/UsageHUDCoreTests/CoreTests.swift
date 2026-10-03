import Foundation
@testable import UsageHUDCore

final class FakeCredentials: CredentialReading {
    var calls = 0
    var text = "fixture"
    func password(service: String, account: String?) throws -> String { calls += 1; return text }
}
final class FakeHTTP: HTTPReading {
    var calls = 0
    var response: JSON = [:]
    var error: Error?
    var handler: ((URL) throws -> JSON)?
    func get(_ url: URL, token: String, headers: [String: String], limit: Int) throws -> JSON {
        calls += 1
        if let error = error { throw error }
        return try handler?(url) ?? response
    }
}
struct FakeProvider: UsageProvider {
    let id: String
    var name: String { id }
    let automatic = true
    let fail: Bool
    func refresh() throws { if fail { throw HUDProblem("offline") } }
    func panel() -> Panel { Panel(id: id, name: name, windows: [Window(label: "5h", pct: 20)]) }
}
final class CoreTests {
    var root: URL!, cache: Cache!, credentials: FakeCredentials!, http: FakeHTTP!
    func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("usagehud-test-" + UUID().uuidString)
        cache = Cache(root); credentials = FakeCredentials(); http = FakeHTTP()
    }
    func tearDownWithError() throws { if FileManager.default.fileExists(atPath: root.path) { try FileManager.default.removeItem(at: root) } }
    func seed() throws {
        try cache.write("claude.json", ["captured_at": 123, "context_pct": 42, "rate_limits": [
            "seven_day": ["used_percentage": 37, "resets_at": 9999999999.0]]])
    }
    func testCachePrivatePermissions() throws {
        try seed()
        let attrs = try FileManager.default.attributesOfItem(atPath: root.appendingPathComponent("claude.json").path)
        expectEqual(attrs[.posixPermissions] as? Int, 0o600)
        expectEqual(try FileManager.default.attributesOfItem(atPath: root.path)[.posixPermissions] as? Int, 0o700)
    }
    func testPartialQuotaPreservesPreviousWeekAndContext() throws {
        try seed(); try cache.quota("claude.json", windows: ["five_hour": ["used_percentage": 12]], now: 1000)
        let blob = cache.read("claude.json"), windows = dict(blob["rate_limits"])
        expectEqual(number(blob["context_pct"]), 42)
        expectEqual(number(dict(windows["seven_day"])["used_percentage"]), 37)
        expectEqual(number(dict(windows["seven_day"])["captured_at"]), 123)
        expectEqual(dict(windows["seven_day"])["stale"] as? Bool, true)
        expectEqual(dict(windows["five_hour"])["stale"] as? Bool, false)
    }
    func testMissingFiveHourCannotBecomeFresh() throws {
        try cache.quota("codex-quota.json", windows: ["primary": ["used_percentage": 50, "window_minutes": 300]], now: 1000)
        try cache.quota("codex-quota.json", windows: ["secondary": ["used_percentage": 20, "window_minutes": 10080]], now: 1001)
        let rows = quotaWindows(cache.read("codex-quota.json"), now: 1001)
        expectEqual(rows[0].stale, true); expectEqual(rows[1].stale, false)
    }
    func testConcurrentMergesDoNotLoseFields() throws {
        let target = cache!
        DispatchQueue.concurrentPerform(iterations: 20) { index in try! target.merge("shared.json", [String(index): index]) }
        expectEqual(cache.read("shared.json").count, 20)
    }
    func testMalformedCacheDoesNotCrash() throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("invalid".utf8).write(to: root.appendingPathComponent("claude.json"))
        expectTrue(cache.read("claude.json").isEmpty)
    }
    func testFiniteNumbersOnly() {
        expectNil(number(Double.nan)); expectNil(number(Double.infinity)); expectNil(number(true)); expectEqual(number("12.5"), 12.5)
    }
    func testWindowNormalizationAndReset() {
        let rows = quotaWindows(["captured_at": 1000, "rate_limits": [
            "secondary": ["used_percentage": 150, "window_minutes": 10080],
            "primary": ["used_percentage": -4, "window_minutes": 300, "resets_at": 1001]]], now: 1002)
        expectEqual(rows.map(\.label), ["5h", "7d"]); expectEqual(rows.map(\.pct), [0, 100]); expectEqual(rows[0].expired, true)
    }
    func testFiveHourPreferredWhenFresh() {
        let panel = Panel(id: "codex", name: "Codex", windows: [Window(label: "7d", pct: 37), Window(label: "5h", pct: 12)])
        expectEqual(panel.displayedQuota?.label, "5h")
    }
    func testCachedWeekReplacesExpiredFiveHour() {
        let panel = Panel(id: "codex", name: "Codex", windows: [Window(label: "5h", pct: 99, expired: true), Window(label: "7d", pct: 37, stale: true)])
        expectEqual(panel.displayedQuota?.label, "7d"); expectEqual(panel.displayedQuota?.pct, 37)
    }
    func testUnknownQuotaNeverAppearsAsFull() { expectNil(Panel(id: "codex", name: "Codex").displayedQuota) }
    func testCacheOnlyReadNeverReadsCredentialsOrNetwork() {
        _ = Engine(root: root, credentials: credentials, http: http).panels()
        expectEqual(credentials.calls, 0); expectEqual(http.calls, 0)
    }
    func testProviderFailureIsIsolated() {
        let engine = Engine(root: root, credentials: credentials, http: http, providers: [FakeProvider(id: "bad", fail: true), FakeProvider(id: "good", fail: false)])
        let panels = engine.panels(refresh: "automatic")
        expectEqual(panels[0].windows[0].stale, true); expectEqual(panels[0].note, "offline")
        expectEqual(panels[1].windows[0].stale, false); expectTrue(panels[1].note.isEmpty)
    }
    func testExpiredClaudeNeverMakesHTTPRequestOrChangesCredential() throws {
        credentials.text = "{\"claudeAiOauth\":{\"accessToken\":\"fixture\",\"expiresAt\":1}}"
        expectError(try ClaudeProvider(cache: cache, credentials: credentials, http: http).refresh())
        expectEqual(credentials.calls, 1); expectEqual(http.calls, 0)
    }
    func testClaudeGETPreservesContextAndCredits() throws {
        try seed(); try cache.merge("claude.json", ["usage_credits": ["is_enabled": true]])
        credentials.text = "{\"claudeAiOauth\":{\"accessToken\":\"fixture\"}}"
        http.response = ["five_hour": ["utilization": 12, "resets_at": "2099-01-01T00:00:00Z"]]
        try ClaudeProvider(cache: cache, credentials: credentials, http: http).refresh()
        let blob = cache.read("claude.json")
        expectEqual(number(blob["context_pct"]), 42); expectNotNil(blob["usage_credits"])
        expectEqual(http.calls, 1)
        expectFalse(String(data: try Data(contentsOf: root.appendingPathComponent("claude.json")), encoding: .utf8)!.contains("fixture"))
    }
    func testClaude429DoesNotInventExhaustedQuota() throws {
        try seed(); let before = try Data(contentsOf: root.appendingPathComponent("claude.json"))
        credentials.text = "{\"accessToken\":\"fixture\"}"; http.error = HTTPFailure(status: 429)
        expectError(try ClaudeProvider(cache: cache, credentials: credentials, http: http).refresh())
        expectEqual(before, try Data(contentsOf: root.appendingPathComponent("claude.json")))
    }
    func testCodexSelectsOnlyCodexBucket() throws {
        let result: JSON = ["rateLimitsByLimitId": ["codex": ["limitId": "codex", "primary": ["usedPercent": 12, "windowDurationMins": 300]],
                                                   "other": ["primary": ["usedPercent": 99]]]]
        expectEqual(number(dict(try CodexProvider.windows(result)["primary"])["used_percentage"]), 12)
    }
    func testWrongCodexBucketFailsClosed() {
        expectError(try CodexProvider.windows(["rateLimitsByLimitId": ["other": ["primary": ["usedPercent": 99]]]]))
        expectError(try CodexProvider.windows(["rateLimits": ["limitId": "other", "primary": ["usedPercent": 99]]]))
    }
    func testRouterRejectsDuplicateSlots() {
        let slot: JSON = ["id": "one", "label": "One", "sources": [["provider": "openrouter"]]]
        expectError(try OpenRouterProvider.slots([slot, slot]))
    }
    func testRouterSourceChangeResetsDailyBaseline() {
        let slot = RouterSlot(id: "one", label: "One", sources: [])
        let row = OpenRouterProvider.successfulRow(slot: slot, source: ["service": "new", "account": "one"], result: ["usage": 50],
                                                  previous: ["source_id": "old", "day": "today", "day_start_usage": 10], day: "today")
        expectEqual(number(row["day_start_usage"]), 50)
    }
    func testRouterSameSourceKeepsDailyBaseline() {
        let slot = RouterSlot(id: "one", label: "One", sources: [])
        let row = OpenRouterProvider.successfulRow(slot: slot, source: ["service": "same", "account": "one"], result: ["usage": 50],
            previous: ["source_id": "openrouter:same:one", "day": "today", "day_start_usage": 10], day: "today")
        expectEqual(number(row["day_start_usage"]), 10)
    }
    func testRouterFallbackAndBalance() throws {
        try cache.write("providers.json", [:])
        let config = [["id": "one", "label": "One", "sources": [["provider": "unsupported"], ["provider": "openrouter", "service": "fixture", "account": "one"]]]]
        try JSONSerialization.data(withJSONObject: config).write(to: root.appendingPathComponent("providers.json"))
        http.handler = { url in url.path.hasSuffix("credits") ? ["data": ["total_credits": 50, "total_usage": 7]] : ["data": ["usage": 7]] }
        let provider = OpenRouterProvider(cache: cache, credentials: credentials, http: http)
        try provider.refresh()
        expectEqual(provider.panel().windows.first?.right, "$43.00 left")
        expectNil(provider.panel().windows.first?.pct)
        let old = Date().timeIntervalSince1970 - 86400
        try cache.merge("openrouter.json", ["balance_captured_at": old])
        http.handler = { url in
            if url.path.hasSuffix("credits") { throw HTTPFailure(status: 503) }
            return ["data": ["usage": 8]]
        }
        try provider.refresh()
        expectEqual(provider.panel().windows.first?.right, "$43.00 left")
        expectEqual(provider.panel().windows.first?.stale, true)
        expectEqual(number(cache.read("openrouter.json")["balance_captured_at"]), old)
    }
    func testStatuslinePreservesBurnGuardContext() throws {
        try seed()
        let engine = Engine(root: root, credentials: credentials, http: http)
        let line = try engine.statusline(JSONSerialization.data(withJSONObject: ["model": ["display_name": "Claude"], "context_window": ["used_percentage": 42]]))
        expectEqual(line, "Claude | ctx 42%")
        expectEqual(number(cache.read("claude.json")["context_pct"]), 42)
        expectNotNil(dict(cache.read("claude.json")["rate_limits"])["seven_day"])
    }
    func testHookMigrationPreservesUnrelatedCommands() throws {
        let file = root.appendingPathComponent("settings.json")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let before: JSON = ["statusLine": ["command": "python3 '\(root.path)/usage_hud.py' --claude-statusline"],
                            "hooks": [["command": "unrelated --probe-if-stale"]], "model": "fixture-model"]
        try JSONSerialization.data(withJSONObject: before).write(to: file)
        let engine = Engine(root: root, credentials: credentials, http: http)
        expectEqual(try engine.migrateHooks(executable: "/a path/usagehud", settings: file), 1)
        let after = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as! JSON
        expectEqual(dict(after["statusLine"])["command"] as? String, "'/a path/usagehud' --claude-statusline")
        expectEqual((after["hooks"] as? [JSON])?.first?["command"] as? String, "unrelated --probe-if-stale")
        expectEqual(after["model"] as? String, "fixture-model")
    }
    func testRPCFramingAndEOF() throws {
        let rpc = try RPCProcess(binary: URL(fileURLWithPath: "/usr/bin/printf"), arguments: ["{\"id\":1,\"result\":{\"ok\":true}}\\n"])
        defer { rpc.stop() }
        expectEqual(try rpc.receive(1)["ok"] as? Bool, true)
    }
    func testProcessTimeoutIsBounded() throws {
        let start = Date()
        let rpc = try RPCProcess(binary: URL(fileURLWithPath: "/bin/sleep"), arguments: ["2"], timeout: 0.05)
        expectError(try rpc.chunk()); rpc.stop()
        expectLess(Date().timeIntervalSince(start), 1.5)
    }
    func result(_ extra: JSON = [:]) -> JSON {
        var value: JSON = ["model": "gpt-6-astra", "input_tokens": 1000, "output_tokens": 100, "num_model_requests": 1]
        value.merge(extra) { _, new in new }; return value
    }
    func testRetainedTariffUsesUncachedAndOutput() throws { expectEqual(try OpenAICredits.usageCost(result()).amount, Decimal(string: "0.015")!) }
    func testCachedInputIsNotChargedTwice() throws {
        expectEqual(try OpenAICredits.usageCost(result(["input_cached_tokens": 500])).amount, Decimal(string: "0.0105")!)
    }
    func testBatchAndFlexDiscount() throws {
        expectEqual(try OpenAICredits.usageCost(result(["batch": true])).amount, Decimal(string: "0.0075")!)
        expectEqual(try OpenAICredits.usageCost(result(["service_tier": "flex"])).amount, Decimal(string: "0.0075")!)
    }
    func testLongContextConservativeAggregation() throws {
        let cost = try OpenAICredits.usageCost(result(["input_tokens": 300000, "num_model_requests": 2]))
        expectTrue(cost.conservative); expectEqual(cost.amount, Decimal(string: "6.0075")!)
    }
    func testUnsupportedAccountingFailsClosed() {
        expectError(try OpenAICredits.usageCost(result(["model": "unknown"])))
        expectError(try OpenAICredits.usageCost(result(["service_tier": "priority"])))
        expectError(try OpenAICredits.usageCost(result(["input_cached_tokens": 5000])))
        expectError(try OpenAICredits.usageCost(result(["num_model_requests": 0])))
        expectError(try OpenAICredits.integer(true, "requests"))
    }
    func testCreditReconciliationUsesGreaterSpendAndMemoizesCredential() throws {
        try cache.write("credits.json", ["openai": ["service": "fixture", "account": "fixture"]])
        try cache.write("codex.json", ["balance": 50, "captured_at": Date().timeIntervalSince1970 - 100])
        http.handler = { url in
            if url.path.hasSuffix("costs") { return ["data": [["results": [["amount": ["value": 2, "currency": "usd"]]]]], "has_more": false] }
            return ["data": [["end_time": 1234, "results": [self.result(["input_tokens": 300000, "num_model_requests": 2])]]], "has_more": false]
        }
        let credit = OpenAICredits(cache: cache, credentials: credentials, http: http)
        try credit.refresh(); try credit.refresh()
        expectEqual(number(cache.read("codex.json")["balance"])!, 43.9925, accuracy: 0.000001)
        expectEqual(credentials.calls, 1)
        expectFalse(String(data: try Data(contentsOf: root.appendingPathComponent("codex.json")), encoding: .utf8)!.contains("fixture"))
    }
    func testPaginationCycleRejected() throws {
        http.response = ["data": [], "has_more": true, "next_page": "same"]
        expectError(try OpenAICredits(cache: cache, credentials: credentials, http: http).pages(path: "costs", start: 1, end: 2, usage: false, token: "fixture"))
    }
}
