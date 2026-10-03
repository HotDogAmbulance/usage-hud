import Cocoa
import Darwin
import ServiceManagement
import CoreText

import UsageHUDCore

/// Reports pointer entry and exit over a status item button.
final class HoverTracker: NSResponder {
    var changed: (Bool) -> Void = { _ in }
    override func mouseEntered(with event: NSEvent) { changed(true) }
    override func mouseExited(with event: NSEvent) { changed(false) }
}

/// The hover panel for providers with per-key detail: a few header lines, then one small battery per key, green while
/// plenty is left, yellow under 30%, red under 10% (where your own keys start to pulse). It sizes itself to its text.
final class CellsView: NSView {
    let lines: [String], rows: [Window]
    static let head: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 12, weight: .semibold), .foregroundColor: NSColor.labelColor]
    static let body: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular), .foregroundColor: NSColor.secondaryLabelColor]
    let nameWidth: CGFloat
    init(lines: [String], rows: [Window]) {
        self.lines = lines; self.rows = rows
        func width(_ text: String, _ style: [NSAttributedString.Key: Any]) -> CGFloat { ceil((text as NSString).size(withAttributes: style).width) }
        nameWidth = min(140, rows.map { width($0.label, Self.body) }.max() ?? 0)
        let text = max(lines.map { width($0, Self.head) }.max() ?? 0, nameWidth + 54 + (rows.map { width($0.right ?? "", Self.body) }.max() ?? 0))
        super.init(frame: NSRect(x: 0, y: 0, width: min(560, max(260, text + 24)), height: CGFloat(lines.count * 18 + rows.count * 20 + 16)))
    }
    required init?(coder: NSCoder) { nil }
    override var isFlipped: Bool { true }
    static func color(left: Double) -> NSColor { left <= 0.1 ? .systemRed : left <= 0.3 ? .systemYellow : .systemGreen }
    override func draw(_ dirtyRect: NSRect) {
        let clip = NSMutableParagraphStyle(); clip.lineBreakMode = .byTruncatingTail
        var head = Self.head, body = Self.body; head[.paragraphStyle] = clip; body[.paragraphStyle] = clip
        let width = bounds.width - 24
        var y: CGFloat = 8
        for line in lines { (line as NSString).draw(in: NSRect(x: 12, y: y, width: width, height: 16), withAttributes: head); y += 18 }
        for row in rows {
            (row.label as NSString).draw(in: NSRect(x: 12, y: y + 2, width: nameWidth, height: 16), withAttributes: body)
            let x = 12 + nameWidth + 8
            if let used = row.pct {
                // A battery like the menu bar's: the share of the cap left, with its digits cut out of the fill.
                let left = max(0, min(1, (100 - used) / 100)), shell = NSRect(x: x, y: y + 3, width: 36, height: 13)
                let image = NSImage(size: shell.size, flipped: false) { rect in
                    let outline = NSBezierPath(roundedRect: NSRect(x: 0, y: 0, width: 33, height: 13), xRadius: 3.5, yRadius: 3.5)
                    NSGraphicsContext.saveGraphicsState(); outline.addClip()
                    NSColor.tertiaryLabelColor.withAlphaComponent(0.35).setFill(); rect.fill()
                    Self.color(left: left).setFill(); NSRect(x: 0, y: 0, width: 33 * left, height: 13).fill()
                    NSGraphicsContext.restoreGraphicsState()
                    NSColor.tertiaryLabelColor.setFill()
                    NSBezierPath(roundedRect: NSRect(x: 34, y: 4, width: 2, height: 5), xRadius: 1, yRadius: 1).fill()
                    let digits = String(Int((left * 100).rounded())) as NSString
                    let style: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .semibold), .foregroundColor: NSColor.black]
                    let size = digits.size(withAttributes: style)
                    NSGraphicsContext.current?.cgContext.setBlendMode(.destinationOut)
                    digits.draw(at: NSPoint(x: 16.5 - size.width / 2, y: 6.5 - size.height / 2), withAttributes: style)
                    return true
                }
                image.draw(in: shell)
            }
            ((row.right ?? "") as NSString).draw(in: NSRect(x: x + 46, y: y + 2, width: bounds.width - x - 58, height: 16), withAttributes: body)
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
    /// A Refresh chosen while a background pass is running; it runs as soon as that pass ends.
    var pending: String?
    var lockDescriptor: Int32 = -1
    let engine = Engine()
    var home: URL { engine.root }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        // An installed app starts at login by itself; a build run from Terminal does not register.
        if #available(macOS 13, *), Bundle.main.bundleURL.pathExtension == "app", SMAppService.mainApp.status == .notRegistered {
            try? SMAppService.mainApp.register()
        }
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
        guard !busy else { if let refresh = refresh, refresh != "automatic" { pending = refresh }; return }
        busy = true
        DispatchQueue.global(qos: .utility).async {
            let panels = self.engine.panels(refresh: refresh)
            DispatchQueue.main.async {
                self.busy = false
                for panel in panels { self.render(panel); self.shelf.observe(panel, now: Date().timeIntervalSince1970) }
                UserDefaults.standard.set(self.shelf.levels, forKey: "shelfLevels")
                UserDefaults.standard.set(self.shelf.lastUsed, forKey: "shelfLastUsed")
                self.arrange(panels.map { $0.id })
                if let next = self.pending { self.pending = nil; self.load(next) }
            }
        }
    }
    func tint(_ id: String) -> NSColor {
        switch id {
        // Every tint stays well below white (relative luminance at most 0.5), so from across the room no battery reads as
        // the Mac's own. Brand colours where the brand has one; black-and-white marks get distinct mid tones.
        case "codex": return NSColor(srgbRed: 0.16, green: 0.66, blue: 0.58, alpha: 1)
        case "claude": return NSColor(srgbRed: 0.85, green: 0.47, blue: 0.34, alpha: 1)
        case "glm": return NSColor(srgbRed: 0.42, green: 0.36, blue: 0.98, alpha: 1)
        case "gemini": return NSColor(srgbRed: 0.19, green: 0.53, blue: 1.00, alpha: 1)
        case "grok": return NSColor(srgbRed: 0.52, green: 0.55, blue: 0.62, alpha: 1)
        case "vercel": return NSColor(srgbRed: 0.58, green: 0.56, blue: 0.54, alpha: 1)
        case "deepseek": return NSColor(srgbRed: 0.30, green: 0.42, blue: 1.00, alpha: 1)
        case "kimi": return NSColor(srgbRed: 0.09, green: 0.51, blue: 1.00, alpha: 1)
        case "openrouter": return NSColor(srgbRed: 0.30, green: 0.80, blue: 0.12, alpha: 1)
        default: return NSColor(srgbRed: 0.65, green: 0.57, blue: 0.92, alpha: 1)
        }
    }
    /// Whether the menu bar is dark; it follows the wallpaper, so it can differ from the system appearance.
    var darkMenuBar: Bool {
        (items.values.first?.button?.effectiveAppearance ?? NSApp.effectiveAppearance).bestMatch(from: [.darkAqua, .aqua]) != .aqua
    }
    /// Fills `rect` with the provider's tint. Gemini uses its four-colour mark, spread across the whole body.
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
        guard id == "gemini" else { shade(tint(id)).setFill(); rect.fill(); return }
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
    /// The digits' font, by size. `--self-test` also renders the candidates side by side in font-preview.png.
    static var digitFont: (CGFloat) -> NSFont = { NSFont.monospacedDigitSystemFont(ofSize: $0, weight: .bold) }
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
        // Like the system battery's percentage: SF digits, heavy enough to read once cut out of a small fill.
        let baseSize: CGFloat = money != nil ? 10 : 9.5
        let baseFont = Self.digitFont(baseSize)
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
        // Each layer fills only its own span, on whole device pixels. Stacked layers would each blend the same soft edge,
        // leaving a pale fringe of the track around every full battery.
        let pixel = { (x: CGFloat) -> CGFloat in (x * 2).rounded() / 2 }
        let span = { (from: CGFloat, to: CGFloat) in NSRect(x: 1 + from, y: bodyY, width: max(0, to - from), height: bodyHeight) }
        let fillEnd = money != nil ? bodyWidth : pixel(fillWidth)
        let weeklyEnd = weeklyValid ? max(fillEnd, pixel(bodyWidth * weeklyRemaining / 100)) : fillEnd
        let weeklyAlpha: CGFloat = weekly?.stale == true || weekly?.expired == true ? 0.50 : 1, fillAlpha: CGFloat = cached ? (money != nil ? 0.50 : 0.45) : 1
        // A translucent layer still needs the track behind it.
        let trackStart = fillAlpha < 1 ? 0 : weeklyAlpha < 1 ? fillEnd : weeklyEnd
        ink.withAlphaComponent(dark ? 0.36 : 0.22).setFill(); span(trackStart, bodyWidth).fill()
        if weeklyEnd > fillEnd {
            paint(span(fillEnd, weeklyEnd), body: bodyRect, id: panel.id, light: true, alpha: weeklyAlpha, dark: dark)
        }
        paint(span(0, fillEnd), body: bodyRect, id: panel.id, light: money != nil || weeklyShade, alpha: fillAlpha, dark: dark)
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
        let font = Self.digitFont(fontSize)
        // Centre the digits' ink, not their line box, the way the system battery does: side bearings and the
        // descender space would otherwise push "100" left and every number up.
        if let context = NSGraphicsContext.current?.cgContext {
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: NSColor.white]))
            let glyphs = CTLineGetImageBounds(line, context)
            context.saveGState()
            context.setBlendMode(.destinationOut); context.textMatrix = .identity
            context.textPosition = CGPoint(x: pixel(1 + bodyWidth / 2 - glyphs.midX), y: pixel(bodyY + bodyHeight / 2 - glyphs.midY))
            CTLineDraw(line, context)
            context.restoreGState()
        }
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
                    // Just long enough to ignore a pointer passing over on its way elsewhere.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { self.showCells(id) }
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
            menu.addItem(withTitle: "All keys (\(panel.cells.count))", action: nil, keyEquivalent: "").submenu = all
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
        // A refresh problem rides along too, since this panel replaces the tooltip that would have said so.
        let lines = [panel.alert.map { "⚠︎ " + $0 }, panel.windows.first { $0.label == panel.name }.map { panel.name + " · " + ($0.right ?? "") },
                     panel.cellsTitle, panel.note.isEmpty || panel.note == panel.alert ? nil : panel.note].compactMap { $0 }
        let controller = NSViewController()
        controller.view = CellsView(lines: lines, rows: Array(panel.cells.prefix(8)))
        popover.contentViewController = controller
        popover.contentSize = controller.view.frame.size
        popover.animates = false
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
    }
    @objc func refreshProvider(_ sender: NSMenuItem) { load(sender.representedObject as? String) }
    @objc func quit() { NSApp.terminate(nil) }
}
// A CLI that exits before reading its input must not take the app down with it.
signal(SIGPIPE, SIG_IGN)
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
    precondition(CellsView(lines: ["a", "b"], rows: team.cells).frame.height == 92)
    // The panel widens to show a whole reset time instead of cutting it off.
    let long = Window(label: "Guy1", pct: 0, right: "$0.00 of $5.00 today · resets in 7h 16m")
    precondition(CellsView(lines: ["OpenRouter"], rows: [long]).frame.width > CellsView(lines: ["OpenRouter"], rows: [Window(label: "a", pct: 0, right: "$1")]).frame.width)
    // No tint may pass for the system battery's white.
    for id in ["codex", "claude", "glm", "gemini", "grok", "vercel", "deepseek", "kimi", "openrouter", "other"] {
        let rgb = delegate.tint(id).usingColorSpace(.sRGB)!
        let linear = [rgb.redComponent, rgb.greenComponent, rgb.blueComponent].map { $0 <= 0.04045 ? $0 / 12.92 : pow(($0 + 0.055) / 1.055, 2.4) }
        precondition(0.2126 * linear[0] + 0.7152 * linear[1] + 0.0722 * linear[2] <= 0.5, id + " is too close to white")
    }
    precondition(CellsView.color(left: 0.05) == .systemRed && CellsView.color(left: 0.2) == .systemYellow && CellsView.color(left: 0.9) == .systemGreen)
    // Balances stretch with their digits; a whole amount keeps the standard battery size.
    func balance(_ right: String) -> NSImage {
        delegate.icon(Panel(id: "openrouter", name: "OpenRouter", windows: [Window(label: "OpenRouter", pct: nil, right: right, resets_at: nil, expired: false, stale: false)], note: ""))
    }
    precondition(balance("$26.00 left").size.width == 28)
    precondition(balance("$26.25 left").size.width > balance("$26.00 left").size.width)
    precondition(balance("$1026.25 left").size.width > balance("$26.25 left").size.width)
    let representation = NSBitmapImageRep(data: image.tiffRepresentation!)!
    try! representation.representation(using: .png, properties: [:])!.write(to: delegate.home.appendingPathComponent("battery-preview.png"))
    // Candidate digit fonts, numbered, to compare against the system battery beside them in the menu bar.
    func proportional(_ size: CGFloat, _ weight: NSFont.Weight) -> NSFont { NSFont.systemFont(ofSize: size, weight: weight) }
    func rounded(_ size: CGFloat, _ weight: NSFont.Weight) -> NSFont {
        NSFont(descriptor: NSFont.systemFont(ofSize: size, weight: weight).fontDescriptor.withDesign(.rounded) ?? NSFont.systemFont(ofSize: size).fontDescriptor, size: size) ?? .systemFont(ofSize: size)
    }
    let candidates: [(String, (CGFloat) -> NSFont)] = [
        ("1 bold, fixed digits (now)", { NSFont.monospacedDigitSystemFont(ofSize: $0, weight: .bold) }),
        ("2 semibold, fixed digits", { NSFont.monospacedDigitSystemFont(ofSize: $0, weight: .semibold) }),
        ("3 bold", { proportional($0, .bold) }), ("4 semibold", { proportional($0, .semibold) }),
        ("5 medium", { proportional($0, .medium) }), ("6 heavy", { proportional($0, .heavy) }),
        ("7 bold, 0.5pt larger", { proportional($0 + 0.5, .bold) }), ("8 semibold, 0.5pt larger", { proportional($0 + 0.5, .semibold) }),
        ("9 rounded bold", { rounded($0, .bold) }), ("10 rounded semibold", { rounded($0, .semibold) })]
    let samples = [Panel(id: "codex", name: "Codex", windows: [Window(label: "5h", pct: 30)]),
                   Panel(id: "claude", name: "Claude", windows: [Window(label: "5h", pct: 0)]),
                   Panel(id: "openrouter", name: "OpenRouter", windows: [Window(label: "OpenRouter", right: "$26.25 left")])]
    let sheet = NSImage(size: NSSize(width: 300, height: CGFloat(candidates.count) * 26 + 8))
    sheet.lockFocus()
    NSColor(srgbRed: 0.18, green: 0.20, blue: 0.30, alpha: 1).setFill(); NSRect(origin: .zero, size: sheet.size).fill()
    for (index, candidate) in candidates.enumerated() {
        HUD.digitFont = candidate.1
        let y = sheet.size.height - CGFloat(index + 1) * 26
        (candidate.0 as NSString).draw(at: NSPoint(x: 8, y: y + 6), withAttributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.white])
        var x: CGFloat = 160
        for sample in samples { let battery = delegate.icon(sample); battery.draw(at: NSPoint(x: x, y: y + 2), from: .zero, operation: .sourceOver, fraction: 1); x += battery.size.width + 8 }
    }
    sheet.unlockFocus()
    try! NSBitmapImageRep(data: sheet.tiffRepresentation!)!.representation(using: .png, properties: [:])!.write(to: delegate.home.appendingPathComponent("font-preview.png"))
    HUD.digitFont = candidates[0].1
    print("Battery drawing and note-free menus passed")
    exit(0)
}
app.delegate = delegate
app.run()
