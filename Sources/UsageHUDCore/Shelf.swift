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
    public init(levels: [String: Double] = [:], lastUsed: [String: Double] = [:], scores: [String: Double] = [:], scoredAt: Double = 0, pins: [String] = []) {
        self.levels = levels; self.lastUsed = lastUsed; self.scores = scores; self.scoredAt = scoredAt; self.pins = pins
    }
    /// Keeps `id` in the bar as the latest choice.
    public mutating func pin(_ id: String) { pins.removeAll { $0 == id }; pins.append(id) }
    /// Pins `id`, or lets it go if it was already pinned.
    public mutating func togglePin(_ id: String) {
        if let index = pins.firstIndex(of: id) { pins.remove(at: index) } else { pins.append(id) }
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
    public func ranked(_ ids: [String], urgent: Set<String> = []) -> [String] {
        let key = { (id: String) in (urgent.contains(id) ? 1 : 0, (self.pins.lastIndex(of: id)).map { $0 + 1 } ?? 0, self.scores[id] ?? 0, self.lastUsed[id] ?? 0) }
        return ids.enumerated().sorted { key($0.element) != key($1.element) ? key($0.element) > key($1.element) : $0.offset < $1.offset }.map { $0.element }
    }
    /// Splits `ids` into those shown and those moved to the overflow item, both in their original order.
    public func arrange(_ ids: [String], limit: Int, urgent: Set<String> = []) -> (shown: [String], hidden: [String]) {
        let shown = Set(ranked(ids, urgent: urgent).prefix(max(0, limit)))
        return (ids.filter { shown.contains($0) }, ids.filter { !shown.contains($0) })
    }
}
