import XCTest
import AppKit
@testable import FineWineCore

final class PEIconTests: XCTestCase {
    private func u16(_ d: Data, _ o: Int) -> Int { Int(d[o]) | Int(d[o + 1]) << 8 }
    private func u32(_ d: Data, _ o: Int) -> Int { u16(d, o) | u16(d, o + 2) << 16 }

    func testExtractsAnIconGroupAsAnIcoFile() throws {
        let small: [UInt8] = Array(repeating: 0xAA, count: 40)
        let large: [UInt8] = Array(repeating: 0xBB, count: 100)
        let exe = PEBuilder.make(images: [(16, 16, small), (48, 48, large)])
        let ico = try XCTUnwrap(PEIcon.icoData(fromExecutable: exe))

        XCTAssertEqual(u16(ico, 0), 0)
        XCTAssertEqual(u16(ico, 2), 1, "type 1 is an icon")
        XCTAssertEqual(u16(ico, 4), 2)
        // First directory entry: 16×16, 40 bytes, right after the two entries.
        XCTAssertEqual(ico[6], 16)
        XCTAssertEqual(u32(ico, 6 + 8), 40)
        XCTAssertEqual(u32(ico, 6 + 12), 6 + 2 * 16)
        // Second: 48×48, 100 bytes, after the first image.
        XCTAssertEqual(ico[22], 48)
        XCTAssertEqual(u32(ico, 22 + 8), 100)
        XCTAssertEqual(u32(ico, 22 + 12), 6 + 2 * 16 + 40)
        XCTAssertEqual(Array(ico.suffix(140)), small + large)
    }

    func testWorksForPE32AsWell() {
        let exe = PEBuilder.make(images: [(32, 32, [1, 2, 3, 4])], pe32Plus: false)
        XCTAssertEqual(PEIcon.icoData(fromExecutable: exe)?.suffix(4), Data([1, 2, 3, 4]))
    }

    func testExecutablesWithoutResourcesHaveNoIcon() {
        XCTAssertNil(PEIcon.icoData(fromExecutable: PEBuilder.make(images: [(16, 16, [1])], includeResources: false)))
    }

    func testRejectsNonExecutables() {
        XCTAssertNil(PEIcon.icoData(fromExecutable: Data()))
        XCTAssertNil(PEIcon.icoData(fromExecutable: Data("#!/bin/sh\necho hi\n".utf8)))
        XCTAssertNil(PEIcon.icoData(fromExecutable: Data(repeating: 0x4D, count: 4096)))
    }

    func testTruncatedExecutablesNeverCrash() {
        let exe = PEBuilder.make(images: [(16, 16, Array(repeating: 7, count: 64))])
        for length in stride(from: 0, to: exe.count, by: 7) {
            _ = PEIcon.icoData(fromExecutable: exe.prefix(length))
        }
    }

    func testARealIconSurvivesTheRoundTrip() throws {
        // A PNG-compressed icon image, as modern executables carry for large sizes.
        let image = NSImage(size: NSSize(width: 64, height: 64), flipped: false) { rect in
            NSColor.systemRed.setFill()
            rect.fill()
            return true
        }
        let png = try XCTUnwrap(ICNS.png(from: image, pixelSize: 64))
        let exe = PEBuilder.make(images: [(64, 64, [UInt8](png))])
        let ico = try XCTUnwrap(PEIcon.icoData(fromExecutable: exe))
        let decoded = try XCTUnwrap(NSImage(data: ico))
        XCTAssertEqual(decoded.representations.first?.pixelsWide, 64)

        let file = FileManager.default.temporaryDirectory.appendingPathComponent("fw-icon-\(UUID().uuidString).exe")
        try exe.write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let icns = try XCTUnwrap(ICNS.data(fromExecutable: file))
        XCTAssertEqual(String(decoding: icns.prefix(4), as: UTF8.self), "icns")
        XCTAssertNotNil(NSImage(data: icns))
    }
}

final class ICNSTests: XCTestCase {
    func testLayout() throws {
        let icns = try XCTUnwrap(ICNS.data(pngsByPixelSize: [256: Data([1, 2, 3]), 32: Data([9])]))
        // Header, then elements smallest first: icp5 (1 byte) and ic08 (3 bytes).
        XCTAssertEqual(Array(icns), Array("icns".utf8) + [0, 0, 0, 28]
                       + Array("icp5".utf8) + [0, 0, 0, 9] + [9]
                       + Array("ic08".utf8) + [0, 0, 0, 11] + [1, 2, 3])
    }

    func testUnsupportedSizesAreLeftOut() {
        XCTAssertNil(ICNS.data(pngsByPixelSize: [:]))
        XCTAssertNil(ICNS.data(pngsByPixelSize: [48: Data([1])]))
    }

    func testPNGHasTheRequestedPixelSize() throws {
        let image = NSImage(size: NSSize(width: 10, height: 10), flipped: false) { rect in
            NSColor.blue.setFill(); rect.fill(); return true
        }
        let png = try XCTUnwrap(ICNS.png(from: image, pixelSize: 128))
        XCTAssertEqual(Array(png.prefix(4)), [0x89, 0x50, 0x4E, 0x47])
        let rep = try XCTUnwrap(NSBitmapImageRep(data: png))
        XCTAssertEqual(rep.pixelsWide, 128)
        XCTAssertEqual(rep.pixelsHigh, 128)
    }

    func testImageBecomesAMultiSizeIcon() throws {
        let image = NSImage(size: NSSize(width: 256, height: 256), flipped: false) { rect in
            NSColor.green.setFill(); rect.fill(); return true
        }
        let icns = try XCTUnwrap(ICNS.data(from: image, sizes: [16, 128]))
        let text = String(data: icns, encoding: .isoLatin1)!
        XCTAssertTrue(text.contains("icp4"))
        XCTAssertTrue(text.contains("ic07"))
        XCTAssertFalse(text.contains("ic09"))
    }
}
