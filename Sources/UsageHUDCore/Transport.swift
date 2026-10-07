import Foundation
import Darwin
import Security

/// The command-line tools the HUD talks to. An app opened from Finder or at login gets launchd's bare PATH, so the
/// usual install folders are searched here, and each CLI runs with its own folder on PATH so npm's `env node` resolves.
enum CLI {
    static func find(_ name: String, configured: String? = nil, home: URL = FileManager.default.homeDirectoryForCurrentUser,
                     environment: [String: String] = ProcessInfo.processInfo.environment) -> URL? {
        let nvm = home.appendingPathComponent(".nvm/versions/node")
        let versions = ((try? FileManager.default.contentsOfDirectory(atPath: nvm.path)) ?? [])
            .sorted { $0.compare($1, options: .numeric) == .orderedDescending }.map { nvm.path + "/" + $0 + "/bin" }
        let folders = [home.appendingPathComponent(".local/bin").path, "/opt/homebrew/bin", "/usr/local/bin"] +
            (environment["PATH"] ?? "").split(separator: ":").map(String.init) +
            [".npm-global/bin", ".bun/bin", ".volta/bin"].map { home.appendingPathComponent($0).path } + versions
        return ([configured].compactMap { $0 } + folders.map { $0 + "/" + name })
            .first { $0.hasPrefix("/") && FileManager.default.isExecutableFile(atPath: $0) }.map { URL(fileURLWithPath: $0) }
    }
    static func environment(for binary: URL, _ base: [String: String] = ProcessInfo.processInfo.environment) -> [String: String] {
        var environment = base, seen = Set<String>()
        let folders = [binary.deletingLastPathComponent().path, "/opt/homebrew/bin", "/usr/local/bin"] +
            (base["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin").split(separator: ":").map(String.init)
        environment["PATH"] = folders.filter { seen.insert($0).inserted }.joined(separator: ":")
        return environment
    }
}
/// Runs a provider's own sign-in command out of sight: the CLI opens the browser and returns once the user approves there.
/// `done` gets whether it worked and whether it ended within seconds, which means it wanted a terminal after all.
/// A sign-in left unfinished is stopped after ten minutes. Only these commands ever run.
public enum SignIn {
    public static let commands: Set<String> = ["claude auth login", "codex login", "grok login"]
    public static func start(_ command: String, done: @escaping (_ ok: Bool, _ quick: Bool) -> Void) -> Bool {
        guard commands.contains(command) else { return false }
        let words = command.split(separator: " ").map(String.init), env = ProcessInfo.processInfo.environment
        let configured = ["codex": env["USAGE_HUD_CODEX_CLI"] ?? Bundle.main.object(forInfoDictionaryKey: "UsageHUDCodexCLI") as? String,
                          "grok": env["USAGE_HUD_GROK_CLI"]][words[0]] ?? nil
        guard let binary = CLI.find(words[0], configured: configured) else { return false }
        let process = Process(), started = Date()
        process.executableURL = binary; process.arguments = Array(words.dropFirst())
        process.environment = CLI.environment(for: binary)
        process.standardInput = FileHandle.nullDevice; process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
        process.terminationHandler = { done($0.terminationStatus == 0, Date().timeIntervalSince(started) < 15) }
        guard (try? process.run()) != nil else { return false }
        DispatchQueue.global().asyncAfter(deadline: .now() + 600) { if process.isRunning { process.terminate() } }
        return true
    }
}
final class RPCProcess {
    let process = Process(), input = Pipe(), output = Pipe()
    let deadline: Date
    var buffered = Data()
    var errorMessage = "Codex quota unavailable; check codex login status"
    init(binary: URL, arguments: [String], environment: [String: String]? = nil, timeout: Double = 25) throws {
        deadline = Date().addingTimeInterval(timeout)
        process.executableURL = binary; process.arguments = arguments
        process.standardInput = input; process.standardOutput = output; process.standardError = FileHandle.nullDevice
        if let environment = environment { process.environment = environment }
        do { try process.run() } catch { throw HUDProblem("CLI unavailable: \(binary.lastPathComponent)") }
        // Only the child owns the write end; closing ours lets EOF be observed.
        try? output.fileHandleForWriting.close(); try? input.fileHandleForReading.close()
    }
    func stop() {
        try? input.fileHandleForWriting.close()
        if process.isRunning { process.terminate() }
        let end = Date().addingTimeInterval(1)
        while process.isRunning && Date() < end { usleep(10000) }
        if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        process.waitUntilExit(); try? output.fileHandleForReading.close()
    }
    deinit { stop() }
    func send(_ message: JSON) throws {
        // Grok's ACP server reads "x.ai/billing" literally, so slashes stay unescaped.
        var data = try JSONSerialization.data(withJSONObject: message, options: [.withoutEscapingSlashes]); data.append(10)
        do { try input.fileHandleForWriting.write(contentsOf: data) } catch { throw HUDProblem("CLI connection closed") }
    }
    func chunk() throws -> Data {
        while Date() < deadline {
            var item = pollfd(fd: output.fileHandleForReading.fileDescriptor, events: Int16(POLLIN | POLLHUP), revents: 0)
            let result = poll(&item, 1, Int32(max(1, min(1000, deadline.timeIntervalSinceNow * 1000))))
            if result < 0 && errno == EINTR { continue }
            guard result >= 0 else { throw HUDProblem("CLI pipe unavailable") }
            if result > 0 {
                var bytes = [UInt8](repeating: 0, count: 65536)
                let count = Darwin.read(item.fd, &bytes, bytes.count)
                guard count > 0 else { return Data() }
                return Data(bytes.prefix(count))
            }
        }
        throw HUDProblem("CLI request timed out")
    }
    func receive(_ id: Int) throws -> JSON {
        while Date() < deadline {
            while let end = buffered.firstIndex(of: 10) {
                let line = buffered[..<end]; buffered.removeSubrange(...end)
                guard let object = try? JSONSerialization.jsonObject(with: Data(line)) as? JSON else { continue }
                if number(object["id"]) == Double(id) {
                    if object["error"] != nil { throw HUDProblem(errorMessage) }
                    return dict(object["result"])
                }
            }
            let data = try chunk()
            guard !data.isEmpty else { throw HUDProblem("CLI connection closed") }
            buffered.append(data)
            guard buffered.count <= 4 * 1024 * 1024 else { throw HUDProblem("CLI response too large") }
        }
        throw HUDProblem("CLI request timed out")
    }
    func allOutput() throws -> Data {
        var result = Data()
        while true {
            let data = try chunk(); if data.isEmpty { break }
            result.append(data)
            guard result.count <= 1024 * 1024 else { throw HUDProblem("Credential response too large") }
        }
        return result
    }
}
protocol CredentialReading { func password(service: String, account: String?) throws -> String }
extension CredentialReading {
    /// nil when nothing is stored. A Keychain prompt still surfaces, so the caller backs off instead of asking again.
    func stored(service: String, account: String?) throws -> String? {
        do { return try password(service: service, account: account) }
        catch let problem as HUDProblem where problem.prompted { throw problem }
        catch { return nil }
    }
}
/// Reads through `security`. macOS shows an item's attributes to anyone without asking, but asks before handing over its
/// secret unless the user chose Always Allow. So each secret stays in memory beside the item's attributes and is fetched
/// again only when the item itself changed: someone who clicked Allow is asked once per change, not every refresh.
final class KeychainReader: CredentialReading {
    /// Runs `security` with these arguments, returning its output and how long it took.
    let run: ([String]) -> (text: String, seconds: Double)
    var memo: [String: (stamp: String, secret: String)] = [:]
    init(run: @escaping ([String]) -> (text: String, seconds: Double) = KeychainReader.security) { self.run = run }
    static func security(_ arguments: [String]) -> (text: String, seconds: Double) {
        let started = Date()
        guard let pipe = try? RPCProcess(binary: URL(fileURLWithPath: "/usr/bin/security"), arguments: arguments, timeout: 20) else { return ("", 0) }
        defer { pipe.stop() }
        let text = (try? pipe.allOutput()).flatMap { String(data: $0, encoding: .utf8) }?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return (text, Date().timeIntervalSince(started))
    }
    /// An answer, or why there is none: a missing item answers at once, while a slow empty answer means macOS asked
    /// (for the secret, or to unlock the keychain) and the user said no.
    func ask(_ arguments: [String]) throws -> String {
        let (text, seconds) = run(arguments)
        guard text.isEmpty else { return text }
        if seconds > 2 { throw HUDProblem("Keychain asked for your password; choose Refresh here, then Always Allow", prompted: true) }
        throw HUDProblem("Keychain credential unavailable", gone: true)
    }
    /// The item's persistent reference is kept (it names no secret) and survives the item's account being renamed, so a renamed
    /// account is followed to its new name instead of being taken for a deleted key.
    static func refsFile() -> URL { FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".usage-hud/keychain-refs.json") }
    func reference(service: String, account: String) -> Data? {
        var out: CFTypeRef?
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account,
                                    kSecReturnPersistentRef as String: true]
        return SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess ? out as? Data : nil
    }
    func renamed(service: String, account: String) -> String? {
        let url = Self.refsFile()
        let refs = (try? Data(contentsOf: url)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: String] } ?? [:]
        guard let text = refs[service + "\u{0}" + account], let data = Data(base64Encoded: text) else { return nil }
        var out: CFTypeRef?
        let query: [String: Any] = [kSecValuePersistentRef as String: data, kSecReturnAttributes as String: true]
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess, let attributes = out as? [String: Any],
              let now = attributes[kSecAttrAccount as String] as? String, now != account else { return nil }
        return now
    }
    func remember(service: String, account: String) {
        guard let data = reference(service: service, account: account) else { return }
        let url = Self.refsFile()
        var refs = (try? Data(contentsOf: url)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: String] } ?? [:]
        let key = service + "\u{0}" + account
        guard refs[key] != data.base64EncodedString() else { return }
        refs[key] = data.base64EncodedString()
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try? JSONSerialization.data(withJSONObject: refs).write(to: url, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
    var followed: [String: String] = [:]
    func password(service: String, account: String?) throws -> String {
        guard let account = account else { return try lookup(service: service, account: nil) }
        let original = account
        do {
            let secret = try lookup(service: service, account: followed[service + "\u{0}" + original] ?? original)
            if followed[service + "\u{0}" + original] == nil { remember(service: service, account: original) }
            return secret
        } catch let problem as HUDProblem where problem.gone {
            guard let now = renamed(service: service, account: original) else { throw problem }
            followed[service + "\u{0}" + original] = now
            return try lookup(service: service, account: now)
        }
    }
    func lookup(service: String, account: String?) throws -> String {
        let arguments = ["find-generic-password", "-s", service] + (account.map { ["-a", $0] } ?? [])
        let stamp = try ask(arguments), key = arguments.joined(separator: "\u{0}")
        if let known = memo[key], known.stamp == stamp { return known.secret }
        let secret = try ask(arguments + ["-w"])
        memo[key] = (stamp, secret)
        return secret
    }
}
protocol HTTPReading {
    func get(_ url: URL, token: String, headers: [String: String], limit: Int) throws -> JSON
    func post(_ url: URL, token: String, headers: [String: String], body: JSON, limit: Int) throws -> JSON
    /// One response header, for the APIs that answer there (Fireworks names a key's account that way).
    func header(_ url: URL, token: String, name: String) throws -> String?
}
struct HTTPFailure: Error { let status: Int }
/// Credentials never follow a redirect. Stop receiving as soon as the body exceeds its bound.
final class ResponseBox: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    let limit: Int, semaphore = DispatchSemaphore(value: 0)
    var data = Data(), response: HTTPURLResponse?, error: Error?
    init(limit: Int) { self.limit = limit }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        self.response = response as? HTTPURLResponse
        if response.expectedContentLength > Int64(limit) {
            error = HUDProblem("Usage response too large"); completionHandler(.cancel)
        } else { completionHandler(.allow) }
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard data.count <= limit - self.data.count else {
            error = HUDProblem("Usage response too large"); dataTask.cancel(); return
        }
        self.data.append(data)
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        self.error = self.error ?? error; semaphore.signal()
    }
}
struct HTTPReader: HTTPReading {
    func get(_ url: URL, token: String, headers: [String: String] = [:], limit: Int = 8 * 1024 * 1024) throws -> JSON {
        try send(URLRequest(url: url, timeoutInterval: 25), token: token, headers: headers, limit: limit)
    }
    func post(_ url: URL, token: String, headers: [String: String] = [:], body: JSON, limit: Int = 8 * 1024 * 1024) throws -> JSON {
        var request = URLRequest(url: url, timeoutInterval: 25)
        request.httpMethod = "POST"; request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        return try send(request, token: token, headers: headers, limit: limit)
    }
    func header(_ url: URL, token: String, name: String) throws -> String? {
        try exchange(URLRequest(url: url, timeoutInterval: 25), token: token, headers: [:], limit: 1024 * 1024).response.value(forHTTPHeaderField: name)
    }
    private func send(_ request: URLRequest, token: String, headers: [String: String], limit: Int) throws -> JSON {
        guard let result = try JSONSerialization.jsonObject(with: exchange(request, token: token, headers: headers, limit: limit).data) as? JSON else {
            throw HUDProblem("Invalid usage response")
        }
        return result
    }
    private func exchange(_ original: URLRequest, token: String, headers: [String: String], limit: Int) throws -> (data: Data, response: HTTPURLResponse) {
        var request = original
        request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil; config.urlCache = nil
        config.timeoutIntervalForResource = 30
        config.httpShouldSetCookies = false
        guard limit >= 0 else { throw HUDProblem("Invalid response limit") }
        let box = ResponseBox(limit: limit)
        let session = URLSession(configuration: config, delegate: box, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let task = session.dataTask(with: request)
        task.resume()
        guard box.semaphore.wait(timeout: .now() + 30) == .success else { task.cancel(); throw HUDProblem("Usage request timed out") }
        if let problem = box.error as? HUDProblem { throw problem }
        guard box.error == nil, let response = box.response else { throw HUDProblem("Usage connection failed") }
        guard (200..<300).contains(response.statusCode) else { throw HTTPFailure(status: response.statusCode) }
        return (box.data, response)
    }
}
