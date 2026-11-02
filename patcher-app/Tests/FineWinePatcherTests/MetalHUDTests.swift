import XCTest
@testable import FineWinePatcher

final class MetalHUDTests: XCTestCase {

    private var workDir: URL!

    override func setUpWithError() throws {
        workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("finewine-metal-hud-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: workDir)
    }

    // MARK: - cxbottle.conf

    func testAddsHUDKeyToExistingEnvironmentSection() {
        let original = """
        [Bottle]
        "WineArch" = "win64"

        [EnvironmentVariables]
        "WINEMSYNC" = "1"
        "CX_GRAPHICS_BACKEND" = "dxmt"
        ;;"PROMPT" = "$p$g"

        [Wine]
        "Version" = "11.0"
        """
        let updated = BottleConf.setEnvironmentValue(original, key: "MTL_HUD_ENABLED", value: "1")
        XCTAssertEqual(BottleConf.environmentValue(in: updated, key: "MTL_HUD_ENABLED"), "1")
        XCTAssertEqual(BottleConf.environmentValue(in: updated, key: "WINEMSYNC"), "1")
        XCTAssertTrue(updated.contains(";;\"PROMPT\" = \"$p$g\""))
        XCTAssertTrue(updated.contains("[Wine]"))
        XCTAssertFalse(MetalHUD.isEnabled(in: original))
        XCTAssertTrue(MetalHUD.isEnabled(in: updated))
    }

    func testCreatesEnvironmentSectionWhenMissing() {
        let original = """
        [Bottle]
        "WineArch" = "win64"
        """
        let updated = BottleConf.setEnvironmentValue(original, key: "MTL_HUD_ENABLED", value: "1")
        XCTAssertTrue(updated.contains("[EnvironmentVariables]"))
        XCTAssertEqual(BottleConf.environmentValue(in: updated, key: "MTL_HUD_ENABLED"), "1")
    }

    func testRemovesHUDKeyAndRestoresPrevious() {
        let original = """
        [EnvironmentVariables]
        "MTL_HUD_ENABLED" = "1"
        "WINEMSYNC" = "1"
        """
        let removed = BottleConf.setEnvironmentValue(original, key: "MTL_HUD_ENABLED", value: nil)
        XCTAssertNil(BottleConf.environmentValue(in: removed, key: "MTL_HUD_ENABLED"))
        XCTAssertEqual(BottleConf.environmentValue(in: removed, key: "WINEMSYNC"), "1")

        let restored = BottleConf.setEnvironmentValue(original, key: "MTL_HUD_ENABLED", value: "0")
        XCTAssertEqual(BottleConf.environmentValue(in: restored, key: "MTL_HUD_ENABLED"), "0")
        XCTAssertFalse(MetalHUD.isEnabled(in: restored))
    }

    func testIgnoresCommentedHUDKey() {
        let original = """
        [EnvironmentVariables]
        ;;"MTL_HUD_ENABLED" = "1"
        "WINEMSYNC" = "1"
        """
        XCTAssertNil(BottleConf.environmentValue(in: original, key: "MTL_HUD_ENABLED"))
        let updated = BottleConf.setEnvironmentValue(original, key: "MTL_HUD_ENABLED", value: "1")
        XCTAssertTrue(updated.contains(";;\"MTL_HUD_ENABLED\" = \"1\""))
        XCTAssertEqual(BottleConf.environmentValue(in: updated, key: "MTL_HUD_ENABLED"), "1")
    }

    func testPreservesCRLF() {
        let original = "[EnvironmentVariables]\r\n\"WINEMSYNC\" = \"1\"\r\n"
        let updated = BottleConf.setEnvironmentValue(original, key: "MTL_HUD_ENABLED", value: "1")
        XCTAssertTrue(updated.contains("\r\n"))
        XCTAssertEqual(BottleConf.environmentValue(in: updated, key: "MTL_HUD_ENABLED"), "1")
    }

    func testSetFPSCapAndPlanReadsIt() throws {
        let bottle = try makeBottle()
        try MetalHUD.setFPSCap(bottle: bottle, fps: "60")
        let plan = MetalHUD.plan(for: bottle, includeDefaultLauncherRoots: false)
        XCTAssertEqual(plan?.maxFPS, "60")

        try MetalHUD.setFPSCap(bottle: bottle, fps: nil)
        let unplan = MetalHUD.plan(for: bottle, includeDefaultLauncherRoots: false)
        XCTAssertNil(unplan?.maxFPS)
    }

    // MARK: - related Windows apps

    func testFindsEndfieldGamesAndGryphlinkButIgnoresUnrelatedLauncher() throws {
        let bottle = try makeBottle()
        let driveC = bottle.appendingPathComponent("drive_c", isDirectory: true)
        try writeFakeExe(driveC.appendingPathComponent("Program Files/GRYPHLINK/1.6.0/Games.exe"))
        try writeFakeExe(driveC.appendingPathComponent("Program Files/GRYPHLINK/1.6.0/Launcher.exe"))
        try writeFakeExe(driveC.appendingPathComponent("Program Files/GRYPHLINK/games/Arknights Endfield/Endfield.exe"))
        try writeFakeExe(driveC.appendingPathComponent("users/crossover/AppData/Roaming/XXMI Launcher/XXMI Launcher.exe"))
        try writeFakeExe(driveC.appendingPathComponent("Program Files/Git/cmd/Launcher.exe"))

        let related = MetalHUD.findRelatedApps(bottle: bottle)
        let names = Set(related.map { $0.fileName.lowercased() })
        XCTAssertTrue(names.contains("endfield.exe"))
        XCTAssertTrue(names.contains("games.exe"))
        XCTAssertTrue(names.contains("launcher.exe"))
        XCTAssertTrue(names.contains("xxmi launcher.exe"))
        XCTAssertEqual(related.filter { $0.fileName.lowercased() == "launcher.exe" }.count, 1)

        let games = related.first { $0.fileName.lowercased() == "games.exe" }
        XCTAssertEqual(games?.kind, .launcherUI)
        XCTAssertEqual(games?.windowsPath, "C:\\Program Files\\GRYPHLINK\\1.6.0\\Games.exe")
        XCTAssertEqual(related.first { $0.fileName.lowercased() == "endfield.exe" }?.kind, .game)
    }

    func testClassifiesShippingBinaryAsGame() throws {
        let driveC = workDir.appendingPathComponent("drive_c", isDirectory: true)
        let url = driveC.appendingPathComponent("game/EM-Win64-Shipping.exe")
        try writeFakeExe(url)
        let app = MetalHUD.relatedApp(at: url, driveC: driveC)
        XCTAssertEqual(app?.kind, .game)
        XCTAssertEqual(app?.windowsPath, "C:\\game\\EM-Win64-Shipping.exe")
    }

    // MARK: - apply / revert

    func testApplyAndRevertBottleAndMacLauncher() throws {
        let bottle = try makeBottle()
        let driveC = bottle.appendingPathComponent("drive_c", isDirectory: true)
        try writeFakeExe(driveC.appendingPathComponent("Program Files/GRYPHLINK/games/Arknights Endfield/Endfield.exe"))
        try writeFakeExe(driveC.appendingPathComponent("Program Files/GRYPHLINK/1.6.0/Games.exe"))

        let launcherRoot = workDir.appendingPathComponent("MacLaunchers", isDirectory: true)
        let stub = try makeUnsignedApp(
            named: "Arknights Endfield.app",
            in: launcherRoot,
            plistExtras: ["CXStart": "C:\\Program Files\\GRYPHLINK\\games\\Arknights Endfield\\Endfield.exe"]
        )

        guard let plan = MetalHUD.plan(for: bottle, extraLauncherRoots: [launcherRoot],
                                       includeDefaultLauncherRoots: false) else {
            return XCTFail("expected a HUD plan")
        }
        XCTAssertFalse(plan.currentlyEnabled)
        XCTAssertEqual(Set(plan.related.map { $0.fileName.lowercased() }), ["endfield.exe", "games.exe"])
        XCTAssertEqual(plan.macLaunchers.map(\.name), ["Arknights Endfield"])

        let state = try MetalHUD.apply(plan: plan)
        XCTAssertNil(state.previous)
        let conf = try String(contentsOf: bottle.appendingPathComponent("cxbottle.conf"), encoding: .utf8)
        XCTAssertTrue(MetalHUD.isEnabled(in: conf))
        XCTAssertEqual(try MetalHUD.readLSEnvironment(stub)["MTL_HUD_ENABLED"], "1")
        XCTAssertNotNil(MetalHUD.readState(bottle: bottle))

        try MetalHUD.revert(bottle: bottle)
        let reverted = try String(contentsOf: bottle.appendingPathComponent("cxbottle.conf"), encoding: .utf8)
        XCTAssertFalse(MetalHUD.isEnabled(in: reverted))
        XCTAssertEqual(BottleConf.environmentValue(in: reverted, key: "WINEMSYNC"), "1")
        XCTAssertNil(try MetalHUD.readLSEnvironment(stub)["MTL_HUD_ENABLED"])
        XCTAssertNil(MetalHUD.readState(bottle: bottle))
    }

    func testMacLauncherMatchesGamesExeInPlist() throws {
        let root = workDir.appendingPathComponent("stubs", isDirectory: true)
        _ = try makeUnsignedApp(
            named: "GRYPHLINK.app",
            in: root,
            plistExtras: ["CXCommand": "--cx-app Games.exe"]
        )
        let matches = MetalHUD.findMacLaunchers(
            bottle: workDir.appendingPathComponent("Endfield12Sep"),
            extraRoots: [root],
            includeDefaultLauncherRoots: false
        )
        XCTAssertEqual(matches.count, 1)
        XCTAssertEqual(matches.first?.reason, "targets Games.exe")
    }

    // MARK: - fixtures

    private func makeBottle() throws -> URL {
        let bottle = workDir.appendingPathComponent("Arknights Endfield", isDirectory: true)
        try FileManager.default.createDirectory(at: bottle, withIntermediateDirectories: true)
        let conf = """
        [Bottle]
        "WineArch" = "win64"

        [EnvironmentVariables]
        "WINEMSYNC" = "1"
        "CX_GRAPHICS_BACKEND" = "dxmt"
        """
        try conf.write(to: bottle.appendingPathComponent("cxbottle.conf"), atomically: true, encoding: .utf8)
        return bottle
    }

    private func writeFakeExe(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("MZ".utf8).write(to: url)
    }

    private func makeUnsignedApp(named: String, in root: URL, plistExtras: [String: String]) throws -> URL {
        let app = root.appendingPathComponent(named, isDirectory: true)
        let contents = app.appendingPathComponent("Contents", isDirectory: true)
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        var plist: [String: Any] = [
            "CFBundleIdentifier": "com.example.\(named)",
            "CFBundleName": (named as NSString).deletingPathExtension,
        ]
        for (k, v) in plistExtras { plist[k] = v }
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try data.write(to: contents.appendingPathComponent("Info.plist"))
        return app
    }
}
