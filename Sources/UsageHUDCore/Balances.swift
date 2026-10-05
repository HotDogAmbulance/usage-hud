import Foundation

/// A provider read with an API key: a prepaid balance shown in money like OpenRouter, a plan's quota windows, or spend
/// against a limit. The key is one already on this Mac (an environment variable, a shell profile, a tool's config, or
/// Claude Code pointed at the provider), or one in the Keychain under `service` with the API host as the account, so
/// regional endpoints share one adapter. Every key goes only to the host it was found for and stays in memory.
final class KeyProvider: UsageProvider {
    /// One provider host and the key found for it. `base` is "https://host", or the address a self-hosted proxy was found at.
    struct Call {
        let host: String, key: String, http: HTTPReading
        var base: String { host.contains("://") ? host : "https://" + host }
        func get(_ path: String, _ headers: [String: String] = [:]) throws -> JSON {
            guard let url = URL(string: base + path) else { throw HUDProblem("Invalid address for \(host)") }
            return try http.get(url, token: key, headers: headers, limit: 1024 * 1024)
        }
    }
    let id: String, name: String, automatic = true
    let service: String, hosts: [String], variables: [String]
    /// Keys a provider finds in places of its own (a CLI's config, a proxy's address), by host.
    let discover: (URL, [String: String]) -> [String: String]
    /// What to keep from one host: `balance` and `symbol` for money; `rate_limits` (and `plan`) for quota; `spent`,
    /// `limit` and `period` for spend against a limit.
    let read: (Call) throws -> JSON
    let cache: Cache, credentials: CredentialReading, http: HTTPReading
    let home: URL, environment: [String: String]
    var found: (at: Double, keys: [String: String]) = (0, [:])
    /// Addresses found beside a key that turned out not to be this provider (a company gateway that isn't LiteLLM),
    /// left alone until the app restarts.
    /// Gateways found by discovery that did not answer: skipped for an hour (forever when they answered "not LiteLLM").
    var notHere: [String: Date] = [:]
    init(id: String, name: String, hosts: [String], variables: [String], cache: Cache, credentials: CredentialReading, http: HTTPReading,
         home: URL = FileManager.default.homeDirectoryForCurrentUser, environment: [String: String] = ProcessInfo.processInfo.environment,
         discover: @escaping (URL, [String: String]) -> [String: String] = { _, _ in [:] }, read: @escaping (Call) throws -> JSON) {
        self.id = id; self.name = name; service = "Usage HUD " + name; self.hosts = hosts; self.variables = variables
        self.cache = cache; self.credentials = credentials; self.http = http; self.home = home; self.environment = environment
        self.discover = discover; self.read = read
    }
    /// Keys already on this Mac, by host. The search runs at most hourly; keys stay in memory only.
    func discovered() -> [String: String] {
        let now = Date().timeIntervalSince1970
        guard now - found.at > 3600 else { return found.keys }
        var keys = KeyFinder.claudeCode(hosts: hosts, home: home, environment: environment)
        if !variables.isEmpty, let key = KeyFinder.assigned(variables, in: KeyFinder.places(home: home), environment: environment) {
            for host in hosts where keys[host] == nil { keys[host] = key }
        }
        keys.merge(discover(home, environment)) { mine, _ in mine }
        found = (now, keys)
        return keys
    }
    func shown() -> Bool { FileManager.default.fileExists(atPath: cache.root.appendingPathComponent(id + ".json").path) }
    func refresh() throws {
        var lastProblem = HUDProblem("No \(name) API key found on this Mac; see PROVIDERS.md", gone: true)
        let keys = discovered()
        for host in hosts + keys.keys.filter({ !hosts.contains($0) && notHere[$0].map { $0 < Date() } ?? true }).sorted() {
            let stored = try hosts.contains(host) ? credentials.stored(service: service, account: host) : nil
            guard let key = stored ?? keys[host] else { continue }
            let blob: JSON
            do { blob = try read(Call(host: host, key: key, http: http)) }
            catch let error as HTTPFailure {
                if !hosts.contains(host), [401, 403, 404, 405].contains(error.status) { notHere[host] = .distantFuture }
                // A key someone stored and that stopped working needs them; an old one left in a profile doesn't.
                lastProblem = error.status == 401 || error.status == 403 ? HUDProblem("\(name) API key rejected", attention: stored != nil) : HUDProblem("\(name) HTTP \(error.status)")
                continue
            } catch let error as HUDProblem where !hosts.contains(host) {
                // A gateway that is down or slow costs a 30 s wait; try it again in an hour, not at every refresh.
                notHere[host] = Date().addingTimeInterval(3600); lastProblem = error
                continue
            }
            let receipt = (id == "litellm" ? ReadingSource.liteLLMProxy : .providerAPI).receipt()
            let metadata = receipt.merging(["host": host]) { _, new in new }
            if let windows = blob["rate_limits"] as? JSON {
                try cache.quota(id + ".json", windows: windows, extra: blob.filter { $0.key != "rate_limits" }.merging(metadata) { _, new in new })
            } else {
                try cache.write(id + ".json", blob.merging(metadata.merging(["captured_at": Date().timeIntervalSince1970]) { _, new in new }) { _, new in new })
            }
            return
        }
        throw lastProblem
    }
    func panel() -> Panel {
        let blob = cache.read(id + ".json")
        let age = Date().timeIntervalSince1970 - (number(blob["captured_at"]) ?? 0)
        let old = age > 21600
        var rows = quotaWindows(blob)
        if let balance = number(blob["balance"]) {
            rows.insert(Window(label: name, right: money(balance, blob["symbol"] as? String ?? "$") + " left", stale: old), at: 0)
        }
        // Spend against a limit is its own row; spend with no limit is all there is to show, so the battery carries it.
        if let spent = number(blob["spent"]) {
            let period = (blob["period"] as? String).map { " · " + $0 } ?? ""
            if let limit = number(blob["limit"]) { rows.append(Window(label: "Spent", right: usd(spent) + " / " + usd(limit) + period, stale: age > 600)) }
            else { rows.insert(Window(label: name, right: usd(spent) + " spent" + period, stale: old), at: 0) }
        }
        let plan = (blob["plan"] as? String).map { "Plan: " + $0 }
        var panel = Panel(id: id, name: name, windows: rows, note: plan ?? (rows.isEmpty ? "Refresh \(name) to read usage" : ""))
        // Infrastructure providers with a spending limit also show it as a small battery on hover, like OpenRouter's keys.
        if ["xai", "fireworks", "litellm"].contains(id), let spent = number(blob["spent"]), let limit = number(blob["limit"]), limit >= 0 {
            let period = (blob["period"] as? String).map { $0.prefix(1).uppercased() + $0.dropFirst() } ?? "Budget"
            let budget = rows.first { $0.pct != nil }
            let reset = budget?.resets_at
            let resetText = reset.map { $0 > Date().timeIntervalSince1970 ? " · ↻ " + countdown($0 - Date().timeIntervalSince1970) : "" } ?? ""
            panel.cells = [Window(label: period, pct: limit > 0 ? min(100, spent / limit * 100) : 100, right: usd(spent) + " / " + usd(limit) + resetText,
                                  resets_at: reset, expired: budget?.expired, stale: old || budget?.stale == true)]
        }
        // Only usage the proxy explicitly returned is eligible; configured budgets without usage are not full batteries.
        for row in blob["budget_cells"] as? [JSON] ?? [] {
            guard let label = row["label"] as? String, let spent = number(row["spent"]), spent >= 0,
                  let limit = number(row["limit"]), limit >= 0 else { continue }
            let period = (row["period"] as? String).map { " · " + $0 } ?? ""
            panel.cells.append(Window(label: label, pct: limit > 0 ? min(100, spent / limit * 100) : 100,
                                      right: usd(spent) + " / " + usd(limit) + period, stale: age > 600))
        }
        if !panel.cells.isEmpty { panel.cellsTitle = id == "litellm" ? "Virtual key budgets" : "Account budget" }
        return panel
    }

    /// A balance read with one GET and turned into money by `parse`.
    static func balance(_ path: String, _ parse: @escaping (JSON, String) throws -> (Double, String)) -> (Call) throws -> JSON {
        { call in let (amount, symbol) = try parse(call.get(path), call.host); return ["balance": amount, "symbol": symbol] }
    }
    static func vercel(cache: Cache, credentials: CredentialReading, http: HTTPReading, home: URL = FileManager.default.homeDirectoryForCurrentUser,
                       environment: [String: String] = ProcessInfo.processInfo.environment) -> KeyProvider {
        KeyProvider(id: "vercel", name: "Vercel", hosts: ["ai-gateway.vercel.sh"], variables: ["AI_GATEWAY_API_KEY"],
                    cache: cache, credentials: credentials, http: http, home: home, environment: environment, read: balance("/v1/credits", vercelBalance))
    }
    static func deepSeek(cache: Cache, credentials: CredentialReading, http: HTTPReading, home: URL = FileManager.default.homeDirectoryForCurrentUser,
                         environment: [String: String] = ProcessInfo.processInfo.environment) -> KeyProvider {
        KeyProvider(id: "deepseek", name: "DeepSeek", hosts: ["api.deepseek.com"], variables: ["DEEPSEEK_API_KEY"],
                    cache: cache, credentials: credentials, http: http, home: home, environment: environment, read: balance("/user/balance", deepSeekBalance))
    }
    static func kimi(cache: Cache, credentials: CredentialReading, http: HTTPReading, home: URL = FileManager.default.homeDirectoryForCurrentUser,
                     environment: [String: String] = ProcessInfo.processInfo.environment) -> KeyProvider {
        KeyProvider(id: "kimi", name: "Kimi", hosts: ["api.moonshot.ai", "api.moonshot.cn"], variables: ["MOONSHOT_API_KEY", "KIMI_API_KEY"],
                    cache: cache, credentials: credentials, http: http, home: home, environment: environment, read: balance("/v1/users/me/balance", kimiBalance))
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

    /// Kimi Code (Kimi For Coding): a 5h window, a weekly one and, on newer plans, a monthly total. The key is the one
    /// Claude Code or kimi-cli already uses for `api.kimi.com/coding`; Moonshot's API keys are a different thing.
    static func kimiCode(cache: Cache, credentials: CredentialReading, http: HTTPReading, home: URL = FileManager.default.homeDirectoryForCurrentUser,
                         environment: [String: String] = ProcessInfo.processInfo.environment) -> KeyProvider {
        KeyProvider(id: "kimi-code", name: "Kimi Code", hosts: ["api.kimi.com", "api.kimi.ai"], variables: ["KIMI_CODE_API_KEY"],
                    cache: cache, credentials: credentials, http: http, home: home, environment: environment,
                    discover: kimiCLIKeys, read: { call in try kimiCodeUsage(call.get("/coding/v1/usages")) })
    }
    /// kimi-cli keeps its key in `~/.kimi/config.toml`, in the provider table pointed at the coding endpoint; KIMI_API_KEY
    /// counts only when it holds a Kimi Code key (`sk-kimi-`), since Moonshot's keys use that name too.
    static func kimiCLIKeys(home: URL, environment: [String: String]) -> [String: String] {
        let folder = environment["KIMI_SHARE_DIR"].map { URL(fileURLWithPath: $0) } ?? home.appendingPathComponent(".kimi")
        let text = (try? String(contentsOf: folder.appendingPathComponent("config.toml"), encoding: .utf8)) ?? ""
        for table in text.components(separatedBy: "\n[") where table.contains("/coding") {
            if let key = KeyFinder.capture(#"api_key\s*=\s*["']([A-Za-z0-9._-]{16,})["']"#, in: table) {
                return [table.contains("kimi.ai") ? "api.kimi.ai" : "api.kimi.com": key]
            }
        }
        if let key = KeyFinder.assigned(["KIMI_API_KEY"], in: KeyFinder.places(home: home), environment: environment), key.hasPrefix("sk-kimi-") {
            return ["api.kimi.com": key]
        }
        return [:]
    }
    /// Counts come as strings and a zero may be left out, so `used` falls back to limit minus remaining. Newer accounts
    /// also report a ratio per pool, which wins unless it is a placeholder zero beside real counts.
    static func kimiCodeUsage(_ response: JSON) throws -> JSON {
        var windows: JSON = [:]
        func add(_ key: String, _ minutes: Double?, _ pct: Double?, _ reset: Any?) {
            guard let pct = pct else { return }
            windows[key] = ["used_percentage": pct, "window_minutes": minutes as Any? ?? NSNull(), "resets_at": resetTime(reset) as Any? ?? NSNull()]
        }
        func share(_ counts: JSON) -> Double? {
            guard let limit = number(counts["limit"]), limit > 0, let used = number(counts["used"]) ?? number(counts["remaining"]).map({ limit - $0 }) else { return nil }
            return used / limit * 100
        }
        func reset(_ value: JSON) -> Any? { value["resetTime"] ?? value["reset_time"] ?? value["resetAt"] ?? value["reset_at"] }
        let week = dict(response["usage"])
        add("w10080", 10080, share(week), reset(week))
        for item in response["limits"] as? [JSON] ?? [] {
            let window = dict(item["window"]), detail = item["detail"] is JSON ? dict(item["detail"]) : item
            let unit = window["timeUnit"] as? String ?? "TIME_UNIT_MINUTE"
            guard let duration = number(window["duration"]), duration > 0 else { continue }
            let minutes = duration * (unit.hasSuffix("HOUR") ? 60 : unit.hasSuffix("DAY") ? 1440 : 1)
            guard minutes.isFinite, minutes < Double(Int.max) else { continue }
            add("w\(Int(minutes))", minutes, share(detail), reset(detail))
        }
        let pools = dict(response["usages"])
        for (pool, key, minutes) in [("limit_5h", "w300", 300.0), ("limit_7d", "w10080", 10080.0), ("limit_month_total", "month", 0)] {
            let value = dict(pools[pool])
            guard let ratio = number(value["used_ratio"]), ratio > 0 || windows[key] == nil else { continue }
            add(key, minutes > 0 ? minutes : nil, min(ratio, 1) * 100, reset(value))
        }
        guard !windows.isEmpty else { throw HUDProblem("Kimi Code returned no quota windows") }
        let level = dict(dict(response["user"])["membership"])["level"] as? String ?? ""
        let plans = ["LEVEL_TRIAL": "Andante", "LEVEL_BASIC": "Moderato", "LEVEL_INTERMEDIATE": "Allegretto", "LEVEL_ADVANCED": "Allegro"]
        return ["rate_limits": windows, "plan": plans[level] as Any? ?? NSNull()]
    }

    /// xAI API teams, through a management key (xAI Console › Settings › Management keys); ordinary API keys can't read
    /// billing. The key itself says which team it belongs to.
    static func xai(cache: Cache, credentials: CredentialReading, http: HTTPReading, home: URL = FileManager.default.homeDirectoryForCurrentUser,
                    environment: [String: String] = ProcessInfo.processInfo.environment) -> KeyProvider {
        KeyProvider(id: "xai", name: "xAI", hosts: ["management-api.x.ai"], variables: ["XAI_MANAGEMENT_API_KEY", "XAI_MANAGEMENT_KEY"],
                    cache: cache, credentials: credentials, http: http, home: home, environment: environment, read: xaiBilling)
    }
    /// Amounts are USD cents as strings, bare or as `{"val": "…"}`. The prepaid ledger counts a top-up as negative and
    /// posts spend when a cycle closes; teams billed afterwards show this cycle's spend against their limit instead.
    static func xaiBilling(_ call: Call) throws -> JSON {
        let key = try call.get("/auth/management-keys/validation")
        guard let team = (key["scope"] as? String == "SCOPE_TEAM" ? key["scopeId"] : nil) as? String ?? key["teamId"] as? String,
              team.range(of: "^[A-Za-z0-9-]{1,64}$", options: .regularExpression) != nil else { throw HUDProblem("Use an xAI management key made for one team") }
        func cents(_ value: Any?) -> Double? { (number(dict(value)["val"]) ?? number(value)).map { $0 / 100 } }
        let billing = "/v1/billing/teams/" + team
        let prepaid = (try? call.get(billing + "/prepaid/balance")).flatMap { cents($0["total"]) }.map { -$0 }
        let preview = (try? call.get(billing + "/postpaid/invoice/preview")) ?? [:]
        var blob: JSON = [:]
        if let limit = cents(preview["effectiveSpendingLimit"]), limit > 0, let spent = cents(dict(preview["coreInvoice"])["amountBeforeVat"]) {
            blob = ["spent": spent, "limit": limit, "period": "this month", "rate_limits": ["month": ["used_percentage": spent / limit * 100]]]
        }
        // A team billed afterwards holds no prepaid credit, and "$0 left" would only cry wolf.
        if let prepaid = prepaid, prepaid != 0 || blob.isEmpty { blob["balance"] = prepaid; blob["symbol"] = "$" }
        guard !blob.isEmpty else { throw HUDProblem("xAI response missing balance") }
        return blob
    }

    /// Fireworks: this month's spend against the account's monthly spend limit (the `monthly-spend-usd` quota, in USD).
    /// Fireworks has no balance API. The key and account are the ones firectl saved, or FIREWORKS_API_KEY; the account
    /// comes from FIREWORKS_ACCOUNT_ID, firectl, or else the key itself.
    static func fireworks(cache: Cache, credentials: CredentialReading, http: HTTPReading, home: URL = FileManager.default.homeDirectoryForCurrentUser,
                          environment: [String: String] = ProcessInfo.processInfo.environment) -> KeyProvider {
        let firectl = { (try? String(contentsOf: home.appendingPathComponent(".fireworks/auth.ini"), encoding: .utf8)) ?? "" }
        return KeyProvider(id: "fireworks", name: "Fireworks", hosts: ["api.fireworks.ai"], variables: ["FIREWORKS_API_KEY"],
                           cache: cache, credentials: credentials, http: http, home: home, environment: environment,
                           discover: { _, _ in KeyFinder.capture(#"api_key\s*=\s*"?([A-Za-z0-9._-]{16,})"#, in: firectl()).map { ["api.fireworks.ai": $0] } ?? [:] },
                           read: { call in
            let named = environment["FIREWORKS_ACCOUNT_ID"] ?? KeyFinder.capture(#"account_id\s*=\s*"?([A-Za-z0-9/_-]+)"#, in: firectl())
            return try fireworksSpend(call, account: named ?? call.http.header(URL(string: call.base + "/verifyApiKey")!, token: call.key, name: "x-fireworks-account-id"))
        })
    }
    static func fireworksSpend(_ call: Call, account: String?) throws -> JSON {
        guard let account = account.map({ $0.hasPrefix("accounts/") ? String($0.dropFirst(9)) : $0 }),
              account.range(of: "^[A-Za-z0-9_-]{1,63}$", options: .regularExpression) != nil else { throw HUDProblem("Fireworks account not found for this key") }
        let quota = try call.get("/v1/accounts/\(account)/quotas/monthly-spend-usd")
        guard let spent = number(quota["usage"]) else { throw HUDProblem("Fireworks response missing spend") }
        guard let limit = number(quota["value"]), limit > 0 else { return ["spent": spent, "period": "this month"] }
        return ["spent": spent, "limit": limit, "period": "this month", "rate_limits": ["month": ["used_percentage": spent / limit * 100]]]
    }

    /// A LiteLLM proxy: the virtual key's spend against its budget. The proxy is the one LITELLM_PROXY_API_BASE or
    /// LITELLM_BASE_URL names, or the gateway Claude Code is pointed at; its key goes back only to that same address,
    /// and an address that turns out not to be LiteLLM is left alone.
    static func liteLLM(cache: Cache, credentials: CredentialReading, http: HTTPReading, home: URL = FileManager.default.homeDirectoryForCurrentUser,
                        environment: [String: String] = ProcessInfo.processInfo.environment) -> KeyProvider {
        KeyProvider(id: "litellm", name: "LiteLLM", hosts: [], variables: [], cache: cache, credentials: credentials, http: http,
                    home: home, environment: environment, discover: liteLLMProxies, read: liteLLMBudget)
    }
    /// Hosts whose own APIs Claude Code may be pointed at; any other gateway may be LiteLLM.
    static let knownHosts = ["anthropic.com", "z.ai", "bigmodel.cn", "moonshot.ai", "moonshot.cn", "kimi.com", "kimi.ai", "deepseek.com",
                             "x.ai", "openai.com", "openrouter.ai", "vercel.sh", "fireworks.ai", "googleapis.com", "amazonaws.com", "azure.com"]
    /// Plain http is for a proxy on this machine or its own network, where nothing crosses the internet.
    static func isLocalHost(_ host: String) -> Bool {
        let host = host.lowercased()
        if host == "localhost" || host == "::1" || host.hasSuffix(".local") || host.hasSuffix(".localhost") { return true }
        let octets = host.split(separator: ".").compactMap { Int($0) }
        guard octets.count == 4, host.split(separator: ".").count == 4 else { return false }
        return octets[0] == 10 || octets[0] == 127 || (octets[0] == 192 && octets[1] == 168) || (octets[0] == 172 && (16...31).contains(octets[1]))
    }
    static func liteLLMProxies(home: URL, environment: [String: String]) -> [String: String] {
        /// "https://host:4000/v1" is the proxy at "https://host:4000"; its management routes live at the root.
        func root(_ address: String?) -> String? {
            guard let url = URL(string: address ?? ""), let scheme = url.scheme, ["http", "https"].contains(scheme), let host = url.host,
                  scheme == "https" || isLocalHost(host) else { return nil }
            return scheme + "://" + host + (url.port.map { ":\($0)" } ?? "")
        }
        var proxies: [String: String] = [:]
        let places = KeyFinder.places(home: home)
        // An address and its credential must come from the same source; never pair unrelated profiles.
        for files in [[]] + places.map({ [$0] }) {
            let env = files.isEmpty ? environment : [:]
            if let base = root(KeyFinder.assigned(["LITELLM_PROXY_API_BASE", "LITELLM_PROXY_BASE_URL", "LITELLM_BASE_URL"], in: files,
                                                  environment: env, value: #"https?://[^\s"']+"#)),
               let key = KeyFinder.assigned(["LITELLM_PROXY_API_KEY", "LITELLM_API_KEY"], in: files, environment: env), proxies[base] == nil {
                proxies[base] = key
            }
        }
        let settings = (try? Data(contentsOf: home.appendingPathComponent(".claude/settings.json"))).flatMap { try? JSONSerialization.jsonObject(with: $0) }
        for source in [environment, dict(dict(settings)["env"]).compactMapValues { $0 as? String }] {
            guard let base = root(source["ANTHROPIC_BASE_URL"]), let host = URL(string: base)?.host?.lowercased(),
                  !knownHosts.contains(where: { host == $0 || host.hasSuffix("." + $0) }),
                  let key = source["ANTHROPIC_AUTH_TOKEN"] ?? source["ANTHROPIC_API_KEY"], !key.isEmpty, proxies[base] == nil else { continue }
            proxies[base] = key
        }
        return proxies
    }
    /// Only a 200 with `info.spend` is LiteLLM; anything else reads as "not here". `max_budget` null means no cap.
    static func liteLLMBudget(_ call: Call) throws -> JSON {
        let info = dict(try call.get("/key/info")["info"])
        guard let spent = number(info["spend"]) else { throw HTTPFailure(status: 404) }
        var blob: JSON = ["spent": spent]
        if let limit = number(info["max_budget"]), limit >= 0 {
            blob["limit"] = limit
            blob["rate_limits"] = ["Budget": ["used_percentage": limit > 0 ? min(100, spent / limit * 100) : 100,
                "resets_at": resetTime(info["budget_reset_at"]) as Any? ?? NSNull()]]
        }
        if let duration = info["budget_duration"] as? String, !duration.isEmpty { blob["period"] = "every " + duration }
        let models = dict(info["model_max_budget_usage"])
        blob["budget_cells"] = models.keys.sorted().compactMap { label -> JSON? in
            let model = dict(models[label])
            guard let current = number(model["current_spend"]), current >= 0,
                  let limit = number(model["budget_limit"]), limit >= 0 else { return nil }
            return ["label": label, "spent": current, "limit": limit,
                    "period": (model["time_period"] as? String).map { "every " + $0 } as Any? ?? NSNull()]
        }
        return blob
    }
}
