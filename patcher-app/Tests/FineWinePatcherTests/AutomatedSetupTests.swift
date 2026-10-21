import XCTest
@testable import FineWinePatcher

final class AutomatedSetupTests: XCTestCase {

    // MARK: - Bottle name validation

    func testBottleNameRejectsEmptyAndReservedNames() {
        for name in ["", "   ", ".", ".."] {
            XCTAssertNotNil(SetupValidation.bottleNameError(name, existing: []), "expected \(debugName(name)) to be rejected")
        }
    }

    func testBottleNameRejectsCrossOverForbiddenCharacters() {
        for name in ["a/b", "a\\b", "a:b", "a*b", "a?b", "a|b", "a\"b", "a<b", "a>b", "a'b", "a{b}"] {
            XCTAssertNotNil(SetupValidation.bottleNameError(name, existing: []), "expected \(debugName(name)) to be rejected")
        }
    }

    func testBottleNameRejectsExistingBottle() {
        let error = SetupValidation.bottleNameError("Arknights Endfield", existing: ["Arknights Endfield"])
        XCTAssertNotNil(error)
        XCTAssertTrue(error?.contains("already exists") == true)
    }

    func testBottleNameAcceptsTheDefaultAndTrimsWhitespace() {
        XCTAssertNil(SetupValidation.bottleNameError("Arknights Endfield", existing: []))
        XCTAssertNil(SetupValidation.bottleNameError("  Arknights Endfield  ", existing: []))
        // Whitespace is trimmed before the duplicate check, so a padded name still collides.
        XCTAssertNotNil(SetupValidation.bottleNameError(" Arknights Endfield ", existing: ["Arknights Endfield"]))
    }

    func testBottleNameLengthIsBounded() {
        XCTAssertNotNil(SetupValidation.bottleNameError(String(repeating: "a", count: 65), existing: []))
        XCTAssertNil(SetupValidation.bottleNameError(String(repeating: "a", count: 64), existing: []))
    }

    // MARK: - Installer validation

    func testInstallerMustExistAndBeAnExe() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("fw-setup-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        XCTAssertNotNil(SetupValidation.installerError(nil))

        let missing = dir.appendingPathComponent("GRYPHLINK_missing.exe")
        XCTAssertNotNil(SetupValidation.installerError(missing))

        let dmg = dir.appendingPathComponent("GRYPHLINK.dmg")
        XCTAssertTrue(FileManager.default.createFile(atPath: dmg.path, contents: Data()))
        XCTAssertNotNil(SetupValidation.installerError(dmg))

        let exe = dir.appendingPathComponent("GRYPHLINK_v1.6.0.exe")
        XCTAssertTrue(FileManager.default.createFile(atPath: exe.path, contents: Data()))
        XCTAssertNil(SetupValidation.installerError(exe))
    }

    // MARK: - Settings → cxbottle parameters

    func testDefaultSettingsMatchCreateBottleScript() {
        let settings = BottleSettings()
        XCTAssertEqual(settings.name, "Arknights Endfield")
        XCTAssertEqual(settings.template, "win11_64")
        XCTAssertEqual(settings.backend, .d3dmetal)
        XCTAssertTrue(settings.msync)
        XCTAssertTrue(settings.upscaling)

        let env = Dictionary(uniqueKeysWithValues: settings.environment.map { ($0.key, $0.value) })
        XCTAssertEqual(env["CX_GRAPHICS_BACKEND"], "d3dmetal")
        XCTAssertEqual(env["WINEMSYNC"], "1")
        XCTAssertEqual(env["D3DM_ENABLE_METALFX"], "1")
        XCTAssertNil(env["DXMT_ENABLE_NVEXT"])
    }

    func testAutoBackendOmitsTheBackendKey() {
        var settings = BottleSettings()
        settings.backend = .auto
        let env = Dictionary(uniqueKeysWithValues: settings.environment.map { ($0.key, $0.value) })
        XCTAssertNil(env["CX_GRAPHICS_BACKEND"])
        XCTAssertNil(env["D3DM_ENABLE_METALFX"])
        XCTAssertEqual(env["WINEMSYNC"], "1")
    }

    func testMSyncAndUpscalingCanBeDisabled() {
        var settings = BottleSettings()
        settings.msync = false
        settings.upscaling = false
        let env = Dictionary(uniqueKeysWithValues: settings.environment.map { ($0.key, $0.value) })
        XCTAssertEqual(env["WINEMSYNC"], "0")
        XCTAssertNil(env["D3DM_ENABLE_METALFX"])
    }

    func testDXMTUsesItsOwnUpscalerKey() {
        var settings = BottleSettings()
        settings.backend = .dxmt
        let env = Dictionary(uniqueKeysWithValues: settings.environment.map { ($0.key, $0.value) })
        XCTAssertEqual(env["CX_GRAPHICS_BACKEND"], "dxmt")
        XCTAssertEqual(env["DXMT_ENABLE_NVEXT"], "1")
        XCTAssertNil(env["D3DM_ENABLE_METALFX"])
    }

    func testBackendsWithoutAnUpscalerDoNotWriteOne() {
        for backend in [BottleBackend.dxvk, .wined3d, .auto] {
            var settings = BottleSettings()
            settings.backend = backend
            let env = Dictionary(uniqueKeysWithValues: settings.environment.map { ($0.key, $0.value) })
            XCTAssertNil(env["D3DM_ENABLE_METALFX"], "\(backend.rawValue)")
            XCTAssertNil(env["DXMT_ENABLE_NVEXT"], "\(backend.rawValue)")
        }
    }

    // MARK: - Patched-app detection

    func testStockCrossOverIsNotAcceptedAsPatched() throws {
        let app = FileManager.default.temporaryDirectory
            .appendingPathComponent("StockCrossOver-\(UUID().uuidString).app", isDirectory: true)
        let contents = app.appendingPathComponent("Contents", isDirectory: true)
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: app) }

        let plist = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0"><dict>
        <key>CFBundleIdentifier</key><string>com.codeweavers.CrossOver</string>
        </dict></plist>
        """
        try plist.write(to: contents.appendingPathComponent("Info.plist"), atomically: true, encoding: .utf8)

        XCTAssertFalse(SetupValidation.isPatchedCrossOver(app))
    }

    private func debugName(_ name: String) -> String { name.isEmpty ? "<empty>" : "\"\(name)\"" }
}
