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
    /// The cell under the pointer according to the group's own layout. A click that lands on a different button is handed over.
    var route: (NSEvent) -> StatusCellButton? = { _ in nil }
    init(id: String) {
        sourceID = id
        super.init(frame: NSRect(x: 0, y: 0, width: 32, height: 22))
        title = ""; isBordered = false; bezelStyle = .regularSquare
        imagePosition = .imageOnly; imageScaling = .scaleNone; focusRingType = .none
        setButtonType(.momentaryChange)
    }
    required init?(coder: NSCoder) { nil }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    private func handOver(_ event: NSEvent) -> StatusCellButton? {
        let inside = bounds.contains(convert(event.locationInWindow, from: nil))
        let owner = route(event)
        ClickLog.write("click \(sourceID) at \(event.locationInWindow) frame \(frame) inside=\(inside) owner=\(owner?.sourceID ?? "none")")
        guard let owner = owner, owner !== self else { return nil }
        return owner
    }
    override func mouseDown(with event: NSEvent) {
        if let owner = handOver(event) { owner.mouseDown(with: event); return }
        beforeClick(); super.mouseDown(with: event)
    }
    override func rightMouseDown(with event: NSEvent) {
        if let owner = handOver(event) { owner.rightMouseDown(with: event); return }
        beforeClick(); performClick(nil)
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
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); appearanceChanged() }
}

final class StatusGroup {
    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    let content = GroupView(frame: NSRect(x: 0, y: 0, width: 100, height: 22))
    let surface: NativeSurface
    private(set) var order: [String] = []
    var dark = false
    init() {
        surface = NativeSurface(content: content, radius: 11)
        item.autosaveName = "Usage HUD group"
        item.button?.title = ""; item.button?.image = nil
        item.button?.addSubview(surface)
        item.button?.setAccessibilityElement(false)
        content.setAccessibilityElement(false)
    }
    /// Space inside the rounded edge, and between neighbouring batteries (each side of a battery gets half of `gap`).
    static let pad: CGFloat = 7, gap: CGFloat = 6
    /// The button under the pointer by horizontal position alone, so a slightly different bar height cannot change the answer.
    func cellButton(for event: NSEvent) -> StatusCellButton? {
        let x = content.convert(event.locationInWindow, from: nil).x
        return content.subviews.compactMap { $0 as? StatusCellButton }.first { x >= $0.frame.minX && x < $0.frame.maxX }
    }
    func install(_ cells: [StatusCell]) {
        let width = cells.reduce(2 * Self.pad) { $0 + $1.length }
        item.length = width; item.isVisible = !cells.isEmpty
        guard let button = item.button else { return }
        let height = max(22, button.bounds.height - 2)
        surface.frame = NSRect(x: 1, y: (button.bounds.height - height) / 2, width: width - 2, height: height)
        surface.layoutSubtreeIfNeeded()
        var x = Self.pad
        let retained = Set(cells.compactMap { $0.button.map(ObjectIdentifier.init) })
        for view in content.subviews where !retained.contains(ObjectIdentifier(view)) { view.removeFromSuperview() }
        for cell in cells {
            guard let child = cell.button else { continue }
            child.frame = NSRect(x: x, y: (height - 22) / 2, width: cell.length, height: 22)
            if child.superview !== content { content.addSubview(child) }
            child.route = { [weak self] in self?.cellButton(for: $0) }
            child.isHidden = false; x += cell.length
        }
        order = cells.compactMap { $0.button?.sourceID }
    }
}
