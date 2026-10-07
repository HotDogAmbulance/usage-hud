import Foundation

/// The places a person pointed Usage HUD at. Only paths are kept; keys are read when needed and stay in memory.
public enum KeySources {
    static func file(_ home: URL) -> URL { home.appendingPathComponent(".usage-hud/key-sources.json") }
    public static func list(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> [String] {
        (try? Data(contentsOf: file(home))).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String] } ?? []
    }
    static func marks(_ home: URL) -> URL { home.appendingPathComponent(".usage-hud/key-source-marks.json") }
    /// macOS bookmarks for the chosen paths (a bookmark follows its file when it is renamed or moved); no key is in them.
    static func bookmarks(home: URL) -> [String: String] {
        (try? Data(contentsOf: marks(home))).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: String] } ?? [:]
    }
    /// A bookmark for every chosen path that exists and has none yet (paths written by hand, or chosen before bookmarks existed).
    static func ensureMarks(home: URL) {
        var marks = bookmarks(home: home), changed = false
        for path in list(home: home) where marks[path] == nil && FileManager.default.fileExists(atPath: path) {
            if let data = try? URL(fileURLWithPath: path).bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil) { marks[path] = data.base64EncodedString(); changed = true }
        }
        if changed, let data = try? JSONSerialization.data(withJSONObject: marks) { try? data.write(to: Self.marks(home), options: .atomic) }
    }
    /// A chosen path that is gone, found again through its bookmark. The list is updated so the new name is used from now on.
    static func resolve(_ path: String, home: URL) -> URL? {
        var marks = bookmarks(home: home)
        guard let text = marks[path], let data = Data(base64Encoded: text) else { return nil }
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: data, options: [], relativeTo: nil, bookmarkDataIsStale: &stale),
              FileManager.default.fileExists(atPath: url.path) else { return nil }
        var paths = list(home: home)
        if let index = paths.firstIndex(of: path) { paths[index] = url.path }
        marks[path] = nil
        marks[url.path] = (try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil))?.base64EncodedString() ?? text
        try? JSONSerialization.data(withJSONObject: paths).write(to: file(home), options: .atomic)
        try? JSONSerialization.data(withJSONObject: marks).write(to: Self.marks(home), options: .atomic)
        return url
    }
    /// Remembers `urls` and returns how many distinct OpenRouter keys they hold, so the person can see it worked.
    @discardableResult
    public static func add(_ urls: [URL], home: URL = FileManager.default.homeDirectoryForCurrentUser) -> Int {
        var paths = list(home: home), marks = bookmarks(home: home)
        for url in urls where !paths.contains(url.path) { paths.append(url.path) }
        for url in urls { marks[url.path] = (try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil))?.base64EncodedString() }
        try? FileManager.default.createDirectory(at: file(home).deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        if let data = try? JSONSerialization.data(withJSONObject: marks) { try? data.write(to: Self.marks(home), options: .atomic) }
        if let data = try? JSONSerialization.data(withJSONObject: paths) {
            try? data.write(to: file(home), options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file(home).path)
        }
        return KeyFinder.find(in: KeyFinder.chosen(home: home), environment: [:]).count
    }
}
