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
    func panel() -> Panel {
        let rows = quotaWindows(cache.read("antigravity.json")).sorted {
            if $0.pct == $1.pct { return $0.label < $1.label }
            return ($0.pct ?? 0) > ($1.pct ?? 0)
        }
        let cells = rows.map { row -> Window in
            var text = "\(Int((100 - (row.pct ?? 0)).rounded()))% remaining"
            if let reset = row.resets_at, reset > Date().timeIntervalSince1970 {
                let minutes = Int((reset - Date().timeIntervalSince1970) / 60)
                text += " · \(minutes / 60)h \(minutes % 60)m"
            }
            if row.stale == true || row.expired == true { text += " · cached" }
            return Window(label: row.label, pct: row.pct, right: text, resets_at: row.resets_at,
                          expired: row.expired, stale: row.stale)
        }
        return Panel(id: id, name: name, windows: rows, note: "Model quotas · requires Antigravity running",
                     cells: cells, cellsTitle: "\(rows.count) models · click for all quotas")
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
            throw HUDProblem("Open Antigravity and sign in to read its quota", attention: true)
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
