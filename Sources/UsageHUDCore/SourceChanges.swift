import Foundation

/// A receipt from a successful reader, never inferred from which apps are installed.
public enum ReadingSource: String, Codable {
    case claudeStatusline = "claude-statusline"
    case claudeOAuth = "claude-oauth-usage"
    case codexCLI = "codex-cli"
    case antigravityLocal = "antigravity-local"
    case providerAPI = "provider-api"
    case grokCLI = "grok-cli-billing"
    case grokBotLocal = "grok-bot-local"
    case liteLLMProxy = "litellm-proxy"

    public func description(provider: String) -> String {
        switch self {
        case .claudeStatusline: return "Usage from Claude Code’s statusline"
        case .claudeOAuth: return "Usage read with Claude Code’s existing sign-in"
        case .codexCLI: return "Limits from Codex CLI"
        case .antigravityLocal: return "Quotas from Antigravity on this Mac"
        case .providerAPI: return provider == "OpenRouter" ? "Balance and key limits from OpenRouter’s API" : "Readings from \(provider)’s API"
        case .grokCLI: return "Billing read with Grok CLI’s existing sign-in"
        case .grokBotLocal: return "Usage from Grok Bot on this Mac"
        case .liteLLMProxy: return "Spend and budget from your LiteLLM proxy"
        }
    }
    func receipt(now: Double = Date().timeIntervalSince1970) -> JSON {
        ["reading_source": rawValue, "source_read_at": now]
    }
}

public struct SourceNotice {
    public let title: String
    public let lines: [String]
    public static let duration: TimeInterval = 6
    public init(title: String, lines: [String]) { self.title = title; self.lines = lines }
}

/// Tracks connections, rather than visibility: overflow, stale readings and outages are not removals.
/// Startup establishes a quiet baseline. A new connection needs a recent, usable reader receipt.
public struct SourceChanges {
    private var known: [String: String] = [:]
    public init() {}
    public mutating func update(panels: [Panel], gone: Set<String> = [], announce: Bool = true,
                                now: Double = Date().timeIntervalSince1970) -> SourceNotice? {
        if !announce {
            for panel in panels where (panel.windows + panel.cells).contains(where: { $0.pct != nil || $0.right != nil }) {
                known[panel.id] = panel.name
            }
            for id in gone { known[id] = nil }
            return nil
        }
        let removed = gone.sorted().compactMap { id -> String? in
            guard let name = known.removeValue(forKey: id) else { return nil }
            return name
        }
        var added: [(String, ReadingSource)] = []
        for panel in panels.sorted(by: { $0.id < $1.id }) where !gone.contains(panel.id) {
            guard let source = panel.readingSource, let readAt = panel.sourceReadAt,
                  now - readAt >= -30, now - readAt < 600,
                  (panel.windows + panel.cells).contains(where: { !$0.isCached && ($0.pct != nil || $0.right != nil) }) else { continue }
            if known[panel.id] == nil { added.append((panel.name, source)) }
            known[panel.id] = panel.name
        }
        guard !added.isEmpty || !removed.isEmpty else { return nil }
        func names(_ values: [String]) -> String { values.joined(separator: ", ") }
        let title: String
        if removed.isEmpty { title = added.count == 1 ? "Tracking " + added[0].0 : "Tracking \(added.count) new sources" }
        else if added.isEmpty { title = removed.count == 1 ? "Stopped tracking " + removed[0] : "Stopped tracking \(removed.count) sources" }
        else { title = "Sources updated" }
        var lines = added.map { name, source in
            (added.count == 1 && removed.isEmpty ? "" : name + " · ") + source.description(provider: name)
        }
        if !removed.isEmpty {
            lines.append(added.isEmpty && removed.count == 1 ? "Usage HUD will check again automatically." : "No longer tracking: " + names(removed))
        }
        return SourceNotice(title: title, lines: lines)
    }
}
