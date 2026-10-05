import Cocoa

/// No vendor artwork is bundled; missing templates retain the normal provider tooltip.
enum ModelIdentity {
    static func glyph(_ id: String) -> NSImage? {
        let resources: (String, [String])
        switch id {
        case "claude": resources = ("Claude", ["TrayIconTemplate@2x.png", "TrayIconTemplate.png"])
        case "codex": resources = ("ChatGPT", ["chatgptTemplate@2x.png", "chatgptTemplate.png"])
        case "kimi-code": resources = ("KimiCode", ["build/trayTemplate@2x.png", "build/trayTemplate.png"])
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
final class ModelIdentityView: NSView {
    override var allowsVibrancy: Bool { true }
    init(glyph: NSImage, name: String) {
        super.init(frame: NSRect(x: 0, y: 0, width: 32, height: 32))
        let image = NSImageView(frame: NSRect(x: 7, y: 7, width: 18, height: 18))
        image.image = glyph; image.imageScaling = .scaleProportionallyUpOrDown
        addSubview(image)
        setAccessibilityElement(true); setAccessibilityRole(.image); setAccessibilityLabel(name)
        toolTip = name
    }
    required init?(coder: NSCoder) { nil }
}
