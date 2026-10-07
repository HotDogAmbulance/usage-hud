import Cocoa

/// One hidden battery, lowered out of the stacked-batteries logo. Click keeps it in the bar (or lets it go); right-click opens its menu.
final class DropTile: NSView {
    struct Entry { let id: String, name: String, reading: String, image: NSImage, state: String }
    let entry: Entry
    var picked: (String) -> Void = { _ in }
    var contextual: (String, NSView, NSEvent) -> Void = { _, _, _ in }
    var hover: (String, NSView, Bool) -> Void = { _, _, _ in }
    init(_ entry: Entry) {
        self.entry = entry
        super.init(frame: NSRect(origin: .zero, size: entry.image.size))
        wantsLayer = true
        toolTip = entry.name + " · " + entry.reading + (entry.state.isEmpty ? "" : " · " + entry.state)
        setAccessibilityElement(true); setAccessibilityRole(.button)
        setAccessibilityLabel(entry.name + ", " + entry.reading + (entry.state.isEmpty ? "" : ", " + entry.state))
        setAccessibilityHelp("Click to keep this battery in the menu bar, or let it go. Right-click for its menu.")
    }
    required init?(coder: NSCoder) { nil }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }
    override func mouseEntered(with event: NSEvent) { hover(entry.id, self, true) }
    override func mouseExited(with event: NSEvent) { hover(entry.id, self, false) }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { picked(entry.id) }
    override func rightMouseDown(with event: NSEvent) { contextual(entry.id, self, event) }
    override func draw(_ dirtyRect: NSRect) { entry.image.draw(in: bounds) }
}

final class DropPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// A click on the panel's empty strip (where the logo was) puts everything away.
final class DropContent: NSView {
    var dismiss: () -> Void = {}
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { dismiss() }
}

/// Opens the hidden batteries out of the logo with no surface behind them: with one hidden, the logo's front battery drops
/// and becomes it; with two or more, both logo batteries become the first two and the rest follow in a column.
final class DropPresenter {
    private(set) var panel: DropPanel?
    private var monitor: Any?
    private var tiles: [DropTile] = []
    private var starts: [CGPoint] = []
    var isShown: Bool { panel?.isVisible == true }
    /// Whether the bar is dark, which the surface follows like the hover panels.
    var dark = true
    var onPick: (String) -> Void = { _ in }
    var onContext: (String, NSView, NSEvent) -> Void = { _, _, _ in }
    var onHover: (String, NSView, Bool) -> Void = { _, _, _ in }
    /// Called with the number of hidden batteries now out of the logo (0 when put away), so the bar can draw the rest of the logo.
    var changed: (Int) -> Void = { _ in }
    static let rowHeight: CGFloat = 22, gap: CGFloat = 6
    static var calm: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    func close() {
        if let monitor = monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
        guard let panel = panel, panel.isVisible else { return }
        let finish = { [weak self] in panel.orderOut(nil); self?.changed(0) }
        if Self.calm { finish(); return }
        // Back into the logo, which never left.
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.22)
        CATransaction.setCompletionBlock(finish)
        for (tile, start) in zip(tiles, starts) { tile.layer?.opacity = 0; tile.layer?.position = start }
        panel.contentView?.subviews.first?.layer?.opacity = 0
        CATransaction.commit()
    }
    /// `logo` is the stacked-batteries cell on screen. The logo stays as it is; the hidden batteries come out of it, one row
    /// each, below the bar.
    func show(_ entries: [DropTile.Entry], from logo: NSRect, screen: NSScreen) {
        close()
        guard !entries.isEmpty else { return }
        let count = entries.count, pitch = Self.rowHeight + Self.gap
        let inner = max(32, entries.map { $0.image.size.width }.max() ?? 32), width = inner + 20
        // The bar's own row (where the logo is), a hairline gap, then the glass holding one row per battery.
        let glassHeight = CGFloat(count) * pitch - Self.gap + 16, height = Self.rowHeight + 3 + glassHeight
        let origin = NSPoint(x: logo.midX - width / 2, y: logo.midY + 11 - height)
        let content = DropContent(frame: NSRect(x: 0, y: 0, width: width, height: height))
        content.wantsLayer = true; content.dismiss = { [weak self] in self?.close() }
        // A click's surface, like the system menus next to it; the hover panels have their own.
        let glass = MenuSurface.make(frame: NSRect(x: 0, y: 0, width: width, height: glassHeight))
        content.addSubview(glass)
        func rowCentre(_ row: Int) -> CGPoint { CGPoint(x: width / 2, y: glassHeight - 8 - Self.rowHeight / 2 - CGFloat(row) * pitch) }
        let logoCentre = CGPoint(x: width / 2, y: height - Self.rowHeight / 2)
        tiles = []; starts = []
        for (index, entry) in entries.enumerated() {
            let tile = DropTile(entry)
            tile.picked = { [weak self] id in self?.onPick(id) }
            tile.contextual = { [weak self] id, view, event in self?.onContext(id, view, event) }
            tile.hover = { [weak self] id, view, inside in self?.onHover(id, view, inside) }
            tile.frame = NSRect(x: width / 2 - entry.image.size.width / 2, y: rowCentre(index).y - entry.image.size.height / 2,
                                width: entry.image.size.width, height: entry.image.size.height)
            content.addSubview(tile); tiles.append(tile)
            starts.append(logoCentre)
        }
        glass.wantsLayer = true
        if !Self.calm {
            let rise = CABasicAnimation(keyPath: "opacity"); rise.fromValue = 0; rise.toValue = 1; rise.duration = 0.18
            glass.layer?.add(rise, forKey: "appear")
        }
        let window = panel ?? DropPanel(contentRect: content.bounds, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        window.isOpaque = false; window.backgroundColor = .clear; window.hasShadow = true
        window.level = .statusBar; window.hidesOnDeactivate = false
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        window.contentView = content
        window.title = "Usage HUD — Hidden batteries"
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        // The computed size, not content.bounds: assigning contentView already shrank it to a reused panel's old frame,
        // which cut a wider battery (a balance with cents) short on its right.
        window.setFrame(NSRect(origin: origin, size: NSSize(width: width, height: height)), display: false)
        panel = window
        changed(count)
        window.orderFrontRegardless()
        content.layoutSubtreeIfNeeded()
        if !Self.calm {
            for (index, tile) in tiles.enumerated() {
                guard let layer = tile.layer else { continue }
                let target = layer.position, delay = CACurrentMediaTime() + Double(index) * 0.035
                let move = CASpringAnimation(keyPath: "position")
                move.fromValue = NSValue(point: starts[index]); move.toValue = NSValue(point: target)
                move.damping = 16; move.stiffness = 230; move.mass = 1; move.duration = move.settlingDuration
                let grow = CABasicAnimation(keyPath: "transform.scale"); grow.fromValue = 0.85; grow.toValue = 1; grow.duration = 0.22
                let appear = CABasicAnimation(keyPath: "opacity"); appear.fromValue = 0; appear.toValue = 1; appear.duration = 0.2
                let group = CAAnimationGroup()
                group.animations = [move, grow, appear]; group.duration = move.duration
                group.beginTime = delay; group.fillMode = .backwards
                layer.add(group, forKey: "drop")
            }
        }
        monitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] _ in self?.close() }
    }
}
