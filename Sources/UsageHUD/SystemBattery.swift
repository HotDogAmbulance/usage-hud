import Cocoa

// Read the installed system artwork through AppKit. Nothing is copied into the bundle.
// Cache the masks once; the interior of the outline is filled without changing its outer edge.
enum SystemBattery {
    private static let resources = Bundle(path: "/System/Library/CoreServices/ControlCenter.app")
    static let body = mask("battery-outline", fillInterior: true)
    static let cap = mask("battery-cap", fillInterior: false)
    static let outline = mask("battery-outline", fillInterior: false)

    /// Two copies of the installed Mac battery artwork; the front copy masks the rear one.
    static let stackedWidth: CGFloat = 32
    static func stacked(dark: Bool) -> NSImage {
        let image = NSImage(size: NSSize(width: stackedWidth, height: 22))
        image.lockFocus()
        func paint(_ mask: CGImage?, in rect: NSRect, ink: NSColor, operation: CGBlendMode = .normal) {
            guard let mask = mask, let context = NSGraphicsContext.current?.cgContext else { return }
            context.saveGState(); context.setBlendMode(operation); context.clip(to: rect, mask: mask)
            ink.setFill(); rect.fill(); context.restoreGState()
        }
        for (x, y, front) in [(CGFloat(1), CGFloat(8), false), (CGFloat(5), CGFloat(4), true)] {
            let rect = NSRect(x: x, y: y, width: 23, height: 12)
            let capRect = NSRect(x: x + 24, y: y, width: 2, height: 12)
            if front {
                paint(body, in: rect, ink: .black, operation: .destinationOut)
                paint(cap, in: capRect, ink: .black, operation: .destinationOut)
            }
            if outline != nil {
                paint(outline, in: rect, ink: .black.withAlphaComponent(front ? 1 : BatteryText.trackAlpha(dark: dark)))
            } else {
                NSColor.black.withAlphaComponent(front ? 1 : BatteryText.trackAlpha(dark: dark)).setStroke()
                let fallback = NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: 3.5, yRadius: 3.5)
                fallback.lineWidth = 1; fallback.stroke()
            }
            paint(cap, in: capRect, ink: .black.withAlphaComponent(front ? 0.5 : 0.35))
        }
        image.unlockFocus(); image.isTemplate = true
        return image
    }

    private static func mask(_ name: String, fillInterior: Bool) -> CGImage? {
        guard let image = resources?.image(forResource: name) else { return nil }
        let scale: CGFloat = 4
        let width = Int(image.size.width * scale), height = Int(image.size.height * scale)
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
            let context = NSGraphicsContext(bitmapImageRep: bitmap) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        context.cgContext.scaleBy(x: scale, y: scale)
        image.draw(in: NSRect(origin: .zero, size: image.size))
        NSGraphicsContext.restoreGraphicsState()
        guard let bytes = bitmap.bitmapData else { return nil }
        var alpha = [CGFloat](repeating: 0, count: width * height)
        var peak: CGFloat = 0
        for y in 0..<height { for x in 0..<width {
            let value = CGFloat(bytes[y * bitmap.bytesPerRow + x * 4 + 3]) / 255
            alpha[y * width + x] = value; peak = max(peak, value)
        } }
        guard peak > 0 else { return nil }
        for y in 0..<height {
            let row = (0..<width).filter { alpha[y * width + $0] > 0 }
            for x in 0..<width {
                var value = alpha[y * width + x] / peak
                if fillInterior, let left = row.first, let right = row.last, x > left && x < right { value = 1 }
                let byte = UInt8(min(255, max(0, (value * 255).rounded())))
                let offset = y * bitmap.bytesPerRow + x * 4
                for component in 0..<4 { bytes[offset + component] = byte }
            }
        }
        return bitmap.cgImage
    }
}
