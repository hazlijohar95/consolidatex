import AppKit

/// App icons for the panel, drawn once into a 14-point bitmap and kept. The full icon file, with
/// sizes up to 1024 pixels, is let go as soon as the small one exists.
@MainActor
enum AppIcons {
    private static var drawn: [String: NSImage] = [:]
    private static let size = NSSize(width: 14, height: 14)

    static func icon(for bundle: String) -> NSImage {
        if let icon = drawn[bundle] { return icon }
        let icon = NSImage(size: size)
        if let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width) * 2, pixelsHigh: Int(size.height) * 2,
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) {
            bitmap.size = size
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
            NSWorkspace.shared.icon(forFile: bundle).draw(in: NSRect(origin: .zero, size: size))
            NSGraphicsContext.restoreGraphicsState()
            icon.addRepresentation(bitmap)
        }
        drawn[bundle] = icon
        return icon
    }
}
