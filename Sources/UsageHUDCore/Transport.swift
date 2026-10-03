import Foundation
import Darwin

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
struct KeychainReader: CredentialReading {
    func password(service: String, account: String?) throws -> String {
        var args = ["find-generic-password", "-s", service]
        if let account = account { args += ["-a", account] }
        args.append("-w")
        let pipe = try RPCProcess(binary: URL(fileURLWithPath: "/usr/bin/security"), arguments: args, timeout: 30)
        defer { pipe.stop() }
        let data = try pipe.allOutput()
        let text = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !text.isEmpty else { throw HUDProblem("Keychain credential unavailable") }
        return text
    }
}
protocol HTTPReading {
    func get(_ url: URL, token: String, headers: [String: String], limit: Int) throws -> JSON
    func post(_ url: URL, token: String, headers: [String: String], body: JSON, limit: Int) throws -> JSON
}
struct HTTPFailure: Error { let status: Int }
final class ResponseBox: @unchecked Sendable {
    var data: Data?; var response: URLResponse?; var error: Error?
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
    private func send(_ original: URLRequest, token: String, headers: [String: String], limit: Int) throws -> JSON {
        var request = original
        request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil; config.urlCache = nil
        config.timeoutIntervalForResource = 30
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        let semaphore = DispatchSemaphore(value: 0), box = ResponseBox()
        let task = session.dataTask(with: request) { data, response, error in
            box.data = data; box.response = response; box.error = error; semaphore.signal()
        }
        task.resume()
        guard semaphore.wait(timeout: .now() + 30) == .success else { task.cancel(); throw HUDProblem("Usage request timed out") }
        guard box.error == nil, let response = box.response as? HTTPURLResponse else { throw HUDProblem("Usage connection failed") }
        guard (200..<300).contains(response.statusCode) else { throw HTTPFailure(status: response.statusCode) }
        guard let data = box.data, data.count <= limit,
              let result = try JSONSerialization.jsonObject(with: data) as? JSON else { throw HUDProblem("Invalid usage response") }
        return result
    }
}
