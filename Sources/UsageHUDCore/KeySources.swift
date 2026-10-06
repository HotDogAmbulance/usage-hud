import Foundation

/// The places a person pointed Usage HUD at. Only paths are kept; keys are read when needed and stay in memory.
public enum KeySources {
    static func file(_ home: URL) -> URL { home.appendingPathComponent(".usage-hud/key-sources.json") }
    public static func list(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> [String] {
        (try? Data(contentsOf: file(home))).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String] } ?? []
    }
    /// Remembers `urls` and returns how many distinct OpenRouter keys they hold, so the person can see it worked.
    @discardableResult
    public static func add(_ urls: [URL], home: URL = FileManager.default.homeDirectoryForCurrentUser) -> Int {
        var paths = list(home: home)
        for url in urls where !paths.contains(url.path) { paths.append(url.path) }
        try? FileManager.default.createDirectory(at: file(home).deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        if let data = try? JSONSerialization.data(withJSONObject: paths) {
            try? data.write(to: file(home), options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file(home).path)
        }
        return KeyFinder.find(in: KeyFinder.chosen(home: home), environment: [:]).count
    }
}
