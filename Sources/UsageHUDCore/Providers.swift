import Foundation

protocol UsageProvider {
    var id: String { get }
    var name: String { get }
    var automatic: Bool { get }
    var cacheFile: String { get }
    func refresh() throws
    func panel() -> Panel
    /// Optional providers stay out of the menu bar until they have read a quota once.
    func shown() -> Bool
}
extension UsageProvider {
    func shown() -> Bool { true }
    var cacheFile: String { id + ".json" }
}
final class ClaudeProvider: UsageProvider {
    let id = "claude", name = "Claude", automatic = true
    /// Hidden until a first read or a Claude Code status line, so Codex-only people don't carry an empty battery.
    func shown() -> Bool { FileManager.default.fileExists(atPath: cache.root.appendingPathComponent("claude.json").path) }
    let cache: Cache, credentials: CredentialReading, http: HTTPReading, home: URL
    init(cache: Cache, credentials: CredentialReading, http: HTTPReading, home: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.cache = cache; self.credentials = credentials; self.http = http; self.home = home
    }
    static let headers = ["anthropic-beta": "oauth-2025-04-20", "anthropic-version": "2023-06-01"]
    static func accessToken(_ text: String, now: Double = Date().timeIntervalSince1970) throws -> String {
        guard let data = text.data(using: .utf8), let object = try? JSONSerialization.jsonObject(with: data) as? JSON else {
            throw HUDProblem("Claude credential unreadable")
        }
        let oauth = (object["claudeAiOauth"] as? JSON) ?? object
        guard let token = oauth["accessToken"] as? String, !token.isEmpty else { throw HUDProblem("Claude token missing") }
        // Expiry does not establish sign-out or which credential store Desktop uses. The HUD leaves renewal to Claude
        // Code; a newer statusline reading can also clear the cached failure without this token changing.
        if let expiry = number(oauth["expiresAt"]), expiry / 1000 < now { throw HUDProblem("Claude Code credential expired; it renews with one small Claude Code call, or run claude once in a terminal") }
        return token
    }
    func refresh() throws {
        // A fresh statusline quota takes precedence, even without a usable OAuth credential.
        // Money rows keep their own age; the OAuth fallback can refresh them when statusline readings stop.
        let blob = cache.read("claude.json"), now = Date().timeIntervalSince1970
        // The usage endpoint is undocumented and answers 429 when read too often: after one, stay away for a growing while,
        // and otherwise read it at most every five minutes, whoever asks (timers, hooks, restarts).
        let backoff = cache.read("claude-backoff.json")
        if ["statusline", "claude-run"].contains(blob["source"] as? String),
           ["five_hour", "seven_day"].contains(where: { key in
               let window = dict(dict(blob["rate_limits"])[key])
               return number(window["used_percentage"]) != nil && window["stale"] as? Bool != true &&
                   now - (number(window["captured_at"]) ?? 0) < 600 &&
                   (resetTime(window["resets_at"]) ?? .infinity) > now
           }) { return }
        if now < (number(backoff["until"]) ?? 0) || now - (number(blob["oauth_at"]) ?? 0) < 300 { return }
        let token = try Self.accessToken(credentials.password(service: "Claude Code-credentials", account: nil))
        let data: JSON
        do {
            data = try http.get(URL(string: "https://api.anthropic.com/api/oauth/usage")!, token: token, headers: Self.headers, limit: 1024 * 1024)
        } catch let error as HTTPFailure {
            if error.status == 401 || error.status == 403 { throw HUDProblem("Claude needs sign-in: claude auth login", attention: true, fix: "claude auth login") }
            if error.status == 429 {
                let strikes = min(4, Int(number(backoff["strikes"]) ?? 0) + 1)
                try? cache.write("claude-backoff.json", ["strikes": strikes, "until": now + Double(900 << (strikes - 1))])
                throw HUDProblem("Claude usage endpoint throttled; reading again in \(15 << (strikes - 1)) min")
            }
            throw HUDProblem("Claude usage HTTP \(error.status)")
        }
        var windows: JSON = [:]
        for key in ["five_hour", "seven_day", "seven_day_sonnet", "seven_day_opus"] {
            let window = dict(data[key])
            guard let pct = number(window["utilization"]) else { continue }
            windows[key] = ["used_percentage": pct, "resets_at": resetTime(window["resets_at"]) as Any? ?? NSNull()]
        }
        guard !windows.isEmpty else { throw HUDProblem("Claude response has no quota windows") }
        if !backoff.isEmpty { try? cache.write("claude-backoff.json", [:]) }
        var extra: JSON = ReadingSource.claudeOAuth.receipt(now: now)
        extra.merge(["source": "oauth-usage-get", "oauth_at": now, "depleted": false, "probe_blocked_until": NSNull()]) { _, new in new }
        if var credits = data["extra_usage"] as? JSON {
            credits["captured_at"] = Date().timeIntervalSince1970; extra["usage_credits"] = credits
        }
        if now - (number(cache.read("claude.json")["extras_at"]) ?? 0) > 3600 { extra.merge(extras(token)) { _, new in new } }
        try cache.quota("claude.json", windows: windows, extra: extra)
    }
    /// The prepaid balance changes rarely, so it is read hourly, the way Claude Code reads it; a failure just leaves the row out.
    /// Reset grants are not read: the experimental request was removed rather than emulate another client's identity.
    func extras(_ token: String) -> JSON {
        var extras: JSON = ["extras_at": Date().timeIntervalSince1970]
        if let organization = organization(),
           let paid = try? http.get(URL(string: "https://api.anthropic.com/api/oauth/organizations/\(organization)/prepaid/credits")!, token: token,
                                    headers: Self.headers.merging(["x-organization-uuid": organization], uniquingKeysWith: { $1 }), limit: 64 * 1024),
           let amount = number(paid["amount"]) {
            extras["prepaid"] = ["amount": amount, "currency": paid["currency"] as? String ?? "USD"]
        }
        return extras
    }
    /// The organization Claude Code signed in to, from its own config file (an id, not a secret).
    func organization() -> String? {
        guard let data = try? Data(contentsOf: home.appendingPathComponent(".claude.json")),
              let id = dict(dict(try? JSONSerialization.jsonObject(with: data))["oauthAccount"])["organizationUuid"] as? String,
              id.range(of: "^[0-9a-fA-F-]{36}$", options: .regularExpression) != nil else { return nil }
        return id
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
            let amount = { (value: Double) in money(value / scale, code == "USD" ? "$" : code + " ") }
            let limit = number(credits["monthly_limit"]).flatMap { $0 > 0 ? $0 : nil }
            rows.append(Window(label: "Extra usage", right: amount(used) + (limit.map { " / " + amount($0) } ?? "") + " · this month", stale: old))
        } else if credits["user_disabled"] as? Bool == true || credits["credits_ever_enabled"] as? Bool == true {
            rows.append(Window(label: "Extra usage", right: "Off", stale: old))
        }
        let extrasOld = Date().timeIntervalSince1970 - (number(blob["extras_at"]) ?? 0) > 7200
        let prepaid = dict(blob["prepaid"])
        if let cents = number(prepaid["amount"]) {
            let code = prepaid["currency"] as? String ?? "USD"
            rows.append(Window(label: "Balance", right: money(cents / 100, code == "USD" ? "$" : code + " "), stale: extrasOld))
        }
        return Panel(id: id, name: name, windows: rows, note: rows.isEmpty ? "Refresh Claude to read quota" : "")
    }
}
final class CodexProvider: UsageProvider {
    let id = "codex", name = "Codex", automatic = true
    var cacheFile: String { "codex-quota.json" }
    /// Hidden until a first read, so Claude-only people don't carry an empty battery.
    func shown() -> Bool { FileManager.default.fileExists(atPath: cache.root.appendingPathComponent("codex-quota.json").path) }
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
        let configured = ProcessInfo.processInfo.environment["USAGE_HUD_CODEX_CLI"] ?? Bundle.main.object(forInfoDictionaryKey: "UsageHUDCodexCLI") as? String
        guard let binary = CLI.find("codex", configured: configured) else { throw HUDProblem("Install Codex CLI and sign in with codex login", gone: true) }
        var env = CLI.environment(for: binary)
        env["CODEX_HOME"] = env["CODEX_HOME"] ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex").path
        let rpc = try RPCProcess(binary: binary, arguments: ["app-server", "--stdio"], environment: env)
        defer { rpc.stop() }
        try rpc.send(["id": 1, "method": "initialize", "params": ["clientInfo": ["name": "usage_hud", "version": "2.0"]]])
        _ = try rpc.receive(1)
        try rpc.send(["method": "initialized", "params": JSON()])
        try rpc.send(["id": 2, "method": "account/rateLimits/read"])
        let response = try rpc.receive(2), bucket = try Self.bucket(response)
        try cache.quota("codex-quota.json", windows: Self.windows(response), extra: ["reading_source": ReadingSource.codexCLI.rawValue, "source_read_at": Date().timeIntervalSince1970, "source": "standalone-cli",
            "plan": bucket["planType"] ?? NSNull(), "subscription_credits": bucket["credits"] ?? NSNull(),
            "free_resets": Self.freeResets(response) as Any? ?? NSNull()])
    }
    /// The usage-limit resets ChatGPT grants, from the same read: how many, and when the soonest one expires.
    static func freeResets(_ response: JSON) -> JSON? {
        let grants = dict(response["rateLimitResetCredits"])
        guard let left = number(grants["availableCount"]) else { return nil }
        let expiries = (grants["credits"] as? [JSON] ?? []).filter { ($0["status"] as? String ?? "available") == "available" }.compactMap { number($0["expiresAt"]) }
        return ["left": left, "until": expiries.min() as Any? ?? NSNull()]
    }
    func panel() -> Panel {
        let blob = cache.read("codex-quota.json"), plan = blob["plan"] as? String
        var rows = quotaWindows(blob)
        if ["pro", "prolite"].contains(plan ?? "") { rows.removeAll { $0.label == "5h" } }
        let purchased = dict(blob["subscription_credits"])
        let old = Date().timeIntervalSince1970 - (number(blob["captured_at"]) ?? 0) > 600
        // Purchased credits show only when there are some; an empty balance is the normal case, not news.
        if purchased["unlimited"] as? Bool == true {
            rows.append(Window(label: "Credits", right: "Unlimited", stale: old))
        } else if let balance = number(purchased["balance"]), balance > 0 {
            rows.append(Window(label: "Credits", right: String(format: "%g", balance), stale: old))
        }
        if let resets = freeResetsRow(blob["free_resets"], stale: old) { rows.append(resets) }
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
    var found: (at: Double, slots: [RouterSlot]) = (0, [])
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
        // The slots written in providers.json, plus what dropped boots and the usual places hold.
        if let data = data { return try Self.slots(JSONSerialization.jsonObject(with: data)) + foundSlots() }
        guard let service = env["USAGE_HUD_OPENROUTER_SERVICE"], let pairs = env["USAGE_HUD_OPENROUTER_KEYS"] else { return foundSlots() }
        return pairs.split(separator: ",").enumerated().compactMap { index, pair in
            let values = pair.split(separator: ":", maxSplits: 1)
            guard values.count == 2 else { return nil }
            return RouterSlot(id: "legacy-\(index+1)", label: String(values[0]), sources: [["provider": "openrouter", "service": service, "account": String(values[1])]])
        }
    }
    /// The keys already on this Mac. The search runs at most hourly; keys stay in memory only.
    func foundSlots() -> [RouterSlot] {
        let now = Date().timeIntervalSince1970
        let edited = ((try? FileManager.default.attributesOfItem(atPath: home.appendingPathComponent(".usage-hud/key-sources.json").path))?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        if now - found.at > 3600 || edited > found.at {
            let chosen = KeyFinder.chosen(home: home)
            found = (now, KeyFinder.find(in: KeyFinder.places(home: home), chosen: chosen, environment: environment).map {
                RouterSlot(id: "found-" + KeyFinder.fingerprint($0.key), label: $0.label, sources: [["provider": "openrouter", "found": $0.key]])
            } + KeyFinder.zen(in: chosen).map { RouterSlot(id: "zen-" + $0, label: $0, sources: [["provider": "zen"]]) })
        }
        return found.slots
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
                            "key_label": key["label"] as? String as Any? ?? NSNull(), "management": key["is_provisioning_key"] as? Bool == true,
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
        return ["slot_id": slot.id, "label": slot.label, "provider": "openrouter", "source_id": fingerprint, "key_label": result["key_label"] ?? NSNull(),
                "usage": usage, "limit": result["limit"] ?? NSNull(), "day": day,
                "usage_daily": result["usage_daily"] ?? NSNull(), "limit_remaining": result["limit_remaining"] ?? NSNull(),
                "limit_reset": result["limit_reset"] ?? NSNull(), "captured_at": Date().timeIntervalSince1970,
                "day_start_usage": same ? number(previous["day_start_usage"]) ?? usage : usage, "state": "ok"]
    }
    /// One key, personal or a teammate's: `pct` is the share of its cap used, `left` the share remaining (for ordering),
    /// and `warning` is set within 10% of the cap.
    static func keyCell(_ row: JSON, old: Bool, capturedAt: Double? = nil, now: Date = Date()) -> (cell: Window, left: Double, warning: String?) {
        let label = (row["name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? row["label"] as? String ?? "Key"
        let problem = row["error"] is String
        // A key that is gone or refused says so; one that merely can't be read keeps its last value, dimmed.
        if let state = row["state"] as? String {
            if state == "zen" { return (Window(label: label, right: "Free · Zen"), 1.5, nil) }
            if state == "removed" || state == "invalid" { return (Window(label: label, right: row["error"] as? String ?? "Key unavailable", stale: true), 2, nil) }
        }
        let cached = old || row["stale"] as? Bool == true || problem
        if problem && number(row["usage"]) == nil { return (Window(label: label, right: row["error"] as? String ?? "Unavailable", stale: true), 2, nil) }
        let usage = number(row["usage"]) ?? 0
        let today = number(row["usage_daily"]) ?? number(row["day_start_usage"]).map { max(0, usage - $0) }
        guard let limit = number(row["limit"]), limit >= 0 else {
            return (Window(label: label, right: today.map { usd($0) + " today" } ?? usd(usage) + " total", stale: cached), 1, nil)
        }
        let period = row["limit_reset"] as? String
        let remaining = min(limit, max(0, number(row["limit_remaining"]) ?? limit - usage)), left = limit > 0 ? remaining / limit : 0
        let captured = number(row["captured_at"]) ?? capturedAt ?? now.timeIntervalSince1970
        let resetAt = nextReset(period, after: Date(timeIntervalSince1970: captured))?.timeIntervalSince1970
        let expired = resetAt.map { $0 <= now.timeIntervalSince1970 } ?? false
        let stale = cached || now.timeIntervalSince1970 - captured > 600
        let reset = expired ? " · waiting for its reset" : resetAt.map { " · ↻ " + countdown($0 - now.timeIntervalSince1970) } ?? ""
        let text = "\(usd(limit - remaining)) / \(usd(limit))" + reset
        return (Window(label: label, pct: (1 - left) * 100, right: text, resets_at: resetAt, expired: expired, stale: stale), left,
                stale || expired || left > 0.1 ? nil : remaining <= 0 ? "cap reached" : "near its cap")
    }
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
        var team = try credentials.stored(service: Self.teamService, account: "openrouter.ai"), listed: [JSON]?
        guard !slots.isEmpty || team != nil else { throw HUDProblem("Add an OpenRouter key; see PROVIDERS.md", gone: true) }
        let previous = cache.read("openrouter.json")
        let oldRows = previous["rows"] as? [JSON] ?? []
        var rows: [JSON] = [], balances = dict(previous["balances"]), failures: [String] = []
        if balances["openrouter"] == nil { balances["openrouter"] = previous["credits_remaining"] }
        var balanceCaptured = number(previous["balance_captured_at"]) ?? number(previous["captured_at"]) ?? 0
        // OpenRouter's days, and its daily caps, turn over at midnight UTC.
        let formatter = DateFormatter(); formatter.dateFormat = "yyyy-MM-dd"; formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        let day = formatter.string(from: Date()), now = Date().timeIntervalSince1970
        var seenKeys = Set<String>()
        // A key whose Keychain item is gone is announced once, then its row goes; it comes back by itself if the item does.
        var dismissed = Set(previous["dismissed"] as? [String] ?? [])
        for slot in slots {
            let old = oldRows.first(where: { $0["slot_id"] as? String == slot.id || $0["label"] as? String == slot.label }) ?? [:]
            var winner: (JSON, JSON)?, management = false, rejected = false, removed = false
            if slot.sources.first?["provider"] as? String == "zen" {
                rows.append(["slot_id": slot.id, "label": slot.label, "provider": "zen", "state": "zen", "captured_at": now]); continue
            }
            for source in slot.sources {
                do { winner = (source, try probe(source)) }
                catch let problem as HUDProblem where problem.prompted { throw problem }
                catch let problem as HUDProblem where problem.gone { removed = true }
                catch let failure as HTTPFailure { rejected = failure.status == 401 || failure.status == 403 }
                catch {}
                // A management key found on the Mac lists the team instead of showing as a key of its own: OpenRouter flags it,
                // its variable says so, or it can't read /key but can list keys.
                let named = ["management", "provisioning", "admin"].contains { slot.label.lowercased().contains($0) }
                if let found = source["found"] as? String, team == nil || team == found,
                   winner?.1["management"] as? Bool == true || named || winner == nil && listed == nil,
                   let keys = try? teamKeys(found) { team = found; listed = keys; management = true; winner = nil; break }
                if winner != nil { break }
            }
            // A revoked key left in an old script is not yours to fix; it simply isn't shown.
            if management || winner == nil && rejected && slot.sources.allSatisfy({ $0["found"] != nil }) { continue }
            // A key already shown under another name (the same one in a keychain slot and a script) shows once.
            if let (_, result) = winner, let hint = result["key_label"] as? String, !seenKeys.insert(hint).inserted { continue }
            if winner != nil { dismissed.remove(slot.id) }
            if let (source, result) = winner {
                rows.append(Self.successfulRow(slot: slot, source: source, result: result, previous: old, day: day))
                if let balance = number(result["credits_remaining"]) { balances["openrouter"] = balance; balanceCaptured = now }
            } else {
                if removed && dismissed.contains(slot.id) { continue }
                var row = old; row["slot_id"] = slot.id; row["label"] = slot.label
                row["stale"] = true; if !removed { failures.append(slot.label) }
                if removed && old["state"] as? String == "removed" { dismissed.insert(slot.id); continue }
                row["state"] = removed ? "removed" : rejected ? "invalid" : "unreachable"
                row["error"] = removed ? "Key removed" : rejected ? "Key no longer valid" : "Temporarily unreadable"
                rows.append(row)
            }
        }
        var teamRows = previous["team"] as? [JSON], teamProblem: HUDProblem?
        if let team = team {
            do {
                teamRows = try (listed ?? teamKeys(team)).map { $0.merging(["captured_at": now]) { _, new in new } }
                if let payload = try? http.get(URL(string: "https://openrouter.ai/api/v1/credits")!, token: team, headers: [:], limit: 1024 * 1024),
                   let total = number(dict(payload["data"])["total_credits"]), let used = number(dict(payload["data"])["total_usage"]) {
                    balances["openrouter"] = total - used; balanceCaptured = now
                }
            } catch let error as HTTPFailure {
                teamProblem = error.status == 401 || error.status == 403 ? HUDProblem("OpenRouter management key rejected", attention: true)
                    : HUDProblem("OpenRouter key list HTTP \(error.status)")
            } catch { teamProblem = error as? HUDProblem ?? HUDProblem("OpenRouter key list unavailable") }
        }
        let fresh = failures.count < rows.count || team != nil && teamProblem == nil
        // Nothing has ever worked: stay hidden rather than show an empty battery.
        if !fresh && previous.isEmpty { throw teamProblem ?? HUDProblem("No working OpenRouter key found") }
        try cache.write("openrouter.json", ["captured_at": fresh ? now : number(previous["captured_at"]) ?? 0,
                                           "checked_at": now, "balance_captured_at": balanceCaptured, "balances": balances, "rows": rows, "dismissed": Array(dismissed),
                                           "team": teamRows as Any? ?? NSNull(),
                                           "reading_source": fresh ? ReadingSource.providerAPI.rawValue : previous["reading_source"] ?? NSNull(),
                                           "source_read_at": fresh ? now : previous["source_read_at"] ?? NSNull()])
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
            rows.map { Self.keyCell($0, old: old, capturedAt: number(blob["captured_at"])) }.enumerated().sorted { ($0.element.left, $0.offset) < ($1.element.left, $1.offset) }.map { $0.element }
        }
        // Your own keys also appear in the team list; they show once, as yours.
        let own = Set((blob["rows"] as? [JSON] ?? []).compactMap { $0["key_label"] as? String })
        let mine = ranked(blob["rows"] as? [JSON] ?? []), team = ranked((blob["team"] as? [JSON] ?? []).filter { !own.contains($0["label"] as? String ?? "") })
        // Menu rows carry no percentage, so the battery keeps showing money.
        rows += mine.map { Window(label: $0.cell.label, right: $0.cell.right, expired: $0.cell.expired, stale: $0.cell.stale) }
        var title: String?
        if !team.isEmpty {
            let all = blob["team"] as? [JSON] ?? [], today = all.compactMap { number($0["usage_daily"]) }.reduce(0, +)
            let near = team.filter { $0.warning != nil }.count
            title = "\(all.count) keys · \(usd(today)) today" + (near > 0 ? " · \(near) near cap" : "")
            rows.append(Window(label: "Team", right: title, stale: old))
        }
        // Only your own keys pulse: a teammate reaching the cap they were given is the cap doing its job.
        let alert = mine.first { $0.warning != nil }.map { $0.cell.label + ": " + ($0.warning ?? "") }
        var panel = Panel(id: id, name: name, windows: rows, note: rows.isEmpty ? "Add an OpenRouter key; see PROVIDERS.md" : "", alert: alert,
                          cells: (mine + team).map { $0.cell }, cellsTitle: title)
        // The balance is the number; how full the body is says how close your tightest capped key is to its cap.
        var states: [String: String] = [:], names: [String: String] = [:]
        for row in blob["rows"] as? [JSON] ?? [] {
            guard let label = row["label"] as? String else { continue }
            let id = row["slot_id"] as? String ?? label
            states[id] = row["state"] as? String ?? (row["error"] is String ? "unreachable" : "ok"); names[id] = label
        }
        panel.keys = states; panel.keyNames = names
        panel.gauge = mine.filter { $0.cell.pct != nil }.map { $0.left }.min()
        return panel
    }
}
