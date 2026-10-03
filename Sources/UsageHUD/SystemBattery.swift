import Cocoa

// Read the installed system artwork through AppKit. Nothing is copied into the bundle.
// Cache the masks once; the interior of the outline is filled without changing its outer edge.
enum SystemBattery {
    private static let resources = Bundle(path: "/System/Library/CoreServices/ControlCenter.app")
    static let body = mask("battery-outline", fillInterior: true)
    static let cap = mask("battery-cap", fillInterior: false)

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
