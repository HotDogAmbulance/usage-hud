import Cocoa

/// One native material for the group, hover details, identifiers and notices.
/// Runtime lookup uses the documented public API so an older SDK can still build the app.
final class NativeSurface: NSView {
    let materialView: NSView
    let content: NSView
    let usesLiquidGlass: Bool
    init(content: NSView, radius: CGFloat = 12) {
        self.content = content
        if #available(macOS 26, *), let type = NSClassFromString("NSGlassEffectView") as? NSView.Type {
            let glass = type.init(frame: content.bounds)
            glass.setValue(content, forKey: "contentView")
            glass.setValue(radius, forKey: "cornerRadius")
            materialView = glass; usesLiquidGlass = true
        } else {
            let blur = NSVisualEffectView(frame: content.bounds)
            blur.material = .popover; blur.state = .active; blur.blendingMode = .behindWindow
            blur.wantsLayer = true; blur.layer?.cornerRadius = radius; blur.layer?.masksToBounds = true
            blur.addSubview(content)
            materialView = blur; usesLiquidGlass = false
        }
        super.init(frame: content.bounds)
        materialView.autoresizingMask = [.width, .height]
        content.autoresizingMask = [.width, .height]
        addSubview(materialView)
    }
    required init?(coder: NSCoder) { nil }
    override func layout() {
        super.layout(); materialView.frame = bounds; content.frame = bounds
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
        let x = min(max(anchor.midX - contentSize.width / 2, visible.minX), visible.maxX - contentSize.width)
        let y = max(visible.minY, min(anchor.minY - 6 - contentSize.height, visible.maxY - contentSize.height))
        hover.setFrame(NSRect(x: x, y: y, width: contentSize.width, height: contentSize.height), display: false)
        panel = hover; hover.orderFrontRegardless()
    }
}
