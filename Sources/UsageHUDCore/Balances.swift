import Foundation

/// A prepaid API balance shown in money, like OpenRouter. The key is one already on this Mac (an environment variable,
/// a shell profile, or Claude Code pointed at the provider), or one in the Keychain under `service` with the API host
/// as the account, so regional endpoints share one adapter.
final class BalanceProvider: UsageProvider {
    let id: String, name: String, automatic = true
    let service: String, hosts: [String], path: String, variables: [String]
    /// Returns the amount left and its currency symbol for one response from `host`.
    let parse: (JSON, String) throws -> (Double, String)
    let cache: Cache, credentials: CredentialReading, http: HTTPReading
    let home: URL, environment: [String: String]
    var found: (at: Double, keys: [String: String]) = (0, [:])
    init(id: String, name: String, hosts: [String], path: String, variables: [String], cache: Cache, credentials: CredentialReading, http: HTTPReading,
         home: URL = FileManager.default.homeDirectoryForCurrentUser, environment: [String: String] = ProcessInfo.processInfo.environment,
         parse: @escaping (JSON, String) throws -> (Double, String)) {
        self.id = id; self.name = name; service = "Usage HUD " + name; self.hosts = hosts; self.path = path; self.variables = variables
        self.cache = cache; self.credentials = credentials; self.http = http; self.home = home; self.environment = environment; self.parse = parse
    }
    /// Keys already on this Mac, by host. The search runs at most hourly; keys stay in memory only.
    func discovered() -> [String: String] {
        let now = Date().timeIntervalSince1970
        guard now - found.at > 3600 else { return found.keys }
        var keys = KeyFinder.claudeCode(hosts: hosts, home: home, environment: environment)
        if let key = KeyFinder.assigned(variables, in: KeyFinder.places(home: home), environment: environment) {
            for host in hosts where keys[host] == nil { keys[host] = key }
        }
        found = (now, keys)
        return keys
    }
    func shown() -> Bool { FileManager.default.fileExists(atPath: cache.root.appendingPathComponent(id + ".json").path) }
    func refresh() throws {
        var lastProblem = HUDProblem("No \(name) API key found on this Mac; see PROVIDERS.md")
        for host in hosts {
            let stored = try credentials.stored(service: service, account: host)
            guard let key = stored ?? discovered()[host] else { continue }
            let data: JSON
            do {
                data = try http.get(URL(string: "https://" + host + path)!, token: key, headers: [:], limit: 1024 * 1024)
            } catch let error as HTTPFailure {
                // A key someone stored and that stopped working needs them; an old one left in a profile doesn't.
                lastProblem = error.status == 401 || error.status == 403 ? HUDProblem("\(name) API key rejected", attention: stored != nil) : HUDProblem("\(name) balance HTTP \(error.status)")
                continue
            }
            let (amount, symbol) = try parse(data, host)
            try cache.write(id + ".json", ["balance": amount, "symbol": symbol, "host": host, "captured_at": Date().timeIntervalSince1970])
            return
        }
        throw lastProblem
    }
    func panel() -> Panel {
        let blob = cache.read(id + ".json")
        guard let balance = number(blob["balance"]) else { return Panel(id: id, name: name, note: "Refresh \(name) to read balance") }
        let symbol = blob["symbol"] as? String ?? "$"
        let old = Date().timeIntervalSince1970 - (number(blob["captured_at"]) ?? 0) > 21600
        return Panel(id: id, name: name, windows: [Window(label: name, right: symbol + String(format: "%.2f", balance) + " left", stale: old)])
    }

    static func vercel(cache: Cache, credentials: CredentialReading, http: HTTPReading, home: URL = FileManager.default.homeDirectoryForCurrentUser,
                     environment: [String: String] = ProcessInfo.processInfo.environment) -> BalanceProvider {
        BalanceProvider(id: "vercel", name: "Vercel", hosts: ["ai-gateway.vercel.sh"], path: "/v1/credits", variables: ["AI_GATEWAY_API_KEY"],
                        cache: cache, credentials: credentials, http: http, home: home, environment: environment, parse: vercelBalance)
    }
    static func deepSeek(cache: Cache, credentials: CredentialReading, http: HTTPReading, home: URL = FileManager.default.homeDirectoryForCurrentUser,
                         environment: [String: String] = ProcessInfo.processInfo.environment) -> BalanceProvider {
        BalanceProvider(id: "deepseek", name: "DeepSeek", hosts: ["api.deepseek.com"], path: "/user/balance", variables: ["DEEPSEEK_API_KEY"],
                        cache: cache, credentials: credentials, http: http, home: home, environment: environment, parse: deepSeekBalance)
    }
    static func kimi(cache: Cache, credentials: CredentialReading, http: HTTPReading, home: URL = FileManager.default.homeDirectoryForCurrentUser,
                       environment: [String: String] = ProcessInfo.processInfo.environment) -> BalanceProvider {
        BalanceProvider(id: "kimi", name: "Kimi", hosts: ["api.moonshot.ai", "api.moonshot.cn"], path: "/v1/users/me/balance", variables: ["MOONSHOT_API_KEY", "KIMI_API_KEY"],
                        cache: cache, credentials: credentials, http: http, home: home, environment: environment, parse: kimiBalance)
    }
    /// `balance` is a USD decimal string.
    static func vercelBalance(_ data: JSON, _ host: String) throws -> (Double, String) {
        guard let balance = number(data["balance"]) else { throw HUDProblem("Vercel response missing balance") }
        return (balance, "$")
    }
    /// One entry per currency; USD is preferred when the account holds both.
    static func deepSeekBalance(_ data: JSON, _ host: String) throws -> (Double, String) {
        let infos = data["balance_infos"] as? [JSON] ?? []
        guard let info = infos.first(where: { $0["currency"] as? String == "USD" }) ?? infos.first,
              let total = number(info["total_balance"]) else { throw HUDProblem("DeepSeek response missing balance") }
        return (total, info["currency"] as? String == "CNY" ? "¥" : "$")
    }
    /// The global endpoint reports USD and the mainland endpoint CNY.
    static func kimiBalance(_ data: JSON, _ host: String) throws -> (Double, String) {
        guard let balance = number(dict(data["data"])["available_balance"]) else { throw HUDProblem("Kimi response missing balance") }
        return (balance, host.hasSuffix(".cn") ? "¥" : "$")
    }
}
