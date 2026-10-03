import Foundation

protocol UsageProvider {
    var id: String { get }
    var name: String { get }
    var automatic: Bool { get }
    func refresh() throws
    func panel() -> Panel
    /// Optional providers stay out of the menu bar until they have read a quota once.
    func shown() -> Bool
}
extension UsageProvider { func shown() -> Bool { true } }
final class ClaudeProvider: UsageProvider {
    let id = "claude", name = "Claude", automatic = true
    let cache: Cache, credentials: CredentialReading, http: HTTPReading
    init(cache: Cache, credentials: CredentialReading, http: HTTPReading) {
        self.cache = cache; self.credentials = credentials; self.http = http
    }
    static func accessToken(_ text: String, now: Double = Date().timeIntervalSince1970) throws -> String {
        guard let data = text.data(using: .utf8), let object = try? JSONSerialization.jsonObject(with: data) as? JSON else {
            throw HUDProblem("Claude credential unreadable")
        }
        let oauth = (object["claudeAiOauth"] as? JSON) ?? object
        guard let token = oauth["accessToken"] as? String, !token.isEmpty else { throw HUDProblem("Claude token missing") }
        if let expiry = number(oauth["expiresAt"]), expiry / 1000 < now { throw HUDProblem("Claude authentication expired; run claude auth login") }
        return token
    }
    func refresh() throws {
        let token = try Self.accessToken(credentials.password(service: "Claude Code-credentials", account: nil))
        let data: JSON
        do {
            data = try http.get(URL(string: "https://api.anthropic.com/api/oauth/usage")!, token: token,
                                headers: ["anthropic-beta": "oauth-2025-04-20", "anthropic-version": "2023-06-01"], limit: 1024 * 1024)
        } catch let error as HTTPFailure {
            if error.status == 401 || error.status == 403 { throw HUDProblem("Claude needs sign-in: claude auth login", attention: true) }
            if error.status == 429 { throw HUDProblem("Claude usage endpoint throttled; retry later") }
            throw HUDProblem("Claude usage HTTP \(error.status)")
        }
        var windows: JSON = [:]
        for key in ["five_hour", "seven_day", "seven_day_sonnet", "seven_day_opus"] {
            let window = dict(data[key])
            guard let pct = number(window["utilization"]) else { continue }
            windows[key] = ["used_percentage": pct, "resets_at": resetTime(window["resets_at"]) as Any? ?? NSNull()]
        }
        guard !windows.isEmpty else { throw HUDProblem("Claude response has no quota windows") }
        var extra: JSON = ["source": "oauth-usage-get", "depleted": false, "probe_blocked_until": NSNull()]
        if var credits = data["extra_usage"] as? JSON {
            credits["captured_at"] = Date().timeIntervalSince1970; extra["usage_credits"] = credits
        }
        try cache.quota("claude.json", windows: windows, extra: extra)
    }
    func panel() -> Panel {
        let blob = cache.read("claude.json")
        var rows = quotaWindows(blob)
        let credits = dict(blob["usage_credits"])
        let old = Date().timeIntervalSince1970 - (number(credits["captured_at"]) ?? 0) > 21600
        if credits["is_enabled"] as? Bool == true, let used = number(credits["used_credits"]) {
            // Amounts are in minor units; `decimal_places` says how many, and cents when it is absent.
            let scale = pow(10, number(credits["decimal_places"]) ?? 2)
            let code = credits["currency"] as? String ?? "USD"
            let money = { (value: Double) in (code == "USD" ? "$" : code + " ") + String(format: "%.2f", value / scale) }
            if let limit = number(credits["monthly_limit"]), limit > 0 {
                let percent = number(credits["utilization"]) ?? used / limit * 100
                rows.append(Window(label: "extra usage", right: "\(money(used)) of \(money(limit)) this month · \(Int(percent.rounded()))%", stale: old))
            } else {
                rows.append(Window(label: "extra usage", right: "\(money(used)) spent this month", stale: old))
            }
        } else if credits["user_disabled"] as? Bool == true || credits["credits_ever_enabled"] as? Bool == true {
            rows.append(Window(label: "extra usage", right: "Off", stale: old))
        }
        return Panel(id: id, name: name, windows: rows, note: rows.isEmpty ? "Refresh Claude to read quota" : "")
    }
}
final class CodexProvider: UsageProvider {
    let id = "codex", name = "Codex", automatic = true
    let cache: Cache
    let credits: OpenAICredits
    init(cache: Cache, credits: OpenAICredits) { self.cache = cache; self.credits = credits }
    static func bucket(_ result: JSON) throws -> JSON {
        let buckets = dict(result["rateLimitsByLimitId"])
        let bucket = buckets.isEmpty ? dict(result["rateLimits"]) : dict(buckets["codex"])
        guard !bucket.isEmpty, bucket["limitId"] == nil || bucket["limitId"] is NSNull || bucket["limitId"] as? String == "codex" else {
            throw HUDProblem("Codex quota bucket missing")
        }
        return bucket
    }
    static func windows(_ result: JSON) throws -> JSON {
        let bucket = try Self.bucket(result)
        var windows: JSON = [:]
        for key in ["primary", "secondary"] {
            let window = dict(bucket[key])
            guard let pct = number(window["usedPercent"]) else { continue }
            windows[key] = ["used_percentage": pct,
                            "window_minutes": number(window["windowDurationMins"]) as Any? ?? NSNull(),
                            "resets_at": number(window["resetsAt"]) as Any? ?? NSNull()]
        }
        guard !windows.isEmpty || !dict(bucket["credits"]).isEmpty else { throw HUDProblem("Codex returned no quota windows") }
        return windows
    }
    func refresh() throws {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let environment = ProcessInfo.processInfo.environment
        let configured = environment["USAGE_HUD_CODEX_CLI"] ?? Bundle.main.object(forInfoDictionaryKey: "UsageHUDCodexCLI") as? String
        let candidates = [configured].compactMap { $0 } +
            [home.appendingPathComponent(".local/bin/codex").path, "/opt/homebrew/bin/codex", "/usr/local/bin/codex"] +
            (environment["PATH"] ?? "").split(separator: ":").map { String($0) + "/codex" }
        guard let path = candidates.first(where: { $0.hasPrefix("/") && FileManager.default.isExecutableFile(atPath: $0) }) else {
            throw HUDProblem("Install Codex CLI and sign in with codex login")
        }
        let binary = URL(fileURLWithPath: path)
        var env = ProcessInfo.processInfo.environment
        env["CODEX_HOME"] = env["CODEX_HOME"] ?? home.appendingPathComponent(".codex").path
        let rpc = try RPCProcess(binary: binary, arguments: ["app-server", "--stdio"], environment: env)
        defer { rpc.stop() }
        try rpc.send(["id": 1, "method": "initialize", "params": ["clientInfo": ["name": "usage_hud", "version": "2.0"]]])
        _ = try rpc.receive(1)
        try rpc.send(["method": "initialized", "params": JSON()])
        try rpc.send(["id": 2, "method": "account/rateLimits/read"])
        let response = try rpc.receive(2), bucket = try Self.bucket(response)
        try cache.quota("codex-quota.json", windows: Self.windows(response), extra: ["source": "standalone-cli",
            "plan": bucket["planType"] ?? NSNull(), "subscription_credits": bucket["credits"] ?? NSNull()])
    }
    func panel() -> Panel {
        let blob = cache.read("codex-quota.json"), plan = blob["plan"] as? String
        var rows = quotaWindows(blob)
        if ["pro", "prolite"].contains(plan ?? "") { rows.removeAll { $0.label == "5h" } }
        let purchased = dict(blob["subscription_credits"])
        let old = Date().timeIntervalSince1970 - (number(blob["captured_at"]) ?? 0) > 600
        if purchased["unlimited"] as? Bool == true {
            rows.append(Window(label: "Codex credits", right: "Unlimited credits", stale: old))
        } else if let balance = number(purchased["balance"]), balance >= 0 {
            rows.append(Window(label: "Codex credits", right: String(format: "%g credits left", balance), stale: old))
        } else if purchased["hasCredits"] as? Bool == false {
            rows.append(Window(label: "Codex credits", right: "No purchased credits", stale: old))
        }
        if let credit = credits.row() { rows.append(credit) }
        return Panel(id: id, name: name, windows: rows, note: plan.map { "Plan: " + $0 } ?? (rows.isEmpty ? "Refresh Codex to read quota" : ""))
    }
}
struct RouterSlot {
    let id: String, label: String
    let sources: [JSON]
}
final class OpenRouterProvider: UsageProvider {
    let id = "openrouter", name = "OpenRouter"
    /// A management key lists every key on the account, so a team lead adds one secret instead of each person's.
    static let teamService = "Usage HUD OpenRouter Team"
    /// Refreshes in the background; with nothing configured it stays hidden and quiet.
    let automatic = true
    /// Hidden until its first read, so people without OpenRouter don't spend a menu bar slot on it.
    func shown() -> Bool { FileManager.default.fileExists(atPath: cache.root.appendingPathComponent("openrouter.json").path) }
    let cache: Cache, credentials: CredentialReading, http: HTTPReading
    let home: URL, environment: [String: String]
    init(cache: Cache, credentials: CredentialReading, http: HTTPReading,
         home: URL = FileManager.default.homeDirectoryForCurrentUser, environment: [String: String] = ProcessInfo.processInfo.environment) {
        self.cache = cache; self.credentials = credentials; self.http = http; self.home = home; self.environment = environment
    }
    static func slots(_ array: Any) throws -> [RouterSlot] {
        guard let values = array as? [JSON] else { throw HUDProblem("Invalid provider slots") }
        var seen = Set<String>()
        return try values.map {
            guard let id = $0["id"] as? String, !id.isEmpty, seen.insert(id).inserted,
                  let label = $0["label"] as? String, !label.isEmpty,
                  let sources = $0["sources"] as? [JSON], !sources.isEmpty,
                  sources.allSatisfy({ $0["provider"] is String }) else { throw HUDProblem("Invalid or duplicate provider slot") }
            return RouterSlot(id: id, label: label, sources: sources)
        }
    }
    func configuredSlots() throws -> [RouterSlot] {
        let env = environment
        let data = env["USAGE_HUD_PROVIDER_SLOTS"].flatMap { $0.data(using: .utf8) } ?? (try? Data(contentsOf: cache.root.appendingPathComponent("providers.json")))
        if let data = data { return try Self.slots(JSONSerialization.jsonObject(with: data)) }
        guard let service = env["USAGE_HUD_OPENROUTER_SERVICE"], let pairs = env["USAGE_HUD_OPENROUTER_KEYS"] else {
            // Nothing configured: use the keys already on this Mac.
            return KeyFinder.find(in: KeyFinder.places(home: home), environment: env).map {
                RouterSlot(id: "found-" + $0.label, label: $0.label, sources: [["provider": "openrouter", "found": $0.key]])
            }
        }
        return pairs.split(separator: ",").enumerated().compactMap { index, pair in
            let values = pair.split(separator: ":", maxSplits: 1)
            guard values.count == 2 else { return nil }
            return RouterSlot(id: "legacy-\(index+1)", label: String(values[0]), sources: [["provider": "openrouter", "service": service, "account": String(values[1])]])
        }
    }
    func probe(_ source: JSON) throws -> JSON {
        guard source["provider"] as? String == "openrouter" else { throw HUDProblem("Unsupported provider source") }
        let token: String
        if let found = source["found"] as? String { token = found } else {
            guard let service = source["service"] as? String, !service.isEmpty, let account = source["account"] as? String, !account.isEmpty else {
                throw HUDProblem("OpenRouter source requires service and account")
            }
            token = try credentials.password(service: service, account: account)
        }
        let key = dict(try http.get(URL(string: "https://openrouter.ai/api/v1/key")!, token: token, headers: [:], limit: 1024 * 1024)["data"])
        guard let usage = number(key["usage"]) else { throw HUDProblem("OpenRouter response missing usage") }
        var result: JSON = ["usage": max(0, usage), "limit": number(key["limit"]) as Any? ?? NSNull(),
                            "usage_daily": number(key["usage_daily"]) as Any? ?? NSNull(),
                            "limit_remaining": number(key["limit_remaining"]) as Any? ?? NSNull(),
                            "limit_reset": key["limit_reset"] as? String as Any? ?? NSNull()]
        if let payload = try? http.get(URL(string: "https://openrouter.ai/api/v1/credits")!, token: token, headers: [:], limit: 1024 * 1024) {
            let data = dict(payload["data"])
            if let total = number(data["total_credits"]), let used = number(data["total_usage"]) { result["credits_remaining"] = total - used }
        }
        return result
    }
    static func successfulRow(slot: RouterSlot, source: JSON, result: JSON, previous: JSON, day: String) -> JSON {
        let fingerprint = "openrouter:\(source["service"] as? String ?? ""):\(source["account"] as? String ?? "")"
        let usage = number(result["usage"]) ?? 0
        let same = previous["source_id"] as? String == fingerprint && previous["day"] as? String == day
        return ["slot_id": slot.id, "label": slot.label, "provider": "openrouter", "source_id": fingerprint,
                "usage": usage, "limit": result["limit"] ?? NSNull(), "day": day,
                "usage_daily": result["usage_daily"] ?? NSNull(), "limit_remaining": result["limit_remaining"] ?? NSNull(),
                "limit_reset": result["limit_reset"] ?? NSNull(),
                "day_start_usage": same ? number(previous["day_start_usage"]) ?? usage : usage]
    }
    /// One key, personal or a teammate's: `pct` is the share of its cap used, `left` the share remaining (for ordering),
    /// and `warning` is set within 10% of the cap.
    static func keyCell(_ row: JSON, old: Bool) -> (cell: Window, left: Double, warning: String?) {
        let label = (row["name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? row["label"] as? String ?? "Key"
        if row["error"] != nil { return (Window(label: label, right: "Unavailable · cached", stale: true), 2, nil) }
        let usage = number(row["usage"]) ?? 0
        let today = number(row["usage_daily"]) ?? number(row["day_start_usage"]).map { max(0, usage - $0) }
        guard let limit = number(row["limit"]), limit > 0 else {
            return (Window(label: label, right: today.map { usd($0) + " today" } ?? usd(usage) + " total", stale: old), 1, nil)
        }
        let period = row["limit_reset"] as? String
        let remaining = max(0, number(row["limit_remaining"]) ?? limit - usage), left = remaining / limit
        let reset = nextReset(period).map { " · resets in " + countdown($0.timeIntervalSinceNow) } ?? ""
        let text = "\(usd(limit - remaining)) of \(usd(limit)) " + (periodName[period ?? ""] ?? "cap") + reset
        return (Window(label: label, pct: (1 - left) * 100, right: text, stale: old), left,
                left > 0.1 ? nil : remaining <= 0 ? "cap reached" : usd(remaining) + " left of its cap")
    }
    static let periodName = ["daily": "today", "weekly": "this week", "monthly": "this month"]
    /// When a key's cap resets: OpenRouter counts days, weeks (from Monday) and months in UTC.
    static func nextReset(_ period: String?, after now: Date = Date()) -> Date? {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let match: DateComponents
        switch period {
        case "daily": match = DateComponents(hour: 0, minute: 0, second: 0)
        case "weekly": match = DateComponents(hour: 0, minute: 0, second: 0, weekday: 2)
        case "monthly": match = DateComponents(day: 1, hour: 0, minute: 0, second: 0)
        default: return nil
        }
        return calendar.nextDate(after: now, matching: match, matchingPolicy: .nextTime)
    }
    /// Every enabled key on the account, 100 a page, stopping at 2,000 keys.
    func teamKeys(_ token: String) throws -> [JSON] {
        var keys: [JSON] = []
        for page in 0..<20 {
            let payload = try http.get(URL(string: "https://openrouter.ai/api/v1/keys?offset=\(page * 100)")!, token: token, headers: [:], limit: 4 * 1024 * 1024)
            guard let batch = payload["data"] as? [JSON] else { throw HUDProblem("OpenRouter key list missing data") }
            keys += batch.filter { $0["disabled"] as? Bool != true }
            if batch.count < 100 { break }
        }
        return keys
    }
    func refresh() throws {
        let slots = try configuredSlots()
        let team = try credentials.stored(service: Self.teamService, account: "openrouter.ai")
        guard !slots.isEmpty || team != nil else { throw HUDProblem("Add an OpenRouter key; see PROVIDERS.md") }
        let previous = cache.read("openrouter.json")
        let oldRows = previous["rows"] as? [JSON] ?? []
        var rows: [JSON] = [], balances = dict(previous["balances"]), failures: [String] = []
        if balances["openrouter"] == nil { balances["openrouter"] = previous["credits_remaining"] }
        var balanceCaptured = number(previous["balance_captured_at"]) ?? number(previous["captured_at"]) ?? 0
        // OpenRouter's days, and its daily caps, turn over at midnight UTC.
        let formatter = DateFormatter(); formatter.dateFormat = "yyyy-MM-dd"; formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        let day = formatter.string(from: Date()), now = Date().timeIntervalSince1970
        for slot in slots {
            let old = oldRows.first(where: { $0["slot_id"] as? String == slot.id || $0["label"] as? String == slot.label }) ?? [:]
            var winner: (JSON, JSON)?
            for source in slot.sources {
                do { winner = (source, try probe(source)); break }
                catch let problem as HUDProblem where problem.prompted { throw problem }
                catch {}
            }
            if let (source, result) = winner {
                rows.append(Self.successfulRow(slot: slot, source: source, result: result, previous: old, day: day))
                if let balance = number(result["credits_remaining"]) { balances["openrouter"] = balance; balanceCaptured = now }
            } else {
                var row = old; row["slot_id"] = slot.id; row["label"] = slot.label
                row["stale"] = true; row["error"] = "All sources unavailable"; rows.append(row); failures.append(slot.label)
            }
        }
        var teamRows = previous["team"] as? [JSON], teamProblem: HUDProblem?
        if let team = team {
            do {
                teamRows = try teamKeys(team)
                if let payload = try? http.get(URL(string: "https://openrouter.ai/api/v1/credits")!, token: team, headers: [:], limit: 1024 * 1024),
                   let total = number(dict(payload["data"])["total_credits"]), let used = number(dict(payload["data"])["total_usage"]) {
                    balances["openrouter"] = total - used; balanceCaptured = now
                }
            } catch let error as HTTPFailure {
                teamProblem = error.status == 401 || error.status == 403 ? HUDProblem("OpenRouter management key rejected", attention: true)
                    : HUDProblem("OpenRouter key list HTTP \(error.status)")
            } catch { teamProblem = error as? HUDProblem ?? HUDProblem("OpenRouter key list unavailable") }
        }
        let fresh = failures.count < slots.count || team != nil && teamProblem == nil
        try cache.write("openrouter.json", ["captured_at": fresh ? now : number(previous["captured_at"]) ?? 0,
                                           "checked_at": now, "balance_captured_at": balanceCaptured, "balances": balances, "rows": rows,
                                           "team": teamRows as Any? ?? NSNull()])
        if let problem = teamProblem { throw problem }
        if !failures.isEmpty { throw HUDProblem("OpenRouter failed slots: " + failures.joined(separator: ", ")) }
    }
    func panel() -> Panel {
        let blob = cache.read("openrouter.json")
        let old = Date().timeIntervalSince1970 - (number(blob["captured_at"]) ?? 0) > 21600
        var rows: [Window] = []
        let balances = dict(blob["balances"])
        let balance = number(balances["openrouter"]) ?? number(blob["credits_remaining"])
        let balanceOld = Date().timeIntervalSince1970 - (number(blob["balance_captured_at"]) ?? number(blob["captured_at"]) ?? 0) > 21600
        if let balance = balance { rows.append(Window(label: name, right: usd(balance) + " left", stale: balanceOld)) }
        let ranked = { (rows: [JSON]) -> [(cell: Window, left: Double, warning: String?)] in
            rows.map { Self.keyCell($0, old: old) }.enumerated().sorted { ($0.element.left, $0.offset) < ($1.element.left, $1.offset) }.map { $0.element }
        }
        let mine = ranked(blob["rows"] as? [JSON] ?? []), team = ranked(blob["team"] as? [JSON] ?? [])
        // Menu rows carry no percentage, so the battery keeps showing money.
        rows += mine.map { Window(label: $0.cell.label, right: $0.cell.right, stale: $0.cell.stale) }
        var title: String?
        if !team.isEmpty {
            let today = (blob["team"] as? [JSON] ?? []).compactMap { number($0["usage_daily"]) }.reduce(0, +)
            let near = team.filter { $0.warning != nil }.count
            title = "\(team.count) keys · \(usd(today)) today" + (near > 0 ? " · \(near) near cap" : "")
            rows.append(Window(label: "Team", right: title, stale: old))
        }
        // Only your own keys pulse: a teammate reaching the cap they were given is the cap doing its job.
        let alert = mine.first { $0.warning != nil }.map { $0.cell.label + ": " + ($0.warning ?? "") }
        return Panel(id: id, name: name, windows: rows, note: rows.isEmpty ? "Add an OpenRouter key; see PROVIDERS.md" : "", alert: alert,
                     cells: (mine + team).map { $0.cell }, cellsTitle: title)
    }
}
