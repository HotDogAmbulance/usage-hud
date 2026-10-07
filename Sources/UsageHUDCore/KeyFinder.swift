import Foundation

/// Finds the OpenRouter keys people already keep on this Mac, so nothing needs setting up. OpenRouter has no sign-in file,
/// but its keys are unmistakable, so a few likely places are read and only exact key matches are taken. Keys go nowhere
/// but openrouter.ai and are never written down.
enum KeyFinder {
    /// The key, and the variable it is assigned to when there is one.
    static let pattern = try! NSRegularExpression(pattern: "(?:\\b([A-Za-z_][A-Za-z0-9_]*)\\s*[=:]\\s*[\"']?)?(sk-or-v1-[0-9a-f]{64})")
    /// `ALICE_OPENROUTER_KEY` names its key "alice"; generic names like `OPENROUTER_API_KEY` say nothing, so the file names it.
    static func person(_ variable: String) -> String? {
        let words = variable.lowercased().split(separator: "_").filter { !["openrouter", "or", "api", "key", "token"].contains($0) }
        return words.isEmpty ? nil : words.joined(separator: " ")
    }
    /// Files and folders the person pointed Usage HUD at, one path each in `~/.usage-hud/key-sources.json`. A folder is read
    /// to four levels, hidden folders included, since the person chose it.
    static func chosen(home: URL) -> [URL] {
        guard let data = try? Data(contentsOf: home.appendingPathComponent(".usage-hud/key-sources.json")),
              let paths = (try? JSONSerialization.jsonObject(with: data)) as? [String] else { return [] }
        let kinds: Set<String> = ["sh", "zsh", "bash", "env", "json", "jsonc", "yaml", "yml", "toml", "conf", "txt", "fish", ""]
        var found: [URL] = []
        for path in paths {
            let root = URL(fileURLWithPath: path)
            var isFolder: ObjCBool = false
            guard FileManager.default.fileExists(atPath: root.path, isDirectory: &isFolder) else { continue }
            guard isFolder.boolValue else { found.append(root); continue }
            guard let walk = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil, options: [.skipsPackageDescendants]) else { continue }
            while let url = walk.nextObject() as? URL, found.count < 2000 {
                if ["node_modules", ".git", "build", "dist", "venv", ".build"].contains(url.lastPathComponent) || walk.level > 4 { walk.skipDescendants(); continue }
                var file: ObjCBool = false
                if FileManager.default.fileExists(atPath: url.path, isDirectory: &file), !file.boolValue, kinds.contains(url.pathExtension.lowercased()) { found.append(url) }
            }
        }
        return found
    }
    /// What the person chose, then the few usual places: shell profiles and AI tool configs. Scripts are only read when dropped.
    static func places(home: URL) -> [URL] {
        chosen(home: home) + [".zshrc", ".zprofile", ".zshenv", ".bashrc", ".bash_profile", ".profile", ".env", ".config/fish/config.fish",
                     ".local/share/opencode/auth.json", ".aider.conf.yml", ".config/crush/crush.json", ".continue/config.yaml",
                     ".continue/config.json", ".config/zed/settings.json"].map { home.appendingPathComponent($0) }
    }
    /// "boot-alice.sh" is "boot-alice", ".zshrc" is "zshrc"; a tool's config is named after its folder, so opencode's auth.json is "opencode".
    static func label(_ file: URL) -> String {
        let stem = file.deletingPathExtension().lastPathComponent
        let name = ["auth", "config", "settings"].contains(stem) ? file.deletingLastPathComponent().lastPathComponent : stem
        return name.trimmingCharacters(in: CharacterSet(charactersIn: "."))
    }
    /// A dropped boot is named after its file: "ox3.sh" is "Ox3".
    static func boot(_ file: URL) -> String {
        let name = label(file)
        return name.prefix(1).uppercased() + name.dropFirst()
    }
    /// Each distinct key once, named after its variable or else the first file it appears in; a dropped boot is always named
    /// after its file. Files over 1 MB are skipped.
    static func find(in files: [URL], chosen: [URL] = [], environment: [String: String] = ProcessInfo.processInfo.environment) -> [(label: String, key: String)] {
        var found: [(label: String, key: String)] = [], seen = Set<String>()
        let dropped = Set(chosen.map { $0.path })
        let sources = [("environment", environment["OPENROUTER_API_KEY"] ?? "", false)] + files.compactMap { file -> (String, String, Bool)? in
            guard ((try? file.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? .max) < 1 << 20,
                  let text = try? String(contentsOf: file, encoding: .utf8) else { return nil }
            return dropped.contains(file.path) ? (boot(file), text, true) : (label(file), text, false)
        }
        for (file, text, isBoot) in sources {
            for match in pattern.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                let key = (text as NSString).substring(with: match.range(at: 2))
                guard seen.insert(key).inserted else { continue }
                let variable = match.range(at: 1).location == NSNotFound ? "" : (text as NSString).substring(with: match.range(at: 1))
                let name = isBoot ? file : person(variable) ?? file
                let taken = found.filter { $0.label == name || $0.label.hasPrefix(name + " ") }.count
                found.append((taken == 0 ? name : "\(name) \(taken + 1)", key))
            }
        }
        return found
    }
    /// Dropped boots that run OpenCode Zen's free models and hold no OpenRouter key. Zen needs no key and publishes no usage.
    static func zen(in files: [URL]) -> [String] {
        let free = try! NSRegularExpression(pattern: "opencode/[A-Za-z0-9._-]+-free\\b")
        return files.compactMap { file -> String? in
            guard ((try? file.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? .max) < 1 << 20,
                  let text = try? String(contentsOf: file, encoding: .utf8),
                  free.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil,
                  pattern.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) == nil else { return nil }
            return boot(file)
        }
    }
    /// Keys for providers whose Anthropic-compatible endpoint Claude Code is pointed at (Z.ai, DeepSeek, Moonshot), keyed by
    /// whichever of `hosts` shares that endpoint's domain. The key only ever goes to our fixed host, never to the URL found beside it.
    static func claudeCode(hosts: [String], home: URL, environment: [String: String]) -> [String: String] {
        let settings = (try? Data(contentsOf: home.appendingPathComponent(".claude/settings.json"))).flatMap { try? JSONSerialization.jsonObject(with: $0) }
        var keys: [String: String] = [:]
        for source in [environment, dict(dict(settings)["env"]).compactMapValues { $0 as? String }] {
            guard let base = URL(string: source["ANTHROPIC_BASE_URL"] ?? "")?.host?.lowercased(),
                  let key = source["ANTHROPIC_AUTH_TOKEN"] ?? source["ANTHROPIC_API_KEY"], !key.isEmpty,
                  let host = hosts.first(where: { let domain = $0.split(separator: ".").suffix(2).joined(separator: ".")
                                                  return base == domain || base.hasSuffix("." + domain) }) else { continue }
            keys[host] = keys[host] ?? key
        }
        return keys
    }
    /// The first group of `pattern`'s first match in `text`.
    static func capture(_ pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[range])
    }
    /// The value given to one of `variables` (`DEEPSEEK_API_KEY=…`, `export …`, or a JSON `"…": "…"`) in the environment or
    /// the usual places. These keys look like any other provider's, so only the variable's name can say whose they are.
    /// `value` is what the value must look like: a key by default, or a proxy's address.
    static func assigned(_ variables: [String], in files: [URL], environment: [String: String] = ProcessInfo.processInfo.environment,
                         value: String = "[A-Za-z0-9._-]{16,}") -> String? {
        if let key = variables.lazy.compactMap({ environment[$0] }).first(where: { $0.range(of: "^" + value + "$", options: .regularExpression) != nil }) { return key }
        guard let pattern = try? NSRegularExpression(pattern: "\\b(?:" + variables.joined(separator: "|") + ")[\"']?\\s*[=:]\\s*[\"']?(" + value + ")") else { return nil }
        for file in files where ((try? file.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? .max) < 1 << 20 {
            guard let text = try? String(contentsOf: file, encoding: .utf8),
                  let match = pattern.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { continue }
            return (text as NSString).substring(with: match.range(at: 1))
        }
        return nil
    }
}
