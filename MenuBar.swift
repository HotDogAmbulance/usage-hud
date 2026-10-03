import Cocoa
import Darwin

struct Window: Decodable {
    let label: String
    let pct: Double?
    let right: String?
    let resets_at: Double?
    let expired: Bool?
    let stale: Bool?
}
struct Panel: Decodable {
    let id: String
    let name: String
    let windows: [Window]
    let note: String
}
final class HUD: NSObject, NSApplicationDelegate {
    var items: [String: NSStatusItem] = [:]
    var busy = false
    var lockDescriptor: Int32 = -1
    let home = URL(fileURLWithPath: (Bundle.main.object(forInfoDictionaryKey: "UsageHUDDataDirectory") as? String) ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".usage-hud").path)
    let python = (Bundle.main.object(forInfoDictionaryKey: "UsageHUDPython") as? String) ?? "/usr/bin/python3"

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        lockDescriptor = Darwin.open(home.appendingPathComponent("menubar.lock").path, O_CREAT | O_RDWR, 0o600)
        if lockDescriptor < 0 || flock(lockDescriptor, LOCK_EX | LOCK_NB) != 0 { NSApp.terminate(nil); return }
        load(nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { self.load("automatic") }
        Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in self?.load("automatic") }
        Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in self?.load(nil) }
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        load("automatic")
        if let item = items["codex"] ?? items.values.first { item.button?.performClick(nil) }
        return true
    }
    func load(_ refresh: String?) {
        guard !busy else { return }
        busy = true
        DispatchQueue.global(qos: .utility).async {
            let process = Process(), output = Pipe()
            process.executableURL = URL(fileURLWithPath: self.python)
            process.arguments = [self.home.appendingPathComponent("collector.py").path] + (refresh.map{["--refresh", $0]} ?? [])
            process.standardOutput = output
            process.standardError = FileHandle.nullDevice
            var env = ProcessInfo.processInfo.environment
            env["USAGE_HUD_HOME"] = self.home.path
            env["PATH"] = FileManager.default.homeDirectoryForCurrentUser.path + "/.local/bin:/opt/homebrew/bin:/usr/bin:/bin"
            process.environment = env
            var panels: [Panel] = []
            do {
                try process.run()
                let data = output.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                panels = try JSONDecoder().decode([Panel].self, from: data)
            } catch {}
            DispatchQueue.main.async {
                self.busy = false
                for panel in panels { self.render(panel) }
            }
        }
    }
    func tint(_ id: String) -> NSColor {
        switch id {
        case "codex": return NSColor(srgbRed: 0.40, green: 0.82, blue: 0.74, alpha: 1)
        case "claude": return NSColor(srgbRed: 0.85, green: 0.58, blue: 0.45, alpha: 1)
        default: return NSColor(srgbRed: 0.65, green: 0.57, blue: 0.92, alpha: 1)
        }
    }
    func displayedQuota(_ panel: Panel) -> Window? {
        let fiveHour = panel.windows.first(where: {$0.label == "5h" && $0.pct != nil})
        if let fiveHour = fiveHour, fiveHour.stale != true && fiveHour.expired != true { return fiveHour }
        if let week = panel.windows.first(where: {$0.label == "7d" && $0.pct != nil}) { return week }
        return panel.windows.first(where: {$0.pct != nil && $0.stale != true && $0.expired != true})
    }
    func icon(_ panel: Panel) -> NSImage {
        let quota = displayedQuota(panel)
        let valid = quota != nil
        let cached = quota?.stale == true || quota?.expired == true
        let remaining = valid ? min(100, max(0, 100 - (quota?.pct ?? 0))) : 0
        let money = quota == nil ? panel.windows.first(where: {$0.label == panel.name && $0.stale != true})?.right?.split(separator: " ").first.map(String.init) : nil
        let text = valid ? String(Int(remaining.rounded())) : money.map{$0.replacingOccurrences(of: "$", with: "")} ?? "?"
        // Full-height layers share the native battery silhouette: grey, 7d, then 5h.
        let weekly = panel.windows.first(where: {$0.label == "7d" && $0.label != quota?.label && $0.pct != nil})
        let weeklyValid = weekly != nil
        let weeklyRemaining = weeklyValid ? min(100, max(0, 100 - (weekly?.pct ?? 0))) : 0
        let image = NSImage(size: NSSize(width: 28, height: 22))
        image.lockFocus()
        let body = NSBezierPath(roundedRect: NSRect(x: 1, y: 4, width: 23, height: 13), xRadius: 3.5, yRadius: 3.5)
        let color = tint(panel.id)
        let fillWidth = valid ? 23 * remaining / 100 : 0
        NSColor.white.withAlphaComponent(0.30).setFill(); body.fill()
        NSGraphicsContext.saveGraphicsState()
        body.addClip()
        if weeklyValid {
            color.withAlphaComponent(weekly?.stale == true || weekly?.expired == true ? 0.20 : 0.45).setFill()
            NSRect(x: 1, y: 4, width: 23 * weeklyRemaining / 100, height: 13).fill()
        }
        color.withAlphaComponent(cached ? 0.45 : 1).setFill()
        NSRect(x: 1, y: 4, width: fillWidth, height: 13).fill()
        NSGraphicsContext.restoreGraphicsState()
        NSColor.white.withAlphaComponent(0.40).setFill()
        NSBezierPath(roundedRect: NSRect(x: 25, y: 8, width: 2, height: 5), xRadius: 1, yRadius: 1).fill()
        let font = NSFont.systemFont(ofSize: text.count > 3 ? 7.5 : 9.5, weight: .bold)
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: (money != nil ? color : NSColor.labelColor).withAlphaComponent(cached ? 0.55 : 1)]
        let size = (text as NSString).size(withAttributes: attrs)
        let origin = NSPoint(x: 12.5-size.width/2, y: 10.5-size.height/2)
        (text as NSString).draw(at: origin, withAttributes: attrs)
        if valid {
            NSGraphicsContext.saveGraphicsState()
            body.addClip()
            NSBezierPath(rect: NSRect(x: 1, y: 4, width: fillWidth, height: 13)).addClip()
            (text as NSString).draw(at: origin, withAttributes: [.font: font, .foregroundColor: NSColor.black.withAlphaComponent(cached ? 0.50 : 0.85)])
            NSGraphicsContext.restoreGraphicsState()
        }
        image.unlockFocus()
        return image
    }
    func render(_ panel: Panel) {
        let item = items[panel.id] ?? NSStatusBar.system.statusItem(withLength: 32)
        items[panel.id] = item
        item.button?.image = icon(panel)
        let displayed = displayedQuota(panel)
        let cached = displayed?.stale == true || displayed?.expired == true
        let reading = displayed.map { $0.label + (cached ? " · cached" : " · remaining") } ?? "balance in USD"
        item.button?.toolTip = panel.name + " · " + reading + (displayed?.label == "5h" ? "; lighter fill = 7d" : "")
        item.button?.setAccessibilityLabel(panel.name + " usage")
        let menu = NSMenu()
        menu.addItem(withTitle: panel.name + " · Usage HUD", action: nil, keyEquivalent: "")
        if displayed?.label == "7d" { menu.addItem(withTitle: "Showing 7d" + (cached ? " · cached" : ""), action: nil, keyEquivalent: "") }
        if !panel.note.isEmpty { menu.addItem(withTitle: panel.note, action: nil, keyEquivalent: "") }
        for window in panel.windows {
            var text = window.label + ": "
            if let pct = window.pct {
                text += "\(Int((100-pct).rounded()))% " + (window.expired == true ? "last known · window reset" : "remaining")
                if let reset = window.resets_at, reset > Date().timeIntervalSince1970 {
                    let minutes = Int((reset - Date().timeIntervalSince1970) / 60)
                    text += " · resets in \(minutes/60)h \(minutes%60)m"
                }
            } else { text += window.right ?? "Unavailable" }
            if window.stale == true { text += " · cached" }
            menu.addItem(withTitle: text, action: nil, keyEquivalent: "")
        }
        menu.addItem(NSMenuItem.separator())
        let refresh = menu.addItem(withTitle: "Refresh " + panel.name, action: #selector(refreshProvider(_:)), keyEquivalent: "r")
        refresh.representedObject = panel.id; refresh.target = self
        if panel.id == "codex" {
            let credits = menu.addItem(withTitle: "Refresh OpenAI API credits", action: #selector(refreshProvider(_:)), keyEquivalent: "")
            credits.representedObject = "openai-credits"; credits.target = self
        }
        menu.addItem(withTitle: "Quit Usage HUD", action: #selector(quit), keyEquivalent: "q").target = self
        item.menu = menu
    }
    @objc func refreshProvider(_ sender: NSMenuItem) { load(sender.representedObject as? String) }
    @objc func quit() { NSApp.terminate(nil) }
}
let app = NSApplication.shared
let delegate = HUD()
if CommandLine.arguments.contains("--self-test") {
    let unavailable = Window(label: "5h", pct: 99, right: nil, resets_at: nil, expired: true, stale: false)
    let previousWeek = Window(label: "7d", pct: 27, right: nil, resets_at: nil, expired: false, stale: true)
    let fallback = Panel(id: "codex", name: "Codex", windows: [unavailable, previousWeek], note: "")
    precondition(delegate.displayedQuota(fallback)?.label == "7d")
    precondition(delegate.displayedQuota(fallback)?.pct == 27)
    delegate.render(fallback)
    precondition(delegate.items["codex"]?.menu?.items.contains{$0.title == "Showing 7d · cached"} == true)
    let image = NSImage(size: NSSize(width: 144, height: 44))
    image.lockFocus()
    for (index, id) in ["codex", "claude", "openrouter"].enumerated() {
        let panel = Panel(id: id, name: id == "openrouter" ? "OpenRouter" : id.capitalized, windows: [Window(label: id == "openrouter" ? "OpenRouter" : "5h", pct: id == "openrouter" ? nil : 19, right: id == "openrouter" ? "$26.25 left" : nil, resets_at: nil, expired: false, stale: false), Window(label: "7d", pct: id == "openrouter" ? nil : 37, right: nil, resets_at: nil, expired: false, stale: false)], note: "")
        delegate.render(panel)
        precondition(delegate.items[id]?.menu?.items.allSatisfy{!$0.title.contains("note")} == true)
        delegate.icon(panel).draw(in: NSRect(x: index*48, y: 11, width: 28, height: 22))
    }
    image.unlockFocus()
    let representation = NSBitmapImageRep(data: image.tiffRepresentation!)!
    try! representation.representation(using: .png, properties: [:])!.write(to: delegate.home.appendingPathComponent("battery-preview.png"))
    print("Battery drawing and note-free menus passed")
    exit(0)
}
app.delegate = delegate
app.run()
