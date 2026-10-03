import Foundation

/// Z.ai / Zhipu GLM Coding Plan. The API key lives in the Keychain under `GLMProvider.service`,
/// with the API host as the account, so the international and mainland endpoints both work.
final class GLMProvider: UsageProvider {
    let id = "glm", name = "GLM", automatic = true
    static let service = "Usage HUD GLM"
    static let hosts = ["api.z.ai", "open.bigmodel.cn"]
    let cache: Cache, credentials: CredentialReading, http: HTTPReading
    init(cache: Cache, credentials: CredentialReading, http: HTTPReading) {
        self.cache = cache; self.credentials = credentials; self.http = http
    }
    func shown() -> Bool { FileManager.default.fileExists(atPath: cache.root.appendingPathComponent("glm.json").path) }
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
            let minutes: Double? = unit == 3 ? count * 60 : unit == 6 ? count * 10080 : type == "TOKENS_LIMIT" ? 300 : nil
            guard let minutes = minutes else { continue }
            windows["w\(Int(minutes))"] = ["used_percentage": pct, "window_minutes": minutes,
                                           "resets_at": number(limit["nextResetTime"]).map { $0 / 1000 } as Any? ?? NSNull()]
        }
        guard !windows.isEmpty else { throw HUDProblem("GLM returned no quota windows") }
        return windows
    }
    func refresh() throws {
        var lastProblem = HUDProblem("Add a GLM Coding Plan API key to the Keychain; see PROVIDERS.md")
        for host in Self.hosts {
            guard let key = try? credentials.password(service: Self.service, account: host) else { continue }
            let data: JSON
            do {
                // Z.ai expects the raw key, without a Bearer prefix.
                data = try http.get(URL(string: "https://\(host)/api/monitor/usage/quota/limit")!, token: key,
                                    headers: ["Authorization": key, "Accept-Language": "en-US,en"], limit: 1024 * 1024)
            } catch let error as HTTPFailure {
                lastProblem = error.status == 401 || error.status == 403 ? HUDProblem("GLM API key rejected", attention: true) : HUDProblem("GLM usage HTTP \(error.status)")
                continue
            }
            try cache.quota("glm.json", windows: Self.windows(data), extra: ["host": host, "plan": dict(data["data"])["level"] ?? NSNull()])
            return
        }
        throw lastProblem
    }
    func panel() -> Panel {
        let blob = cache.read("glm.json"), rows = quotaWindows(blob)
        return Panel(id: id, name: name, windows: rows, note: (blob["plan"] as? String).map { "Plan: " + $0 } ?? (rows.isEmpty ? "Refresh GLM to read quota" : ""))
    }
}

/// Gemini CLI signed in with a Google account. Reads the CLI's own OAuth file and never renews or rewrites it.
final class GeminiProvider: UsageProvider {
    let id = "gemini", name = "Gemini", automatic = true
    static let base = "https://cloudcode-pa.googleapis.com/v1internal"
    let cache: Cache, http: HTTPReading
    let credentialFile: URL
    init(cache: Cache, http: HTTPReading, credentialFile: URL? = nil) {
        self.cache = cache; self.http = http
        self.credentialFile = credentialFile ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".gemini/oauth_creds.json")
    }
    func shown() -> Bool { FileManager.default.fileExists(atPath: cache.root.appendingPathComponent("gemini.json").path) }
    static func accessToken(_ data: Data, now: Double = Date().timeIntervalSince1970) throws -> String {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? JSON else { throw HUDProblem("Gemini credential unreadable") }
        guard let token = object["access_token"] as? String, !token.isEmpty else { throw HUDProblem("Gemini token missing; run gemini and sign in with Google") }
        if let expiry = number(object["expiry_date"]), expiry / 1000 < now { throw HUDProblem("Gemini sign-in expired; run gemini once to renew it") }
        return token
    }
    static func family(_ model: String) -> String {
        let lower = model.lowercased()
        if lower.contains("flash") && lower.contains("lite") { return "flash_lite" }
        if lower.contains("pro") { return "pro" }
        if lower.contains("flash") { return "flash" }
        return lower
    }
    /// Models in one family share a pool, so each family keeps its lowest remaining fraction and earliest reset.
    static func windows(_ response: JSON) throws -> JSON {
        var windows: JSON = [:]
        for bucket in response["buckets"] as? [JSON] ?? [] {
            guard let model = bucket["modelId"] as? String, let remaining = number(bucket["remainingFraction"]) else { continue }
            let key = family(model), old = dict(windows[key])
            let used = (1 - max(0, min(1, remaining))) * 100
            let reset = resetTime(bucket["resetTime"]), oldReset = number(old["resets_at"])
            windows[key] = ["used_percentage": max(used, number(old["used_percentage"]) ?? 0),
                            "resets_at": [reset, oldReset].compactMap { $0 }.min() as Any? ?? NSNull()]
        }
        guard !windows.isEmpty else { throw HUDProblem("Gemini returned no quota buckets") }
        return windows
    }
    func refresh() throws {
        guard let data = try? Data(contentsOf: credentialFile) else { throw HUDProblem("Install Gemini CLI and sign in with Google") }
        let token = try Self.accessToken(data)
        do {
            let tier = try http.post(URL(string: Self.base + ":loadCodeAssist")!, token: token, headers: [:], body: ["metadata":
                ["ideType": "IDE_UNSPECIFIED", "platform": "PLATFORM_UNSPECIFIED", "pluginType": "GEMINI"]], limit: 1024 * 1024)
            let project = tier["cloudaicompanionProject"] as? String ?? dict(tier["cloudaicompanionProject"])["id"] as? String
            let quota = try http.post(URL(string: Self.base + ":retrieveUserQuota")!, token: token, headers: [:],
                                      body: project.map { ["project": $0] } ?? [:], limit: 1024 * 1024)
            let plan = dict(tier["paidTier"])["name"] ?? dict(tier["currentTier"])["name"] ?? NSNull()
            try cache.quota("gemini.json", windows: Self.windows(quota), extra: ["plan": plan])
        } catch let error as HTTPFailure {
            if error.status == 401 || error.status == 403 { throw HUDProblem("Gemini sign-in expired; run gemini once to renew it") }
            throw HUDProblem("Gemini usage HTTP \(error.status)")
        }
    }
    func panel() -> Panel {
        let blob = cache.read("gemini.json")
        // The most used family leads, so the battery shows the tightest pool.
        let rows = quotaWindows(blob).sorted { ($0.pct ?? 0) > ($1.pct ?? 0) }
        return Panel(id: id, name: name, windows: rows, note: (blob["plan"] as? String).map { "Plan: " + $0 } ?? (rows.isEmpty ? "Refresh Gemini to read quota" : ""))
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
        let home = FileManager.default.homeDirectoryForCurrentUser
        let environment = ProcessInfo.processInfo.environment
        let candidates = [environment["USAGE_HUD_GROK_CLI"]].compactMap { $0 } +
            [home.appendingPathComponent(".local/bin/grok").path, "/opt/homebrew/bin/grok", "/usr/local/bin/grok"] +
            (environment["PATH"] ?? "").split(separator: ":").map { String($0) + "/grok" }
        guard let path = candidates.first(where: { $0.hasPrefix("/") && FileManager.default.isExecutableFile(atPath: $0) }) else {
            throw HUDProblem("Install Grok CLI and sign in with grok login")
        }
        let rpc = try RPCProcess(binary: URL(fileURLWithPath: path), arguments: ["agent", "stdio"], environment: environment)
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
