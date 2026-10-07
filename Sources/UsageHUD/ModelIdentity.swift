import Cocoa

/// No vendor artwork is bundled; missing templates retain the normal provider tooltip.
enum ModelIdentity {
    static func glyph(_ id: String) -> NSImage? {
        let resources: (String, [String])
        switch id {
        case "claude": resources = ("Claude", ["TrayIconTemplate@2x.png", "TrayIconTemplate.png"])
        case "codex": resources = ("ChatGPT", ["chatgptTemplate@2x.png", "chatgptTemplate.png"])
        case "kimi-code": resources = ("KimiCode", ["build/trayTemplate@2x.png", "build/trayTemplate.png"])
        case "antigravity": return antigravity
        case "grokbot": return grokBot
        default: return nil
        }
        for folder in ["/Applications", FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications").path] {
            for name in resources.1 {
                let path = folder + "/" + resources.0 + ".app/Contents/Resources/" + name
                if let image = NSImage(contentsOfFile: path) { image.isTemplate = true; return image }
            }
        }
        return nil
    }
}
extension ModelIdentity {
    /// Antigravity ships no template of its mark, so it is drawn here: an arch with a notch at its foot. An approximation of
    /// the real mark, kept as a template so it takes the bar's ink like the others.
    static let antigravity: NSImage = {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in
            let outer = NSBezierPath()
            outer.move(to: NSPoint(x: 1, y: 2))
            outer.curve(to: NSPoint(x: 9, y: 16.5), controlPoint1: NSPoint(x: 5.2, y: 2.4), controlPoint2: NSPoint(x: 6.6, y: 14.2))
            outer.curve(to: NSPoint(x: 17, y: 2), controlPoint1: NSPoint(x: 11.4, y: 14.2), controlPoint2: NSPoint(x: 12.8, y: 2.4))
            outer.curve(to: NSPoint(x: 12.4, y: 2), controlPoint1: NSPoint(x: 15.6, y: 2), controlPoint2: NSPoint(x: 13.9, y: 2))
            outer.curve(to: NSPoint(x: 9, y: 7.4), controlPoint1: NSPoint(x: 11.8, y: 4.8), controlPoint2: NSPoint(x: 10.6, y: 7.4))
            outer.curve(to: NSPoint(x: 5.6, y: 2), controlPoint1: NSPoint(x: 7.4, y: 7.4), controlPoint2: NSPoint(x: 6.2, y: 4.8))
            outer.close()
            NSColor.black.setFill(); outer.fill()
            return true
        }
        image.isTemplate = true
        return image
    }()
}
final class ModelIdentityView: NSView {
    override var allowsVibrancy: Bool { true }
    /// The mark alone, or with a short caption beside it (Antigravity names the pool its battery is showing).
    init(glyph: NSImage, name: String, caption: String? = nil) {
        let text = caption.map { NSTextField(labelWithString: $0) }
        text?.font = .systemFont(ofSize: 12, weight: .medium); text?.textColor = .labelColor
        let textWidth = text.map { ceil($0.intrinsicContentSize.width) } ?? 0
        super.init(frame: NSRect(x: 0, y: 0, width: caption == nil ? 32 : 7 + 18 + 7 + textWidth + 11, height: 32))
        let image = NSImageView(frame: NSRect(x: 7, y: 7, width: 18, height: 18))
        image.image = glyph; image.imageScaling = .scaleProportionallyUpOrDown
        addSubview(image)
        if let text = text { text.frame = NSRect(x: 32, y: 8, width: textWidth + 2, height: 16); addSubview(text) }
        setAccessibilityElement(true); setAccessibilityRole(.image); setAccessibilityLabel(name + (caption.map { ", " + $0 } ?? ""))
        toolTip = name
    }
    required init?(coder: NSCoder) { nil }
}
extension ModelIdentity {
    /// Grok Bot ships only its colour app icon, so its mascot is drawn here: a round head with two slanted eyes cut out of it.
    /// An approximation, kept as a template so it takes the bar's ink like the others.
    static let grokBot: NSImage = {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in
            let path = NSBezierPath(ovalIn: NSRect(x: 1, y: 1, width: 16, height: 16))
            for (x, y) in [(5.6, 10.4), (11.6, 11.4)] {
                var eye = NSBezierPath(roundedRect: NSRect(x: -1.0, y: -2.3, width: 2.0, height: 4.6), xRadius: 1, yRadius: 1)
                var move = AffineTransform(translationByX: x, byY: y); move.rotate(byDegrees: -22)
                eye.transform(using: move)
                path.append(eye)
            }
            path.windingRule = .evenOdd
            NSColor.black.setFill(); path.fill()
            return true
        }
        image.isTemplate = true
        return image
    }()
}
