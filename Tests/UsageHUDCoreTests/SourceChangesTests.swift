import Foundation
@testable import UsageHUDCore

extension CoreTests {
    func sourcePanel(_ id: String, source: ReadingSource = .providerAPI, time: Double = 1000) -> Panel {
        var panel = Panel(id: id, name: id == "claude" ? "Claude" : id, windows: [Window(label: "5h", pct: 25)])
        panel.readingSource = source; panel.sourceReadAt = time
        return panel
    }
    func testSourceNoticesStartQuietAndDeduplicate() {
        var changes = SourceChanges()
        let claude = sourcePanel("claude", source: .claudeStatusline)
        expectNil(changes.update(panels: [claude], announce: false, now: 1000))
        expectNil(changes.update(panels: [claude], now: 1001))
        let router = sourcePanel("OpenRouter")
        expectEqual(changes.update(panels: [claude, router], now: 1001)?.title, "Tracking OpenRouter")
        expectNil(changes.update(panels: [router, claude], now: 1002))
        var oauth = claude; oauth.readingSource = .claudeOAuth
        expectNil(changes.update(panels: [oauth, router], now: 1003))
        expectEqual(SourceNotice.duration, 6)
        var pending = SourceChanges()
        let empty = Panel(id: "claude", name: "Claude", note: "Waiting for the first reading")
        _ = pending.update(panels: [empty], announce: false, now: 1000)
        expectNil(pending.update(panels: [], gone: ["claude"], now: 1001))
        expectEqual(pending.update(panels: [claude], now: 1002)?.title, "Tracking Claude")
    }
    func testSourceNoticeNeedsFreshSuccessfulData() {
        var changes = SourceChanges()
        var panel = sourcePanel("claude", source: .claudeStatusline)
        panel.windows[0].stale = true
        expectNil(changes.update(panels: [panel], now: 1001))
        panel.windows[0].stale = false
        expectNil(changes.update(panels: [panel], now: 1601))
        panel.sourceReadAt = nil
        expectNil(changes.update(panels: [panel], now: 1001))
        panel.sourceReadAt = 1000; panel.readingSource = nil
        expectNil(changes.update(panels: [panel], now: 1001))
        panel.readingSource = .claudeStatusline; panel.windows = []
        expectNil(changes.update(panels: [panel], now: 1001))
        panel.windows = [Window(label: "7d", pct: 30)]
        expectTrue(changes.update(panels: [panel], now: 1001)?.lines.first?.contains("statusline") == true)
    }
    func testOutagesAndOverflowAreNotSourceRemovals() {
        var changes = SourceChanges()
        let panel = sourcePanel("claude")
        _ = changes.update(panels: [panel], announce: false, now: 1000)
        expectNil(changes.update(panels: [], now: 1001))
        var old = panel; old.windows[0].stale = true
        expectNil(changes.update(panels: [old], now: 1002))
        expectNil(changes.update(panels: [panel], now: 1003))
        expectEqual(changes.update(panels: [], gone: ["claude"], now: 1004)?.title, "Stopped tracking Claude")
        expectNil(changes.update(panels: [], gone: ["claude"], now: 1005))
        expectEqual(changes.update(panels: [panel], now: 1006)?.title, "Tracking Claude")
    }
    func testSourceChangesGroupAndDescribeActualRoutes() {
        var changes = SourceChanges()
        let claude = sourcePanel("claude", source: .claudeStatusline)
        let codex = sourcePanel("Codex", source: .codexCLI)
        let router = sourcePanel("OpenRouter")
        _ = changes.update(panels: [router], announce: false, now: 1000)
        let notice = changes.update(panels: [claude, codex], gone: ["OpenRouter"], now: 1001)
        expectEqual(notice?.title, "Sources updated")
        expectEqual(notice?.lines.count, 3)
        expectTrue(notice?.lines.contains(where: { $0.contains("statusline") }) == true)
        expectTrue(notice?.lines.contains(where: { $0.contains("Codex CLI") }) == true)
        expectTrue(notice?.lines.contains("No longer tracking: OpenRouter") == true)
        var other = SourceChanges()
        let oauth = other.update(panels: [sourcePanel("claude", source: .claudeOAuth)], now: 1001)
        expectTrue(oauth?.lines.first?.contains("existing sign-in") == true)
        expectTrue(oauth?.lines.first?.contains("statusline") == false)
    }
    func testStatuslineReceiptsIgnoreContextAndMalformedQuota() throws {
        let claude = ClaudeProvider(cache: cache, credentials: credentials, http: http, home: root)
        let engine = Engine(root: root, credentials: credentials, http: http, providers: [claude])
        _ = try engine.statusline(JSONSerialization.data(withJSONObject: ["context_window": ["used_percentage": 45]]))
        expectNil(engine.panels().first?.readingSource)
        _ = try engine.statusline(JSONSerialization.data(withJSONObject: ["rate_limits": ["five_hour": ["used_percentage": true], "other": ["used_percentage": 20]]]))
        expectNil(engine.panels().first?.readingSource)
        _ = try engine.statusline(JSONSerialization.data(withJSONObject: ["rate_limits": ["five_hour": ["used_percentage": 15]]]))
        expectEqual(engine.panels().first?.readingSource, .claudeStatusline)
        let receipt = engine.panels().first?.sourceReadAt
        expectNotNil(receipt)
        _ = try engine.statusline(JSONSerialization.data(withJSONObject: ["context_window": ["used_percentage": 50]]))
        expectEqual(engine.panels().first?.sourceReadAt, receipt)
    }
    func testClaudeFreshStatuslineClearsFailureWithoutOAuth() throws {
        let claude = ClaudeProvider(cache: cache, credentials: credentials, http: http, home: root)
        let engine = Engine(root: root, credentials: credentials, http: http, providers: [claude])
        credentials.text = "{\"accessToken\":\"fixture\",\"expiresAt\":1}"
        try cache.quota("claude.json", windows: ["five_hour": ["used_percentage": 50]], now: 1)
        expectTrue(engine.panels(refresh: "automatic").first?.windows.first?.isCached == true)
        let before = credentials.calls
        _ = try engine.statusline(JSONSerialization.data(withJSONObject: ["rate_limits": ["five_hour": ["used_percentage": 20], "seven_day": ["used_percentage": 30]]]))
        let restored = engine.panels(refresh: "automatic").first
        expectEqual(restored?.readingSource, .claudeStatusline)
        expectEqual(restored?.windows.first?.pct, 20)
        expectTrue(restored?.windows.allSatisfy { !$0.isCached } == true)
        expectEqual(restored?.note, ""); expectNil(restored?.alert)
        expectEqual(credentials.calls, before); expectEqual(http.calls, 0)
    }
    func testGoneEvidenceUsesProviderCacheAndExpiresOnFreshRead() throws {
        let provider = SwitchProvider()
        let engine = Engine(root: root, credentials: credentials, http: http, providers: [provider])
        _ = engine.panels(refresh: "automatic")
        provider.problem = HUDProblem("offline")
        _ = engine.panels(refresh: "automatic")
        expectTrue(engine.goneSources.isEmpty)
        provider.problem = HUDProblem("removed", gone: true)
        _ = engine.panels(refresh: "automatic")
        expectEqual(engine.goneSources, ["s"])
        try cache.quota("s.json", windows: ["five_hour": ["used_percentage": 20]], now: Date().timeIntervalSince1970 + 1)
        expectTrue(engine.goneSources.isEmpty)
        let codex = CodexProvider(cache: cache, credits: OpenAICredits(cache: cache, credentials: credentials, http: http))
        let codexEngine = Engine(root: root, credentials: credentials, http: http, providers: [codex])
        try cache.write("codex-status.json", ["error": "offline", "checked_at": 1, "gone": true])
        try cache.quota("codex-quota.json", windows: ["primary": ["used_percentage": 20]], now: Date().timeIntervalSince1970)
        expectTrue(codexEngine.goneSources.isEmpty)
        expectTrue(codexEngine.panels().first?.windows.first?.isCached == false)
    }
    func testSourceReceiptsPreservePartialWindowProvenance() throws {
        try cache.quota("claude.json", windows: ["five_hour": ["used_percentage": 20], "seven_day": ["used_percentage": 30]],
                        extra: ReadingSource.claudeOAuth.receipt(now: 1000), now: 1000)
        try cache.quota("claude.json", windows: ["five_hour": ["used_percentage": 25]],
                        extra: ReadingSource.claudeStatusline.receipt(now: 1010), now: 1010)
        let windows = dict(cache.read("claude.json")["rate_limits"])
        expectEqual(dict(windows["seven_day"])["reading_source"] as? String, ReadingSource.claudeOAuth.rawValue)
        expectEqual(dict(windows["five_hour"])["reading_source"] as? String, ReadingSource.claudeStatusline.rawValue)
        expectTrue(dict(windows["seven_day"])["stale"] as? Bool == true)
        let decoded = try JSONDecoder().decode(Panel.self, from: JSONSerialization.data(withJSONObject: ["id": "old", "name": "Old", "windows": [], "cells": [], "note": ""]))
        expectNil(decoded.readingSource); expectNil(decoded.sourceReadAt)
    }
    func testAntigravityPaletteFollowsUsageAndModelRemoval() throws {
        var left = ["Gemini Pro": 0.16, "Claude Sonnet": 0.76, "GPT-OSS": 0.76]
        let provider = AntigravityProvider(cache: cache, read: {
            ["userStatus": ["cascadeModelConfigData": ["clientModelConfigs": left.map { label, value -> JSON in
                ["label": label, "quotaInfo": ["remainingFraction": value, "resetTime": "2099-10-10T00:00:00Z"]]
            }]]]
        })
        try provider.refresh()
        expectEqual(provider.panel().displayedQuota?.palette, .google)
        expectEqual(provider.panel().cellsTitle, "3 models")
        left["Claude Sonnet"] = 0.70; left["GPT-OSS"] = 0.70
        try provider.refresh()
        expectEqual(provider.panel().displayedQuota?.palette, .claudeOpenAI)
        left.removeValue(forKey: "GPT-OSS")
        try provider.refresh()
        expectEqual(provider.panel().displayedQuota?.palette, .claude)
        expectEqual(provider.panel().cellsTitle, "2 models")
        expectFalse(provider.panel().cells.contains { $0.label.contains("GPT") })
    }
    func testQuotaPalettesKeepUnknownAndLegacyRowsNeutral() throws {
        expectNil(QuotaPalette.families(["Unknown Model"]))
        expectEqual(QuotaPalette.families(["Gemini", "Claude", "GPT"]), .mixed)
        let legacy = try JSONDecoder().decode(Window.self, from: JSONSerialization.data(withJSONObject: ["label": "Budget", "pct": 20]))
        expectNil(legacy.palette)
    }
}
