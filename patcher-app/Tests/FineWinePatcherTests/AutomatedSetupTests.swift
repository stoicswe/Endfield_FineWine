import XCTest
@testable import FineWinePatcher

final class AutomatedSetupTests: XCTestCase {

    func testRosettaSupportInstallsAndVerifiesWhenProbeFails() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("fw-rosetta-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let marker = dir.appendingPathComponent("installed")
        let probe = dir.appendingPathComponent("probe.sh")
        let installer = dir.appendingPathComponent("installer.sh")
        try """
        #!/bin/sh
        if [ -f "\(marker.path)" ]; then exit 0; else exit 1; fi
        """.write(to: probe, atomically: true, encoding: .utf8)
        try """
        #!/bin/sh
        touch "\(marker.path)"
        exit 0
        """.write(to: installer, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: probe.path)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: installer.path)

        try RosettaSupport.ensureInstalled(
            archPath: probe.path,
            softwareUpdatePath: installer.path,
            appleSilicon: true
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: marker.path))
    }

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
        XCTAssertFalse(settings.metalHUD)

        let env = Dictionary(uniqueKeysWithValues: settings.environment.map { ($0.key, $0.value) })
        XCTAssertEqual(env["CX_GRAPHICS_BACKEND"], "d3dmetal")
        XCTAssertEqual(env["WINEMSYNC"], "1")
        XCTAssertEqual(env["D3DM_ENABLE_METALFX"], "1")
        XCTAssertNil(env["DXMT_ENABLE_NVEXT"])
        XCTAssertNil(env["MTL_HUD_ENABLED"])
    }

    func testMetalHUDCanBeEnabled() {
        var settings = BottleSettings()
        settings.metalHUD = true
        let env = Dictionary(uniqueKeysWithValues: settings.environment.map { ($0.key, $0.value) })
        XCTAssertEqual(env["MTL_HUD_ENABLED"], "1")
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

    // MARK: - Metal 4 properties vs. macOS version

    func testMetal4PropertiesAreStrippedBeforeMacOS27() {
        // The GPTK4 guides' two spellings of the Metal 4 opt-in (plus a future variant) must
        // never survive into a bottle config on macOS 26 — Metal 4 is macOS 27-era software.
        let pairs: [(key: String, value: String)] = [
            ("CX_GRAPHICS_BACKEND", "d3dmetal"),
            ("D3DM_MTL4", "1"),
            ("D3D_MTL_4", "1"),
            ("d3dm_mtl4", "1"),
            ("WINEMSYNC", "1"),
        ]
        let kept = BottleSettings.withoutUnsupportedMetal4Properties(pairs, osMajor: 26)
        XCTAssertEqual(
            Set(kept.map { $0.key }),
            ["CX_GRAPHICS_BACKEND", "WINEMSYNC"]
        )
    }

    func testMetal4PropertiesAreKeptFromMacOS27On() {
        let pairs: [(key: String, value: String)] = [
            ("CX_GRAPHICS_BACKEND", "d3dmetal"),
            ("D3DM_MTL4", "1"),
            ("D3D_MTL_4", "1"),
            ("WINEMSYNC", "1"),
        ]
        for osMajor in [27, 28, 30] {
            let kept = BottleSettings.withoutUnsupportedMetal4Properties(pairs, osMajor: osMajor)
            XCTAssertEqual(kept.count, pairs.count, "osMajor \(osMajor)")
        }
    }

    func testDefaultSetupPropertiesNeverIncludeMetal4() {
        // Whatever the OS: the stock settings the wizard writes contain no Metal 4 property.
        let settings = BottleSettings()
        let env = Dictionary(uniqueKeysWithValues: settings.environment.map { ($0.key, $0.value) })
        for key in BottleSettings.metal4PropertyKeys {
            XCTAssertNil(env[key.uppercased()], key)
        }
    }

    // MARK: - cxbottle arguments + MSync-off fallback

    func testCxbottleArgumentsMatchTheWizardContract() {
        let settings = BottleSettings()
        let args = SetupEngine.cxbottleArguments(
            bottle: settings.trimmedName, template: settings.template,
            environment: settings.environment)
        XCTAssertEqual(args, [
            "--bottle", "Arknights Endfield",
            "--create",
            "--template", "win11_64",
            "--description", "Arknights: Endfield (Endfield_FineWine)",
            "--param", "EnvironmentVariables:CX_GRAPHICS_BACKEND=d3dmetal",
            "--param", "EnvironmentVariables:WINEMSYNC=1",
            "--param", "EnvironmentVariables:D3DM_ENABLE_METALFX=1",
        ])
    }

    func testMsyncOverrideChangesOnlyWINEMSYNC() {
        // The fallback retry rebuilds the arguments with MSync off; every other setting is
        // carried over unchanged.
        let settings = BottleSettings()
        let on = Dictionary(uniqueKeysWithValues: settings.environment.map { ($0.key, $0.value) })
        let off = Dictionary(
            uniqueKeysWithValues: settings.environment(msyncOverride: false).map { ($0.key, $0.value) })
        XCTAssertEqual(on["WINEMSYNC"], "1")
        XCTAssertEqual(off["WINEMSYNC"], "0")
        XCTAssertEqual(on["CX_GRAPHICS_BACKEND"], off["CX_GRAPHICS_BACKEND"])
        XCTAssertEqual(on["D3DM_ENABLE_METALFX"], off["D3DM_ENABLE_METALFX"])
    }

    func testCxbottleArgumentsRequestArm64BottleOnArm() {
        let args = SetupEngine.cxbottleArguments(
            bottle: "B", template: "win11_64", wineArch: CrossOverVariant.arm.bottleWineArch, environment: [])
        XCTAssertEqual(args, [
            "--bottle", "B",
            "--create",
            "--template", "win11_64",
            "--description", "Arknights: Endfield (Endfield_FineWine)",
            "--winearch", "arm64",
        ])
    }

    // MARK: - Preflight (Rosetta + wine smoke exec)

    /// A fake CrossOver root whose `bin/wine` prints a version and exits with `status`.
    private func fakeCrossOverRoot(status: Int32, output: String = "wine-11.0\n") throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("fw-preflight-\(UUID().uuidString)", isDirectory: true)
        let bin = dir.appendingPathComponent("bin", isDirectory: true)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let wine = bin.appendingPathComponent("wine")
        let body = status == 0 ? "#!/bin/sh\nprintf '%s' \"\(output)\"\nexit 0\n"
                               : "#!/bin/sh\nprintf '%s' \"\(output)\" >&2\nexit \(status)\n"
        try body.write(to: wine, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: wine.path)
        return dir
    }

    /// A fake `arch` helper exiting with `status`.
    private func fakeArch(status: Int32) throws -> String {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("fw-preflight-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let arch = dir.appendingPathComponent("arch")
        try "#!/bin/sh\nexit \(status)\n".write(to: arch, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: arch.path)
        return arch.path
    }

    private func tempLog(in dir: URL) -> URL {
        dir.appendingPathComponent("preflight.log")
    }

    func testPreflightPassesWhenWineRuns() throws {
        let cxr = try fakeCrossOverRoot(status: 0)
        let log = tempLog(in: cxr)
        try SetupEngine.runPreflight(cxr: cxr, log: log, archPath: try fakeArch(status: 0))
        let text = try String(contentsOf: log, encoding: .utf8)
        XCTAssertTrue(text.contains("preflight ok"), text)
        XCTAssertTrue(text.contains("wine-11.0"), text)
    }

    func testPreflightFailsWithoutRosetta() throws {
        let cxr = try fakeCrossOverRoot(status: 0)
        XCTAssertThrowsError(
            try SetupEngine.runPreflight(cxr: cxr, log: tempLog(in: cxr), archPath: try fakeArch(status: 1))
        ) { error in
            XCTAssertTrue("\(error)".contains("Rosetta"), "\(error)")
        }
    }

    func testArmPreflightPassesWithoutRosetta() throws {
        let cxr = try fakeCrossOverRoot(status: 0)
        let log = tempLog(in: cxr)
        try SetupEngine.runPreflight(cxr: cxr, log: log, requiresRosetta: false, archPath: try fakeArch(status: 1))
        let text = try String(contentsOf: log, encoding: .utf8)
        XCTAssertTrue(text.contains("preflight ok"), text)
        XCTAssertFalse(text.contains("Rosetta"), text)
    }

    func testPreflightFailsWhenWineCannotStart() throws {
        let cxr = try fakeCrossOverRoot(status: 1, output: "dyld: Library not loaded\n")
        XCTAssertThrowsError(
            try SetupEngine.runPreflight(cxr: cxr, log: tempLog(in: cxr), archPath: try fakeArch(status: 0))
        ) { error in
            XCTAssertTrue("\(error)".contains("wine failed to start"), "\(error)")
        }
    }

    func testPreflightPassesForCrossOverBanner() throws {
        // The patched CrossOver's `bin/wine --version` prints CrossOver's banner, not Wine's
        // `wine-x.y` string. That is a healthy run and must not fail the setup.
        let banner = """
            Product Name: CrossOver
            Public Version: 26.3.0
            Product Version: 26.3.0.39832
            Build Tag: cxoffice-26.3.0rc2
            Build Timestamp: 20260715T103801Z
            """
        let cxr = try fakeCrossOverRoot(status: 0, output: banner)
        let log = tempLog(in: cxr)
        try SetupEngine.runPreflight(cxr: cxr, log: log, archPath: try fakeArch(status: 0))
        let text = try String(contentsOf: log, encoding: .utf8)
        XCTAssertTrue(text.contains("preflight ok"), text)
    }

    func testWineVersionOutputMustNameWineOrCrossOver() {
        XCTAssertTrue(SetupEngine.wineVersionLooksValid("wine-11.0"))
        XCTAssertTrue(SetupEngine.wineVersionLooksValid("Product Name: CrossOver\nPublic Version: 26.3.0"))
        XCTAssertTrue(SetupEngine.wineVersionLooksValid("cxoffice-26.3.0rc2"))
        XCTAssertFalse(SetupEngine.wineVersionLooksValid(""))
        XCTAssertFalse(SetupEngine.wineVersionLooksValid("   \n"))
        XCTAssertFalse(SetupEngine.wineVersionLooksValid("some unrelated output"))
    }

    func testPreflightFailsWhenWinePrintsNoVersion() throws {
        // A zero exit with no version output is also a broken loader chain (e.g. a silent kill
        // relayed as an empty string) — do not accept it.
        let cxr = try fakeCrossOverRoot(status: 0, output: "")
        XCTAssertThrowsError(
            try SetupEngine.runPreflight(cxr: cxr, log: tempLog(in: cxr), archPath: try fakeArch(status: 0))
        ) { error in
            XCTAssertTrue("\(error)".contains("wine failed to start"), "\(error)")
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

    func testArmBottlesAreSetToWindows11_24H2() {
        let commands = SetupEngine.armWindowsBuildCommands(bottle: "My Bottle")
        XCTAssertEqual(commands.count, 2)
        XCTAssertEqual(commands.map { $0[7] }, ["CurrentBuild", "CurrentBuildNumber"])
        for args in commands {
            XCTAssertEqual(Array(args.prefix(5)), ["--bottle", "My Bottle", "--wait-children", "reg", "add"])
            XCTAssertEqual(args[5], "HKLM\\Software\\Microsoft\\Windows NT\\CurrentVersion")
            XCTAssertEqual(Array(args.suffix(5)), ["/t", "REG_SZ", "/d", "26100", "/f"])
        }
    }
}
