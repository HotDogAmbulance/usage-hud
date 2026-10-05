import Cocoa
import UsageHUDCore

/// Model-family colors shared by the main Antigravity battery and its quota cells.
enum BatteryPaint {
    static let claude = NSColor(srgbRed: 0.85, green: 0.58, blue: 0.45, alpha: 1)
    static func colors(_ palette: QuotaPalette?, dark: Bool) -> [NSColor] {
        let black = dark ? NSColor(srgbRed: 0.16, green: 0.16, blue: 0.16, alpha: 1) : .black
        let google = [NSColor(srgbRed: 0.19, green: 0.53, blue: 1, alpha: 1),
                      NSColor(srgbRed: 0.98, green: 0.27, blue: 0.26, alpha: 1),
                      NSColor(srgbRed: 0.98, green: 0.74, blue: 0.07, alpha: 1),
                      NSColor(srgbRed: 0.03, green: 0.73, blue: 0.38, alpha: 1)]
        switch palette {
        case .google: return google
        case .claudeOpenAI: return [black, claude]
        case .claude: return [claude]
        case .openAI: return [black]
        case .mixed: return google + [black, claude]
        case nil: return [dark ? .white : .black]
        }
    }
    static func fill(_ rect: NSRect, body: NSRect, palette: QuotaPalette?, dark: Bool, alpha: CGFloat = 1) {
        let colors = colors(palette, dark: dark).map { $0.withAlphaComponent(alpha) }
        guard colors.count > 1 else { colors[0].setFill(); rect.fill(); return }
        NSGraphicsContext.saveGraphicsState(); NSBezierPath(rect: rect).addClip()
        NSGradient(colors: colors)?.draw(in: body, angle: 0)
        NSGraphicsContext.restoreGraphicsState()
    }
}
