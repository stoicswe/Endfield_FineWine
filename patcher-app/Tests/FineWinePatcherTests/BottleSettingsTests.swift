import XCTest
@testable import FineWinePatcher

final class BottleSettingsTests: XCTestCase {

    private var workDir: URL!

    override func setUpWithError() throws {
        workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("finewine-bottle-settings-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: workDir)
    }

    // MARK: - BottleSettings Read/Write

    func testReadBottleSettingsFromConf() {
        let conf = """
        [Bottle]
        "WineArch" = "win64"

        [EnvironmentVariables]
        "CX_GRAPHICS_BACKEND" = "d3dmetal"
        "WINEMSYNC" = "1"
        "D3DM_ENABLE_METALFX" = "1"
        "MTL_HUD_ENABLED" = "1"
        "D3DM_MAX_FPS" = "60"
        """
        let settings = BottleSettings.read(from: conf)
        XCTAssertEqual(settings.backend, .d3dmetal)
        XCTAssertTrue(settings.msync)
        XCTAssertTrue(settings.upscaling)
        XCTAssertTrue(settings.metalHUD)
    }

    func testWriteBottleSettingsToBottleDir() throws {
        let confURL = workDir.appendingPathComponent("cxbottle.conf")
        let initialConf = """
        [Bottle]
        "WineArch" = "win64"

        [EnvironmentVariables]
        "CX_GRAPHICS_BACKEND" = "wined3d"
        "WINEMSYNC" = "0"
        """
        try initialConf.write(to: confURL, atomically: true, encoding: .utf8)

        var newSettings = BottleSettings()
        newSettings.backend = .d3dmetal
        newSettings.msync = true
        newSettings.upscaling = true
        newSettings.metalHUD = true

        try newSettings.write(to: workDir, fpsCap: "120")

        let updatedConf = try String(contentsOf: confURL, encoding: .utf8)
        let readBack = BottleSettings.read(from: updatedConf)
        XCTAssertEqual(readBack.backend, .d3dmetal)
        XCTAssertTrue(readBack.msync)
        XCTAssertTrue(readBack.upscaling)
        XCTAssertTrue(readBack.metalHUD)
        XCTAssertEqual(BottleSettings.readFPSCap(from: workDir), "120")

        // Ensure backup was created
        let backupURL = confURL.appendingPathExtension("finewine-settings.bak")
        XCTAssertTrue(FileManager.default.fileExists(atPath: backupURL.path))
    }

    func testUpscalerKeySwitchesWithBackend() throws {
        let confURL = workDir.appendingPathComponent("cxbottle.conf")
        let initialConf = """
        [EnvironmentVariables]
        "CX_GRAPHICS_BACKEND" = "d3dmetal"
        "D3DM_ENABLE_METALFX" = "1"
        """
        try initialConf.write(to: confURL, atomically: true, encoding: .utf8)

        var dxmtSettings = BottleSettings()
        dxmtSettings.backend = .dxmt
        dxmtSettings.upscaling = true

        try dxmtSettings.write(to: workDir)

        let updatedConf = try String(contentsOf: confURL, encoding: .utf8)
        XCTAssertNil(BottleConf.environmentValue(in: updatedConf, key: "D3DM_ENABLE_METALFX"))
        XCTAssertEqual(BottleConf.environmentValue(in: updatedConf, key: "DXMT_ENABLE_NVEXT"), "1")
    }

    // MARK: - AppAlias Tests

    func testAppAliasConfigAndPlistGeneration() throws {
        let customAppName = "TestEndfield_\(UUID().uuidString.prefix(6))"

        // Create a fake bottle dir in temp with a minimal cxbottle.conf and lnk
        let fakeBottle = workDir.appendingPathComponent("FakeBottle")
        let desktopDir = fakeBottle.appendingPathComponent(
            "desktopdata/cxmenu/Desktop.C^5E3A_users_Public_Desktop", isDirectory: true)
        try FileManager.default.createDirectory(at: desktopDir, withIntermediateDirectories: true)
        try "\"BottleID\" = \"DEADBEEF-DEAD-DEAD-DEAD-DEADBEEFCAFE\"".write(
            to: fakeBottle.appendingPathComponent("cxbottle.conf"), atomically: true, encoding: .utf8)
        try Data().write(to: desktopDir.appendingPathComponent("Arknights+Endfield.lnk"))

        let config = AppAlias.Config(
            appName: customAppName,
            bottleName: "FakeBottle",
            bottlePath: fakeBottle.path,
            lnkName: "Arknights+Endfield.lnk",
            environment: ["MTL_HUD_ENABLED": "1", "D3DM_MAX_FPS": "60"]
        )

        let aliasURL = try AppAlias.create(config: config)
        defer { try? AppAlias.remove(named: customAppName) }

        XCTAssertTrue(FileManager.default.fileExists(atPath: aliasURL.path))

        // Check Info.plist
        let infoPlistURL = aliasURL.appendingPathComponent("Contents/Info.plist")
        let plistData = try Data(contentsOf: infoPlistURL)
        let plist = try PropertyListSerialization.propertyList(from: plistData, format: nil) as? [String: Any]
        XCTAssertNotNil(plist)
        XCTAssertEqual(plist?["CFBundleIdentifier"] as? String, AppAlias.bundleIdentifier)
        XCTAssertEqual(plist?["CFBundleName"] as? String, customAppName)
        XCTAssertEqual(plist?["CXHelperAppBottleName"] as? String, "FakeBottle")
        XCTAssertEqual(plist?["CXHelperAppBottleTag"] as? String, "CrossOver-DEADBEEF-DEAD-DEAD-DEAD-DEADBEEFCAFE/")
        XCTAssertTrue((plist?["CrossOverHelperCommand"] as? String)?.contains("Arknights+Endfield.lnk") == true)

        // LSEnvironment should carry through
        let lsEnv = plist?["LSEnvironment"] as? [String: String]
        XCTAssertEqual(lsEnv?["MTL_HUD_ENABLED"], "1")
        XCTAssertEqual(lsEnv?["D3DM_MAX_FPS"], "60")

        // NSPrincipalClass must be CXFBHelperApp for Menu Helper to work
        XCTAssertEqual(plist?["NSPrincipalClass"] as? String, "CXFBHelperApp")
    }
}

