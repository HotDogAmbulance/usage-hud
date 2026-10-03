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
    /// The standard places only: shell profiles and AI tool configs. Personal scripts are left alone.
    static func places(home: URL) -> [URL] {
        [".zshrc", ".zprofile", ".zshenv", ".bashrc", ".bash_profile", ".profile", ".env", ".config/fish/config.fish",
                     ".local/share/opencode/auth.json", ".aider.conf.yml", ".config/crush/crush.json", ".continue/config.yaml",
                     ".continue/config.json", ".config/zed/settings.json"].map { home.appendingPathComponent($0) }
    }
    /// ".zshrc" is "zshrc"; a tool's config is named after its folder, so opencode's auth.json is "opencode".
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
}
