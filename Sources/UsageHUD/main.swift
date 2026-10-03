import Cocoa
import Darwin

import UsageHUDCore

final class HUD: NSObject, NSApplicationDelegate {
    var items: [String: NSStatusItem] = [:]
    var busy = false
    var lockDescriptor: Int32 = -1
    let engine = Engine()
    var home: URL { engine.root }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        do {
            try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        } catch { NSApp.terminate(nil); return }
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
            let panels = self.engine.panels(refresh: refresh)
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
        panel.displayedQuota
    }
    func icon(_ panel: Panel) -> NSImage {
        let quota = displayedQuota(panel)
        let valid = quota != nil
        let moneyWindow = quota == nil ? panel.windows.first(where: {$0.label == panel.name}) : nil
        let cached = quota?.stale == true || quota?.expired == true || moneyWindow?.stale == true
        let remaining = valid ? min(100, max(0, 100 - (quota?.pct ?? 0))) : 0
        let money = moneyWindow?.right?.split(separator: " ").first.map(String.init)
        let text = valid ? String(Int(remaining.rounded())) : money.map{$0.replacingOccurrences(of: "$", with: "")} ?? "?"
        // Full-height layers share the native battery silhouette: grey, 7d, then 5h.
        let weekly = panel.windows.first(where: {$0.label == "7d" && $0.label != quota?.label && $0.pct != nil})
        let weeklyValid = weekly != nil
        let weeklyRemaining = weeklyValid ? min(100, max(0, 100 - (weekly?.pct ?? 0))) : 0
        let bodyWidth: CGFloat = money != nil ? 32 : 23
        let bodyHeight: CGFloat = money != nil ? 13 : 12
        let bodyY = 10.5 - bodyHeight / 2
        let image = NSImage(size: NSSize(width: bodyWidth + 5, height: 22))
        image.lockFocus()
        let body = NSBezierPath(roundedRect: NSRect(x: 1, y: bodyY, width: bodyWidth, height: bodyHeight), xRadius: 3.5, yRadius: 3.5)
        let color = tint(panel.id)
        let fillWidth = valid ? bodyWidth * remaining / 100 : 0
        let bodyRect = NSRect(x: 1, y: bodyY, width: bodyWidth, height: bodyHeight)
        NSGraphicsContext.saveGraphicsState()
        if money == nil, let mask = SystemBattery.body {
            NSGraphicsContext.current?.cgContext.clip(to: bodyRect, mask: mask)
        } else { body.addClip() }
        NSColor.white.withAlphaComponent(0.36).setFill(); bodyRect.fill()
        if money != nil {
            color.blended(withFraction: 0.65, of: .white)!.withAlphaComponent(cached ? 0.50 : 1).setFill()
            bodyRect.fill()
        }
        if weeklyValid {
            color.blended(withFraction: 0.65, of: .white)!.withAlphaComponent(weekly?.stale == true || weekly?.expired == true ? 0.50 : 1).setFill()
            NSRect(x: 1, y: bodyY, width: bodyWidth * weeklyRemaining / 100, height: bodyHeight).fill()
        }
        color.withAlphaComponent(cached ? 0.45 : 1).setFill()
        NSRect(x: 1, y: bodyY, width: fillWidth, height: bodyHeight).fill()
        // A pale boundary keeps 7d visible even when the 5h fill covers it.
        if weeklyValid && weeklyRemaining > 0 && weeklyRemaining < 100 {
            NSColor.white.withAlphaComponent(weekly?.stale == true || weekly?.expired == true ? 0.45 : 0.85).setFill()
            NSRect(x: 1 + bodyWidth * weeklyRemaining / 100 - 0.5, y: bodyY, width: 1, height: bodyHeight).fill()
        }
        NSGraphicsContext.restoreGraphicsState()
        NSGraphicsContext.saveGraphicsState()
        if let mask = SystemBattery.cap {
            let capRect = NSRect(x: bodyWidth + 2, y: 4.5, width: 2, height: 12)
            NSGraphicsContext.current?.cgContext.clip(to: capRect, mask: mask)
            NSColor.white.withAlphaComponent(0.50).setFill(); capRect.fill()
        } else {
            let cap = NSBezierPath()
            cap.move(to: NSPoint(x: bodyWidth + 2, y: 8.5))
            cap.curve(to: NSPoint(x: bodyWidth + 2, y: 12.5), controlPoint1: NSPoint(x: bodyWidth + 4.5, y: 8.5), controlPoint2: NSPoint(x: bodyWidth + 4.5, y: 12.5))
            cap.close(); NSColor.white.withAlphaComponent(0.50).setFill(); cap.fill()
        }
        NSGraphicsContext.restoreGraphicsState()
        // Native battery digits are taller and lighter than a semibold status label.
        let baseSize: CGFloat = money != nil ? 10 : 9.5
        let baseFont = NSFont.monospacedDigitSystemFont(ofSize: baseSize, weight: .medium)
        let measuredWidth = (text as NSString).size(withAttributes: [.font: baseFont]).width
        let fontSize = min(baseSize, baseSize * (bodyWidth - 2) / max(1, measuredWidth))
        let font = NSFont.monospacedDigitSystemFont(ofSize: fontSize, weight: .medium)
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.white]
        let size = (text as NSString).size(withAttributes: attrs)
        let origin = NSPoint(x: 1 + bodyWidth/2-size.width/2, y: 10.5-size.height/2)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current?.cgContext.setBlendMode(.destinationOut)
        (text as NSString).draw(at: origin, withAttributes: attrs)
        NSGraphicsContext.restoreGraphicsState()
        image.unlockFocus()
        return image
    }
    func render(_ panel: Panel) {
        let item = items[panel.id] ?? NSStatusBar.system.statusItem(withLength: 32)
        items[panel.id] = item
        item.button?.image = icon(panel)
        item.length = (item.button?.image?.size.width ?? 28) + 4
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
do {
    if try Engine().handleCLI(Array(CommandLine.arguments.dropFirst())) { exit(0) }
} catch {
    fputs("Usage HUD: " + error.localizedDescription + "\n", stderr)
    exit(1)
}
let app = NSApplication.shared
let delegate = HUD()
if CommandLine.arguments.contains("--self-test") {
    if let body = SystemBattery.body, let cap = SystemBattery.cap {
        precondition(body.width == 92 && body.height == 48)
        precondition(cap.width == 8 && cap.height == 48)
        if let bytes = body.dataProvider?.data as Data? {
            precondition(bytes[24 * body.bytesPerRow + 46 * 4 + 3] == 255)
            precondition(bytes[3] == 0)
        }
    }
    let unavailable = Window(label: "5h", pct: 99, right: nil, resets_at: nil, expired: true, stale: false)
    let previousWeek = Window(label: "7d", pct: 27, right: nil, resets_at: nil, expired: false, stale: true)
    let fallback = Panel(id: "codex", name: "Codex", windows: [unavailable, previousWeek], note: "")
    precondition(delegate.displayedQuota(fallback)?.label == "7d")
    precondition(delegate.displayedQuota(fallback)?.pct == 27)
    delegate.render(fallback)
    precondition(delegate.items["codex"]?.menu?.items.contains{$0.title == "Showing 7d · cached"} == true)
    let image = NSImage(size: NSSize(width: 144, height: 44))
    image.lockFocus()
    NSColor(srgbRed: 0.32, green: 0.44, blue: 0.59, alpha: 1).setFill()
    NSRect(x: 0, y: 0, width: 144, height: 44).fill()
    for (index, id) in ["codex", "claude", "openrouter"].enumerated() {
        let panel = Panel(id: id, name: id == "openrouter" ? "OpenRouter" : id.capitalized, windows: [Window(label: id == "openrouter" ? "OpenRouter" : "5h", pct: id == "openrouter" ? nil : 19, right: id == "openrouter" ? "$26.25 left" : nil, resets_at: nil, expired: false, stale: false), Window(label: "7d", pct: id == "openrouter" ? nil : 37, right: nil, resets_at: nil, expired: false, stale: false)], note: "")
        delegate.render(panel)
        precondition(delegate.items[id]?.menu?.items.allSatisfy{!$0.title.contains("note")} == true)
        let battery = delegate.icon(panel)
        precondition(battery.size == NSSize(width: id == "openrouter" ? 37 : 28, height: 22))
        precondition(delegate.items[id]?.length == (id == "openrouter" ? 41 : 32))
        battery.draw(in: NSRect(x: CGFloat(index*48), y: 11, width: battery.size.width, height: 22))
    }
    image.unlockFocus()
    let representation = NSBitmapImageRep(data: image.tiffRepresentation!)!
    try! representation.representation(using: .png, properties: [:])!.write(to: delegate.home.appendingPathComponent("battery-preview.png"))
    print("Battery drawing and note-free menus passed")
    exit(0)
}
app.delegate = delegate
app.run()
