import Foundation

/// Decides which batteries stay in the menu bar. A provider counts as used when its quota rises or its balance falls,
/// so the most recently used ones stay visible and the rest move into one overflow item.
public struct Shelf {
    public var levels: [String: Double]
    public var lastUsed: [String: Double]
    public init(levels: [String: Double] = [:], lastUsed: [String: Double] = [:]) {
        self.levels = levels; self.lastUsed = lastUsed
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
        if let old = levels[panel.id], level > old + 0.001 { lastUsed[panel.id] = now }
        levels[panel.id] = level
    }
    /// Splits `ids` into those shown and those moved to the overflow item, both in their original order.
    /// Batteries asking for attention come first, then the most recently used; providers never seen in use keep the engine's order.
    public func arrange(_ ids: [String], limit: Int, urgent: Set<String> = []) -> (shown: [String], hidden: [String]) {
        guard ids.count > limit else { return (ids, []) }
        let ranked = ids.enumerated().sorted { a, b in
            let x = urgent.contains(a.element) ? Double.infinity : lastUsed[a.element] ?? 0
            let y = urgent.contains(b.element) ? Double.infinity : lastUsed[b.element] ?? 0
            return x != y ? x > y : a.offset < b.offset
        }
        let shown = Set(ranked.prefix(max(0, limit)).map { $0.element })
        return (ids.filter { shown.contains($0) }, ids.filter { !shown.contains($0) })
    }
}
