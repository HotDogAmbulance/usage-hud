import Foundation

/// Claude Code renews its own sign-in only when it makes a request, so after about eight hours without a terminal session the
/// credential Usage HUD reads is expired. When that happens, and only then, the person's own `claude` makes one small request
/// (the cheapest model, no tools, nothing saved) so it renews itself; Usage HUD never touches the token or the Keychain.
/// It does not matter whether `claude` is running: a running Claude Code renews its own credential on every request, and the Desktop app keeps idle `claude` processes open that would otherwise block this. It is rare, announced each time, written to `~/.usage-hud/renewals.log`, and stops after three in a row with no real use.
/// Opt out with `touch ~/.usage-hud/no-auto-renew`.
public final class ClaudeRenewal {
    public typealias Runner = (_ executable: URL, _ arguments: [String], _ directory: URL) -> (status: Int32, output: Data)
    /// After a renewal the credential lasts about eight hours, so nothing needed is held back; after a failure, try again in half an hour.
    public static let minimumGap: Double = 6 * 3600, retryGap: Double = 1800
    public static let unattendedLimit = 3
    let home: URL, run: Runner, now: () -> Double
    var state: URL { home.appendingPathComponent(".usage-hud/claude-renewal.json") }
    var log: URL { home.appendingPathComponent(".usage-hud/renewals.log") }
    var workDirectory: URL { home.appendingPathComponent(".usage-hud/renew") }

    public init(home: URL = FileManager.default.homeDirectoryForCurrentUser, run: @escaping Runner = ClaudeRenewal.process,
                now: @escaping () -> Double = { Date().timeIntervalSince1970 }
) {
        self.home = home; self.run = run; self.now = now
    }
    public static func process(_ executable: URL, _ arguments: [String], _ directory: URL) -> (status: Int32, output: Data) {
        let task = Process(), pipe = Pipe()
        task.executableURL = executable; task.arguments = arguments; task.currentDirectoryURL = directory
        task.standardOutput = pipe; task.standardError = FileHandle.nullDevice; task.standardInput = FileHandle.nullDevice
        do { try task.run() } catch { return (-1, Data()) }
        let deadline = Date().addingTimeInterval(90)
        var data = Data(); let reading = DispatchGroup()
        reading.enter()
        DispatchQueue.global().async { data = pipe.fileHandleForReading.readDataToEndOfFile(); reading.leave() }
        while task.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.2) }
        if task.isRunning { task.terminate(); return (-2, Data()) }
        _ = reading.wait(timeout: .now() + 2)
        return (task.terminationStatus, data)
    }
    func executable() -> URL? {
        ["/opt/homebrew/bin/claude", "/usr/local/bin/claude", home.path + "/.local/bin/claude", home.path + "/.claude/local/claude"]
            .map { URL(fileURLWithPath: $0) }.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }
    func saved() -> JSON { (try? Data(contentsOf: state)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? JSON } ?? [:] }
    func save(_ values: JSON) {
        try? FileManager.default.createDirectory(at: state.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        if let data = try? JSONSerialization.data(withJSONObject: values) { try? data.write(to: state, options: .atomic) }
    }
    func note(_ line: String) {
        let text = ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: now())) + " " + line + "\n"
        guard let data = text.data(using: .utf8) else { return }
        if let handle = try? FileHandle(forWritingTo: log) { handle.seekToEndOfFile(); handle.write(data); try? handle.close() }
        else { try? data.write(to: log) }
    }
    /// Claude Code names a project's folder after its path, with every `/` and `.` as `-`.
    func leftovers() -> Int {
        let name = workDirectory.path.map { $0 == "/" || $0 == "." ? "-" : String($0) }.joined()
        let folder = home.appendingPathComponent(".claude/projects/" + name)
        guard folder.deletingLastPathComponent().lastPathComponent == "projects", FileManager.default.fileExists(atPath: folder.path) else { return 0 }
        let count = (FileManager.default.enumerator(atPath: folder.path)?.allObjects.count ?? 0) + 1
        try? FileManager.default.removeItem(at: folder)
        return count
    }
    /// The quota Claude Code reported during the call, stored like a statusline reading but marked as coming from this call, so it
    /// never counts as someone using Claude Code.
    func recordQuota(_ event: JSON?) {
        let windows = dict(dict(event?["rate_limit_info"])["unifiedWindows"])
        var saved: JSON = [:]
        for (key, raw) in windows where ["five_hour", "seven_day"].contains(key) {
            let window = dict(raw)
            guard let used = number(window["utilization"]) else { continue }
            saved[key] = ["used_percentage": max(0, min(100, used * 100)), "resets_at": number(window["resetsAt"]) as Any? ?? NSNull()]
        }
        guard !saved.isEmpty else { return }
        try? Cache(home.appendingPathComponent(".usage-hud")).quota("claude.json", windows: saved, extra: ["source": "claude-run", "reading_source": "claude-statusline"], now: now())
    }
    /// A notice to show when a renewal ran, or nil when nothing was due or it could not be done. `lastRealUse` is when Claude Code
    /// last reported through its statusline (seconds since 1970), which clears the count of renewals made without anyone present.
    public func renewIfDue(lastRealUse: Double) -> SourceNotice? {
        guard !FileManager.default.fileExists(atPath: home.appendingPathComponent(".usage-hud/no-auto-renew").path) else { return nil }
        var values = saved()
        let attempted = (values["last_attempt"] as? NSNumber)?.doubleValue ?? 0, succeeded = (values["last_ok"] as? NSNumber)?.doubleValue ?? 0
        var alone = (values["unattended"] as? NSNumber)?.intValue ?? 0
        if lastRealUse > succeeded { alone = 0 }
        let gap = attempted > succeeded ? Self.retryGap : Self.minimumGap
        guard now() - attempted >= gap, alone < Self.unattendedLimit else { return nil }
        values["last_attempt"] = now(); values["unattended"] = alone; save(values)
        guard let claude = executable() else { note("skipped: no claude command found"); return nil }
        try? FileManager.default.createDirectory(at: workDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let result = run(claude, ["-p", "Reply with the single word OK", "--model", "haiku", "--no-session-persistence", "--setting-sources", "local",
                                  "--tools", "", "--disable-slash-commands", "--output-format", "stream-json", "--verbose"], workDirectory)
        let removed = leftovers()
        // One JSON object per line: the final `result`, and a `rate_limit_event` with the quota Claude Code itself was told.
        let events = String(decoding: result.output, as: UTF8.self).split(separator: "\n").compactMap {
            (try? JSONSerialization.jsonObject(with: Data($0.utf8))) as? JSON
        }
        let reply = events.last { $0["type"] as? String == "result" }
        recordQuota(events.last { $0["type"] as? String == "rate_limit_event" })
        guard result.status == 0, reply?["is_error"] as? Bool == false else {
            note("renewal failed (exit \(result.status)); removed \(removed) leftover item(s); trying again in 30 minutes")
            return nil
        }
        let usage = reply?["usage"] as? JSON ?? [:]
        let tokens = ["input_tokens", "output_tokens", "cache_creation_input_tokens", "cache_read_input_tokens"].reduce(0) { $0 + ((usage[$1] as? NSNumber)?.intValue ?? 0) }
        values["last_ok"] = now(); values["unattended"] = alone + 1; save(values)
        note("renewed with one Claude Code call (haiku, \(tokens) tokens); removed \(removed) leftover item(s) from ~/.claude/projects")
        return SourceNotice(title: "Claude sign-in renewed",
                            lines: ["It had expired, so Claude Code made one tiny request (\(tokens) tokens, nothing saved). See ~/.usage-hud/renewals.log."])
    }
}
