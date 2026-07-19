// make-appicon.swift — render a source PNG into the macOS .iconset size set.
// Dependency-free (ImageIO / Core Graphics only). Centers the artwork on a
// transparent square canvas with a small margin, one high-quality render per size.
//
// Usage:  swift make-appicon.swift <source.png> <out.iconset-dir> [marginFraction]
import Foundation
import ImageIO
import CoreGraphics
import UniformTypeIdentifiers

let args = CommandLine.arguments
guard args.count >= 3 else {
    FileHandle.standardError.write(Data("usage: make-appicon.swift <source.png> <out.iconset> [margin]\n".utf8))
    exit(2)
}
let srcPath = args[1]
let outDir = args[2]
let margin = args.count >= 4 ? (Double(args[3]) ?? 0.06) : 0.06

guard let imgSrc = CGImageSourceCreateWithURL(URL(fileURLWithPath: srcPath) as CFURL, nil),
      let cg = CGImageSourceCreateImageAtIndex(imgSrc, 0, nil) else {
    FileHandle.standardError.write(Data("cannot load \(srcPath)\n".utf8))
    exit(1)
}
let srcW = CGFloat(cg.width), srcH = CGFloat(cg.height)

try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)

func writePNG(_ image: CGImage, to path: String) -> Bool {
    guard let dest = CGImageDestinationCreateWithURL(
        URL(fileURLWithPath: path) as CFURL, UTType.png.identifier as CFString, 1, nil) else { return false }
    CGImageDestinationAddImage(dest, image, nil)
    return CGImageDestinationFinalize(dest)
}

func render(_ size: Int, to path: String) -> Bool {
    let s = CGFloat(size)
    guard let ctx = CGContext(
        data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
    ctx.interpolationQuality = .high
    ctx.clear(CGRect(x: 0, y: 0, width: s, height: s))
    let avail = s * (1 - 2 * CGFloat(margin))
    let scale = min(avail / srcW, avail / srcH)
    let w = srcW * scale, h = srcH * scale
    ctx.draw(cg, in: CGRect(x: (s - w) / 2, y: (s - h) / 2, width: w, height: h))
    guard let out = ctx.makeImage() else { return false }
    return writePNG(out, to: path)
}

let sizes: [(String, Int)] = [
    ("icon_16x16.png", 16), ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32), ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128), ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256), ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512), ("icon_512x512@2x.png", 1024),
]
for (name, px) in sizes {
    guard render(px, to: "\(outDir)/\(name)") else {
        FileHandle.standardError.write(Data("failed to render \(name)\n".utf8))
        exit(1)
    }
}
print("wrote \(sizes.count) icons to \(outDir) (source \(Int(srcW))x\(Int(srcH)), margin \(margin))")
