import XCTest
@testable import FineWinePatcher

/// Exercises the x64-vs-ARM CrossOver detection and the per-variant path table — the pieces the
/// single patcher uses to decide which payload (and which bundle paths) to use.
final class VariantTests: XCTestCase {

    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("fw-variant-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    /// Create an .app with the given CrossOver-relative files (empty files are enough).
    @discardableResult
    private func makeApp(_ name: String, files: [String]) throws -> URL {
        let app = tempDir.appendingPathComponent("\(name).app", isDirectory: true)
        let cxr = app.appendingPathComponent("Contents/SharedSupport/CrossOver", isDirectory: true)
        let fm = FileManager.default
        try fm.createDirectory(at: cxr, withIntermediateDirectories: true)
        for relative in files {
            let url = cxr.appendingPathComponent(relative)
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            fm.createFile(atPath: url.path, contents: Data("x".utf8))
        }
        return app
    }

    private let x64Layout = [
        "lib/wine/x86_64-unix/ntdll.so",
        "lib/wine/x86_64-windows/kernel32.dll",
        "lib/wine/x86_64-windows/ntoskrnl.exe",
        "lib/wine/x86_64-windows/wineboot.exe",
        "lib64/libMoltenVK.dylib",
    ]

    private let armLayout = [
        "lib/wine/aarch64-unix/ntdll.so",
        "lib/wine/x86_64-windows/kernel32.dll",
        "lib/wine/x86_64-windows/ntoskrnl.exe",
        "lib/wine/aarch64-windows/lsass.exe",
        "lib/wine/aarch64-windows/wineboot.exe",
        "lib/aarch64/libMoltenVK.dylib",
    ]

    func testDetectsX64Layout() throws {
        let app = try makeApp("CrossOver", files: x64Layout)
        let info = CrossOverInfo(url: app)
        XCTAssertEqual(info.variant, .x64)
        XCTAssertTrue(info.hasWineModules)
    }

    func testDetectsArmLayout() throws {
        let app = try makeApp("CrossOver ARM Preview", files: armLayout)
        let info = CrossOverInfo(url: app)
        XCTAssertEqual(info.variant, .arm)
        XCTAssertTrue(info.hasWineModules)
    }

    func testPrefersArmWhenBothTreesExist() throws {
        // A CrossOver ARM app also carries the x86_64 tree; the aarch64 marker must win.
        let app = try makeApp("CrossOver ARM Preview", files: armLayout + x64Layout)
        XCTAssertEqual(CrossOverInfo(url: app).variant, .arm)
    }

    func testRejectsUnknownLayout() throws {
        let app = try makeApp("NotCrossOver", files: ["lib/wine/x86_64-unix/ntdll.so"])
        let info = CrossOverInfo(url: app)
        XCTAssertNil(info.variant)
        XCTAssertFalse(info.hasWineModules)
        XCTAssertFalse(info.isExpectedVersion)
    }

    func testX64VersionGating() throws {
        let arm = try makeApp("arm", files: armLayout)
        // ARM is detected structurally; any preview version counts as expected.
        XCTAssertTrue(CrossOverInfo(url: arm).isExpectedVersion)

        let x64 = try makeApp("x64", files: x64Layout)
        // No Info.plist version -> not expected for x64.
        XCTAssertFalse(CrossOverInfo(url: x64).isExpectedVersion)
    }

    func testVariantPathTable() {
        XCTAssertEqual(CrossOverVariant.x64.hostArch, "x86_64")
        XCTAssertEqual(CrossOverVariant.arm.hostArch, "aarch64")

        XCTAssertEqual(CrossOverVariant.x64.hostLibSubpath, "lib64")
        XCTAssertEqual(CrossOverVariant.arm.hostLibSubpath, "lib/aarch64")

        XCTAssertEqual(CrossOverVariant.x64.requiredNtdllRpath, "@loader_path/../../../lib64")
        XCTAssertEqual(CrossOverVariant.arm.requiredNtdllRpath, "@loader_path/../../../lib/aarch64")

        XCTAssertEqual(CrossOverVariant.x64.gptkPrefixSubpath, "lib64/apple_gptk")
        XCTAssertEqual(CrossOverVariant.arm.gptkPrefixSubpath, "lib/apple_gptk")
    }

    func testVariantModulePaths() {
        // x64: unchanged from the original payload layout.
        XCTAssertEqual(CrossOverVariant.x64.modules.first?.crossoverSubpath, "lib/wine/x86_64-unix/ntdll.so")
        XCTAssertTrue(CrossOverVariant.x64.modules.contains { $0.crossoverSubpath == "lib64/libMoltenVK.dylib" })

        // ARM: aarch64 unix ntdll; x86_64 PE for the emulated game process; aarch64-windows
        // host programs (wineboot/lsass); aarch64 MoltenVK.
        let arm = CrossOverVariant.arm.modules
        XCTAssertTrue(arm.contains { $0.crossoverSubpath == "lib/wine/aarch64-unix/ntdll.so" })
        XCTAssertTrue(arm.contains { $0.crossoverSubpath == "lib/wine/x86_64-windows/kernel32.dll" })
        XCTAssertTrue(arm.contains { $0.crossoverSubpath == "lib/wine/aarch64-windows/lsass.exe" })
        XCTAssertTrue(arm.contains { $0.crossoverSubpath == "lib/wine/aarch64-windows/wineboot.exe" })
        XCTAssertTrue(arm.contains { $0.crossoverSubpath == "lib/aarch64/libMoltenVK.dylib" })
        // No x86_64 unix ntdll and no lib64 on the ARM path.
        XCTAssertFalse(arm.contains { $0.crossoverSubpath.contains("lib64") })
        XCTAssertFalse(arm.contains { $0.crossoverSubpath == "lib/wine/x86_64-unix/ntdll.so" })
        // Stock Wine 11.17 ships lsass.exe, so nothing on the ARM path is "new".
        XCTAssertTrue(arm.filter(\.isNew).isEmpty)
    }
}
