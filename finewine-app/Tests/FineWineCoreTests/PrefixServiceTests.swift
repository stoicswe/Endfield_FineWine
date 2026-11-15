import XCTest
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
}
