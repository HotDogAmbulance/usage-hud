import Foundation
import Darwin

public final class Engine {
    public let root: URL
    let cache: Cache
    let providers: [UsageProvider]
    let credits: OpenAICredits
    public static var defaultRoot: URL {
        if let path = ProcessInfo.processInfo.environment["USAGE_HUD_HOME"] ?? Bundle.main.object(forInfoDictionaryKey: "UsageHUDDataDirectory") as? String {
            return URL(fileURLWithPath: path)
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".usage-hud")
    }
    public convenience init(root: URL = Engine.defaultRoot) { self.init(root: root, credentials: KeychainReader(), http: HTTPReader()) }
    init(root: URL, credentials: CredentialReading, http: HTTPReading, providers: [UsageProvider]? = nil) {
        self.root = root; cache = Cache(root)
        credits = OpenAICredits(cache: cache, credentials: credentials, http: http)
        self.providers = providers ?? [CodexProvider(cache: cache, credits: credits),
                                      ClaudeProvider(cache: cache, credentials: credentials, http: http),
                                      OpenRouterProvider(cache: cache, credentials: credentials, http: http),
                                      GLMProvider(cache: cache, credentials: credentials, http: http),
                                      GeminiProvider(cache: cache, http: http),
                                      GrokProvider(cache: cache),
                                      BalanceProvider.vercel(cache: cache, credentials: credentials, http: http),
                                      BalanceProvider.deepSeek(cache: cache, credentials: credentials, http: http),
                                      BalanceProvider.kimi(cache: cache, credentials: credentials, http: http)]
    }
    public func panels(refresh: String? = nil) -> [Panel] {
        if refresh == "openai-credits" { try? credits.refresh() }
        return providers.compactMap { provider -> Panel? in
            let statusFile = provider.id + "-status.json"
            if refresh == provider.id || refresh == "automatic" && provider.automatic {
                do {
                    try provider.refresh()
                    try cache.write(statusFile, ["error": NSNull(), "checked_at": Date().timeIntervalSince1970])
                } catch {
                    let message = (error as? HUDProblem)?.message ?? (error as? HTTPFailure).map { "Usage HTTP \($0.status)" } ?? "Usage unavailable"
                    try? cache.write(statusFile, ["error": message, "checked_at": Date().timeIntervalSince1970])
                }
            }
            guard provider.shown() else { return nil }
            var panel = provider.panel()
            if let message = cache.read(statusFile)["error"] as? String {
                panel.note = message
                for index in panel.windows.indices { panel.windows[index].stale = true }
            }
            return panel
        }
    }
    public func statusline(_ data: Data) throws -> String {
        guard let payload = try? JSONSerialization.jsonObject(with: data) as? JSON else { return "" }
        let now = Date().timeIntervalSince1970
        var updates: JSON = [:]
        let windows = dict(payload["rate_limits"])
        if !windows.isEmpty { try cache.quota("claude.json", windows: windows) }
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
    public func migrateHooks(executable: String, settings: URL? = nil) throws -> Int {
        let file = settings ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/settings.json")
        guard let data = try? Data(contentsOf: file), var value = try JSONSerialization.jsonObject(with: data) as? JSON else { return 0 }
        // Change only commands pointing at this HUD's retired script. Unrelated hooks remain untouched.
        let script = root.appendingPathComponent("usage_hud.py").path
        var changed = 0
        func rewrite(_ item: Any) -> Any {
            if let items = item as? [Any] { return items.map(rewrite) }
            guard var object = item as? JSON else { return item }
            for (key, raw) in object {
                if key == "command", let command = raw as? String, command.contains(script) {
                    if let flag = ["--claude-statusline", "--probe-if-stale"].first(where: command.contains) {
                        // POSIX single quotes protect spaces and shell metacharacters in user paths.
                        let quoted = "'" + executable.replacingOccurrences(of: "'", with: "'\\''") + "'"
                        object[key] = quoted + " " + flag; changed += 1
                    }
                } else if raw is JSON || raw is [Any] { object[key] = rewrite(raw) }
            }
            return object
        }
        value = dict(rewrite(value))
        if changed > 0 {
            let backup = file.appendingPathExtension("usagehud-native-backup")
            if !FileManager.default.fileExists(atPath: backup.path) { try data.write(to: backup, options: .atomic); chmod(backup.path, 0o600) }
            try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys]).write(to: file, options: .atomic)
            chmod(file.path, 0o600)
        }
        return changed
    }
    public func handleCLI(_ arguments: [String]) throws -> Bool {
        guard !arguments.isEmpty && arguments != ["--self-test"] else { return false }
        if arguments == ["--claude-statusline"] {
            print(try statusline(FileHandle.standardInput.readDataToEndOfFile())); return true
        }
        if arguments == ["--probe-if-stale"] {
            if Date().timeIntervalSince1970 - (number(cache.read("claude.json")["captured_at"]) ?? 0) > 300 { _ = panels(refresh: "claude") }
            return true
        }
        if arguments == ["--migrate-hooks"] {
            print("Updated \(try migrateHooks(executable: root.appendingPathComponent("usagehud").path)) Usage HUD hook commands")
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
            print("usagehud [--json | --refresh automatic|codex|claude|openrouter|glm|gemini|grok|vercel|deepseek|kimi|openai-credits | --claude-statusline | --probe-if-stale]")
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
