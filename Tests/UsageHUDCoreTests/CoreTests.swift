import Foundation
@testable import UsageHUDCore

final class FakeCredentials: CredentialReading {
    var calls = 0
    var text = "fixture"
    /// Services with nothing stored; no team key unless a test asks for one.
    var missing: Set<String> = [OpenRouterProvider.teamService]
    func password(service: String, account: String?) throws -> String {
        calls += 1
        if missing.contains(service) { throw HUDProblem("not found") }
        return text
    }
}
final class FakeHTTP: HTTPReading {
    var calls = 0
    var response: JSON = [:]
    var error: Error?
    var handler: ((URL) throws -> JSON)?
    func get(_ url: URL, token: String, headers: [String: String], limit: Int) throws -> JSON {
        calls += 1; sentHeaders = headers; sentToken = token
        if let error = error { throw error }
        return try handler?(url) ?? response
    }
    var bodies: [JSON] = [], sentHeaders: [String: String] = [:], sentToken = ""
    func post(_ url: URL, token: String, headers: [String: String], body: JSON, limit: Int) throws -> JSON {
        bodies.append(body)
        return try get(url, token: token, headers: headers, limit: limit)
    }
    /// Answers with the `header` entry of what `get` would return.
    func header(_ url: URL, token: String, name: String) throws -> String? {
        dict(try get(url, token: token, headers: [:], limit: 0)["header"])[name] as? String
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
final class SwitchProvider: UsageProvider {
    let id = "s", name = "S", automatic = true
    var problem: HUDProblem?
    func refresh() throws { if let problem = problem { throw problem } }
    func panel() -> Panel { Panel(id: id, name: name, windows: [Window(label: "5h", pct: 10)]) }
}
final class PromptingProvider: UsageProvider {
    let id = "p", name = "P", automatic = true
    var calls = 0
    func refresh() throws { calls += 1; throw HUDProblem("Keychain asked", prompted: true) }
    func panel() -> Panel { Panel(id: id, name: name, windows: [Window(label: "5h", pct: 1)]) }
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
        try ClaudeProvider(cache: cache, credentials: credentials, http: http, home: root).refresh()
        let blob = cache.read("claude.json")
        expectEqual(number(blob["context_pct"]), 42); expectNotNil(blob["usage_credits"])
        // The quota, plus the hourly free-reset read; without Claude Code's config there is no organization to ask.
        expectEqual(http.calls, 2)
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
        expectEqual(panel.windows.first?.right, "125.5")
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
        expectEqual(provider.panel().windows.first?.right, "$43 left")
        expectNil(provider.panel().windows.first?.pct)
        let old = Date().timeIntervalSince1970 - 86400
        try cache.merge("openrouter.json", ["balance_captured_at": old])
        http.handler = { url in
            if url.path.hasSuffix("credits") { throw HTTPFailure(status: 503) }
            return ["data": ["usage": 8]]
        }
        try provider.refresh()
        expectEqual(provider.panel().windows.first?.right, "$43 left")
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
    /// Free resets and prepaid credits show beside the quota: Codex's from its usage read, Claude's from an hourly read.
    func testFreeResetsAndPrepaidBalance() throws {
        expectEqual(money(20), "$20"); expectEqual(money(1.25), "$1.25"); expectEqual(money(0.001), "$0"); expectEqual(money(3.5, "¥"), "¥3.50")
        let soon = Date().timeIntervalSince1970 + 3 * 86400
        let codex = CodexProvider.freeResets(["rateLimitResetCredits": ["availableCount": 2, "credits": [
            ["status": "available", "expiresAt": soon + 86400], ["status": "available", "expiresAt": soon], ["status": "redeemed", "expiresAt": 1]]]])
        expectEqual(number(codex?["left"]), 2); expectEqual(number(codex?["until"]), soon)
        expectNil(CodexProvider.freeResets([:]))
        try cache.write("codex-quota.json", ["captured_at": Date().timeIntervalSince1970, "free_resets": codex!,
                                            "subscription_credits": ["balance": "0", "hasCredits": false]])
        let rows = CodexProvider(cache: cache, credits: OpenAICredits(cache: cache, credentials: credentials, http: http)).panel().windows
        // No purchased credits is the normal case and shows nothing; the free resets do show.
        expectEqual(rows.map { $0.label }, ["Free resets"])
        expectTrue(rows.first?.right?.hasPrefix("2 · ends in ") == true)
        let home = root.appendingPathComponent("home"), org = "12345678-1234-1234-1234-123456789abc"
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: ["oauthAccount": ["organizationUuid": org]]).write(to: home.appendingPathComponent(".claude.json"))
        credentials.text = "{\"claudeAiOauth\":{\"accessToken\":\"fixture\"}}"
        var asked: [String] = []
        http.handler = { url in
            asked.append(url.absoluteString)
            if url.path.hasSuffix("/prepaid/credits") { return ["amount": 2776, "currency": "USD"] }
            if url.query?.contains("cedar_ember=1") == true {
                return ["cedar_ember": ["grants": [["resets_left": 1, "ends_at": "2099-10-22T00:00:00Z"], ["resets_left": 3, "paused": true],
                                                   ["resets_left": 0, "ends_at": "2099-01-01T00:00:00Z"]]]]
            }
            return ["five_hour": ["utilization": 4]]
        }
        let claude = ClaudeProvider(cache: cache, credentials: credentials, http: http, home: home)
        try claude.refresh()
        expectTrue(asked.contains("https://api.anthropic.com/api/oauth/organizations/\(org)/prepaid/credits"))
        expectEqual(http.sentHeaders["x-organization-uuid"], org)
        let panel = claude.panel()
        expectEqual(panel.windows.first { $0.label == "Balance" }?.right, "$27.76")
        expectTrue(panel.windows.first { $0.label == "Free resets" }?.right?.hasPrefix("1 · ends in ") == true)
        // Those two are read hourly, not with every quota refresh.
        asked = []; try claude.refresh()
        expectEqual(asked.count, 1)
    }
    /// Claude Code gets our hooks and statusline beside the person's own, once; switched off, only ours leave.
    func testClaudeCodeConnectsAndDisconnectsCleanly() throws {
        let folder = root.appendingPathComponent("claude"), file = folder.appendingPathComponent("settings.json")
        let engine = Engine(root: root, credentials: credentials, http: http)
        expectFalse(try engine.connectClaudeCode(true, settings: file))
        expectFalse(FileManager.default.fileExists(atPath: folder.path))
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let before: JSON = ["statusLine": ["command": "python3 '\(root.path)/usage_hud.py' --claude-statusline", "padding": 0],
                            "hooks": ["Stop": [["hooks": [["type": "command", "command": "my-linter"]]]],
                                      "UserPromptSubmit": [["hooks": [["type": "command", "command": "'\(root.path)/usagehud' --probe-if-stale"]]]]],
                            "model": "fixture-model"]
        try JSONSerialization.data(withJSONObject: before).write(to: file)
        expectTrue(try engine.connectClaudeCode(true, settings: file))
        expectFalse(try engine.connectClaudeCode(true, settings: file))
        var after: JSON = [:]
        func load() throws { after = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as! JSON }
        func commands(_ event: String) -> [String] {
            ((dict(after["hooks"])[event] as? [JSON]) ?? []).flatMap { $0["hooks"] as? [JSON] ?? [] }.compactMap { $0["command"] as? String }
        }
        try load()
        let ours = "'\(root.path)/usagehud' --probe-if-stale 2>/dev/null || true"
        expectEqual(commands("Stop"), ["my-linter", ours])
        expectEqual(commands("UserPromptSubmit"), [ours]); expectEqual(commands("SessionStart"), [ours])
        expectEqual(dict(after["statusLine"])["command"] as? String, "'\(root.path)/usagehud' --claude-statusline 2>/dev/null")
        expectEqual(number(dict(after["statusLine"])["padding"]), 0)
        expectEqual(after["model"] as? String, "fixture-model")
        expectTrue(FileManager.default.fileExists(atPath: file.path + ".usagehud-backup"))
        expectTrue(try engine.connectClaudeCode(false, settings: file))
        try load()
        expectEqual(commands("Stop"), ["my-linter"]); expectEqual(commands("UserPromptSubmit"), [])
        expectNil(after["statusLine"])
        // Someone else's statusline is never replaced, and a file that isn't JSON is left alone.
        try JSONSerialization.data(withJSONObject: ["statusLine": ["type": "command", "command": "starship"]]).write(to: file)
        expectTrue(try engine.connectClaudeCode(true, settings: file))
        try load()
        expectEqual(dict(after["statusLine"])["command"] as? String, "starship"); expectEqual(commands("Stop"), [ours])
        try Data("{oops".utf8).write(to: file)
        expectFalse(try engine.connectClaudeCode(true, settings: file))
        expectEqual(String(data: try Data(contentsOf: file), encoding: .utf8), "{oops")
        expectTrue(engine.claudeCodeConnected)
        engine.claudeCodeConnected = false
        expectFalse(Engine(root: root, credentials: credentials, http: http).claudeCodeConnected)
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
        let provider = GLMProvider(cache: cache, credentials: credentials, http: http, home: root, environment: [:])
        expectFalse(provider.shown())
        try provider.refresh()
        expectTrue(provider.shown()); expectEqual(http.sentHeaders["Authorization"], "zai-key")
        expectEqual(cache.read("glm.json")["host"] as? String, "open.bigmodel.cn")
    }
    func testAntigravityModelQuotaAndPrivateCache() throws {
        let response: JSON = ["userStatus": ["email": "private@example.com", "token": "private-token",
            "cascadeModelConfigData": ["clientModelConfigs": [
                ["label": "Gemini Pro", "quotaInfo": ["remainingFraction": 0.75, "resetTime": "2099-10-04T00:00:00Z"]],
                ["label": "Claude", "quotaInfo": ["remainingFraction": 0.25]],
                ["label": "Unavailable"]]]]]
        let provider = AntigravityProvider(cache: cache, read: { response })
        expectFalse(provider.shown()); try provider.refresh(); expectTrue(provider.shown())
        expectEqual(provider.panel().windows.first?.label, "Claude")
        expectEqual(provider.panel().windows.first?.pct, 75)
        expectEqual(provider.panel().windows.count, 2)
        expectNotNil(provider.panel().windows.last?.resets_at)
        let raw = String(decoding: try Data(contentsOf: root.appendingPathComponent("antigravity.json")), as: UTF8.self)
        expectFalse(raw.contains("private@example.com")); expectFalse(raw.contains("private-token"))
    }
    func testAntigravityUnavailableKeepsLastReading() throws {
        try cache.quota("antigravity.json", windows: ["Gemini": ["used_percentage": 30]])
        let provider = AntigravityProvider(cache: cache, read: { throw HUDProblem("Open Antigravity") })
        expectError(try provider.refresh()); expectEqual(provider.panel().windows.first?.pct, 30)
    }
    func testAntigravityRejectsInvalidQuotaAndParsesFlags() throws {
        expectError(try AntigravityProvider.windows([:]))
        expectError(try AntigravityProvider.windows(["userStatus": ["cascadeModelConfigData": ["clientModelConfigs": [
            ["label": "Model", "quotaInfo": ["remainingFraction": 2]]]]]]))
        expectEqual(AntigravityLocal.flag("--csrf_token", in: "binary --csrf_token=fixture --other x"), "fixture")
        expectEqual(AntigravityLocal.flag("--csrf_token", in: "binary --csrf_token fixture --other x"), "fixture")
        expectNil(AntigravityLocal.flag("--csrf_token", in: "binary --csrf_token_extra wrong"))
    }
    /// Grok reads its credits with the sign-in Grok CLI saved, and waits quietly once that sign-in is old.
    func testGrokCreditsFromTheCLISignIn() throws {
        let folder = root.appendingPathComponent(".grok")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        func signIn(_ expires: String) throws {
            try JSONSerialization.data(withJSONObject: ["https://accounts.x.ai/sign-in": ["key": "legacy"],
                "https://auth.x.ai::client": ["key": "grok-token", "expires_at": expires]]).write(to: folder.appendingPathComponent("auth.json"))
        }
        let grok = GrokProvider(cache: cache, http: http, home: root, environment: [:])
        expectError(try grok.refresh()); expectEqual(http.calls, 0)
        try signIn("2099-01-01T00:00:00.123456Z")
        http.response = ["config": ["creditUsagePercent": 12.5, "subscriptionTier": "SUPERGROK_HEAVY",
                                    "currentPeriod": ["type": "USAGE_PERIOD_TYPE_WEEKLY", "end": "2099-09-27T18:42:45.537749+00:00"]]]
        try grok.refresh()
        expectEqual(http.sentToken, "grok-token"); expectEqual(http.sentHeaders["x-xai-token-auth"], "xai-grok-cli")
        let panel = grok.panel()
        expectEqual(panel.windows.first?.label, "7d"); expectEqual(panel.windows.first?.pct, 12.5)
        expectNotNil(panel.windows.first?.resets_at); expectEqual(panel.note, "Plan: SuperGrok Heavy")
        // On-demand spend against its cap when there is no credit percentage.
        expectEqual(number(dict(try GrokProvider.windows(["config": ["onDemandCap": ["val": 1000], "onDemandUsed": ["val": 250]]])["month"])["used_percentage"]), 25)
        expectError(try GrokProvider.windows(["subscriptionTier": "SUPERGROK"]))
        try signIn("2020-01-01T00:00:00Z"); http.calls = 0
        do { try grok.refresh(); fail("an old sign-in should wait") } catch let problem as HUDProblem { expectFalse(problem.attention || problem.gone) }
        expectEqual(http.calls, 0)
    }
    /// Kimi Code reports counts as strings (a zero may be missing) and, on newer plans, a ratio per pool.
    func testKimiCodeWindowsAndPlan() throws {
        let blob = try KeyProvider.kimiCodeUsage([
            "user": ["membership": ["level": "LEVEL_INTERMEDIATE"]],
            "usage": ["limit": "2048", "used": "512", "resetTime": "2099-01-09T15:23:13.716839300Z"],
            "limits": [["window": ["duration": 300, "timeUnit": "TIME_UNIT_MINUTE"], "detail": ["limit": "200", "remaining": "50"]]],
            "usages": ["limit_5h": ["used_ratio": 0, "reset_time": "2099-01-06T13:33:02Z"], "limit_month_total": ["used_ratio": 0.5]]])
        let windows = dict(blob["rate_limits"])
        expectEqual(number(dict(windows["w10080"])["used_percentage"]), 25)
        expectNotNil(resetTime(dict(windows["w10080"])["resets_at"]))
        // A placeholder zero ratio doesn't hide real counts.
        expectEqual(number(dict(windows["w300"])["used_percentage"]), 75)
        expectEqual(number(dict(windows["month"])["used_percentage"]), 50)
        expectEqual(blob["plan"] as? String, "Allegretto")
        expectError(try KeyProvider.kimiCodeUsage(["usage": ["limit": "0"]]))
    }
    /// kimi-cli's own config holds the plan's key; a Moonshot key under KIMI_API_KEY is not taken for one.
    func testKimiCodeFindsKimiCLIKey() throws {
        let folder = root.appendingPathComponent(".kimi")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try "[providers.moonshot]\ntype = \"kimi\"\nbase_url = \"https://api.moonshot.ai/v1\"\napi_key = \"sk-moonshot-0000000000000000\"\n\n[providers.\"managed:kimi-code\"]\ntype = \"kimi\"\nbase_url = \"https://api.kimi.com/coding/v1\"\napi_key = \"sk-kimi-1111111111111111\"\n"
            .write(to: folder.appendingPathComponent("config.toml"), atomically: true, encoding: .utf8)
        expectEqual(KeyProvider.kimiCLIKeys(home: root, environment: [:]), ["api.kimi.com": "sk-kimi-1111111111111111"])
        let none = root.appendingPathComponent("none")
        expectEqual(KeyProvider.kimiCLIKeys(home: none, environment: ["KIMI_API_KEY": "sk-moonshot-0000000000000000"]), [:])
        credentials.missing = ["Usage HUD Kimi Code"]
        http.response = ["usage": ["limit": "100", "used": "10"]]
        let provider = KeyProvider.kimiCode(cache: cache, credentials: credentials, http: http, home: root, environment: [:])
        try provider.refresh()
        expectEqual(http.sentToken, "sk-kimi-1111111111111111")
        expectEqual(provider.panel().windows.first?.label, "7d")
    }
    /// An xAI management key names its team; a prepaid team shows money left, a team billed afterwards its spend.
    func testXAIBillingFromAManagementKey() throws {
        var paths: [String] = []
        http.handler = { url in
            paths.append(url.path)
            if url.path.hasSuffix("validation") { return ["scope": "SCOPE_TEAM", "scopeId": "team-1", "teamId": "old"] }
            if url.path.hasSuffix("prepaid/balance") { return ["total": ["val": "-1050"]] }
            return ["effectiveSpendingLimit": "20000", "coreInvoice": ["amountBeforeVat": "5000"]]
        }
        let blob = try KeyProvider.xaiBilling(KeyProvider.Call(host: "management-api.x.ai", key: "k", http: http))
        expectTrue(paths.contains("/v1/billing/teams/team-1/prepaid/balance"))
        expectEqual(number(blob["balance"]), 10.5); expectEqual(number(blob["spent"]), 50); expectEqual(number(blob["limit"]), 200)
        http.handler = { url in
            if url.path.hasSuffix("validation") { return ["teamId": "team-2"] }
            return url.path.hasSuffix("prepaid/balance") ? ["total": ["val": "0"]] : ["effectiveSpendingLimit": "20000", "coreInvoice": ["amountBeforeVat": "5000"]]
        }
        let postpaid = try KeyProvider.xaiBilling(KeyProvider.Call(host: "management-api.x.ai", key: "k", http: http))
        expectNil(postpaid["balance"]); expectEqual(number(dict(dict(postpaid["rate_limits"])["month"])["used_percentage"]), 25)
        http.handler = { _ in ["scope": "SCOPE_ORGANIZATION", "scopeId": "org"] }
        expectError(try KeyProvider.xaiBilling(KeyProvider.Call(host: "management-api.x.ai", key: "k", http: http)))
    }
    /// Fireworks' account comes from the key itself, and its monthly spend limit gives the battery a share.
    func testFireworksSpendAgainstTheMonthlyLimit() throws {
        credentials.missing = ["Usage HUD Fireworks"]
        http.handler = { url in
            if url.path == "/verifyApiKey" { return ["header": ["x-fireworks-account-id": "my-team"]] }
            expectEqual(url.path, "/v1/accounts/my-team/quotas/monthly-spend-usd")
            return ["name": "accounts/my-team/quotas/monthly-spend-usd", "value": "50", "maxValue": "50", "usage": 12.5]
        }
        let provider = KeyProvider.fireworks(cache: cache, credentials: credentials, http: http, home: root, environment: ["FIREWORKS_API_KEY": "fw_0123456789abcdef"])
        try provider.refresh()
        let panel = provider.panel()
        expectEqual(panel.windows.first?.pct, 25); expectEqual(panel.windows.last?.right, "$12.50 / $50 · this month")
        expectEqual(try KeyProvider.fireworksSpend(KeyProvider.Call(host: "api.fireworks.ai", key: "k", http: http), account: "accounts/my-team")["limit"] as? Double, 50)
        expectError(try KeyProvider.fireworksSpend(KeyProvider.Call(host: "api.fireworks.ai", key: "k", http: http), account: "../x"))
    }
    /// A LiteLLM key reads its own budget; a gateway Claude Code uses that isn't LiteLLM is asked once, then left alone.
    func testLiteLLMBudgetAndOtherGateways() throws {
        http.handler = { url in
            expectEqual(url.absoluteString, "http://localhost:4000/key/info")
            return ["key": "hash", "info": ["spend": 12.5, "max_budget": 50, "budget_reset_at": "2099-11-01T00:00:00Z"]]
        }
        let none = root.appendingPathComponent("none")
        let proxy = KeyProvider.liteLLM(cache: cache, credentials: credentials, http: http, home: none,
                                        environment: ["LITELLM_PROXY_API_BASE": "http://localhost:4000/v1", "LITELLM_PROXY_API_KEY": "sk-0123456789abcdef"])
        try proxy.refresh()
        expectEqual(credentials.calls, 0)
        let panel = proxy.panel()
        expectEqual(panel.windows.first?.label, "Budget"); expectEqual(panel.windows.first?.pct, 25)
        expectEqual(panel.windows.last?.right, "$12.50 / $50")
        expectEqual(try KeyProvider.liteLLMBudget(KeyProvider.Call(host: "http://localhost:4000", key: "k", http: http))["limit"] as? Double, 50)
        // A key with no budget shows what it spent, and that is never a low balance.
        http.handler = { _ in ["info": ["spend": 3, "max_budget": NSNull()]] }
        let open = try KeyProvider.liteLLMBudget(KeyProvider.Call(host: "http://localhost:4000", key: "k", http: http))
        expectNil(open["limit"]); try cache.write("litellm.json", open)
        expectEqual(proxy.panel().windows.map { $0.label + " " + ($0.right ?? "") }, ["LiteLLM $3 spent"])
        let engine = Engine(root: root, credentials: credentials, http: http, providers: [proxy])
        expectNil(engine.panels().first?.alert)
        // Claude Code pointed at its own provider is not a proxy; another gateway is tried once.
        expectEqual(KeyProvider.liteLLMProxies(home: none, environment: ["ANTHROPIC_BASE_URL": "https://api.z.ai/api/anthropic", "ANTHROPIC_AUTH_TOKEN": "t"]), [:])
        let gateway = KeyProvider.liteLLM(cache: cache, credentials: credentials, http: http, home: none,
                                          environment: ["ANTHROPIC_BASE_URL": "https://gateway.example.com/anthropic", "ANTHROPIC_AUTH_TOKEN": "t"])
        http.handler = { _ in throw HTTPFailure(status: 404) }; http.calls = 0
        expectError(try gateway.refresh()); expectError(try gateway.refresh())
        expectEqual(http.calls, 1)
    }
    /// Review fixes: postpaid-only xAI teams, underscores in Fireworks accounts, a gateway that is down, public http.
    func testReviewFixesForNewReaders() throws {
        http.handler = { url in
            if url.path.hasSuffix("validation") { return ["teamId": "team-3"] }
            if url.path.hasSuffix("prepaid/balance") { throw HTTPFailure(status: 404) }
            return ["effectiveSpendingLimit": "20000", "coreInvoice": ["amountBeforeVat": "5000"]]
        }
        let postpaid = try KeyProvider.xaiBilling(KeyProvider.Call(host: "management-api.x.ai", key: "k", http: http))
        expectNil(postpaid["balance"]); expectEqual(number(postpaid["spent"]), 50)
        http.handler = { _ in ["value": "50", "usage": 1] }
        expectEqual(try KeyProvider.fireworksSpend(KeyProvider.Call(host: "api.fireworks.ai", key: "k", http: http), account: "team_prod")["limit"] as? Double, 50)
        let none = root.appendingPathComponent("none")
        expectEqual(KeyProvider.liteLLMProxies(home: none, environment: ["ANTHROPIC_BASE_URL": "http://gateway.example.com", "ANTHROPIC_AUTH_TOKEN": "t"]), [:])
        expectEqual(KeyProvider.liteLLMProxies(home: none, environment: ["ANTHROPIC_BASE_URL": "http://192.168.1.5:4000", "ANTHROPIC_AUTH_TOKEN": "t"]), ["http://192.168.1.5:4000": "t"])
        expectEqual(KeyProvider.liteLLMProxies(home: none, environment: ["ANTHROPIC_BASE_URL": "https://api.openai.com/v1", "ANTHROPIC_AUTH_TOKEN": "t"]), [:])
        // A gateway that times out is left alone for the next refreshes instead of costing 30 s each time.
        let gateway = KeyProvider.liteLLM(cache: cache, credentials: credentials, http: http, home: none,
                                          environment: ["ANTHROPIC_BASE_URL": "https://gateway.example.com/anthropic", "ANTHROPIC_AUTH_TOKEN": "t"])
        http.handler = { _ in throw HUDProblem("Usage request timed out") }; http.calls = 0
        expectError(try gateway.refresh()); expectError(try gateway.refresh())
        expectEqual(http.calls, 1)
    }
    /// OpenRouter: amber under $15, a pulse under $10; the body is as full as the tightest capped key.
    func testOpenRouterBalanceLevelsAndGauge() throws {
        func levels(_ total: Double) throws -> Panel {
            http.handler = { url in
                url.path.hasSuffix("credits") ? ["data": ["total_credits": total, "total_usage": 0]]
                    : ["data": ["usage": 1, "usage_daily": 0, "limit": 5, "limit_remaining": 4, "limit_reset": "daily"]]
            }
            let provider = OpenRouterProvider(cache: cache, credentials: credentials, http: http, home: root, environment: ["OPENROUTER_API_KEY": "sk-or-v1-" + String(repeating: "e5", count: 32)])
            try provider.refresh()
            return Engine(root: root, credentials: credentials, http: http, providers: [provider]).panels()[0]
        }
        var panel = try levels(20)
        expectNil(panel.caution); expectNil(panel.alert); expectEqual(panel.gauge ?? 0, 0.8, accuracy: 0.001)
        panel = try levels(12)
        expectEqual(panel.caution, "Balance under $15"); expectNil(panel.alert)
        panel = try levels(9)
        expectEqual(panel.alert, "Balance low"); expectEqual(panel.caution, "Balance under $15")
    }
    func testUnusedPlansStayOutOfMenuBar() {
        let engine = Engine(root: root, credentials: credentials, http: http)
        expectEqual(engine.panels().map(\.id), [])
        try? cache.write("claude.json", ["captured_at": 1])
        expectEqual(engine.panels().map(\.id), ["claude"])
    }

    func testBalanceParsers() throws {
        let vercel = try KeyProvider.vercelBalance(["balance": "95.50", "total_used": "4.50"], "ai-gateway.vercel.sh")
        expectEqual(vercel.0, 95.5); expectEqual(vercel.1, "$")
        let deepSeek = try KeyProvider.deepSeekBalance(["is_available": true, "balance_infos": [
            ["currency": "CNY", "total_balance": "110.00"], ["currency": "USD", "total_balance": "12.30"]]], "api.deepseek.com")
        expectEqual(deepSeek.0, 12.3); expectEqual(deepSeek.1, "$")
        let yuan = try KeyProvider.deepSeekBalance(["balance_infos": [["currency": "CNY", "total_balance": "110.00"]]], "api.deepseek.com")
        expectEqual(yuan.1, "¥")
        let kimi = try KeyProvider.kimiBalance(["code": 0, "data": ["available_balance": 49.58894]], "api.moonshot.cn")
        expectEqual(kimi.0, 49.58894); expectEqual(kimi.1, "¥")
        expectError(try KeyProvider.vercelBalance([:], "ai-gateway.vercel.sh"))
    }
    func testKeyProviderFallsBackToSecondHostAndShowsMoney() throws {
        http.handler = { url in
            if url.host == "api.moonshot.ai" { throw HTTPFailure(status: 401) }
            return ["data": ["available_balance": 3.5]]
        }
        let provider = KeyProvider.kimi(cache: cache, credentials: credentials, http: http)
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
        // A first sighting with quota spent counts a little; a balance or a falling quota (a window reset) doesn't.
        shelf.observe(quota("glm", 40), now: 10); shelf.observe(balance("kimi", "¥9.00 left"), now: 10)
        shelf.observe(quota("glm", 5), now: 20)
        expectEqual(shelf.arrange(ids, limit: 3).hidden, ["openrouter", "kimi"])
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
        expectEqual(provider.panel().windows.first { $0.label == "Extra usage" }?.right, "$12.34 / $50 · this month")
        try cache.merge("claude.json", ["usage_credits": ["is_enabled": true, "monthly_limit": NSNull(), "used_credits": 250]])
        expectEqual(provider.panel().windows.first { $0.label == "Extra usage" }?.right, "$2.50 · this month")
        try cache.merge("claude.json", ["usage_credits": ["is_enabled": false, "user_disabled": true, "used_credits": NSNull()]])
        expectEqual(provider.panel().windows.first { $0.label == "Extra usage" }?.right, "Off")
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
        expectEqual(panels[1].alert, "Balance low")
        expectNil(panels[2].alert)
        engine.lowBalance = 0.25
        expectNil(engine.panels(refresh: nil)[1].alert)
    }
    func testRouterKeyCapUsesOpenRouterNumbersAndAlerts() throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let config = [["id": "one", "label": "One", "sources": [["provider": "openrouter", "service": "fixture", "account": "one"]]]]
        try JSONSerialization.data(withJSONObject: config).write(to: root.appendingPathComponent("providers.json"))
        http.handler = { url in
            url.path.hasSuffix("credits") ? ["data": ["total_credits": 50, "total_usage": 7]]
                : ["data": ["usage": 120, "usage_daily": 4.6, "limit": 5, "limit_remaining": 0.4, "limit_reset": "daily"]]
        }
        let provider = OpenRouterProvider(cache: cache, credentials: credentials, http: http)
        try provider.refresh()
        let panel = provider.panel()
        expectEqual(panel.windows.first?.right, "$43 left")
        expectTrue(panel.windows[1].right?.hasPrefix("$4.60 / $5 · ↻ ") == true)
        expectEqual(panel.alert, "One: near its cap")
    }
    func testRouterCapsResetOnUTCBoundaries() {
        let saturday = Date(timeIntervalSince1970: 1791039600) // 2026-10-03 15:00 UTC
        expectEqual(OpenRouterProvider.nextReset("daily", after: saturday)?.timeIntervalSince1970, 1791072000)
        expectEqual(OpenRouterProvider.nextReset("weekly", after: saturday)?.timeIntervalSince1970, 1791158400)
        expectEqual(OpenRouterProvider.nextReset("monthly", after: saturday)?.timeIntervalSince1970, 1793491200)
        expectNil(OpenRouterProvider.nextReset(nil, after: saturday))
        expectEqual(Shelf().arrange(["codex", "claude", "openrouter", "kimi"], limit: 3, urgent: ["kimi"]).hidden, ["openrouter"])
    }
    func testRouterTeamListsEveryKeyWithoutPulsing() throws {
        credentials.missing = []
        let first: [JSON] = (0..<100).map { ["name": "k\($0)", "usage_daily": 0.5, "limit": 5, "limit_reset": "daily",
                                              "limit_remaining": $0 == 7 ? 0.2 : 4.5, "disabled": $0 == 99] }
        http.handler = { url in
            if url.path.hasSuffix("credits") { return ["data": ["total_credits": 50, "total_usage": 7]] }
            return ["data": url.query == "offset=0" ? first : [["name": "", "label": "sk-or-v1-abc", "usage_daily": 1]]]
        }
        let provider = OpenRouterProvider(cache: cache, credentials: credentials, http: http, home: root, environment: [:])
        expectTrue(provider.automatic)
        try provider.refresh()
        let panel = provider.panel()
        expectEqual(panel.windows.first?.right, "$43 left")
        expectEqual(panel.cellsTitle, "100 keys · $50.50 today · 1 near cap")
        expectEqual(panel.cells.first?.label, "k7"); expectEqual(panel.cells.last?.label, "sk-or-v1-abc")
        expectNil(panel.alert); expectNil(panel.displayedQuota)
        http.handler = { _ in throw HTTPFailure(status: 401) }
        do { try provider.refresh(); fail("Expected rejection") } catch { expectTrue((error as? HUDProblem)?.attention == true) }
        expectEqual(provider.panel().cells.count, 100)
    }
    func testKeysAlreadyOnTheMacNeedNoSetup() throws {
        let alice = "sk-or-v1-" + String(repeating: "a1", count: 32), bob = "sk-or-v1-" + String(repeating: "b2", count: 32)
        let carol = "sk-or-v1-" + String(repeating: "c3", count: 32)
        let opencode = root.appendingPathComponent(".local/share/opencode")
        try FileManager.default.createDirectory(at: opencode, withIntermediateDirectories: true)
        try "{\"openrouter\":{\"type\":\"api\",\"key\":\"\(alice)\"}}".write(to: opencode.appendingPathComponent("auth.json"), atomically: true, encoding: .utf8)
        try "export OPENROUTER_API_KEY=sk-or-v1-short\nexport OPENROUTER_API_KEY=\(bob)\nexport ALICE_OPENROUTER_KEY='\(alice)'".write(to: root.appendingPathComponent(".zshrc"), atomically: true, encoding: .utf8)
        try "OPENROUTER_API_KEY=\(carol) agent run\n# \(bob)".write(to: root.appendingPathComponent("boot-carol.sh"), atomically: true, encoding: .utf8)
        // Organised folders are searched; guarded and too-deep ones are not.
        for (folder, key) in [("team/research", "d4"), ("Documents", "e5"), ("a/b/c/d", "f6")] {
            let url = root.appendingPathComponent(folder)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            try "export DANA_KEY=sk-or-v1-\(String(repeating: key, count: 32))".write(to: url.appendingPathComponent("run.sh"), atomically: true, encoding: .utf8)
        }
        let found = KeyFinder.find(in: KeyFinder.places(home: root), environment: [:])
        expectEqual(found.map { $0.label }, ["zshrc", "alice", "boot-carol", "dana"])
        expectEqual(found.map { $0.key }, [bob, alice, carol, "sk-or-v1-" + String(repeating: "d4", count: 32)])
        expectEqual(KeyFinder.label(opencode.appendingPathComponent("auth.json")), "opencode")
        expectEqual(KeyFinder.find(in: [], environment: ["OPENROUTER_API_KEY": alice + "\n" + bob]).map { $0.label }, ["environment", "environment 2"])
        http.handler = { url in url.path.hasSuffix("credits") ? ["data": ["total_credits": 9, "total_usage": 1]] : ["data": ["usage": 3, "usage_daily": 0.25]] }
        let provider = OpenRouterProvider(cache: cache, credentials: credentials, http: http, home: root, environment: [:])
        expectTrue(provider.automatic)
        try provider.refresh()
        expectEqual(provider.panel().windows.map { $0.label }, ["OpenRouter", "zshrc", "alice", "boot-carol", "dana"])
        expectFalse(String(data: try Data(contentsOf: root.appendingPathComponent("openrouter.json")), encoding: .utf8)!.contains("sk-or-v1-"))
    }
    /// A Keychain password prompt may follow a click on Refresh, never a background timer.
    func testKeychainPromptNeverReturnsOnItsOwn() throws {
        let provider = PromptingProvider()
        let engine = Engine(root: root, credentials: credentials, http: http, providers: [provider])
        expectEqual(engine.panels(refresh: "automatic")[0].alert, "Keychain asked")
        _ = engine.panels(refresh: "automatic"); expectEqual(provider.calls, 1)
        _ = engine.panels(refresh: "p"); expectEqual(provider.calls, 2)
        credentials.missing = ["absent"]
        let absent = try credentials.stored(service: "absent", account: nil), present = try credentials.stored(service: "present", account: nil)
        expectNil(absent); expectEqual(present, "fixture")
    }
    /// An app opened from Finder has a bare PATH; npm and nvm installs must still be found and able to reach node.
    func testCLIsFoundOutsideTheAppsBarePATH() throws {
        let old = root.appendingPathComponent(".nvm/versions/node/v9.0.0/bin"), new = root.appendingPathComponent(".nvm/versions/node/v22.1.0/bin")
        for folder in [old, new] {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let file = folder.appendingPathComponent("usagehud-fake-cli")
            try "#!/bin/sh\n".write(to: file, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
        }
        let found = CLI.find("usagehud-fake-cli", home: root, environment: ["PATH": "/usr/bin:/bin"])
        expectEqual(found?.path, new.appendingPathComponent("usagehud-fake-cli").path)
        expectEqual(CLI.environment(for: found!, ["PATH": "/usr/bin:/opt/homebrew/bin:/bin"])["PATH"], new.path + ":/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin")
        expectEqual(CLI.find("usagehud-fake-cli", configured: old.appendingPathComponent("usagehud-fake-cli").path, home: root, environment: [:])?.path,
                    old.appendingPathComponent("usagehud-fake-cli").path)
        expectNil(CLI.find("usagehud-fake-cli", configured: "relative/cli", home: root.appendingPathComponent("none"), environment: [:]))
    }
    /// GLM Coding Plan users already gave Claude Code their key; a lookalike domain gets nothing.
    func testGLMKeyComesFromClaudeCodeSettings() throws {
        credentials.missing = [GLMProvider.service]
        let settings = root.appendingPathComponent(".claude")
        try FileManager.default.createDirectory(at: settings, withIntermediateDirectories: true)
        try "{\"env\":{\"ANTHROPIC_BASE_URL\":\"https://open.bigmodel.cn/api/anthropic\",\"ANTHROPIC_AUTH_TOKEN\":\"cc-key\"}}"
            .write(to: settings.appendingPathComponent("settings.json"), atomically: true, encoding: .utf8)
        http.handler = { url in
            expectEqual(url.host, "open.bigmodel.cn")
            return ["data": ["limits": [["type": "TOKENS_LIMIT", "unit": 3, "number": 5, "percentage": 20]]]]
        }
        try GLMProvider(cache: cache, credentials: credentials, http: http, home: root, environment: [:]).refresh()
        expectEqual(http.sentHeaders["Authorization"], "cc-key")
        let none = root.appendingPathComponent("none")
        expectEqual(GLMProvider.found(home: none, environment: ["ANTHROPIC_BASE_URL": "https://evilz.ai/api", "ANTHROPIC_AUTH_TOKEN": "x"]), [:])
        expectEqual(GLMProvider.found(home: none, environment: ["ANTHROPIC_BASE_URL": "https://api.z.ai/api/anthropic", "ANTHROPIC_API_KEY": "y"]), ["api.z.ai": "y"])
        expectEqual(GLMProvider.found(home: none, environment: ["ANTHROPIC_BASE_URL": "https://api.anthropic.com", "ANTHROPIC_AUTH_TOKEN": "z"]), [:])
    }
    /// A management key sitting in a script lists the team by itself, and your own keys show once, not twice.
    func testManagementKeyOnTheMacListsTheTeam() throws {
        let guy = "sk-or-v1-" + String(repeating: "a1", count: 32), boss = "sk-or-v1-" + String(repeating: "b2", count: 32)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try "export GUY1_OPENROUTER_KEY=\(guy)\nexport OPENROUTER_MANAGEMENT_KEY=\(boss)".write(to: root.appendingPathComponent(".zshrc"), atomically: true, encoding: .utf8)
        http.handler = { url in
            if url.path.hasSuffix("credits") { return ["data": ["total_credits": 30, "total_usage": 4]] }
            if url.path.hasSuffix("/keys") { return ["data": [["name": "Guy1", "label": "sk-or-v1-a1a", "usage_daily": 1],
                                                              ["name": "Other", "label": "sk-or-v1-c3c", "usage_daily": 2]]] }
            return ["data": ["usage": 1, "label": "sk-or-v1-a1a"]]
        }
        let provider = OpenRouterProvider(cache: cache, credentials: credentials, http: http, home: root, environment: [:])
        try provider.refresh()
        let panel = provider.panel()
        expectEqual(panel.cells.map { $0.label }, ["guy1", "Other"])
        expectEqual(panel.cellsTitle, "2 keys · $3 today")
        expectFalse(panel.windows.contains { $0.label == "management" })
    }
    /// A revoked key left in an old script is skipped, and with nothing working OpenRouter stays out of sight.
    func testRevokedFoundKeyStaysQuiet() throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try "export OPENROUTER_API_KEY=sk-or-v1-\(String(repeating: "d4", count: 32))".write(to: root.appendingPathComponent(".zshrc"), atomically: true, encoding: .utf8)
        http.handler = { _ in throw HTTPFailure(status: 401) }
        let provider = OpenRouterProvider(cache: cache, credentials: credentials, http: http, home: root, environment: [:])
        expectError(try provider.refresh())
        expectFalse(provider.shown())
    }
    /// Models sharing a quota pool show as one row named by their families; the battery leads with the tightest pool.
    func testAntigravityPoolsModelsThatShareAQuota() throws {
        func model(_ label: String, _ left: Double) -> JSON { ["label": label, "quotaInfo": ["remainingFraction": left, "resetTime": "2099-10-10T00:00:00Z"]] }
        let response: JSON = ["userStatus": ["cascadeModelConfigData": ["clientModelConfigs": [
            model("Claude Opus 4.6 (Thinking)", 0.97), model("Claude Sonnet 4.6", 0.97), model("GPT-OSS 120B (Medium)", 0.97),
            model("Gemini 3.1 Pro (High)", 1), model("Gemini 3.6 Flash (Low)", 1)]]]]
        let provider = AntigravityProvider(cache: cache, read: { response })
        try provider.refresh()
        let panel = provider.panel()
        expectEqual(panel.cells.map { $0.label }, ["Claude & GPT", "Gemini"])
        expectTrue(panel.cells.first?.right?.hasPrefix("↻ ") == true)
        expectEqual(panel.displayedQuota?.label, "Claude & GPT")
        // Closed app: no pulse, last reading kept and still shown.
        let closed = Engine(root: root, credentials: credentials, http: http, providers: [AntigravityProvider(cache: cache, read: { throw HUDProblem("Open Antigravity to update its quota") })])
        let shown = closed.panels(refresh: "automatic")[0]
        expectNil(shown.alert); expectEqual(shown.displayedQuota?.pct ?? 0, 3, accuracy: 0.01)
    }
    /// When every model has its own quota, untouched ones fold into one full row that still names their families.
    func testAntigravityFoldsUntouchedModelsByFamily() throws {
        func model(_ label: String, _ left: Double, _ day: Int) -> JSON { ["label": label, "quotaInfo": ["remainingFraction": left, "resetTime": "2099-10-\(day)T00:00:00Z"]] }
        let response: JSON = ["userStatus": ["cascadeModelConfigData": ["clientModelConfigs": [
            model("Claude Opus", 0.5, 10), model("Claude Sonnet", 0.8, 11), model("Gemini Pro", 0.9, 12),
            model("Gemini Flash", 1, 13), model("GPT-OSS", 1, 14)]]]]
        let provider = AntigravityProvider(cache: cache, read: { response })
        try provider.refresh()
        expectEqual(provider.panel().cells.map { $0.label }, ["Claude Opus", "Claude Sonnet", "Gemini Pro", "GPT & Gemini"])
        expectEqual(provider.panel().cells.last?.pct, 0)
    }
    /// A problem with a known harmless fix carries it to the menu.
    func testSignInProblemsOfferTheirFix() {
        let engine = Engine(root: root, credentials: credentials, http: http, providers: [
            AlertProvider(id: "a", problem: "a needs sign-in", attention: true, right: "$9.00 left")])
        expectNil(engine.panels(refresh: "automatic")[0].fix)
        // An old token only means Claude Code sat idle: no sign-in, no red battery.
        credentials.text = "{\"claudeAiOauth\":{\"accessToken\":\"t\",\"expiresAt\":1000}}"
        try? cache.write("claude.json", ["captured_at": 1])
        let claude = { (refresh: String?) in Engine(root: self.root, credentials: self.credentials, http: self.http).panels(refresh: refresh).first { $0.id == "claude" } }
        let idle = claude("claude")
        expectTrue(idle?.fix == nil && idle?.alert == nil && idle?.note.contains("Code tab") == true)
        // A rejected token is a real sign-out, and the menu offers the sign-in.
        credentials.text = "{\"claudeAiOauth\":{\"accessToken\":\"t\",\"expiresAt\":99999999999999}}"
        http.error = HTTPFailure(status: 401)
        let out = claude("claude")
        expectTrue(out?.fix == "claude auth login" && out?.alert != nil)
        // A newer reading from Claude Code's statusline means it healed by itself.
        try? cache.quota("claude.json", windows: ["five_hour": ["used_percentage": 30]], now: Date().timeIntervalSince1970 + 5)
        let healed = claude(nil)
        expectTrue(healed?.fix == nil && healed?.alert == nil && healed?.note == "")
    }
    func testShelfLearnsEachPersonsMainTools() {
        func quota(_ id: String, _ pct: Double) -> Panel { Panel(id: id, name: id, windows: [Window(label: "5h", pct: pct)]) }
        func balance(_ id: String, _ amount: Double) -> Panel { Panel(id: id, name: id, windows: [Window(label: id, right: String(format: "$%.2f left", amount))]) }
        var shelf = Shelf()
        let ids = ["codex", "claude", "openrouter", "glm", "kimi"]
        // Someone living on GLM and Kimi: a day and a half of steady use.
        var glm = 0.0, kimi = 100.0, now = 0.0
        shelf.observe(quota("glm", glm), now: 0); shelf.observe(balance("kimi", kimi), now: 0); shelf.observe(quota("codex", 0), now: 0)
        for step in 1...200 {
            now = Double(step) * 600; glm += 0.2; kimi -= 0.1
            shelf.observe(quota("glm", glm), now: now); shelf.observe(balance("kimi", kimi), now: now)
        }
        // Codex, tried just now, doesn't push them out.
        shelf.observe(quota("codex", 3), now: now + 60)
        expectEqual(Array(shelf.ranked(ids).prefix(3)), ["glm", "kimi", "codex"])
        expectEqual(shelf.arrange(ids, limit: 2).shown, ["glm", "kimi"])
        expectEqual(shelf.arrange(ids, limit: 2, urgent: ["openrouter"]).shown, ["openrouter", "glm"])
        // A week later, every score has halved.
        let before = shelf.scores["glm"]!
        shelf.observe(quota("glm", glm), now: now + 60 + 604_800)
        expectTrue(abs(shelf.scores["glm"]! - before / 2) < 0.01)
        // A tool reporting every 30 seconds counts no more than one reporting every five minutes.
        var chatty = Shelf()
        chatty.observe(quota("claude", 0), now: 0)
        for step in 1...20 { chatty.observe(quota("claude", Double(step)), now: Double(step) * 30) }
        expectTrue(abs(chatty.scores["claude"]! - 3) < 0.01)
    }
    /// DeepSeek, Kimi and Vercel keys people already keep need no setup, and a stale one stays quiet.
    func testBalanceKeysAlreadyOnTheMac() throws {
        credentials.missing = ["Usage HUD DeepSeek", "Usage HUD Kimi", "Usage HUD Vercel"]
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try "export OLD_DEEPSEEK_API_KEY=sk-ffffffffffffffffffff\nexport DEEPSEEK_API_KEY=\"sk-0123456789abcdef0123\"\n"
            .write(to: root.appendingPathComponent(".zshrc"), atomically: true, encoding: .utf8)
        http.handler = { url in
            expectEqual(url.host, "api.deepseek.com")
            return ["balance_infos": [["currency": "USD", "total_balance": "7.00"]]]
        }
        try KeyProvider.deepSeek(cache: cache, credentials: credentials, http: http, home: root, environment: [:]).refresh()
        expectEqual(http.sentToken, "sk-0123456789abcdef0123")
        let none = root.appendingPathComponent("none")
        let kimi = KeyProvider.kimi(cache: cache, credentials: credentials, http: http, home: none,
                                        environment: ["ANTHROPIC_BASE_URL": "https://api.moonshot.ai/anthropic", "ANTHROPIC_AUTH_TOKEN": "kimi-cc-key"])
        http.handler = { _ in ["data": ["available_balance": 2.0]] }
        try kimi.refresh()
        expectEqual(http.sentToken, "kimi-cc-key")
        http.error = HTTPFailure(status: 401)
        do { try kimi.refresh(); fail("a rejected key should fail") } catch let problem as HUDProblem { expectFalse(problem.attention) }
        http.error = nil; http.calls = 0
        expectError(try KeyProvider.vercel(cache: cache, credentials: credentials, http: http, home: none, environment: [:]).refresh())
        expectEqual(http.calls, 0)
    }
    /// Someone who clicked Allow rather than Always Allow is asked again only when the item changes.
    func testKeychainAsksForASecretOnlyWhenItChanges() throws {
        var stamp = "mdat 1", secrets = 0, missing = false
        let reader = KeychainReader { arguments in
            if missing { return ("", 0.1) }
            if arguments.last == "-w" { secrets += 1; return ("secret " + stamp, 3) }
            return (stamp, 0.1)
        }
        expectEqual(try reader.password(service: "s", account: nil), "secret mdat 1")
        expectEqual(try reader.password(service: "s", account: nil), "secret mdat 1")
        expectEqual(secrets, 1)
        stamp = "mdat 2"
        expectEqual(try reader.password(service: "s", account: nil), "secret mdat 2")
        expectEqual(secrets, 2)
        missing = true
        do { _ = try reader.password(service: "s", account: nil); fail("a missing item should fail") } catch let problem as HUDProblem { expectFalse(problem.prompted) }
        let refused = KeychainReader { $0.last == "-w" ? ("", 5.0) : ("mdat", 0.1) }
        do { _ = try refused.password(service: "s", account: nil); fail("a refused prompt should fail") } catch let problem as HUDProblem { expectTrue(problem.prompted) }
    }
    /// While Claude Code's statusline reports, the Keychain is not touched; credits still update hourly.
    func testClaudeLeavesTheKeychainAloneWhileItsStatuslineReports() throws {
        _ = try Engine(root: root, credentials: credentials, http: http)
            .statusline(JSONSerialization.data(withJSONObject: ["rate_limits": ["five_hour": ["used_percentage": 12]]]))
        try cache.merge("claude.json", ["oauth_at": Date().timeIntervalSince1970])
        try ClaudeProvider(cache: cache, credentials: credentials, http: http).refresh()
        expectEqual(credentials.calls, 0); expectEqual(http.calls, 0)
        try cache.merge("claude.json", ["oauth_at": 0])
        credentials.text = "{\"accessToken\":\"fixture\"}"; http.response = ["five_hour": ["utilization": 12]]
        try ClaudeProvider(cache: cache, credentials: credentials, http: http, home: root).refresh()
        expectEqual(http.calls, 2)
    }
    /// A provider in use refreshes between background passes, but a paused one stays paused.
    func testProvidersInUseRefreshBetweenPasses() {
        let prompting = PromptingProvider()
        let engine = Engine(root: root, credentials: credentials, http: http, providers: [FakeProvider(id: "bad", fail: true), prompting])
        expectEqual(engine.panels(also: ["bad"]).first?.note, "offline")
        _ = engine.panels(refresh: "p"); _ = engine.panels(also: ["p"])
        expectEqual(prompting.calls, 1)
    }
    /// Removing an app, CLI or key takes its battery away; a closed app or an outage only dims it; all come back by themselves.
    func testBatteriesLeaveWithTheirSource() throws {
        let provider = SwitchProvider()
        let engine = Engine(root: root, credentials: credentials, http: http, providers: [provider])
        expectEqual(engine.panels(refresh: "automatic").count, 1)
        provider.problem = HUDProblem("Open Antigravity to update its quota")
        expectEqual(engine.panels(refresh: "automatic").first?.note, "Open Antigravity to update its quota")
        provider.problem = HUDProblem("Antigravity isn't installed", gone: true)
        expectEqual(engine.panels(refresh: "automatic").count, 0)
        provider.problem = nil
        expectEqual(engine.panels(refresh: "automatic").count, 1)
        provider.problem = HUDProblem("offline")
        expectEqual(engine.panels(refresh: "automatic").count, 1)
        var status = cache.read("s-status.json")
        status["ok_at"] = Date().timeIntervalSince1970 - 8 * 86400
        try cache.write("s-status.json", status)
        expectEqual(engine.panels().count, 0)
    }
}
