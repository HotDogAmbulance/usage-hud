import Cocoa

/// One surface for the group, hover details, identifiers and notices.
/// Panels are a popover blur with a hairline rim.
final class NativeSurface: NSView {
    let materialView: NSView
    let content: NSView
    /// True for the group's tint-only background, whose fill follows `dark`.
    var dark = true { didSet { if dark != oldValue { needsDisplay = true; materialView.needsDisplay = true; rim.needsDisplay = true } } }
    private let rim = RimView()
    init(content: NSView, radius: CGFloat = 12) {
        self.content = content
        let blur = NSVisualEffectView(frame: content.bounds)
        blur.material = .popover; blur.state = .active; blur.blendingMode = .behindWindow
        blur.wantsLayer = true; blur.layer?.cornerRadius = radius; blur.layer?.masksToBounds = true
        blur.addSubview(content)
        materialView = blur
        super.init(frame: content.bounds)
        materialView.autoresizingMask = [.width, .height]
        content.autoresizingMask = [.width, .height]
        addSubview(materialView)
        rim.radius = radius
        addSubview(rim)
    }
    required init?(coder: NSCoder) { nil }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    }
    override func layout() {
        super.layout(); materialView.frame = bounds; content.frame = bounds; rim.frame = bounds
    }
    override func draw(_ dirtyRect: NSRect) {
        rim.dark = dark
    }
}

/// A hairline in the ink colour, as on the system's popovers.
final class RimView: NSView {
    var radius: CGFloat = 12 { didSet { needsDisplay = true } }
    var dark = true { didSet { if dark != oldValue { needsDisplay = true } } }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: radius - 0.5, yRadius: radius - 0.5)
        path.lineWidth = 1
        (dark ? NSColor(white: 1, alpha: 0.16) : NSColor(white: 0, alpha: 0.12)).setStroke(); path.stroke()
    }
}

final class HoverPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Hover is read-only; it cannot intercept the following click on the battery.
final class HoverSurface {
    private(set) var panel: HoverPanel?
    var contentViewController: NSViewController?
    var contentSize = NSSize.zero
    var animates = false
    var dark = false
    var isShown: Bool { panel?.isVisible == true }
    func close() { panel?.orderOut(nil) }
    func show(relativeTo rect: NSRect, of view: NSView, preferredEdge: NSRectEdge) {
        guard let window = view.window, let screen = window.screen, let content = contentViewController?.view else { return }
        let anchor = window.convertToScreen(view.convert(rect, to: nil))
        let hover = panel ?? HoverPanel(contentRect: content.bounds, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        hover.isOpaque = false; hover.backgroundColor = .clear; hover.hasShadow = true
        hover.level = .statusBar; hover.hidesOnDeactivate = false; hover.ignoresMouseEvents = true
        hover.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        hover.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        hover.contentView = NativeSurface(content: content, radius: contentSize.width <= 40 ? 8 : 12)
        let visible = screen.visibleFrame.insetBy(dx: 6, dy: 6)
        // Beside the anchor when asked (a lowered battery has others under it), else below it.
        let beside = preferredEdge == .maxX
        let x = beside ? min(anchor.maxX + 8, visible.maxX - contentSize.width) : min(max(anchor.midX - contentSize.width / 2, visible.minX), visible.maxX - contentSize.width)
        let y = beside ? max(visible.minY, min(anchor.midY - contentSize.height / 2, visible.maxY - contentSize.height))
                       : max(visible.minY, min(anchor.minY - 6 - contentSize.height, visible.maxY - contentSize.height))
        hover.setFrame(NSRect(x: x, y: y, width: contentSize.width, height: contentSize.height), display: false)
        panel = hover; hover.orderFrontRegardless()
    }
}
