// make-icns.swift — build a Mac .icns from one appearance of the Icon Composer exports.
//
// Usage: swift make-icns.swift <Icon Exports folder> <variant> <out.icns>
//   variant is the appearance in the export names: Default, Dark, ClearLight, ClearDark,
//   TintedLight or TintedDark.
//
// The exports fill their whole canvas, as iOS icons do. Mac icons leave a margin around the
// shape (it spans 824 of 1024 points), so each image is scaled into that area; without this the
// icon would look oversized next to others in the Dock.
import AppKit

let args = CommandLine.arguments
guard args.count == 4 else {
    FileHandle.standardError.write(Data("usage: make-icns.swift <exports> <variant> <out.icns>\n".utf8))
    exit(2)
}
let exports = URL(fileURLWithPath: args[1], isDirectory: true)
let variant = args[2]
let output = URL(fileURLWithPath: args[3])

// icns element type for each pixel size, with the export that supplies it.
let slots: [(type: String, pixels: Int, file: String)] = [
    ("icp4", 16, "16@1x"), ("icp5", 32, "32@1x"), ("icp6", 64, "32@2x"), ("ic07", 128, "128@1x"),
    ("ic08", 256, "256@1x"), ("ic09", 512, "512@1x"), ("ic10", 1024, "1024@1x"),
    ("ic11", 32, "16@2x"), ("ic12", 64, "32@2x"), ("ic13", 256, "128@2x"), ("ic14", 512, "256@2x")
]

func be32(_ v: Int) -> Data { Data([UInt8(v >> 24 & 0xFF), UInt8(v >> 16 & 0xFF), UInt8(v >> 8 & 0xFF), UInt8(v & 0xFF)]) }

var body = Data()
for slot in slots {
    let url = exports.appendingPathComponent("Icon-iOS-\(variant)-\(slot.file).png")
    guard let source = NSImage(contentsOf: url) else {
        FileHandle.standardError.write(Data("missing export: \(url.lastPathComponent)\n".utf8))
        exit(1)
    }
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: slot.pixels, pixelsHigh: slot.pixels,
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: slot.pixels, height: slot.pixels)
    NSGraphicsContext.saveGraphicsState()
    let context = NSGraphicsContext(bitmapImageRep: rep)!
    context.imageInterpolation = .high
    NSGraphicsContext.current = context
    let side = CGFloat(slot.pixels) * 824 / 1024
    let inset = (CGFloat(slot.pixels) - side) / 2
    source.draw(in: NSRect(x: inset, y: inset, width: side, height: side), from: .zero, operation: .copy, fraction: 1)
    NSGraphicsContext.restoreGraphicsState()
    let png = rep.representation(using: .png, properties: [:])!
    body.append(slot.type.data(using: .ascii)!)
    body.append(be32(png.count + 8))
    body.append(png)
}
var icns = Data("icns".utf8)
icns.append(be32(body.count + 8))
icns.append(body)
try icns.write(to: output)
