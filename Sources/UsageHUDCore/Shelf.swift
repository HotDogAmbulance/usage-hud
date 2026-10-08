import Foundation

/// Decides which batteries stay in the menu bar, learning each person's main tools from use. A provider counts as used
/// when its quota rises or its balance falls; the most used ones stay visible and the rest move into one overflow item.
public struct Shelf {
    public var levels: [String: Double]
    public var lastUsed: [String: Double]
    /// One point per five-minute stretch with use, halving every week, so a main tool outranks one tried yesterday
    /// and a switch of main tools shows within days. Every tool is counted the same, however often it reports.
    public var scores: [String: Double]
    public var scoredAt: Double
    /// Batteries the person chose to keep in the bar, oldest first; a new choice takes a place from the least recent one.
    public var pins: [String]
    /// When each pin was made. A pin holds its place while that battery is in use, and lapses after a week without use or
    /// a fresh choice; the battery stays one click away in the logo, as before.
    public var pinnedAt: [String: Double]
    public static let pinLife: Double = 7 * 86_400
    /// The bar as the person laid it out by dragging, left to right. Once set it holds (use no longer reorders it); batteries not
    /// in it fill any free places by rank, and one asking for attention takes the seat of the least used.
    public var placed: [String]
    /// Alerts the person chose to leave out of the bar by taking the battery's seat for another, by battery id: the alert's text
    /// at that moment. The same alert stays out, across restarts; a different one, or the same one after it cleared, asks again.
    public var settled: [String: String]
    public init(levels: [String: Double] = [:], lastUsed: [String: Double] = [:], scores: [String: Double] = [:], scoredAt: Double = 0,
                pins: [String] = [], pinnedAt: [String: Double] = [:], placed: [String] = [], settled: [String: String] = [:]) {
        self.levels = levels; self.lastUsed = lastUsed; self.scores = scores; self.scoredAt = scoredAt; self.pins = pins; self.pinnedAt = pinnedAt
        self.placed = placed; self.settled = settled
    }
    /// The batteries whose alert should claim a seat: every alert in `alerts` (by battery id) except one the person already
    /// left out. Alerts that cleared or changed since are forgotten here, so they ask again next time; a battery absent from
    /// `ids` (not read yet, or hidden) keeps its answer.
    public mutating func urgent(_ alerts: [String: String], among ids: [String]) -> Set<String> {
        settled = settled.filter { id, text in !ids.contains(id) || alerts[id] == text }
        return Set(alerts.filter { ids.contains($0.key) && settled[$0.key] != $0.value }.keys)
    }
    /// The person took the seat of `id` for another battery: its current alert, if any, stays out of the bar until it changes.
    public mutating func leave(_ id: String, alert: String?) { if let alert = alert { settled[id] = alert } }
    /// Puts `id` where `seat` stands in the bar `bar` (left to right): two batteries in the bar trade places; one from outside
    /// takes the seat and the battery there leaves the bar.
    public mutating func place(_ id: String, at seat: String, bar: [String]) {
        if !placed.contains(seat) { placed = bar }
        guard id != seat, let target = placed.firstIndex(of: seat) else { return }
        if let from = placed.firstIndex(of: id) { placed.swapAt(from, target) } else { placed[target] = id }
    }
    /// The pin still holds: made, or the battery used, within the last week. A pin with no date (older settings) holds.
    func pinned(_ id: String, now: Double) -> Int? {
        guard let index = pins.lastIndex(of: id) else { return nil }
        guard let made = pinnedAt[id] else { return index + 1 }
        return now - max(made, lastUsed[id] ?? 0) < Self.pinLife ? index + 1 : nil
    }
    /// Keeps `id` in the bar as the latest choice.
    public mutating func pin(_ id: String, now: Double = Date().timeIntervalSince1970) { pins.removeAll { $0 == id }; pins.append(id); pinnedAt[id] = now }
    /// Pins `id`, or lets it go if it was already pinned.
    public mutating func togglePin(_ id: String) {
        if let index = pins.firstIndex(of: id) { pins.remove(at: index); pinnedAt[id] = nil } else { pin(id) }
    }
    /// One number that grows with use: the sum of used percentages, or the negated balance.
    public static func level(_ panel: Panel) -> Double? {
        let used = panel.windows.compactMap { $0.pct }
        if !used.isEmpty { return used.reduce(0, +) }
        guard let right = panel.windows.first(where: { $0.label == panel.name })?.right,
              let amount = Double(String(right.split(separator: " ").first ?? "").filter { "-0123456789.".contains($0) }) else { return nil }
        return -amount
    }
    public mutating func observe(_ panel: Panel, now: Double) {
        guard let level = Self.level(panel) else { return }
        if scoredAt > 0 { let fade = pow(0.5, max(0, now - scoredAt) / 604_800); scores = scores.mapValues { $0 * fade } }
        scoredAt = now
        if let old = levels[panel.id] {
            if level > old + 0.001 {
                if Int(now / 300) != Int((lastUsed[panel.id] ?? -300) / 300) { scores[panel.id, default: 0] += 1 }
                lastUsed[panel.id] = now
            }
        } else if level > 0, scores[panel.id] == nil {
            // Quota already spent at first sight means the tool is in use, so a main tool leads from day one.
            scores[panel.id] = min(1, level / 100)
        }
        levels[panel.id] = level
    }
    /// Batteries asking for attention first, then the ones chosen by hand (latest choice first), then by score and last use;
    /// ties keep the engine's order.
    public func ranked(_ ids: [String], urgent: Set<String> = [], now: Double = Date().timeIntervalSince1970) -> [String] {
        let key = { (id: String) in (urgent.contains(id) ? 1 : 0, self.pinned(id, now: now) ?? 0, self.scores[id] ?? 0, self.lastUsed[id] ?? 0) }
        return ids.enumerated().sorted { key($0.element) != key($1.element) ? key($0.element) > key($1.element) : $0.offset < $1.offset }.map { $0.element }
    }
    /// The battery in `ids` worth least to keep in the bar: not asking for attention, and last by choice, score and use.
    public func leastUsed(_ ids: [String], urgent: Set<String> = [], now: Double = Date().timeIntervalSince1970) -> String? {
        ranked(ids.filter { !urgent.contains($0) }, now: now).last
    }
    /// Splits `ids` into those shown and those moved to the overflow item. Without a laid-out bar both keep their original
    /// order; with one, the shown follow it. The bar never holds more than `limit`: a battery asking for attention takes the
    /// seat of the least used one, and gives it back once its alert clears or the person takes the seat for another battery.
    public func arrange(_ ids: [String], limit: Int, urgent: Set<String> = [], now: Double = Date().timeIntervalSince1970) -> (shown: [String], hidden: [String]) {
        let laid = Array(placed.filter(ids.contains).prefix(max(0, limit)))
        guard !laid.isEmpty else {
            let shown = Set(ranked(ids, urgent: urgent, now: now).prefix(max(0, limit)))
            return (ids.filter { shown.contains($0) }, ids.filter { !shown.contains($0) })
        }
        let rest = ranked(ids.filter { !laid.contains($0) }, urgent: urgent, now: now), free = max(0, limit - laid.count)
        var shown = laid + rest.prefix(free)
        for id in rest.dropFirst(free) where urgent.contains(id) {
            guard let out = leastUsed(shown, urgent: urgent, now: now), let seat = shown.firstIndex(of: out) else { break }
            shown[seat] = id
        }
        return (shown, ids.filter { !shown.contains($0) })
    }
}
