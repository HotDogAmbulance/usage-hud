import Cocoa
import UsageHUDCore

/// Runs the production status buttons, menus and hover view with disposable readings.
/// Refresh is intercepted here, so this mode never reads credentials or contacts a provider.
final class FixtureHUD: HUD {
    var recovered: () -> Void = {}
    override func load(_ refresh: String?, also: Set<String> = []) { recovered() }
}
final class ProductTest: NSObject, NSApplicationDelegate, NSWindowDelegate {
    let hud = FixtureHUD()
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 440),
                          styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
    let provider = NSPopUpButton(frame: NSRect(x: 20, y: 349, width: 250, height: 28))
    let summary = NSTextField(wrappingLabelWithString: "")
    var preview: NSView?
    var state = "Fresh"
    let names = [("codex", "Codex"), ("claude", "Claude"), ("antigravity", "Antigravity"), ("openrouter", "OpenRouter"),
                 ("grok", "Grok"), ("xai", "xAI"), ("vercel", "Vercel"), ("deepseek", "DeepSeek"), ("kimi", "Kimi"),
                 ("kimi-code", "Kimi Code"), ("fireworks", "Fireworks"), ("litellm", "LiteLLM")]
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        window.title = "Usage HUD — Product Test"; window.delegate = self
        let info = NSTextField(wrappingLabelWithString: "Usage HUD · simulated provider readings\nThe batteries and menus use the app's normal rendering. Refresh recovers the fixture. No account or API calls.")
        info.frame = NSRect(x: 20, y: 386, width: 560, height: 44); window.contentView?.addSubview(info)
        provider.addItems(withTitles: names.map { $0.1 }); provider.target = self; provider.action = #selector(providerChanged)
        window.contentView?.addSubview(provider)
        for (index, title) in ["Fresh", "Cached", "Partial", "Recovered", "11 models", "Many keys", "Cycles", "Low quota"].enumerated() {
            let button = NSButton(title: title, target: self, action: #selector(scenario(_:)))
            button.frame = NSRect(x: 20 + CGFloat(index % 4) * 140, y: 306 - CGFloat(index / 4) * 35, width: 132, height: 28)
            window.contentView?.addSubview(button)
        }
        summary.frame = NSRect(x: 20, y: 220, width: 560, height: 40); window.contentView?.addSubview(summary)
        for (index, title) in ["Open provider menu", "Show hover panel", "Open overflow menu"].enumerated() {
            let button = NSButton(title: title, target: self, action: #selector(open(_:)))
            button.frame = NSRect(x: 20 + CGFloat(index) * 186, y: 18, width: 178, height: 30)
            window.contentView?.addSubview(button)
        }
        hud.recovered = { [weak self] in self?.state = "Recovered"; self?.show() }
        show(); window.center(); window.makeKeyAndOrderFront(nil)
    }
    @objc func providerChanged() { show() }
    @objc func scenario(_ sender: NSButton) { state = sender.title; show() }
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
                Window(label: "Claude & GPT", pct: low ? 99 : 7, right: "↻ 6h", resets_at: reset, stale: cached)] :
                [Window(label: "5h", pct: low ? 99 : 18, resets_at: reset, stale: cached || partial), Window(label: "7d", pct: low ? 99 : 30, resets_at: reset + 86400 * 6, stale: cached)]
            panel = Panel(id: id, name: name, windows: rows, cells: id == "antigravity" ? rows : [],
                          cellsTitle: id == "antigravity" ? (state == "11 models" ? "11 models" : "14 models") : nil)
            if id == "grok" { panel.windows = [Window(label: "7d", pct: low ? 99 : 30, resets_at: reset + 86400 * 6, stale: cached || partial)] }
            if id == "codex" { panel.windows.append(Window(label: "OpenAI API", right: "$40.47 · estimate", stale: cached || partial)) }
        }
        if cached || partial { panel.note = "Source unavailable; last reading retained" }
        return panel
    }
    func show() {
        hud.popover.close(); hud.hovered = nil
        let selected = names[max(0, provider.indexOfSelectedItem)]
        let panels = names.map { fixture($0.0, $0.1) }
        panels.forEach { hud.render($0) }
        hud.shelf = Shelf(); hud.arrange([selected.0] + names.map { $0.0 }.filter { $0 != selected.0 })
        let panel = panels.first { $0.id == selected.0 }!
        summary.stringValue = selected.1 + " · " + state + "\nClick its battery above, or use the buttons below to open its real menu/hover panel."
        preview?.removeFromSuperview()
        let view = CellsView(title: panel.name, subtitle: panel.cellsTitle, lines: panel.note.isEmpty ? [] : [panel.note],
                             rows: Array((panel.cells.isEmpty ? panel.windows : panel.cells).prefix(5)),
                             more: max(0, panel.cells.count - 5))
        view.frame.origin = NSPoint(x: 20, y: max(53, 210 - view.frame.height)); window.contentView?.addSubview(view); preview = view
    }
    @objc func open(_ sender: NSButton) {
        let id = names[max(0, provider.indexOfSelectedItem)].0
        if sender.title == "Open overflow menu" { hud.overflow?.menu?.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.maxY), in: sender) }
        else if sender.title == "Show hover panel" { hud.hovered = id; hud.showCells(id) }
        else { hud.items[id]?.menu?.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.maxY), in: sender) }
    }
    func windowWillClose(_ notification: Notification) { NSApp.terminate(nil) }
}
