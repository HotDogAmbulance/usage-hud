import Cocoa

/// One hidden battery, lowered out of the stacked-batteries logo. Click keeps it in the bar (or lets it go); right-click opens its menu.
final class DropTile: NSView {
    struct Entry { let id: String, name: String, reading: String, image: NSImage, state: String }
    let entry: Entry
    var picked: (String) -> Void = { _ in }
    var contextual: (String, NSView, NSEvent) -> Void = { _, _, _ in }
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
    private var ghosts: [CALayer] = []
    private var tiles: [DropTile] = []
    private var starts: [CGPoint] = []
    var isShown: Bool { panel?.isVisible == true }
    var onPick: (String) -> Void = { _ in }
    var onContext: (String, NSView, NSEvent) -> Void = { _, _, _ in }
    /// Called with the number of hidden batteries now out of the logo (0 when put away), so the bar can draw the rest of the logo.
    var changed: (Int) -> Void = { _ in }
    static let rowHeight: CGFloat = 22, gap: CGFloat = 6
    static var calm: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    func close() {
        if let monitor = monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
        guard let panel = panel, panel.isVisible else { return }
        let finish = { [weak self] in panel.orderOut(nil); self?.changed(0) }
        if Self.calm { finish(); return }
        // Back into the logo: ghosts return, tiles retreat to where they came from.
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.22)
        CATransaction.setCompletionBlock(finish)
        for ghost in ghosts { ghost.opacity = 1 }
        for (tile, start) in zip(tiles, starts) { tile.layer?.opacity = 0; tile.layer?.position = start }
        CATransaction.commit()
    }
    /// `logo` is the stacked-batteries cell on screen; `front` and `rear` are its two batteries drawn on their own.
    func show(_ entries: [DropTile.Entry], from logo: NSRect, logoImages: (rear: NSImage, front: NSImage), screen: NSScreen) {
        close()
        guard !entries.isEmpty else { return }
        let count = entries.count, pitch = Self.rowHeight + Self.gap
        let rows = max(2, count)
        let width = max(32, entries.map { $0.image.size.width }.max() ?? 32), height = CGFloat(rows) * pitch - Self.gap
        let origin = NSPoint(x: logo.midX - width / 2, y: logo.midY - 11 - CGFloat(rows - 1) * pitch)
        let content = DropContent(frame: NSRect(x: 0, y: 0, width: width, height: height))
        content.wantsLayer = true; content.dismiss = { [weak self] in self?.close() }
        func rowCentre(_ row: Int) -> CGPoint { CGPoint(x: width / 2, y: height - Self.rowHeight / 2 - CGFloat(row) * pitch) }
        // The logo's batteries sit at (14, 12.5) and (18, 8.5) from the lower left of its 32 x 22 picture; row 0 is the bar's own row.
        let logoOrigin = CGPoint(x: width / 2 - 16, y: height - Self.rowHeight)
        let rearStart = CGPoint(x: logoOrigin.x + 14, y: logoOrigin.y + 12.5), frontStart = CGPoint(x: logoOrigin.x + 18, y: logoOrigin.y + 8.5)
        tiles = []; starts = []; ghosts = []
        for (index, entry) in entries.enumerated() {
            let tile = DropTile(entry)
            tile.picked = { [weak self] id in self?.onPick(id) }
            tile.contextual = { [weak self] id, view, event in self?.onContext(id, view, event) }
            let row = count == 1 ? 1 : index
            tile.frame = NSRect(x: width / 2 - entry.image.size.width / 2, y: rowCentre(row).y - entry.image.size.height / 2,
                                width: entry.image.size.width, height: entry.image.size.height)
            content.addSubview(tile); tiles.append(tile)
            starts.append(count >= 2 && index == 0 ? rearStart : frontStart)
        }
        func ghost(_ image: NSImage) -> CALayer {
            let layer = CALayer()
            layer.frame = CGRect(origin: logoOrigin, size: image.size)
            layer.contents = image.cgImage(forProposedRect: nil, context: nil, hints: nil)
            layer.contentsScale = NSScreen.main?.backingScaleFactor ?? 2
            content.layer?.addSublayer(layer); ghosts.append(layer)
            return layer
        }
        let frontGhost = ghost(logoImages.front)
        let rearGhost = count >= 2 ? ghost(logoImages.rear) : nil
        let window = panel ?? DropPanel(contentRect: content.bounds, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        window.isOpaque = false; window.backgroundColor = .clear; window.hasShadow = false
        window.level = .statusBar; window.hidesOnDeactivate = false
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        window.contentView = content
        window.title = "Usage HUD — Hidden batteries"
        window.setFrame(NSRect(origin: origin, size: content.bounds.size), display: false)
        panel = window
        changed(count)           // the bar's logo now shows only what stays: the rear battery for one, nothing for two or more
        window.orderFrontRegardless()
        content.layoutSubtreeIfNeeded()
        if !Self.calm {
            for (index, tile) in tiles.enumerated() {
                guard let layer = tile.layer else { continue }
                let target = layer.position, delay = CACurrentMediaTime() + Double(max(0, index - 1)) * 0.035
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
            // The logo's own batteries let go of their outline as the coloured ones arrive; the front one travels with its tile.
            let fade = CABasicAnimation(keyPath: "opacity"); fade.fromValue = 1; fade.toValue = 0; fade.duration = 0.22
            rearGhost?.opacity = 0; rearGhost?.add(fade, forKey: "fade")
            let follow = CASpringAnimation(keyPath: "position")
            let landing = rowCentre(count == 1 ? 1 : 1)
            follow.fromValue = NSValue(point: frontGhost.position)
            follow.toValue = NSValue(point: CGPoint(x: frontGhost.position.x + (landing.x - frontStart.x), y: frontGhost.position.y + (landing.y - frontStart.y)))
            follow.damping = 16; follow.stiffness = 230; follow.mass = 1; follow.duration = follow.settlingDuration
            let gone = CABasicAnimation(keyPath: "opacity"); gone.fromValue = 1; gone.toValue = 0; gone.duration = 0.22
            let both = CAAnimationGroup(); both.animations = [follow, gone]; both.duration = follow.duration
            frontGhost.opacity = 0; both.fillMode = .forwards
            frontGhost.add(both, forKey: "follow")
        } else {
            ghosts.forEach { $0.opacity = 0 }
        }
        for ghost in ghosts { ghost.opacity = 0 }
        monitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] _ in self?.close() }
    }
}
