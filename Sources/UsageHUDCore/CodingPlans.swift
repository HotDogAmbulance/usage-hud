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
    /// Z.ai's setup points Claude Code at its Anthropic-compatible endpoint, so that key is the plan's key, keyed by our API host.
    /// The key only ever goes to our fixed host, never to the URL found beside it.
    static func found(home: URL, environment: [String: String]) -> [String: String] {
        let settings = (try? Data(contentsOf: home.appendingPathComponent(".claude/settings.json"))).flatMap { try? JSONSerialization.jsonObject(with: $0) }
        var keys: [String: String] = [:]
        for source in [environment, dict(dict(settings)["env"]).compactMapValues { $0 as? String }] {
            guard let base = URL(string: source["ANTHROPIC_BASE_URL"] ?? "")?.host?.lowercased(),
                  let key = source["ANTHROPIC_AUTH_TOKEN"] ?? source["ANTHROPIC_API_KEY"], !key.isEmpty,
                  let host = hosts.first(where: { let domain = $0.split(separator: ".").suffix(2).joined(separator: ".")
                                                  return base == domain || base.hasSuffix("." + domain) }) else { continue }
            keys[host] = keys[host] ?? key
        }
        return keys
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
        var lastProblem = HUDProblem("Set up GLM in Claude Code, or add its API key to the Keychain; see PROVIDERS.md")
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

/// Grok CLI. Reads monthly billing through the CLI's own `agent stdio` JSON-RPC, using its existing login.
final class GrokProvider: UsageProvider {
    let id = "grok", name = "Grok", automatic = true
    let cache: Cache
    init(cache: Cache) { self.cache = cache }
    func shown() -> Bool { FileManager.default.fileExists(atPath: cache.root.appendingPathComponent("grok.json").path) }
    static func cents(_ value: Any?) -> Double? { number(dict(value)["val"]) }
    static func windows(_ billing: JSON) throws -> JSON {
        guard let limit = cents(billing["monthlyLimit"]), limit > 0 else { throw HUDProblem("Grok returned no monthly limit") }
        let used = cents(dict(billing["usage"])["totalUsed"]) ?? 0
        return ["month": ["used_percentage": used / limit * 100, "resets_at": resetTime(dict(billing["billingCycle"])["billingPeriodEnd"]) as Any? ?? NSNull()]]
    }
    func refresh() throws {
        guard let binary = CLI.find("grok", configured: ProcessInfo.processInfo.environment["USAGE_HUD_GROK_CLI"]) else {
            throw HUDProblem("Install Grok CLI and sign in with grok login")
        }
        let rpc = try RPCProcess(binary: binary, arguments: ["agent", "stdio"], environment: CLI.environment(for: binary))
        defer { rpc.stop() }
        rpc.errorMessage = "Grok billing unavailable; check grok login"
        let capabilities: JSON = ["fs": ["readTextFile": false, "writeTextFile": false], "terminal": false]
        let initialize: JSON = ["protocolVersion": "1", "clientCapabilities": capabilities]
        try rpc.send(["jsonrpc": "2.0", "id": 1, "method": "initialize", "params": initialize])
        _ = try rpc.receive(1)
        try rpc.send(["jsonrpc": "2.0", "id": 2, "method": "x.ai/billing", "params": JSON()])
        let billing = try rpc.receive(2)
        try cache.quota("grok.json", windows: Self.windows(billing), extra: [
            "spent_cents": Self.cents(dict(billing["usage"])["totalUsed"]) as Any? ?? NSNull(),
            "limit_cents": Self.cents(billing["monthlyLimit"]) as Any? ?? NSNull()])
    }
    func panel() -> Panel {
        let blob = cache.read("grok.json")
        var rows = quotaWindows(blob)
        if let spent = number(blob["spent_cents"]), let limit = number(blob["limit_cents"]) {
            rows.append(Window(label: "spent", right: "\(usd(spent / 100)) of \(usd(limit / 100)) this month",
                               stale: Date().timeIntervalSince1970 - (number(blob["captured_at"]) ?? 0) > 600))
        }
        return Panel(id: id, name: name, windows: rows, note: rows.isEmpty ? "Refresh Grok to read quota" : "")
    }
}
