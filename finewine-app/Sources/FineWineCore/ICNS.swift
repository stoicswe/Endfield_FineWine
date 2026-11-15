import Foundation
import AppKit

/// Writes `.icns` files, the icon format app bundles use.
public enum ICNS {
    /// The element type for a PNG of each pixel size.
    static let types: [(size: Int, type: String)] = [
        (16, "icp4"), (32, "icp5"), (64, "icp6"), (128, "ic07"), (256, "ic08"), (512, "ic09"), (1024, "ic10")
    ]

    /// An `.icns` file holding the given PNGs. Sizes the format has no slot for are left out;
    /// returns `nil` when nothing usable was given.
    public static func data(pngsByPixelSize pngs: [Int: Data]) -> Data? {
        var body = Data()
        for (size, type) in types {
            guard let png = pngs[size] else { continue }
            body.append(type.data(using: .ascii)!)
            body.append(contentsOf: be32(png.count + 8))
            body.append(png)
        }
        guard !body.isEmpty else { return nil }
        var out = Data("icns".utf8)
        out.append(contentsOf: be32(body.count + 8))
        out.append(body)
        return out
    }

    static func be32(_ value: Int) -> [UInt8] {
        [UInt8((value >> 24) & 0xFF), UInt8((value >> 16) & 0xFF), UInt8((value >> 8) & 0xFF), UInt8(value & 0xFF)]
    }

    /// An `.icns` made by scaling one image to each standard size.
    public static func data(from image: NSImage, sizes: [Int] = [16, 32, 64, 128, 256, 512]) -> Data? {
        var pngs: [Int: Data] = [:]
        for size in sizes {
            if let png = png(from: image, pixelSize: size) { pngs[size] = png }
        }
        return data(pngsByPixelSize: pngs)
    }

    /// The image drawn into a square bitmap of exactly `pixelSize` pixels, as PNG.
    public static func png(from image: NSImage, pixelSize: Int) -> Data? {
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: pixelSize, pixelsHigh: pixelSize, bitsPerSample: 8,
            samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        rep.size = NSSize(width: pixelSize, height: pixelSize)
        guard let context = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        context.imageInterpolation = .high
        image.draw(in: NSRect(x: 0, y: 0, width: pixelSize, height: pixelSize),
                   from: .zero, operation: .copy, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .png, properties: [:])
    }

    /// The icon of a Windows executable as `.icns` data, or `nil` if it has no icon.
    public static func data(fromExecutable url: URL) -> Data? {
        guard let exe = try? Data(contentsOf: url, options: .mappedIfSafe),
              let ico = PEIcon.icoData(fromExecutable: exe),
              let image = NSImage(data: ico) else { return nil }
        // An .ico holds several sizes; draw from the largest so small sizes are scaled down, not up.
        if let largest = image.representations.max(by: { $0.pixelsWide < $1.pixelsWide }) {
            let single = NSImage(size: NSSize(width: largest.pixelsWide, height: largest.pixelsHigh))
            single.addRepresentation(largest)
            return data(from: single)
        }
        return data(from: image)
    }
}
