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

    private func env(_ settings: PrefixSettings) -> [String: String] {
        Dictionary(settings.environmentVariables().map { ($0.name, $0.value) }, uniquingKeysWith: { _, last in last })
    }

    func testDLSSThroughMetalFXIsOnByDefaultForEveryGraphicsLayer() {
        var settings = PrefixSettings()
        XCTAssertTrue(settings.dlssThroughMetalFX)
        XCTAssertEqual(env(settings)["FINEWINE_DLSS"], "1", "Direct3D 12 and Vulkan games reach MetalFX through MoltenVK")
        XCTAssertEqual(env(settings)["DXMT_ENABLE_NVEXT"], "1", "Direct3D 11 games reach it through DXMT")

        settings.dlssThroughMetalFX = false
        XCTAssertNil(env(settings)["FINEWINE_DLSS"])
        XCTAssertNil(env(settings)["DXMT_ENABLE_NVEXT"])

        settings.dlssThroughMetalFX = true
        settings.graphicsBackend = .wined3d
        XCTAssertEqual(env(settings)["FINEWINE_DLSS"], "1", "Direct3D 12 and Vulkan do not depend on the Direct3D 11 layer")
        XCTAssertNil(env(settings)["DXMT_ENABLE_NVEXT"], "only DXMT has that switch")

        let old = try? JSONDecoder().decode(PrefixSettings.self, from: Data("{}".utf8))
        XCTAssertEqual(old?.dlssThroughMetalFX, true)
    }

    func testTheGPUIsReportedAsItIsUnlessAsked() {
        var settings = PrefixSettings()
        XCTAssertFalse(settings.reportNvidiaGPU)
        XCTAssertNil(env(settings)["FINEWINE_GPU_VENDOR_ID"])
        XCTAssertNil(env(settings)["FINEWINE_GPU_NAME"])
        XCTAssertNil(env(settings)["WINE_D3D_CONFIG"])
        // DXMT would report NVIDIA's vendor id on its own once DLSS is on; it is told Apple's.
        XCTAssertEqual(env(settings)["DXMT_CONFIG"], "dxgi.customVendorId=106b")

        settings.dlssThroughMetalFX = false
        XCTAssertNil(env(settings)["DXMT_CONFIG"], "without DLSS, DXMT reports Apple's id unprompted")

        let old = try? JSONDecoder().decode(PrefixSettings.self, from: Data("{}".utf8))
        XCTAssertEqual(old?.reportNvidiaGPU, false)
    }

    func testReportingAnNvidiaGPUUsesTheNameAndIdsOfAnRTX5080OnEveryLayer() throws {
        XCTAssertEqual(PrefixSettings.reportedGPUVendorID, 0x10DE)
        XCTAssertEqual(PrefixSettings.reportedGPUDeviceID, 0x2C02)
        XCTAssertEqual(PrefixSettings.reportedGPUName, "NVIDIA GeForce RTX 5080")

        var settings = PrefixSettings()
        settings.reportNvidiaGPU = true
        var e = env(settings)
        XCTAssertEqual(e["FINEWINE_GPU_VENDOR_ID"], "10de", "Vulkan, through MoltenVK")
        XCTAssertEqual(e["FINEWINE_GPU_DEVICE_ID"], "2c02")
        XCTAssertEqual(e["FINEWINE_GPU_NAME"], "NVIDIA GeForce RTX 5080", "the name, for Vulkan and Wine's Direct3D")
        XCTAssertEqual(e["WINE_D3D_CONFIG"], "VideoPciVendorID=0x10de,VideoPciDeviceID=0x2c02", "Wine's Direct3D, and Direct3D 12 with it")
        XCTAssertEqual(e["DXMT_CONFIG"], "dxgi.customVendorId=10de;dxgi.customDeviceId=2c02;dxgi.customDeviceDesc=\"NVIDIA GeForce RTX 5080\"",
                       "Direct3D 10 and 11, through DXMT")

        settings.graphicsBackend = .wined3d
        e = env(settings)
        XCTAssertEqual(e["WINE_D3D_CONFIG"], "VideoPciVendorID=0x10de,VideoPciDeviceID=0x2c02")
        XCTAssertNil(e["DXMT_CONFIG"], "DXMT is not in use")

        // It is independent of DLSS, and survives being saved.
        settings.dlssThroughMetalFX = false
        XCTAssertEqual(env(settings)["FINEWINE_GPU_VENDOR_ID"], "10de")
        let saved = try JSONDecoder().decode(PrefixSettings.self, from: JSONEncoder().encode(settings))
        XCTAssertTrue(saved.reportNvidiaGPU)

        // The user's own variables still have the last word.
        settings.environment = [EnvironmentVariable(name: "FINEWINE_GPU_DEVICE_ID", value: "2684")]
        XCTAssertEqual(env(settings)["FINEWINE_GPU_DEVICE_ID"], "2684")
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
        XCTAssertEqual(settings.environmentVariables().map(\.name), ["WINEDEBUG", "WINEMSYNC", "MTL_HUD_ENABLED", "FINEWINE_METAL_HUD", "FINEWINE_FULLSCREEN",
                        "FEX_HIDEHYPERVISORBIT", "FINEWINE_DLSS", "DXMT_ENABLE_NVEXT", "DXMT_CONFIG"])
        XCTAssertEqual(settings.environmentVariables().first?.value, "-all")
        // The hypervisor flag is hidden unless the prefix says otherwise.
        var shown = PrefixSettings(); shown.hideHypervisor = false
        XCTAssertFalse(shown.environmentVariables().contains { $0.name == "FEX_HIDEHYPERVISORBIT" })

        settings.metalHUD = true
        settings.hideHypervisor = true
        settings.debugChannels = "err+all"
        settings.environment = [EnvironmentVariable(name: "MY_FLAG", value: "1"),
                                EnvironmentVariable(name: "bad name", value: "x")]
        let env = Dictionary(uniqueKeysWithValues: settings.environmentVariables().map { ($0.name, $0.value) })
        XCTAssertEqual(env, ["WINEDEBUG": "err+all", "WINEMSYNC": "1", "MTL_HUD_ENABLED": "1",
                             "FINEWINE_METAL_HUD": "1", "FINEWINE_FULLSCREEN": "space",
                             "FEX_HIDEHYPERVISORBIT": "1", "FINEWINE_DLSS": "1", "DXMT_ENABLE_NVEXT": "1",
                             "DXMT_CONFIG": "dxgi.customVendorId=106b", "MY_FLAG": "1"])
    }

    func testEmptyDebugChannelsFallBackToSilent() {
        var settings = PrefixSettings()
        settings.debugChannels = ""
        let env = Dictionary(uniqueKeysWithValues: settings.environmentVariables().map { ($0.name, $0.value) })
        XCTAssertEqual(env["WINEDEBUG"], "-all")
    }

    func testMSyncIsTheDefaultAndCanBeTurnedOff() throws {
        var settings = PrefixSettings()
        XCTAssertEqual(settings.syncMode, .msync, "measured 4 to 23 times faster than going through the server")
        XCTAssertEqual(env(settings)["WINEMSYNC"], "1")
        settings.syncMode = .standard
        XCTAssertNil(env(settings)["WINEMSYNC"])
        // A prefix saved with the old default keeps what it was saved with.
        let saved = try JSONDecoder().decode(PrefixSettings.self, from: JSONEncoder().encode(settings))
        XCTAssertEqual(saved.syncMode, .standard)
    }

    func testFullScreenIsAMacSpaceByDefault() throws {
        var settings = PrefixSettings()
        XCTAssertEqual(settings.fullScreenMode, .space)
        XCTAssertEqual(env(settings)["FINEWINE_FULLSCREEN"], "space")
        settings.fullScreenMode = .borderless
        XCTAssertEqual(env(settings)["FINEWINE_FULLSCREEN"], "borderless")
        settings.fullScreenMode = .exclusive
        XCTAssertEqual(env(settings)["FINEWINE_FULLSCREEN"], "exclusive")
        let saved = try JSONDecoder().decode(PrefixSettings.self, from: JSONEncoder().encode(settings))
        XCTAssertEqual(saved.fullScreenMode, .exclusive)
        XCTAssertEqual(try JSONDecoder().decode(PrefixSettings.self, from: Data("{}".utf8)).fullScreenMode, .space)
    }

    func testTheMetalOverlayIsAlwaysAvailableAndStartsAsTheSettingSays() {
        var settings = PrefixSettings()
        // Metal only has the overlay in a process started with MTL_HUD_ENABLED, so it is always
        // set; whether the overlay is drawn at the start is a separate variable.
        XCTAssertEqual(env(settings)["MTL_HUD_ENABLED"], "1")
        XCTAssertEqual(env(settings)["FINEWINE_METAL_HUD"], "0")
        settings.metalHUD = true
        XCTAssertEqual(env(settings)["MTL_HUD_ENABLED"], "1")
        XCTAssertEqual(env(settings)["FINEWINE_METAL_HUD"], "1")
    }

    func testGameModeIsOnByDefault() throws {
        XCTAssertTrue(PrefixSettings().gameMode)
        let old = try JSONDecoder().decode(PrefixSettings.self, from: Data("{}".utf8))
        XCTAssertTrue(old.gameMode)
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

    func testRoundedWindowsAreOnUnlessTurnedOff() {
        var settings = PrefixSettings()
        XCTAssertFalse(settings.environmentVariables().contains { $0.0 == "FINEWINE_ROUNDED_WINDOWS" })
        settings.roundedWindows = false
        XCTAssertTrue(settings.environmentVariables().contains { $0.0 == "FINEWINE_ROUNDED_WINDOWS" && $0.1 == "0" })
    }

    func testMetalFXUpscalingIsOnUnlessTurnedOff() throws {
        var settings = PrefixSettings()
        XCTAssertFalse(settings.environmentVariables().contains { $0.0 == "FINEWINE_METALFX_AUTO" })
        settings.metalFXUpscaling = false
        XCTAssertTrue(settings.environmentVariables().contains { $0.0 == "FINEWINE_METALFX_AUTO" && $0.1 == "0" })
        // settings saved before the switch existed have it on
        let old = try JSONDecoder().decode(PrefixSettings.self, from: Data("{}".utf8))
        XCTAssertTrue(old.metalFXUpscaling)
    }

    func testNonUnicodeLanguages() throws {
        let expected: [NonUnicodeLanguage: (String?, Int?)] = [
            .automatic: (nil, nil), .english: ("en_US.UTF-8", 1252), .japanese: ("ja_JP.UTF-8", 932),
            .chineseSimplified: ("zh_CN.UTF-8", 936), .chineseTraditional: ("zh_TW.UTF-8", 950),
            .korean: ("ko_KR.UTF-8", 949),
        ]
        for language in NonUnicodeLanguage.allCases {
            XCTAssertEqual(language.unixLocale, expected[language]?.0, "\(language)")
            XCTAssertEqual(language.codePage, expected[language]?.1, "\(language)")
            XCTAssertFalse(language.displayName.isEmpty)
            if let locale = language.unixLocale {
                // the locale has to exist on the Mac, or setlocale() gives Wine "C" for everything
                XCTAssertTrue(FileManager.default.fileExists(atPath: "/usr/share/locale/\(locale)"), locale)
            }
        }
        var settings = PrefixSettings()
        XCTAssertFalse(settings.environmentVariables().contains { $0.0 == "LC_CTYPE" })
        settings.nonUnicodeLanguage = .korean
        XCTAssertTrue(settings.environmentVariables().contains { $0.0 == "LC_CTYPE" && $0.1 == "ko_KR.UTF-8" })
        // round trip, and settings saved before the choice existed (or by a newer FineWine with
        // a value this one does not know) are automatic
        let saved = try JSONDecoder().decode(PrefixSettings.self, from: JSONEncoder().encode(settings))
        XCTAssertEqual(saved.nonUnicodeLanguage, .korean)
        XCTAssertEqual(try JSONDecoder().decode(PrefixSettings.self, from: Data("{}".utf8)).nonUnicodeLanguage, .automatic)
        let unknown = Data(#"{"nonUnicodeLanguage":"klingon"}"#.utf8)
        XCTAssertEqual(try JSONDecoder().decode(PrefixSettings.self, from: unknown).nonUnicodeLanguage, .automatic)
    }
}
