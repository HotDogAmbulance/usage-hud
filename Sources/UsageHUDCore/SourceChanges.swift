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
    /// The last settled state of every key under each battery. "unreachable" is a hiccup and never replaces it.
    private var keyStates: [String: [String: String]] = [:]
    private var lastNames: [String: [String: String]] = [:]
    public init() {}
    public mutating func update(panels: [Panel], gone: Set<String> = [], announce: Bool = true,
                                now: Double = Date().timeIntervalSince1970) -> SourceNotice? {
        if !announce {
            for panel in panels { remember(panel) }
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
        // Keys changing inside a battery already on the bar; a battery's first appearance is announced as a whole.
        var keyEvents: [(title: String, line: String)] = []
        for panel in panels.sorted(by: { $0.id < $1.id }) where known[panel.id] != nil && !gone.contains(panel.id) {
            keyEvents += keyChanges(panel)
        }
        var added: [(String, ReadingSource)] = []
        for panel in panels.sorted(by: { $0.id < $1.id }) where !gone.contains(panel.id) {
            guard let source = panel.readingSource, let readAt = panel.sourceReadAt,
                  now - readAt >= -30, now - readAt < 600,
                  (panel.windows + panel.cells).contains(where: { !$0.isCached && ($0.pct != nil || $0.right != nil) }) else { continue }
            if known[panel.id] == nil { added.append((panel.name, source)) }
            known[panel.id] = panel.name
        }
        for panel in panels { remember(panel) }
        guard !added.isEmpty || !removed.isEmpty else {
            guard !keyEvents.isEmpty else { return nil }
            return SourceNotice(title: keyEvents.count == 1 ? keyEvents[0].title : "Keys updated", lines: keyEvents.map { $0.line })
        }
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
        return SourceNotice(title: title, lines: lines + keyEvents.map { $0.line })
    }
    private mutating func remember(_ panel: Panel) {
        guard let keys = panel.keys else { return }
        var settled = keyStates[panel.id] ?? [:]
        for (label, state) in keys where state != "unreachable" { settled[label] = state }
        for label in settled.keys where keys[label] == nil { settled[label] = nil }
        keyStates[panel.id] = settled
        lastNames[panel.id] = panel.keyNames ?? [:]
    }
    private func keyChanges(_ panel: Panel) -> [(title: String, line: String)] {
        guard let keys = panel.keys else { return [] }
        let before = keyStates[panel.id] ?? [:], names = panel.keyNames ?? [:]
        func name(_ id: String) -> String { names[id] ?? id }
        var events: [(title: String, line: String)] = []
        for (id, state) in keys.sorted(by: { name($0.key) < name($1.key) }) where state != "unreachable" && before[id] != state {
            let label = name(id)
            switch state {
            case "ok": events.append(("Tracking " + label, label + " · added to " + panel.name + (before[id] == nil ? "" : " again")))
            case "removed": events.append(("Stopped tracking " + label, label + " · its key is no longer in Keychain"))
            case "invalid": events.append((label + "’s key was refused", panel.name + " says the key is no longer valid"))
            case "zen": events.append((label + " uses free Zen models",
                                       label + " · OpenCode Zen free models need no key. Zen publishes no usage, so Usage HUD can’t measure it; on a limit error, wait or switch free model."))
            default: break
            }
        }
        for id in before.keys.sorted() where keys[id] == nil && before[id] != "removed" && before[id] != "invalid" {
            events.append(("Stopped tracking " + (lastNames[panel.id]?[id] ?? id), (lastNames[panel.id]?[id] ?? id) + " · no longer in " + panel.name))
        }
        return events
    }
}
