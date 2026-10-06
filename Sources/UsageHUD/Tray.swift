import Cocoa
import UsageHUDCore

/// One battery in the tray: its picture, name and reading. Click keeps it in the bar (or lets it go); right-click opens its menu.
final class TrayTile: NSView {
    struct Entry { let id: String, name: String, reading: String, image: NSImage, state: String }
    let entry: Entry
    var picked: (String) -> Void = { _ in }
    var contextual: (String, NSView, NSEvent) -> Void = { _, _, _ in }
    private var inside = false { didSet { needsDisplay = true } }
    static let size = NSSize(width: 108, height: 62)
    init(_ entry: Entry) {
        self.entry = entry
        super.init(frame: NSRect(origin: .zero, size: Self.size))
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
    override func mouseEntered(with event: NSEvent) { inside = true }
    override func mouseExited(with event: NSEvent) { inside = false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { picked(entry.id) }
    override func rightMouseDown(with event: NSEvent) { contextual(entry.id, self, event) }
    override func draw(_ dirtyRect: NSRect) {
        if inside {
            NSColor.labelColor.withAlphaComponent(0.1).setFill()
            NSBezierPath(roundedRect: bounds, xRadius: 9, yRadius: 9).fill()
        }
        let image = entry.image
        let scale = min(1, (bounds.width - 16) / image.size.width)
        let drawn = NSSize(width: image.size.width * scale, height: image.size.height * scale)
        image.draw(in: NSRect(x: (bounds.width - drawn.width) / 2, y: bounds.height - 6 - drawn.height, width: drawn.width, height: drawn.height))
        let clip = NSMutableParagraphStyle(); clip.lineBreakMode = .byTruncatingTail; clip.alignment = .center
        NSAttributedString(string: entry.name, attributes: [.font: NSFont.systemFont(ofSize: 11, weight: .medium), .foregroundColor: NSColor.labelColor, .paragraphStyle: clip])
            .draw(in: NSRect(x: 6, y: 18, width: bounds.width - 12, height: 14))
        let line = entry.reading + (entry.state.isEmpty ? "" : " · " + entry.state)
        NSAttributedString(string: line, attributes: [.font: NSFont.systemFont(ofSize: 10), .foregroundColor: NSColor.secondaryLabelColor, .paragraphStyle: clip])
            .draw(in: NSRect(x: 6, y: 4, width: bounds.width - 12, height: 13))
    }
}

final class TrayPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// The tray under the stacked-batteries cell: every battery as a tile, springing out of that cell. Any click outside closes it.
final class TrayPresenter {
    private(set) var panel: TrayPanel?
    private var monitor: Any?
    var isShown: Bool { panel?.isVisible == true }
    var onPick: (String) -> Void = { _ in }
    var onContext: (String, NSView, NSEvent) -> Void = { _, _, _ in }
    var onAdd: () -> Void = {}
    var onHelp: () -> Void = {}
    var onQuit: () -> Void = {}
    var closed: () -> Void = {}

    func close() {
        if let monitor = monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
        guard let panel = panel, panel.isVisible else { return }
        NSAnimationContext.runAnimationGroup({ $0.duration = 0.14; panel.animator().alphaValue = 0 }, completionHandler: { panel.orderOut(nil) })
        closed()
    }
    func show(_ entries: [TrayTile.Entry], from logo: NSRect, screen: NSScreen, dark: Bool) {
        close()
        let columns = min(4, max(1, entries.count)), rows = (entries.count + columns - 1) / columns
        let gap: CGFloat = 6, inset: CGFloat = 12, footer: CGFloat = 34
        let width = inset * 2 + CGFloat(columns) * TrayTile.size.width + CGFloat(columns - 1) * gap
        let height = inset + CGFloat(rows) * TrayTile.size.height + CGFloat(max(0, rows - 1)) * gap + 10 + footer
        let content = NSView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        var tiles: [TrayTile] = []
        for (index, entry) in entries.enumerated() {
            let tile = TrayTile(entry)
            tile.picked = { [weak self] id in self?.onPick(id) }
            tile.contextual = { [weak self] id, view, event in self?.onContext(id, view, event) }
            let column = index % columns, row = index / columns
            tile.frame.origin = NSPoint(x: inset + CGFloat(column) * (TrayTile.size.width + gap),
                                        y: height - inset - CGFloat(row + 1) * TrayTile.size.height - CGFloat(row) * gap)
            content.addSubview(tile); tiles.append(tile)
        }
        let rule = NSBox(frame: NSRect(x: inset, y: footer + 4, width: width - inset * 2, height: 1)); rule.boxType = .separator
        content.addSubview(rule)
        var x = inset
        for (title, action) in [("Add source…", { [weak self] in self?.onAdd() }), ("How sources work", { [weak self] in self?.onHelp() }), ("Quit", { [weak self] in self?.onQuit() })] as [(String, () -> Void)] {
            let button = TrayLink(title: title, action: action)
            button.frame.origin = NSPoint(x: x, y: 8); x += button.frame.width + 14
            content.addSubview(button)
        }
        let window = panel ?? TrayPanel(contentRect: content.bounds, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        window.isOpaque = false; window.backgroundColor = .clear; window.hasShadow = true
        window.level = .statusBar; window.hidesOnDeactivate = false
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.contentView = NativeSurface(content: content, radius: 16)
        window.title = "Usage HUD — All batteries"
        let visible = screen.visibleFrame.insetBy(dx: 8, dy: 8)
        let originX = min(max(logo.minX - 8, visible.minX), visible.maxX - width)
        let originY = max(visible.minY, logo.minY - 6 - height)
        window.setFrame(NSRect(x: originX, y: originY, width: width, height: height), display: false)
        panel = window; window.alphaValue = 0; window.orderFrontRegardless()
        window.contentView?.layoutSubtreeIfNeeded()
        let calm = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        NSAnimationContext.runAnimationGroup { $0.duration = calm ? 0.12 : 0.18; window.animator().alphaValue = 1 }
        if !calm {
            // Each tile springs out of the logo's place, the nearest first.
            let origin = CGPoint(x: logo.midX - window.frame.minX, y: logo.midY - window.frame.minY)
            for (index, tile) in tiles.enumerated() {
                guard let layer = tile.layer else { continue }
                let target = layer.position
                let move = CASpringAnimation(keyPath: "position")
                move.fromValue = NSValue(point: origin); move.toValue = NSValue(point: target)
                move.damping = 17; move.stiffness = 220; move.mass = 1; move.duration = move.settlingDuration
                let grow = CABasicAnimation(keyPath: "transform.scale"); grow.fromValue = 0.3; grow.toValue = 1; grow.duration = 0.22
                let appear = CABasicAnimation(keyPath: "opacity"); appear.fromValue = 0; appear.toValue = 1; appear.duration = 0.16
                let group = CAAnimationGroup()
                group.animations = [move, grow, appear]; group.duration = move.duration
                group.beginTime = CACurrentMediaTime() + Double(index) * 0.025; group.fillMode = .backwards
                layer.add(group, forKey: "springOut")
            }
        }
        monitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] _ in self?.close() }
    }
}

/// A quiet text button for the tray's foot.
final class TrayLink: NSView {
    let title: String, action: () -> Void
    private var inside = false { didSet { needsDisplay = true } }
    init(title: String, action: @escaping () -> Void) {
        self.title = title; self.action = action
        let width = ceil((title as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 11)]).width) + 14
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: 20))
        setAccessibilityElement(true); setAccessibilityRole(.button); setAccessibilityLabel(title)
    }
    required init?(coder: NSCoder) { nil }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }
    override func mouseEntered(with event: NSEvent) { inside = true }
    override func mouseExited(with event: NSEvent) { inside = false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { action() }
    override func draw(_ dirtyRect: NSRect) {
        if inside { NSColor.labelColor.withAlphaComponent(0.1).setFill(); NSBezierPath(roundedRect: bounds, xRadius: 6, yRadius: 6).fill() }
        NSAttributedString(string: title, attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor])
            .draw(at: NSPoint(x: 7, y: 3))
    }
}
