import Cocoa
import UsageHUDCore

/// An in-app notice: no notification permission, focus change, sound or required action.
final class SourceNoticeView: NSVisualEffectView {
    init(_ notice: SourceNotice) {
        let width: CGFloat = 340
        let shown = Array(notice.lines.prefix(3)) + (notice.lines.count > 3 ? ["\(notice.lines.count - 3) more sources updated"] : [])
        let body = NSTextField(wrappingLabelWithString: shown.joined(separator: "\n"))
        body.font = .systemFont(ofSize: 11); body.textColor = .secondaryLabelColor
        let bodyWidth = width - 28
        let size = body.sizeThatFits(NSSize(width: bodyWidth, height: 1000))
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: 56 + ceil(size.height) + 14))
        material = .popover; blendingMode = .behindWindow; state = .active
        wantsLayer = true; layer?.cornerRadius = 12; layer?.masksToBounds = true
        let app = NSTextField(labelWithString: "Usage HUD")
        app.font = .systemFont(ofSize: 10); app.textColor = .secondaryLabelColor
        app.frame = NSRect(x: 14, y: frame.height - 26, width: bodyWidth, height: 14)
        let title = NSTextField(labelWithString: notice.title)
        title.font = .systemFont(ofSize: 12, weight: .semibold)
        title.lineBreakMode = .byTruncatingTail
        title.frame = NSRect(x: 14, y: frame.height - 46, width: bodyWidth, height: 17)
        body.frame = NSRect(x: 14, y: 14, width: bodyWidth, height: ceil(size.height))
        [app, title, body].forEach(addSubview)
        setAccessibilityElement(true); setAccessibilityRole(.group)
        setAccessibilityLabel("Usage HUD. " + notice.title + ". " + notice.lines.joined(separator: ". "))
    }
    required init?(coder: NSCoder) { nil }
}

final class SourceNoticePanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
final class SourceNoticePresenter {
    private(set) var panel: SourceNoticePanel?
    private var dismissal: DispatchWorkItem?
    /// Fixture observers use the same presenter and expiry timer as the menu bar.
    var visibilityChanged: (Bool) -> Void = { _ in }
    func dismiss() {
        dismissal?.cancel(); dismissal = nil
        let wasVisible = panel?.isVisible == true
        panel?.orderOut(nil)
        if wasVisible { visibilityChanged(false) }
    }
    func show(_ notice: SourceNotice, below anchor: NSRect, screen: NSScreen) {
        dismiss()
        let view = SourceNoticeView(notice)
        let window = panel ?? SourceNoticePanel(contentRect: view.bounds, styleMask: [.borderless, .nonactivatingPanel],
                                               backing: .buffered, defer: false)
        window.isOpaque = false; window.backgroundColor = .clear; window.hasShadow = true
        window.level = .statusBar; window.hidesOnDeactivate = false; window.ignoresMouseEvents = true
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        window.contentView = view
        let visible = screen.visibleFrame.insetBy(dx: 8, dy: 8)
        let x = min(max(anchor.midX - view.frame.width / 2, visible.minX), visible.maxX - view.frame.width)
        let y = max(visible.minY, min(anchor.minY - 8 - view.frame.height, visible.maxY - view.frame.height))
        window.setFrame(NSRect(origin: NSPoint(x: x, y: y), size: view.frame.size), display: false)
        window.title = "Usage HUD — Source notice"
        panel = window; window.orderFrontRegardless(); visibilityChanged(true)
        let work = DispatchWorkItem { [weak self] in self?.dismiss() }
        dismissal = work
        DispatchQueue.main.asyncAfter(deadline: .now() + SourceNotice.duration, execute: work)
    }
}
