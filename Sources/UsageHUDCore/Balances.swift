import Foundation

/// A prepaid API balance shown in money, like OpenRouter. The API key lives in the Keychain under
/// `service`, with the API host as the account, so regional endpoints share one adapter.
final class BalanceProvider: UsageProvider {
    let id: String, name: String, automatic = true
    let service: String, hosts: [String], path: String
    /// Returns the amount left and its currency symbol for one response from `host`.
    let parse: (JSON, String) throws -> (Double, String)
    let cache: Cache, credentials: CredentialReading, http: HTTPReading
    init(id: String, name: String, hosts: [String], path: String, cache: Cache, credentials: CredentialReading, http: HTTPReading,
         parse: @escaping (JSON, String) throws -> (Double, String)) {
        self.id = id; self.name = name; service = "Usage HUD " + name; self.hosts = hosts; self.path = path
        self.cache = cache; self.credentials = credentials; self.http = http; self.parse = parse
    }
    func shown() -> Bool { FileManager.default.fileExists(atPath: cache.root.appendingPathComponent(id + ".json").path) }
    func refresh() throws {
        var lastProblem = HUDProblem("Add a \(name) API key to the Keychain; see PROVIDERS.md")
        for host in hosts {
            guard let key = try? credentials.password(service: service, account: host) else { continue }
            let data: JSON
            do {
                data = try http.get(URL(string: "https://" + host + path)!, token: key, headers: [:], limit: 1024 * 1024)
            } catch let error as HTTPFailure {
                lastProblem = HUDProblem(error.status == 401 || error.status == 403 ? "\(name) API key rejected" : "\(name) balance HTTP \(error.status)")
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

    static func vercel(cache: Cache, credentials: CredentialReading, http: HTTPReading) -> BalanceProvider {
        BalanceProvider(id: "vercel", name: "Vercel", hosts: ["ai-gateway.vercel.sh"], path: "/v1/credits",
                        cache: cache, credentials: credentials, http: http, parse: vercelBalance)
    }
    static func deepSeek(cache: Cache, credentials: CredentialReading, http: HTTPReading) -> BalanceProvider {
        BalanceProvider(id: "deepseek", name: "DeepSeek", hosts: ["api.deepseek.com"], path: "/user/balance",
                        cache: cache, credentials: credentials, http: http, parse: deepSeekBalance)
    }
    static func kimi(cache: Cache, credentials: CredentialReading, http: HTTPReading) -> BalanceProvider {
        BalanceProvider(id: "kimi", name: "Kimi", hosts: ["api.moonshot.ai", "api.moonshot.cn"], path: "/v1/users/me/balance",
                        cache: cache, credentials: credentials, http: http, parse: kimiBalance)
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
