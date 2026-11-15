import XCTest
@testable import FineWineCore

final class SteamStandInTests: XCTestCase {
    func testOnlyHoYoverseProgramsAreRecognised() {
        XCTAssertEqual(SteamStandIn.appID(forWindowsPath: #"C:\Program Files\HoYoPlay\games\ZenlessZoneZero Game\ZenlessZoneZero.exe"#), "zenlesszonezero")
        XCTAssertEqual(SteamStandIn.appID(forWindowsPath: #"D:\Games\GENSHINIMPACT.EXE"#), "genshin")
        XCTAssertEqual(SteamStandIn.appID(forWindowsPath: #"C:\x\BH3.exe"#), "zenlesszonezero")
        XCTAssertEqual(SteamStandIn.appID(forWindowsPath: #"C:\Program Files\HoYoPlay\launcher.exe"#), "zenlesszonezero")
        XCTAssertNil(SteamStandIn.appID(forWindowsPath: #"C:\Program Files\HoYoPlay\games\Some Game\launcher.exe"#))
        XCTAssertNil(SteamStandIn.appID(forWindowsPath: #"C:\Other\launcher.exe"#))
        XCTAssertNil(SteamStandIn.appID(forWindowsPath: #"C:\Game\Game.exe"#))
    }

    private func fixture(helper: Bool = true) -> (Sandbox, WineRuntime, Prefix, Program) {
        let sandbox = Sandbox()
        let root = sandbox.makeRuntime()
        if helper { sandbox.write(Data("MZ stand-in".utf8), to: root.appendingPathComponent(SteamStandIn.runtimePath)) }
        let runtime = WineRuntime(manifest: RuntimeManifest(id: "r", name: "R", version: "1", wineVersion: "11.21"), root: root, kind: .managed)
        let prefix = Prefix(metadata: PrefixMetadata(name: "P", runtimeID: "r"), directory: sandbox.root.appendingPathComponent("pfx"))
        return (sandbox, runtime, prefix, Program(name: "ZZZ", windowsPath: #"C:\ZZZ\ZenlessZoneZero.exe"#, arguments: ["-x"]))
    }

    func testARecognisedGameIsStartedThroughTheStandIn() throws {
        let (sandbox, runtime, prefix, program) = fixture(); _ = sandbox
        let plan = try LaunchPlanner(runtime: runtime, prefix: prefix, baseEnvironment: [:]).plan(for: program)
        XCTAssertEqual(plan.arguments, [SteamStandIn.windowsPath, program.windowsPath, "-x"])
        XCTAssertEqual(plan.environment["SteamGameId"], "zenlesszonezero")
        XCTAssertEqual(plan.environment["SteamAppId"], "zenlesszonezero")
    }

    func testOtherProgramsTheSettingOffAndRuntimesWithoutItAreLeftAlone() throws {
        var (sandbox, runtime, prefix, program) = fixture()
        let other = Program(name: "G", windowsPath: #"C:\Game\Game.exe"#)
        var plan = try LaunchPlanner(runtime: runtime, prefix: prefix, baseEnvironment: [:]).plan(for: other)
        XCTAssertEqual(plan.arguments, [other.windowsPath])
        XCTAssertNil(plan.environment["SteamGameId"])

        prefix.metadata.settings.steamForHoYoverse = false
        plan = try LaunchPlanner(runtime: runtime, prefix: prefix, baseEnvironment: [:]).plan(for: program)
        XCTAssertEqual(plan.arguments.first, program.windowsPath)

        (sandbox, runtime, prefix, program) = fixture(helper: false)
        plan = try LaunchPlanner(runtime: runtime, prefix: prefix, baseEnvironment: [:]).plan(for: program)
        XCTAssertEqual(plan.arguments.first, program.windowsPath)
        XCTAssertNil(plan.environment["SteamGameId"])
    }

    func testTheStandInIsCopiedIntoThePrefixButNeverOverARealSteam() throws {
        let (sandbox, runtime, prefix, _) = fixture()
        let service = PrefixService(paths: sandbox.paths)
        let target = WindowsPath.macURL(for: SteamStandIn.windowsPath, inPrefix: prefix.directory)!
        try service.installSteamStandIn(from: runtime, in: prefix)
        XCTAssertEqual(try Data(contentsOf: target), Data("MZ stand-in".utf8))

        // A real Steam: other files beside a different steam.exe.
        sandbox.write(Data("real".utf8), to: target)
        sandbox.write(Data(), to: target.deletingLastPathComponent().appendingPathComponent("steamclient64.dll"))
        try service.installSteamStandIn(from: runtime, in: prefix)
        XCTAssertEqual(try Data(contentsOf: target), Data("real".utf8))
    }
}
