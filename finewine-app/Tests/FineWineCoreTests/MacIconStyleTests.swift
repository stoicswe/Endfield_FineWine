import AppKit
import XCTest
@testable import FineWineCore

final class MacIconStyleTests: XCTestCase {
    /// A square image `side` pixels wide, drawn by `paint` into an RGBA bitmap.
    private func image(side: Int, _ paint: (CGContext) -> Void) -> NSImage {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side, bitsPerSample: 8,
                                   samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                   bytesPerRow: 0, bitsPerPixel: 0)!
        let context = NSGraphicsContext(bitmapImageRep: rep)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        paint(context.cgContext)
        NSGraphicsContext.restoreGraphicsState()
        let image = NSImage(size: NSSize(width: side, height: side))
        image.addRepresentation(rep)
        return image
    }

    private var squareArt: NSImage {
        image(side: 256) { $0.setFillColor(NSColor.systemBlue.cgColor); $0.fill(CGRect(x: 0, y: 0, width: 256, height: 256)) }
    }
    private var roundLogo: NSImage {
        image(side: 256) { $0.setFillColor(NSColor.systemRed.cgColor); $0.fillEllipse(in: CGRect(x: 40, y: 40, width: 176, height: 176)) }
    }

    private func alpha(_ rep: NSBitmapImageRep, _ x: Int, _ y: Int) -> CGFloat {
        rep.colorAt(x: x, y: y)?.alphaComponent ?? 0
    }

    func testPlacement() throws {
        XCTAssertEqual(MacIconStyle.placement(of: try XCTUnwrap(MacIconStyle.largestBitmap(of: squareArt))), .tile)
        XCTAssertEqual(MacIconStyle.placement(of: try XCTUnwrap(MacIconStyle.largestBitmap(of: roundLogo))), .onPlate)
        // a picture with rounded corners of its own is still a tile
        let rounded = image(side: 256) {
            $0.setFillColor(NSColor.systemGreen.cgColor)
            $0.addPath(CGPath(roundedRect: CGRect(x: 0, y: 0, width: 256, height: 256), cornerWidth: 40, cornerHeight: 40, transform: nil))
            $0.fillPath()
        }
        XCTAssertEqual(MacIconStyle.placement(of: try XCTUnwrap(MacIconStyle.largestBitmap(of: rounded))), .tile)
    }

    func testVisiblePartIgnoresTheEmptyMargin() throws {
        let (part, coverage) = MacIconStyle.visiblePart(of: try XCTUnwrap(MacIconStyle.largestBitmap(of: roundLogo)))
        XCTAssertEqual(part.minX, 40.0 / 256, accuracy: 0.01)
        XCTAssertEqual(part.width, 176.0 / 256, accuracy: 0.01)
        XCTAssertEqual(coverage, Double.pi / 4, accuracy: 0.03)   // a circle in its square
    }

    func testStyledIconIsOnTheMacIconGrid() throws {
        for source in [squareArt, roundLogo] {
            let rep = try XCTUnwrap(MacIconStyle.styled(source, pixelSize: 1024))
            XCTAssertEqual(rep.pixelsWide, 1024)
            // outside the rounded square: nothing but shadow; the canvas corners are clear
            XCTAssertLessThan(alpha(rep, 5, 5), 0.02)
            XCTAssertLessThan(alpha(rep, 1018, 5), 0.02)
            // the rounded square's own corner is cut: (102, 102) is outside the curve
            XCTAssertLessThan(alpha(rep, 104, 104), 0.5)
            // the middle of the rounded square is solid
            XCTAssertEqual(alpha(rep, 512, 512), 1, accuracy: 0.01)
            XCTAssertEqual(alpha(rep, 512, 130), 1, accuracy: 0.01)
        }
        // the round logo stands on a light plate: the plate shows between its edge and the shape
        let plate = try XCTUnwrap(MacIconStyle.styled(roundLogo, pixelSize: 1024))
        let colour = try XCTUnwrap(plate.colorAt(x: 512, y: 130)?.usingColorSpace(.deviceRGB))
        XCTAssertGreaterThan(colour.redComponent, 0.85)
        XCTAssertGreaterThan(colour.greenComponent, 0.85)
        // the square art fills it to the edge
        let tile = try XCTUnwrap(MacIconStyle.styled(squareArt, pixelSize: 1024))
        let edge = try XCTUnwrap(tile.colorAt(x: 512, y: 130)?.usingColorSpace(.deviceRGB))
        XCTAssertGreaterThan(edge.blueComponent, edge.redComponent + 0.3)
    }

    func testICNSWithMacStyleHasEverySizeUpTo1024() throws {
        let png = try XCTUnwrap(ICNS.png(from: roundLogo, pixelSize: 256))
        // a one-image .ico holding a PNG, as Windows icons of 256 pixels are stored
        var ico = Data([0, 0, 1, 0, 1, 0, 0, 0, 0, 0, 1, 0, 32, 0])
        ico.append(contentsOf: [UInt8(png.count & 0xFF), UInt8((png.count >> 8) & 0xFF), UInt8((png.count >> 16) & 0xFF), 0])
        ico.append(contentsOf: [22, 0, 0, 0])
        ico.append(png)
        let styled = try XCTUnwrap(ICNS.data(fromICO: ico, macStyle: true))
        XCTAssertNotNil(styled.range(of: Data("ic10".utf8)), "1024-pixel slot")
        XCTAssertNotNil(styled.range(of: Data("ic11".utf8)), "32-pixel slot")
        let plain = try XCTUnwrap(ICNS.data(fromICO: ico, macStyle: false))
        XCTAssertNotEqual(plain, styled, "macStyle: false leaves the picture as it is")
    }

    func testSettingTurnsTheRuntimeStyleOff() throws {
        var settings = PrefixSettings()
        XCTAssertTrue(settings.macStyleIcons)
        XCTAssertFalse(settings.environmentVariables().contains { $0.0 == "FINEWINE_MAC_ICONS" })
        settings.macStyleIcons = false
        XCTAssertTrue(settings.environmentVariables().contains { $0.0 == "FINEWINE_MAC_ICONS" && $0.1 == "0" })
        XCTAssertTrue(try JSONDecoder().decode(PrefixSettings.self, from: Data("{}".utf8)).macStyleIcons)
    }

    func testAProgramsIconComesFromTheChosenFileAndTheShortcutCarriesIt() throws {
        let sandbox = Sandbox()
        let service = PrefixService(paths: sandbox.paths, runner: RecordingRunner())
        XCTAssertTrue(sandbox.paths.shortcuts.path.hasPrefix(sandbox.root.path))
        var prefix = try service.prefixes.create(name: "Icons", runtimeID: "none", profile: nil)
        sandbox.write("not a program", to: prefix.directory.appendingPathComponent("drive_c/Game/game.exe"))
        let picture = sandbox.root.appendingPathComponent("art/logo.png")
        try FileManager.default.createDirectory(at: picture.deletingLastPathComponent(), withIntermediateDirectories: true)
        try XCTUnwrap(ICNS.png(from: roundLogo, pixelSize: 256)).write(to: picture)

        var program = Program(name: "Game", windowsPath: #"C:\Game\game.exe"#)
        // no icon in the executable and none chosen
        XCTAssertNil(PrefixService.iconData(for: program, in: prefix))
        // a picture from anywhere on the Mac
        program.iconPath = WindowsPath.windowsPath(for: picture, inPrefix: prefix.directory)
        let icon = try XCTUnwrap(PrefixService.iconData(for: program, in: prefix))
        XCTAssertEqual(String(decoding: icon.prefix(4), as: UTF8.self), "icns")
        // a chosen file that has gone falls back to the executable
        var gone = program
        gone.iconPath = #"C:\Game\missing.ico"#
        XCTAssertNil(PrefixService.iconData(for: gone, in: prefix))

        // the shortcut app is made with the icon, and made again when the icon is taken away
        prefix.metadata.programs = [program]
        try service.prefixes.save(prefix)
        prefix = try service.createShortcut(for: program.id, in: prefix)
        let app = try XCTUnwrap(prefix.metadata.programs[0].shortcutPath)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: app + "/Contents/Resources/AppIcon.icns")), icon)
        prefix.metadata.programs[0].iconPath = nil
        prefix = try service.createShortcut(for: program.id, in: prefix)
        XCTAssertEqual(prefix.metadata.programs[0].shortcutPath, app)
        XCTAssertFalse(FileManager.default.fileExists(atPath: app + "/Contents/Resources/AppIcon.icns"))
    }
}
