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
        calls += 1; sentHeaders = headers
        if let error = error { throw error }
        return try handler?(url) ?? response
    }
    var bodies: [JSON] = [], sentHeaders: [String: String] = [:]
    func post(_ url: URL, token: String, headers: [String: String], body: JSON, limit: Int) throws -> JSON {
        bodies.append(body)
        return try get(url, token: token, headers: headers, limit: limit)
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
struct AlertProvider: UsageProvider {
    let id: String
    var name: String { id }
    let automatic = true
    let problem: String?
    var attention = false
    let right: String
    func refresh() throws { if let problem = problem { throw HUDProblem(problem, attention: attention) } }
    func panel() -> Panel { Panel(id: id, name: name, windows: [Window(label: id, right: right)]) }
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
    func testProUsesWeeklyWindowInsteadOfOldFiveHour() throws {
        let now = Date().timeIntervalSince1970
        try cache.write("codex-quota.json", ["plan": "pro", "captured_at": now, "rate_limits": [
            "primary": ["used_percentage": 20, "window_minutes": 300, "captured_at": now],
            "secondary": ["used_percentage": 31, "window_minutes": 10080, "captured_at": now]]])
        let provider = CodexProvider(cache: cache, credits: OpenAICredits(cache: cache, credentials: credentials, http: http))
        let panel = provider.panel()
        expectEqual(panel.displayedQuota?.label, "7d")
        expectFalse(panel.windows.contains { $0.label == "5h" })
        expectEqual(panel.note, "Plan: pro")
    }
    func testWeeklyPrimaryIsNotMislabelledFiveHour() throws {
        let windows = try CodexProvider.windows(["rateLimits": ["limitId": "codex", "planType": "pro",
            "primary": ["usedPercent": 31, "windowDurationMins": 10080]]])
        expectEqual(quotaWindows(["captured_at": Date().timeIntervalSince1970, "rate_limits": windows]).first?.label, "7d")
    }
    func testPurchasedCodexCreditsAreNotDollars() throws {
        try cache.write("codex-quota.json", ["plan": "pro", "captured_at": Date().timeIntervalSince1970,
                                            "subscription_credits": ["balance": "125.5", "hasCredits": true, "unlimited": false]])
        let panel = CodexProvider(cache: cache, credits: OpenAICredits(cache: cache, credentials: credentials, http: http)).panel()
        expectEqual(panel.windows.first?.right, "125.5 credits left")
        expectNil(panel.displayedQuota)
    }
    func testCreditOnlyCodexResponseDoesNotInventQuota() throws {
        let windows = try CodexProvider.windows(["rateLimits": ["credits": ["unlimited": true, "hasCredits": true]]])
        expectTrue(windows.isEmpty)
        expectError(try CodexProvider.windows(["rateLimits": ["planType": "pro"]]))
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

    func testGLMCreditWindowsBecomeFiveHourAndWeek() throws {
        let windows = try GLMProvider.windows(["success": true, "data": ["level": "lite", "limits": [
            ["type": "TIME_LIMIT", "unit": 5, "number": 1, "percentage": 1],
            ["type": "CREDIT_LIMIT", "unit": 6, "number": 1, "percentage": 52, "nextResetTime": 1788784466996],
            ["type": "CREDIT_LIMIT", "unit": 3, "number": 5, "percentage": 20, "nextResetTime": 1788351145586]]]])
        let rows = quotaWindows(["captured_at": 1000, "rate_limits": windows], now: 1000)
        expectEqual(rows.map(\.label), ["5h", "7d"]); expectEqual(rows.map(\.pct), [20, 52])
        expectEqual(rows[0].resets_at, 1788351145.586)
    }
    func testGLMLegacyTokensLimitIsFiveHour() throws {
        let windows = try GLMProvider.windows(["data": ["limits": [["type": "TOKENS_LIMIT", "unit": 5, "number": 1, "percentage": 66]]]])
        expectEqual(quotaWindows(["captured_at": 1000, "rate_limits": windows], now: 1000).first?.label, "5h")
        expectError(try GLMProvider.windows(["success": false, "msg": "invalid key"]))
    }
    func testGLMSendsRawKeyAndTriesMainlandHost() throws {
        credentials.text = "zai-key"
        http.handler = { url in
            if url.host == "api.z.ai" { throw HTTPFailure(status: 401) }
            return ["data": ["limits": [["type": "CREDIT_LIMIT", "unit": 3, "number": 5, "percentage": 10]]]]
        }
        let provider = GLMProvider(cache: cache, credentials: credentials, http: http)
        expectFalse(provider.shown())
        try provider.refresh()
        expectTrue(provider.shown()); expectEqual(http.sentHeaders["Authorization"], "zai-key")
        expectEqual(cache.read("glm.json")["host"] as? String, "open.bigmodel.cn")
    }
    func testGeminiFamiliesKeepTightestPool() throws {
        let windows = try GeminiProvider.windows(["buckets": [
            ["modelId": "gemini-2.5-pro", "remainingFraction": 0.75, "resetTime": "2026-10-04T00:00:00Z"],
            ["modelId": "gemini-3-pro-preview", "remainingFraction": 0.40, "resetTime": "2026-10-03T20:00:00Z"],
            ["modelId": "gemini-2.5-flash", "remainingFraction": 0.9],
            ["modelId": "gemini-2.5-flash-lite", "remainingFraction": 1]]])
        expectEqual(Set(windows.keys), ["pro", "flash", "flash_lite"])
        expectEqual(number(dict(windows["pro"])["used_percentage"]) ?? 0, 60, accuracy: 0.001)
        expectEqual(number(dict(windows["pro"])["resets_at"]), resetTime("2026-10-03T20:00:00Z"))
    }
    func testExpiredGeminiNeverCallsNetwork() throws {
        let file = root.appendingPathComponent("oauth_creds.json")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("{\"access_token\":\"fixture\",\"expiry_date\":1}".utf8).write(to: file)
        expectError(try GeminiProvider(cache: cache, http: http, credentialFile: file).refresh())
        expectEqual(http.calls, 0)
    }
    func testGeminiPostsProjectFromTier() throws {
        let file = root.appendingPathComponent("oauth_creds.json")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("{\"access_token\":\"fixture\"}".utf8).write(to: file)
        http.handler = { url in url.absoluteString.hasSuffix("loadCodeAssist") ?
            ["cloudaicompanionProject": "proj-1", "currentTier": ["name": "Gemini Code Assist"]] :
            ["buckets": [["modelId": "gemini-2.5-pro", "remainingFraction": 0.5]]] }
        let provider = GeminiProvider(cache: cache, http: http, credentialFile: file)
        try provider.refresh()
        expectEqual(http.bodies.last?["project"] as? String, "proj-1")
        expectEqual(provider.panel().note, "Plan: Gemini Code Assist")
        expectEqual(provider.panel().windows.first?.pct, 50)
    }
    func testGrokMonthlyBillingInCents() throws {
        let billing: JSON = ["monthlyLimit": ["val": 5000], "usage": ["totalUsed": ["val": 1250]],
                             "billingCycle": ["billingPeriodEnd": "2026-11-01T00:00:00Z"]]
        let windows = try GrokProvider.windows(billing)
        expectEqual(number(dict(windows["month"])["used_percentage"]), 25)
        try cache.quota("grok.json", windows: windows, extra: ["spent_cents": 1250, "limit_cents": 5000])
        expectEqual(GrokProvider(cache: cache).panel().windows.last?.right, "$12.50 of $50.00 this month")
        expectError(try GrokProvider.windows(["usage": ["totalUsed": ["val": 1]]]))
    }
    func testUnusedPlansStayOutOfMenuBar() {
        let panels = Engine(root: root, credentials: credentials, http: http).panels()
        expectEqual(panels.map(\.id), ["codex", "claude", "openrouter"])
    }

    func testBalanceParsers() throws {
        let vercel = try BalanceProvider.vercelBalance(["balance": "95.50", "total_used": "4.50"], "ai-gateway.vercel.sh")
        expectEqual(vercel.0, 95.5); expectEqual(vercel.1, "$")
        let deepSeek = try BalanceProvider.deepSeekBalance(["is_available": true, "balance_infos": [
            ["currency": "CNY", "total_balance": "110.00"], ["currency": "USD", "total_balance": "12.30"]]], "api.deepseek.com")
        expectEqual(deepSeek.0, 12.3); expectEqual(deepSeek.1, "$")
        let yuan = try BalanceProvider.deepSeekBalance(["balance_infos": [["currency": "CNY", "total_balance": "110.00"]]], "api.deepseek.com")
        expectEqual(yuan.1, "¥")
        let kimi = try BalanceProvider.kimiBalance(["code": 0, "data": ["available_balance": 49.58894]], "api.moonshot.cn")
        expectEqual(kimi.0, 49.58894); expectEqual(kimi.1, "¥")
        expectError(try BalanceProvider.vercelBalance([:], "ai-gateway.vercel.sh"))
    }
    func testBalanceProviderFallsBackToSecondHostAndShowsMoney() throws {
        http.handler = { url in
            if url.host == "api.moonshot.ai" { throw HTTPFailure(status: 401) }
            return ["data": ["available_balance": 3.5]]
        }
        let provider = BalanceProvider.kimi(cache: cache, credentials: credentials, http: http)
        expectFalse(provider.shown())
        try provider.refresh()
        expectTrue(provider.shown())
        expectEqual(provider.panel().windows.first?.label, "Kimi")
        expectEqual(provider.panel().windows.first?.right, "¥3.50 left")
    }
    func testShelfKeepsMostRecentlyUsedBatteries() {
        func quota(_ id: String, _ pct: Double) -> Panel { Panel(id: id, name: id, windows: [Window(label: "5h", pct: pct)]) }
        func balance(_ id: String, _ right: String) -> Panel { Panel(id: id, name: id, windows: [Window(label: id, right: right)]) }
        var shelf = Shelf()
        let ids = ["codex", "claude", "openrouter", "glm", "kimi"]
        expectEqual(shelf.arrange(ids, limit: 3).shown, ["codex", "claude", "openrouter"])
        expectEqual(shelf.arrange(ids, limit: 3).hidden, ["glm", "kimi"])
        expectEqual(shelf.arrange(["codex", "claude"], limit: 3).hidden, [])
        // First sightings and falling quota (a window reset) are not use.
        shelf.observe(quota("glm", 40), now: 10); shelf.observe(balance("kimi", "¥9.00 left"), now: 10)
        shelf.observe(quota("glm", 5), now: 20)
        expectEqual(shelf.arrange(ids, limit: 3).hidden, ["glm", "kimi"])
        // Rising quota and a falling balance are.
        shelf.observe(quota("glm", 12), now: 30)
        shelf.observe(balance("kimi", "¥8.75 left"), now: 40)
        expectEqual(shelf.arrange(ids, limit: 3).shown, ["codex", "glm", "kimi"])
        expectEqual(shelf.arrange(ids, limit: 3).hidden, ["claude", "openrouter"])
        expectEqual(Shelf.level(balance("vercel", "$1026.25 left")), -1026.25)
    }
    func testClaudeExtraUsageInMinorUnits() throws {
        try seed()
        try cache.merge("claude.json", ["usage_credits": ["is_enabled": true, "monthly_limit": 5000, "used_credits": 1234,
                                                          "utilization": 24.68, "currency": "USD", "decimal_places": 2]])
        let provider = ClaudeProvider(cache: cache, credentials: credentials, http: http)
        expectEqual(provider.panel().windows.first { $0.label == "extra usage" }?.right, "$12.34 of $50.00 this month · 25%")
        try cache.merge("claude.json", ["usage_credits": ["is_enabled": true, "monthly_limit": NSNull(), "used_credits": 250]])
        expectEqual(provider.panel().windows.first { $0.label == "extra usage" }?.right, "$2.50 spent this month")
        try cache.merge("claude.json", ["usage_credits": ["is_enabled": false, "user_disabled": true, "used_credits": NSNull()]])
        expectEqual(provider.panel().windows.first { $0.label == "extra usage" }?.right, "Off")
    }
    func testUpdateTagsCompareNumerically() {
        expectTrue(Updates.isNewer("v2.10", than: "2.9")); expectTrue(Updates.isNewer("2.1.1", than: "2.1"))
        expectFalse(Updates.isNewer("v2.1", than: "2.1")); expectFalse(Updates.isNewer("v2.0.9", than: "2.1"))
        expectEqual(Updates.newer(["tag_name": "v2.2", "html_url": "https://github.com/o/r/releases/tag/v2.2"], than: "2.1")?.tag, "v2.2")
        expectNil(Updates.newer(["tag_name": "v2.1", "html_url": "https://github.com/o/r"], than: "2.1"))
    }
    /// An idle CLI's expired token and a passing outage stay calm; a rejected key and a low balance ask for attention.
    func testAlertsForRejectedKeysAndLowBalanceOnly() {
        let engine = Engine(root: root, credentials: credentials, http: http, providers: [
            AlertProvider(id: "a", problem: "a API key rejected", attention: true, right: "$9.00 left"),
            AlertProvider(id: "b", problem: nil, right: "$0.50 left"),
            AlertProvider(id: "c", problem: "c sign-in expired; run c once", right: "$9.00 left")])
        let panels = engine.panels(refresh: "automatic")
        expectEqual(panels[0].alert, "a API key rejected")
        expectEqual(panels[1].alert, "Balance low: $0.50 left")
        expectNil(panels[2].alert)
        engine.lowBalance = 0.25
        expectNil(engine.panels(refresh: nil)[1].alert)
    }
    func testRouterKeyCapUsesOpenRouterNumbersAndAlerts() throws {
        let config = [["id": "one", "label": "One", "sources": [["provider": "openrouter", "service": "fixture", "account": "one"]]]]
        try JSONSerialization.data(withJSONObject: config).write(to: root.appendingPathComponent("providers.json"))
        http.handler = { url in
            url.path.hasSuffix("credits") ? ["data": ["total_credits": 50, "total_usage": 7]]
                : ["data": ["usage": 120, "usage_daily": 4.6, "limit": 5, "limit_remaining": 0.4, "limit_reset": "daily"]]
        }
        let provider = OpenRouterProvider(cache: cache, credentials: credentials, http: http)
        try provider.refresh()
        let panel = provider.panel()
        expectEqual(panel.windows.first?.right, "$43.00 left")
        expectTrue(panel.windows[1].right?.hasPrefix("$4.60 of $5.00 today · resets in ") == true)
        expectEqual(panel.alert, "One: $0.40 left of its cap")
    }
    func testRouterCapsResetOnUTCBoundaries() {
        let saturday = Date(timeIntervalSince1970: 1791039600) // 2026-10-03 15:00 UTC
        expectEqual(OpenRouterProvider.nextReset("daily", after: saturday)?.timeIntervalSince1970, 1791072000)
        expectEqual(OpenRouterProvider.nextReset("weekly", after: saturday)?.timeIntervalSince1970, 1791158400)
        expectEqual(OpenRouterProvider.nextReset("monthly", after: saturday)?.timeIntervalSince1970, 1793491200)
        expectNil(OpenRouterProvider.nextReset(nil, after: saturday))
        expectEqual(Shelf().arrange(["codex", "claude", "openrouter", "kimi"], limit: 3, urgent: ["kimi"]).hidden, ["openrouter"])
    }
}
