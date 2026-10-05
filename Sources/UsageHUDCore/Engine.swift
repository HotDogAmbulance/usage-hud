import Foundation
import Darwin

public final class Engine {
    public let root: URL
    let cache: Cache
    let providers: [UsageProvider]
    let credits: OpenAICredits
    /// A money battery below this amount, in its own currency, asks for attention.
    public var lowBalance = 1.0
    /// OpenRouter caps free models at 50 requests a day until $10 has been bought, so under $15 its battery turns amber
    /// and under $10 it asks for attention. The other providers have no balance threshold, only the generic one above.
    public var balanceLevels: [String: (caution: Double, alert: Double)] = ["openrouter": (15, 10)]
    public static var defaultRoot: URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        // A copied app still names the folder of whoever built it; another person's Mac uses its own home.
        if let path = ProcessInfo.processInfo.environment["USAGE_HUD_HOME"] ?? (Bundle.main.object(forInfoDictionaryKey: "UsageHUDDataDirectory") as? String)
            .flatMap({ $0.hasPrefix(home.path + "/") ? $0 : nil }) {
            return URL(fileURLWithPath: path)
        }
        return home.appendingPathComponent(".usage-hud")
    }
    public convenience init(root: URL = Engine.defaultRoot) { self.init(root: root, credentials: KeychainReader(), http: HTTPReader()) }
    init(root: URL, credentials: CredentialReading, http: HTTPReading, providers: [UsageProvider]? = nil) {
        self.root = root; cache = Cache(root)
        credits = OpenAICredits(cache: cache, credentials: credentials, http: http)
        self.providers = providers ?? [CodexProvider(cache: cache, credits: credits),
                                      ClaudeProvider(cache: cache, credentials: credentials, http: http),
                                      OpenRouterProvider(cache: cache, credentials: credentials, http: http),
                                      GLMProvider(cache: cache, credentials: credentials, http: http),
                                      AntigravityProvider(cache: cache),
                                      GrokProvider(cache: cache, http: http),
                                      KeyProvider.vercel(cache: cache, credentials: credentials, http: http),
                                      KeyProvider.deepSeek(cache: cache, credentials: credentials, http: http),
                                      KeyProvider.kimi(cache: cache, credentials: credentials, http: http),
                                      KeyProvider.kimiCode(cache: cache, credentials: credentials, http: http),
                                      KeyProvider.xai(cache: cache, credentials: credentials, http: http),
                                      KeyProvider.fireworks(cache: cache, credentials: credentials, http: http),
                                      KeyProvider.liteLLM(cache: cache, credentials: credentials, http: http)]
    }
    /// After a Keychain prompt, only the user's own Refresh may ask again.
    func prompted(_ id: String) -> Bool {
        let status = cache.read(id + "-status.json")
        return status["prompted"] as? Bool == true
    }
    /// `also` names providers to refresh the way the background does, so one in use can follow along between passes.
    public func panels(refresh: String? = nil, also: Set<String> = []) -> [Panel] {
        if refresh == "openai-credits" { try? credits.refresh() }
        return providers.compactMap { provider -> Panel? in
            let statusFile = provider.id + "-status.json"
            if refresh == provider.id || (refresh == "automatic" || also.contains(provider.id)) && !prompted(provider.id) && provider.automatic {
                let now = Date().timeIntervalSince1970
                do {
                    try provider.refresh()
                    try cache.write(statusFile, ["error": NSNull(), "checked_at": now, "ok_at": now])
                } catch {
                    let problem = error as? HUDProblem
                    let message = problem?.message ?? (error as? HTTPFailure).map { "Usage HTTP \($0.status)" } ?? "Usage unavailable"
                    try? cache.write(statusFile, ["error": message, "attention": problem?.attention == true, "prompted": problem?.prompted == true,
                                                  "fix": problem?.fix as Any? ?? NSNull(), "gone": problem?.gone == true, "checked_at": now,
                                                  "ok_at": cache.read(statusFile)["ok_at"] ?? now])
                }
            }
            let status = cache.read(statusFile)
            // A provider not yet read stays hidden, unless it needs the user (a prompt or a rejected key) to get there.
            guard provider.shown() || status["attention"] as? Bool == true else { return nil }
            // A statusline reading newer than the failed request clears that failure; hooks only announce activity.
            let failing = status["error"] is String && number(cache.read(provider.cacheFile)["captured_at"]) ?? 0 <= number(status["checked_at"]) ?? 0
            // A battery whose source left the Mac goes with it, as does one without a good read for a week; the background
            // keeps trying, so either comes back with its next good read.
            if failing, status["gone"] as? Bool == true || Date().timeIntervalSince1970 - (number(status["ok_at"]) ?? .infinity) > 604_800 { return nil }
            var panel = provider.panel()
            let blob = cache.read(provider.cacheFile)
            panel.readingSource = (blob["reading_source"] as? String).flatMap(ReadingSource.init(rawValue:))
            panel.sourceReadAt = number(blob["source_read_at"])
            if provider.id == "claude" {
                let legacy: ReadingSource? = blob["source"] as? String == "statusline" ? .claudeStatusline :
                    blob["source"] as? String == "oauth-usage-get" ? .claudeOAuth : nil
                let usable = quotaWindows(blob).contains { !$0.isCached && ($0.label == "5h" || $0.label.hasPrefix("7d")) }
                panel.readingSource = usable ? legacy : nil
                panel.sourceReadAt = usable ? number(blob["captured_at"]) : nil
            }
            if failing, let message = status["error"] as? String {
                panel.note = message; panel.fix = status["fix"] as? String
                for index in panel.windows.indices { panel.windows[index].stale = true }
                for index in panel.cells.indices { panel.cells[index].stale = true }
                // A rejected key won't fix itself; a passing outage or an idle CLI's token will.
                if status["attention"] as? Bool == true { panel.alert = panel.alert ?? message }
            }
            // The text stays the same as the balance moves, so one hover silences it until it recovers.
            if panel.windows.contains(where: { $0.label == panel.name && $0.pct == nil && $0.stale != true && $0.right?.hasSuffix(" left") == true }),
               let level = Shelf.level(panel) {
                let amount = -level, levels = balanceLevels[panel.id]
                if panel.alert == nil, amount < (levels?.alert ?? lowBalance) { panel.alert = "Balance low" }
                if let caution = levels?.caution, amount < caution { panel.caution = "Balance under " + usd(caution); if panel.note.isEmpty { panel.note = panel.caution ?? "" } }
            }
            return panel
        }
    }
    /// An outage or a battery hidden after a week is not proof that a source was removed.
    public var goneSources: Set<String> {
        Set(providers.compactMap { provider in
            let status = cache.read(provider.id + "-status.json")
            guard status["error"] is String, status["gone"] as? Bool == true,
                  (number(cache.read(provider.cacheFile)["captured_at"]) ?? 0) <= (number(status["checked_at"]) ?? 0) else { return nil }
            return provider.id
        })
    }
    public func statusline(_ data: Data) throws -> String {
        guard let payload = try? JSONSerialization.jsonObject(with: data) as? JSON else { return "" }
        let now = Date().timeIntervalSince1970
        var updates: JSON = [:]
        let windows = dict(payload["rate_limits"])
        if !windows.isEmpty { try cache.quota("claude.json", windows: windows, extra: ["source": "statusline"]) }
        let context = number(dict(payload["context_window"])["used_percentage"])
        if let context = context { updates["context_pct"] = context; updates["context_captured_at"] = now }
        if !updates.isEmpty { try cache.merge("claude.json", updates) }
        let model = (payload["model"] as? String) ?? (dict(payload["model"])["display_name"] as? String) ?? ""
        var bits = model.isEmpty ? [] : [model]
        if let context = context { bits.append("ctx \(Int(context.rounded()))%") }
        for window in quotaWindows(["captured_at": now, "rate_limits": windows]) {
            bits.append("\(window.label) \(Int((window.pct ?? 0).rounded()))%")
        }
        return bits.joined(separator: " | ")
    }
    /// Claude Code's hooks call this when it starts, takes a prompt and finishes a turn.
    public static let claudeCodeRan = Notification.Name("local.usage-hud.claude-code-ran")
    /// Our own hook and statusline commands, in exactly the form we write; one someone wrapped in a script of theirs stays theirs.
    static let ownCommand = #"^(python3? )?'?[^']*/(usagehud|usage_hud\.py)'? (--probe-if-stale|--claude-statusline)( 2>/dev/null)?( \|\| true)?$"#
    /// Whether this HUD keeps its hooks in Claude Code; the person can switch it off from Claude's menu.
    public var claudeCodeConnected: Bool {
        get { cache.read("claude-code.json")["connected"] as? Bool != false }
        set { try? cache.write("claude-code.json", ["connected": newValue]) }
    }
    /// Adds this HUD's hooks and statusline to Claude Code's settings, or removes them, touching nothing else. Claude Code
    /// not installed means nothing to do, and the app checks again later, so reinstalling it reconnects by itself.
    /// The commands go through the stable link in our folder and stay silent if the app was deleted.
    /// Writes only on a change, after a one-time backup. Returns whether the file changed.
    @discardableResult
    public func connectClaudeCode(_ on: Bool, settings: URL? = nil) throws -> Bool {
        let file = settings ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/settings.json")
        guard FileManager.default.fileExists(atPath: file.deletingLastPathComponent().path) else { return false }
        let data = try? Data(contentsOf: file)
        // A settings file that isn't readable JSON, or isn't shaped the way Claude Code writes it, is left as it is.
        guard let original = data.map({ (try? JSONSerialization.jsonObject(with: $0)) as? JSON }) ?? JSON(),
              original["hooks"] == nil || original["hooks"] is JSON else { return false }
        let executable = "'" + root.appendingPathComponent("usagehud").path.replacingOccurrences(of: "'", with: "'\\''") + "'"
        let legacy = root.appendingPathComponent("usage_hud.py").path
        func command(_ item: Any) -> String { (item as? JSON)?["command"] as? String ?? "" }
        func ours(_ item: Any) -> Bool { command(item).contains(legacy) || command(item).range(of: Self.ownCommand, options: .regularExpression) != nil }
        var value = original, hooks = dict(original["hooks"])
        for event in ["SessionStart", "UserPromptSubmit", "Stop"] {
            guard hooks[event] == nil || hooks[event] is [Any] else { continue }
            let before = hooks[event] as? [Any] ?? []
            var groups = before.compactMap { raw -> Any? in
                guard var group = raw as? JSON, let inner = group["hooks"] as? [Any], inner.contains(where: ours) else { return raw }
                let kept = inner.filter { !ours($0) }
                group["hooks"] = kept
                return kept.isEmpty ? nil : group
            }
            let wrapped = groups.contains { ((($0 as? JSON)?["hooks"] as? [Any]) ?? []).contains { command($0).contains("usagehud") && command($0).contains("--probe-if-stale") } }
            if on && !wrapped { groups.append(["hooks": [["type": "command", "command": executable + " --probe-if-stale 2>/dev/null || true"]]]) }
            if !groups.isEmpty { hooks[event] = groups } else if !before.isEmpty { hooks[event] = nil }
        }
        value["hooks"] = hooks.isEmpty && original["hooks"] == nil ? nil : hooks
        // Someone else's statusline stays; hooks can request a read but do not carry quota data.
        if original["statusLine"] == nil || (original["statusLine"] as? JSON).map({ ours($0) }) == true {
            var line = original["statusLine"] as? JSON ?? ["type": "command"]
            line["command"] = executable + " --claude-statusline 2>/dev/null"
            value["statusLine"] = on ? line : nil
        }
        guard !NSDictionary(dictionary: value).isEqual(to: original) else { return false }
        let backup = file.appendingPathExtension("usagehud-backup")
        if let data = data, !FileManager.default.fileExists(atPath: backup.path) { try data.write(to: backup, options: .atomic); chmod(backup.path, 0o600) }
        let mode = (try? FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int) ?? 0o600
        try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]).write(to: file, options: .atomic)
        chmod(file.path, mode_t(mode))
        return true
    }
    public func handleCLI(_ arguments: [String]) throws -> Bool {
        // macOS may pass its own arguments (-psn_…, -NSDocument…); only ours start with two dashes.
        guard arguments.first?.hasPrefix("--") == true && arguments != ["--self-test"] && arguments != ["--product-test"] else { return false }
        if arguments == ["--claude-statusline"] {
            print(try statusline(FileHandle.standardInput.readDataToEndOfFile())); return true
        }
        if arguments == ["--probe-if-stale"] {
            // The running app reads Claude: it already holds the Keychain's answer, so a hook never brings a password prompt.
            DistributedNotificationCenter.default().postNotificationName(Self.claudeCodeRan, object: nil, userInfo: nil, deliverImmediately: true)
            return true
        }
        if arguments == ["--migrate-hooks"] {
            print(try connectClaudeCode(claudeCodeConnected) ? "Connected Claude Code" : "Claude Code already up to date")
            return true
        }
        if arguments == ["--disconnect-claude-code"] {
            // For uninstalling: our lines leave Claude Code's settings, and a later install connects again.
            print(try connectClaudeCode(false) ? "Removed Usage HUD from Claude Code's settings" : "Nothing to remove from Claude Code's settings")
            return true
        }
        if arguments.count == 4 && arguments[0] == "--write-bundle-info" {
            var info: JSON = ["CFBundleName": arguments[2], "CFBundleDisplayName": arguments[2],
                "CFBundleIdentifier": "local.usage-hud", "CFBundleVersion": "5", "CFBundleShortVersionString": "2.1",
                "CFBundlePackageType": "APPL", "CFBundleExecutable": "usagehud", "CFBundleIconFile": "AppIcon",
                "LSUIElement": true, "LSMinimumSystemVersion": "12.0", "NSHighResolutionCapable": true,
                "UsageHUDDataDirectory": arguments[3]]
            if let path = ProcessInfo.processInfo.environment["USAGE_HUD_CODEX_CLI"] {
                guard path.hasPrefix("/"), FileManager.default.isExecutableFile(atPath: path) else {
                    throw HUDProblem("USAGE_HUD_CODEX_CLI must point to an executable using an absolute path")
                }
                info["UsageHUDCodexCLI"] = path
            }
            try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: URL(fileURLWithPath: arguments[1]), options: .atomic)
            return true
        }
        if arguments.count == 2 && arguments[0] == "--stop-running" {
            let process = try RPCProcess(binary: URL(fileURLWithPath: "/bin/ps"), arguments: ["-axo", "pid=,comm="], timeout: 5)
            defer { process.stop() }
            let data = try process.allOutput()
            for line in (String(data: data, encoding: .utf8) ?? "").split(separator: "\n") {
                let fields = line.trimmingCharacters(in: .whitespaces).split(maxSplits: 1, whereSeparator: { $0.isWhitespace })
                if fields.count == 2, let pid = Int32(fields[0]), pid != getpid(), String(fields[1]) == arguments[1] { kill(pid, SIGTERM) }
            }
            return true
        }
        if arguments == ["--help"] {
            print("usagehud [--json | --refresh automatic|\(providers.map { $0.id }.joined(separator: "|"))|openai-credits | --claude-statusline | --probe-if-stale | --disconnect-claude-code]")
            return true
        }
        let refresh: String?
        if arguments == ["--json"] || arguments == ["--once"] { refresh = nil }
        else if arguments.count == 2 && arguments[0] == "--refresh" && (["automatic", "openai-credits"] + providers.map { $0.id }).contains(arguments[1]) { refresh = arguments[1] }
        else { throw HUDProblem("Unknown arguments; use --help") }
        let data = try JSONEncoder().encode(panels(refresh: refresh))
        print(String(data: data, encoding: .utf8)!); return true
    }
}
