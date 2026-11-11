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
        "lib/wine/x86_64-windows/dwmapi.dll",
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

    /// A seed Menu Helper must not depend on a bundle ID or signature, so it holds a script, and that
    /// script must run the command CrossOver writes into each launcher.
    func testMenuHelperSeedsRunTheirLauncherCommand() throws {
        try checkMenuHelperSeed("Menu Helper", variant: .x64)
        try checkMenuHelperSeed("Menu Helper arm64", variant: .arm)
    }

    private func checkMenuHelperSeed(_ name: String, variant: CrossOverVariant) throws {
        let fm = FileManager.default
        let root = tempDir.appendingPathComponent(name, isDirectory: true)
        let app = root.appendingPathComponent("Patched.app", isDirectory: true)
        let resources = app.appendingPathComponent("Contents/Resources", isDirectory: true)
        try fm.createDirectory(at: resources, withIntermediateDirectories: true)
        let plist: [String: Any] = ["CFBundleIdentifier": "com.codeweavers.CrossOver"]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            .write(to: app.appendingPathComponent("Contents/Info.plist"))

        let seed = root.appendingPathComponent("seed", isDirectory: true)
        let macOS = seed.appendingPathComponent("Contents/MacOS", isDirectory: true)
        try fm.createDirectory(at: macOS, withIntermediateDirectories: true)
        fm.createFile(atPath: macOS.appendingPathComponent(name).path, contents: Data("stock\n".utf8))
        let archive = resources.appendingPathComponent("\(name).cpbz2")
        try shell("cd '\(seed.path)' && find . | cpio -o -H odc 2>/dev/null | bzip2 -c > '\(archive.path)'")

        try PatcherEngine.patchBundleIdentifier(in: app, variant: variant)

        let launcher = root.appendingPathComponent("Launcher (Test).app", isDirectory: true)
        let contents = launcher.appendingPathComponent("Contents", isDirectory: true)
        try fm.createDirectory(at: contents, withIntermediateDirectories: true)
        try shell("cd '\(contents.path)/..' && bzip2 -dc '\(archive.path)' | cpio -idm 2>/dev/null")
        let helper = contents.appendingPathComponent("MacOS/\(name)")
        XCTAssertTrue(fm.isExecutableFile(atPath: helper.path))

        let marker = root.appendingPathComponent("launched")
        let command = root.appendingPathComponent("Bottle Dir/Game^5E3A.lnk")
        try fm.createDirectory(at: command.deletingLastPathComponent(), withIntermediateDirectories: true)
        fm.createFile(atPath: command.path, contents: Data("#!/bin/sh\ntouch '\(marker.path)'\n".utf8))
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: command.path)
        let launcherPlist: [String: Any] = ["CrossOverHelperCommand": "\"\(command.path)\""]
        try PropertyListSerialization.data(fromPropertyList: launcherPlist, format: .xml, options: 0)
            .write(to: contents.appendingPathComponent("Info.plist"))

        try shell("'\(helper.path)'")
        XCTAssertTrue(fm.fileExists(atPath: marker.path), name)
    }

    func testMenuHelperScriptMatchesTheRepoScript() throws {
        let repoScript = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("scripts/lib/menu-helper.sh")
        XCTAssertEqual(try String(contentsOf: repoScript, encoding: .utf8), PatcherEngine.menuHelperScript)
    }

    private func shell(_ command: String) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command]
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, command)
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

        // ARM: the ARM64 PE modules an arm64 bottle loads, plus the launcher-alpha library that
        // CrossOver ARM's own winemac.so is made to load. Nothing of CrossOver's is replaced
        // except those PE modules.
        let arm = CrossOverVariant.arm.modules.map(\.crossoverSubpath)
        XCTAssertEqual(arm.sorted(), [
            "lib/wine/aarch64-unix/fwalpha.dylib",
            "lib/wine/aarch64-windows/ntoskrnl.exe",
            "lib/wine/aarch64-windows/rundll32.exe",
            "lib/wine/aarch64-windows/wdfldr.sys",
        ])
        // Upstream's ntdll.so and wineserver can't run inside CrossOver ARM.
        XCTAssertFalse(arm.contains { $0.contains("ntdll") || $0.contains("wineserver") || $0.contains("winemac") })
        XCTAssertFalse(arm.contains { $0.contains("x86_64-windows") })
        XCTAssertEqual(CrossOverVariant.arm.modules.filter(\.isNew).map(\.crossoverSubpath).sorted(),
                       ["lib/wine/aarch64-unix/fwalpha.dylib", "lib/wine/aarch64-windows/wdfldr.sys"])
    }
}
