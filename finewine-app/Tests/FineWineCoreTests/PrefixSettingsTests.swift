import XCTest
@testable import FineWineCore

final class PrefixSettingsTests: XCTestCase {
    private func edit(_ edits: [RegistryEdit], _ key: String, _ name: String) -> RegistryEdit.Action? {
        edits.last { $0.key == key && $0.name == name }?.action
    }

    func testDefaultsProduceTheBaselineEdits() {
        let edits = PrefixSettings().registryEdits()
        XCTAssertEqual(edit(edits, PrefixSettings.wineKey, "Version"), .setString("win11"))
        XCTAssertEqual(edit(edits, PrefixSettings.macDriverKey, "RetinaMode"), .setString("y"), "high-resolution mode is the default")
        XCTAssertEqual(edit(edits, PrefixSettings.macDriverKey, "LeftOptionIsAlt"), .setString("y"))
        XCTAssertEqual(edit(edits, PrefixSettings.desktopKey, "LogPixels"), .setDWord(96))
        XCTAssertEqual(edit(edits, PrefixSettings.explorerKey, "Desktop"), .deleteValue)
        XCTAssertNil(edit(edits, PrefixSettings.currentVersionKey, "CurrentBuild"))
    }

    func testHighResolutionAndAutomaticScalingAreTheDefaults() {
        let settings = PrefixSettings()
        XCTAssertTrue(settings.retinaMode)
        XCTAssertTrue(settings.automaticDPI)
        // On a Retina display programs get 192 DPI, so they keep their size and gain sharpness.
        XCTAssertEqual(settings.effectiveDPI(displayScale: 2), 192)
        XCTAssertEqual(edit(settings.registryEdits(displayScale: 2), PrefixSettings.desktopKey, "LogPixels"), .setDWord(192))
        XCTAssertEqual(edit(settings.registryEdits(displayScale: 1), PrefixSettings.desktopKey, "LogPixels"), .setDWord(96))
    }

    func testEffectiveDPI() {
        var settings = PrefixSettings()
        XCTAssertEqual(settings.effectiveDPI(displayScale: 1), 96)
        XCTAssertEqual(settings.effectiveDPI(displayScale: 1.5), 144)
        XCTAssertEqual(settings.effectiveDPI(displayScale: 3), 288)
        XCTAssertEqual(settings.effectiveDPI(displayScale: 0), 96, "nonsense scales are clamped")
        XCTAssertEqual(settings.effectiveDPI(displayScale: 99), 384)

        settings.retinaMode = false
        XCTAssertEqual(settings.effectiveDPI(displayScale: 2), 96, "without high-resolution mode Wine already works in points")

        settings.automaticDPI = false
        settings.dpi = 120
        XCTAssertEqual(settings.effectiveDPI(displayScale: 2), 120, "a manual DPI is used as given")
        settings.retinaMode = true
        XCTAssertEqual(edit(settings.registryEdits(displayScale: 2), PrefixSettings.desktopKey, "LogPixels"), .setDWord(120))
    }

    func testAutomaticDPIIgnoresAnOutOfRangeManualValue() {
        var settings = PrefixSettings()
        settings.dpi = 5
        XCTAssertEqual(settings.validationProblems(), [], "the manual value is not in use")
        settings.automaticDPI = false
        XCTAssertEqual(settings.validationProblems().count, 1)
    }

    func testPrefixesSavedBeforeAutomaticScalingKeepTheirDPI() throws {
        let chosen = try JSONDecoder().decode(PrefixSettings.self, from: Data(#"{"dpi":144,"retinaMode":true}"#.utf8))
        XCTAssertFalse(chosen.automaticDPI)
        XCTAssertEqual(chosen.effectiveDPI(displayScale: 2), 144)
        let untouched = try JSONDecoder().decode(PrefixSettings.self, from: Data("{}".utf8))
        XCTAssertTrue(untouched.automaticDPI)
        XCTAssertTrue(untouched.retinaMode)
    }

    func testDLSSThroughMetalFXIsSwitchedOnOnlyWithDXMT() {
        func env(_ settings: PrefixSettings) -> [String: String] {
            Dictionary(uniqueKeysWithValues: settings.environmentVariables().map { ($0.name, $0.value) })
        }
        var settings = PrefixSettings()
        XCTAssertTrue(settings.dlssThroughMetalFX)
        XCTAssertEqual(env(settings)["DXMT_ENABLE_NVEXT"], "1")

        settings.dlssThroughMetalFX = false
        XCTAssertNil(env(settings)["DXMT_ENABLE_NVEXT"])

        settings.dlssThroughMetalFX = true
        settings.graphicsBackend = .wined3d
        XCTAssertNil(env(settings)["DXMT_ENABLE_NVEXT"], "only DXMT has the library that does the translation")

        let old = try? JSONDecoder().decode(PrefixSettings.self, from: Data("{}".utf8))
        XCTAssertEqual(old?.dlssThroughMetalFX, true)
    }

    func testWindowsBuildWritesBothBuildValues() {
        var settings = PrefixSettings()
        settings.windowsBuild = "26100"
        let edits = settings.registryEdits()
        XCTAssertEqual(edit(edits, PrefixSettings.currentVersionKey, "CurrentBuild"), .setString("26100"))
        XCTAssertEqual(edit(edits, PrefixSettings.currentVersionKey, "CurrentBuildNumber"), .setString("26100"))
    }

    func testVirtualDesktopEdits() {
        var settings = PrefixSettings()
        settings.virtualDesktop = VirtualDesktop(width: 1920, height: 1080)
        let edits = settings.registryEdits()
        XCTAssertEqual(edit(edits, PrefixSettings.explorerKey, "Desktop"), .setString("Default"))
        XCTAssertEqual(edit(edits, PrefixSettings.desktopsKey, "Default"), .setString("1920x1080"))
    }

    func testDLLOverridesAreNormalizedAndWritten() {
        var settings = PrefixSettings()
        settings.dllOverrides = [DLLOverride(name: " D3D11.DLL ", order: .nativeThenBuiltin),
                                 DLLOverride(name: "winemenubuilder.exe", order: .disabled)]
        let edits = settings.registryEdits()
        XCTAssertEqual(edit(edits, PrefixSettings.overridesKey, "d3d11"), .setString("native,builtin"))
        XCTAssertEqual(edit(edits, PrefixSettings.overridesKey, "winemenubuilder.exe"), .setString(""))
    }

    func testRemovedOverridesAreDeletedOnTheNextApply() {
        var before = PrefixSettings()
        before.dllOverrides = [DLLOverride(name: "dxgi", order: .native), DLLOverride(name: "d3d11", order: .native)]
        var after = before
        after.dllOverrides.removeFirst()
        let edits = after.registryEdits(replacing: before)
        XCTAssertEqual(edit(edits, PrefixSettings.overridesKey, "dxgi"), .deleteValue)
        XCTAssertEqual(edit(edits, PrefixSettings.overridesKey, "d3d11"), .setString("native"))
    }

    func testEnvironmentVariables() {
        var settings = PrefixSettings()
        XCTAssertEqual(settings.environmentVariables().map(\.name), ["WINEDEBUG", "DXMT_ENABLE_NVEXT"])
        XCTAssertEqual(settings.environmentVariables().first?.value, "-all")

        settings.syncMode = .msync
        settings.metalHUD = true
        settings.hideHypervisor = true
        settings.debugChannels = "err+all"
        settings.environment = [EnvironmentVariable(name: "MY_FLAG", value: "1"),
                                EnvironmentVariable(name: "bad name", value: "x")]
        let env = Dictionary(uniqueKeysWithValues: settings.environmentVariables().map { ($0.name, $0.value) })
        XCTAssertEqual(env, ["WINEDEBUG": "err+all", "WINEMSYNC": "1", "MTL_HUD_ENABLED": "1",
                             "FEX_HIDEHYPERVISORBIT": "1", "DXMT_ENABLE_NVEXT": "1", "MY_FLAG": "1"])
    }

    func testEmptyDebugChannelsFallBackToSilent() {
        var settings = PrefixSettings()
        settings.debugChannels = ""
        let env = Dictionary(uniqueKeysWithValues: settings.environmentVariables().map { ($0.name, $0.value) })
        XCTAssertNil(env["WINEMSYNC"])
        XCTAssertEqual(env["WINEDEBUG"], "-all")
    }

    func testUserVariablesComeLastSoTheyWin() {
        var settings = PrefixSettings()
        settings.environment = [EnvironmentVariable(name: "WINEDEBUG", value: "+seh")]
        XCTAssertEqual(settings.environmentVariables().last?.value, "+seh")
    }

    func testValidation() {
        XCTAssertEqual(PrefixSettings().validationProblems(), [])
        var settings = PrefixSettings()
        settings.windowsBuild = "24H2"
        settings.automaticDPI = false
        settings.dpi = 20
        settings.virtualDesktop = VirtualDesktop(width: 100, height: 100)
        settings.environment = [EnvironmentVariable(name: "1BAD", value: "")]
        settings.dllOverrides = [DLLOverride(name: "d3d11", order: .native),
                                 DLLOverride(name: "D3D11.dll", order: .builtin),
                                 DLLOverride(name: "  ", order: .builtin)]
        XCTAssertEqual(settings.validationProblems().count, 6)
    }

    func testEnvironmentVariableNames() {
        XCTAssertTrue(EnvironmentVariable.isValidName("WINEDEBUG"))
        XCTAssertTrue(EnvironmentVariable.isValidName("_x9"))
        XCTAssertFalse(EnvironmentVariable.isValidName(""))
        XCTAssertFalse(EnvironmentVariable.isValidName("9X"))
        XCTAssertFalse(EnvironmentVariable.isValidName("A=B"))
        XCTAssertFalse(EnvironmentVariable.isValidName("A B"))
    }

    func testDecodingOlderMetadataFillsInDefaults() throws {
        let json = #"{"windowsVersion":"win7","dpi":120}"#
        let settings = try JSONDecoder().decode(PrefixSettings.self, from: Data(json.utf8))
        XCTAssertEqual(settings.windowsVersion, .win7)
        XCTAssertEqual(settings.dpi, 120)
        XCTAssertEqual(settings.graphicsBackend, .dxmt)
        XCTAssertEqual(settings.debugChannels, "-all")
        XCTAssertTrue(settings.leftOptionIsAlt)
    }

    func testCodableRoundTrip() throws {
        var settings = PrefixSettings()
        settings.windowsBuild = "26100"
        settings.virtualDesktop = VirtualDesktop(width: 1280, height: 720)
        settings.dllOverrides = [DLLOverride(name: "dxgi", order: .builtinThenNative)]
        settings.environment = [EnvironmentVariable(name: "A", value: "b")]
        let decoded = try JSONDecoder().decode(PrefixSettings.self, from: JSONEncoder().encode(settings))
        XCTAssertEqual(decoded, settings)
    }

    func testLoadOrderEnvironmentCodes() {
        XCTAssertEqual(DLLLoadOrder.allCases.map(\.environmentCode), ["n,b", "b,n", "n", "b", ""])
    }

    func testSnapshotReadsThePrefixRegistry() {
        let sandbox = Sandbox()
        let prefix = sandbox.root.appendingPathComponent("pfx")
        sandbox.write(WineRegistryReaderTests.sample, to: prefix.appendingPathComponent("user.reg"))
        sandbox.write("""
        WINE REGISTRY Version 2
        [Software\\\\Microsoft\\\\Windows NT\\\\CurrentVersion] 1
        "CurrentBuild"="26100"
        """, to: prefix.appendingPathComponent("system.reg"))
        let snapshot = PrefixRegistrySnapshot.read(prefix: prefix)
        XCTAssertEqual(snapshot.windowsVersion, "win10")
        XCTAssertEqual(snapshot.windowsBuild, "26100")
        XCTAssertEqual(snapshot.dpi, 120)
        XCTAssertEqual(snapshot.dllOverrides["d3d11"], "native,builtin")
        XCTAssertNil(snapshot.virtualDesktop)
        XCTAssertNil(snapshot.retinaMode)
    }

    func testSnapshotOfAMissingPrefixIsEmpty() {
        XCTAssertEqual(PrefixRegistrySnapshot.read(prefix: URL(fileURLWithPath: "/nonexistent/pfx")),
                       PrefixRegistrySnapshot())
    }
}
