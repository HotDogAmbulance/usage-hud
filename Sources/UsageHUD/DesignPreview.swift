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
        // Read existing menu-bar glyphs, never substitute a square application icon.
        func glyph(_ path: String, at point: NSPoint, size: CGFloat = 18) {
            guard let source = NSImage(contentsOfFile: path) else { return }
            let image = NSImage(size: NSSize(width: size, height: size))
            image.lockFocus()
            let factor = size / max(source.size.width, source.size.height)
            let scaled = NSSize(width: source.size.width * factor, height: source.size.height * factor)
            source.draw(in: NSRect(x: (size - scaled.width) / 2, y: (size - scaled.height) / 2, width: scaled.width, height: scaled.height))
            NSColor.white.setFill(); NSRect(origin: .zero, size: image.size).fill(using: .sourceIn)
            image.unlockFocus(); image.draw(at: point, from: .zero, operation: .sourceOver, fraction: 1)
        }
        let claudeGlyph = "/Applications/Claude.app/Contents/Resources/TrayIconTemplate@2x.png"
        let openaiGlyph = "/Applications/ChatGPT.app/Contents/Resources/chatgptTemplate@2x.png"
        hud.forcedDarkBar = true
        let codex = Panel(id: "codex", name: "Codex", windows: [Window(label: "5h", pct: 50), Window(label: "7d", pct: 30)])
        try save("logo-hover-demo.png", size: NSSize(width: 1000, height: 420)) {
            text("Hover · giữ nguyên viên pin, thêm dấu nhận diện", 30, 369, size: 22, strong: true)
            text("Codex: 50% còn lại trong 5h / 70% còn lại trong 7d", 30, 338, size: 14)
            for x: CGFloat in [30, 510] {
                NSColor(srgbRed: 0.08, green: 0.35, blue: 0.54, alpha: 1).setFill()
                NSBezierPath(roundedRect: NSRect(x: x, y: 183, width: 450, height: 104), xRadius: 12, yRadius: 12).fill()
            }
            text("Bình thường", 48, 257, strong: true)
            text("Hover", 528, 257, strong: true)
            hud.icon(codex).draw(in: NSRect(x: 222, y: 205, width: 84, height: 66))
            hud.icon(hud.hoverPanel(codex)!, weeklyShade: true).draw(in: NSRect(x: 702, y: 205, width: 84, height: 66))
            // The small identifier sits below the same hovered battery, outside the menu bar.
            NSColor(srgbRed: 0.18, green: 0.20, blue: 0.22, alpha: 1).setFill()
            NSBezierPath(roundedRect: NSRect(x: 728, y: 137, width: 32, height: 32), xRadius: 8, yRadius: 8).fill()
            glyph(openaiGlyph, at: NSPoint(x: 735, y: 144))
            text("Logo mở rộng bên dưới; không thêm cell hoặc đổi chỗ các pin.", 30, 96, size: 14)
            glyph(claudeGlyph, at: NSPoint(x: 32, y: 44), size: 24)
            glyph(openaiGlyph, at: NSPoint(x: 78, y: 44), size: 24)
            text("Asset menu bar thật từ Claude / OpenAI đang cài · mẫu vị trí, chưa áp dụng vào app", 120, 47, size: 12)
        }
        // Optional audit folder contains extracted assets from read-only official installers.
        let audit = ProcessInfo.processInfo.environment["USAGE_HUD_LOGO_AUDIT_DIR"]
        try save("tray-logo-samples.png", size: NSSize(width: 760, height: 230)) {
            text("Menu-bar assets · actual templates", 24, 191, size: 20, strong: true)
            let samples = [("Claude", claudeGlyph), ("OpenAI / Codex", openaiGlyph),
                           ("Kimi Code", audit.map { $0 + "/kimi-code-trayTemplate@2x.png" } ?? ""),
                           ("Antigravity", audit.map { $0 + "/trayTemplate@2x.png" } ?? "")]
            for (i, sample) in samples.enumerated() {
                let x = 30 + CGFloat(i) * 183
                glyph(sample.1, at: NSPoint(x: x + 39, y: 106), size: 24)
                text(sample.0, x, 71, size: 13)
            }
            text("Antigravity keeps its quota table. Model hover gets an identifier only.", 24, 29, size: 12)
        }
        try save("provider-moodboard.png", size: NSSize(width: 1440, height: 960)) {
            text("Usage HUD", 64, 875, size: 20, strong: true)
            text("Your AI usage. At a glance.", 64, 789, size: 48, strong: true)
            text("Plan limits, account balances and team budgets, in the Mac menu bar.", 67, 748, size: 19)
            NSColor(srgbRed: 0.16, green: 0.18, blue: 0.20, alpha: 1).setFill()
            NSBezierPath(roundedRect: NSRect(x: 64, y: 513, width: 1312, height: 188), xRadius: 18, yRadius: 18).fill()
            text("A palette of providers", 86, 666, size: 14, strong: true)
            let providers: [(String, String)] = [("codex", "Codex"), ("claude", "Claude"), ("antigravity", "Antigravity"), ("glm", "GLM"), ("grok", "Grok"), ("xai", "xAI"), ("vercel", "Vercel"), ("deepseek", "DeepSeek"), ("kimi", "Kimi"), ("kimi-code", "Kimi Code"), ("openrouter", "OpenRouter"), ("fireworks", "Fireworks"), ("litellm", "LiteLLM")]
            for (i, provider) in providers.enumerated() {
                let id = provider.0, x = 88 + CGFloat(i) * 99
                var panel = Panel(id: id, name: provider.1, windows: [Window(label: "Budget", pct: 20)])
                if id == "codex" || id == "claude" { panel.windows = [Window(label: "5h", pct: 20), Window(label: "7d", pct: 40)] }
                if id == "antigravity" { panel.windows = [Window(label: "Gemini", pct: 20), Window(label: "Claude & GPT", pct: 30)] }
                if ["vercel", "deepseek", "kimi", "openrouter"].contains(id) { panel.windows = [Window(label: provider.1, right: id == "deepseek" ? "¥26 left" : "$26 left")] }
                let icon = hud.icon(panel)
                icon.draw(in: NSRect(x: x, y: 581, width: icon.size.width * 2, height: icon.size.height * 2))
                text(provider.1, x, 554, size: 11)
            }
            text("13 adapters · illustrated readings · providers appear when connected", 86, 529, size: 11)
            for x: CGFloat in [64, 744] {
                NSColor(srgbRed: 0.13, green: 0.15, blue: 0.17, alpha: 1).setFill()
                NSBezierPath(roundedRect: NSRect(x: x, y: 158, width: 632, height: 307), xRadius: 18, yRadius: 18).fill()
            }
            text("A little room on your Mac", 90, 418, size: 24, strong: true)
            text("Three batteries by default. The others stay within reach.", 90, 387, size: 15)
            NSColor(srgbRed: 0.20, green: 0.23, blue: 0.29, alpha: 1).setFill()
            NSBezierPath(roundedRect: NSRect(x: 90, y: 297, width: 580, height: 54), xRadius: 8, yRadius: 8).fill()
            text("Usage HUD", 106, 315, strong: true)
            let stack = SystemBattery.stacked(); stack.isTemplate = false
            let tint = NSImage(size: stack.size); tint.lockFocus()
            stack.draw(at: .zero, from: .zero, operation: .sourceOver, fraction: 1)
            NSColor.white.setFill(); NSRect(origin: .zero, size: stack.size).fill(using: .sourceIn); tint.unlockFocus()
            tint.draw(at: NSPoint(x: 387, y: 313), from: .zero, operation: .sourceOver, fraction: 1)
            let compact = [codex, Panel(id: "claude", name: "Claude", windows: [Window(label: "5h", pct: 18)]), Panel(id: "openrouter", name: "OpenRouter", windows: [Window(label: "OpenRouter", right: "$26 left")])]
            for (i, panel) in compact.enumerated() { hud.icon(panel).draw(at: NSPoint(x: 430 + CGFloat(i) * 58, y: 313), from: .zero, operation: .sourceOver, fraction: 1) }
            text("50 = 50% left in the current window", 90, 254, size: 15)
            text("26 = $26 left in the account", 90, 226, size: 15)
            text("Hover for weekly usage. Click for all details.", 90, 187, size: 14)
            text("Details when you need them", 770, 418, size: 24, strong: true)
            text("Per-model quotas and reset times, close to the battery.", 770, 387, size: 15)
            preview(CellsView(title: "Antigravity", subtitle: "14 models", rows: [Window(label: "Gemini", pct: 16, right: "↻ 6d 1h"), Window(label: "Claude & GPT", pct: 7, right: "↻ 6d 1h")]), at: NSPoint(x: 785, y: 269))
            text("Full names and refresh controls are a click away.", 770, 222, size: 14)
            text("Keeps the last reading when a source is unavailable.", 770, 191, size: 14)
            text("Open source · Native Swift + AppKit · macOS 12+", 64, 99, size: 15)
            text("First visual study · simulated data · Usage HUD is a working name", 64, 65, size: 12)
        }
        hud.forcedDarkBar = nil
    }
}
