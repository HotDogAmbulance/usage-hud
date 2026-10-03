import Foundation
import Darwin
import CoreFoundation

typealias JSON = [String: Any]
struct HUDProblem: Error, LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
func number(_ value: Any?) -> Double? {
    guard let value = value, !(value is NSNull) else { return nil }
    if let n = value as? NSNumber, CFGetTypeID(n) == CFBooleanGetTypeID() { return nil }
    let result = (value as? NSNumber)?.doubleValue ?? (value as? String).flatMap(Double.init)
    return result?.isFinite == true ? result : nil
}
func dict(_ value: Any?) -> JSON { value as? JSON ?? [:] }
func usd(_ value: Double) -> String { String(format: "$%.2f", value) }
func resetTime(_ value: Any?) -> Double? {
    if let n = number(value) { return n }
    guard let text = value as? String else { return nil }
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
    public init(id: String, name: String, windows: [Window] = [], note: String = "") {
        self.id = id; self.name = name; self.windows = windows; self.note = note
    }
    public var displayedQuota: Window? {
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
