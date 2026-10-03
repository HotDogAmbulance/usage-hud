import Cocoa
import Darwin

import UsageHUDCore

/// Reports pointer entry and exit over a status item button.
final class HoverTracker: NSResponder {
    var changed: (Bool) -> Void = { _ in }
    override func mouseEntered(with event: NSEvent) { changed(true) }
    override func mouseExited(with event: NSEvent) { changed(false) }
}

/// The hover panel for providers with per-key detail: a few header lines, then each key's cap as a row of cells.
final class CellsView: NSView {
    let lines: [String], rows: [Window], tint: NSColor
    init(lines: [String], rows: [Window], tint: NSColor) {
        self.lines = lines; self.rows = rows; self.tint = tint
        super.init(frame: NSRect(x: 0, y: 0, width: 380, height: CGFloat(lines.count * 18 + rows.count * 20 + 16)))
    }
    required init?(coder: NSCoder) { nil }
    override var isFlipped: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        let clip = NSMutableParagraphStyle(); clip.lineBreakMode = .byTruncatingTail
        let head: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 12, weight: .semibold), .foregroundColor: NSColor.labelColor, .paragraphStyle: clip]
        let body: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular), .foregroundColor: NSColor.secondaryLabelColor, .paragraphStyle: clip]
        var y: CGFloat = 8
        for line in lines { (line as NSString).draw(in: NSRect(x: 12, y: y, width: 356, height: 16), withAttributes: head); y += 18 }
        for row in rows {
            (row.label as NSString).draw(in: NSRect(x: 12, y: y + 2, width: 96, height: 16), withAttributes: body)
            if let used = row.pct {
                // Ten cells of what is left; the last one turns red.
                let left = Int(((100 - used) / 10).rounded(.up))
                for index in 0..<10 {
                    (index >= left ? NSColor.tertiaryLabelColor.withAlphaComponent(0.35) : left <= 1 ? NSColor.systemRed : tint).setFill()
                    NSBezierPath(roundedRect: NSRect(x: 112 + CGFloat(index) * 10, y: y + 4, width: 8, height: 10), xRadius: 2, yRadius: 2).fill()
                }
            }
            ((row.right ?? "").replacingOccurrences(of: " · resets in ", with: " · ") as NSString)
                .draw(in: NSRect(x: 218, y: y + 2, width: 150, height: 16), withAttributes: body)
            y += 20
        }
    }
}

final class HUD: NSObject, NSApplicationDelegate {
    var items: [String: NSStatusItem] = [:]
    var panels: [String: Panel] = [:]
    var trackers: [String: HoverTracker] = [:]
    var hovered: String?
    /// Batteries past `visibleLimit` move into this item; hovering it opens their menu.
    var overflow: NSStatusItem?
    let overflowTracker = HoverTracker()
    var shelf = Shelf(levels: UserDefaults.standard.dictionary(forKey: "shelfLevels") as? [String: Double] ?? [:],
                      lastUsed: UserDefaults.standard.dictionary(forKey: "shelfLastUsed") as? [String: Double] ?? [:])
    /// Change with `defaults write local.usage-hud visibleBatteries 4`.
    var visibleLimit: Int { UserDefaults.standard.integer(forKey: "visibleBatteries") > 0 ? UserDefaults.standard.integer(forKey: "visibleBatteries") : 3 }
    /// Alerts the user has already seen by hovering, by provider; those batteries stop pulsing until the alert changes.
    var acknowledged: [String: String] = [:]
    var pulse: Timer?
    let popover = NSPopover()
    /// A newer release, offered at the foot of every battery menu.
    var update: (tag: String, page: URL)?
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
        let lowBalance = UserDefaults.standard.double(forKey: "lowBalance")
        if lowBalance > 0 { engine.lowBalance = lowBalance }
        checkForUpdate()
        Timer.scheduledTimer(withTimeInterval: 86400, repeats: true) { [weak self] _ in self?.checkForUpdate() }
        DistributedNotificationCenter.default().addObserver(forName: NSNotification.Name("AppleInterfaceThemeChangedNotification"),
                                                            object: nil, queue: .main) { [weak self] _ in
            self?.items.keys.forEach { self?.drawIcon($0) }
        }
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        load("automatic")
        if let item = items["codex"] ?? items.values.first { item.button?.performClick(nil) }
        return true
    }
    /// Undocumented usage endpoints change, so readers need fixes quickly. Builds name their release source in
    /// Info.plist (`UsageHUDReleases`, "owner/repo"); only the public release metadata is fetched.
    func checkForUpdate() {
        let info = Bundle.main.infoDictionary ?? [:]
        guard let current = info["CFBundleShortVersionString"] as? String,
              let url = URL(string: "https://api.github.com/repos/" + (info["UsageHUDReleases"] as? String ?? "HotDogAmbulance/usage-hud") + "/releases/latest") else { return }
        var request = URLRequest(url: url, timeoutInterval: 15)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        URLSession.shared.dataTask(with: request) { data, _, _ in
            guard let data = data, let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let found = Updates.newer(json, than: current) else { return }
            DispatchQueue.main.async {
                self.update = found
                for panel in self.panels.values { self.render(panel) }
            }
        }.resume()
    }
    @objc func openUpdate() { if let page = update?.page { NSWorkspace.shared.open(page) } }
    func load(_ refresh: String?) {
        guard !busy else { return }
        busy = true
        DispatchQueue.global(qos: .utility).async {
            let panels = self.engine.panels(refresh: refresh)
            DispatchQueue.main.async {
                self.busy = false
                for panel in panels { self.render(panel); self.shelf.observe(panel, now: Date().timeIntervalSince1970) }
                UserDefaults.standard.set(self.shelf.levels, forKey: "shelfLevels")
                UserDefaults.standard.set(self.shelf.lastUsed, forKey: "shelfLastUsed")
                self.arrange(panels.map { $0.id })
            }
        }
    }
    func tint(_ id: String) -> NSColor {
        switch id {
        case "codex": return NSColor(srgbRed: 0.40, green: 0.82, blue: 0.74, alpha: 1)
        case "claude": return NSColor(srgbRed: 0.85, green: 0.58, blue: 0.45, alpha: 1)
        // Brand colours where the brand has one; black-and-white marks get light neutrals so they show on the menu bar.
        case "glm": return NSColor(srgbRed: 0.96, green: 0.96, blue: 0.97, alpha: 1)
        case "antigravity": return NSColor(srgbRed: 0.19, green: 0.53, blue: 1.00, alpha: 1)
        case "grok": return NSColor(srgbRed: 0.80, green: 0.80, blue: 0.84, alpha: 1)
        case "vercel": return NSColor(srgbRed: 0.66, green: 0.64, blue: 0.62, alpha: 1)
        case "deepseek": return NSColor(srgbRed: 0.30, green: 0.42, blue: 1.00, alpha: 1)
        case "kimi": return NSColor(srgbRed: 0.09, green: 0.51, blue: 1.00, alpha: 1)
        case "openrouter": return NSColor(srgbRed: 0.40, green: 0.93, blue: 0.16, alpha: 1)
        default: return NSColor(srgbRed: 0.65, green: 0.57, blue: 0.92, alpha: 1)
        }
    }
    /// Whether the menu bar is dark; it follows the wallpaper, so it can differ from the system appearance.
    var darkMenuBar: Bool {
        (items.values.first?.button?.effectiveAppearance ?? NSApp.effectiveAppearance).bestMatch(from: [.darkAqua, .aqua]) != .aqua
    }
    /// Fills `rect` with the provider's tint. Antigravity uses its four-colour mark, spread across the whole body.
    /// On a light menu bar, pale tints are deepened and the weekly shade is softened less, so white and silver stay visible.
    func paint(_ rect: NSRect, body: NSRect, id: String, light: Bool, alpha: CGFloat, dark: Bool = true) {
        let shade = { (color: NSColor) -> NSColor in
            var color = color
            if !dark, let rgb = color.usingColorSpace(.sRGB),
               0.2126 * rgb.redComponent + 0.7152 * rgb.greenComponent + 0.0722 * rgb.blueComponent > 0.6 {
                color = color.blended(withFraction: 0.45, of: .black)!
            }
            return (light ? color.blended(withFraction: dark ? 0.65 : 0.45, of: .white)! : color).withAlphaComponent(alpha)
        }
        guard id == "antigravity" else { shade(tint(id)).setFill(); rect.fill(); return }
        let marks: [(CGFloat, CGFloat, CGFloat)] = [(0.19, 0.53, 1.00), (0.19, 0.53, 1.00), (0.98, 0.27, 0.26), (0.98, 0.74, 0.07), (0.03, 0.73, 0.38)]
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: rect).addClip()
        NSGradient(colors: marks.map { shade(NSColor(srgbRed: $0.0, green: $0.1, blue: $0.2, alpha: 1)) })?.draw(in: body, angle: 0)
        NSGraphicsContext.restoreGraphicsState()
    }
    func displayedQuota(_ panel: Panel) -> Window? {
        panel.displayedQuota
    }
    /// While hovered, a battery led by 5h shows its 7d window on its own.
    func hoverPanel(_ panel: Panel) -> Panel? {
        guard displayedQuota(panel)?.label == "5h",
              let weekly = panel.windows.first(where: { $0.label == "7d" && $0.pct != nil }) else { return nil }
        return Panel(id: panel.id, name: panel.name, windows: [weekly], note: panel.note)
    }
    func drawIcon(_ id: String) {
        guard let panel = panels[id], let button = items[id]?.button else { return }
        if hovered == id, let weekly = hoverPanel(panel) { button.image = icon(weekly, weeklyShade: true) }
        else { button.image = icon(panel, glow: pulsing(id) ? glow() : 0) }
    }
    func pulsing(_ id: String) -> Bool {
        guard let alert = panels[id]?.alert else { return false }
        return acknowledged[id] != alert
    }
    /// A slow, soft breath: about three seconds a cycle, never fully red.
    func glow(at time: TimeInterval = Date().timeIntervalSinceReferenceDate) -> CGFloat {
        CGFloat(0.55 * (1 - cos(2 * Double.pi * time / 3.2)) / 2)
    }
    /// Runs the pulse only while some battery is asking for attention.
    func updatePulse() {
        let ids = panels.keys.filter(pulsing)
        if ids.isEmpty { pulse?.invalidate(); pulse = nil; return }
        guard pulse == nil else { return }
        pulse = Timer.scheduledTimer(withTimeInterval: 1.0 / 12, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            for id in self.panels.keys where self.pulsing(id) { self.drawIcon(id) }
        }
    }
    /// `weeklyShade` draws the main fill in the same lighter tone the 7d layer uses behind 5h.
    /// `glow` washes the body in soft red, for a battery asking for attention.
    func icon(_ panel: Panel, weeklyShade: Bool = false, glow: CGFloat = 0) -> NSImage {
        let quota = displayedQuota(panel)
        let valid = quota != nil
        let moneyWindow = quota == nil ? panel.windows.first(where: {$0.label == panel.name}) : nil
        let cached = quota?.stale == true || quota?.expired == true || moneyWindow?.stale == true
        let remaining = valid ? min(100, max(0, 100 - (quota?.pct ?? 0))) : 0
        let money = moneyWindow?.right?.split(separator: " ").first.map(String.init)
        var text = valid ? String(Int(remaining.rounded())) : money.map{$0.replacingOccurrences(of: "$", with: "")} ?? "?"
        if !valid, text.hasSuffix(".00") { text.removeLast(3) }
        // Full-height layers share the native battery silhouette: grey, 7d, then 5h.
        let weekly = panel.windows.first(where: {$0.label == "7d" && $0.label != quota?.label && $0.pct != nil})
        let weeklyValid = weekly != nil
        let weeklyRemaining = weeklyValid ? min(100, max(0, 100 - (weekly?.pct ?? 0))) : 0
        // Native battery digits are taller and lighter than a semibold status label.
        let baseSize: CGFloat = money != nil ? 10 : 9.5
        let baseFont = NSFont.monospacedDigitSystemFont(ofSize: baseSize, weight: .medium)
        let measuredWidth = (text as NSString).size(withAttributes: [.font: baseFont]).width
        // A balance stretches the body to fit its digits: whole amounts keep the standard size, cents widen it.
        let bodyWidth: CGFloat = money != nil ? max(23, (measuredWidth + 6).rounded(.up)) : 23
        let bodyHeight: CGFloat = money != nil ? 13 : 12
        let bodyY = 10.5 - bodyHeight / 2
        let image = NSImage(size: NSSize(width: bodyWidth + 5, height: 22))
        image.lockFocus()
        let body = NSBezierPath(roundedRect: NSRect(x: 1, y: bodyY, width: bodyWidth, height: bodyHeight), xRadius: 3.5, yRadius: 3.5)
        let fillWidth = valid ? bodyWidth * remaining / 100 : 0
        let bodyRect = NSRect(x: 1, y: bodyY, width: bodyWidth, height: bodyHeight)
        NSGraphicsContext.saveGraphicsState()
        if money == nil, let mask = SystemBattery.body {
            NSGraphicsContext.current?.cgContext.clip(to: bodyRect, mask: mask)
        } else { body.addClip() }
        let dark = darkMenuBar
        // The empty part and the cap contrast with the menu bar: white on a dark bar, black on a light one.
        let ink = dark ? NSColor.white : NSColor.black
        ink.withAlphaComponent(dark ? 0.36 : 0.22).setFill(); bodyRect.fill()
        if money != nil {
            paint(bodyRect, body: bodyRect, id: panel.id, light: true, alpha: cached ? 0.50 : 1, dark: dark)
        }
        if weeklyValid {
            paint(NSRect(x: 1, y: bodyY, width: bodyWidth * weeklyRemaining / 100, height: bodyHeight), body: bodyRect, id: panel.id,
                  light: true, alpha: weekly?.stale == true || weekly?.expired == true ? 0.50 : 1, dark: dark)
        }
        paint(NSRect(x: 1, y: bodyY, width: fillWidth, height: bodyHeight), body: bodyRect, id: panel.id, light: weeklyShade, alpha: cached ? 0.45 : 1, dark: dark)
        if glow > 0 { NSColor(srgbRed: 1.0, green: 0.33, blue: 0.30, alpha: glow).setFill(); bodyRect.fill() }
        NSGraphicsContext.restoreGraphicsState()
        NSGraphicsContext.saveGraphicsState()
        if let mask = SystemBattery.cap {
            let capRect = NSRect(x: bodyWidth + 2, y: 4.5, width: 2, height: 12)
            NSGraphicsContext.current?.cgContext.clip(to: capRect, mask: mask)
            ink.withAlphaComponent(dark ? 0.50 : 0.35).setFill(); capRect.fill()
        } else {
            let cap = NSBezierPath()
            cap.move(to: NSPoint(x: bodyWidth + 2, y: 8.5))
            cap.curve(to: NSPoint(x: bodyWidth + 2, y: 12.5), controlPoint1: NSPoint(x: bodyWidth + 4.5, y: 8.5), controlPoint2: NSPoint(x: bodyWidth + 4.5, y: 12.5))
            cap.close(); ink.withAlphaComponent(dark ? 0.50 : 0.35).setFill(); cap.fill()
        }
        NSGraphicsContext.restoreGraphicsState()
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
        panels[panel.id] = panel
        if trackers[panel.id] == nil, let button = item.button {
            let tracker = HoverTracker(), id = panel.id
            tracker.changed = { [weak self] inside in
                guard let self = self else { return }
                if inside {
                    self.hovered = id; self.acknowledged[id] = self.panels[id]?.alert
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { self.showCells(id) }
                } else {
                    if self.hovered == id { self.hovered = nil }
                    if self.popover.isShown { self.popover.close() }
                }
                self.updatePulse()
                self.drawIcon(id)
            }
            button.addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                                  owner: tracker, userInfo: nil))
            trackers[panel.id] = tracker
        }
        drawIcon(panel.id)
        item.length = (item.button?.image?.size.width ?? 28) + 4
        let displayed = displayedQuota(panel)
        let cached = displayed?.stale == true || displayed?.expired == true
        let reading = displayed.map { $0.label + (cached ? " · cached" : " · remaining") } ?? "balance in USD"
        // Money rows (credits, extra usage) ride along in the hover text, so balances need no click.
        let money = panel.windows.filter { $0.pct == nil && $0.right != nil && $0.label != panel.name }.map { "\n" + $0.label + ": " + ($0.right ?? "") }
        if panel.alert == nil { acknowledged[panel.id] = nil }
        // Providers with per-key cells get the hover panel instead of a tooltip.
        item.button?.toolTip = !panel.cells.isEmpty ? nil : (panel.alert.map { "⚠︎ " + $0 + "\n" } ?? "") + panel.name + " · " + reading + (hoverPanel(panel) != nil ? "; lighter fill = 7d, hover to show 7d" : "") + money.joined()
        item.button?.setAccessibilityLabel(panel.name + " usage" + (panel.alert.map { ", " + $0 } ?? ""))
        updatePulse()
        let menu = NSMenu()
        menu.addItem(withTitle: panel.name + " · Usage HUD", action: nil, keyEquivalent: "")
        if let alert = panel.alert { menu.addItem(withTitle: "⚠︎ " + alert, action: nil, keyEquivalent: "") }
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
        if panel.cellsTitle != nil {
            let all = NSMenu()
            for cell in panel.cells { all.addItem(withTitle: cell.label + " · " + (cell.right ?? ""), action: nil, keyEquivalent: "") }
            let title = panel.id == "antigravity" ? "All models" : "All keys"
            menu.addItem(withTitle: title + " (\(panel.cells.count))", action: nil, keyEquivalent: "").submenu = all
        }
        menu.addItem(NSMenuItem.separator())
        let refresh = menu.addItem(withTitle: "Refresh " + panel.name, action: #selector(refreshProvider(_:)), keyEquivalent: "r")
        refresh.representedObject = panel.id; refresh.target = self
        if panel.id == "codex" {
            let credits = menu.addItem(withTitle: "Refresh OpenAI API credits", action: #selector(refreshProvider(_:)), keyEquivalent: "")
            credits.representedObject = "openai-credits"; credits.target = self
        }
        if let update = update {
            menu.addItem(withTitle: "Update available: " + update.tag + "…", action: #selector(openUpdate), keyEquivalent: "").target = self
        }
        menu.addItem(withTitle: "Quit Usage HUD", action: #selector(quit), keyEquivalent: "q").target = self
        item.menu = menu
    }
    /// Keeps the most recently used batteries in the menu bar, so a crowded bar or the notch never hides them silently.
    func arrange(_ ids: [String]) {
        let hidden = shelf.arrange(ids, limit: visibleLimit, urgent: Set(ids.filter { panels[$0]?.alert != nil })).hidden
        for id in ids { items[id]?.isVisible = !hidden.contains(id) }
        guard !hidden.isEmpty else { overflow?.isVisible = false; return }
        let item = overflow ?? NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if overflow == nil, let button = item.button {
            overflow = item
            overflowTracker.changed = { [weak self] inside in
                guard inside else { return }
                // A short pause, so sweeping the pointer across the bar doesn't pop the menu open.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                    guard let button = self?.overflow?.button, let window = button.window,
                          button.bounds.contains(button.convert(window.mouseLocationOutsideOfEventStream, from: nil)) else { return }
                    button.performClick(nil)
                }
            }
            button.addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                                  owner: overflowTracker, userInfo: nil))
        }
        item.isVisible = true
        item.button?.title = "+\(hidden.count)"
        item.button?.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        item.button?.toolTip = "\(hidden.count) more: " + hidden.compactMap { panels[$0]?.name }.joined(separator: ", ")
        item.button?.setAccessibilityLabel("\(hidden.count) more usage batteries")
        let menu = NSMenu()
        for id in hidden {
            guard let panel = panels[id] else { continue }
            let entry = menu.addItem(withTitle: items[id]?.button?.toolTip?.components(separatedBy: "\n").first ?? panel.name, action: nil, keyEquivalent: "")
            entry.image = icon(panel)
            entry.submenu = items[id]?.menu?.copy() as? NSMenu
        }
        menu.addItem(NSMenuItem.separator())
        menu.addItem(withTitle: "Quit Usage HUD", action: #selector(quit), keyEquivalent: "q").target = self
        item.menu = menu
    }
    /// Opens the per-key panel under a battery that is still hovered.
    func showCells(_ id: String) {
        guard hovered == id, let panel = panels[id], !panel.cells.isEmpty, let button = items[id]?.button, button.window != nil else { return }
        let lines = [panel.alert.map { "⚠︎ " + $0 }, panel.windows.first { $0.label == panel.name }.map { panel.name + " · " + ($0.right ?? "") },
                     panel.cellsTitle].compactMap { $0 }
        let controller = NSViewController()
        controller.view = CellsView(lines: lines, rows: Array(panel.cells.prefix(6)), tint: tint(id))
        popover.contentViewController = controller
        popover.contentSize = controller.view.frame.size
        popover.animates = false
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
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
    let layered = Panel(id: "claude", name: "Claude", windows: [Window(label: "5h", pct: 20), Window(label: "7d", pct: 80)])
    precondition(delegate.hoverPanel(layered)?.displayedQuota?.label == "7d")
    precondition(delegate.hoverPanel(layered)?.windows.count == 1)
    precondition(delegate.hoverPanel(fallback) == nil)
    delegate.render(layered)
    delegate.trackers["claude"]?.changed(true)
    precondition(delegate.hovered == "claude")
    delegate.trackers["claude"]?.changed(false)
    precondition(delegate.hovered == nil)
    let image = NSImage(size: NSSize(width: 144, height: 44))
    image.lockFocus()
    NSColor(srgbRed: 0.32, green: 0.44, blue: 0.59, alpha: 1).setFill()
    NSRect(x: 0, y: 0, width: 144, height: 44).fill()
    for (index, id) in ["codex", "claude", "openrouter"].enumerated() {
        let panel = Panel(id: id, name: id == "openrouter" ? "OpenRouter" : id.capitalized, windows: [Window(label: id == "openrouter" ? "OpenRouter" : "5h", pct: id == "openrouter" ? nil : 19, right: id == "openrouter" ? "$26.25 left" : nil, resets_at: nil, expired: false, stale: false), Window(label: "7d", pct: id == "openrouter" ? nil : 37, right: nil, resets_at: nil, expired: false, stale: false)], note: "")
        delegate.render(panel)
        precondition(delegate.items[id]?.menu?.items.allSatisfy{!$0.title.contains("note")} == true)
        let battery = delegate.icon(panel)
        precondition(battery.size.height == 22 && (id == "openrouter" ? battery.size.width > 28 : battery.size.width == 28))
        precondition(delegate.items[id]?.length == battery.size.width + 4)
        battery.draw(in: NSRect(x: CGFloat(index*48), y: 11, width: battery.size.width, height: 22))
    }
    image.unlockFocus()
    // Past the limit, the least recently used batteries move into one overflow item.
    for id in ["glm", "deepseek"] { delegate.render(Panel(id: id, name: id.uppercased(), windows: [Window(label: "5h", pct: 10)])) }
    delegate.shelf = Shelf()
    delegate.arrange(["codex", "claude", "openrouter", "glm", "deepseek"])
    precondition(delegate.items["glm"]?.isVisible == false && delegate.items["deepseek"]?.isVisible == false)
    precondition(delegate.items["codex"]?.isVisible == true && delegate.overflow?.button?.title == "+2")
    precondition(delegate.overflow?.menu?.items.first?.submenu?.items.contains { $0.title.hasPrefix("Refresh GLM") } == true)
    delegate.arrange(["codex", "claude"])
    precondition(delegate.overflow?.isVisible == false)
    // An alert pulses until hovered, and the hover text says what is wrong.
    let capped = Panel(id: "openrouter", name: "OpenRouter", windows: [Window(label: "OpenRouter", right: "$0.40 left")], alert: "Balance low: $0.40 left")
    delegate.render(capped)
    precondition(delegate.pulsing("openrouter") && delegate.pulse != nil)
    precondition(delegate.items["openrouter"]?.button?.toolTip?.hasPrefix("⚠︎ Balance low") == true)
    precondition(delegate.glow(at: 0) == 0 && delegate.glow(at: 1.6) > 0.5)
    precondition(delegate.icon(capped, glow: 0.5).size == delegate.icon(capped).size)
    delegate.trackers["openrouter"]?.changed(true)
    precondition(!delegate.pulsing("openrouter") && delegate.pulse == nil)
    delegate.trackers["openrouter"]?.changed(false)
    delegate.render(Panel(id: "openrouter", name: "OpenRouter", windows: [Window(label: "OpenRouter", right: "$9.00 left")]))
    precondition(delegate.acknowledged["openrouter"] == nil)
    // Per-key cells replace the tooltip with a hover panel sized to its rows.
    let team = Panel(id: "openrouter", name: "OpenRouter", windows: [Window(label: "OpenRouter", right: "$43.00 left"), Window(label: "Team", right: "2 keys")],
                     cells: [Window(label: "k7", pct: 96, right: "$4.80 of $5.00 today"), Window(label: "k8", right: "$1.00 today")], cellsTitle: "2 keys")
    delegate.render(team)
    precondition(delegate.items["openrouter"]?.button?.toolTip == nil)
    precondition(delegate.items["openrouter"]?.menu?.items.contains { $0.title == "All keys (2)" && $0.submenu?.items.count == 2 } == true)
    precondition(CellsView(lines: ["a", "b"], rows: team.cells, tint: .white).frame.height == 92)
    // Balances stretch with their digits; a whole amount keeps the standard battery size.
    func balance(_ right: String) -> NSImage {
        delegate.icon(Panel(id: "openrouter", name: "OpenRouter", windows: [Window(label: "OpenRouter", pct: nil, right: right, resets_at: nil, expired: false, stale: false)], note: ""))
    }
    precondition(balance("$26.00 left").size.width == 28)
    precondition(balance("$26.25 left").size.width > balance("$26.00 left").size.width)
    precondition(balance("$1026.25 left").size.width > balance("$26.25 left").size.width)
    let representation = NSBitmapImageRep(data: image.tiffRepresentation!)!
    try! representation.representation(using: .png, properties: [:])!.write(to: delegate.home.appendingPathComponent("battery-preview.png"))
    print("Battery drawing and note-free menus passed")
    exit(0)
}
app.delegate = delegate
app.run()
