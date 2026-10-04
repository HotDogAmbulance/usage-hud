import Foundation
import CoreFoundation

struct UsageCost {
    let amount: Decimal
    let conservative: Bool
    let requests: Int
}
final class OpenAICredits {
    let cache: Cache, credentials: CredentialReading, http: HTTPReading
    var token: String?, selector: String?
    init(cache: Cache, credentials: CredentialReading, http: HTTPReading) {
        self.cache = cache; self.credentials = credentials; self.http = http
    }
    static func integer(_ value: Any?, _ name: String) throws -> Int {
        guard let n = number(value), n >= 0, n < Double(Int.max), n.rounded(.towardZero) == n else {
            throw HUDProblem("Invalid usage field: " + name)
        }
        return Int(n)
    }
    static func usageCost(_ result: JSON) throws -> UsageCost {
        guard result["model"] as? String == "gpt-6-astra" else { throw HUDProblem("Unsupported priced model") }
        var batch = false
        if let value = result["batch"], !(value is NSNull) {
            guard let boolean = value as? NSNumber, CFGetTypeID(boolean) == CFBooleanGetTypeID() else { throw HUDProblem("Invalid batch value") }
            batch = boolean.boolValue
        }
        let tier = result["service_tier"] as? String
        let multiplier: Decimal
        if batch || tier == "flex" || tier == "flex-tier" { multiplier = Decimal(string: "0.5")! }
        else if tier == nil || ["default", "standard", "auto"].contains(tier!) { multiplier = 1 }
        else { throw HUDProblem("Unsupported service tier") }
        let cached = try integer(result["input_cached_tokens"] ?? 0, "input_cached_tokens")
        let written = try integer(result["input_cache_write_tokens"] ?? 0, "input_cache_write_tokens")
        let uncached: Int, total: Int
        if let raw = result["input_uncached_tokens"], !(raw is NSNull) {
            uncached = try integer(raw, "input_uncached_tokens")
            total = try integer(result["input_tokens"] ?? (Double(uncached) + Double(cached) + Double(written)), "input_tokens")
        } else {
            total = try integer(result["input_tokens"], "input_tokens")
            guard Double(cached) + Double(written) <= Double(total) else { throw HUDProblem("Input components exceed total") }
            uncached = total - cached - written
        }
        let output = try integer(result["output_tokens"] ?? 0, "output_tokens")
        let requests = try integer(result["num_model_requests"] ?? 0, "num_model_requests")
        guard requests > 0 || (total == 0 && output == 0) else { throw HUDProblem("Usage tokens without a request") }
        let long = total > 272000
        let inputScale: Decimal = long ? 2 : 1, outputScale: Decimal = long ? Decimal(string: "1.5")! : 1
        // Retained accounting tariff; unsupported models/tiers fail closed.
        let inputCost = (Decimal(uncached) * 10 + Decimal(cached) + Decimal(written) * Decimal(string: "12.5")!) * inputScale
        let cost = (inputCost + Decimal(output) * 50 * outputScale) * multiplier / 1000000
        return UsageCost(amount: cost, conservative: long && requests > 1, requests: requests)
    }
    func pages(path: String, start: Int, end: Int, usage: Bool, token: String) throws -> (Decimal, Int, Bool, Int) {
        var total: Decimal = 0, coverage = start, conservative = false, requests = 0
        var page: String?, seen = Set<String>()
        for _ in 0..<1000 {
            var components = URLComponents(string: "https://api.openai.com/v1/organization/" + path)!
            var query = [URLQueryItem(name: "start_time", value: String(start)), URLQueryItem(name: "end_time", value: String(end)),
                         URLQueryItem(name: "bucket_width", value: usage ? "1m" : "1d"), URLQueryItem(name: "limit", value: usage ? "1440" : "180")]
            if usage { query += ["model", "batch", "service_tier"].map { URLQueryItem(name: "group_by", value: $0) } }
            if let page = page { query.append(URLQueryItem(name: "page", value: page)) }
            components.queryItems = query
            let payload = try http.get(components.url!, token: token, headers: [:], limit: usage ? 8 * 1024 * 1024 : 4 * 1024 * 1024)
            guard let buckets = payload["data"] as? [JSON] else { throw HUDProblem("Credit response missing data") }
            for bucket in buckets {
                guard let results = bucket["results"] as? [JSON] else { throw HUDProblem("Credit bucket missing results") }
                if usage { coverage = max(coverage, try Self.integer(bucket["end_time"], "end_time")) }
                for result in results {
                    if usage {
                        let cost = try Self.usageCost(result)
                        total += cost.amount; conservative = conservative || cost.conservative; requests += cost.requests
                    } else {
                        let amount = dict(result["amount"])
                        guard (amount["currency"] as? String)?.lowercased() == "usd", let n = number(amount["value"]),
                              let value = Decimal(string: String(n), locale: Locale(identifier: "en_US_POSIX")) else { throw HUDProblem("Invalid USD cost amount") }
                        total += value
                    }
                }
            }
            if payload["has_more"] as? Bool != true { return (total, coverage, conservative, requests) }
            guard let next = payload["next_page"] as? String, !next.isEmpty, seen.insert(next).inserted else { throw HUDProblem("Invalid credit pagination") }
            page = next
        }
        throw HUDProblem("Too many credit pages")
    }
    func refresh() throws {
        do {
            let source = dict(cache.read("credits.json")["openai"]), previous = cache.read("codex.json")
            guard let service = source["service"] as? String, !service.isEmpty,
                  let account = source["account"] as? String, !account.isEmpty else { throw HUDProblem("Configure credits.json first") }
            let explicitSeed = number(source["balance_seed_usd"]), explicitAt = number(source["balance_seed_at"])
            let seeded = explicitSeed != nil && explicitAt != nil
            let seed = seeded ? explicitSeed : number(previous["balance_seed_usd"]) ?? number(previous["balance"])
            let at = seeded ? explicitAt : number(previous["balance_seed_at"]) ?? number(previous["captured_at"])
            let now = Int(Date().timeIntervalSince1970)
            guard let seed = seed, seed >= 0, let at = at, at > 0, at < Double(now) else { throw HUDProblem("Invalid balance seed") }
            let selected = service + ":" + account
            if token == nil || selector != selected { token = try credentials.password(service: service, account: account); selector = selected }
            let settled = try pages(path: "costs", start: Int(at), end: now, usage: false, token: token!).0
            let usage = try pages(path: "usage/completions", start: Int(at), end: now, usage: true, token: token!)
            let spent = max(settled, usage.0), balance = Decimal(string: String(seed))! - spent
            try cache.merge("codex.json", ["captured_at": Date().timeIntervalSince1970, "balance": NSDecimalNumber(decimal: balance),
                "currency": "USD", "manual": false, "estimated": true, "live_estimate": true,
                "balance_seed_usd": seed, "balance_seed_at": Int(at), "spent_since_seed": NSDecimalNumber(decimal: spent),
                "settled_spend": NSDecimalNumber(decimal: settled), "usage_estimated_spend": NSDecimalNumber(decimal: usage.0),
                "usage_coverage_end": usage.1, "usage_request_count": usage.3, "conservative_long_context": usage.2,
                "pricing_revision": "gpt-6-astra-2026-09-08", "source": "organization_costs_plus_server_usage", "error": NSNull()])
        } catch {
            if let failure = error as? HTTPFailure, failure.status == 401 || failure.status == 403 { token = nil; selector = nil }
            let message = (error as? HUDProblem)?.message ?? (error as? HTTPFailure).map { "Credit HTTP \($0.status)" } ?? "Credit refresh failed"
            try? cache.merge("codex.json", ["error": message]); throw HUDProblem(message)
        }
    }
    func row() -> Window? {
        let blob = cache.read("codex.json")
        guard let balance = number(blob["balance"]) else { return nil }
        if let error = blob["error"] as? String { return Window(label: "OpenAI API", right: usd(balance) + " · " + error, stale: true) }
        let text = usd(balance) + (blob["manual"] as? Bool == true ? " · set by hand" : blob["live_estimate"] as? Bool == true ? " · estimate" : "")
        let expiry: Double = blob["live_estimate"] as? Bool == true ? 600 : 21600
        return Window(label: "OpenAI API", right: text, stale: Date().timeIntervalSince1970 - (number(blob["captured_at"]) ?? 0) > expiry)
    }
}
