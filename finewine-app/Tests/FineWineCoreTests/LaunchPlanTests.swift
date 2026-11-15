import XCTest
@testable import FineWineCore

final class LaunchPlannerTests: XCTestCase {
    private struct Fixture {
        let sandbox = Sandbox()
        var runtime: WineRuntime
        var prefix: Prefix

        init(graphics: [String: GraphicsBackendSpec] = [:]) {
            let root = sandbox.makeRuntime()
            runtime = WineRuntime(manifest: RuntimeManifest(id: "r", name: "R", version: "1", wineVersion: "11.21",
                                                            graphics: graphics), root: root, kind: .managed)
            let dir = sandbox.root.appendingPathComponent("pfx")
            try! FileManager.default.createDirectory(at: dir.appendingPathComponent("drive_c/Game"), withIntermediateDirectories: true)
            prefix = Prefix(metadata: PrefixMetadata(name: "P", runtimeID: "r"), directory: dir)
        }

        func planner(profile: GameProfile? = nil, base: [String: String] = ["PATH": "/usr/bin", "HOME": "/Users/me"]) -> LaunchPlanner {
            LaunchPlanner(runtime: runtime, prefix: prefix, profile: profile, baseEnvironment: base)
        }
    }

    func testBaseEnvironment() {
        let f = Fixture()
        let env = f.planner().environment()
        XCTAssertEqual(env["WINEPREFIX"], f.prefix.directory.path)
        XCTAssertEqual(env["WINESERVER"], f.runtime.root.appendingPathComponent("bin/wineserver").path)
        XCTAssertEqual(env["PATH"], f.runtime.root.appendingPathComponent("bin").path + ":/usr/bin")
        XCTAssertEqual(env["HOME"], "/Users/me")
        XCTAssertEqual(env["WINEDEBUG"], "-all")
        XCTAssertEqual(env["WINEDLLOVERRIDES"], "winemenubuilder.exe=d")
        XCTAssertEqual(env["DYLD_FALLBACK_LIBRARY_PATH"], f.runtime.root.appendingPathComponent("lib").path + ":/usr/local/lib:/usr/lib")
        XCTAssertNil(env["WINEDLLPATH"])
    }

    func testOnlyAllowListedVariablesAreInherited() {
        let f = Fixture()
        let env = f.planner(base: ["PATH": "/bin", "DYLD_INSERT_LIBRARIES": "/evil.dylib", "WINEPREFIX": "/other",
                                   "WINEDLLOVERRIDES": "x=n", "SECRET_TOKEN": "s", "LANG": "ja_JP.UTF-8"]).environment()
        XCTAssertNil(env["DYLD_INSERT_LIBRARIES"])
        XCTAssertNil(env["SECRET_TOKEN"])
        XCTAssertEqual(env["WINEPREFIX"], f.prefix.directory.path)
        XCTAssertEqual(env["WINEDLLOVERRIDES"], "winemenubuilder.exe=d")
        XCTAssertEqual(env["LANG"], "ja_JP.UTF-8")
    }

    func testMissingPATHGetsADefault() {
        let f = Fixture()
        XCTAssertTrue(f.planner(base: [:]).environment()["PATH"]!.hasSuffix(":/usr/bin:/bin"))
    }

    func testGraphicsBackendFromTheRuntimeManifest() {
        var f = Fixture(graphics: ["dxmt": GraphicsBackendSpec(dllPath: "lib/dxmt",
                                                               overrides: ["dxgi": "n,b", "d3d11": "n,b"])])
        var env = f.planner().environment()
        XCTAssertEqual(env["WINEDLLPATH"], f.runtime.root.appendingPathComponent("lib/dxmt").path)
        XCTAssertEqual(env["WINEDLLOVERRIDES"], "winemenubuilder.exe=d;d3d11=n,b;dxgi=n,b")

        // A backend the runtime doesn't ship changes nothing.
        f.prefix.metadata.settings.graphicsBackend = .dxvk
        env = f.planner().environment()
        XCTAssertNil(env["WINEDLLPATH"])
        XCTAssertNil(f.planner().activeGraphicsSpec)
        XCTAssertEqual(env["WINEDLLOVERRIDES"], "winemenubuilder.exe=d")
    }

    func testSettingsAndUserOverridesReachTheEnvironment() {
        var f = Fixture()
        f.prefix.metadata.settings.syncMode = .msync
        f.prefix.metadata.settings.environment = [EnvironmentVariable(name: "WINEDLLOVERRIDES", value: "dinput8=n,b"),
                                                  EnvironmentVariable(name: "DXMT_LOG_LEVEL", value: "info")]
        let env = f.planner().environment(extra: [EnvironmentVariable(name: "DXMT_LOG_LEVEL", value: "debug"),
                                                  EnvironmentVariable(name: "not valid", value: "x")])
        XCTAssertEqual(env["WINEMSYNC"], "1")
        XCTAssertEqual(env["WINEDLLOVERRIDES"], "winemenubuilder.exe=d;dinput8=n,b")
        XCTAssertEqual(env["DXMT_LOG_LEVEL"], "debug", "a program's own variable beats the prefix's")
        XCTAssertNil(env["not valid"])
    }

    func testProgramPlan() throws {
        let f = Fixture()
        let program = Program(name: "Game", windowsPath: #"C:\Game\Game.exe"#, arguments: ["-windowed"],
                              environment: [EnvironmentVariable(name: "GAME_FLAG", value: "1")])
        let plan = try f.planner().plan(for: program)
        XCTAssertEqual(plan.executable, f.runtime.wineBinary)
        XCTAssertEqual(plan.arguments, [#"C:\Game\Game.exe"#, "-windowed"])
        XCTAssertEqual(plan.workingDirectory?.resolvingSymlinksInPath().path,
                       f.prefix.directory.appendingPathComponent("drive_c/Game").resolvingSymlinksInPath().path)
        XCTAssertEqual(plan.environment["GAME_FLAG"], "1")
    }

    func testProgramPlanFallsBackToThePrefixWhenTheFolderIsMissing() throws {
        let f = Fixture()
        let plan = try f.planner().plan(for: Program(name: "G", windowsPath: #"C:\Missing\g.exe"#))
        XCTAssertEqual(plan.workingDirectory, f.prefix.directory)
    }

    func testExplicitWorkingDirectoryWins() throws {
        let f = Fixture()
        try FileManager.default.createDirectory(at: f.prefix.directory.appendingPathComponent("drive_c/Saves"),
                                                withIntermediateDirectories: true)
        let plan = try f.planner().plan(for: Program(name: "G", windowsPath: #"C:\Game\g.exe"#, workingDirectory: #"C:\Saves"#))
        XCTAssertTrue(plan.workingDirectory!.path.hasSuffix("drive_c/Saves"))
    }

    func testProfileArgumentsApplyOnlyToItsExecutables() throws {
        let f = Fixture()
        let planner = f.planner(profile: .endfield)
        XCTAssertEqual(try planner.plan(for: Program(name: "E", windowsPath: #"C:\Game\Endfield.exe"#, arguments: ["-x"])).arguments,
                       [#"C:\Game\Endfield.exe"#, "-force-d3d11", "-x"])
        XCTAssertEqual(try planner.plan(for: Program(name: "L", windowsPath: #"C:\Game\Launcher.exe"#)).arguments,
                       [#"C:\Game\Launcher.exe"#])
        // Not repeated when the program already passes it.
        XCTAssertEqual(try planner.plan(for: Program(name: "E", windowsPath: #"C:\Game\Endfield.exe"#, arguments: ["-force-d3d11"])).arguments,
                       [#"C:\Game\Endfield.exe"#, "-force-d3d11"])
    }

    func testToolPlans() throws {
        let f = Fixture()
        XCTAssertEqual(try f.planner().plan(for: WineTool.winecfg).arguments, ["winecfg"])
        XCTAssertEqual(try f.planner().plan(for: WineTool.regedit).arguments, ["regedit"])
        XCTAssertEqual(try f.planner().plan(for: WineTool.cmd).arguments, ["start", "cmd.exe"])
        for tool in WineTool.allCases {
            XCTAssertFalse(tool.displayName.isEmpty)
            XCTAssertFalse(tool.summary.isEmpty)
            XCTAssertEqual(try f.planner().plan(for: tool).workingDirectory, f.prefix.directory)
        }
    }

    func testWinebootRegistryImportAndKillPlans() throws {
        let f = Fixture()
        XCTAssertEqual(try f.planner().plan(for: WinebootAction.initialize).arguments, ["wineboot", "--init"])
        XCTAssertEqual(try f.planner().plan(for: WinebootAction.restart).arguments, ["wineboot", "--restart"])
        // Setting a prefix up must not stop on Wine's Mono and Gecko download prompts.
        XCTAssertEqual(try f.planner().plan(for: WinebootAction.initialize).environment["WINEDLLOVERRIDES"],
                       "winemenubuilder.exe=d;mscoree=d;mshtml=d")
        XCTAssertEqual(try f.planner().plan(for: WinebootAction.update).environment["WINEDLLOVERRIDES"],
                       "winemenubuilder.exe=d;mscoree=d;mshtml=d")
        XCTAssertEqual(try f.planner().plan(for: WinebootAction.restart).environment["WINEDLLOVERRIDES"],
                       "winemenubuilder.exe=d", "other wineboot actions are left alone")
        XCTAssertEqual(try f.planner().plan(importingRegistryFile: URL(fileURLWithPath: "/tmp/a.reg")).arguments,
                       ["regedit", "/S", "/tmp/a.reg"])
        let kill = try f.planner().killPlan()
        XCTAssertEqual(kill.executable, f.runtime.wineserverBinary)
        XCTAssertEqual(kill.arguments, ["-k"])
        XCTAssertEqual(kill.environment["WINEPREFIX"], f.prefix.directory.path)
    }

    func testInstallerPlans() throws {
        let f = Fixture()
        let exe = try f.planner().plan(forExecutableAt: URL(fileURLWithPath: "/Users/me/Downloads/Setup.exe"), arguments: ["/S"])
        XCTAssertEqual(exe.arguments, ["/Users/me/Downloads/Setup.exe", "/S"])
        XCTAssertEqual(exe.workingDirectory?.path, "/Users/me/Downloads")
        let msi = try f.planner().plan(forExecutableAt: URL(fileURLWithPath: "/Users/me/Downloads/Thing.MSI"))
        XCTAssertEqual(msi.arguments, ["msiexec", "/i", "/Users/me/Downloads/Thing.MSI"])
    }

    func testPlansFailClearlyWithoutWine() {
        let sandbox = Sandbox()
        let root = sandbox.makeRuntime(wine: false, server: false)
        let runtime = WineRuntime(manifest: RuntimeManifest(id: "r", name: "Broken", version: "", wineVersion: ""),
                                  root: root, kind: .managed)
        let planner = LaunchPlanner(runtime: runtime, prefix: Prefix(metadata: PrefixMetadata(name: "P"),
                                                                     directory: sandbox.root), baseEnvironment: [:])
        XCTAssertThrowsError(try planner.plan(for: WineTool.winecfg)) { XCTAssertTrue($0.localizedDescription.contains("Broken")) }
        XCTAssertThrowsError(try planner.killPlan())
    }
}

final class SystemProcessRunnerTests: XCTestCase {
    func testRunCapturesOutputStatusEnvironmentAndDirectory() throws {
        let dir = realTemporaryDirectory()
        let plan = LaunchPlan(executable: URL(fileURLWithPath: "/bin/sh"),
                              arguments: ["-c", "echo \"$FW_VALUE\"; pwd; echo err >&2; exit 3"],
                              environment: ["FW_VALUE": "hello", "PATH": "/usr/bin:/bin"], workingDirectory: dir)
        let result = try SystemProcessRunner().run(plan)
        XCTAssertEqual(result.status, 3)
        XCTAssertEqual(result.output.split(separator: "\n").map(String.init).sorted(), [dir.path, "err", "hello"].sorted())
    }

    func testRunDoesNotInheritTheParentEnvironment() throws {
        setenv("FW_LEAK_CHECK", "leaked", 1)
        defer { unsetenv("FW_LEAK_CHECK") }
        let plan = LaunchPlan(executable: URL(fileURLWithPath: "/usr/bin/env"), arguments: [], environment: ["ONLY": "this"])
        XCTAssertEqual(try SystemProcessRunner().run(plan).output.trimmingCharacters(in: .whitespacesAndNewlines), "ONLY=this")
    }

    func testRunHandlesOutputLargerThanAPipeBuffer() throws {
        let plan = LaunchPlan(executable: URL(fileURLWithPath: "/bin/sh"),
                              arguments: ["-c", "i=0; while [ $i -lt 20000 ]; do echo 0123456789; i=$((i+1)); done"],
                              environment: [:])
        XCTAssertEqual(try SystemProcessRunner().run(plan).output.utf8.count, 220_000)
    }

    func testStartWritesALogAndReportsTheExitStatus() throws {
        let log = FileManager.default.temporaryDirectory.appendingPathComponent("fw-\(UUID().uuidString)/sub/run.log")
        defer { try? FileManager.default.removeItem(at: log.deletingLastPathComponent().deletingLastPathComponent()) }
        let exited = expectation(description: "process exits")
        let plan = LaunchPlan(executable: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", "echo logged; exit 7"], environment: [:])
        let pid = try SystemProcessRunner().start(plan, logFile: log) { status in
            XCTAssertEqual(status, 7)
            exited.fulfill()
        }
        XCTAssertGreaterThan(pid, 0)
        wait(for: [exited], timeout: 10)
        XCTAssertEqual(try String(contentsOf: log, encoding: .utf8), "logged\n")
    }

    func testMissingExecutableThrows() {
        let plan = LaunchPlan(executable: URL(fileURLWithPath: "/nonexistent/wine"), arguments: [], environment: [:])
        XCTAssertThrowsError(try SystemProcessRunner().run(plan))
        XCTAssertThrowsError(try SystemProcessRunner().start(plan, logFile: nil) { _ in })
    }
}
