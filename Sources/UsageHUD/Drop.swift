import Cocoa

/// One hidden battery, lowered under the bar. Click keeps it in the bar; drag it onto a battery in the bar to take that place;
/// right-click opens its menu.
final class DropTile: NSView {
    struct Entry { let id: String, name: String, reading: String, image: NSImage, state: String }
    var entry: Entry { didSet { needsDisplay = true; toolTip = entry.name + " · " + entry.reading } }
    var picked: (String) -> Void = { _ in }
    /// Let go after a drag, at this point on the screen.
    var dropped: (String, NSPoint) -> Void = { _, _ in }
    var contextual: (String, NSView, NSEvent) -> Void = { _, _, _ in }
    var hover: (String, NSView, Bool) -> Void = { _, _, _ in }
    init(_ entry: Entry) {
        self.entry = entry
        super.init(frame: NSRect(origin: .zero, size: entry.image.size))
        wantsLayer = true
        toolTip = entry.name + " · " + entry.reading + (entry.state.isEmpty ? "" : " · " + entry.state)
        setAccessibilityElement(true); setAccessibilityRole(.button)
        setAccessibilityLabel(entry.name + ", " + entry.reading + (entry.state.isEmpty ? "" : ", " + entry.state))
        setAccessibilityHelp("Click to keep this battery in the menu bar, or drag it onto a battery in the bar to take its place. Right-click for its menu.")
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
    override func mouseDown(with event: NSEvent) {
        alphaValue = 0.35
        BatteryDrag.follow(entry.image) { [weak self] point in
            guard let self = self else { return }
            self.alphaValue = 1
            if let point = point { self.dropped(self.entry.id, point) } else { self.picked(self.entry.id) }
        }
    }
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

/// A battery carried by the pointer, from a press until the button is let go: its picture follows the pointer in a small
/// window above everything. `done` gets where it was let go, or nil when the pointer never moved past a few points (a click).
/// The button is watched rather than its events: macOS 27 hands an item in the bar its release at once, while the finger is
/// still down, and keeps the drag for itself.
enum BatteryDrag {
    static func follow(_ image: NSImage, done: @escaping (NSPoint?) -> Void) {
        let start = NSEvent.mouseLocation
        var ghost: NSPanel?
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { timer in
            let point = NSEvent.mouseLocation
            if NSEvent.pressedMouseButtons & 1 == 0 {
                timer.invalidate(); ghost?.orderOut(nil); done(ghost == nil ? nil : point); return
            }
            if ghost == nil {
                guard hypot(point.x - start.x, point.y - start.y) > 3 else { return }
                let panel = NSPanel(contentRect: NSRect(origin: .zero, size: image.size), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
                panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = true; panel.ignoresMouseEvents = true
                panel.level = .popUpMenu; panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
                panel.contentView = NSImageView(image: image)
                ghost = panel; panel.orderFrontRegardless()
            }
            ghost?.setFrameOrigin(NSPoint(x: point.x - image.size.width / 2, y: point.y - image.size.height / 2))
        }
        RunLoop.main.add(timer, forMode: .common)
    }
}

/// Lowers the hidden batteries under the bar with no surface or edge behind them, in a grid whose columns stand under the
/// batteries in the bar, so any of them can be dragged straight up onto the one it should replace.
final class DropPresenter {
    private(set) var panel: DropPanel?
    private var monitors: [Any] = []
    /// Counts openings, so a closing animation that ends after the next opening leaves the new one alone.
    private var generation = 0
    private var tiles: [DropTile] = []
    private var starts: [CGPoint] = []
    /// Out, and not already on its way back.
    var isShown: Bool { panel?.isVisible == true && !closing }
    private var closing = false
    /// This app's items on screen (the logo and the batteries): a click there is theirs (the logo toggles, a battery opens its
    /// menu or is dragged down), so the monitors leave it alone. A click on a status item does not report the item's window,
    /// so it is told by where the pointer is.
    private var own: [NSRect] = []
    private var onOwnItem: Bool { own.contains { $0.insetBy(dx: -2, dy: -4).contains(NSEvent.mouseLocation) } }
    var onPick: (String) -> Void = { _ in }
    /// A hidden battery let go after a drag, at this point on the screen.
    var onDrop: (String, NSPoint) -> Void = { _, _ in }
    var onContext: (String, NSView, NSEvent) -> Void = { _, _, _ in }
    var onHover: (String, NSView, Bool) -> Void = { _, _, _ in }
    /// Called with the number of hidden batteries now out (0 when put away).
    var changed: (Int) -> Void = { _ in }
    static let rowHeight: CGFloat = 22, gap: CGFloat = 6
    static var calm: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    /// The hidden battery under a point on the screen, for a battery dragged down from the bar.
    func battery(at point: NSPoint) -> String? {
        guard isShown, let window = panel else { return nil }
        let local = window.convertPoint(fromScreen: point)
        return tiles.first { $0.frame.insetBy(dx: -4, dy: -3).contains(local) }?.entry.id
    }
    /// New readings for the same hidden batteries: the tiles are redrawn where they are. Says false when the set or a tile's
    /// size changed, which needs a fresh opening.
    func refresh(_ entries: [DropTile.Entry]) -> Bool {
        guard isShown, entries.map(\.id) == tiles.map(\.entry.id),
              zip(entries, tiles).allSatisfy({ $0.image.size == $1.entry.image.size }) else { return false }
        for (entry, tile) in zip(entries, tiles) { tile.entry = entry }
        return true
    }
    func close() {
        monitors.forEach(NSEvent.removeMonitor); monitors = []
        guard let panel = panel, panel.isVisible, !closing else { return }
        closing = true
        let opened = generation
        let finish = { [weak self] in
            guard let self = self, self.generation == opened else { return }
            panel.orderOut(nil); self.closing = false; self.changed(0)
        }
        ClickLog.write("drop closes")
        if Self.calm { finish(); return }
        // Back under the bar. Put away on a timer rather than a transaction's completion, which did not always come and left
        // an empty panel up.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.24, execute: finish)
        CATransaction.begin()
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
    /// `columns` are the batteries in the bar, left to right, on screen (the logo's place when there are none); the hidden
    /// batteries fill the rows under them, left to right. `own` is every item of this app on screen. `animated` false redraws
    /// in place, after a swap.
    func show(_ entries: [DropTile.Entry], columns: [NSRect], own: [NSRect], animated: Bool = true) {
        let wasOpen = isShown
        if wasOpen && !animated { panel?.orderOut(nil); monitors.forEach(NSEvent.removeMonitor); monitors = [] } else { close() }
        guard !entries.isEmpty, let first = columns.first else { changed(0); return }
        generation += 1
        self.own = own
        ClickLog.write("drop opens with \(entries.count) under \(columns.count) columns")
        if closing, let old = panel { old.orderOut(nil); closing = false }
        let pitch = Self.rowHeight + Self.gap, count = columns.count, rows = (entries.count + count - 1) / count
        let widest = max(32, entries.map { $0.image.size.width }.max() ?? 32)
        let minX = (columns.map(\.midX).min() ?? first.midX) - widest / 2 - 2, maxX = (columns.map(\.midX).max() ?? first.midX) + widest / 2 + 2
        // Below the bar only: a window over the bar itself makes macOS give the bar a solid backing for a few seconds.
        let width = maxX - minX, height = CGFloat(rows) * pitch + 4
        let origin = NSPoint(x: minX, y: first.minY - 1 - height)
        let content = DropContent(frame: NSRect(x: 0, y: 0, width: width, height: height))
        content.wantsLayer = true; content.dismiss = { [weak self] in self?.close() }
        tiles = []; starts = []
        for (index, entry) in entries.enumerated() {
            let column = columns[index % count].midX - minX, row = CGFloat(index / count)
            let tile = DropTile(entry)
            tile.picked = { [weak self] id in self?.onPick(id) }
            tile.dropped = { [weak self] id, point in self?.onDrop(id, point) }
            tile.contextual = { [weak self] id, view, event in self?.onContext(id, view, event) }
            tile.hover = { [weak self] id, view, inside in self?.onHover(id, view, inside) }
            let y = height - 4 - Self.rowHeight / 2 - row * pitch
            tile.frame = NSRect(x: (column - entry.image.size.width / 2).rounded(), y: (y - entry.image.size.height / 2).rounded(),
                                width: entry.image.size.width, height: entry.image.size.height)
            content.addSubview(tile); tiles.append(tile)
            // Each battery comes out from under the bar's edge, above its own column, and goes back there.
            starts.append(CGPoint(x: column, y: height + Self.rowHeight / 2))
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
        changed(entries.count)
        window.orderFrontRegardless()
        content.layoutSubtreeIfNeeded()
        if animated && !Self.calm {
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
        // Like a menu: a click anywhere else puts it away, in another app or on another app's item. Clicks on this app's own
        // items are theirs.
        let clicks: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        // macOS 27 hands a click on a status item through the system first, so it reaches the global monitor too.
        if let global = NSEvent.addGlobalMonitorForEvents(matching: clicks, handler: { [weak self] _ in
            guard let self = self, !self.onOwnItem else { return }
            self.close()
        }) { monitors.append(global) }
        if let local = NSEvent.addLocalMonitorForEvents(matching: clicks, handler: { [weak self] event in
            guard let self = self else { return event }
            if event.window !== self.panel && !self.onOwnItem { self.close() }
            return event
        }) { monitors.append(local) }
    }
}
