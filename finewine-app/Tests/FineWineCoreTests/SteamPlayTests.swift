import XCTest
@testable import FineWineCore

/// A runner whose started programs end at once, as `runForSteam` waits for them.
private final class EndingRunner: ProcessRunning, @unchecked Sendable {
    var ran: [LaunchPlan] = []
    var started: [LaunchPlan] = []
    func run(_ plan: LaunchPlan) throws -> ProcessResult {
        ran.append(plan)
        return ProcessResult(status: 0, output: "")
    }
    func start(_ plan: LaunchPlan, logFile: URL?, onExit: @escaping @Sendable (Int32) -> Void) throws -> Int32 {
        started.append(plan)
        onExit(7)
        return 1
    }
}

final class SteamPlayTests: XCTestCase {
    private func client(_ sandbox: Sandbox) -> SteamClient {
        let support = sandbox.root.appendingPathComponent("AppSupport")
        return SteamClient(root: support.appendingPathComponent("Steam"), applicationSupport: support)
    }

    /// A runtime with the bridge's three files in it.
    private func bridgedRuntime(_ sandbox: Sandbox) -> URL {
        let runtime = sandbox.makeRuntime(manifest: RuntimeManifest(id: "bridged", name: "Bridged", version: "1", wineVersion: "11.21"))
        for file in ["wine/lsteamclient.dll", "wine/lsteamclient.so", "steam/steam.exe", "steam/lsteamclient.dll"] {
            sandbox.write(file, to: runtime.appendingPathComponent("lib/steam-bridge/\(file)"))
        }
        return runtime
    }

    private func valve(_ sandbox: Sandbox, contents: [String: String]) -> ValveClientFiles {
        var valve = ValveClientFiles(directory: sandbox.paths.valveClientFiles)
        valve.files = contents.keys.sorted().map { name in
            let digest = SHA256Hex.of(Data(contents[name]!.utf8))
            return .init(name: name, package: "pkg", pathInPackage: "inner/" + name, sha256: digest)
        }
        return valve
    }

    func testToolIsInstalledBesideOthersAndRemovedWithoutTouchingThem() throws {
        let sandbox = Sandbox()
        let client = client(sandbox)
        sandbox.write("theirs", to: client.toolsDirectory.appendingPathComponent("notproton-26.3/run"))
        let tool = SteamTool(client: client)
        XCTAssertFalse(tool.isInstalled)

        let app = URL(fileURLWithPath: "/Applications/Fine'Wine.app")
        try tool.install(app: app)
        XCTAssertTrue(tool.isInstalled)
        XCTAssertEqual(tool.appPath, app.path)
        XCTAssertEqual(tool.directory.lastPathComponent, "finewine-proton")
        // not a name the other tools clean up, and one Steam maps Cloud folders for
        XCTAssertFalse(SteamTool.name.hasPrefix("notproton"))
        XCTAssertFalse(SteamTool.name.hasPrefix("bridgeplay"))
        XCTAssertTrue(SteamTool.name.contains("proton"))
        let declaration = try String(contentsOf: tool.directory.appendingPathComponent("compatibilitytool.vdf"), encoding: .utf8)
        XCTAssertTrue(declaration.contains("\"finewine-proton\""))
        XCTAssertTrue(declaration.contains("\"to_oslist\" \"macos\""))
        let run = tool.directory.appendingPathComponent("run")
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: run.path))
        let script = try String(contentsOf: run, encoding: .utf8)
        XCTAssertTrue(script.contains(#"'/Applications/Fine'\''Wine.app'"#), "the app's path is quoted for the shell")
        XCTAssertTrue(script.contains("--steam-run \"$@\""))

        // the script is valid shell and answers Steam's question about the prefix folder
        let check = Process()
        check.executableURL = URL(fileURLWithPath: "/bin/sh")
        check.arguments = [run.path, "getcompatpath"]
        check.environment = ["STEAM_COMPAT_DATA_PATH": "/some/where"]
        let pipe = Pipe()
        check.standardOutput = pipe
        try check.run()
        check.waitUntilExit()
        XCTAssertEqual(check.terminationStatus, 0)
        XCTAssertEqual(String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self), "/some/where\n")

        // a file someone else put in the folder keeps the folder
        sandbox.write("x", to: tool.directory.appendingPathComponent("notes.txt"))
        try tool.remove()
        XCTAssertFalse(tool.isInstalled)
        XCTAssertTrue(FileManager.default.fileExists(atPath: tool.directory.appendingPathComponent("notes.txt").path))
        try FileManager.default.removeItem(at: tool.directory.appendingPathComponent("notes.txt"))
        try tool.install(app: app)
        try tool.remove()
        XCTAssertFalse(FileManager.default.fileExists(atPath: tool.directory.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: client.toolsDirectory.appendingPathComponent("notproton-26.3/run").path))
    }

    func testClientFindsEnablersAndGameNames() throws {
        let sandbox = Sandbox()
        let client = client(sandbox)
        XCTAssertFalse(client.isInstalled)
        XCTAssertEqual(client.steamPlayEnablers, [])
        sandbox.write("""
        "AppState"
        {
        \t"appid"\t\t"2739990"
        \t"name"\t\t"Mahjong Soul"
        \t"installdir"\t\t"Mahjong Soul"
        }
        """, to: client.root.appendingPathComponent("steamapps/appmanifest_2739990.acf"))
        sandbox.write("x", to: client.toolsDirectory.appendingPathComponent("bridgeplay-proton-winecx/run"))
        sandbox.write("1", to: client.applicationSupport.appendingPathComponent("notproton/dylib.version"))
        XCTAssertTrue(client.isInstalled)
        XCTAssertEqual(client.steamPlayEnablers, ["NotProton", "Bridgeplay"])
        XCTAssertEqual(client.appName(appID: "2739990", installPath: nil), "Mahjong Soul")
        XCTAssertNil(client.appName(appID: "1", installPath: nil))
        // a game in another Steam library: the manifest is two folders above the game
        let library = sandbox.root.appendingPathComponent("Drive/SteamLibrary/steamapps")
        sandbox.write("\"AppState\"\n{\n\t\"name\"\t\t\"Other Game\"\n}\n", to: library.appendingPathComponent("appmanifest_42.acf"))
        XCTAssertEqual(client.appName(appID: "42", installPath: library.appendingPathComponent("common/Other Game")), "Other Game")
    }

    func testValveFilesAreAdoptedOnlyWhenTheyAreTheRightOnes() throws {
        let sandbox = Sandbox()
        let valve = valve(sandbox, contents: ["steamclient64.dll": "client", "tier0_s64.dll": "tier0"])
        XCTAssertEqual(valve.missing().map(\.name), ["steamclient64.dll", "tier0_s64.dll"])
        let theirs = sandbox.root.appendingPathComponent("their-bridge")
        sandbox.write("client", to: theirs.appendingPathComponent("steamclient64.dll"))
        sandbox.write("another build", to: theirs.appendingPathComponent("tier0_s64.dll"))
        XCTAssertEqual(try valve.adopt(from: [sandbox.root.appendingPathComponent("nowhere"), theirs]), 1)
        XCTAssertEqual(valve.missing().map(\.name), ["tier0_s64.dll"])
        XCTAssertFalse(valve.isComplete)
    }

    func testValveFilesAreFetchedCheckedAndTakenOutOfThePackage() throws {
        let sandbox = Sandbox()
        // a real zip, made with the system's zip, served by a stand-in for the download
        let staging = sandbox.root.appendingPathComponent("zip-src")
        sandbox.write("client", to: staging.appendingPathComponent("inner/steamclient64.dll"))
        let archive = sandbox.root.appendingPathComponent("package.zip")
        let zip = Process()
        zip.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        zip.arguments = ["-q", "-r", archive.path, "inner"]
        zip.currentDirectoryURL = staging
        try zip.run()
        zip.waitUntilExit()
        XCTAssertEqual(zip.terminationStatus, 0)

        var valve = valve(sandbox, contents: ["steamclient64.dll": "client"])
        valve.packages = [.init(id: "pkg", fileName: "package.zip.abc", sha256: try XCTUnwrap(ValveClientFiles.sha256(of: archive)))]
        let asked = LockedBox<[URL]>([])
        valve.download = { url, file in
            asked.set(asked.get() + [url])
            try FileManager.default.copyItem(at: archive, to: file)
        }
        try valve.ensure(adoptingFrom: [])
        XCTAssertTrue(valve.isComplete)
        XCTAssertEqual(asked.get().map(\.lastPathComponent), ["package.zip.abc"])
        XCTAssertEqual(asked.get().first?.host, URL(string: ValveClientFiles.servers[0])?.host)
        // nothing is fetched again once the files are there
        try valve.ensure(adoptingFrom: [])
        XCTAssertEqual(asked.get().count, 1)

        // a package that is not the pinned one is refused, from every server
        var wrong = self.valve(sandbox, contents: ["tier0_s64.dll": "tier0"])
        wrong.packages = [.init(id: "pkg", fileName: "package.zip.abc", sha256: String(repeating: "0", count: 64))]
        wrong.download = valve.download
        XCTAssertThrowsError(try wrong.fetch())
        XCTAssertFalse(wrong.isComplete)
    }

    func testALaunchIsReadFromWhatSteamPasses() throws {
        let env = ["SteamAppId": "2739990", "STEAM_COMPAT_INSTALL_PATH": "/lib/steamapps/common/Game",
                   "STEAM_COMPAT_CLIENT_INSTALL_PATH": "/steam", "SteamUser": "someone", "PATH": "/usr/bin",
                   "ENABLE_VK_LAYER_VALVE_steam_overlay_1": "1"]
        let run = try XCTUnwrap(SteamRun.parse(arguments: ["waitforexitandrun", "/lib/steamapps/common/Game/Game.exe", "-windowed"], environment: env))
        XCTAssertEqual(run.verb, .waitForExitAndRun)
        XCTAssertEqual(run.appID, "2739990")
        XCTAssertEqual(run.arguments, ["-windowed"])
        XCTAssertEqual(run.steamEnvironment.keys.sorted(),
                       ["ENABLE_VK_LAYER_VALVE_steam_overlay_1", "STEAM_COMPAT_CLIENT_INSTALL_PATH", "STEAM_COMPAT_INSTALL_PATH", "SteamAppId", "SteamUser"])
        XCTAssertNil(try SteamRun.parse(arguments: ["getnativepath", "x"], environment: env))
        XCTAssertThrowsError(try SteamRun.parse(arguments: ["run"], environment: env))
        XCTAssertThrowsError(try SteamRun.parse(arguments: ["run", "/x.exe"], environment: ["PATH": "/usr/bin"]))

        XCTAssertEqual(SteamRun.prefixName(for: "Game: The Sequel", appID: "5", taken: []), "Game  The Sequel")
        XCTAssertEqual(SteamRun.prefixName(for: nil, appID: "5", taken: []), "Steam 5")
        XCTAssertEqual(SteamRun.prefixName(for: "Game", appID: "5", taken: ["game"]), "Game (Steam)")
        XCTAssertEqual(SteamRun.prefixName(for: "Game", appID: "5", taken: ["Game", "Game (Steam)"]), "Game (Steam 2)")
    }

    func testAGameGetsAPrefixOfItsOwnAndIsStartedThroughTheBridge() throws {
        let sandbox = Sandbox()
        let store = RuntimeStore(paths: sandbox.paths, bundledRoot: nil)
        _ = try store.installManaged(from: bridgedRuntime(sandbox))
        let runner = EndingRunner()
        let service = PrefixService(paths: sandbox.paths, runner: runner, runtimes: store)
        XCTAssertNotNil(service.steamRuntime())

        let client = client(sandbox)
        let game = client.root.appendingPathComponent("steamapps/common/Mahjong Soul/Game.exe")
        sandbox.write("MZ", to: game)
        sandbox.write("\"AppState\"\n{\n\t\"name\"\t\t\"Mahjong Soul\"\n}\n", to: client.root.appendingPathComponent("steamapps/appmanifest_2739990.acf"))
        // Valve's files are there already, as another tool's copy
        let valve = valve(sandbox, contents: ["steamclient64.dll": "client"])

        let env = ["SteamAppId": "2739990", "STEAM_COMPAT_INSTALL_PATH": game.deletingLastPathComponent().path,
                   "STEAM_COMPAT_CLIENT_INSTALL_PATH": "/steam/client", "WINEDLLPATH": "/evil"]
        let run = try XCTUnwrap(SteamRun.parse(arguments: ["waitforexitandrun", game.path, "-windowed"], environment: env))

        let (prefix, program) = try service.prepareSteamPrefix(for: run, client: client)
        XCTAssertEqual(prefix.name, "Mahjong Soul")
        XCTAssertEqual(prefix.metadata.steamAppID, "2739990")
        XCTAssertEqual(program.name, "Mahjong Soul")
        XCTAssertTrue(program.windowsPath.hasPrefix("Z:\\"))
        // the same game again: the same prefix and the same entry
        let again = try service.prepareSteamPrefix(for: run, client: client)
        XCTAssertEqual(again.prefix.id, prefix.id)
        XCTAssertEqual(again.program.id, program.id)
        XCTAssertEqual(service.prefixes.list().count, 1)
        XCTAssertEqual(service.steamPrefix(appID: "2739990")?.id, prefix.id)

        // without Valve's files there is nothing to stage the game against
        XCTAssertThrowsError(try service.stageSteamBridge(from: try service.runtime(for: prefix), valve: valve, in: prefix))
        sandbox.write("client", to: valve.directory.appendingPathComponent("steamclient64.dll"))
        try service.stageSteamBridge(from: try service.runtime(for: prefix), valve: valve, in: prefix)
        let steamFolder = prefix.directory.appendingPathComponent(SteamRun.steamFolderInPrefix)
        for file in ["steam.exe", "lsteamclient.dll", "steamclient64.dll"] {
            XCTAssertTrue(FileManager.default.fileExists(atPath: steamFolder.appendingPathComponent(file).path), file)
        }

        let plan = try service.steamLaunchPlan(for: run, program: program, in: prefix)
        XCTAssertEqual(plan.arguments, [SteamRun.helperWindowsPath, program.windowsPath, "-windowed"])
        XCTAssertEqual(plan.environment[SteamRun.bridgeVariable], "1")
        XCTAssertEqual(plan.environment["SteamAppId"], "2739990")
        XCTAssertEqual(plan.environment["STEAM_COMPAT_CLIENT_INSTALL_PATH"], "/steam/client")
        XCTAssertEqual(plan.environment["WINEPREFIX"], prefix.directory.path)
        let dllPath = try XCTUnwrap(plan.environment["WINEDLLPATH"])
        XCTAssertTrue(dllPath.hasSuffix("lib/steam-bridge/wine"), dllPath)
        XCTAssertFalse(dllPath.contains("/evil"), "only Steam's own variables are passed on")
        XCTAssertEqual(plan.workingDirectory?.path, game.deletingLastPathComponent().path)
        // the overlay helper is named only when the runtime has it
        XCTAssertNil(plan.environment[SteamRun.overlayShimVariable])
        let runtimeRoot = try service.runtime(for: prefix).root
        sandbox.write("shim", to: runtimeRoot.appendingPathComponent("lib/steam-bridge/overlay-shim.dylib"))
        let withShim = try service.steamLaunchPlan(for: run, program: program, in: prefix)
        XCTAssertEqual(withShim.environment[SteamRun.overlayShimVariable],
                       runtimeRoot.appendingPathComponent("lib/steam-bridge/overlay-shim.dylib").path)
    }
}

enum SHA256Hex {
    static func of(_ data: Data) -> String {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("sha-\(UUID().uuidString)")
        try? data.write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        return ValveClientFiles.sha256(of: file) ?? ""
    }
}
