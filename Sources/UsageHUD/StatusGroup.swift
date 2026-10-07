import Cocoa

/// With `~/.usage-hud/click-debug` present, record where each click landed and which cell took it (no account data).
enum ClickLog {
    static func write(_ line: String) {
        let root = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".usage-hud")
        guard FileManager.default.fileExists(atPath: root.appendingPathComponent("click-debug").path),
              let data = (ISO8601DateFormatter().string(from: Date()) + " " + line + "\n").data(using: .utf8) else { return }
        let log = root.appendingPathComponent("click-log.txt")
        if let handle = try? FileHandle(forWritingTo: log) { handle.seekToEndOfFile(); handle.write(data); try? handle.close() }
        else { try? data.write(to: log) }
    }
}

final class StatusCellButton: NSButton {
    let sourceID: String
    var beforeClick: () -> Void = {}
    /// macOS reports every click on a status item at one fixed point, so the cell is found from where the pointer really is.
    var route: () -> StatusCellButton? = { nil }
    /// Files or folders dropped on this cell.
    var onDrop: ([URL]) -> Void = { _ in }
    init(id: String) {
        sourceID = id
        super.init(frame: NSRect(x: 0, y: 0, width: 32, height: 22))
        title = ""; isBordered = false; bezelStyle = .regularSquare
        imagePosition = .imageOnly; imageScaling = .scaleNone; focusRingType = .none
        setButtonType(.momentaryChange)
        registerForDraggedTypes([.fileURL])
    }
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { .copy }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let urls = (sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
        onDrop(urls); return !urls.isEmpty
    }
    required init?(coder: NSCoder) { nil }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    /// The cell the pointer is over now, or this one when the layout cannot say.
    private func target(_ event: NSEvent) -> StatusCellButton {
        let owner = route()
        ClickLog.write("click received by \(sourceID) at \(event.locationInWindow), pointer over \(owner?.sourceID ?? "none")")
        return owner ?? self
    }
    override func mouseDown(with event: NSEvent) {
        let cell = target(event); cell.beforeClick(); cell.performClick(nil)
    }
    override func rightMouseDown(with event: NSEvent) {
        let cell = target(event); cell.beforeClick(); cell.performClick(nil)
    }
}

/// A logical provider cell, not a separate system status item. Its menu and accessibility stay independent.
final class StatusCell {
    let button: StatusCellButton?
    var menu: NSMenu?
    var length: CGFloat
    var isVisible = true
    init(id: String, length: CGFloat = 32) { button = StatusCellButton(id: id); self.length = length }
}

/// Ask AppKit to draw a template using the real status-button cell, including its local wallpaper contrast.
/// This renders our own glyph off-screen, not the screen or the user's wallpaper image.
enum MenuBarInk {
    static let reference: NSImage = {
        let image = NSImage(size: NSSize(width: 8, height: 8))
        image.lockFocus(); NSColor.black.setFill(); NSRect(x: 0, y: 0, width: 8, height: 8).fill(); image.unlockFocus()
        image.isTemplate = true; return image
    }()
    static func isDark(_ button: NSStatusBarButton) -> Bool? {
        guard button.window != nil, let cell = button.cell?.copy() as? NSButtonCell else { return nil }
        cell.title = ""; cell.image = reference; cell.imagePosition = .imageOnly; cell.isHighlighted = false
        let image = NSImage(size: NSSize(width: 24, height: 22))
        button.effectiveAppearance.performAsCurrentDrawingAppearance {
            image.lockFocus(); cell.drawInterior(withFrame: NSRect(x: 0, y: 0, width: 24, height: 22), in: button); image.unlockFocus()
        }
        guard let data = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: data) else { return nil }
        var total: CGFloat = 0, weight: CGFloat = 0
        for y in 0..<bitmap.pixelsHigh {
            for x in 0..<bitmap.pixelsWide {
                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB), color.alphaComponent > 0.1 else { continue }
                total += (color.redComponent * 0.2126 + color.greenComponent * 0.7152 + color.blueComponent * 0.0722) * color.alphaComponent
                weight += color.alphaComponent
            }
        }
        return weight > 0 ? total / weight > 0.5 : nil
    }
}

final class GroupView: NSView {
    var appearanceChanged: () -> Void = {}
    var hover: (Bool) -> Void = { _ in }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); appearanceChanged() }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }
    override func mouseEntered(with event: NSEvent) { hover(true) }
    override func mouseExited(with event: NSEvent) { hover(false) }
}

final class StatusGroup {
    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    let content = GroupView(frame: NSRect(x: 0, y: 0, width: 100, height: 22))
    let surface: NativeSurface
    private(set) var order: [String] = []
    var dark = false { didSet { surface.dark = dark } }
    /// The rounded edge belongs to hover and press only, like the system's own highlight; at rest the batteries sit on the bar.
    private(set) var pointerInside = false
    private var emphasised = false
    /// The pill is the system's own highlight, for hover as well as for a press or an open menu: one drawing, so ours can never
    /// overlap it or hand over to it. (Ours is kept, hidden, only as the fallback below.)
    var menuOpen = false { didSet { refreshEmphasis() } }
    private(set) var pressed = false
    func press(_ down: Bool) { pressed = down; refreshEmphasis() }
    func refreshEmphasis(instant: Bool = false) { setEmphasis(pointerInside || menuOpen || pressed, instant: instant) }
    init() {
        surface = NativeSurface(content: NSView(), radius: StatusGroup.highlightHeight / 2, flat: true)
        item.autosaveName = "Usage HUD group"
        item.button?.title = ""; item.button?.image = nil
        surface.alphaValue = 0
        item.button?.addSubview(surface)
        item.button?.addSubview(content)
        item.button?.setAccessibilityElement(false)
        content.setAccessibilityElement(false)
        // Enter and leave are reported again whenever a battery is redrawn; the pill follows where the pointer is a moment later.
        content.hover = { [weak self] _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                guard let self = self, let window = self.content.window else { return }
                let inside = window.frame.contains(NSEvent.mouseLocation)
                if inside != self.pointerInside { self.pointerInside = inside; self.refreshEmphasis() }
            }
        }
    }
    func setEmphasis(_ on: Bool, instant: Bool = false) {
        if on == emphasised { return }
        emphasised = on
        item.button?.highlight(on)
    }
    /// Space inside the rounded edge, and between neighbouring batteries (each side of a battery gets half of `gap`).
    static let pad: CGFloat = 15, gap: CGFloat = 6
    static let hug: CGFloat = 6, highlightHeight: CGFloat = 20
    /// The button under a point on the screen, by horizontal position alone so a slightly different bar height cannot change
    /// the answer. The default is the pointer now: a status item's click event carries one fixed point whatever was pressed.
    func cellButton(atScreen point: NSPoint = NSEvent.mouseLocation) -> StatusCellButton? {
        guard let window = content.window else { return nil }
        let x = content.convert(window.convertPoint(fromScreen: point), from: nil).x
        return content.subviews.compactMap { $0 as? StatusCellButton }.first { x >= $0.frame.minX && x < $0.frame.maxX }
    }
    func install(_ cells: [StatusCell]) {
        let width = cells.reduce(2 * Self.pad) { $0 + $1.length }
        item.length = width; item.isVisible = !cells.isEmpty
        guard let button = item.button else { return }
        let height = max(22, button.bounds.height)
        // Half a point above centre: that is where the system's own battery sits, measured on a real bar.
        content.frame = NSRect(x: 1, y: (button.bounds.height - height) / 2 + 0.5, width: width - 2, height: height)
        // The pill follows the system's own highlight, measured on macOS 27 from a screenshot of each on the same bar: it hugs the
        // batteries (about 9 pt beyond the first battery's edge and the last one's nub) and is 20 pt tall on the batteries' centre.
        // Measured against the item's edges it is not a fixed inset, because the item is wider than what it holds.
        surface.frame = NSRect(x: content.frame.minX + Self.pad - Self.hug, y: content.frame.midY - Self.highlightHeight / 2,
                               width: width - 2 * Self.pad + 2 * Self.hug, height: Self.highlightHeight)
        surface.layoutSubtreeIfNeeded()
        var x = Self.pad
        let retained = Set(cells.compactMap { $0.button.map(ObjectIdentifier.init) })
        for view in content.subviews where !retained.contains(ObjectIdentifier(view)) { view.removeFromSuperview() }
        for cell in cells {
            guard let child = cell.button else { continue }
            child.frame = NSRect(x: x, y: (height - 22) / 2, width: cell.length, height: 22)
            if child.superview !== content { content.addSubview(child) }
            child.route = { [weak self] in self?.cellButton() }
            child.isHidden = false; x += cell.length
        }
        order = cells.compactMap { $0.button?.sourceID }
    }
}
