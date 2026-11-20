import Foundation
import AppKit

/// Writes `.icns` files, the icon format app bundles use.
public enum ICNS {
    /// The element types a PNG of each pixel size goes in, smallest first: the slots Apple's
    /// `iconutil` writes, which macOS always reads as PNG. Not `icp4`, `icp5` and `icp6` (16, 32
    /// and 48 pixels): macOS can read what is in those as raw pixels, and the program icons in
    /// FineWine's menu, drawn small from exactly those, came out as coloured noise. For 16 points
    /// macOS scales the 32-pixel picture down.
    static let types: [(size: Int, type: String)] = [
        (32, "ic11"), (64, "ic12"), (128, "ic07"), (256, "ic13"), (256, "ic08"),
        (512, "ic14"), (512, "ic09"), (1024, "ic10")
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

    /// Whether an `.icns` file has pictures in the slots macOS can read as raw pixels (`icp4`,
    /// `icp5`, `icp6`), as the shortcut apps FineWine made before 2026-11-17 do: their icons
    /// draw as coloured noise at small sizes, in FineWine's own menu among other places.
    public static func hasMisreadSlots(at url: URL) -> Bool {
        guard let data = try? Data(contentsOf: url), data.count > 8,
              data.prefix(4) == Data("icns".utf8) else { return false }
        var offset = 8
        while offset + 8 <= data.count {
            let type = String(data: data[offset..<offset + 4], encoding: .ascii) ?? ""
            if ["icp4", "icp5", "icp6"].contains(type) { return true }
            let length = data[offset + 4..<offset + 8].reduce(0) { $0 << 8 | Int($1) }
            guard length >= 8 else { return false }
            offset += length
        }
        return false
    }

    static func be32(_ value: Int) -> [UInt8] {
        [UInt8((value >> 24) & 0xFF), UInt8((value >> 16) & 0xFF), UInt8((value >> 8) & 0xFF), UInt8(value & 0xFF)]
    }

    /// An `.icns` made by scaling one image to each standard size.
    public static func data(from image: NSImage, sizes: [Int] = [32, 64, 128, 256, 512, 1024]) -> Data? {
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

    /// The icon in a file: one a Windows shortcut names (an `.ico`, or a program or library
    /// with icons in it) or a picture chosen by hand (`.icns`, `.png` and whatever else the Mac
    /// reads). `nil` if the file is missing or holds no icon. With `macStyle` it is drawn as a
    /// Mac app icon (`MacIconStyle`).
    public static func data(fromIconFile url: URL, macStyle: Bool = false) -> Data? {
        let programs = ["exe", "dll", "scr", "cpl", "ocx"]
        if programs.contains(url.pathExtension.lowercased()) { return data(fromExecutable: url, macStyle: macStyle) }
        if let picture = try? Data(contentsOf: url), let icon = data(fromICO: picture, macStyle: macStyle) { return icon }
        return data(fromExecutable: url, macStyle: macStyle)
    }

    /// The icon of a Windows executable as `.icns` data, or `nil` if it has no icon.
    public static func data(fromExecutable url: URL, macStyle: Bool = false) -> Data? {
        guard let exe = try? Data(contentsOf: url, options: .mappedIfSafe),
              let ico = PEIcon.icoData(fromExecutable: exe) else { return nil }
        return data(fromICO: ico, macStyle: macStyle)
    }

    /// The sizes of a Mac-style icon, up to the 1024 pixels of a Retina 512-point icon.
    static let macStyleSizes = [32, 64, 128, 256, 512, 1024]

    static func data(fromICO ico: Data, macStyle: Bool = false) -> Data? {
        guard let image = NSImage(data: ico) else { return nil }
        if macStyle {
            var pngs: [Int: Data] = [:]
            for size in macStyleSizes {
                if let png = MacIconStyle.styled(image, pixelSize: size)?.representation(using: .png, properties: [:]) {
                    pngs[size] = png
                }
            }
            if let styled = data(pngsByPixelSize: pngs) { return styled }
        }
        // An .ico holds several sizes; draw from the largest so small sizes are scaled down, not up.
        if let largest = image.representations.max(by: { $0.pixelsWide < $1.pixelsWide }) {
            let single = NSImage(size: NSSize(width: largest.pixelsWide, height: largest.pixelsHigh))
            single.addRepresentation(largest)
            return data(from: single)
        }
        return data(from: image)
    }
}
