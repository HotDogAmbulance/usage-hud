import Foundation

/// Z.ai / Zhipu GLM Coding Plan. The key is the one Claude Code already uses for Z.ai, or one stored in the Keychain
/// under `GLMProvider.service` with the API host as the account, so the international and mainland endpoints both work.
final class GLMProvider: UsageProvider {
    let id = "glm", name = "GLM", automatic = true
    static let service = "Usage HUD GLM"
    static let hosts = ["api.z.ai", "open.bigmodel.cn"]
    let cache: Cache, credentials: CredentialReading, http: HTTPReading
    let home: URL, environment: [String: String]
    init(cache: Cache, credentials: CredentialReading, http: HTTPReading,
         home: URL = FileManager.default.homeDirectoryForCurrentUser, environment: [String: String] = ProcessInfo.processInfo.environment) {
        self.cache = cache; self.credentials = credentials; self.http = http; self.home = home; self.environment = environment
    }
    func shown() -> Bool { FileManager.default.fileExists(atPath: cache.root.appendingPathComponent("glm.json").path) }
    /// Z.ai's setup points Claude Code at its Anthropic-compatible endpoint, so that key is the plan's key.
    static func found(home: URL, environment: [String: String]) -> [String: String] {
        KeyFinder.claudeCode(hosts: hosts, home: home, environment: environment)
    }
    static func windows(_ response: JSON) throws -> JSON {
        if response["success"] as? Bool == false { throw HUDProblem("GLM quota unavailable: " + (response["msg"] as? String ?? "unknown error")) }
        let limits = dict(response["data"])["limits"] as? [JSON] ?? []
        var windows: JSON = [:]
        for limit in limits {
            // TIME_LIMIT is the monthly MCP tool allowance, not model quota.
            guard let type = limit["type"] as? String, type == "TOKENS_LIMIT" || type == "CREDIT_LIMIT",
                  let pct = number(limit["percentage"]) else { continue }
            let unit = number(limit["unit"]), count = number(limit["number"]) ?? 1
            // Observed unit codes: 3 = hours, 6 = weeks. Older TOKENS_LIMIT entries describe the 5h window.
            // Any other unit is a window we don't know yet, never a 5h one in disguise.
            let minutes: Double? = unit == 3 ? count * 60 : unit == 6 ? count * 10080 : type == "TOKENS_LIMIT" && (unit == nil || unit == 5) ? 300 : nil
            guard let minutes = minutes else { continue }
            windows["w\(Int(minutes))"] = ["used_percentage": pct, "window_minutes": minutes,
                                           "resets_at": number(limit["nextResetTime"]).map { $0 / 1000 } as Any? ?? NSNull()]
        }
        guard !windows.isEmpty else { throw HUDProblem("GLM returned no quota windows") }
        return windows
    }
    func refresh() throws {
        var lastProblem = HUDProblem("Set up GLM in Claude Code, or add its API key to the Keychain; see PROVIDERS.md", gone: true)
        let found = Self.found(home: home, environment: environment)
        for host in Self.hosts {
            guard let key = try credentials.stored(service: Self.service, account: host) ?? found[host] else { continue }
            let data: JSON
            do {
                // Z.ai expects the raw key, without a Bearer prefix.
                data = try http.get(URL(string: "https://\(host)/api/monitor/usage/quota/limit")!, token: key,
                                    headers: ["Authorization": key, "Accept-Language": "en-US,en"], limit: 1024 * 1024)
            } catch let error as HTTPFailure {
                lastProblem = error.status == 401 || error.status == 403 ? HUDProblem("GLM API key rejected", attention: true) : HUDProblem("GLM usage HTTP \(error.status)")
                continue
            }
            // One host refusing the key (success: false) still leaves the other to try.
            do { try cache.quota("glm.json", windows: Self.windows(data), extra: ["host": host, "plan": dict(data["data"])["level"] ?? NSNull()]) }
            catch let problem as HUDProblem { lastProblem = problem; continue }
            return
        }
        throw lastProblem
    }
    func panel() -> Panel {
        let blob = cache.read("glm.json"), rows = quotaWindows(blob)
        return Panel(id: id, name: name, windows: rows, note: (blob["plan"] as? String).map { "Plan: " + $0 } ?? (rows.isEmpty ? "Refresh GLM to read quota" : ""))
    }
}

/// Grok CLI. Reads the plan's credit usage from the CLI's own billing endpoint, with the sign-in `grok login` saved in
/// `~/.grok/auth.json`. The CLI renews that sign-in whenever it runs; the HUD only reads it and keeps it in memory.
/// (The CLI's `x.ai/billing` RPC answers "method not found" in current versions, so it isn't used.)
final class GrokProvider: UsageProvider {
    let id = "grok", name = "Grok", automatic = true
    let cache: Cache, http: HTTPReading, home: URL, environment: [String: String]
    init(cache: Cache, http: HTTPReading, home: URL = FileManager.default.homeDirectoryForCurrentUser,
         environment: [String: String] = ProcessInfo.processInfo.environment) {
        self.cache = cache; self.http = http; self.home = home; self.environment = environment
    }
    func shown() -> Bool { FileManager.default.fileExists(atPath: cache.root.appendingPathComponent("grok.json").path) }
    /// The xAI sign-in first, then the older one; `expired` once past its `expires_at` (none means it doesn't say).
    static func token(_ auth: JSON, now: Double = Date().timeIntervalSince1970) -> (key: String, expired: Bool)? {
        let names = auth.keys.sorted()
        for name in names.filter({ $0.hasPrefix("https://auth.x.ai::") }) + names.filter({ $0.contains("/sign-in") }) {
            let entry = dict(auth[name])
            guard let key = entry["key"] as? String, !key.isEmpty else { continue }
            return (key, resetTime(entry["expires_at"]).map { $0 <= now } ?? false)
        }
        return nil
    }
    /// `creditUsagePercent` over the current period (weekly on current plans), or on-demand spend against its cap.
    static func windows(_ billing: JSON) throws -> JSON {
        let config = dict(billing["config"]), period = dict(config["currentPeriod"])
        let cap = number(dict(config["onDemandCap"])["val"]) ?? 0
        guard let pct = number(config["creditUsagePercent"]) ?? (cap > 0 ? number(dict(config["onDemandUsed"])["val"]).map { $0 / cap * 100 } : nil) else {
            throw HUDProblem("Grok returned no credit usage")
        }
        let weekly = (period["type"] as? String)?.contains("WEEK") == true
        return [weekly ? "w10080" : "month": ["used_percentage": pct, "window_minutes": weekly ? 10080 as Any : NSNull() as Any,
                                              "resets_at": resetTime(period["end"] ?? config["billingPeriodEnd"]) as Any? ?? NSNull()]]
    }
    /// "SUPERGROK_HEAVY" reads "SuperGrok Heavy".
    static func plan(_ billing: JSON) -> String? {
        guard let tier = (dict(billing["config"])["subscriptionTier"] ?? billing["subscriptionTier"]) as? String, !tier.isEmpty else { return nil }
        return tier.replacingOccurrences(of: "_", with: " ").lowercased().capitalized.replacingOccurrences(of: "Supergrok", with: "SuperGrok")
    }
    func refresh() throws {
        let folder = environment["GROK_HOME"].map { URL(fileURLWithPath: $0) } ?? home.appendingPathComponent(".grok")
        guard let data = try? Data(contentsOf: folder.appendingPathComponent("auth.json")),
              let token = Self.token(dict(try? JSONSerialization.jsonObject(with: data))) else {
            throw HUDProblem("Install Grok CLI and sign in with grok login", gone: true)
        }
        // An old sign-in only means the CLI sat idle; it renews it the next time it runs.
        let idle = HUDProblem("Updates when you next use Grok CLI")
        guard !token.expired else { throw idle }
        let billing: JSON
        do {
            billing = try http.get(URL(string: "https://cli-chat-proxy.grok.com/v1/billing?format=credits")!, token: token.key,
                                   headers: ["x-xai-token-auth": "xai-grok-cli"], limit: 1024 * 1024)
        } catch let error as HTTPFailure where error.status == 401 || error.status == 403 { throw idle }
        try cache.quota("grok.json", windows: Self.windows(billing), extra: ["plan": Self.plan(billing) as Any? ?? NSNull()])
    }
    func panel() -> Panel {
        let blob = cache.read("grok.json"), rows = quotaWindows(blob)
        return Panel(id: id, name: name, windows: rows, note: (blob["plan"] as? String).map { "Plan: " + $0 } ?? (rows.isEmpty ? "Refresh Grok to read quota" : ""))
    }
}
