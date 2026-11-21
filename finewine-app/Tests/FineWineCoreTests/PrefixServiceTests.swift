import XCTest
import AppKit
@testable import FineWineCore

final class PrefixServiceTests: XCTestCase {
    private struct Fixture {
        let sandbox = Sandbox()
        let runner = RecordingRunner()
        let service: PrefixService
        let runtime: WineRuntime

        init() {
            service = PrefixService(paths: sandbox.paths, runner: runner)
            let source = sandbox.makeRuntime(manifest: RuntimeManifest(id: "fw", name: "FineWine", version: "1", wineVersion: "11.21"))
            runtime = try! service.runtimes.installManaged(from: source)
        }

        func prefixWithGame() throws -> Prefix {
            let prefix = try service.createPrefix(name: "Games", runtime: runtime, profile: nil)
            sandbox.write(PEBuilder.make(images: [(16, 16, [1, 2, 3])]),
                          to: prefix.driveC.appendingPathComponent("Game/Game.exe"))
            return try service.addProgram(Program(name: "Game", windowsPath: #"C:\Game\Game.exe"#), to: prefix)
        }
    }

    func testCreatePrefixRunsWinebootThenImportsSettings() throws {
        let f = Fixture()
        var imported = ""
        f.runner.onRun = { plan in
            if plan.arguments.first == "regedit" {
                let data = try! Data(contentsOf: URL(fileURLWithPath: plan.arguments[2]))
                imported = String(data: data.dropFirst(2), encoding: .utf16LittleEndian) ?? ""
            }
        }
        let prefix = try f.service.createPrefix(name: "Endfield", runtime: f.runtime, profile: .endfield)

        XCTAssertEqual(f.runner.ran.map { Array($0.arguments.prefix(2)) }, [["wineboot", "--init"], ["regedit", "/S"]])
        XCTAssertEqual(f.runner.ran[0].environment["WINEPREFIX"], prefix.directory.path)
        XCTAssertEqual(f.runner.ran[0].environment["FEX_HIDEHYPERVISORBIT"], "1")
        XCTAssertTrue(imported.contains("\"CurrentBuild\"=\"26100\""), imported)
        XCTAssertTrue(imported.contains("\"Version\"=\"win11\""))
        XCTAssertEqual(prefix.metadata.appliedSettings, prefix.metadata.settings)
        XCTAssertEqual(f.service.prefixes.prefix(id: prefix.id)?.metadata.appliedSettings, prefix.metadata.settings)
        // The temporary .reg file is cleaned up.
        XCTAssertFalse(FileManager.default.fileExists(atPath: prefix.directory.appendingPathComponent(".finewine-settings.reg").path))
    }

    func testEveryNewPrefixHasDLSSThroughMetalFXOn() throws {
        let f = Fixture()
        // With no profile, with each built-in profile, and with a user profile that says nothing
        // about it: the setting is on, and the launch environment switches DXMT's support on.
        f.sandbox.write(#"{"id":"bare","name":"Bare","settings":{"dpi":96}}"#,
                        to: f.sandbox.paths.profiles.appendingPathComponent("bare.json"))
        let profiles: [GameProfile?] = [nil] + f.service.profiles.list().map(Optional.some)
        XCTAssertTrue(profiles.contains { $0?.id == "bare" })
        for (index, profile) in profiles.enumerated() {
            let prefix = try f.service.createPrefix(name: "P\(index)", runtime: f.runtime, profile: profile)
            XCTAssertTrue(prefix.metadata.settings.dlssThroughMetalFX, profile?.id ?? "no profile")
            XCTAssertEqual(prefix.metadata.settings.graphicsBackend, .dxmt, profile?.id ?? "no profile")
            XCTAssertEqual(try f.service.planner(for: prefix).environment()["DXMT_ENABLE_NVEXT"], "1",
                           profile?.id ?? "no profile")
        }
    }

    func testAFailedSetupLeavesNoPrefixBehind() {
        let f = Fixture()
        f.runner.status = { $0.arguments.first == "wineboot" ? 1 : 0 }
        XCTAssertThrowsError(try f.service.createPrefix(name: "Broken", runtime: f.runtime, profile: nil)) { error in
            XCTAssertTrue(error.localizedDescription.contains("exit status 1"))
            XCTAssertTrue(error.localizedDescription.contains("line two"), "the tail of Wine's output is included")
        }
        XCTAssertEqual(f.service.prefixes.list(), [])
        f.runner.status = { _ in 0 }
        XCTAssertNoThrow(try f.service.createPrefix(name: "Broken", runtime: f.runtime, profile: nil),
                         "the name is free again")
    }

    func testCreateRejectsAnUnusableRuntime() {
        let f = Fixture()
        let broken = WineRuntime(manifest: RuntimeManifest(id: "x", name: "X", version: "", wineVersion: ""),
                                 root: f.sandbox.makeRuntime(wine: false), kind: .external)
        XCTAssertThrowsError(try f.service.createPrefix(name: "P", runtime: broken, profile: nil))
        XCTAssertEqual(f.runner.ran.count, 0)
        XCTAssertEqual(f.service.prefixes.list(), [])
    }

    func testApplySettingsValidatesAndDeletesRemovedOverrides() throws {
        let f = Fixture()
        var prefix = try f.service.createPrefix(name: "P", runtime: f.runtime, profile: nil)
        prefix.metadata.settings.dllOverrides = [DLLOverride(name: "dxgi", order: .native)]
        prefix = try f.service.applySettings(to: prefix)

        var imported = ""
        f.runner.onRun = { plan in
            let data = try! Data(contentsOf: URL(fileURLWithPath: plan.arguments[2]))
            imported = String(data: data.dropFirst(2), encoding: .utf16LittleEndian) ?? ""
        }
        prefix.metadata.settings.dllOverrides = []
        prefix = try f.service.applySettings(to: prefix)
        XCTAssertTrue(imported.contains("\"dxgi\"=-"), imported)

        let runsBefore = f.runner.ran.count
        prefix.metadata.settings.automaticDPI = false
        prefix.metadata.settings.dpi = 5
        XCTAssertThrowsError(try f.service.applySettings(to: prefix))
        XCTAssertEqual(f.runner.ran.count, runsBefore, "invalid settings never reach Wine")
    }

    func testMacStylingIsAppliedAndRefreshedWhenTheMacAppearanceChanges() throws {
        let f = Fixture()
        let light = MacAppearance(isDark: false, accentRed: 0, accentGreen: 122, accentBlue: 255)
        let dark = MacAppearance(isDark: true, accentRed: 0, accentGreen: 122, accentBlue: 255)
        var imported = ""
        f.runner.onRun = { plan in
            guard plan.arguments.first == "regedit" else { return }
            let data = try! Data(contentsOf: URL(fileURLWithPath: plan.arguments[2]))
            imported = String(data: data.dropFirst(2), encoding: .utf16LittleEndian) ?? ""
        }
        var prefix = try f.service.createPrefix(name: "P", runtime: f.runtime, profile: nil, appearance: light)
        XCTAssertTrue(imported.contains("\"Hilight\"=\"0 122 255\""), imported)
        XCTAssertTrue(imported.contains("\"ThemeActive\"=\"1\""))
        XCTAssertEqual(prefix.metadata.appliedAppearance, light)
        XCTAssertFalse(f.service.needsAppearanceRefresh(prefix, current: light))
        XCTAssertTrue(f.service.needsAppearanceRefresh(prefix, current: dark))

        prefix = try f.service.applySettings(to: prefix, appearance: dark)
        XCTAssertTrue(imported.contains("\"Window\"=\"30 30 30\""))
        XCTAssertTrue(imported.contains("\"ThemeActive\"=\"0\""))
        XCTAssertEqual(f.service.prefixes.prefix(id: prefix.id)?.metadata.appliedAppearance, dark)

        prefix.metadata.settings.macAppearance = false
        prefix = try f.service.applySettings(to: prefix, appearance: dark)
        XCTAssertTrue(imported.contains("\"Hilight\"=-"))
        XCTAssertEqual(prefix.metadata.appliedAppearance, dark, "still recorded: the automatic DPI used its display scale")
        XCTAssertFalse(f.service.needsAppearanceRefresh(prefix, current: light), "styling is off, so light or dark no longer matters")
        var onASharperDisplay = light
        onASharperDisplay.displayScale = 3
        XCTAssertTrue(f.service.needsAppearanceRefresh(prefix, current: onASharperDisplay), "the automatic DPI is out of date")
        prefix.metadata.settings.automaticDPI = false
        XCTAssertFalse(f.service.needsAppearanceRefresh(prefix, current: onASharperDisplay))
    }

    func testAFailedApplyDoesNotRecordTheSettingsAsApplied() throws {
        let f = Fixture()
        var prefix = try f.service.createPrefix(name: "P", runtime: f.runtime, profile: nil)
        let applied = prefix.metadata.appliedSettings
        f.runner.status = { _ in 2 }
        prefix.metadata.settings.retinaMode = true
        XCTAssertThrowsError(try f.service.applySettings(to: prefix))
        XCTAssertEqual(f.service.prefixes.prefix(id: prefix.id)?.metadata.appliedSettings, applied)
    }

    func testRuntimeLookupErrors() throws {
        let f = Fixture()
        var prefix = try f.service.createPrefix(name: "P", runtime: f.runtime, profile: nil)
        prefix.metadata.runtimeID = nil
        XCTAssertThrowsError(try f.service.runtime(for: prefix)) { XCTAssertTrue($0.localizedDescription.contains("no runtime")) }
        prefix.metadata.runtimeID = "gone"
        XCTAssertThrowsError(try f.service.runtime(for: prefix)) { XCTAssertTrue($0.localizedDescription.contains("no longer installed")) }
    }

    func testAddProgramUpdatesAnExistingEntryForTheSameExecutable() throws {
        let f = Fixture()
        var prefix = try f.prefixWithGame()
        let original = prefix.metadata.programs[0]
        prefix = try f.service.addProgram(Program(name: "Game (renamed)", windowsPath: #"c:\game\GAME.exe"#, arguments: ["-x"]), to: prefix)
        XCTAssertEqual(prefix.metadata.programs.count, 1)
        XCTAssertEqual(prefix.metadata.programs[0].id, original.id)
        XCTAssertEqual(prefix.metadata.programs[0].name, "Game (renamed)")
        XCTAssertEqual(prefix.metadata.programs[0].arguments, ["-x"])
    }

    func testTheWindowsDesktopIsKeptInThePrefixAndItsShortcutsBroughtBack() throws {
        let f = Fixture()
        let prefix = try f.prefixWithGame()
        let fm = FileManager.default
        // As Wine sets a prefix up: the Windows desktop is a link to the Mac's.
        let macDesktop = f.sandbox.root.appendingPathComponent("MacDesktop")
        let winDesktop = prefix.driveC.appendingPathComponent("users/me/Desktop")
        try fm.createDirectory(at: macDesktop, withIntermediateDirectories: true)
        try fm.createDirectory(at: winDesktop.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.createSymbolicLink(at: winDesktop, withDestinationURL: macDesktop)
        // An installer's shortcut to a program in this prefix, one to a program that is not, and a file of the user's.
        f.sandbox.write(LinkBuilder.make(target: #"C:\Game\Game.exe"#), to: macDesktop.appendingPathComponent("Game.lnk"))
        f.sandbox.write(LinkBuilder.make(target: #"C:\Elsewhere\Other.exe"#), to: macDesktop.appendingPathComponent("Other.lnk"))
        f.sandbox.write("mine", to: macDesktop.appendingPathComponent("notes.txt"))

        XCTAssertEqual(f.service.keepDesktopInPrefix(prefix), 1)
        XCTAssertNil(try? fm.destinationOfSymbolicLink(atPath: winDesktop.path), "a folder of its own now")
        XCTAssertTrue(fm.fileExists(atPath: winDesktop.appendingPathComponent("Game.lnk").path))
        XCTAssertEqual(try fm.contentsOfDirectory(atPath: macDesktop.path).sorted(), ["Other.lnk", "notes.txt"])
        XCTAssertEqual(f.service.keepDesktopInPrefix(prefix), 0, "nothing left to do the second time")
    }

    func testAnIconFileBecomesAnAppIconAndAMissingOneDoesNot() throws {
        let sandbox = Sandbox()
        // An .ico with one PNG image in it, as modern icons are stored.
        let image = NSImage(size: NSSize(width: 64, height: 64))
        image.lockFocus(); NSColor.systemPurple.setFill(); NSRect(x: 0, y: 0, width: 64, height: 64).fill(); image.unlockFocus()
        let png = try XCTUnwrap(ICNS.png(from: image, pixelSize: 64))
        var ico: [UInt8] = [0, 0, 1, 0, 1, 0, 64, 64, 0, 0, 1, 0, 32, 0]
        ico += Bytes.le32(png.count) + Bytes.le32(22)
        let file = sandbox.root.appendingPathComponent("gameicon.ico")
        sandbox.write(Data(ico) + png, to: file)
        let icns = try XCTUnwrap(ICNS.data(fromIconFile: file))
        XCTAssertEqual(String(decoding: icns.prefix(4), as: UTF8.self), "icns")
        XCTAssertNil(ICNS.data(fromIconFile: sandbox.root.appendingPathComponent("missing.ico")))
    }

    func testAPrefixGetsTheRuntimesEmulatorWhenItsOwnCopyIsOlder() throws {
        let f = Fixture()
        let prefix = try f.prefixWithGame()
        let inRuntime = f.runtime.root.appendingPathComponent("lib/wine/aarch64-windows/xtajit64.dll")
        let inPrefix = prefix.driveC.appendingPathComponent("windows/system32/xtajit64.dll")
        f.sandbox.write("new emulator", to: inRuntime)
        XCTAssertFalse(f.service.refreshEmulator(in: prefix, from: f.runtime), "a prefix without one is not given one")
        f.sandbox.write("old emulator", to: inPrefix)
        XCTAssertTrue(f.service.refreshEmulator(in: prefix, from: f.runtime))
        XCTAssertEqual(try String(contentsOf: inPrefix, encoding: .utf8), "new emulator")
        XCTAssertFalse(f.service.refreshEmulator(in: prefix, from: f.runtime), "nothing to do when they match")
    }

    func testAPrefixIsGivenThe32BitEmulatorWhenTheRuntimeHasOne() throws {
        let f = Fixture()
        let prefix = try f.prefixWithGame()
        let windows = f.runtime.root.appendingPathComponent("lib/wine")
        let inPrefix = prefix.driveC.appendingPathComponent("windows/system32/xtajit.dll")
        XCTAssertFalse(f.runtime.runs32BitPrograms)
        f.sandbox.write("emulator 32", to: windows.appendingPathComponent("aarch64-windows/xtajit.dll"))
        XCTAssertFalse(f.runtime.runs32BitPrograms, "the emulator alone is not enough")
        f.sandbox.write("ntdll", to: windows.appendingPathComponent("i386-windows/ntdll.dll"))
        XCTAssertTrue(f.runtime.runs32BitPrograms)
        f.sandbox.write("x", to: prefix.driveC.appendingPathComponent("windows/system32/kernel32.dll"))
        XCTAssertTrue(f.service.refreshEmulator(in: prefix, from: f.runtime), "an older prefix gets the 32-bit emulator")
        XCTAssertEqual(try String(contentsOf: inPrefix, encoding: .utf8), "emulator 32")
        XCTAssertFalse(f.service.refreshEmulator(in: prefix, from: f.runtime))
    }

    func testImportDiscoveredProgramsAddsOnlyNewOnes() throws {
        let f = Fixture()
        var prefix = try f.prefixWithGame()
        let menu = prefix.driveC.appendingPathComponent("ProgramData/Microsoft/Windows/Start Menu/Programs")
        f.sandbox.write(LinkBuilder.make(target: #"C:\Game\Game.exe"#), to: menu.appendingPathComponent("Game.lnk"))
        f.sandbox.write(LinkBuilder.make(target: #"C:\Tools\Editor.exe"#, workingDirectory: #"C:\Tools"#, arguments: "-safe \"my file\""),
                        to: menu.appendingPathComponent("Editor.lnk"))
        var added = 0
        (prefix, added) = try f.service.importDiscoveredPrograms(into: prefix)
        XCTAssertEqual(added, 1)
        let editor = try XCTUnwrap(prefix.metadata.programs.first { $0.name == "Editor" })
        XCTAssertEqual(editor.arguments, ["-safe", "my file"])
        XCTAssertEqual(editor.workingDirectory, #"C:\Tools"#)
        XCTAssertEqual(try f.service.importDiscoveredPrograms(into: prefix).added, 0)
    }

    func testShortcutLifecycle() throws {
        let f = Fixture()
        var prefix = try f.prefixWithGame()
        let id = prefix.metadata.programs[0].id
        prefix = try f.service.createShortcut(for: id, in: prefix)
        let path = try XCTUnwrap(prefix.metadata.programs[0].shortcutPath)
        XCTAssertTrue(path.hasPrefix(f.sandbox.paths.shortcuts.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: path))
        XCTAssertEqual(f.service.prefixes.prefix(id: prefix.id)?.metadata.programs[0].shortcutPath, path)

        prefix = try f.service.removeShortcut(for: id, in: prefix)
        XCTAssertNil(prefix.metadata.programs[0].shortcutPath)
        XCTAssertFalse(FileManager.default.fileExists(atPath: path))
        XCTAssertThrowsError(try f.service.createShortcut(for: UUID(), in: prefix))
    }

    func testRemoveProgramAlsoRemovesItsShortcut() throws {
        let f = Fixture()
        var prefix = try f.prefixWithGame()
        let id = prefix.metadata.programs[0].id
        prefix = try f.service.createShortcut(for: id, in: prefix)
        prefix = try f.service.removeProgram(id: id, from: prefix)
        XCTAssertEqual(prefix.metadata.programs, [])
        XCTAssertEqual(f.service.shortcuts.list(), [])
    }

    func testAMemoryTraceLaunchGetsAFolderBesideItsLog() throws {
        let f = Fixture()
        let prefix = try f.prefixWithGame()
        _ = try f.service.launch(programID: prefix.metadata.programs[0].id, in: prefix, memoryTrace: true)
        let started = try XCTUnwrap(f.runner.started.first)
        let log = try XCTUnwrap(started.logFile)
        let folder = f.service.memoryTraceFolder(forLog: log)
        XCTAssertEqual(started.plan.environment["FINEWINE_MEMORY_TRACE"], folder.path)
        XCTAssertTrue(folder.lastPathComponent.hasSuffix(" Game memory"))
        XCTAssertEqual(folder.deletingLastPathComponent(), log.deletingLastPathComponent())
        var isDir: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDir) && isDir.boolValue,
                      "the runtime does not make the folder, so it must exist before the program starts")
    }

    func testLaunchStartsTheProgramWithALog() throws {
        let f = Fixture()
        let prefix = try f.prefixWithGame()
        let pid = try f.service.launch(programID: prefix.metadata.programs[0].id, in: prefix)
        XCTAssertEqual(pid, 4242)
        let started = try XCTUnwrap(f.runner.started.first)
        XCTAssertEqual(started.plan.arguments, [#"C:\Game\Game.exe"#])
        let log = try XCTUnwrap(started.logFile)
        XCTAssertTrue(log.path.hasPrefix(f.sandbox.paths.logs.appendingPathComponent(prefix.directory.lastPathComponent).path))
        XCTAssertTrue(log.lastPathComponent.hasSuffix(" Game.log"))
    }

    func testLaunchRefusesMissingProgramsAndExecutables() throws {
        let f = Fixture()
        var prefix = try f.prefixWithGame()
        XCTAssertThrowsError(try f.service.launch(programID: UUID(), in: prefix))
        prefix = try f.service.addProgram(Program(name: "Ghost", windowsPath: #"C:\Ghost\ghost.exe"#), to: prefix)
        let ghost = try XCTUnwrap(prefix.metadata.programs.first { $0.name == "Ghost" })
        XCTAssertThrowsError(try f.service.launch(programID: ghost.id, in: prefix)) {
            XCTAssertTrue($0.localizedDescription.contains("doesn't exist"))
        }
        XCTAssertEqual(f.runner.started.count, 0)
    }

    func testToolAndInstallerLaunches() throws {
        let f = Fixture()
        let prefix = try f.service.createPrefix(name: "P", runtime: f.runtime, profile: nil)
        try f.service.launch(tool: .winecfg, in: prefix)
        try f.service.launch(executable: URL(fileURLWithPath: "/Users/me/Downloads/Setup.exe"), in: prefix)
        XCTAssertEqual(f.runner.started.map(\.plan.arguments), [["winecfg"], ["/Users/me/Downloads/Setup.exe"]])
    }

    func testLogFileNamesAreSafe() throws {
        let f = Fixture()
        let prefix = try f.service.createPrefix(name: "P", runtime: f.runtime, profile: nil)
        let date = Date(timeIntervalSince1970: 0)
        let log = f.service.logFile(for: prefix, name: "A/B: C", date: date)
        XCTAssertFalse(log.lastPathComponent.contains("/"))
        XCTAssertFalse(log.lastPathComponent.contains(":"))
        XCTAssertTrue(log.lastPathComponent.hasSuffix(" A-B- C.log"))
    }

    func testDeletePrefixStopsWineRemovesShortcutsAndFiles() throws {
        let f = Fixture()
        var prefix = try f.prefixWithGame()
        prefix = try f.service.createShortcut(for: prefix.metadata.programs[0].id, in: prefix)
        f.runner.ran.removeAll()
        try f.service.deletePrefix(prefix)
        XCTAssertEqual(f.runner.ran.map(\.arguments), [["-k"]])
        XCTAssertEqual(f.service.shortcuts.list(), [])
        XCTAssertFalse(FileManager.default.fileExists(atPath: prefix.directory.path))
    }

    func testDeleteStillWorksWhenTheRuntimeIsGone() throws {
        let f = Fixture()
        let prefix = try f.service.createPrefix(name: "P", runtime: f.runtime, profile: nil)
        try f.service.runtimes.removeManaged(id: f.runtime.id)
        XCTAssertNoThrow(try f.service.deletePrefix(prefix))
        XCTAssertEqual(f.service.prefixes.list(), [])
    }

    func testStopAllAndWineboot() throws {
        let f = Fixture()
        let prefix = try f.service.createPrefix(name: "P", runtime: f.runtime, profile: nil)
        f.runner.ran.removeAll()
        try f.service.stopAll(in: prefix)
        try f.service.runWineboot(.restart, in: prefix)
        XCTAssertEqual(f.runner.ran.map(\.arguments), [["-k"], ["wineboot", "--restart"]])
        f.runner.status = { _ in 5 }
        XCTAssertThrowsError(try f.service.runWineboot(.update, in: prefix))
    }

    func testChangingTheSyncModeStopsThePrefixFirst() throws {
        let f = Fixture()
        var prefix = try f.service.createPrefix(name: "Sync", runtime: f.runtime, profile: nil)
        XCTAssertEqual(prefix.metadata.appliedSettings?.syncMode, .msync)
        f.runner.ran.removeAll()

        // Nothing about synchronisation changed: nothing is stopped.
        prefix.metadata.settings.metalHUD = true
        prefix = try f.service.applySettings(to: prefix)
        XCTAssertFalse(f.runner.ran.contains { $0.arguments == ["-k"] })

        // A program started with MSync cannot join a server started without it, and the other
        // way round, so the server is stopped before the settings are written with the new mode.
        f.runner.ran.removeAll()
        prefix.metadata.settings.syncMode = .standard
        prefix = try f.service.applySettings(to: prefix)
        XCTAssertEqual(f.runner.ran.first?.arguments, ["-k"])
        XCTAssertEqual(f.runner.ran.first?.executable.lastPathComponent, "wineserver")
        XCTAssertEqual(f.runner.ran.last?.arguments.first, "regedit")
        XCTAssertNil(f.runner.ran.last?.environment["WINEMSYNC"])
    }

    func testLaunchingAProgramMakesRoomForItsGameMarker() throws {
        let f = Fixture()
        let prefix = try f.prefixWithGame()
        _ = try f.service.launch(programID: prefix.metadata.programs[0].id, in: prefix)
        var isDir: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: prefix.directory.appendingPathComponent(".finewine-games").path, isDirectory: &isDir))
        XCTAssertTrue(isDir.boolValue)
    }

    func testShutDownAsksProgramsToCloseAndDoesNotWait() throws {
        let f = Fixture()
        let prefix = try f.service.createPrefix(name: "Down", runtime: f.runtime, profile: nil)
        f.runner.ran.removeAll()
        try f.service.shutDown(prefix)
        XCTAssertEqual(f.runner.started.last?.plan.arguments, ["wineboot", "--shutdown"])
        XCTAssertTrue(f.runner.ran.isEmpty, "nothing is waited for: a frozen program would never answer")
    }

    func testForceShutDownKillsWhatTheServerLeftBehind() throws {
        var f = Fixture()
        let prefix = try f.service.createPrefix(name: "Stuck", runtime: f.runtime, profile: nil)
        let other = try f.service.createPrefix(name: "Stuck 2", runtime: f.runtime, profile: nil)
        f.runner.ran.removeAll()

        let killed = Killed()
        var service = f.service
        let directory = prefix.directory
        service.findProcesses = { asked in asked == directory ? [101, 102] : [103] }
        service.killProcess = { killed.add($0) }
        XCTAssertEqual(try service.forceShutDown(prefix), 2)
        XCTAssertEqual(f.runner.ran.first?.arguments, ["-k"], "the server is told first")
        XCTAssertEqual(killed.pids, [101, 102], "then what is still there is killed; another prefix's programs are left alone")
        _ = other
        _ = f
    }
}

private final class Killed: @unchecked Sendable {
    private let lock = NSLock()
    private var _pids: [Int32] = []
    func add(_ pid: Int32) { lock.lock(); _pids.append(pid); lock.unlock() }
    var pids: [Int32] { lock.lock(); defer { lock.unlock() }; return _pids }
}

final class PrefixProcessesTests: XCTestCase {
    func testFindsProcessesByTheirPrefix() {
        let ps = """
            11 /rt/wine a.exe USER=me WINEPREFIX=/Users/me/Library/Application Support/FineWine/Prefixes/Games WINEDEBUG=-all
            12 /rt/wine b.exe WINEPREFIX=/Users/me/Library/Application Support/FineWine/Prefixes/Games
            13 /rt/wine c.exe WINEPREFIX=/Users/me/Library/Application Support/FineWine/Prefixes/Games 2 LANG=C
            14 /rt/wine d.exe WINEPREFIX=/Users/me/Library/Application Support/FineWine/Prefixes/Games2
          15 /bin/zsh -c echo WINEPREFIX= HOME=/Users/me
          notapid /rt/wine WINEPREFIX=/Users/me/Library/Application Support/FineWine/Prefixes/Games
        """
        let path = "/Users/me/Library/Application Support/FineWine/Prefixes/Games"
        XCTAssertEqual(PrefixProcesses.pids(inPSOutput: ps, prefixPath: path), [11, 12])
        XCTAssertEqual(PrefixProcesses.pids(inPSOutput: ps, prefixPath: path + " 2"), [13])
        XCTAssertEqual(PrefixProcesses.pids(inPSOutput: "", prefixPath: path), [])
    }

    func testLsofOutputIsOnePidPerLine() {
        XCTAssertEqual(PrefixProcesses.pids(inLsofOutput: "101\n 202 \n\nnot a pid\n303\n"), [101, 202, 303])
        XCTAssertEqual(PrefixProcesses.pids(inLsofOutput: ""), [])
    }

    func testTheRealSearchFindsWhoHoldsThePrefixMarkerOpen() throws {
        let sandbox = Sandbox()
        let prefix = sandbox.root.appendingPathComponent("held prefix")
        try FileManager.default.createDirectory(at: prefix, withIntermediateDirectories: true)
        XCTAssertEqual(PrefixProcesses.systemPIDs(prefixDirectory: prefix), [], "nothing runs in a prefix that was never used")

        // A stand-in for a Wine program: something that keeps the marker open.
        let marker = prefix.appendingPathComponent(PrefixProcesses.aliveMarkerName)
        FileManager.default.createFile(atPath: marker.path, contents: nil)
        let holder = Process()
        holder.executableURL = URL(fileURLWithPath: "/bin/sh")
        holder.arguments = ["-c", "exec 3< \"$0\"; exec /bin/sleep 30", marker.path]
        try holder.run()
        defer { holder.terminate() }
        var found: [Int32] = []
        for _ in 0..<40 where found.isEmpty {
            found = PrefixProcesses.systemPIDs(prefixDirectory: prefix)
            if found.isEmpty { Thread.sleep(forTimeInterval: 0.1) }
        }
        XCTAssertEqual(found, [holder.processIdentifier])
    }
}
