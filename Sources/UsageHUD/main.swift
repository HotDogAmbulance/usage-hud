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

/// The hover panel for providers with per-key detail: the name in bold with a short grey summary beside it, any problem
/// below, then one small battery per key or pool, white while plenty is left, yellow under 30%, red under 10% (where your
/// own keys start to pulse). It sizes itself to its text.
final class CellsView: NSView {
    let title: String, subtitle: String, lines: [String], rows: [Window]
    static let head: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 12, weight: .semibold), .foregroundColor: NSColor.labelColor]
    static let body: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular), .foregroundColor: NSColor.secondaryLabelColor]
    let nameWidth: CGFloat, titleWidth: CGFloat
    let allCached: Bool, more: Int
    let moreHint: String
    let darkBar: Bool?
    let providerID: String?
    func detail(_ row: Window) -> String { (row.right ?? "") + (row.isCached && !allCached ? " · cached" : "") }
    init(title: String, subtitle: String? = nil, lines: [String] = [], rows: [Window], more: Int = 0, allReadingsCached: Bool? = nil, moreHint: String = "click battery for all", darkBar: Bool? = nil, providerID: String? = nil) {
        self.darkBar = darkBar; self.providerID = providerID
        self.title = title; self.lines = lines; self.rows = rows; self.more = more; self.moreHint = moreHint
        let allOld = allReadingsCached ?? (!rows.isEmpty && rows.allSatisfy(\.isCached))
        allCached = allOld
        self.subtitle = (subtitle ?? "") + (allCached ? (subtitle?.isEmpty == false ? " · cached" : "cached") : "")
        func width(_ text: String, _ style: [NSAttributedString.Key: Any]) -> CGFloat { ceil((text as NSString).size(withAttributes: style).width) }
        nameWidth = min(140, rows.map { width($0.label, Self.body) }.max() ?? 0)
        titleWidth = width(title, Self.head)
        let text = max(titleWidth + 8 + width(self.subtitle, Self.body), lines.map { width($0, Self.body) }.max() ?? 0,
                       nameWidth + 54 + (rows.map { width(($0.right ?? "") + ($0.isCached && !allOld ? " · cached" : ""), Self.body) }.max() ?? 0))
        super.init(frame: NSRect(x: 0, y: 0, width: min(560, max(220, text + 24)), height: CGFloat(18 + lines.count * 18 + rows.count * 20 + (more > 0 ? 18 : 0) + 16)))
        autoresizingMask = [.width]
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel(title + (self.subtitle.isEmpty ? "" : ", " + self.subtitle))
        let spoken: [String] = lines + rows.map(\.accessibilityReading) + (more > 0 ? ["\(more) more. " + moreHint + "."] : [])
        let children = spoken.enumerated().map { index, label in
            let element = NSAccessibilityElement.element(withRole: .staticText, frame: .zero, label: label, parent: self) as! NSAccessibilityElement
            let y = index < lines.count ? 26 + index * 18 : 26 + lines.count * 18 + (index - lines.count) * 20
            element.setAccessibilityFrameInParentSpace(NSRect(x: 12, y: CGFloat(y), width: frame.width - 24, height: index < lines.count ? 18 : 20))
            return element
        }
        setAccessibilityChildren(children)
        setAccessibilityHelp("Click the menu bar battery for all usage details.")
    }
    required init?(coder: NSCoder) { nil }
    override var isFlipped: Bool { true }
    override var allowsVibrancy: Bool { true }
    static func color(left: Double, dark: Bool) -> NSColor { left <= 0.1 ? .systemRed : left <= 0.3 ? .systemYellow : dark ? .white : .black }
    
    override func draw(_ dirtyRect: NSRect) {
        effectiveAppearance.performAsCurrentDrawingAppearance { drawContent() }
    }
    private func drawContent() {
        let clip = NSMutableParagraphStyle(); clip.lineBreakMode = .byTruncatingTail
        var head = Self.head, body = Self.body; head[.paragraphStyle] = clip; body[.paragraphStyle] = clip
        let dark = darkBar ?? (effectiveAppearance.bestMatch(from: [.darkAqua, .vibrantDark, .aqua, .vibrantLight]).map { $0 == .darkAqua || $0 == .vibrantDark } ?? false)
        let width = bounds.width - 24
        var y: CGFloat = 8
        (title as NSString).draw(in: NSRect(x: 12, y: y, width: width, height: 16), withAttributes: head)
        (subtitle as NSString).draw(in: NSRect(x: 20 + titleWidth, y: y + 1, width: max(0, width - titleWidth - 8), height: 16), withAttributes: body)
        y += 18
        for line in lines { (line as NSString).draw(in: NSRect(x: 12, y: y, width: width, height: 16), withAttributes: body); y += 18 }
        for row in rows {
            (row.label as NSString).draw(in: NSRect(x: 12, y: y + 2, width: nameWidth, height: 16), withAttributes: body)
            let x = 12 + nameWidth + 8
            if let used = row.pct {
                // Match the originating bar's contrast; inverse digits stay legible inside a differently shaded panel.
                let left = max(0, min(1, (100 - used) / 100)), shell = NSRect(x: x, y: y + 3, width: 36, height: 13)
                let image = NSImage(size: shell.size, flipped: false) { rect in
                    let outline = NSBezierPath(roundedRect: NSRect(x: 0, y: 0, width: 33, height: 13), xRadius: 3.5, yRadius: 3.5)
                    NSGraphicsContext.saveGraphicsState(); outline.addClip()
                    BatteryText.track(dark: dark).setFill(); rect.fill()
                    let fill = NSRect(x: 0, y: 0, width: 33 * left, height: 13)
                    let palette = self.providerID == "antigravity" ? row.palette ?? QuotaPalette.families([row.label]) : nil
                    if left <= 0.3 { Self.color(left: left, dark: dark).setFill(); fill.fill() }
                    else { BatteryPaint.fill(fill, body: NSRect(x: 0, y: 0, width: 33, height: 13), palette: palette, dark: dark) }
                    NSGraphicsContext.restoreGraphicsState()
                    (dark ? NSColor.white : NSColor.black).withAlphaComponent(0.45).setFill()
                    NSBezierPath(roundedRect: NSRect(x: 34, y: 4, width: 2, height: 5), xRadius: 1, yRadius: 1).fill()
                    BatteryText.draw(String(Int((left * 100).rounded())), font: .monospacedDigitSystemFont(ofSize: 9, weight: .semibold),
                                     body: NSRect(x: 0, y: 0, width: 33, height: 13),
                                     ink: left > 0.3 && (palette == .claudeOpenAI || palette == .openAI) ? .white : .black,
                                     cutout: left > 0.3 && palette != .claudeOpenAI && palette != .openAI)
                    return true
                }
                image.draw(in: shell, from: .zero, operation: .sourceOver, fraction: row.isCached ? 0.55 : 1, respectFlipped: true, hints: nil)
            }
            (detail(row) as NSString).draw(in: NSRect(x: x + 46, y: y + 2, width: bounds.width - x - 58, height: 16), withAttributes: body)
            y += 20
        }
        if more > 0 { ("\(more) more · " + moreHint as NSString).draw(in: NSRect(x: 12, y: y + 2, width: width, height: 16), withAttributes: body) }
    }
}

class HUD: NSObject, NSApplicationDelegate, NSMenuDelegate {
    var items: [String: StatusCell] = [:]
    lazy var group: StatusGroup = {
        let group = StatusGroup()
        group.item.button?.target = self; group.item.button?.action = #selector(groupClicked(_:))
        group.item.button?.sendAction(on: [.leftMouseDown, .rightMouseDown])
        (group.item.button?.cell as? NSButtonCell)?.highlightsBy = []
        group.content.appearanceChanged = { [weak self] in DispatchQueue.main.async { self?.updateContrast() } }
        return group
    }()
    let brandCell = StatusCell(id: "usage-hud", length: SystemBattery.stackedWidth + StatusGroup.gap)
    var contrastTimer: Timer?
    var openMenu: NSMenu?
    /// Any menu being tracked: a hover panel must not open under it, and one already open goes away.
    var menuTracking = false
    var hoverMonitor: Any?
    var panels: [String: Panel] = [:]
    var trackers: [String: HoverTracker] = [:]
    var hovered: String?
    /// Batteries past `visibleLimit` move into this item; hovering it opens their menu.
    var overflow: StatusCell?
    let logoPopover = NSPopover()
    /// Hidden batteries lowered out of the logo right now; the logo draws only what is left of itself.
    var arrangedIDs: [String] = []
    var shelf = Shelf(levels: UserDefaults.standard.dictionary(forKey: "shelfLevels") as? [String: Double] ?? [:],
                      lastUsed: UserDefaults.standard.dictionary(forKey: "shelfLastUsed") as? [String: Double] ?? [:],
                      scores: UserDefaults.standard.dictionary(forKey: "shelfScores") as? [String: Double] ?? [:],
                      scoredAt: UserDefaults.standard.double(forKey: "shelfScoredAt"),
                      pins: UserDefaults.standard.stringArray(forKey: "shelfPins") ?? [],
                      pinnedAt: UserDefaults.standard.dictionary(forKey: "shelfPinnedAt") as? [String: Double] ?? [:])
    /// Change with `defaults write local.usage-hud visibleBatteries 4`.
    var visibleLimit: Int { UserDefaults.standard.integer(forKey: "visibleBatteries") > 0 ? UserDefaults.standard.integer(forKey: "visibleBatteries") : 3 }
    /// Alerts the user has already seen by hovering, by provider; those batteries stop pulsing until the alert changes.
    var acknowledged: [String: String] = [:]
    var pulse: Timer?
    let popover = HoverSurface()
    let modelPopover = HoverSurface()
    /// A newer release, offered at the foot of every battery menu.
    var update: (tag: String, page: URL)?
    var busy = false
    var pendingCacheRead = false
    var pendingAlso: Set<String> = []
    var pendingAutomaticRead = false
    var sourceChanges = SourceChanges()
    var sourceNoticesReady = false
    let sourceNotice = SourceNoticePresenter()
    var lastNoticeAnchor: (rect: NSRect, screen: NSScreen)?
    /// A Refresh chosen while a background pass is running; it runs as soon as that pass ends.
    var pending: String?
    var lockDescriptor: Int32 = -1
    let engine = Engine()
    var home: URL { engine.root }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NotificationCenter.default.addObserver(forName: NSMenu.didBeginTrackingNotification, object: nil, queue: .main) { [weak self] _ in
            self?.menuTracking = true; self?.closeHover()
        }
        NotificationCenter.default.addObserver(forName: NSMenu.didEndTrackingNotification, object: nil, queue: .main) { [weak self] _ in self?.menuTracking = false }
        // A click anywhere else (another app, the desktop) puts a hover panel away; clicks on the bar are handled by the cell.
        hoverMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in self?.closeHover() }
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
        contrastTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.updateContrast() }
        load(nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { self.load("automatic") }
        // Claude Code's hooks and statusline bring Claude's readings while it runs; added once, and again whenever
        // Claude Code is (re)installed, unless the person switched them off from Claude's menu.
        connectClaudeCode()
        DistributedNotificationCenter.default().addObserver(self, selector: #selector(claudeCodeRan(_:)), name: Engine.claudeCodeRan,
                                                            object: nil, suspensionBehavior: .deliverImmediately)
        DistributedNotificationCenter.default().addObserver(self, selector: #selector(claudeUsageRead(_:)), name: Engine.claudeUsageRead,
                                                            object: nil, suspensionBehavior: .deliverImmediately)
        Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in self?.load("automatic"); self?.connectClaudeCode() }
        Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in self?.load(nil) }
        // A provider used in the last ten minutes refreshes every minute, so its battery follows a chat as it happens.
        Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            let now = Date().timeIntervalSince1970, active = Set(self.shelf.lastUsed.filter { now - $0.value < 600 }.keys)
            if !active.isEmpty { self.load(nil, also: active) }
        }
        let lowBalance = UserDefaults.standard.double(forKey: "lowBalance")
        if lowBalance > 0 { engine.lowBalance = lowBalance }
        checkForUpdate()
        Timer.scheduledTimer(withTimeInterval: 86400, repeats: true) { [weak self] _ in self?.checkForUpdate() }
        DistributedNotificationCenter.default().addObserver(forName: NSNotification.Name("AppleInterfaceThemeChangedNotification"),
                                                            object: nil, queue: .main) { [weak self] _ in
            guard let self = self else { return }
            Array(self.panels.values).forEach { self.render($0) }
            if let id = self.hovered { self.showHover(id) }
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
    /// Points our folder's stable link at this app and keeps Claude Code's hooks in step. Only an installed app does this;
    /// a build run from Terminal, or a copy macOS runs from a temporary place before it's moved, does not.
    func connectClaudeCode() {
        guard Bundle.main.bundleURL.pathExtension == "app", let executable = Bundle.main.executablePath,
              !executable.contains("/AppTranslocation/") else { return }
        let link = home.appendingPathComponent("usagehud"), files = FileManager.default
        let target = try? files.destinationOfSymbolicLink(atPath: link.path)
        if target != executable && (target != nil || !files.fileExists(atPath: link.path)) {
            try? files.removeItem(at: link); try? files.createSymbolicLink(atPath: link.path, withDestinationPath: executable)
        }
        _ = try? engine.connectClaudeCode(engine.claudeCodeConnected)
    }
    /// Claude Code started, took a prompt or finished a turn: read Claude now (at most once a minute) with the Keychain
    /// answer this app already holds, so nothing new is asked.
    var claudeNudged = 0.0
    @objc func claudeCodeRan(_ note: Notification) {
        let now = Date().timeIntervalSince1970
        guard now - claudeNudged > 60 else { return }
        claudeNudged = now; load(nil, also: ["claude"])
    }
    /// A committed quota write wakes the cache display without asking OAuth.
    @objc func claudeUsageRead(_ note: Notification) { load(nil) }
    @objc func toggleClaudeCode() {
        engine.claudeCodeConnected.toggle()
        connectClaudeCode()
        if let panel = panels["claude"] { render(panel) }
    }
    @objc func openUpdate() { if let page = update?.page { NSWorkspace.shared.open(page) } }
    func load(_ refresh: String?, also: Set<String> = []) {
        guard !busy else {
            if refresh == "automatic" { pendingAutomaticRead = true }
            else if let refresh = refresh { pending = refresh }
            else { pendingCacheRead = true; pendingAlso.formUnion(also) }
            return
        }
        busy = true
        DispatchQueue.global(qos: .utility).async {
            let panels = self.engine.panels(refresh: refresh, also: also)
            let gone = self.engine.goneSources
            DispatchQueue.main.async {
                self.busy = false
                // Batteries are placed as they first appear, so the most used one takes the first spot, then the next.
                let rank = self.shelf.ranked(panels.map { $0.id })
                for panel in panels.sorted(by: { rank.firstIndex(of: $0.id)! < rank.firstIndex(of: $1.id)! }) {
                    self.render(panel); self.shelf.observe(panel, now: Date().timeIntervalSince1970)
                }
                UserDefaults.standard.set(self.shelf.levels, forKey: "shelfLevels")
                UserDefaults.standard.set(self.shelf.lastUsed, forKey: "shelfLastUsed")
                UserDefaults.standard.set(self.shelf.scores, forKey: "shelfScores")
                UserDefaults.standard.set(self.shelf.scoredAt, forKey: "shelfScoredAt")
                self.rememberSourceNoticeAnchor()
                self.arrange(panels.map { $0.id })
                let notice = self.sourceChanges.update(panels: panels, gone: gone, announce: self.sourceNoticesReady)
                if refresh == "automatic" { self.sourceNoticesReady = true }
                if let notice = notice { self.showSourceNotice(notice) }
                self.renewClaudeIfExpired(panels)
                if let next = self.pending { self.pending = nil; self.load(next) }
                else if self.pendingAutomaticRead { self.pendingAutomaticRead = false; self.load("automatic") }
                else if self.pendingCacheRead {
                    self.pendingCacheRead = false
                    let also = self.pendingAlso; self.pendingAlso = []
                    self.load(nil, also: also)
                }
            }
        }
    }
    func rememberSourceNoticeAnchor() {
        // The overflow belongs to this app too; never anchor a notice to another app’s menu item.
        let button = overflow?.isVisible == true ? overflow?.button :
            items.sorted(by: { $0.key < $1.key }).first(where: { $0.value.isVisible })?.value.button
        guard let button = button, let window = button.window, let screen = window.screen else { return }
        let anchor = window.convertToScreen(button.convert(button.bounds, to: nil))
        lastNoticeAnchor = (anchor, screen)
    }
    func showSourceNotice(_ notice: SourceNotice) {
        rememberSourceNoticeAnchor()
        guard let anchor = lastNoticeAnchor else { return }
        sourceNotice.show(notice, below: anchor.rect, screen: anchor.screen)
    }
    /// The 7d layer's colour where a brand has a second one; the others tone their main colour down.
    static let side: [String: NSColor] = [
        "glm": NSColor(srgbRed: 0.7843, green: 1.0, blue: 1.0, alpha: 1),
        "fireworks": NSColor(srgbRed: 0.2039, green: 0.0667, blue: 0.502, alpha: 1),
        "litellm": NSColor(srgbRed: 91.0 / 255, green: 63.0 / 255, blue: 209.0 / 255, alpha: 1)]
    static let yellow = NSColor(srgbRed: 1.0, green: 0.8471, blue: 0.0, alpha: 1), red = NSColor(srgbRed: 1.0, green: 0.2314, blue: 0.1882, alpha: 1)
    func tint(_ id: String) -> NSColor {
        switch id {
        // No tint is pale and grey at once, so from across the room no battery reads as the Mac's own white one.
        // Brand colours where the brand has one; black-and-white marks get distinct mid tones.
        case "codex": return NSColor(srgbRed: 0.40, green: 0.82, blue: 0.74, alpha: 1)
        case "claude": return NSColor(srgbRed: 0.85, green: 0.58, blue: 0.45, alpha: 1)
        case "glm": return NSColor(srgbRed: 0.0039, green: 0.5961, blue: 0.6078, alpha: 1)
        case "antigravity": return NSColor(srgbRed: 0.19, green: 0.53, blue: 1.00, alpha: 1)
        // Grok is black; xAI the same family in graphite blue, so the two read as one house but not as one battery.
        case "grok": return NSColor(srgbRed: 0.0, green: 0.0, blue: 0.0, alpha: 1)
        // Grok Bot: a warm charcoal between the two, still dark enough to sit with them.
        case "grokbot": return NSColor(srgbRed: 0.2392, green: 0.2078, blue: 0.1922, alpha: 1)
        case "xai": return NSColor(srgbRed: 0.1843, green: 0.2275, blue: 0.3216, alpha: 1)
        case "vercel": return NSColor(srgbRed: 0.58, green: 0.56, blue: 0.54, alpha: 1)
        case "deepseek": return NSColor(srgbRed: 0.30, green: 0.42, blue: 1.00, alpha: 1)
        case "kimi": return NSColor(srgbRed: 0.0667, green: 0.3804, blue: 0.7451, alpha: 1)
        case "kimi-code": return NSColor(srgbRed: 0.0784, green: 0.4902, blue: 0.9529, alpha: 1)
        case "openrouter": return NSColor(srgbRed: 200.0 / 255, green: 254.0 / 255, blue: 1.0 / 255, alpha: 1)
        // The same yellow and red everywhere: a balance getting low, every Antigravity pool spent, the small bars in the hover panel.
        case "caution": return HUD.yellow
        case "critical": return HUD.red
        case "fireworks": return NSColor(srgbRed: 0.3647, green: 0.1098, blue: 0.902, alpha: 1)
        case "litellm": return NSColor(srgbRed: 1.0 / 255, green: 23.0 / 255, blue: 190.0 / 255, alpha: 1)
        default: return NSColor(srgbRed: 0.65, green: 0.57, blue: 0.92, alpha: 1)
        }
    }
    /// Whether the menu bar is dark; it follows the wallpaper, so it can differ from the system appearance.
    /// Set by `--self-test` to draw the contact sheet for a bar of either shade.
    var forcedDarkBar: Bool?
    var darkMenuBar: Bool {
        if let forced = forcedDarkBar { return forced }
        return group.dark
    }
    /// Repaint only when AppKit's actual menu-bar ink changes, including a wallpaper change in the same mode.
    func updateContrast() {
        guard forcedDarkBar == nil, let button = group.item.button, let dark = MenuBarInk.isDark(button), dark != group.dark else { return }
        group.dark = dark
        brandCell.button?.contentTintColor = dark ? .white : .black
        overflow?.button?.contentTintColor = dark ? .white : .black
        brandCell.button?.image = SystemBattery.stacked(dark: dark); overflow?.button?.image = logoImage()
        fades.removeAll()
        for panel in Array(panels.values) { render(panel) }
        if let id = hovered { showHover(id) }
    }
    func closeHover() {
        let id = hovered; hovered = nil; popover.close(); modelPopover.close()
        if let id = id { drawIcon(id) }
    }
    func configure(_ cell: StatusCell) {
        cell.button?.target = self; cell.button?.action = #selector(openCell(_:))
        cell.button?.contentTintColor = darkMenuBar ? .white : .black
        cell.button?.beforeClick = { [weak self] in self?.closeHover() }
        cell.button?.onDrop = { [weak self] urls in self?.addSources(urls) }
    }
    let renewal = ClaudeRenewal()
    var renewing = false
    /// An expired Claude Code credential is renewed by Claude Code itself with one tiny request; see `ClaudeRenewal` for its limits.
    func renewClaudeIfExpired(_ panels: [Panel]) {
        guard !renewing, let claude = panels.first(where: { $0.id == "claude" }), claude.note.contains("credential expired") else { return }
        renewing = true
        let saved = (try? Data(contentsOf: home.appendingPathComponent("claude.json"))).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
        let real = saved["source"] as? String == "statusline" ? (saved["captured_at"] as? NSNumber)?.doubleValue ?? 0 : 0
        DispatchQueue.global(qos: .utility).async {
            let notice = self.renewal.renewIfDue(lastRealUse: real)
            DispatchQueue.main.async {
                self.renewing = false
                guard let notice = notice else { return }
                self.showSourceNotice(notice); self.load("automatic")
            }
        }
    }
    /// Files or folders dropped on the bar, or chosen from the tray: only their paths are kept.
    func addSources(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        let found = KeySources.add(urls)
        showSourceNotice(SourceNotice(title: found > 0 ? "Looking for your keys" : "No OpenRouter key in what you chose",
                                      lines: [found > 0 ? "\(found) OpenRouter key\(found == 1 ? "" : "s") found; reading their balances now. Only the paths are remembered."
                                                        : "Other providers' keys in those files are read too. Only the paths are remembered."]))
        load("automatic")
    }
    @objc func addSourceFromMenu() { chooseSources() }
    func chooseSources() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true; panel.canChooseDirectories = true; panel.allowsMultipleSelection = true
        panel.showsHiddenFiles = true
        panel.message = "Choose files or folders that hold your API keys. Usage HUD reads them on this Mac and remembers only their paths."
        panel.prompt = "Add"
        NSApp.activate(ignoringOtherApps: true)
        if panel.runModal() == .OK { addSources(panel.urls) }
    }
    /// What the logo shows: all of it, the rear battery alone while one is lowered, nothing while two or more are.
    func logoImage() -> NSImage {
        let dark = darkMenuBar
        return SystemBattery.stacked(dark: dark)
    }
    /// With the click log on, say which menu or submenu really appears and which entry it hangs from.
    func menuWillOpen(_ menu: NSMenu) {
        let parent = menu.supermenu?.items.first { $0.submenu === menu }?.title ?? "-"
        ClickLog.write("menu opens first=\(menu.items.first?.title ?? "-") parent=\(parent)")
    }
    /// A click the status item itself received instead of one of its cells goes to the cell under the pointer.
    @objc func groupClicked(_ sender: NSStatusBarButton) {
        let cell = group.cellButton()
        ClickLog.write("status item click, pointer over \(cell?.sourceID ?? "none")")
        cell?.beforeClick(); cell?.performClick(nil)
    }
    @objc func openCell(_ sender: StatusCellButton) {
        closeHover()
        // A left click on the logo opens the system's popover; the right click keeps the plain menu.
        if (sender.sourceID == "overflow" || sender.sourceID == "usage-hud"), NSApp.currentEvent?.type != .rightMouseDown {
            if logoPopover.isShown { logoPopover.close() } else { showLogoPopover(from: sender, hidden: sender.sourceID == "overflow") }
            return
        }
        let cell = sender.sourceID == "overflow" ? overflow : sender.sourceID == "usage-hud" ? brandCell : items[sender.sourceID]
        guard let menu = cell?.menu else { ClickLog.write("open \(sender.sourceID) no menu"); return }
        ClickLog.write("open \(sender.sourceID) menu=\(menu.items.first?.title ?? "-") items=\(menu.items.count)")
        openMenu = menu
        // Placed in screen coordinates just under the cell: a point in the cell's own coordinates put the menu above the bar.
        if let window = sender.window {
            let rect = window.convertToScreen(sender.convert(sender.bounds, to: nil))
            menu.popUp(positioning: nil, at: NSPoint(x: rect.minX, y: rect.minY - 9), in: nil)
        } else {
            menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.minY - 3), in: sender)
        }
        openMenu = nil
    }
    /// Fills `rect` with the provider tint, or the model-family palette carried by an Antigravity row.
    /// The 5h colour is always the one chosen for the provider, on any bar. `muted` is the 7d layer behind it: the same colour at
    /// about half strength over the empty part (which is the bar's own ink), so it stays between the colour and the empty part
    /// whatever the wallpaper; a provider with its own 7d colour uses that.
    func paint(_ rect: NSRect, body: NSRect, id: String, light: Bool, muted: Bool = false, alpha: CGFloat, dark: Bool = true, palette: QuotaPalette? = nil) {
        let shade = { (color: NSColor) -> NSColor in
            var color = color
            // Black and graphite would vanish on a dark bar; lift them just enough to read as a battery.
            if dark, let rgb = color.usingColorSpace(.sRGB), max(rgb.redComponent, rgb.greenComponent, rgb.blueComponent) < 0.35 {
                color = color.blended(withFraction: max(rgb.redComponent, rgb.greenComponent, rgb.blueComponent) < 0.05 ? 0.55 : 0.40, of: .white)!
            }
            if muted, let side = Self.side[id] { return side.withAlphaComponent(alpha) }
            if muted { return color.withAlphaComponent(alpha * 0.55) }
            return (light ? color.blended(withFraction: dark ? 0.65 : 0.45, of: .white)! : color).withAlphaComponent(alpha)
        }
        // The battery warning yellow stays the Mac's own on a light bar too; deepening it would turn it to mud.
        if id == "caution" || id == "critical" { tint(id).withAlphaComponent(alpha).setFill(); rect.fill(); return }
        if id == "antigravity" {
            BatteryPaint.fill(rect, body: body, palette: palette, dark: dark, alpha: alpha); return
        }
        guard id == "litellm" else { shade(tint(id)).setFill(); rect.fill(); return }
        let marks: [(CGFloat, CGFloat, CGFloat)] = [(1.0 / 255, 23.0 / 255, 190.0 / 255), (91.0 / 255, 63.0 / 255, 209.0 / 255)]
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
        if hovered == id, let weekly = hoverPanel(panel) { button.image = icon(weekly, weeklyShade: true); return }
        // OpenRouter's nudge is a faint breath: plenty of people sit just above $10 on purpose.
        let target = icon(panel, glow: pulsing(id) ? glow() * (id == "openrouter" ? 0.4 : 1) : 0)
        // When the battery moves to another reading (Antigravity's pools take turns), it dissolves into it.
        let label = displayedQuota(panel)?.label, now = Date().timeIntervalSinceReferenceDate
        if let before = shownLabel[id], before != label, let old = button.image { fades[id] = (old, now) }
        shownLabel[id] = label
        guard let fade = fades[id], now - fade.start < Self.fadeLength else { fades[id] = nil; button.image = target; return }
        let mix = CGFloat((now - fade.start) / Self.fadeLength)
        let frame = NSImage(size: target.size)
        frame.lockFocus()
        fade.from.draw(in: NSRect(origin: .zero, size: fade.from.size), from: .zero, operation: .sourceOver, fraction: 1 - mix)
        target.draw(in: NSRect(origin: .zero, size: target.size), from: .zero, operation: .sourceOver, fraction: mix)
        frame.unlockFocus()
        button.image = frame
        if fadeTimer == nil {
            fadeTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { [weak self] timer in
                guard let self = self, !self.fades.isEmpty else { timer.invalidate(); self?.fadeTimer = nil; return }
                for id in Array(self.fades.keys) { self.drawIcon(id) }
            }
        }
    }
    static let fadeLength = 0.4
    var shownLabel: [String: String?] = [:]
    var fades: [String: (from: NSImage, start: TimeInterval)] = [:]
    var fadeTimer: Timer?
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
    /// macOS 27's battery digits: SF Pro with tabular figures (the "1" has a foot), Regular, about 10pt. Measured on a zoomed
    /// menu bar: the system's digits stand 7.5pt tall with 1pt strokes, where Medium 11pt stood 8pt with 1.5pt strokes.
    static var digitFont: (CGFloat) -> NSFont = { tabular($0 + 0.5, .regular) }
    static func tabular(_ size: CGFloat, _ weight: NSFont.Weight) -> NSFont { NSFont.monospacedDigitSystemFont(ofSize: size, weight: weight) }
    func icon(_ panel: Panel, weeklyShade: Bool = false, glow: CGFloat = 0) -> NSImage {
        let quota = displayedQuota(panel)
        let valid = quota != nil
        // Antigravity's pools are separate quotas: red, like the Mac's battery under 20%, only once every one is nearly spent.
        let pools = panel.windows.compactMap { $0.pct }
        var critical = panel.id == "antigravity" && !pools.isEmpty && pools.allSatisfy { 100 - $0 <= 20 }
        // Everything else keeps its own colour until what is left of the 5h and 7d windows (the tighter of the two) is 15%, then 10%.
        var caution = panel.caution != nil
        if let shown = quota, panel.id != "antigravity", shown.stale != true, shown.expired != true {
            let spans = panel.windows.filter { ($0.label == "5h" || $0.label == "7d") && $0.pct != nil && $0.stale != true && $0.expired != true }
            let free = (spans.isEmpty ? [shown] : spans).map { 100 - ($0.pct ?? 0) }.min() ?? 100
            if free <= 10 { critical = true } else if free <= 15 { caution = true }
        }
        let palette = panel.id == "antigravity" ? quota?.palette ?? QuotaPalette.families([quota?.label ?? ""]) : nil
        let warning = critical ? "critical" : caution ? "caution" : panel.id
        let moneyWindow = quota == nil ? panel.windows.first(where: {$0.label == panel.name}) : nil
        let cached = quota?.isCached == true || moneyWindow?.isCached == true
        let remaining = valid ? min(100, max(0, 100 - (quota?.pct ?? 0))) : 0
        let money = moneyWindow?.right?.components(separatedBy: " left").first
        var text = valid ? String(Int(remaining.rounded())) : money.map { String($0.drop { !$0.isNumber && $0 != "-" }) } ?? "?"
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
        let fillEnd = money != nil ? pixel(bodyWidth * CGFloat(panel.gauge ?? 1)) : pixel(fillWidth)
        let weeklyEnd = weeklyValid ? max(fillEnd, pixel(bodyWidth * weeklyRemaining / 100)) : fillEnd
        let weeklyAlpha: CGFloat = weekly?.stale == true || weekly?.expired == true ? 0.50 : 1, fillAlpha: CGFloat = cached ? (money != nil ? 0.50 : 0.45) : 1
        // The 7d layer and any translucent layer sit on the track, so they keep their place between colour and empty.
        let trackStart = fillAlpha < 1 || weeklyShade ? 0 : fillEnd
        BatteryText.track(dark: dark).setFill(); span(trackStart, bodyWidth).fill()
        if weeklyEnd > fillEnd {
            paint(span(fillEnd, weeklyEnd), body: bodyRect, id: warning, light: false, muted: true, alpha: weeklyAlpha, dark: dark, palette: palette)
        }
        paint(span(0, fillEnd), body: bodyRect, id: warning, light: money != nil && panel.caution == nil && panel.id != "litellm", muted: weeklyShade, alpha: fillAlpha, dark: dark, palette: palette)
        if glow > 0 { HUD.red.withAlphaComponent(glow).setFill(); bodyRect.fill() }
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
        // Keep native-style cut-out digits; the body/track follows the actual menu-bar contrast.
        // Solid black warning digits stay readable on a yellow fill over a light wallpaper.
        BatteryText.draw(text, font: font, body: bodyRect, ink: .black,
                         cutout: warning != "caution" && warning != "critical")
        image.unlockFocus()
        return image
    }
    func render(_ panel: Panel) {
        let item = items[panel.id] ?? StatusCell(id: panel.id)
        configure(item)
        items[panel.id] = item
        panels[panel.id] = panel
        if trackers[panel.id] == nil, let button = item.button {
            let tracker = HoverTracker(), id = panel.id
            tracker.changed = { [weak self, weak button] inside in
                guard let self = self else { return }
                if inside {
                    // The tracking area is rebuilt whenever the battery is redrawn, which reports a leave and an enter at once.
                    if self.hovered == id { return }
                    self.hovered = id; self.acknowledged[id] = self.panels[id]?.alert
                    // Just long enough to ignore a pointer passing over on its way elsewhere.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { self.showHover(id) }
                } else {
                    // Leaving counts only if the pointer is really outside a moment later.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) {
                        if let button = button, let window = button.window,
                           window.convertToScreen(button.convert(button.bounds, to: nil)).contains(NSEvent.mouseLocation) { return }
                        if self.hovered == id { self.hovered = nil }
                        if self.popover.isShown { self.popover.close() }
                        self.modelPopover.close()
                        self.updatePulse(); self.drawIcon(id)
                    }
                    return
                }
                self.updatePulse()
                self.drawIcon(id)
            }
            button.addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                                  owner: tracker, userInfo: nil))
            trackers[panel.id] = tracker
        }
        drawIcon(panel.id)
        item.length = (item.button?.image?.size.width ?? 28) + StatusGroup.gap
        let displayed = displayedQuota(panel)
        let mainBalance = panel.windows.first { $0.label == panel.name }
        let cached = displayed?.isCached == true || mainBalance?.isCached == true
        let reading = displayed.map { $0.label + (cached ? " · cached" : " · remaining") }
            ?? ((mainBalance?.right ?? "balance") + (cached ? " · cached" : ""))
        // Money rows (credits, extra usage) ride along in the hover text, so balances need no click.
        let money = panel.windows.filter { $0.pct == nil && $0.right != nil && $0.label != panel.name }.map { "\n" + $0.label + ": " + ($0.right ?? "") + ($0.isCached ? " · cached" : "") }
        if panel.alert == nil { acknowledged[panel.id] = nil }
        // Providers with per-key cells get the hover panel instead of a tooltip.
        item.button?.toolTip = !panel.cells.isEmpty ? nil : (panel.alert.map { "⚠︎ " + $0 + "\n" } ?? "") + (panel.fix.map { _ in "Click to sign in again\n" } ?? "") + panel.name + " · " + reading + (hoverPanel(panel) != nil ? "; lighter fill = 7d, hover to show 7d" : "") + money.joined()
        item.button?.setAccessibilityLabel(panel.name + " usage")
        item.button?.setAccessibilityValue(panel.windows.map(\.accessibilityReading).joined(separator: "; "))
        item.button?.setAccessibilityHelp(([panel.alert, panel.note.isEmpty ? nil : panel.note,
            "Click for usage details and refresh actions"].compactMap { $0 }).joined(separator: ". "))
        updatePulse()
        item.menu = providerMenu(panel)
        if hovered == panel.id && popover.isShown { showCells(panel.id) }
    }
    /// Construct a fresh menu for both the status item and overflow: copying an NSMenu archives its views.
    func providerMenu(_ panel: Panel) -> NSMenu {
        let displayed = displayedQuota(panel)
        let balance = panel.windows.first { $0.label == panel.name }
        let cached = displayed?.isCached == true || balance?.isCached == true
        let menu = NSMenu(); menu.delegate = self
        if !panel.cells.isEmpty {
            let detail = NSMenuItem(title: panel.name + " usage", action: nil, keyEquivalent: "")
            detail.view = cellsView(panel, inMenu: true)
            menu.addItem(detail)
        } else {
            let lines = HUD.menuLines(panel, showingWeek: displayed?.label == "7d", cached: cached)
            let width = min(580, max(220, (lines.map { ceil($0.size().width) }.max() ?? 0) + 28))
            for line in lines {
                let item = menu.addItem(withTitle: line.string, action: nil, keyEquivalent: "")
                item.view = MenuReadingView(line, width: width)
            }
        }
        // Keep complete names available when the compact view truncates labels or limits rows.
        if panel.cells.contains(where: { cell in !panel.windows.contains { $0.label == cell.label } }) || panel.cells.count > 5 || panel.cells.contains(where: { ($0.label as NSString).size(withAttributes: CellsView.body).width > 140 }) {
            let all = NSMenu()
            for cell in panel.cells { all.addItem(withTitle: cell.label + " · " + (cell.right ?? "") + (cell.isCached ? " · cached" : ""), action: nil, keyEquivalent: "") }
            menu.addItem(withTitle: (panel.id == "openrouter" ? "All keys" : "All budgets") + " (\(panel.cells.count))", action: nil, keyEquivalent: "").submenu = all
        }
        menu.addItem(NSMenuItem.separator())
        if signingIn == panel.id {
            menu.addItem(withTitle: "Approve the sign-in in your browser…", action: nil, keyEquivalent: "")
        } else if let fix = panel.fix {
            let item = menu.addItem(withTitle: "Sign in to " + panel.name + " again…", action: #selector(runFix(_:)), keyEquivalent: "")
            item.representedObject = [panel.id, fix]; item.target = self
        }
        // Claude's connection/refresh controls stay hidden while Desktop quota delivery is unresolved.
        if panel.id != "claude" {
            let refresh = menu.addItem(withTitle: "Refresh " + panel.name, action: #selector(refreshProvider(_:)), keyEquivalent: "r")
            refresh.representedObject = panel.id; refresh.target = self
        }
        if panel.id == "codex" {
            let credits = menu.addItem(withTitle: "Refresh OpenAI API credits", action: #selector(refreshProvider(_:)), keyEquivalent: "")
            credits.representedObject = "openai-credits"; credits.target = self
        }
        if let update = update {
            menu.addItem(withTitle: "Update available: " + update.tag + "…", action: #selector(openUpdate), keyEquivalent: "").target = self
        }
        menu.addItem(withTitle: "Quit Usage HUD", action: #selector(quit), keyEquivalent: "q").target = self
        return menu
    }
    /// The menu's reading, kept short: the name in bold (with its plan or balance), then one line per window with its
    /// value in bold and grey detail after it, values lined up on a tab stop. "↻ 4h 11m" is when it refills.
    static func menuLines(_ panel: Panel, showingWeek: Bool, cached: Bool) -> [NSAttributedString] {
        let size = NSFont.menuFont(ofSize: 0).pointSize, now = Date().timeIntervalSince1970
        let plain = NSFont.menuFont(ofSize: 0), strong = NSFont.monospacedDigitSystemFont(ofSize: size, weight: .semibold)
        let grey: [NSAttributedString.Key: Any] = [.font: plain, .foregroundColor: NSColor.secondaryLabelColor]
        let rows = panel.windows.filter { $0.label != panel.name }
        // When every reading is old (the app behind it closed), "cached" is said once, after the name.
        let old = !panel.windows.isEmpty && panel.windows.allSatisfy(\.isCached)
        let tabs = NSMutableParagraphStyle()
        tabs.tabStops = [NSTextTab(textAlignment: .left, location: (rows.map { ($0.label as NSString).size(withAttributes: grey).width }.max() ?? 0) + 16)]
        func line(_ parts: [(String, Bool)]) -> NSAttributedString {
            let text = NSMutableAttributedString()
            for (part, bold) in parts where !part.isEmpty {
                text.append(NSAttributedString(string: part, attributes: [.font: bold ? strong : plain, .paragraphStyle: tabs,
                                                                          .foregroundColor: bold ? NSColor.labelColor : NSColor.secondaryLabelColor]))
            }
            return text
        }
        // "max" and "PRO" read "Max" and "Pro"; a name already in its own case ("SuperGrok Heavy") stays as it is.
        let plan = panel.note.hasPrefix("Plan: ") ? String(panel.note.dropFirst(6)) : nil
        let tidy = plan.map { $0 == $0.lowercased() || $0 == $0.uppercased() ? $0.capitalized : $0 }
        let balance = panel.windows.first { $0.label == panel.name }
        var lines = [line([(panel.name, true), (tidy.map { " · " + $0 } ?? "", false), (balance?.right.map { "  " + $0 } ?? "", true),
                           (balance?.isCached == true || old ? " · cached" : "", false)])]
        if let alert = panel.alert { lines.append(line([("⚠︎ " + alert, false)])) }
        if showingWeek { lines.append(line([("Showing 7d" + (cached && !old ? " · cached" : ""), false)])) }
        if !panel.note.isEmpty && plan == nil && panel.note != panel.alert { lines.append(line([(panel.note, false)])) }
        for row in rows {
            // "96% left · ↻ 4h 11m" for a quota; "$0 / $20 · this month" for money, the part before the first dot in bold.
            var parts = (row.right ?? "Unavailable").components(separatedBy: " · "), unit = ""
            if let pct = row.pct {
                parts = ["\(Int((100 - pct).rounded()))%"]; unit = " left"
                if row.expired == true { parts.append("waiting for its reset") }
                else if let reset = row.resets_at, reset > now { parts.append("↻ " + countdown(reset - now)) }
            }
            if row.isCached && !old { parts.append("cached") }
            lines.append(line([(row.label + "\t", false), (parts[0], true), (unit + parts.dropFirst().map { " · " + $0 }.joined(), false)]))
        }
        return lines
    }
    /// Keeps the most recently used batteries in the menu bar, so a crowded bar or the notch never hides them silently.
    func arrange(_ ids: [String]) {
        arrangedIDs = ids
        let arrangement = shelf.arrange(ids, limit: visibleLimit, urgent: Set(ids.filter { panels[$0]?.alert != nil }))
        let hidden = arrangement.hidden
        for (id, item) in items { item.isVisible = ids.contains(id) && !hidden.contains(id) }
        let leading: StatusCell
        if hidden.isEmpty {
            overflow?.isVisible = false; leading = brandCell
            brandCell.button?.setAccessibilityLabel("Usage HUD, all usage batteries")
            brandCell.button?.toolTip = "Usage HUD · all providers"
        } else {
            let item = overflow ?? StatusCell(id: "overflow", length: SystemBattery.stackedWidth + StatusGroup.gap)
            overflow = item; item.isVisible = true; leading = item
            let names = hidden.compactMap { panels[$0]?.name }
            item.button?.toolTip = "Usage HUD · +\(hidden.count) more: " + names.prefix(5).joined(separator: ", ") + (names.count > 5 ? "…" : "")
            item.button?.setAccessibilityLabel("Usage HUD, \(hidden.count) more usage batteries")
        }
        configure(leading)
        leading.button?.image = leading === overflow ? logoImage() : SystemBattery.stacked(dark: darkMenuBar)
        let menu = NSMenu()
        for id in hidden.isEmpty ? ids : hidden {
            guard let panel = panels[id] else { continue }
            let balance = panel.windows.first { $0.label == panel.name }?.right
            let entry = menu.addItem(withTitle: panel.name + (balance.map { "  " + $0 } ?? ""), action: nil, keyEquivalent: "")
            let detail = providerMenu(panel)
            if !hidden.isEmpty {
                let keep = NSMenuItem(title: "Keep in the menu bar", action: #selector(keepInBarItem(_:)), keyEquivalent: "")
                keep.target = self; keep.representedObject = id
                detail.insertItem(keep, at: 0); detail.insertItem(NSMenuItem.separator(), at: 1)
            }
            entry.image = icon(panel); entry.submenu = detail
        }
        menu.addItem(NSMenuItem.separator())
        menu.addItem(withTitle: "Add source…", action: #selector(addSourceFromMenu), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Quit Usage HUD", action: #selector(quit), keyEquivalent: "q").target = self
        menu.delegate = self
        leading.menu = menu
        group.install([leading] + arrangement.shown.compactMap { items[$0] })
        updateContrast()
    }
    /// Chosen from a hidden battery's menu: it takes a place in the bar, as a battery picked from the old drop did.
    @objc func keepInBarItem(_ sender: NSMenuItem) { if let id = sender.representedObject as? String { keepInBar(id) } }
    func keepInBar(_ id: String) {
        shelf.pin(id)
        UserDefaults.standard.set(shelf.pins, forKey: "shelfPins"); UserDefaults.standard.set(shelf.pinnedAt, forKey: "shelfPinnedAt")
        arrange(arrangedIDs)
    }
    /// One presentation of keys/pools/budgets, whether the provider is visible or folded into overflow.
    func cellsView(_ panel: Panel, inMenu: Bool = false) -> CellsView {
        var lines = [panel.alert.map { "⚠︎ " + $0 }, panel.note.isEmpty || panel.note == panel.alert ? nil : panel.note].compactMap { $0 }
        let balance = panel.windows.first { $0.label == panel.name }
        // Retain any additional accounting lines that the key/pool rows do not already describe.
        for row in panel.windows where row.label != panel.name && row.pct == nil && row.label != "Team" {
            if let value = row.right, !panel.cells.contains(where: { $0.label == row.label || $0.right?.hasPrefix(value) == true }) {
                lines.append(row.label + ": " + value + (row.isCached ? " · cached" : ""))
            }
        }
        let allOld = panel.cells.allSatisfy(\.isCached)
        let balanceCached = balance?.isCached == true && !allOld ? " · cached" : ""
        return CellsView(title: panel.name + (balance?.right.map { "  " + $0 + balanceCached } ?? ""), subtitle: panel.cellsTitle, lines: lines,
                         rows: Array(panel.cells.prefix(5)), more: max(0, panel.cells.count - 5), allReadingsCached: allOld,
                         moreHint: inMenu ? (panel.id == "openrouter" ? "All keys below" : "All budgets below") : "click battery for all",
                         darkBar: inMenu ? nil : darkMenuBar, providerID: panel.id)
    }
    func hoverButton(_ id: String) -> NSView? { items[id]?.button }
    func showHover(_ id: String) {
        guard openMenu == nil, !menuTracking, hovered == id, let panel = panels[id] else { return }
        let edge: NSRectEdge = .minY
        // Antigravity says which pool its battery is showing; it is two pools, so the table is for the click.
        if id == "antigravity", let button = hoverButton(id), button.window != nil {
            popover.close()
            let controller = NSViewController(); controller.view = ModelIdentityView(glyph: ModelIdentity.antigravity, name: panel.name, caption: displayedQuota(panel)?.label)
            modelPopover.contentViewController = controller; modelPopover.contentSize = controller.view.frame.size
            modelPopover.animates = false; modelPopover.dark = darkMenuBar
            modelPopover.show(relativeTo: button.bounds, of: button, preferredEdge: edge)
            return
        }
        if !panel.cells.isEmpty { modelPopover.close(); showCells(id); return }
        guard ["claude", "codex", "glm", "grok", "grokbot", "kimi-code"].contains(id),
              let glyph = ModelIdentity.glyph(id), let button = hoverButton(id), button.window != nil else { return }
        let controller = NSViewController(); controller.view = ModelIdentityView(glyph: glyph, name: panel.name)
        modelPopover.contentViewController = controller; modelPopover.contentSize = controller.view.frame.size
        modelPopover.animates = false; modelPopover.dark = darkMenuBar
        modelPopover.show(relativeTo: button.bounds, of: button, preferredEdge: edge)
    }
    /// Opens the per-key panel under a battery that is still hovered.
    func showCells(_ id: String) {
        guard hovered == id, let panel = panels[id], !panel.cells.isEmpty, let button = hoverButton(id), button.window != nil else { return }
        let controller = NSViewController()
        controller.view = cellsView(panel)
        popover.contentViewController = controller
        popover.contentSize = controller.view.frame.size
        popover.animates = false; popover.dark = darkMenuBar
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
    }
    @objc func refreshProvider(_ sender: NSMenuItem) { load(sender.representedObject as? String) }
    /// The provider whose sign-in is waiting in the browser.
    var signingIn: String?
    /// Signs in without a window: the CLI opens the browser, and the battery refreshes once the user approves there.
    /// A CLI that turns out to need a terminal gets one, through a .command file so no Automation permission is needed.
    @objc func runFix(_ sender: NSMenuItem) {
        guard let pair = sender.representedObject as? [String], pair.count == 2, SignIn.commands.contains(pair[1]) else { return }
        let (id, fix) = (pair[0], pair[1])
        let started = SignIn.start(fix) { ok, quick in
            DispatchQueue.main.async {
                self.signingIn = nil
                if ok { self.load(id) } else if quick { self.openTerminal(fix, id: id) }
                if let panel = self.panels[id] { self.render(panel) }
            }
        }
        if started { signingIn = id; if let panel = panels[id] { render(panel) } } else { openTerminal(fix, id: id) }
    }
    static func fixScript(_ fix: String, id: String, executable: String?) -> String {
        let refresh = executable.map { "'" + $0.replacingOccurrences(of: "'", with: "'\\''") + "' --refresh " + id + " >/dev/null 2>&1" } ?? "true"
        return "#!/bin/zsh -l\necho 'Signing in: \(fix)'\n\(fix) && \(refresh) && echo && echo 'Signed in and updated. You can close this window.'\n"
    }
    func openTerminal(_ fix: String, id: String) {
        let script = home.appendingPathComponent("fix.command")
        let text = HUD.fixScript(fix, id: id, executable: Bundle.main.executablePath)
        guard (try? text.write(to: script, atomically: true, encoding: .utf8)) != nil else { return }
        chmod(script.path, 0o700)
        NSWorkspace.shared.open(script)
    }
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
    let noticeView = SourceNoticeView(SourceNotice(title: "Tracking Claude", lines: [ReadingSource.claudeStatusline.description(provider: "Claude")]))
    precondition(noticeView.frame.width == 340 && noticeView.frame.height > 60)
    let noticePanel = SourceNoticePanel(contentRect: noticeView.bounds, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    precondition(!noticePanel.canBecomeKey && !noticePanel.canBecomeMain)
    if let screen = NSScreen.main {
        let presenter = SourceNoticePresenter()
        var visibility: [Bool] = []
        presenter.visibilityChanged = { visibility.append($0) }
        let began = Date()
        presenter.show(SourceNotice(title: "Source notice self-test", lines: ["Disposable fixture · automatically dismissed"]),
                       below: NSRect(x: screen.visibleFrame.midX, y: screen.visibleFrame.maxY, width: 30, height: 20), screen: screen)
        precondition(presenter.panel?.isVisible == true && presenter.panel?.ignoresMouseEvents == true)
        precondition(presenter.panel?.canBecomeKey == false)
        RunLoop.main.run(until: began.addingTimeInterval(SourceNotice.duration + 0.25))
        precondition(presenter.panel?.isVisible == false && visibility == [true, false])
    }

    do { try FileManager.default.createDirectory(at: delegate.home, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]) }
    catch { fputs("Self-test output directory unavailable\n", stderr); exit(1) }
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
    precondition(delegate.items["codex"]?.menu?.items.contains{$0.title == "Showing 7d"} == true)
    precondition(delegate.items["codex"]?.menu?.items.filter{$0.title.contains("cached")}.count == 1)
    let layered = Panel(id: "claude", name: "Claude", windows: [Window(label: "5h", pct: 20), Window(label: "7d", pct: 80)])
    precondition(delegate.hoverPanel(layered)?.displayedQuota?.label == "7d")
    precondition(delegate.hoverPanel(layered)?.windows.count == 1)
    precondition(delegate.hoverPanel(fallback) == nil)
    delegate.render(layered)
    delegate.trackers["claude"]?.changed(true)
    precondition(delegate.hovered == "claude")
    delegate.trackers["claude"]?.changed(false)
    // Leaving counts a moment later, once the pointer is confirmed outside.
    RunLoop.current.run(until: Date().addingTimeInterval(0.2))
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
        precondition(delegate.items[id]?.length == battery.size.width + StatusGroup.gap)
        battery.draw(in: NSRect(x: CGFloat(index*48), y: 11, width: battery.size.width, height: 22))
    }
    image.unlockFocus()
    // Past the limit, the least recently used batteries move into one overflow item.
    for id in ["glm", "deepseek"] { delegate.render(Panel(id: id, name: id.uppercased(), windows: [Window(label: "5h", pct: 10)])) }
    delegate.shelf = Shelf()
    delegate.arrange(["codex", "claude", "openrouter", "glm", "deepseek"])
    precondition(delegate.items["glm"]?.isVisible == false && delegate.items["deepseek"]?.isVisible == false)
    precondition(delegate.items["codex"]?.isVisible == true && delegate.overflow?.button?.image != nil && delegate.overflow?.button?.accessibilityLabel() == "Usage HUD, 2 more usage batteries")
    precondition(delegate.overflow?.menu?.items.first?.submenu?.items.contains { $0.title.hasPrefix("Refresh GLM") } == true)
    // Choosing a hidden battery to keep puts it in the bar and sends another into the logo's menu.
    precondition(delegate.items["glm"]?.isVisible == false)
    delegate.shelf.pin("glm"); delegate.arrange(delegate.arrangedIDs)
    precondition(delegate.items["glm"]?.isVisible == true)
    delegate.shelf.pins = []; delegate.arrange(delegate.arrangedIDs)
    precondition(delegate.items["glm"]?.isVisible == false)
    delegate.arrange(["codex", "claude"])
    precondition(delegate.overflow?.isVisible == false)
    // All visible cells share one native surface, with separate accessible buttons and menus.
    precondition(delegate.group.order == ["usage-hud", "codex", "claude"])
    precondition(delegate.group.content.subviews.count == 3)
    // Whatever point AppKit reports for a click, the cell the pointer is over takes it.
    for cell in delegate.group.content.subviews.compactMap({ $0 as? StatusCellButton }) {
        guard let window = cell.window else { continue }
        let inWindow = delegate.group.content.convert(NSPoint(x: cell.frame.midX, y: cell.frame.midY), to: nil)
        precondition(delegate.group.cellButton(atScreen: window.convertPoint(toScreen: inWindow))?.sourceID == cell.sourceID)
    }
    precondition(delegate.items["codex"]?.button?.acceptsFirstMouse(for: nil) == true)
    // A hover identifier is nonactivating and cannot intercept a subsequent battery click.
    let hover = HoverSurface(), controller = NSViewController()
    controller.view = ModelIdentityView(glyph: NSImage(size: NSSize(width: 18, height: 18)), name: "Codex")
    hover.contentViewController = controller; hover.contentSize = controller.view.frame.size
    if let button = delegate.items["codex"]?.button {
        hover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        precondition(hover.panel?.ignoresMouseEvents == true && hover.panel?.canBecomeKey == false)
        hover.close(); precondition(!hover.isShown)
    }
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
    let visibleDetail = delegate.items["openrouter"]?.menu?.items.first?.view as? CellsView
    precondition(visibleDetail?.rows.count == 2 && visibleDetail?.rows.first?.pct == 96)
    delegate.shelf = Shelf()
    delegate.arrange(["codex", "claude", "glm", "openrouter"])
    let hiddenMenu = delegate.overflow?.menu?.items.first { $0.title.hasPrefix("OpenRouter") }?.submenu
    let hiddenDetail = hiddenMenu?.items.compactMap { $0.view as? CellsView }.first
    precondition(hiddenMenu?.items.first?.title == "Keep in the menu bar")
    precondition(hiddenDetail?.rows.count == 2 && hiddenDetail !== visibleDetail)
    precondition(hiddenMenu?.items.contains { $0.title == "Refresh OpenRouter" && $0.action != nil } == true)
    precondition(hiddenMenu?.items.contains { $0.title == "All keys (2)" && $0.submenu?.items.count == 2 } == true)
    let many = Panel(id: "openrouter", name: "OpenRouter", cells: (1...12).map { Window(label: "Key \($0)", pct: Double($0)) })
    let manyMenu = delegate.providerMenu(many)
    precondition((manyMenu.items.first?.view as? CellsView)?.moreHint == "All keys below")
    precondition(manyMenu.items.contains { $0.title == "All keys (12)" && $0.submenu?.items.count == 12 })
    // A sign-in problem offers its harmless fix in the menu and says so on hover.
    var signedOut = Panel(id: "claude", name: "Claude", windows: [Window(label: "5h", pct: 20)], note: "Claude needs sign-in")
    signedOut.fix = "claude auth login"
    delegate.render(signedOut)
    precondition(delegate.items["claude"]?.menu?.items.contains { $0.title == "Sign in to Claude again…" && $0.action != nil } == true)
    precondition(delegate.items["claude"]?.button?.toolTip?.contains("Click to sign in again") == true)
    precondition(HUD.fixScript("claude auth login", id: "claude", executable: "/A b's/usagehud").contains("claude auth login && '/A b'\\''s/usagehud' --refresh claude"))
    precondition(SignIn.commands.contains("claude auth login") && !SignIn.commands.contains("rm -rf ~"))
    delegate.signingIn = "claude"; delegate.render(signedOut)
    precondition(delegate.items["claude"]?.menu?.items.contains { $0.title == "Approve the sign-in in your browser…" } == true)
    delegate.signingIn = nil
    precondition(delegate.items["openrouter"]?.menu?.items.contains { $0.title == "All keys (2)" && $0.submenu?.items.count == 2 } == true)
    precondition(CellsView(title: "a", lines: ["b"], rows: team.cells).frame.height == 92)
    // The panel widens to show a whole reset time instead of cutting it off.
    let long = Window(label: "Guy1", pct: 0, right: "$0.00 of $5.00 today · resets in 7h 16m")
    precondition(CellsView(title: "OpenRouter", rows: [long]).frame.width > CellsView(title: "OpenRouter", rows: [Window(label: "a", pct: 0, right: "$1")]).frame.width)
    let cachedView = CellsView(title: "Antigravity", subtitle: "14 models", rows: team.cells.map { Window(label: $0.label, pct: $0.pct, right: $0.right, stale: true) })
    precondition(cachedView.subtitle == "14 models · cached")
    precondition(CellsView(title: "Antigravity", subtitle: "14 models", rows: team.cells).subtitle == "14 models")
    precondition((delegate.items["claude"]?.button?.accessibilityValue() as? String)?.contains("percent remaining") == true)
    let mixed = Panel(id: "openrouter", name: "OpenRouter", windows: [Window(label: "OpenRouter", right: "$20 left"), Window(label: "Key", pct: 40, stale: true)])
    let mixedLines = HUD.menuLines(mixed, showingWeek: false, cached: false).map(\.string)
    precondition(!mixedLines[0].contains("cached") && mixedLines[1].contains("cached"))
    // No tint may pass for the system battery's white.
    for id in ["codex", "claude", "glm", "antigravity", "grok", "grokbot", "vercel", "deepseek", "kimi", "openrouter", "fireworks", "litellm", "other"] {
        let rgb = delegate.tint(id).usingColorSpace(.sRGB)!
        let linear = [rgb.redComponent, rgb.greenComponent, rgb.blueComponent].map { $0 <= 0.04045 ? $0 / 12.92 : pow(($0 + 0.055) / 1.055, 2.4) }
        let chroma = max(rgb.redComponent, rgb.greenComponent, rgb.blueComponent) - min(rgb.redComponent, rgb.greenComponent, rgb.blueComponent)
        precondition(0.2126 * linear[0] + 0.7152 * linear[1] + 0.0722 * linear[2] <= 0.5 || chroma >= 0.3, id + " is too close to white")
    }
    precondition(CellsView.color(left: 0.05, dark: true) == .systemRed && CellsView.color(left: 0.2, dark: false) == .systemYellow)
    precondition(CellsView.color(left: 0.9, dark: true) == .white && CellsView.color(left: 0.9, dark: false) == .black)
    let nearCap = Panel(id: "claude", name: "Claude", windows: [Window(label: "5h", pct: 95), Window(label: "7d", pct: 20)])
    let redReference = Panel(id: "critical", name: "Reference", windows: nearCap.windows)
    precondition(delegate.icon(nearCap).tiffRepresentation == delegate.icon(redReference).tiffRepresentation)
    let google = Panel(id: "antigravity", name: "Antigravity", windows: [Window(label: "Gemini", pct: 24, palette: .google)])
    let combined = Panel(id: "antigravity", name: "Antigravity", windows: [Window(label: "Claude & GPT", pct: 24, palette: .claudeOpenAI)])
    precondition(delegate.icon(google).tiffRepresentation != delegate.icon(combined).tiffRepresentation)
    precondition(ModelIdentity.glyph("openrouter") == nil && ModelIdentity.glyph("antigravity") != nil)
    let identity = ModelIdentityView(glyph: NSImage(size: NSSize(width: 18, height: 18)), name: "Codex")
    precondition(identity.frame.size == NSSize(width: 32, height: 32) && identity.accessibilityLabel() == "Codex")
    let expiredClaude = Panel(id: "claude", name: "Claude", windows: [Window(label: "5h", pct: 40, stale: true)],
                              note: "Claude Code credential expired; it renews with one small Claude Code call, or run claude once in a terminal")
    for panel in [expiredClaude, Panel(id: "claude", name: "Claude", windows: [Window(label: "5h", pct: 20)])] {
        let controls = ["Live from Claude Code", "Claude Code CLI connection", "Refresh Claude", "Check Claude usage", "Waiting for fresh Claude usage"]
        precondition(!delegate.providerMenu(panel).items.contains { controls.contains($0.title) })
    }
    // Balances stretch with their digits; a whole amount keeps the standard battery size.
    func balance(_ right: String) -> NSImage {
        delegate.icon(Panel(id: "openrouter", name: "OpenRouter", windows: [Window(label: "OpenRouter", pct: nil, right: right, resets_at: nil, expired: false, stale: false)], note: ""))
    }
    precondition(balance("$-26.00 left").tiffRepresentation != balance("$26.00 left").tiffRepresentation)
    precondition(balance("$26.00 left").size.width == 28)
    precondition(balance("$26.25 left").size.width > balance("$26.00 left").size.width)
    precondition(balance("$1026.25 left").size.width > balance("$26.25 left").size.width)
    let representation = NSBitmapImageRep(data: image.tiffRepresentation!)!
    try! representation.representation(using: .png, properties: [:])!.write(to: delegate.home.appendingPathComponent("battery-preview.png"))
    // The battery dissolves when it moves to another pool.
    let pools = Panel(id: "antigravity", name: "Antigravity", windows: [Window(label: "Gemini", pct: 84), Window(label: "Claude & GPT", pct: 7)], lead: "Gemini")
    delegate.render(pools)
    precondition(delegate.fades["antigravity"] == nil)
    var turned = pools; turned.lead = "Claude & GPT"; delegate.render(turned)
    precondition(delegate.fades["antigravity"] != nil)
    delegate.fades = [:]; delegate.fadeTimer?.invalidate(); delegate.fadeTimer = nil
    // A battery that reads red only when every pool is nearly spent.
    let spent = Panel(id: "antigravity", name: "Antigravity", windows: [Window(label: "Gemini", pct: 85), Window(label: "Claude & GPT", pct: 92)])
    precondition(delegate.icon(spent).tiffRepresentation != delegate.icon(pools).tiffRepresentation)
    // A contact sheet of every provider's battery on a dark and a light bar: full, 35% left, and as a balance, then the
    // OpenRouter balance states (gauge at 40%, under $15, under $10 mid-pulse).
    func sheet(light: Bool) -> NSImage {
        delegate.forcedDarkBar = !light
        let ids = ["codex", "claude", "glm", "antigravity", "grok", "grokbot", "xai", "vercel", "deepseek", "kimi", "kimi-code", "openrouter", "fireworks", "litellm"]
        let states = ["or · gauge 40%", "or · under $15", "or · under $10", "ag · one pool 16%", "ag · both under 20%", "codex · 14% left", "codex · 9% left"]
        let scale: CGFloat = 3, row: CGFloat = 30 * scale, width: CGFloat = 215 * scale
        let sheet = NSImage(size: NSSize(width: width, height: row * CGFloat(ids.count + states.count)))
        sheet.lockFocus()
        (light ? NSColor(white: 0.93, alpha: 1) : NSColor(white: 0.16, alpha: 1)).setFill(); NSRect(origin: .zero, size: sheet.size).fill()
        for (index, id) in (ids + states).enumerated() {
            let y = sheet.size.height - row * CGFloat(index + 1)
            let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 11 * scale), .foregroundColor: light ? NSColor.black : NSColor.white]
            (id as NSString).draw(at: NSPoint(x: 6 * scale, y: y + 6 * scale), withAttributes: attributes)
            let provider = id.hasPrefix("or · ") ? "openrouter" : id.hasPrefix("ag · ") ? "antigravity" : id.hasPrefix("codex · ") ? "codex" : id
            func quota(_ used: Double) -> Panel { Panel(id: provider, name: id, windows: used > 0 ? [Window(label: "5h", pct: used), Window(label: "7d", pct: 20)] : [Window(label: "5h", pct: used)]) }
            var money = Panel(id: provider, name: id, windows: [Window(label: id, right: "$26.25 left")])
            var glow: CGFloat = 0
            if id.hasSuffix("gauge 40%") { money.gauge = 0.4 }
            if id.hasSuffix("$15") { money.caution = "Balance under $15" }
            if id.hasSuffix("$10") { money.caution = "Balance under $15"; glow = 0.2 }
            if id.hasPrefix("ag · ") {
                let used = id.hasSuffix("16%") ? [84.0, 7] : [85.0, 92]
                money = Panel(id: "antigravity", name: id, windows: [Window(label: "Gemini", pct: used[0]), Window(label: "Claude & GPT", pct: used[1])], lead: "Gemini")
            }
            if id.hasPrefix("codex · ") {
                let used = id.contains("14%") ? 86.0 : 91.0
                money = Panel(id: "codex", name: id, windows: [Window(label: "5h", pct: used), Window(label: "7d", pct: used - 2)])
            }
            let panels = states.contains(id) ? [money, money, money] : [quota(0), quota(65), money]
            for (slot, panel) in panels.enumerated() {
                let icon = delegate.icon(panel, glow: glow)
                icon.draw(in: NSRect(x: (100 + CGFloat(slot) * 38) * scale, y: y, width: icon.size.width * scale, height: icon.size.height * scale))
            }
        }
        sheet.unlockFocus()
        return sheet
    }
    for light in [false, true] {
        let rep = NSBitmapImageRep(data: sheet(light: light).tiffRepresentation!)!
        try! rep.representation(using: .png, properties: [:])!.write(to: delegate.home.appendingPathComponent(light ? "palette-light.png" : "palette-dark.png"))
    }
    delegate.forcedDarkBar = nil
    // The empty part against grey bars: the old fixed greys, the ink-strength model, and what the native battery measured.
    do {
        let grays: [(Int, Int?)] = [(32, 131), (64, 150), (112, 175), (135, 188), (149, nil), (231, 133), (255, 147)]
        let scale: CGFloat = 3, rowHeight: CGFloat = 34 * scale, width: CGFloat = 330 * scale
        let sheet = NSImage(size: NSSize(width: width, height: rowHeight * CGFloat(grays.count) + 20 * scale))
        sheet.lockFocus()
        NSColor(white: 0.5, alpha: 1).setFill(); NSRect(origin: .zero, size: sheet.size).fill()
        let head: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 7 * scale), .foregroundColor: NSColor.white]
        for (column, title) in [(60, "native"), (86, "before"), (112, "now"), (150, "batteries now")] {
            (title as NSString).draw(at: NSPoint(x: CGFloat(column) * scale, y: sheet.size.height - 12 * scale), withAttributes: head)
        }
        for (index, entry) in grays.enumerated() {
            let (level, native) = entry
            let bar = NSColor(white: CGFloat(level) / 255, alpha: 1), dark = level <= 140
            let y = sheet.size.height - 20 * scale - rowHeight * CGFloat(index + 1)
            bar.setFill(); NSRect(x: 0, y: y, width: width, height: rowHeight).fill()
            let ink: NSColor = dark ? .white : .black
            (("bar " + String(format: "#%02X", level)) as NSString).draw(at: NSPoint(x: 4 * scale, y: y + 12 * scale),
                withAttributes: [.font: NSFont.systemFont(ofSize: 8 * scale), .foregroundColor: ink])
            func swatch(_ x: CGFloat, _ color: NSColor?) {
                guard let color = color else { return }
                color.setFill(); NSRect(x: x * scale, y: y + 8 * scale, width: 22 * scale, height: 18 * scale).fill()
            }
            swatch(60, native.map { NSColor(white: CGFloat($0) / 255, alpha: 1) })
            swatch(86, NSColor(white: dark ? 0.45 : 0.58, alpha: 1))
            let model = BatteryText.track(dark: dark)
            bar.setFill(); NSRect(x: 112 * scale, y: y + 8 * scale, width: 22 * scale, height: 18 * scale).fill(); swatch(112, model)
            delegate.forcedDarkBar = dark
            let samples = [Panel(id: "codex", name: "Codex", windows: [Window(label: "5h", pct: 78), Window(label: "7d", pct: 40)]),
                           Panel(id: "claude", name: "Claude", windows: [Window(label: "5h", pct: 2)]),
                           Panel(id: "kimi", name: "Kimi", windows: [Window(label: "5h", pct: 89)])]
            // The group as laid out in the menu bar, using the same spacing constants.
            let widths = [SystemBattery.stackedWidth + StatusGroup.gap] + samples.map { delegate.icon($0).size.width + StatusGroup.gap }
            let pillWidth = widths.reduce(2 * StatusGroup.pad, +)
            let pill = NSRect(x: 150 * scale, y: y + 6 * scale, width: pillWidth * scale, height: 22 * scale)
            ink.withAlphaComponent(0.14).setFill(); NSBezierPath(roundedRect: pill, xRadius: 11 * scale, yRadius: 11 * scale).fill()
            var x = 150 + StatusGroup.pad
            let stack = SystemBattery.stacked(dark: dark); stack.isTemplate = false
            let tinted = NSImage(size: stack.size); tinted.lockFocus()
            stack.draw(at: .zero, from: .zero, operation: .sourceOver, fraction: 1); ink.setFill(); NSRect(origin: .zero, size: stack.size).fill(using: .sourceIn); tinted.unlockFocus()
            tinted.draw(in: NSRect(x: (x + StatusGroup.gap / 2) * scale, y: y + 6 * scale, width: stack.size.width * scale, height: 22 * scale))
            x += widths[0]
            for (slot, panel) in samples.enumerated() {
                let icon = delegate.icon(panel)
                icon.draw(in: NSRect(x: (x + StatusGroup.gap / 2) * scale, y: y + 6 * scale, width: icon.size.width * scale, height: 22 * scale))
                x += widths[slot + 1]
            }
        }
        sheet.unlockFocus()
        delegate.forcedDarkBar = nil
        try! NSBitmapImageRep(data: sheet.tiffRepresentation!)!.representation(using: .png, properties: [:])!.write(to: delegate.home.appendingPathComponent("track-contrast.png"))
    }
    // Candidate digit fonts, numbered, to compare against the system battery beside them in the menu bar.
    // Tabular SF Pro around Regular 10pt, measured from macOS 27's own battery; 6 is the previous default.
    let candidates: [(String, (CGFloat) -> NSFont)] = [
        ("1 regular 10pt (now)", { HUD.tabular($0 + 0.5, .regular) }), ("2 regular 10.5pt", { HUD.tabular($0 + 1, .regular) }),
        ("3 regular 9.5pt", { HUD.tabular($0, .regular) }), ("4 light 10pt", { HUD.tabular($0 + 0.5, .light) }),
        ("5 medium 10pt", { HUD.tabular($0 + 0.5, .medium) }), ("6 medium 11pt (before)", { HUD.tabular($0 + 1.5, .medium) })]
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
    try! DesignPreview.write(hud: delegate, to: delegate.home)
    print("Battery drawing and note-free menus passed; fonts: " + delegate.home.appendingPathComponent("font-preview.png").path)
    exit(0)
}
let productTest = (CommandLine.arguments.contains("--product-test") || Bundle.main.object(forInfoDictionaryKey: "UsageHUDProductTest") as? Bool == true) ? ProductTest() : nil
app.delegate = productTest ?? delegate
app.run()
