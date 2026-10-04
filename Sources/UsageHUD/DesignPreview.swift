import Cocoa
import UsageHUDCore

/// Static comparisons rendered by the same AppKit drawing as the app. These are previews, not UI test screenshots.
enum DesignPreview {
    static func write(hud: HUD, to root: URL) throws {
        let appearance = NSAppearance(named: .darkAqua)!
        func text(_ title: String, _ x: CGFloat, _ y: CGFloat, size: CGFloat = 12, strong: Bool = false) {
            (title as NSString).draw(at: NSPoint(x: x, y: y), withAttributes: [.font: NSFont.systemFont(ofSize: size, weight: strong ? .semibold : .regular), .foregroundColor: NSColor.labelColor])
        }
        func save(_ name: String, size: NSSize, draw: () -> Void) throws {
            let image = NSImage(size: size)
            appearance.performAsCurrentDrawingAppearance {
                image.lockFocus(); NSColor(srgbRed: 0.08, green: 0.09, blue: 0.10, alpha: 1).setFill()
                NSRect(origin: .zero, size: size).fill(); draw(); image.unlockFocus()
            }
            let rep = NSBitmapImageRep(data: image.tiffRepresentation!)!
            try rep.representation(using: .png, properties: [:])!.write(to: root.appendingPathComponent(name))
        }
        func preview(_ view: CellsView, at point: NSPoint) {
            view.appearance = appearance
            let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
            view.cacheDisplay(in: view.bounds, to: bitmap)
            NSImage(cgImage: bitmap.cgImage!, size: view.frame.size).draw(in: NSRect(origin: point, size: view.frame.size))
        }
        try save("native-stack-litellm.png", size: NSSize(width: 660, height: 220)) {
            text("Native macOS artwork · overflow + LiteLLM", 18, 190, strong: true)
            text("Kích thước thật trên menu bar", 18, 154)
            let stack = SystemBattery.stacked()
            stack.isTemplate = false
            // Tint a copy for the dark bar using source-in, retaining the installed artwork's alpha.
            let white = NSImage(size: stack.size); white.lockFocus()
            stack.draw(at: .zero, from: .zero, operation: .sourceOver, fraction: 1)
            NSColor.white.setFill(); NSRect(origin: .zero, size: stack.size).fill(using: .sourceIn); white.unlockFocus()
            white.draw(at: NSPoint(x: 20, y: 118), from: .zero, operation: .sourceOver, fraction: 1)
            hud.forcedDarkBar = true
            for (index, id) in ["codex", "antigravity", "claude", "litellm"].enumerated() {
                let rows = id == "antigravity" ? [Window(label: "Gemini", pct: 84), Window(label: "Claude & GPT", pct: 7)] : [Window(label: "5h", pct: id == "claude" ? 30 : 18)]
                let icon = hud.icon(Panel(id: id, name: id, windows: rows, lead: id == "antigravity" ? "Gemini" : nil))
                icon.draw(at: NSPoint(x: 73 + CGFloat(index) * 48, y: 118), from: .zero, operation: .sourceOver, fraction: 1)
            }
            text("Phóng to để so hình thân và đầu pin", 18, 87)
            white.draw(in: NSRect(x: 18, y: 16, width: 96, height: 66))
            let lite = hud.icon(Panel(id: "litellm", name: "LiteLLM", windows: [Window(label: "Budget", pct: 18)]))
            lite.draw(in: NSRect(x: 142, y: 16, width: lite.size.width * 3, height: 66))
            text("#0117BE → #5B3FD1", 268, 43)
            text("Hai màu brand trong cùng một quota", 268, 23, size: 11)
        }
        try save("logo-hover-demo.png", size: NSSize(width: 680, height: 250)) {
            text("A · chỉ logo khi hover", 18, 219, strong: true)
            text("B · tên nhỏ, dễ nhận diện hơn", 356, 219, strong: true)
            for x: CGFloat in [12, 350] {
                NSColor(srgbRed: 0.18, green: 0.19, blue: 0.20, alpha: 1).setFill()
                NSBezierPath(roundedRect: NSRect(x: x, y: 79, width: 316, height: 117), xRadius: 10, yRadius: 10).fill()
            }
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.anthropic.claudefordesktop") {
                NSWorkspace.shared.icon(forFile: url.path).draw(in: NSRect(x: 27, y: 157, width: 22, height: 22))
            }
            text("Max", 62, 161, size: 11)
            preview(CellsView(title: "", rows: [Window(label: "5h", pct: 30, right: "↻ 4h 11m"), Window(label: "7d", pct: 20, right: "↻ 6d 1h")]), at: NSPoint(x: 17, y: 115))
            preview(CellsView(title: "Claude", subtitle: "Max", rows: [Window(label: "5h", pct: 30, right: "↻ 4h 11m"), Window(label: "7d", pct: 20, right: "↻ 6d 1h")]), at: NSPoint(x: 355, y: 115))
            text("Demo dùng icon app Claude đang cài; chưa đổi hover trong app.", 18, 52, size: 11)
            text("Nếu logo khó nhận ra: giữ tên LiteLLM / Kimi / Fireworks, không tự chế monogram.", 18, 30, size: 11)
        }
        hud.forcedDarkBar = nil
    }
}
