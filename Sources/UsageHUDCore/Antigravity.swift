import Foundation
import Security

/// Reads the running app's loopback service. Google credentials remain owned by Antigravity.
final class AntigravityProvider: UsageProvider {
    let id = "antigravity", name = "Antigravity", automatic = true
    let cache: Cache
    let read: () throws -> JSON
    init(cache: Cache, read: @escaping () throws -> JSON = AntigravityLocal.read) {
        self.cache = cache; self.read = read
    }
    func shown() -> Bool { !cache.read("antigravity.json").isEmpty }
    static func windows(_ response: JSON) throws -> JSON {
        let status = dict(response["userStatus"])
        var result: JSON = [:]
        for model in dict(status["cascadeModelConfigData"])["clientModelConfigs"] as? [JSON] ?? [] {
            let quota = dict(model["quotaInfo"])
            guard let remaining = number(quota["remainingFraction"]), remaining.isFinite,
                  (0...1).contains(remaining), let label = model["label"] as? String, !label.isEmpty else { continue }
            result[label] = ["used_percentage": (1 - remaining) * 100,
                             "resets_at": resetTime(quota["resetTime"]) as Any? ?? NSNull()]
        }
        guard !result.isEmpty else { throw HUDProblem("Antigravity returned no model quota; check its sign-in", attention: true) }
        return result
    }
    func refresh() throws {
        let response = try read()
        try cache.write("antigravity.json", ["captured_at": Date().timeIntervalSince1970,
                                            "rate_limits": Self.windows(response)])
    }
    /// "Claude Opus 4.6 (Thinking)" belongs to Claude, "GPT-OSS 120B" to GPT.
    static func family(_ model: String) -> String {
        let word = model.split(separator: " ").first.map(String.init) ?? model
        return word.hasPrefix("GPT") ? "GPT" : word
    }
    /// Models that draw on one quota report the same share left and the same reset, so each pool is one row, named by
    /// the families in it ("Gemini", "Claude & GPT"); a model with a quota of its own keeps its name. Plans that give
    /// every model its own quota just yield more rows, and once there are many, untouched ones fold into one.
    func panel() -> Panel {
        let models = quotaWindows(cache.read("antigravity.json")), now = Date().timeIntervalSince1970
        func text(_ row: Window, models count: Int) -> String {
            var text = "\(Int((100 - (row.pct ?? 0)).rounded()))% left"
            if let reset = row.resets_at, reset > now { text += " · resets in " + countdown(reset - now) }
            if count > 1 { text += " · \(count) models" }
            return text + (row.stale == true || row.expired == true ? " · cached" : "")
        }
        var pools: [String: [Window]] = [:], order: [String] = []
        for model in models.sorted(by: { $0.label < $1.label }) {
            let key = "\(Int((model.pct ?? 0).rounded()))|\(Int((model.resets_at ?? 0) / 600))"
            if pools[key] == nil { order.append(key) }
            pools[key, default: []].append(model)
        }
        var rows = order.compactMap { pools[$0] }.map { members -> Window in
            var families: [String] = []
            for model in members where !families.contains(Self.family(model.label)) { families.append(Self.family(model.label)) }
            let first = members[0]
            return Window(label: members.count == 1 ? first.label : families.joined(separator: " & "), pct: first.pct,
                          right: text(first, models: members.count), resets_at: first.resets_at, expired: first.expired, stale: first.stale)
        }.enumerated().sorted { ($0.element.pct ?? 0, -$0.offset) > ($1.element.pct ?? 0, -$1.offset) }.map { $0.element }
        let untouched = rows.filter { ($0.pct ?? 0) < 0.5 }
        if rows.count > 4 && untouched.count > 1 {
            let count = models.filter { ($0.pct ?? 0) < 0.5 }.count
            rows = rows.filter { ($0.pct ?? 0) >= 0.5 } + [Window(label: "Other models", pct: 0, right: "100% left · \(count) models",
                                                                  stale: untouched.contains { $0.stale == true })]
        }
        let details = models.sorted { ($0.pct ?? 0, $1.label) > ($1.pct ?? 0, $0.label) }.map {
            Window(label: $0.label, pct: $0.pct, right: text($0, models: 1), resets_at: $0.resets_at, expired: $0.expired, stale: $0.stale)
        }
        return Panel(id: id, name: name, windows: rows, note: "Model quotas · updates while Antigravity is open",
                     cells: rows, cellsTitle: "\(models.count) models · \(rows.count) quota \(rows.count == 1 ? "pool" : "pools") · click for every model",
                     details: details, lead: rows.first?.label)
    }
}

enum AntigravityLocal {
    static func command(_ path: String, _ arguments: [String]) throws -> String {
        let process = try RPCProcess(binary: URL(fileURLWithPath: path), arguments: arguments, timeout: 5)
        defer { process.stop() }
        return String(decoding: try process.allOutput(), as: UTF8.self)
    }
    static func flag(_ name: String, in arguments: String) -> String? {
        let pattern = "(?:^|\\s)" + NSRegularExpression.escapedPattern(for: name) + "(?:=|\\s+)([^\\s]+)"
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: arguments, range: NSRange(arguments.startIndex..., in: arguments)),
              let range = Range(match.range(at: 1), in: arguments) else { return nil }
        return String(arguments[range])
    }
    static func read() throws -> JSON {
        let processes = try command("/bin/ps", ["-axo", "pid=,comm="])
        let candidates = processes.split(separator: "\n").compactMap { line -> String? in
            let parts = line.trimmingCharacters(in: .whitespaces).split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
            guard parts.count == 2, Int(parts[0]) != nil,
                  parts[1].hasSuffix("/Antigravity.app/Contents/Resources/bin/language_server") else { return nil }
            return String(parts[0])
        }
        guard candidates.count == 1, let pid = candidates.first else {
            // Closing the app is normal, not a fault: the battery dims with its last reading instead of pulsing.
            // Removing it takes the battery away.
            let home = FileManager.default.homeDirectoryForCurrentUser.path
            let installed = ["/Applications", home + "/Applications"].contains { FileManager.default.fileExists(atPath: $0 + "/Antigravity.app") }
            throw HUDProblem(installed ? "Open Antigravity to update its quota" : "Antigravity isn't installed", gone: !installed)
        }
        let arguments = try command("/bin/ps", ["-p", pid, "-o", "args="])
        guard let csrf = flag("--csrf_token", in: arguments), !csrf.isEmpty else {
            throw HUDProblem("Antigravity local session unavailable")
        }
        let listeners = try command("/usr/sbin/lsof", ["-nP", "-a", "-p", pid, "-iTCP", "-sTCP:LISTEN"])
        let regex = try NSRegularExpression(pattern: "127\\.0\\.0\\.1:(\\d+)")
        let ports = regex.matches(in: listeners, range: NSRange(listeners.startIndex..., in: listeners)).compactMap {
            Range($0.range(at: 1), in: listeners).flatMap { Int(listeners[$0]) }
        }.filter { (1...65535).contains($0) }
        for port in Set(ports).sorted() {
            if let response = try? request(port: port, csrf: csrf), response["userStatus"] != nil { return response }
        }
        throw HUDProblem("Antigravity quota unavailable; keep the app open and retry")
    }
    private static func request(port: Int, csrf: String) throws -> JSON {
        let url = URL(string: "https://127.0.0.1:\(port)/exa.language_server_pb.LanguageServerService/GetUserStatus")!
        var request = URLRequest(url: url, timeoutInterval: 4)
        request.httpMethod = "POST"; request.httpBody = Data("{}".utf8)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("1", forHTTPHeaderField: "Connect-Protocol-Version")
        request.setValue(csrf, forHTTPHeaderField: "X-Codeium-Csrf-Token")
        let config = URLSessionConfiguration.ephemeral
        config.connectionProxyDictionary = [:]; config.httpShouldSetCookies = false; config.urlCache = nil
        let delegate = LocalSession(port: port)
        let session = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let result = LocalResult(), semaphore = DispatchSemaphore(value: 0)
        session.dataTask(with: request) { data, response, _ in
            if let data = data, data.count <= 1024 * 1024,
               (response as? HTTPURLResponse)?.statusCode == 200 {
                result.value = (try? JSONSerialization.jsonObject(with: data)) as? JSON
            }
            semaphore.signal()
        }.resume()
        guard semaphore.wait(timeout: .now() + 5) == .success, let value = result.value else {
            throw HUDProblem("Antigravity local quota request failed")
        }
        return value
    }
}

private final class LocalResult: @unchecked Sendable { var value: JSON? }
/// Trust is relaxed only for the selected process's loopback port; redirects are forbidden.
private final class LocalSession: NSObject, URLSessionTaskDelegate {
    let port: Int
    init(port: Int) { self.port = port }
    func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        guard challenge.protectionSpace.host == "127.0.0.1", challenge.protectionSpace.port == port,
              challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust else {
            completionHandler(.cancelAuthenticationChallenge, nil); return
        }
        completionHandler(.useCredential, URLCredential(trust: trust))
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
