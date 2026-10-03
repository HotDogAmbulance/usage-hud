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
    /// Folders macOS guards with a permission prompt, or that only hold other apps' and packages' files.
    static let skipped: Set<String> = ["Library", "Applications", "Desktop", "Documents", "Downloads", "Movies", "Music", "Pictures",
                                       "Public", "node_modules", "build", "dist", "venv"]
    /// `.sh` scripts within three levels of home, where people keep them in their own order. Hidden and guarded folders
    /// are skipped, and at most 500 scripts are read.
    static func scripts(home: URL) -> [URL] {
        guard let walk = FileManager.default.enumerator(at: home, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles, .skipsPackageDescendants])
        else { return [] }
        var found: [URL] = []
        while let url = walk.nextObject() as? URL, found.count < 500 {
            if skipped.contains(url.lastPathComponent) || walk.level > 3 { walk.skipDescendants(); continue }
            if url.pathExtension == "sh" { found.append(url) }
        }
        return found.sorted { $0.path < $1.path }
    }
    /// Shell profiles, AI tool configs, then personal scripts, which people tend to name after a person or a job.
    static func places(home: URL) -> [URL] {
        [".zshrc", ".zprofile", ".zshenv", ".bashrc", ".bash_profile", ".profile", ".env", ".config/fish/config.fish",
                     ".local/share/opencode/auth.json", ".aider.conf.yml", ".config/crush/crush.json", ".continue/config.yaml",
                     ".continue/config.json", ".config/zed/settings.json"].map { home.appendingPathComponent($0) } + scripts(home: home)
    }
    /// "boot-alice.sh" is "boot-alice", ".zshrc" is "zshrc"; a tool's config is named after its folder, so opencode's auth.json is "opencode".
    static func label(_ file: URL) -> String {
        let stem = file.deletingPathExtension().lastPathComponent
        let name = ["auth", "config", "settings"].contains(stem) ? file.deletingLastPathComponent().lastPathComponent : stem
        return name.trimmingCharacters(in: CharacterSet(charactersIn: "."))
    }
    /// Each distinct key once, named after its variable or else the first file it appears in. Files over 1 MB are skipped.
    static func find(in files: [URL], environment: [String: String] = ProcessInfo.processInfo.environment) -> [(label: String, key: String)] {
        var found: [(label: String, key: String)] = [], seen = Set<String>()
        let sources = [("environment", environment["OPENROUTER_API_KEY"] ?? "")] + files.compactMap { file -> (String, String)? in
            guard ((try? file.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? .max) < 1 << 20,
                  let text = try? String(contentsOf: file, encoding: .utf8) else { return nil }
            return (label(file), text)
        }
        for (file, text) in sources {
            for match in pattern.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                let key = (text as NSString).substring(with: match.range(at: 2))
                guard seen.insert(key).inserted else { continue }
                let variable = match.range(at: 1).location == NSNotFound ? "" : (text as NSString).substring(with: match.range(at: 1))
                let name = person(variable) ?? file
                let taken = found.filter { $0.label == name || $0.label.hasPrefix(name + " ") }.count
                found.append((taken == 0 ? name : "\(name) \(taken + 1)", key))
            }
        }
        return found
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
    /// The value given to one of `variables` (`DEEPSEEK_API_KEY=…`, `export …`, or a JSON `"…": "…"`) in the environment or
    /// the usual places. These keys look like any other provider's, so only the variable's name can say whose they are.
    static func assigned(_ variables: [String], in files: [URL], environment: [String: String] = ProcessInfo.processInfo.environment) -> String? {
        if let key = variables.lazy.compactMap({ environment[$0] }).first(where: { $0.count >= 16 }) { return key }
        guard let pattern = try? NSRegularExpression(pattern: "\\b(?:" + variables.joined(separator: "|") + ")[\"']?\\s*[=:]\\s*[\"']?([A-Za-z0-9._-]{16,})") else { return nil }
        for file in files where ((try? file.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? .max) < 1 << 20 {
            guard let text = try? String(contentsOf: file, encoding: .utf8),
                  let match = pattern.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { continue }
            return (text as NSString).substring(with: match.range(at: 1))
        }
        return nil
    }
}
