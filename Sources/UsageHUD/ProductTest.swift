import Cocoa
import UsageHUDCore

/// Runs the production status buttons, menus and hover view with disposable readings.
/// Refresh is intercepted here, so this mode never reads credentials or contacts a provider.
final class FixtureHUD: HUD {
    var recovered: () -> Void = {}
    var hoverAnchors: [String: NSView] = [:]
    override func hoverButton(_ id: String) -> NSView? { hoverAnchors[id] ?? super.hoverButton(id) }
    override func load(_ refresh: String?, also: Set<String> = []) { recovered() }
}
final class ProductTest: NSObject, NSApplicationDelegate, NSWindowDelegate {
    let hud = FixtureHUD()
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 510),
                          styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
    let provider = NSPopUpButton(frame: NSRect(x: 20, y: 419, width: 250, height: 28))
    let summary = NSTextField(wrappingLabelWithString: "")
    var preview: NSView?
    var groupPreview: NativeSurface?
    var state = "Fresh"
    let names = [("codex", "Codex"), ("claude", "Claude"), ("antigravity", "Antigravity"), ("openrouter", "OpenRouter"),
                 ("grok", "Grok"), ("grokbot", "Grok Bot"), ("xai", "xAI"), ("vercel", "Vercel"), ("deepseek", "DeepSeek"), ("kimi", "Kimi"),
                 ("kimi-code", "Kimi Code"), ("fireworks", "Fireworks"), ("litellm", "LiteLLM")]
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        window.title = "Usage HUD — Product Test"; window.delegate = self
        let info = NSTextField(wrappingLabelWithString: "Usage HUD · simulated provider readings\nThe batteries and menus use the app's normal rendering. Refresh recovers the fixture. No account or API calls.")
        info.frame = NSRect(x: 20, y: 456, width: 560, height: 44); window.contentView?.addSubview(info)
        provider.addItems(withTitles: names.map { $0.1 }); provider.target = self; provider.action = #selector(providerChanged)
        window.contentView?.addSubview(provider)
        for (index, title) in ["Fresh", "Cached", "Partial", "Recovered", "11 models", "Many keys", "Cycles", "Low quota", "Dark bar", "Light bar", "Claude & GPT", "Expired Claude"].enumerated() {
            let button = NSButton(title: title, target: self, action: #selector(scenario(_:)))
            button.frame = NSRect(x: 20 + CGFloat(index % 4) * 140, y: 376 - CGFloat(index / 4) * 35, width: 132, height: 28)
            window.contentView?.addSubview(button)
        }
        for (index, title) in ["Source added", "Sources grouped", "Source removed"].enumerated() {
            let button = NSButton(title: title, target: self, action: #selector(sourceChanged(_:)))
            button.font = .systemFont(ofSize: 11)
            button.frame = NSRect(x: 285 + CGFloat(index) * 98, y: 419, width: 95, height: 28)
            window.contentView?.addSubview(button)
        }
        summary.frame = NSRect(x: 20, y: 255, width: 560, height: 40); window.contentView?.addSubview(summary)
        for (index, title) in ["Open provider menu", "Show hover panel", "Open overflow menu"].enumerated() {
            let button = NSButton(title: title, target: self, action: #selector(open(_:)))
            button.frame = NSRect(x: 20 + CGFloat(index) * 186, y: 18, width: 178, height: 30)
            window.contentView?.addSubview(button)
        }
        let follow = NSButton(title: "Follow actual bar", target: self, action: #selector(followActualBar))
        follow.frame = NSRect(x: 390, y: 219, width: 178, height: 28); window.contentView?.addSubview(follow)
        hud.recovered = { [weak self] in self?.state = "Recovered"; self?.show() }
        hud.contrastTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.hud.updateContrast() }
        show(); window.center(); window.makeKeyAndOrderFront(nil)
    }
    @objc func sourceChanged(_ sender: NSButton) {
        var changes = SourceChanges()
        let selected = names[max(0, provider.indexOfSelectedItem)]
        func connected(_ id: String, _ name: String) -> Panel {
            var panel = fixture(id, name); panel.note = ""
            for index in panel.windows.indices { panel.windows[index].stale = false }
            for index in panel.cells.indices { panel.cells[index].stale = false }
            panel.sourceReadAt = Date().timeIntervalSince1970
            panel.readingSource = id == "claude" ? .claudeStatusline : id == "codex" ? .codexCLI :
                id == "antigravity" ? .antigravityLocal : id == "litellm" ? .liteLLMProxy : id == "grok" ? .grokCLI : id == "grokbot" ? .grokBotLocal : .providerAPI
            return panel
        }
        let current = connected(selected.0, selected.1)
        let notice: SourceNotice?
        if sender.title == "Source removed" {
            _ = changes.update(panels: [current], announce: false)
            notice = changes.update(panels: [], gone: [current.id])
        } else {
            notice = changes.update(panels: sender.title == "Sources grouped" ? names.map { connected($0.0, $0.1) } : [current])
        }
        if let notice = notice {
            hud.sourceNotice.dismiss()
            hud.sourceNotice.visibilityChanged = { [weak self] visible in
                self?.summary.stringValue = visible ? "Native source notice visible · disappears after 6 seconds" :
                    "Notice dismissed automatically · no action needed"
                if !visible { self?.preview?.removeFromSuperview(); self?.preview = nil }
            }
            hud.showSourceNotice(notice)
            preview?.removeFromSuperview()
            let view = NativeSurface(content: SourceNoticeView(notice))
            view.frame.origin = NSPoint(x: 20, y: max(53, 210 - view.frame.height))
            window.contentView?.addSubview(view); preview = view
        }
    }
    @objc func followActualBar() { hud.forcedDarkBar = nil; hud.updateContrast(); show() }
    @objc func providerChanged() { show() }
    @objc func scenario(_ sender: NSButton) {
        if sender.title == "Dark bar" || sender.title == "Light bar" { hud.forcedDarkBar = sender.title == "Dark bar" }
        else { state = sender.title }
        show()
    }
    func fixture(_ id: String, _ name: String) -> Panel {
        let cached = state == "Cached", partial = state == "Partial", low = state == "Low quota"
        let reset = Date().timeIntervalSince1970 + 21600
        var panel: Panel
        if ["vercel", "deepseek", "kimi"].contains(id) {
            let amount = id == "deepseek" ? "¥26.25 left" : "$26.25 left"
            panel = Panel(id: id, name: name, windows: [Window(label: name, right: amount, stale: cached)])
        } else if ["openrouter", "litellm", "xai", "fireworks"].contains(id) {
            var cells = [Window(label: "Research", pct: low ? 99 : 20, right: "$1 / $5 · ↻ 6h", resets_at: reset, stale: cached || partial),
                         Window(label: "Production", pct: 7, right: "$7 / $100 · ↻ 6h", resets_at: reset, stale: cached)]
            if state == "Many keys" {
                cells = (1...12).map { Window(label: "Production agent — nightly research team \($0)", pct: Double($0 * 3), right: "$3 / $100 · ↻ 6h", resets_at: reset) }
            } else if state == "Cycles" {
                cells = [Window(label: "Daily", pct: 20, right: "$1 / $5 · daily", resets_at: reset),
                         Window(label: "Weekly", pct: 10, right: "$5 / $50 · weekly", resets_at: reset + 86400 * 5),
                         Window(label: "Monthly", pct: 3, right: "$3 / $100 · monthly", resets_at: reset + 86400 * 25),
                         Window(label: "No reset", pct: 15, right: "$15 / $100 · total"),
                         Window(label: "No cap", right: "$12 spent")]
            }
            if id == "xai" || id == "fireworks" {
                cells = [Window(label: "This month", pct: low ? 99 : 25, right: "$12.50 / $50", stale: cached || partial)]
            } else if id == "litellm" {
                cells = [Window(label: "Budget", pct: low ? 99 : 25, right: "$12.50 / $50 · ↻ 6h", resets_at: reset, stale: cached || partial),
                         Window(label: "Claude Sonnet", pct: 20, right: "$2 / $10 · every 7d", stale: cached)]
            }
            if id == "openrouter" {
                panel = Panel(id: id, name: name, windows: [Window(label: name, right: "$26.25 left", stale: cached)], cells: cells, cellsTitle: "\(cells.count) keys")
                panel.gauge = cells.compactMap { $0.pct.map { (100 - $0) / 100 } }.min()
            } else {
                panel = Panel(id: id, name: name, windows: [cells[0], Window(label: "Spent", right: "$12.50 / $50", stale: cached)], cells: cells, cellsTitle: id == "litellm" ? "Virtual key budget" : "Account budget")
            }
        } else {
            let rows = id == "antigravity" ? [Window(label: "Gemini", pct: low ? 99 : 84, right: "↻ 6h", resets_at: reset, stale: cached || partial),
                Window(label: "Claude & GPT", pct: low ? 99 : 24, right: "↻ 6h", resets_at: reset, stale: cached)] :
                [Window(label: "5h", pct: low ? 99 : 18, resets_at: reset, stale: cached || partial), Window(label: "7d", pct: low ? 99 : 30, resets_at: reset + 86400 * 6, stale: cached)]
            panel = Panel(id: id, name: name, windows: rows, cells: id == "antigravity" ? rows : [],
                          cellsTitle: id == "antigravity" ? (state == "11 models" ? "11 models" : "14 models") : nil)
            if id == "grok" { panel.windows = [Window(label: "7d", pct: low ? 99 : 30, resets_at: reset + 86400 * 6, stale: cached || partial)] }
            if id == "codex" { panel.windows.append(Window(label: "OpenAI API", right: "$40.47 · estimate", stale: cached || partial)) }
        }
        if id == "antigravity" {
            for index in panel.windows.indices { panel.windows[index].palette = QuotaPalette.families([panel.windows[index].label]) }
            panel.cells = panel.windows
            panel.lead = state == "Claude & GPT" ? "Claude & GPT" : "Gemini"
        }
        if cached || partial { panel.note = "Source unavailable; last reading retained" }
        if id == "claude", state == "Expired Claude" {
            panel.note = "Claude Code credential expired; it renews with one small Claude Code call, or run claude once in a terminal"
            for index in panel.windows.indices { panel.windows[index].stale = true }
        }
        return panel
    }
    func show() {
        hud.popover.close(); hud.modelPopover.close(); hud.hovered = nil
        let selected = names[max(0, provider.indexOfSelectedItem)]
        let panels = names.map { fixture($0.0, $0.1) }
        panels.forEach { hud.render($0) }
        hud.shelf = Shelf(); hud.arrange([selected.0] + names.map { $0.0 }.filter { $0 != selected.0 })
        groupPreview?.removeFromSuperview(); hud.hoverAnchors.removeAll()
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 8, height: 22))
        var x: CGFloat = 4
        let shown = [hud.logo].compactMap { $0 } + hud.shelf.ranked(hud.arrangedIDs).compactMap { hud.items[$0] }.filter(\.isVisible)
        for cell in shown {
            guard let original = cell.button, let image = original.image else { continue }
            let button = NSButton(image: image, target: self, action: #selector(openPreview(_:)))
            button.isBordered = false; button.identifier = NSUserInterfaceItemIdentifier(cell.id)
            button.frame = NSRect(x: x, y: 0, width: image.size.width + 6, height: 22)
            button.setAccessibilityLabel(original.accessibilityLabel()); button.setAccessibilityValue(original.accessibilityValue())
            content.addSubview(button); hud.hoverAnchors[cell.id] = button; x += button.frame.width
        }
        content.frame.size.width = x + 4
        let group = NativeSurface(content: content, radius: 11)
        group.appearance = NSAppearance(named: hud.darkMenuBar ? .darkAqua : .aqua)
        group.frame.origin = NSPoint(x: 20, y: 222); window.contentView?.addSubview(group); groupPreview = group
        let panel = panels.first { $0.id == selected.0 }!
        summary.stringValue = selected.1 + " · " + state + " · " + (hud.forcedDarkBar == nil ? "actual native bar" : "simulated bar") +
            (hud.darkMenuBar ? " · light ink" : " · dark ink") + "\nClick a battery in the group, or show its hover before clicking it."
        preview?.removeFromSuperview()
        let view = panel.cells.isEmpty ? CellsView(title: panel.name, lines: panel.note.isEmpty ? [] : [panel.note],
                                                    rows: Array(panel.windows.prefix(5)), darkBar: hud.darkMenuBar, providerID: panel.id) : hud.cellsView(panel)
        view.appearance = NSAppearance(named: hud.darkMenuBar ? .darkAqua : .aqua)
        let surface = NativeSurface(content: view); surface.appearance = view.appearance
        surface.frame.origin = NSPoint(x: 20, y: max(53, 210 - surface.frame.height)); window.contentView?.addSubview(surface); preview = surface
    }
    @objc func open(_ sender: NSButton) {
        let id = names[max(0, provider.indexOfSelectedItem)].0
        if sender.title == "Open overflow menu" { hud.logoMenu?.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.maxY), in: sender) }
        else if sender.title == "Show hover panel" {
            hud.hovered = id; hud.drawIcon(id); hud.showHover(id)
            if let glyph = ModelIdentity.glyph(id) {
                preview?.removeFromSuperview()
                let view = NativeSurface(content: ModelIdentityView(glyph: glyph, name: names[max(0, provider.indexOfSelectedItem)].1), radius: 8)
                view.frame.origin = NSPoint(x: 20, y: 160); window.contentView?.addSubview(view); preview = view
                summary.stringValue = "Model-only hover identifier · existing 7d battery view retained"
            }
        }
        else if let button = hud.hoverAnchors[id] as? NSButton { openPreview(button) }
    }
    /// The preview's copy of a battery opens the same menu the bar's does.
    @objc func openPreview(_ sender: NSButton) {
        hud.closeHover()
        let id = sender.identifier?.rawValue ?? ""
        let menu = id == "usage-hud" ? hud.logoMenu : hud.items[id]?.menu
        menu?.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.minY - 3), in: sender)
    }
    func windowWillClose(_ notification: Notification) { NSApp.terminate(nil) }
}
