import XCTest
@testable import FineWineCore

final class GameFixesTests: XCTestCase {
    func testKnownGamesGetProtonsSwitches() {
        XCTAssertEqual(GameFixes.fixes(forSteamAppID: "553850").environment, ["WINE_HEAP_ZERO_MEMORY": "1"])
        XCTAssertEqual(GameFixes.fixes(forSteamAppID: "202990").environment, ["WINE_HEAP_DELAY_FREE": "1"])
        XCTAssertEqual(GameFixes.fixes(forSteamAppID: "71230").environment, ["WINE_HEAP_TOP_DOWN": "1"])
        XCTAssertEqual(GameFixes.fixes(forSteamAppID: "298110").environment, ["WINE_CPU_TOPOLOGY": "16"])
        XCTAssertEqual(GameFixes.fixes(forSteamAppID: "1237970").environment, ["OPENSSL_ia32cap": "~0x20000000"])
        XCTAssertEqual(GameFixes.fixes(forSteamAppID: "500810").dllOverrides, ["ddraw": "n,b"])
        XCTAssertTrue(GameFixes.fixes(forSteamAppID: "1").isEmpty)
        // Imperiums: Greek Wars is in one list only here; a game in two gets both.
        XCTAssertEqual(GameFixes.fixes(forSteamAppID: "1183470").environment, ["WINE_HEAP_DELAY_FREE": "1"])
    }

    func testAppIDIsFoundFromTheGamesOwnFiles() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("gamefixes-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let fm = FileManager.default

        // steam_appid.txt two folders above the program
        let game = root.appendingPathComponent("Loose/Game")
        try fm.createDirectory(at: game.appendingPathComponent("bin/x64"), withIntermediateDirectories: true)
        try "553850\n".write(to: game.appendingPathComponent("steam_appid.txt"), atomically: true, encoding: .utf8)
        XCTAssertEqual(SteamAppIDFinder.appID(forProgramAt: game.appendingPathComponent("bin/x64/game.exe")), "553850")

        // a Steam library: the manifest that names the game's folder
        let steamapps = root.appendingPathComponent("Library/steamapps")
        try fm.createDirectory(at: steamapps.appendingPathComponent("common/Far Cry 4/bin"), withIntermediateDirectories: true)
        try "\"AppState\"\n{\n\t\"appid\"\t\t\"298110\"\n\t\"installdir\"\t\t\"Far Cry 4\"\n}\n"
            .write(to: steamapps.appendingPathComponent("appmanifest_298110.acf"), atomically: true, encoding: .utf8)
        try "\"AppState\"\n{\n\t\"installdir\"\t\t\"Other Game\"\n}\n"
            .write(to: steamapps.appendingPathComponent("appmanifest_7.acf"), atomically: true, encoding: .utf8)
        XCTAssertEqual(SteamAppIDFinder.appID(forProgramAt: steamapps.appendingPathComponent("common/Far Cry 4/bin/FarCry4.exe")), "298110")

        // nothing to go by
        try fm.createDirectory(at: root.appendingPathComponent("Plain"), withIntermediateDirectories: true)
        XCTAssertNil(SteamAppIDFinder.appID(forProgramAt: root.appendingPathComponent("Plain/app.exe")))
        XCTAssertNil(SteamAppIDFinder.digits("12ab"))
    }

    func testHideWineExportsIsOffAndSendsItsSwitchWhenOn() throws {
        var settings = PrefixSettings()
        XCTAssertFalse(settings.hideWineExports)
        XCTAssertTrue(settings.gameFixes)
        XCTAssertNil(settings.environmentVariables().first { $0.0 == "FINEWINE_HIDE_WINE_EXPORTS" })
        settings.hideWineExports = true
        XCTAssertEqual(settings.environmentVariables().first { $0.0 == "FINEWINE_HIDE_WINE_EXPORTS" }?.1, "1")
        XCTAssertNil(settings.environmentVariables(supporting: []).first { $0.0 == "FINEWINE_HIDE_WINE_EXPORTS" })
    }
}
