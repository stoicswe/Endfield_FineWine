import XCTest
@testable import FineWinePatcher

/// The CN Gryphline launcher crash: a copy patched with GPTK 4.0b3's framework over CrossOver
/// 26.3's D3DMetal 3.0 DLLs. These build that layout from empty stand-ins.
final class D3DMetalRepairTests: XCTestCase {

    private var tempDir: URL!
    private let fm = FileManager.default

    override func setUpWithError() throws {
        tempDir = fm.temporaryDirectory.appendingPathComponent("fw-d3dm-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? fm.removeItem(at: tempDir)
    }

    private func write(_ text: String, to url: URL) throws {
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    /// A D3DMetal `external` folder: framework binary contents `binary`, version `version`.
    private func makeExternal(_ url: URL, version: String, binary: String) throws {
        try write(binary, to: url.appendingPathComponent("D3DMetal.framework/Versions/A/D3DMetal"))
        try fm.createDirectory(at: url.appendingPathComponent("D3DMetal.framework/Resources"), withIntermediateDirectories: true)
        try PropertyListSerialization.data(fromPropertyList: ["CFBundleShortVersionString": version], format: .xml, options: 0)
            .write(to: url.appendingPathComponent("D3DMetal.framework/Resources/Info.plist"))
        try write("lib \(binary)", to: url.appendingPathComponent("libd3dshared.dylib"))
    }

    /// A glue `wine` folder; the 4.x kind embeds `jump_table.h` in its d3d11.dll.
    private func makeGlue(_ url: URL, jumpTable: Bool) throws {
        let marker = jumpTable ? "D3D4Mac/shared/jump_table.h" : "D3DMetalDLLsBase-17.12"
        for dll in ["d3d11.dll", "dxgi.dll"] {
            try write("\(dll) \(marker)", to: url.appendingPathComponent("x86_64-windows/\(dll)"))
        }
        try fm.createDirectory(at: url.appendingPathComponent("x86_64-unix"), withIntermediateDirectories: true)
        try fm.createSymbolicLink(atPath: url.appendingPathComponent("x86_64-unix/d3d11.so").path,
                                  withDestinationPath: "../../external/libd3dshared.dylib")
    }

    /// A patched x64 CrossOver with D3DMetal 4.0b3 over CrossOver's 3.0 glue and the 3.0
    /// framework kept as external.cxorig — what the patcher made from a 4.0b3 DMG.
    private func makeBrokenApp() throws -> (app: URL, gptk: URL) {
        let app = tempDir.appendingPathComponent("CrossOver_Endfield_Patch.app", isDirectory: true)
        let cxr = app.appendingPathComponent("Contents/SharedSupport/CrossOver", isDirectory: true)
        for file in ["lib/wine/x86_64-unix/ntdll.so", "lib/wine/x86_64-unix/winemac.so",
                     "lib/wine/x86_64-windows/dwmapi.dll", "lib/wine/x86_64-windows/kernel32.dll",
                     "lib/wine/x86_64-windows/ntoskrnl.exe", "lib/wine/x86_64-windows/wineboot.exe",
                     "lib/wine/x86_64-windows/rundll32.exe", "bin/wineserver",
                     "CrossOver-Hosted Application/wineserver", "lib64/libMoltenVK.dylib"] {
            try write("x", to: cxr.appendingPathComponent(file))
        }
        let gptk = cxr.appendingPathComponent("lib64/apple_gptk", isDirectory: true)
        try makeExternal(gptk.appendingPathComponent("external"), version: "4.0b3", binary: "d3dm-4.0b3")
        try makeExternal(gptk.appendingPathComponent("external.cxorig"), version: "3.0", binary: "d3dm-3.0")
        try makeGlue(gptk.appendingPathComponent("wine"), jumpTable: false)
        return (app, gptk)
    }

    func testDetectsTheFrameworkOverStockGlue() throws {
        let (app, _) = try makeBrokenApp()
        let mismatch = try XCTUnwrap(D3DMetalRepair.mismatch(in: app))
        XCTAssertEqual(mismatch.frameworkVersion, "4.0b3")
        XCTAssertFalse(mismatch.glueUsesJumpTable)
    }

    func testConsistencyRules() {
        XCTAssertTrue(D3DMetalRepair.isConsistent(frameworkVersion: "3.0", glueUsesJumpTable: false))
        XCTAssertFalse(D3DMetalRepair.isConsistent(frameworkVersion: "3.0", glueUsesJumpTable: true))
        XCTAssertTrue(D3DMetalRepair.isConsistent(frameworkVersion: "4.0b2", glueUsesJumpTable: false))
        XCTAssertTrue(D3DMetalRepair.isConsistent(frameworkVersion: "4.0b2", glueUsesJumpTable: true))
        XCTAssertFalse(D3DMetalRepair.isConsistent(frameworkVersion: "4.0b3", glueUsesJumpTable: false))
        XCTAssertTrue(D3DMetalRepair.isConsistent(frameworkVersion: "4.0b3", glueUsesJumpTable: true))
    }

    func testRepairInstallsTheGlueBuiltWithTheInstalledFramework() throws {
        let (app, gptk) = try makeBrokenApp()
        let redist = tempDir.appendingPathComponent("dmg/redist/lib", isDirectory: true)
        try makeExternal(redist.appendingPathComponent("external"), version: "4.0b3", binary: "d3dm-4.0b3")
        try makeGlue(redist.appendingPathComponent("wine"), jumpTable: true)
        let source = try XCTUnwrap(GPTKSource(url: redist.appendingPathComponent("external")))

        let result = try D3DMetalRepair.repair(in: app, sources: [source])

        XCTAssertTrue(result.contains("DLLs"), result)
        XCTAssertNil(D3DMetalRepair.mismatch(in: app))
        XCTAssertEqual(D3DMetalRepair.frameworkVersion(external: gptk.appendingPathComponent("external")), "4.0b3")
        XCTAssertEqual(D3DMetalRepair.glueUsesJumpTable(wine: gptk.appendingPathComponent("wine.cxorig")), false)
    }

    func testRepairIgnoresGlueBuiltForADifferentFramework() throws {
        let (app, gptk) = try makeBrokenApp()
        let redist = tempDir.appendingPathComponent("other/redist/lib", isDirectory: true)
        try makeExternal(redist.appendingPathComponent("external"), version: "4.0b3", binary: "some-other-build")
        try makeGlue(redist.appendingPathComponent("wine"), jumpTable: true)
        let source = try XCTUnwrap(GPTKSource(url: redist.appendingPathComponent("external")))

        _ = try D3DMetalRepair.repair(in: app, sources: [source])

        // Fell back to CrossOver's own 3.0, which matches the 3.0 glue still installed.
        XCTAssertNil(D3DMetalRepair.mismatch(in: app))
        XCTAssertEqual(D3DMetalRepair.glueUsesJumpTable(wine: gptk.appendingPathComponent("wine")), false)
    }

    func testRepairWithoutASourceRestoresCrossOversD3DMetal() throws {
        let (app, gptk) = try makeBrokenApp()

        let result = try D3DMetalRepair.repair(in: app, sources: [])

        XCTAssertTrue(result.contains("Restored"), result)
        XCTAssertNil(D3DMetalRepair.mismatch(in: app))
        XCTAssertEqual(D3DMetalRepair.frameworkVersion(external: gptk.appendingPathComponent("external")), "3.0")
        // The 4.0b3 framework stays available as the backup.
        XCTAssertEqual(D3DMetalRepair.frameworkVersion(external: gptk.appendingPathComponent("external.cxorig")), "4.0b3")
    }

    func testRepairFailsWhenNothingMatches() throws {
        let (app, gptk) = try makeBrokenApp()
        try fm.removeItem(at: gptk.appendingPathComponent("external.cxorig"))
        XCTAssertThrowsError(try D3DMetalRepair.repair(in: app, sources: []))
        XCTAssertNotNil(D3DMetalRepair.mismatch(in: app))
    }
}
