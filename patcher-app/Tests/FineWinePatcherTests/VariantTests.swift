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
        "lib/wine/x86_64-unix/winemac.so",
        "lib/wine/x86_64-windows/kernel32.dll",
        "lib/wine/x86_64-windows/ntoskrnl.exe",
        "lib/wine/x86_64-windows/wineboot.exe",
        "lib/wine/x86_64-windows/rundll32.exe",
        "bin/wineserver",
        "CrossOver-Hosted Application/wineserver",
        "lib64/libMoltenVK.dylib",
    ]

    private let armLayout = [
        "lib/wine/aarch64-unix/ntdll.so",
        "lib/wine/aarch64-windows/ntoskrnl.exe",
        "lib/wine/aarch64-windows/rundll32.exe",
    ]

    func testOnlyX64NeedsRosetta() {
        XCTAssertTrue(CrossOverVariant.x64.requiresRosetta)
        XCTAssertFalse(CrossOverVariant.arm.requiresRosetta)
    }

    func testArmUsesItsOwnBottleArchAndPatchedCopy() {
        XCTAssertNil(CrossOverVariant.x64.bottleWineArch)
        XCTAssertEqual(CrossOverVariant.arm.bottleWineArch, "arm64")
        XCTAssertNotEqual(CrossOverVariant.x64.patchedAppName, CrossOverVariant.arm.patchedAppName)
    }

    func testPatchedBundleIdentifiersRouteShortcutsToTheRightCopy() {
        let original = PatcherEngine.originalBundleIdentifier
        let x64 = CrossOverVariant.x64.patchedBundleIdentifier
        let arm = CrossOverVariant.arm.patchedBundleIdentifier
        XCTAssertNotEqual(x64, arm)
        XCTAssertTrue(arm.hasSuffix(".ARM"))
        // The helpers hardcode the ID in a fixed-size slot, so any other length corrupts them.
        XCTAssertEqual(x64.utf8.count, original.utf8.count)
        XCTAssertEqual(arm.utf8.count, original.utf8.count)
    }

    func testAliasFollowsTheBottleArchitecture() throws {
        let write = { (name: String, conf: String) throws -> URL in
            let bottle = self.tempDir.appendingPathComponent(name, isDirectory: true)
            try FileManager.default.createDirectory(at: bottle, withIntermediateDirectories: true)
            try conf.write(to: bottle.appendingPathComponent("cxbottle.conf"), atomically: true, encoding: .utf8)
            return bottle
        }
        XCTAssertEqual(AppAlias.patchedBundleID(forBottle: try write("arm", "\"WineArch\" = \"arm64\"\n")),
                       CrossOverVariant.arm.patchedBundleIdentifier)
        XCTAssertEqual(AppAlias.patchedBundleID(forBottle: try write("x64", "\"WineArch\" = \"win64\"\n")),
                       CrossOverVariant.x64.patchedBundleIdentifier)
    }

    func testD3DMetalIsOfferedOnlyOnX64() {
        XCTAssertTrue(BottleBackend.available(for: .x64).contains(.d3dmetal))
        XCTAssertFalse(BottleBackend.available(for: .arm).contains(.d3dmetal))
        XCTAssertTrue(BottleBackend.available(for: .arm).contains(.dxmt))
    }

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

        // ARM: the ARM64 PE modules an arm64 bottle loads, and nothing else.
        let arm = CrossOverVariant.arm.modules.map(\.crossoverSubpath)
        XCTAssertEqual(arm.sorted(), [
            "lib/wine/aarch64-windows/ntoskrnl.exe",
            "lib/wine/aarch64-windows/rundll32.exe",
        ])
        // Upstream's ntdll.so and wineserver can't run inside CrossOver ARM (protocol 961 vs 1809).
        XCTAssertFalse(arm.contains { $0.contains("ntdll") || $0.contains("wineserver") })
        XCTAssertFalse(arm.contains { $0.contains("x86_64-windows") })
        XCTAssertTrue(CrossOverVariant.arm.modules.filter(\.isNew).isEmpty)
    }
}
