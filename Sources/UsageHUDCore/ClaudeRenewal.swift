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
    let home: URL, directory: URL, run: Runner, now: () -> Double
    var state: URL { directory.appendingPathComponent("claude-renewal.json") }
    var log: URL { directory.appendingPathComponent("renewals.log") }
    var workDirectory: URL { directory.appendingPathComponent("renew") }
    var optOut: URL { directory.appendingPathComponent("no-auto-renew") }

    /// `directory` is where Usage HUD keeps its files (`~/.usage-hud`), the same one its cache uses.
    public init(home: URL = FileManager.default.homeDirectoryForCurrentUser, directory: URL? = nil, run: @escaping Runner = ClaudeRenewal.process,
                now: @escaping () -> Double = { Date().timeIntervalSince1970 }
) {
        self.home = home; self.directory = directory ?? home.appendingPathComponent(".usage-hud"); self.run = run; self.now = now
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
    /// One read-modify-write at a time: a hook noting use must not be undone by a renewal saving its own count a moment later.
    private let lock = NSLock()
    func update(_ change: (inout JSON) -> Void) {
        lock.lock(); defer { lock.unlock() }
        var values = saved(); change(&values); save(values)
    }
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
        try? Cache(directory).quota("claude.json", windows: saved, extra: ["source": "claude-run", "reading_source": "claude-statusline"], now: now())
    }
    /// Claude Code ran (its hooks fire in a terminal and in the Code tab of the Claude app alike): someone is using it, which
    /// clears the count of renewals made with nobody present. Written at most once a minute.
    public func noteUse() {
        guard now() - ((saved()["last_use"] as? NSNumber)?.doubleValue ?? 0) >= 60 else { return }
        update { $0["last_use"] = now() }
    }
    /// When Claude Code last reported through its statusline, which only a terminal session runs.
    public static func statuslineUse(_ blob: [String: Any]) -> Double {
        blob["source"] as? String == "statusline" ? number(blob["captured_at"]) ?? 0 : 0
    }
    public enum State { case ready, paused, off }
    /// Whether a renewal may run when one is due: `off` after the opt-out, `paused` after three renewals in a row with no use of
    /// Claude Code since, otherwise `ready`. `lastRealUse` is the statusline's last reading.
    public func state(lastRealUse: Double) -> State {
        guard !FileManager.default.fileExists(atPath: optOut.path) else { return .off }
        let values = saved()
        let succeeded = (values["last_ok"] as? NSNumber)?.doubleValue ?? 0, alone = (values["unattended"] as? NSNumber)?.intValue ?? 0
        let used = max(lastRealUse, (values["last_use"] as? NSNumber)?.doubleValue ?? 0)
        return alone >= Self.unattendedLimit && used <= succeeded ? .paused : .ready
    }
    /// What an expired sign-in says, as the person can act on it. Plain chat (claude.ai, the Chat tab) never counts: only a
    /// message sent to Claude Code does.
    public static func expiredMessage(_ state: State) -> String {
        switch state {
        case .ready: return "Claude Code credential expired; it renews with one small Claude Code call, or run claude once in a terminal"
        case .paused: return "Claude Code credential expired. Usage HUD stopped renewing it after 3 renewals in a row while Claude Code sat unused. "
            + "Send one message in Claude Code (claude in a terminal, or the Code tab of the Claude app) and it carries on; chat in claude.ai or the Chat tab does not count"
        case .off: return "Claude Code credential expired and automatic renewal is off. Send one message in Claude Code (claude in a terminal) to renew it"
        }
    }
    /// A notice to show when a renewal ran, or nil when nothing was due or it could not be done. `lastRealUse` is when Claude Code
    /// last reported through its statusline (seconds since 1970); a hook seen by `noteUse` counts the same. Either clears the count
    /// of renewals made without anyone present.
    public func renewIfDue(lastRealUse: Double) -> SourceNotice? {
        guard !FileManager.default.fileExists(atPath: optOut.path) else { return nil }
        let values = saved()
        let attempted = (values["last_attempt"] as? NSNumber)?.doubleValue ?? 0, succeeded = (values["last_ok"] as? NSNumber)?.doubleValue ?? 0
        var alone = (values["unattended"] as? NSNumber)?.intValue ?? 0
        if max(lastRealUse, (values["last_use"] as? NSNumber)?.doubleValue ?? 0) > succeeded { alone = 0 }
        let gap = attempted > succeeded ? Self.retryGap : Self.minimumGap
        guard now() - attempted >= gap, alone < Self.unattendedLimit else { return nil }
        update { $0["last_attempt"] = now(); $0["unattended"] = alone }
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
        update { $0["last_ok"] = now(); $0["unattended"] = alone + 1 }
        note("renewed with one Claude Code call (haiku, \(tokens) tokens); removed \(removed) leftover item(s) from ~/.claude/projects")
        return SourceNotice(title: "Claude sign-in renewed",
                            lines: ["It had expired, so Claude Code made one tiny request (\(tokens) tokens, nothing saved). See ~/.usage-hud/renewals.log."])
    }
}
