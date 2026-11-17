import AppKit
import Foundation

/// Draws a Windows icon as a Mac app icon is drawn: on Apple's icon grid, an 824-point rounded
/// square in a 1024-point canvas with its shadow below, so that it sits in the Dock, Launchpad
/// and Finder the size and shape of the Mac apps next to it.
///
/// - An icon that is a square picture already (game art, or a tile with rounded corners of its
///   own) fills the rounded square.
/// - Any other shape stands on a light plate, scaled from its visible part rather than from the
///   empty margin around it.
/// - An icon of 48 pixels or less is scaled up without smoothing, so it stays crisp.
///
/// The runtime's Mac driver draws a running program's Dock icon the same way
/// (`patches/runtime/0030`, `finewine_mac_style_icon` in `cocoa_app.m`); the two must match, so
/// a shortcut and the program it starts look alike in the Dock.
public enum MacIconStyle {
    /// The canvas, the rounded square in it, and the rounded square's corner radius, in points.
    static let canvas: CGFloat = 1024
    static let plateInset: CGFloat = 100
    static let cornerRadius: CGFloat = 185.4
    /// How far a shape on the plate stays from the plate's edges.
    static let contentInset: CGFloat = 112

    /// How an icon is placed.
    public enum Placement: Equatable {
        /// Fills the rounded square.
        case tile
        /// Stands on the light plate.
        case onPlate
    }

    /// Where the visible pixels of an image are, as a fraction of its size (origin at the top
    /// left), and how much of that rectangle they cover.
    static func visiblePart(of image: CGImage) -> (rect: CGRect, coverage: Double) {
        let width = image.width, height = image.height
        guard width > 0, height > 0 else { return (CGRect(x: 0, y: 0, width: 1, height: 1), 0) }
        var alpha = [UInt8](repeating: 0, count: width * height)
        let drawn: Bool = alpha.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height,
                                          bitsPerComponent: 8, bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(),
                                          bitmapInfo: CGImageAlphaInfo.alphaOnly.rawValue) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return (CGRect(x: 0, y: 0, width: 1, height: 1), 0) }
        var left = width, right = -1, top = height, bottom = -1
        for y in 0..<height {
            for x in 0..<width where alpha[y * width + x] > 24 {
                left = min(left, x); right = max(right, x)
                top = min(top, y); bottom = max(bottom, y)
            }
        }
        guard right >= left, bottom >= top else { return (CGRect(x: 0, y: 0, width: 1, height: 1), 0) }
        var opaque = 0
        for y in top...bottom {
            for x in left...right where alpha[y * width + x] > 200 { opaque += 1 }
        }
        let area = (right - left + 1) * (bottom - top + 1)
        return (CGRect(x: Double(left) / Double(width), y: Double(top) / Double(height),
                       width: Double(right - left + 1) / Double(width), height: Double(bottom - top + 1) / Double(height)),
                Double(opaque) / Double(area))
    }

    /// Whether an icon fills the rounded square or stands on the plate.
    public static func placement(of image: CGImage) -> Placement {
        let (part, coverage) = visiblePart(of: image)
        let aspect = (part.width * Double(image.width)) / (part.height * Double(image.height))
        return coverage >= 0.9 && aspect > 0.9 && aspect < 1.11 ? .tile : .onPlate
    }

    /// The largest bitmap in an image, which decides placement and sharpness.
    static func largestBitmap(of image: NSImage) -> CGImage? {
        let reps = image.representations.sorted { $0.pixelsWide > $1.pixelsWide }
        for rep in reps {
            if let bitmap = rep as? NSBitmapImageRep, let cg = bitmap.cgImage { return cg }
        }
        var rect = NSRect(origin: .zero, size: image.size)
        return image.cgImage(forProposedRect: &rect, context: nil, hints: nil)
    }

    /// The icon drawn as a Mac app icon, `pixelSize` pixels square. `nil` if it cannot be drawn.
    public static func styled(_ image: NSImage, pixelSize: Int) -> NSBitmapImageRep? {
        guard let largest = largestBitmap(of: image),
              let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixelSize, pixelsHigh: pixelSize,
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .calibratedRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
        rep.size = NSSize(width: pixelSize, height: pixelSize)
        let s = CGFloat(pixelSize) / canvas
        let (part, coverage) = visiblePart(of: largest)
        let size = image.size
        let aspect = (part.width * size.width) / (part.height * size.height)
        let tile = coverage >= 0.9 && aspect > 0.9 && aspect < 1.11
        let crisp = max(largest.width, largest.height) <= 48
        var from = NSRect(x: part.minX * size.width, y: (1 - part.minY - part.height) * size.height,
                          width: part.width * size.width, height: part.height * size.height)
        if !tile {
            let side = max(from.width, from.height)
            from = NSRect(x: from.midX - side / 2, y: from.midY - side / 2, width: side, height: side)
        }
        let plate = NSRect(x: plateInset * s, y: plateInset * s, width: (canvas - 2 * plateInset) * s,
                           height: (canvas - 2 * plateInset) * s)
        let path = NSBezierPath(roundedRect: plate, xRadius: cornerRadius * s, yRadius: cornerRadius * s)
        let interpolation: NSImageInterpolation = crisp ? .none : .high
        let hints: [NSImageRep.HintKey: Any] = [.interpolation: NSNumber(value: interpolation.rawValue)]

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        context.imageInterpolation = interpolation

        // the rounded square and its shadow
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor(calibratedWhite: 0, alpha: 0.3)
        shadow.shadowOffset = NSSize(width: 0, height: -10 * s)
        shadow.shadowBlurRadius = 22 * s
        shadow.set()
        NSColor.white.setFill()
        path.fill()
        NSGraphicsContext.restoreGraphicsState()

        NSGraphicsContext.saveGraphicsState()
        path.addClip()
        if tile {
            image.draw(in: plate, from: from, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: hints)
        } else {
            NSGradient(starting: NSColor(calibratedWhite: 1, alpha: 1), ending: NSColor(calibratedWhite: 0.9, alpha: 1))?
                .draw(in: path, angle: -90)
            image.draw(in: plate.insetBy(dx: contentInset * s, dy: contentInset * s), from: from,
                       operation: .sourceOver, fraction: 1, respectFlipped: true, hints: hints)
        }
        NSGraphicsContext.restoreGraphicsState()

        // a hairline edge, as Mac icons have, so a white plate holds against a light background
        NSColor(calibratedWhite: 0, alpha: 0.1).setStroke()
        path.lineWidth = max(1, 2 * s)
        path.stroke()

        NSGraphicsContext.restoreGraphicsState()
        return rep
    }
}
