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

/// Opens the hidden batteries out of the logo with no surface or edge behind them, one row each, falling from the logo.
final class DropPresenter {
    private(set) var panel: DropPanel?
    private var monitors: [Any] = []
    /// Counts openings, so a closing animation that ends after the next opening leaves the new one alone.
    private var generation = 0
    private var tiles: [DropTile] = []
    private var starts: [CGPoint] = []
    var isShown: Bool { panel?.isVisible == true }
    /// The logo's window: a click there is the logo's own, which toggles the batteries, so the monitor leaves it alone.
    weak var anchorWindow: NSWindow?
    var onPick: (String) -> Void = { _ in }
    var onContext: (String, NSView, NSEvent) -> Void = { _, _, _ in }
    var onHover: (String, NSView, Bool) -> Void = { _, _, _ in }
    /// Called with the number of hidden batteries now out of the logo (0 when put away), so the bar can draw the rest of the logo.
    var changed: (Int) -> Void = { _ in }
    static let rowHeight: CGFloat = 22, gap: CGFloat = 6
    static var calm: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    func close() {
        monitors.forEach(NSEvent.removeMonitor); monitors = []
        guard let panel = panel, panel.isVisible else { return }
        let opened = generation
        let finish = { [weak self] in
            guard let self = self, self.generation == opened else { return }
            panel.orderOut(nil); self.changed(0)
        }
        if Self.calm { finish(); return }
        // Back into the logo, which never left.
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.22)
        CATransaction.setCompletionBlock(finish)
        // Explicit animations: a view's own layer does not animate a plain change, so the tiles would vanish at once.
        for (tile, start) in zip(tiles, starts) {
            guard let layer = tile.layer else { continue }
            let move = CABasicAnimation(keyPath: "position"); move.fromValue = NSValue(point: layer.position); move.toValue = NSValue(point: start)
            let fade = CABasicAnimation(keyPath: "opacity"); fade.fromValue = 1; fade.toValue = 0
            let shrink = CABasicAnimation(keyPath: "transform.scale"); shrink.fromValue = 1; shrink.toValue = 0.85
            let group = CAAnimationGroup(); group.animations = [move, fade, shrink]; group.duration = 0.22
            group.timingFunction = CAMediaTimingFunction(name: .easeIn)
            layer.opacity = 0; layer.position = start
            layer.add(group, forKey: "lift")
        }
        CATransaction.commit()
    }
    /// `logo` is the stacked-batteries cell on screen. The logo stays as it is; the hidden batteries come out of it, one row
    /// each, below the bar.
    func show(_ entries: [DropTile.Entry], from logo: NSRect, screen: NSScreen) {
        close()
        guard !entries.isEmpty else { return }
        generation += 1
        let count = entries.count, pitch = Self.rowHeight + Self.gap
        let rows = count + 1                    // row 0 is the bar's own row, where the logo is
        let width = max(32, entries.map { $0.image.size.width }.max() ?? 32), height = CGFloat(rows) * pitch - Self.gap
        let origin = NSPoint(x: logo.midX - width / 2, y: logo.midY - 11 - CGFloat(rows - 1) * pitch)
        let content = DropContent(frame: NSRect(x: 0, y: 0, width: width, height: height))
        content.wantsLayer = true; content.dismiss = { [weak self] in self?.close() }
        func rowCentre(_ row: Int) -> CGPoint { CGPoint(x: width / 2, y: height - Self.rowHeight / 2 - CGFloat(row) * pitch) }
        tiles = []; starts = []
        for (index, entry) in entries.enumerated() {
            let tile = DropTile(entry)
            tile.picked = { [weak self] id in self?.onPick(id) }
            tile.contextual = { [weak self] id, view, event in self?.onContext(id, view, event) }
            tile.hover = { [weak self] id, view, inside in self?.onHover(id, view, inside) }
            tile.frame = NSRect(x: width / 2 - entry.image.size.width / 2, y: rowCentre(index + 1).y - entry.image.size.height / 2,
                                width: entry.image.size.width, height: entry.image.size.height)
            content.addSubview(tile); tiles.append(tile)
            starts.append(rowCentre(0))
        }
        let window = panel ?? DropPanel(contentRect: content.bounds, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        window.isOpaque = false; window.backgroundColor = .clear; window.hasShadow = false
        window.level = .statusBar; window.hidesOnDeactivate = false
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        window.contentView = content
        window.title = "Usage HUD — Hidden batteries"
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
        // Like a menu: a click anywhere else puts it away, in another app or on another of this app's items. A click on the logo
        // lands on this panel's empty top row, which puts it away too.
        let clicks: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        if let global = NSEvent.addGlobalMonitorForEvents(matching: clicks, handler: { [weak self] _ in self?.close() }) { monitors.append(global) }
        if let local = NSEvent.addLocalMonitorForEvents(matching: clicks, handler: { [weak self] event in
            if event.window !== self?.panel && event.window !== self?.anchorWindow { self?.close() }
            return event
        }) { monitors.append(local) }
    }
}
