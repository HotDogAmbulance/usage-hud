import Cocoa
import CoreText

/// One number across the native silhouette: cut out normally, solid dark ink for a yellow/red warning.
enum BatteryText {
    /// The empty part of a battery is the bar's own ink (white on a dark bar, black on a light one) at a fixed strength, so it
    /// always sits between the bar and the ink instead of at one grey that some wallpaper will match. The strengths are least-squares
    /// fits to four measured native batteries (bar #000000, #545554, #E6E7E8, #FFFFFF); they are not a published Apple specification.
    static func trackAlpha(dark: Bool) -> CGFloat { dark ? 0.68 : 0.49 }
    static func track(dark: Bool) -> NSColor { NSColor(white: dark ? 1 : 0, alpha: trackAlpha(dark: dark)) }
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
