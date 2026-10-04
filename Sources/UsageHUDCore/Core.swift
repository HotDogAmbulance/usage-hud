import Foundation
import Darwin
import CoreFoundation

typealias JSON = [String: Any]
struct HUDProblem: Error, LocalizedError {
    let message: String
    /// Only the user can fix it (a rejected key, a revoked sign-in); the battery asks for attention.
    /// Tokens that merely expired while their CLI sat idle renew themselves and stay quiet.
    let attention: Bool
    /// macOS showed a Keychain password prompt. Background refreshes then leave that provider alone until the user
    /// refreshes it from its menu, so the prompt never comes back on its own.
    let prompted: Bool
    /// A harmless command that fixes it, offered in the battery's menu (for example `claude auth login`).
    let fix: String?
    /// What feeds the battery is no longer on this Mac (app removed, CLI uninstalled, key deleted), so the battery leaves too.
    let gone: Bool
    init(_ message: String, attention: Bool = false, prompted: Bool = false, fix: String? = nil, gone: Bool = false) {
        self.message = message; self.attention = attention || prompted; self.prompted = prompted; self.fix = fix; self.gone = gone
    }
    var errorDescription: String? { message }
}
func number(_ value: Any?) -> Double? {
    guard let value = value, !(value is NSNull) else { return nil }
    if let n = value as? NSNumber, CFGetTypeID(n) == CFBooleanGetTypeID() { return nil }
    let result = (value as? NSNumber)?.doubleValue ?? (value as? String).flatMap(Double.init)
    return result?.isFinite == true ? result : nil
}
func dict(_ value: Any?) -> JSON { value as? JSON ?? [:] }
/// "$20", "$1.25": whole amounts drop their cents, so "$0 / $20" reads at a glance.
func money(_ value: Double, _ symbol: String = "$") -> String {
    symbol + ((value * 100).rounded() == (value.rounded() * 100) ? String(Int(value.rounded())) : String(format: "%.2f", value))
}
func usd(_ value: Double) -> String { money(value) }
/// Free quota resets a plan granted (Claude, Codex): how many, and the soonest expiry, as "2 · until Oct 23".
func freeResetsRow(_ value: Any?, stale: Bool) -> Window? {
    let resets = dict(value)
    guard let left = number(resets["left"]), left >= 1 else { return nil }
    var text = String(Int(left))
    if let until = number(resets["until"]) {
        let format = DateFormatter(); format.setLocalizedDateFormatFromTemplate("MMMd")
        text += " · until " + format.string(from: Date(timeIntervalSince1970: until))
    }
    return Window(label: "Free resets", right: text, stale: stale)
}
/// "3h 12m" or "2d 5h"; never negative.
public func countdown(_ seconds: Double) -> String {
    let minutes = max(0, Int(seconds / 60))
    return minutes >= 1440 ? "\(minutes / 1440)d \(minutes % 1440 / 60)h" : "\(minutes / 60)h \(minutes % 60)m"
}
func resetTime(_ value: Any?) -> Double? {
    if let n = number(value) { return n }
    // Some APIs send nanoseconds ("…13.716839300Z"); the formatter wants at most milliseconds.
    guard let text = (value as? String)?.replacingOccurrences(of: #"(\.\d{3})\d+"#, with: "$1", options: .regularExpression) else { return nil }
    let format = ISO8601DateFormatter()
    format.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return (format.date(from: text) ?? ISO8601DateFormatter().date(from: text))?.timeIntervalSince1970
}

public struct Window: Codable {
    public let label: String
    public let pct: Double?
    public let right: String?
    public let resets_at: Double?
    public let expired: Bool?
    public var stale: Bool?
    public init(label: String, pct: Double? = nil, right: String? = nil, resets_at: Double? = nil,
                expired: Bool? = false, stale: Bool? = false) {
        self.label = label; self.pct = pct; self.right = right; self.resets_at = resets_at
        self.expired = expired; self.stale = stale
    }
}
public struct Panel: Codable {
    public let id: String
    public let name: String
    public var windows: [Window]
    public var note: String
    /// Something the user should look at (a cap reached, money running out, a rejected key). The battery pulses until hovered.
    public var alert: String?
    /// Per-key detail for the hover panel: `pct` is the share of a cap used, `right` the readable amount.
    public var cells: [Window]
    /// A one-line overview above the cells, such as "23 keys · $41.20 today · 3 near cap".
    public var cellsTitle: String?
    /// The window the battery shows, when the provider knows better than the 5h/7d rule; shown dimmed once cached.
    public var lead: String?
    /// A command that fixes the current problem, from the provider; the menu can run it in Terminal.
    public var fix: String?
    public init(id: String, name: String, windows: [Window] = [], note: String = "", alert: String? = nil,
                cells: [Window] = [], cellsTitle: String? = nil, lead: String? = nil) {
        self.id = id; self.name = name; self.windows = windows; self.note = note; self.alert = alert
        self.cells = cells; self.cellsTitle = cellsTitle; self.lead = lead
    }
    public var displayedQuota: Window? {
        if let lead = lead, let window = windows.first(where: { $0.label == lead && $0.pct != nil }) { return window }
        if let five = windows.first(where: { $0.label == "5h" && $0.pct != nil && $0.stale != true && $0.expired != true }) { return five }
        if let week = windows.first(where: { $0.label == "7d" && $0.pct != nil }) { return week }
        return windows.first(where: { $0.pct != nil && $0.stale != true && $0.expired != true })
    }
}

final class Cache {
    let root: URL
    init(_ root: URL) { self.root = root }
    func read(_ name: String) -> JSON {
        guard let data = try? Data(contentsOf: root.appendingPathComponent(name)),
              let object = try? JSONSerialization.jsonObject(with: data) else { return [:] }
        return dict(object)
    }
    func withLock<T>(_ action: () throws -> T) throws -> T {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        chmod(root.path, 0o700)
        let fd = Darwin.open(root.appendingPathComponent("cache.lock").path, O_CREAT | O_RDWR, 0o600)
        guard fd >= 0 else { throw HUDProblem("Cache lock unavailable") }
        defer { flock(fd, LOCK_UN); close(fd) }
        guard flock(fd, LOCK_EX) == 0 else { throw HUDProblem("Cache lock unavailable") }
        return try action()
    }
    private func replace(_ name: String, _ object: JSON) throws {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        let target = root.appendingPathComponent(name)
        let temporary = root.appendingPathComponent(".\(name).\(UUID().uuidString).tmp")
        defer { try? FileManager.default.removeItem(at: temporary) }
        let fd = Darwin.open(temporary.path, O_CREAT | O_EXCL | O_WRONLY, 0o600)
        guard fd >= 0 else { throw HUDProblem("Cache write unavailable") }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        try handle.write(contentsOf: data); try handle.synchronize(); try handle.close()
        guard rename(temporary.path, target.path) == 0 else { throw HUDProblem("Cache replace unavailable") }
        chmod(target.path, 0o600)
    }
    func write(_ name: String, _ object: JSON) throws { try withLock { try replace(name, object) } }
    func merge(_ name: String, _ updates: JSON) throws {
        try withLock {
            var value = read(name); value.merge(updates) { _, new in new }; try replace(name, value)
        }
    }
    func quota(_ name: String, windows: JSON, extra: JSON = [:], now: Double = Date().timeIntervalSince1970) throws {
        try withLock {
            var blob = read(name), saved: JSON = [:]
            for (key, raw) in dict(blob["rate_limits"]) {
                var window = dict(raw); window["stale"] = true
                window["captured_at"] = number(window["captured_at"]) ?? number(blob["captured_at"]) ?? 0
                saved[key] = window
            }
            for (key, raw) in windows {
                var window = dict(raw); window["stale"] = false; window["captured_at"] = now; saved[key] = window
            }
            blob.merge(extra) { _, new in new }
            blob["rate_limits"] = saved; blob["captured_at"] = now; blob["error"] = NSNull()
            try replace(name, blob)
        }
    }
}
func quotaWindows(_ blob: JSON, now: Double = Date().timeIntervalSince1970) -> [Window] {
    let captured = number(blob["captured_at"]) ?? 0
    let labels = ["five_hour": "5h", "seven_day": "7d", "primary": "5h", "secondary": "7d"]
    var rows: [(Double, Window)] = []
    for (key, raw) in dict(blob["rate_limits"]) {
        let value = dict(raw)
        guard let pct = number(value["used_percentage"]) ?? number(value["used_percent"]) else { continue }
        let minutes = number(value["window_minutes"])
        var label = labels[key] ?? key.replacingOccurrences(of: "_", with: " ")
        if let minutes = minutes, minutes > 0 {
            label = minutes.truncatingRemainder(dividingBy: 10080) == 0 ? "\(Int(minutes / 1440))d" :
                    minutes.truncatingRemainder(dividingBy: 1440) == 0 ? "\(Int(minutes / 1440))d" :
                    minutes.truncatingRemainder(dividingBy: 60) == 0 ? "\(Int(minutes / 60))h" : "\(Int(minutes))m"
        } else if key.hasPrefix("seven_day_") { label = "7d " + key.dropFirst(10).replacingOccurrences(of: "_", with: " ") }
        let capturedWindow = number(value["captured_at"]) ?? captured
        let reset = resetTime(value["resets_at"]) ?? number(value["resets_in_seconds"]).map { capturedWindow + $0 }
        let stale = value["stale"] as? Bool == true || now - capturedWindow > 600
        let duration = minutes.map { $0 * 60 } ?? (key == "five_hour" || key == "primary" ? 18000 : key == "seven_day" || key == "secondary" ? 604800 : .infinity)
        rows.append((duration, Window(label: label, pct: max(0, min(100, pct)), resets_at: reset,
                                      expired: reset.map { $0 < now } ?? false, stale: stale)))
    }
    return rows.sorted { $0.0 == $1.0 ? $0.1.label < $1.1.label : $0.0 < $1.0 }.map { $0.1 }
}
