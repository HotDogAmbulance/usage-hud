import Cocoa

/// Read-only menu content uses labels rather than disabled menu commands, which AppKit intentionally dims.
final class MenuReadingView: NSView {
    let reading: NSAttributedString
    override var allowsVibrancy: Bool { true }
    override var isFlipped: Bool { true }
    init(_ reading: NSAttributedString, width: CGFloat) {
        self.reading = reading
        let height = ceil(NSFont.menuFont(ofSize: 0).boundingRectForFont.height) + 6
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: height))
        setAccessibilityElement(true); setAccessibilityRole(.staticText); setAccessibilityLabel(reading.string)
    }
    override func draw(_ dirtyRect: NSRect) {
        effectiveAppearance.performAsCurrentDrawingAppearance { reading.draw(in: bounds.insetBy(dx: 14, dy: 3)) }
    }
    required init?(coder: NSCoder) { nil }
}
