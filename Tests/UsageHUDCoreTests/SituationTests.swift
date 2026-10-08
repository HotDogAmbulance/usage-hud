import Foundation
@testable import UsageHUDCore

/// The situations matrix: every provider is run through the ways a real Mac lets it down, and what the person would see
/// is compared with one policy (docs/SITUATIONS.md). A provider that worked and then fails must keep its last numbers,
/// dimmed, and stay quiet unless only the person can fix it; a source that is gone takes its battery with it; a fix
/// brings it back by itself; and no secret reaches a file or a panel.
enum Situation: String, CaseIterable {
    case offline, timeout, serverError, rateLimited, rejected, notJSON, tooLarge, shapeChanged, sourceRemoved
}
enum Origin: String { case stored, found, local }
enum Outcome: String {
    case keptQuiet = "dim", keptAlert = "dim+asks", keptFresh = "LOOKS FRESH", explained = "says why", changed = "CHANGED", leaves = "leaves", hidden = "hidden"
}
final class Dial { var mode = "good"; var counter = 0 }

struct World {
    let id: String
    var origins: [Origin] = [.found, .stored]
    var applies: Set<Situation> = Set(Situation.allCases)
    let secret: String
    /// Puts the source (key, sign-in file, app data) where the provider looks.
    let plant: (CoreTests, Origin) throws -> Void
    let unplant: (CoreTests, Origin) throws -> Void
    let make: (CoreTests, Origin, Dial) throws -> UsageProvider
    /// Makes the next read healthy.
    let good: (CoreTests, Dial) throws -> Void
    /// Makes the next read answer with the shape changed.
    let drift: (CoreTests, Dial) -> Void
    /// Non-HTTP providers translate a situation themselves; nil means the HTTP fakes do.
    var fail: ((CoreTests, Dial, Situation) -> Void)?
    /// Lets the clock pass whatever throttle the provider keeps, so the next pass really reads.
    var age: (CoreTests, UsageProvider, Dial) -> Void = { _, provider, _ in
        (provider as? KeyProvider)?.found.at = 0; (provider as? OpenRouterProvider)?.found.at = 0
    }
}

extension CoreTests {
    static let future = "2099-01-01T00:00:00Z"
    func write(_ text: String, to path: String) throws {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }
    func remove(_ path: String) { try? FileManager.default.removeItem(at: root.appendingPathComponent(path)) }

    /// A provider read with one API key: found in ~/.zshrc, or stored in the Keychain.
    func keyWorld(_ id: String, variable: String, service: String, extra: String = "", environment: [String: String] = [:],
                  secret: String? = nil, make: @escaping (CoreTests, [String: String]) -> UsageProvider,
                  good: @escaping (FakeHTTP) -> Void, drift: @escaping (FakeHTTP) -> Void) -> World {
        let key = secret ?? "sk-leakcheck-\(id)-0123456789abcdef"
        return World(id: id, secret: key,
            plant: { t, origin in
                t.credentials.deleted.remove(service)
                if origin == .stored { t.credentials.text = key; t.credentials.missing.remove(service) }
                else { t.credentials.missing.insert(service); try t.write("export \(variable)=\(key)\n\(extra)", to: ".zshrc") }
            },
            unplant: { t, origin in
                if origin == .stored { t.credentials.deleted.insert(service) } else { t.remove(".zshrc") }
            },
            make: { t, _, _ in make(t, environment) },
            good: { t, _ in t.http.error = nil; good(t.http) },
            drift: { t, _ in t.http.error = nil; drift(t.http) })
    }

    func worlds() -> [World] {
        let future = Self.future
        var all: [World] = []
        // Claude: the Keychain item Claude Code keeps; the usage endpoint is read at most every five minutes.
        all.append(World(id: "claude", origins: [.stored], secret: "tok-leakcheck-claude-0123456789",
            plant: { t, _ in t.credentials.deleted.remove("Claude Code-credentials"); t.credentials.text = "{\"claudeAiOauth\":{\"accessToken\":\"tok-leakcheck-claude-0123456789\"}}" },
            unplant: { t, _ in t.credentials.deleted.insert("Claude Code-credentials") },
            make: { t, _, _ in ClaudeProvider(cache: t.cache, credentials: t.credentials, http: t.http, home: t.root) },
            good: { t, _ in t.http.error = nil
                t.http.handler = { _ in ["five_hour": ["utilization": 40, "resets_at": future], "seven_day": ["utilization": 10, "resets_at": future]] } },
            drift: { t, _ in t.http.handler = { _ in ["unexpected": 1] } },
            age: { t, _, _ in try? t.cache.merge("claude.json", ["oauth_at": 0]); try? t.cache.write("claude-backoff.json", [:]) }))
        all.append(openrouterWorld()); all.append(glmWorld())
        all.append(keyWorld("vercel", variable: "AI_GATEWAY_API_KEY", service: "Usage HUD Vercel",
            make: { t, env in KeyProvider.vercel(cache: t.cache, credentials: t.credentials, http: t.http, home: t.root, environment: env) },
            good: { $0.handler = { _ in ["balance": "4.50", "total_used": "0.50"] } }, drift: { $0.handler = { _ in ["credit": 4.5] } }))
        all.append(keyWorld("deepseek", variable: "DEEPSEEK_API_KEY", service: "Usage HUD DeepSeek",
            make: { t, env in KeyProvider.deepSeek(cache: t.cache, credentials: t.credentials, http: t.http, home: t.root, environment: env) },
            good: { $0.handler = { _ in ["is_available": true, "balance_infos": [["currency": "USD", "total_balance": "7.00"]]] } },
            drift: { $0.handler = { _ in ["balance": 7] } }))
        all.append(keyWorld("kimi", variable: "MOONSHOT_API_KEY", service: "Usage HUD Kimi",
            make: { t, env in KeyProvider.kimi(cache: t.cache, credentials: t.credentials, http: t.http, home: t.root, environment: env) },
            good: { $0.handler = { _ in ["code": 0, "data": ["available_balance": 2.0]] } }, drift: { $0.handler = { _ in ["data": [:]] } }))
        all.append(keyWorld("kimi-code", variable: "KIMI_CODE_API_KEY", service: "Usage HUD Kimi Code",
            make: { t, env in KeyProvider.kimiCode(cache: t.cache, credentials: t.credentials, http: t.http, home: t.root, environment: env) },
            good: { $0.handler = { _ in ["usage": ["limit": "100", "used": "10", "resetTime": future]] } }, drift: { $0.handler = { _ in ["unexpected": 1] } }))
        all.append(keyWorld("xai", variable: "XAI_MANAGEMENT_API_KEY", service: "Usage HUD xAI",
            make: { t, env in KeyProvider.xai(cache: t.cache, credentials: t.credentials, http: t.http, home: t.root, environment: env) },
            good: { $0.handler = { url in
                if url.path.hasSuffix("validation") { return ["scope": "SCOPE_TEAM", "scopeId": "team-1"] }
                return url.path.hasSuffix("prepaid/balance") ? ["total": ["val": "-1050"]] : [:] } },
            drift: { $0.handler = { _ in ["unexpected": 1] } }))
        all.append(keyWorld("fireworks", variable: "FIREWORKS_API_KEY", service: "Usage HUD Fireworks", environment: ["FIREWORKS_ACCOUNT_ID": "my-team"],
            make: { t, env in KeyProvider.fireworks(cache: t.cache, credentials: t.credentials, http: t.http, home: t.root, environment: env) },
            good: { $0.handler = { _ in ["value": "50", "usage": 12.5] } }, drift: { $0.handler = { _ in ["unexpected": 1] } }))
        // LiteLLM has no stored key: the proxy address and key come together from one place.
        var lite = keyWorld("litellm", variable: "LITELLM_PROXY_API_KEY", service: "Usage HUD LiteLLM", extra: "export LITELLM_PROXY_API_BASE=http://localhost:4000\n",
            make: { t, env in KeyProvider.liteLLM(cache: t.cache, credentials: t.credentials, http: t.http, home: t.root, environment: env) },
            good: { $0.handler = { _ in ["info": ["spend": 12.5, "max_budget": 50]] } }, drift: { $0.handler = { _ in ["info": [:]] } })
        lite.origins = [.found]
        all.append(lite)
        all.append(antigravityWorld()); all.append(grokWorld()); all.append(grokBotWorld()); all.append(codexWorld())
        return all
    }

    func openrouterWorld() -> World {
        let key = "sk-or-v1-" + String(repeating: "ab", count: 32)
        return World(id: "openrouter", secret: key,
            plant: { t, origin in
                t.credentials.deleted.remove("svc")
                if origin == .stored {
                    t.credentials.text = key
                    try t.write("[{\"id\":\"one\",\"label\":\"One\",\"sources\":[{\"provider\":\"openrouter\",\"service\":\"svc\",\"account\":\"one\"}]}]", to: "providers.json")
                } else { try t.write("export OPENROUTER_API_KEY=\(key)\n", to: ".zshrc") }
            },
            unplant: { t, origin in if origin == .stored { t.credentials.deleted.insert("svc") } else { t.remove(".zshrc") } },
            make: { t, _, _ in OpenRouterProvider(cache: t.cache, credentials: t.credentials, http: t.http, home: t.root, environment: [:]) },
            good: { t, _ in t.http.error = nil
                t.http.handler = { url in url.path.hasSuffix("credits") ? ["data": ["total_credits": 50, "total_usage": 7]] : ["data": ["usage": 7, "usage_daily": 1, "label": "sk-or-v1-abc"]] } },
            drift: { t, _ in t.http.handler = { _ in ["data": ["unexpected": 1]] } })
    }
    func glmWorld() -> World {
        let key = "sk-leakcheck-glm-0123456789abcdef"
        return World(id: "glm", secret: key,
            plant: { t, origin in
                t.credentials.deleted.remove("Usage HUD GLM")
                if origin == .stored { t.credentials.text = key; t.credentials.missing.remove("Usage HUD GLM") }
                else {
                    t.credentials.missing.insert("Usage HUD GLM")
                    try t.write("{\"env\":{\"ANTHROPIC_BASE_URL\":\"https://api.z.ai/api/anthropic\",\"ANTHROPIC_AUTH_TOKEN\":\"\(key)\"}}", to: ".claude/settings.json")
                }
            },
            unplant: { t, origin in if origin == .stored { t.credentials.deleted.insert("Usage HUD GLM") } else { t.remove(".claude/settings.json") } },
            make: { t, _, _ in GLMProvider(cache: t.cache, credentials: t.credentials, http: t.http, home: t.root, environment: [:]) },
            good: { t, _ in t.http.error = nil
                t.http.handler = { _ in ["success": true, "data": ["level": "lite", "limits": [
                    ["type": "CREDIT_LIMIT", "unit": 3, "number": 5, "percentage": 20, "nextResetTime": 4102444800000.0],
                    ["type": "CREDIT_LIMIT", "unit": 6, "number": 1, "percentage": 52, "nextResetTime": 4102444800000.0]]]] } },
            drift: { t, _ in t.http.handler = { _ in ["success": true, "data": ["limits": [["type": "NEW_KIND", "percentage": 5]]]] } })
    }

    func antigravityWorld() -> World {
        let response: JSON = ["userStatus": ["cascadeModelConfigData": ["clientModelConfigs": [
            ["label": "Gemini Pro", "quotaInfo": ["remainingFraction": 0.75, "resetTime": Self.future]]]]]]
        var world = World(id: "antigravity", origins: [.local], applies: [.offline, .shapeChanged, .sourceRemoved], secret: "unused-antigravity",
            plant: { _, _ in }, unplant: { _, _ in },
            make: { t, _, dial in AntigravityProvider(cache: t.cache, read: {
                switch dial.mode {
                case "closed": throw HUDProblem("Open Antigravity to update its quota")
                case "gone": throw HUDProblem("Antigravity isn't installed", gone: true)
                case "drift": return ["userStatus": [:]]
                default: return response } }) },
            good: { _, dial in dial.mode = "good" }, drift: { _, dial in dial.mode = "drift" })
        world.fail = { _, dial, situation in dial.mode = situation == .sourceRemoved ? "gone" : situation == .shapeChanged ? "drift" : "closed" }
        return world
    }
    func grokWorld() -> World {
        let secret = "grok-leakcheck-0123456789abcdef"
        return World(id: "grok", origins: [.local], secret: secret,
            plant: { t, _ in try t.write("{\"https://auth.x.ai::c\":{\"key\":\"\(secret)\",\"expires_at\":\"2099-01-01T00:00:00Z\"}}", to: ".grok/auth.json") },
            unplant: { t, _ in t.remove(".grok/auth.json") },
            make: { t, _, _ in GrokProvider(cache: t.cache, http: t.http, home: t.root, environment: [:]) },
            good: { t, _ in t.http.error = nil
                t.http.handler = { _ in ["config": ["creditUsagePercent": 12.5, "subscriptionTier": "SUPERGROK",
                                                    "currentPeriod": ["type": "USAGE_PERIOD_TYPE_WEEKLY", "end": "2099-09-27T18:42:45Z"]]] } },
            drift: { t, _ in t.http.handler = { _ in ["config": ["unexpected": 1]] } })
    }
    func grokBotWorld() -> World {
        func save(_ t: CoreTests, _ dial: Dial, shape: Bool = true) throws {
            dial.counter += 1
            let usage: JSON = shape ? ["percentUsed": 30, "nextResetMs": 4_102_444_800_000.0, "grokPlanLabel": "Plan"] : ["somethingElse": 30]
            let reading: JSON = ["usage": usage, "readAtMs": Date().timeIntervalSince1970 * 1000 - 100_000 + Double(dial.counter) * 1000]
            try JSONSerialization.data(withJSONObject: ["schemaVersion": 2, "value": ["kind": "present", "reading": reading, "expiresAtMs": 4_102_444_800_000.0]])
                .write(to: URL(fileURLWithPath: t.root.path + "/Library/Application Support/Grok Bot/sand-client-persistence/a.blob"))
        }
        var world = World(id: "grokbot", origins: [.local], applies: [.offline, .shapeChanged, .sourceRemoved], secret: "unused-grokbot",
            plant: { t, _ in try FileManager.default.createDirectory(at: t.root.appendingPathComponent("Library/Application Support/Grok Bot/sand-client-persistence"), withIntermediateDirectories: true) },
            unplant: { t, _ in t.remove("Library") },
            make: { t, _, _ in GrokBotProvider(cache: t.cache, home: t.root) },
            good: { t, dial in dial.mode = "good"; try save(t, dial) }, drift: { t, dial in dial.mode = "drift"; try? save(t, dial, shape: false) })
        world.fail = { _, _, _ in }
        return world
    }
    func codexWorld() -> World {
        let good = "{\"id\":2,\"result\":{\"rateLimits\":{\"limitId\":\"codex\",\"planType\":\"plus\",\"primary\":{\"usedPercent\":40,\"windowDurationMins\":300,\"resetsAt\":4102444800},\"secondary\":{\"usedPercent\":10,\"windowDurationMins\":10080,\"resetsAt\":4102444800}}}}"
        var world = World(id: "codex", origins: [.local], applies: [.offline, .notJSON, .rejected, .shapeChanged], secret: "unused-codex",
            plant: { t, _ in
                let script = """
                #!/bin/bash
                mode=$(cat "\(t.root.path)/codex-mode" 2>/dev/null)
                while IFS= read -r line; do
                  case "$line" in
                    *'"id":1'*)
                      [ "$mode" = eof ] && exit 0
                      [ "$mode" = garbage ] && { echo 'not json at all'; exit 0; }
                      echo '{"id":1,"result":{}}' ;;
                    *'"id":2'*)
                      case "$mode" in
                        error) echo '{"id":2,"error":{"code":-1,"message":"not signed in"}}' ;;
                        drift) echo '{"id":2,"result":{"rateLimits":{"limitId":"codex","planType":"plus"}}}' ;;
                        *) echo '\(good)' ;;
                      esac
                      exit 0 ;;
                  esac
                done
                """
                try t.write(script, to: "codex")
                chmod(t.root.appendingPathComponent("codex").path, 0o755)
                setenv("USAGE_HUD_CODEX_CLI", t.root.appendingPathComponent("codex").path, 1)
            },
            unplant: { _, _ in }, make: { t, _, _ in CodexProvider(cache: t.cache, credits: OpenAICredits(cache: t.cache, credentials: t.credentials, http: t.http)) },
            good: { t, _ in try t.write("good", to: "codex-mode") }, drift: { t, _ in try? t.write("drift", to: "codex-mode") })
        world.fail = { t, _, situation in
            try? t.write(situation == .offline ? "eof" : situation == .notJSON ? "garbage" : situation == .shapeChanged ? "drift" : "error", to: "codex-mode")
        }
        return world
    }

    // MARK: observing

    func signature(_ panel: Panel) -> String {
        (panel.windows + panel.cells).map { window in
            let right = (window.right ?? "").replacingOccurrences(of: #"\s*·?\s*(↻|ends in).*$"#, with: "", options: .regularExpression)
            return "\(window.label)|\(window.pct.map { String(Int($0.rounded())) } ?? "")|\(right)"
        }.joined(separator: ";")
    }
    func dimmed(_ panel: Panel) -> Bool { let rows = panel.windows + panel.cells; return !rows.isEmpty && rows.allSatisfy { $0.isCached } }
    func classify(_ base: Panel, _ now: [Panel]) -> Outcome {
        guard let panel = now.first else { return .leaves }
        if signature(panel) == signature(base) {
            if !dimmed(panel) { return .keptFresh }
            return panel.alert == nil ? .keptQuiet : .keptAlert
        }
        let sig = signature(panel)
        return ["no longer valid", "Key removed", "Temporarily unreadable", "Unavailable"].contains { sig.contains($0) } ? .explained : .changed
    }
    func leaks(_ secret: String, _ panels: [Panel]) -> Bool {
        if let data = try? JSONEncoder().encode(panels), String(decoding: data, as: UTF8.self).contains(secret) { return true }
        let files = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        return files.contains { $0.lastPathComponent.first != "." && ((try? Data(contentsOf: $0)).map { String(decoding: $0, as: UTF8.self).contains(secret) } ?? false) }
    }
    func apply(_ situation: Situation, _ world: World, _ dial: Dial) {
        if let fail = world.fail { fail(self, dial, situation); return }
        switch situation {
        case .offline: http.handler = { _ in throw HUDProblem("Usage connection failed") }
        case .timeout: http.handler = { _ in throw HUDProblem("Usage request timed out") }
        case .serverError: http.handler = { _ in throw HTTPFailure(status: 503) }
        case .rateLimited: http.handler = { _ in throw HTTPFailure(status: 429) }
        case .rejected: http.handler = { _ in throw HTTPFailure(status: 401) }
        case .notJSON: http.handler = { _ in throw HUDProblem("Invalid usage response") }
        case .tooLarge: http.handler = { _ in throw HUDProblem("Usage response too large") }
        case .shapeChanged: world.drift(self, dial)
        case .sourceRemoved: break
        }
    }
    /// What the policy says should happen.
    func expected(_ situation: Situation, _ origin: Origin) -> Set<Outcome> {
        switch situation {
        case .sourceRemoved: return [.leaves]
        case .rejected: return origin == .stored ? [.keptAlert, .explained] : [.keptQuiet, .explained]
        default: return [.keptQuiet]
        }
    }
    /// Cells where today's behaviour differs from the policy and the difference is understood and accepted (or tracked in
    /// docs/SITUATIONS.md), by "world/origin/situation".
    static let acceptedCells: [String: (outcomes: Set<Outcome>, why: String)] = [
        "openrouter/stored/sourceRemoved": ([.explained], "OpenRouter holds several keys: one whose Keychain item is gone is announced once and its row goes; the battery stays for the others."),
        "glm/found/rejected": ([.keptAlert], "The key is the one Claude Code itself uses for Z.ai; if it is refused that tool is broken too, so the battery asks."),
        "antigravity/local/shapeChanged": ([.keptAlert], "A signed-out app and a changed protocol answer the same way, so the battery asks the person to look.")
    ]
    var accepted: [String: (outcomes: Set<Outcome>, why: String)] { Self.acceptedCells }

    func testSituationMatrix() throws {
        signal(SIGPIPE, SIG_IGN)
        let out = ProcessInfo.processInfo.environment["USAGE_HUD_MATRIX_OUT"]
        var table: [String] = [], problems: [String] = []
        let situations = Situation.allCases
        for world in worlds() {
            if world.id == "codex" {
                // The fake CLI only runs if the override took effect; never fall back to a real Codex on this Mac.
                try plantCodexProbe(world)
                guard ProcessInfo.processInfo.environment["USAGE_HUD_CODEX_CLI"]?.hasSuffix("/codex") == true else { table.append("| codex | — | environment override not visible; skipped |"); continue }
            }
            for origin in world.origins {
                var cells: [String] = [], recovery = "recovers"
                for situation in situations {
                    guard world.applies.contains(situation) else { cells.append("n/a"); continue }
                    try setUpWithError()
                    defer { try? tearDownWithError() }
                    let dial = Dial()
                    try world.plant(self, origin)
                    let provider = try world.make(self, origin, dial)
                    let engine = Engine(root: root, credentials: credentials, http: http, providers: [provider])
                    try world.good(self, dial)
                    let base = engine.panels(refresh: "automatic")
                    guard let first = base.first else { problems.append("\(world.id)/\(origin.rawValue): no healthy baseline (\(cache.read(world.id + "-status.json")["error"] ?? "no status"))"); cells.append("no baseline"); continue }
                    apply(situation, world, dial)
                    if situation == .sourceRemoved { try world.unplant(self, origin) }
                    world.age(self, provider, dial)
                    let seen = engine.panels(refresh: "automatic")
                    let outcome = classify(first, seen)
                    let key = "\(world.id)/\(origin.rawValue)/\(situation.rawValue)"
                    var mark = outcome.rawValue
                    if !expected(situation, origin).contains(outcome) {
                        if let known = accepted[key], known.outcomes.contains(outcome) { mark += " (known)" }
                        else { mark += " ✗"; problems.append("\(key): saw \(outcome.rawValue), policy wants \(expected(situation, origin).map { $0.rawValue }.sorted()) — note: \(seen.first?.note ?? "-")") }
                    }
                    cells.append(mark)
                    if leaks(world.secret, seen) { problems.append("\(key): the secret reached a file or a panel") }
                    // The fix brings it back by itself.
                    if situation == .sourceRemoved { try world.plant(self, origin) }
                    try world.good(self, dial); world.age(self, provider, dial)
                    let back = engine.panels(refresh: "automatic")
                    if let again = back.first, signature(again) == signature(first), !dimmed(again), again.alert == nil, again.note == first.note { continue }
                    recovery = "STUCK after " + situation.rawValue
                    if accepted["\(world.id)/\(origin.rawValue)/recover-\(situation.rawValue)"] == nil {
                        problems.append("\(key): did not recover once the cause was fixed (note: \(back.first?.note ?? "hidden"), sig: \(back.first.map { signature($0) } ?? "-"))")
                    }
                }
                table.append("| \(world.id) | \(origin.rawValue) | " + cells.joined(separator: " | ") + " | \(recovery) |")
            }
        }
        if let out = out {
            let head = "| provider | key from | " + situations.map { $0.rawValue }.joined(separator: " | ") + " | recovery |\n|" + String(repeating: "---|", count: situations.count + 3)
            try? (head + "\n" + table.joined(separator: "\n") + "\n").write(toFile: out, atomically: true, encoding: .utf8)
        }
        for problem in problems { fail(problem) }
    }
    func plantCodexProbe(_ world: World) throws {
        try setUpWithError(); defer { try? tearDownWithError() }
        try world.plant(self, .local)
    }

    // MARK: first run, windows that vanish, revoked keys, empty balances, early resets

    /// A provider that has never given a reading stays out of the bar, whatever goes wrong; only a key the person stored and
    /// that is refused brings its battery up, so they can fix it.
    func testNeverWorkedStaysHiddenUnlessTheKeyNeedsYou() throws {
        signal(SIGPIPE, SIG_IGN)
        for world in worlds() {
            for origin in world.origins {
                for step in ["nothing", "offline", "shapeChanged", "rejected"] {
                    if (world.id == "codex" || world.fail != nil) && step == "nothing" { continue }
                    let situation = Situation(rawValue: step)
                    if let situation = situation, !world.applies.contains(situation) { continue }
                    try setUpWithError(); defer { try? tearDownWithError() }
                    let dial = Dial()
                    if step != "nothing" || world.id == "antigravity" { try world.plant(self, origin) }
                    let provider = try world.make(self, origin, dial)
                    let engine = Engine(root: root, credentials: credentials, http: http, providers: [provider])
                    if let situation = situation { apply(situation, world, dial) }
                    if step == "nothing" { http.handler = { _ in throw HTTPFailure(status: 404) } }
                    let seen = engine.panels(refresh: "automatic")
                    let wantsYou = step == "rejected" && origin == .stored && world.id != "openrouter"
                    let key = "\(world.id)/\(origin.rawValue)/first-\(step)"
                    if wantsYou { if seen.first?.alert == nil { fail("\(key): a stored key that is refused should bring its battery up, saw \(seen.count) panels") } }
                    else if !seen.isEmpty, Self.firstRunAccepted[key] == nil { fail("\(key): showed a battery before any good reading (note: \(seen[0].note))") }
                    if let panel = seen.first, leaks(world.secret, [panel]) { fail("\(key): the secret reached a panel") }
                }
            }
        }
    }
    static let firstRunAccepted: [String: String] = [
        "glm/found/first-rejected": "The key is the one Claude Code itself uses for Z.ai; if it is refused that tool is broken too, so the battery asks."
    ]

    func testVanishedWindowsExpireWithTheirReset() throws {
        func keys(_ name: String) -> Set<String> { Set(dict(cache.read(name)["rate_limits"]).keys) }
        try cache.quota("claude.json", windows: ["five_hour": ["used_percentage": 30, "resets_at": 5000], "seven_day": ["used_percentage": 20, "resets_at": 9000]], now: 1000)
        try cache.quota("claude.json", windows: ["five_hour": ["used_percentage": 35, "resets_at": 6000]], now: 2000)
        expectEqual(keys("claude.json"), ["five_hour", "seven_day"])
        expectEqual(dict(dict(cache.read("claude.json")["rate_limits"])["seven_day"])["stale"] as? Bool, true)
        try cache.quota("claude.json", windows: ["five_hour": ["used_percentage": 5, "resets_at": 20000]], now: 10000)
        expectEqual(keys("claude.json"), ["five_hour"])
        // With no reset time a missing window is kept for twice its own length.
        let both: JSON = ["primary": ["used_percentage": 50, "window_minutes": 300], "secondary": ["used_percentage": 20, "window_minutes": 10080]]
        try cache.quota("codex-quota.json", windows: both, now: 1000)
        try cache.quota("codex-quota.json", windows: ["secondary": ["used_percentage": 21, "window_minutes": 10080]], now: 1000 + 36000 - 1)
        expectEqual(keys("codex-quota.json"), ["primary", "secondary"])
        try cache.quota("codex-quota.json", windows: ["secondary": ["used_percentage": 22, "window_minutes": 10080]], now: 1000 + 36000 + 1)
        expectEqual(keys("codex-quota.json"), ["secondary"])
    }

    func testARevokedKeyThatWorkedIsAnnouncedOnceThenGoes() throws {
        let key = "sk-or-v1-" + String(repeating: "d4", count: 32)
        try write("export OPENROUTER_API_KEY=\(key)\n", to: ".zshrc")
        func good() { http.handler = { url in url.path.hasSuffix("credits") ? ["data": ["total_credits": 50, "total_usage": 7]] : ["data": ["usage": 7, "label": "sk-or-v1-abc"]] } }
        good()
        let provider = OpenRouterProvider(cache: cache, credentials: credentials, http: http, home: root, environment: [:])
        var changes = SourceChanges()
        func panel() -> Panel { var panel = provider.panel(); panel.readingSource = .providerAPI; panel.sourceReadAt = Date().timeIntervalSince1970; return panel }
        try provider.refresh()
        _ = changes.update(panels: [panel()], announce: false)
        http.handler = { _ in throw HTTPFailure(status: 401) }
        do { try provider.refresh() } catch {}
        let notice = changes.update(panels: [panel()])
        expectTrue(notice?.title.contains("refused") == true)
        expectTrue(provider.panel().cells.contains { $0.right == "Key no longer valid" })
        // The next pass drops the row quietly, and it stays dropped without a second notice.
        for _ in 0..<2 {
            do { try provider.refresh() } catch {}
            expectFalse(provider.panel().cells.contains { $0.right == "Key no longer valid" })
            expectNil(changes.update(panels: [panel()]))
        }
        // A key that works again comes back.
        good(); try provider.refresh()
        expectTrue(provider.panel().windows.contains { $0.label == "sk-or-v1-abc" || $0.label == "zshrc" })
    }

    func testEmptyBalancesAndFullQuotasAreShownNotHidden() throws {
        try write("export DEEPSEEK_API_KEY=sk-0123456789abcdef0123\n", to: ".zshrc")
        credentials.missing.insert("Usage HUD DeepSeek")
        http.handler = { _ in ["is_available": false, "balance_infos": [["currency": "USD", "total_balance": "0.00"]]] }
        let deepSeek = KeyProvider.deepSeek(cache: cache, credentials: credentials, http: http, home: root, environment: [:])
        let engine = Engine(root: root, credentials: credentials, http: http, providers: [deepSeek])
        let panel = engine.panels(refresh: "automatic").first
        expectEqual(panel?.windows.first?.right, "$0 left"); expectEqual(panel?.alert, "Balance low")
        // A plan used up reads 100% used (an empty battery), never a missing one.
        let kimi = KeyProvider.kimiCode(cache: cache, credentials: credentials, http: http, home: root, environment: ["KIMI_CODE_API_KEY": "sk-kimi-0123456789abcdef"])
        credentials.missing.insert("Usage HUD Kimi Code")
        http.handler = { _ in ["usage": ["limit": "100", "used": "100", "resetTime": Self.future]] }
        let full = Engine(root: root, credentials: credentials, http: http, providers: [kimi]).panels(refresh: "automatic").first
        expectEqual(full?.displayedQuota?.pct, 100)
    }

    func testAnEarlyResetReadsFreshNotStale() throws {
        let now = Date().timeIntervalSince1970
        try cache.quota("claude.json", windows: ["five_hour": ["used_percentage": 92, "resets_at": now + 3600], "seven_day": ["used_percentage": 60, "resets_at": now + 86400]], now: now - 120)
        // A reset coupon is redeemed: usage falls and the five-hour window starts over, long before the old one ended.
        try cache.quota("claude.json", windows: ["five_hour": ["used_percentage": 2, "resets_at": now + 18000], "seven_day": ["used_percentage": 1, "resets_at": now + 86400]], now: now)
        let rows = quotaWindows(cache.read("claude.json"), now: now + 1)
        expectEqual(rows.map { $0.pct ?? -1 }, [2, 1]); expectFalse(rows.contains { $0.isCached })
    }
}
