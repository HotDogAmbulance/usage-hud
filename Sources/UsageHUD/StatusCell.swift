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

/// One battery, or the logo, as its own status item, the way the system's own icons are: the system draws the press
/// highlight around just this item, opens its menu under it, and the space between items takes no click.
final class StatusCell {
    let id: String
    let item: NSStatusItem
    private let catcher = FileCatcher()
    var button: NSStatusBarButton? { item.button }
    var menu: NSMenu? { get { item.menu } set { item.menu = newValue } }
    var isVisible: Bool { get { item.isVisible } set { item.isVisible = newValue } }
    var length: CGFloat { button?.frame.width ?? item.length }
    /// Files or folders dropped on this item.
    var onDrop: ([URL]) -> Void { get { catcher.onDrop } set { catcher.onDrop = newValue } }
    /// The button's tooltip, shown over the file catcher that covers it.
    var toolTip: String? { get { button?.toolTip } set { button?.toolTip = newValue; catcher.toolTip = newValue } }
    init(id: String) {
        self.id = id
        // Variable length: the system pads the image as it pads its own icons.
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.autosaveName = "Usage HUD " + id
        // macOS keeps each item's shown/hidden state by name and hands a new item whatever an old one left behind, so a new
        // item can start hidden; the app decides (`arrange`).
        item.isVisible = true
        guard let button = item.button else { return }
        button.title = ""; button.imagePosition = .imageOnly
        catcher.frame = button.bounds; catcher.autoresizingMask = [.width, .height]
        button.addSubview(catcher)
    }
    deinit { NSStatusBar.system.removeStatusItem(item) }
}

/// Takes files dragged onto a status item; every click goes on to the item's own button, so the system handles it as its own.
final class FileCatcher: NSView {
    var onDrop: ([URL]) -> Void = { _ in }
    override init(frame: NSRect) {
        super.init(frame: frame)
        registerForDraggedTypes([.fileURL]); setAccessibilityElement(false)
    }
    required init?(coder: NSCoder) { nil }
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { .copy }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let urls = (sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
        onDrop(urls); return !urls.isEmpty
    }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { superview?.mouseDown(with: event) }
    override func rightMouseDown(with event: NSEvent) { superview?.rightMouseDown(with: event) }
    override func otherMouseDown(with event: NSEvent) { superview?.otherMouseDown(with: event) }
    override func mouseUp(with event: NSEvent) { superview?.mouseUp(with: event) }
    override func rightMouseUp(with event: NSEvent) { superview?.rightMouseUp(with: event) }
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
