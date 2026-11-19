import XCTest
@testable import FineWineCore

final class RunningProgramsTests: XCTestCase {
    func testNamesProgramsAndLeavesHelpersOut() {
        let programs = [Program(name: "Zenless Zone Zero", windowsPath: #"C:\Program Files\HoYoPlay\games\ZenlessZoneZero Game\ZenlessZoneZero.exe"#)]
        let commands = [
            "/Applications/FineWine.app/Contents/Resources/Runtime/bin/wineserver",
            #"C:\windows\system32\winedevice.exe"#,
            #"C:\windows\system32\explorer.exe /desktop"#,
            #"C:\Program Files (x86)\Steam\steam.exe C:\Program Files\HoYoPlay\launcher.exe"#,
            #"C:\Program Files\HoYoPlay\1.19.0.382\HYP.exe"#,
            #"C:\Program Files\HoYoPlay\1.19.0.382\HYPHelper.exe --type=renderer --lang=en-US"#,
            #"C:\Program Files\HoYoPlay\games\ZenlessZoneZero Game\ZenlessZoneZero.exe login_trace_id=1"#,
            #"C:\Program Files\HoYoPlay\games\ZenlessZoneZero Game\UnityCrashHandler64.exe --attach 1256"#,
            #"C:/Program Files/HoYoPlay/games/ZenlessZoneZero Game/ZenlessZoneZero_Data/Plugins/x86_64/ZFGameBrowser.exe --type=gpu-process"#,
            #"C:\Program Files\HoYoPlay\1.19.0.382\HYP.exe"#,
        ]
        XCTAssertEqual(RunningPrograms.names(commands: commands, programs: programs), ["HYP", "Zenless Zone Zero"])
        XCTAssertEqual(RunningPrograms.names(commands: Array(commands.prefix(3)), programs: programs), [])
        // an installer opened from Finder shows its Mac path
        XCTAssertEqual(RunningPrograms.names(commands: ["/Users/me/Downloads/Game Setup.exe /S", "/bin/zsh -c x"], programs: []), ["Game Setup"])
    }

    func testAGameListedThroughItsLauncherIsNamedByItsFolder() {
        // both entries start the launcher; the game's own file is not listed anywhere
        let programs = [Program(name: "GRYPHLINK", windowsPath: #"C:\Program Files\GRYPHLINK\Launcher.exe"#),
                        Program(name: "Arknights Endfield", windowsPath: #"C:\Program Files\GRYPHLINK\Launcher.exe"#)]
        let commands = [
            #"C:\Program Files\GRYPHLINK\1.6.0\Games.exe --reason=0"#,
            #"C:\Program Files\GRYPHLINK\1.6.0\QtWebEngineProcess.exe --type=renderer --no-sandbox"#,
            #"C:\Program Files\GRYPHLINK\games\Arknights Endfield\Endfield.exe -launcher_lang=en-us"#,
            #"C:\Program Files\GRYPHLINK\games\Arknights Endfield\UnityCrashHandler64.exe --attach 1440"#,
            #"C:\Program Files\GRYPHLINK\games\Arknights Endfield\PlatformProcess.exe -gamehandle=1"#,
        ]
        let names = RunningPrograms.names(commands: commands, programs: programs)
        XCTAssertEqual(names, ["GRYPHLINK", "Arknights Endfield"])
        XCTAssertEqual(DiscordPresence.game(started: "GRYPHLINK", running: names, listed: programs.map(\.name)), "Arknights Endfield")
        // only the launcher is up
        XCTAssertEqual(RunningPrograms.names(commands: Array(commands.prefix(2)), programs: programs), ["GRYPHLINK"])
    }

    private func service(alive: @escaping @Sendable () -> [Int32]) throws -> (PrefixService, Prefix, URL) {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("fw-quit-\(UUID().uuidString)")
        let paths = FineWinePaths(root: home, shortcuts: home.appendingPathComponent("Shortcuts"))
        try paths.ensureDirectories()
        var service = PrefixService(paths: paths)
        service.findProcesses = { _ in alive() }
        let prefix = try service.prefixes.create(name: "Game", runtimeID: nil)
        return (service, prefix, home)
    }

    func testCloseEverythingForcesWhatIsLeftAfterTheGrace() throws {
        let killed = Box<[Int32]>([])
        var (service, prefix, home) = try service(alive: { [42] })
        defer { try? FileManager.default.removeItem(at: home) }
        service.killProcess = { pid in killed.value.append(pid) }
        let waited = Box<TimeInterval>(0)
        let forced = service.closeEverything(in: [prefix], grace: 5) { waited.value += $0 }
        XCTAssertEqual(forced.map(\.id), [prefix.id])
        XCTAssertEqual(killed.value, [42])
        XCTAssertEqual(waited.value, 5, accuracy: 0.01)
    }

    func testCloseEverythingDoesNotForceWhatClosedInTime() throws {
        let polls = Box<Int>(0)
        let killed = Box<[Int32]>([])
        var (service, prefix, home) = try service(alive: { polls.value += 1; return polls.value > 3 ? [] : [42] })
        defer { try? FileManager.default.removeItem(at: home) }
        service.killProcess = { pid in killed.value.append(pid) }
        let waited = Box<TimeInterval>(0)
        let forced = service.closeEverything(in: [prefix], grace: 5) { waited.value += $0 }
        XCTAssertTrue(forced.isEmpty)
        XCTAssertTrue(killed.value.isEmpty)
        XCTAssertLessThan(waited.value, 1.1)
    }
}

private final class Box<T>: @unchecked Sendable {
    var value: T
    init(_ value: T) { self.value = value }
}
