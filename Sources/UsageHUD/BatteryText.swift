import Cocoa
import CoreText

/// One number across the native silhouette: cut out normally, solid dark ink for a yellow/red warning.
enum BatteryText {
    // Calibrated against the owner's native battery references; not a published Apple pixel specification.
    static func track(dark: Bool) -> NSColor { NSColor(white: dark ? 0.45 : 0.58, alpha: 1) }
    static func draw(_ text: String, font: NSFont, body: NSRect, ink: NSColor, cutout: Bool = false) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        let reference = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [.font: font]))
        let glyphs = CTLineGetImageBounds(reference, context)
        let position = CGPoint(x: ((body.midX - glyphs.midX) * 2).rounded() / 2, y: ((body.midY - glyphs.midY) * 2).rounded() / 2)
        context.saveGState(); context.setBlendMode(cutout ? .destinationOut : .normal); context.textMatrix = .identity; context.textPosition = position
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: cutout ? NSColor.white : ink]))
        CTLineDraw(line, context); context.restoreGState()
    }
}
