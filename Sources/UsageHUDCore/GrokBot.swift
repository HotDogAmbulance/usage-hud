import Foundation

/// Grok Bot (xAI and Cursor's agent app). The app keeps its own plan-usage reading, with no credentials in it, in a small
/// file under its support folder; the HUD reads that file and makes no network call. The reading is as fresh as the
/// app's last refresh, so the battery dims when the app has been closed.
final class GrokBotProvider: UsageProvider {
    let id = "grokbot", name = "Grok Bot", automatic = true
    let cache: Cache, home: URL
    init(cache: Cache, home: URL = FileManager.default.homeDirectoryForCurrentUser) { self.cache = cache; self.home = home }
    private var support: URL { home.appendingPathComponent("Library/Application Support/Grok Bot") }
    func shown() -> Bool { FileManager.default.fileExists(atPath: cache.root.appendingPathComponent("grokbot.json").path) }
    /// The newest usage reading among the app's small saved values, found by content because the file names are encoded keys.
    static func reading(in folder: URL) -> (usage: JSON, readAt: Double, expiresAt: Double?)? {
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        var newest: (usage: JSON, readAt: Double, expiresAt: Double?)?
        for file in files where file.pathExtension == "blob" {
            guard let size = try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 16 * 1024,
                  let data = try? Data(contentsOf: file),
                  let value = dict(dict(try? JSONSerialization.jsonObject(with: data))["value"]) as JSON?,
                  case let reading = dict(value["reading"]), number(dict(reading["usage"])["percentUsed"]) != nil,
                  let readAt = number(reading["readAtMs"]).map({ $0 / 1000 }) else { continue }
            if newest == nil || readAt > newest!.readAt {
                newest = (dict(reading["usage"]), readAt, number(value["expiresAtMs"]).map { $0 / 1000 })
            }
        }
        return newest
    }
    static func windows(_ usage: JSON) -> JSON? {
        guard let pct = number(usage["percentUsed"]) else { return nil }
        return ["w10080": ["used_percentage": pct, "window_minutes": 10080,
                           "resets_at": number(usage["nextResetMs"]).map { $0 / 1000 } as Any? ?? NSNull()]]
    }
    static func plan(_ usage: JSON) -> String? {
        if usage["isSandTrial"] as? Bool == true { return "Trial" }
        return (usage["grokPlanLabel"] as? String).flatMap { $0.isEmpty ? nil : $0 }
    }
    func refresh() throws {
        guard FileManager.default.fileExists(atPath: support.path) else { throw HUDProblem("Grok Bot isn't installed", gone: true) }
        let open = HUDProblem("Open Grok Bot to update its usage")
        guard let found = Self.reading(in: support.appendingPathComponent("sand-client-persistence")),
              let windows = Self.windows(found.usage) else { throw open }
        // An old reading stays on the battery, dimmed, until the app writes a newer one.
        guard found.readAt > number(cache.read("grokbot.json")["captured_at"]) ?? 0 else { throw open }
        try cache.quota("grokbot.json", windows: windows, extra: ["reading_source": ReadingSource.grokBotLocal.rawValue,
                        "source_read_at": found.readAt, "plan": Self.plan(found.usage) as Any? ?? NSNull()], now: found.readAt)
        if let expires = found.expiresAt, expires < Date().timeIntervalSince1970 { throw open }
    }
    func panel() -> Panel {
        let blob = cache.read("grokbot.json"), rows = quotaWindows(blob)
        return Panel(id: id, name: name, windows: rows, note: (blob["plan"] as? String).map { "Plan: " + $0 } ?? (rows.isEmpty ? "Open Grok Bot to read usage" : ""))
    }
}
