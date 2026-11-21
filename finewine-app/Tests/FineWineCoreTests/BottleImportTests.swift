import XCTest
@testable import FineWineCore

final class BottleImportTests: XCTestCase {
    /// A folder laid out like a CrossOver bottle, with one program's files and registry.
    private func makeBottle(_ sandbox: Sandbox, name: String = "Game Bottle", arch: String = "win64") -> URL {
        let bottle = sandbox.root.appendingPathComponent("Bottles/\(name)", isDirectory: true)
        sandbox.write("WINE REGISTRY Version 2\n;; All keys relative to REGISTRY\\\\Machine\n\n#arch=\(arch)\n\n"
            + "[Software\\\\Vendor\\\\Game] 1700000000\n\"Path\"=\"C:\\\\users\\\\crossover\\\\AppData\\\\Local\\\\Game\"\n",
                      to: bottle.appendingPathComponent("system.reg"))
        sandbox.write("WINE REGISTRY Version 2\n;; All keys relative to REGISTRY\\\\User\\\\S-1-5-21-0-0-0-1000\n\n#arch=\(arch)\n\n"
            + "[Environment] 1700000000\n\"TEMP\"=\"C:\\\\users\\\\crossover\\\\AppData\\\\Local\\\\Temp\"\n\n"
            + "[Software\\\\Wine] 1700000000\n\"Version\"=\"win10\"\n",
                      to: bottle.appendingPathComponent("user.reg"))
        sandbox.write("[Bottle]\n\"Template\" = \"win10_64\"\n", to: bottle.appendingPathComponent("cxbottle.conf"))
        sandbox.write("game", to: bottle.appendingPathComponent("drive_c/Program Files/Game/game.exe"))
        sandbox.write("save", to: bottle.appendingPathComponent("drive_c/users/crossover/AppData/Local/Game/save.dat"))
        sandbox.write("", to: bottle.appendingPathComponent("drive_c/users/Public/Desktop/.keep"))
        sandbox.write("", to: bottle.appendingPathComponent("drive_c/windows/system32/kernel32.dll"))
        let devices = bottle.appendingPathComponent("dosdevices")
        try! FileManager.default.createDirectory(at: devices, withIntermediateDirectories: true)
        try! FileManager.default.createSymbolicLink(atPath: devices.appendingPathComponent("c:").path, withDestinationPath: "../drive_c")
        try! FileManager.default.createSymbolicLink(atPath: devices.appendingPathComponent("y:").path, withDestinationPath: NSHomeDirectory())
        return bottle
    }

    private func makeService(_ sandbox: Sandbox) -> (PrefixService, RecordingRunner, WineRuntime) {
        let runner = RecordingRunner()
        var service = PrefixService(paths: sandbox.paths, runner: runner, runtimes: RuntimeStore(paths: sandbox.paths, bundledRoot: nil))
        service.findProcesses = { _ in [] }
        let root = sandbox.makeRuntime(manifest: RuntimeManifest(id: "fw", name: "FW", version: "1", wineVersion: "11.21"))
        let runtime = try! service.runtimes.installManaged(from: root)
        return (service, runner, runtime)
    }

    /// Every file under a folder with its contents, to see that nothing in it changed.
    private func contents(of folder: URL) -> [String: Data] {
        var out: [String: Data] = [:]
        let base = folder.standardizedFileURL.path
        for case let url as URL in FileManager.default.enumerator(at: folder, includingPropertiesForKeys: nil)! {
            let key = String(url.standardizedFileURL.path.dropFirst(base.count))
            if let link = try? FileManager.default.destinationOfSymbolicLink(atPath: url.path) { out[key] = Data(("-> " + link).utf8) }
            else if let data = try? Data(contentsOf: url) { out[key] = data }
        }
        return out
    }

    func testReadsABottleAndListsAFolderOfThem() throws {
        let sandbox = Sandbox()
        let folder = makeBottle(sandbox)
        _ = makeBottle(sandbox, name: "Old", arch: "win32")
        sandbox.write("x", to: sandbox.root.appendingPathComponent("Bottles/not a bottle/readme.txt"))
        let bottle = try XCTUnwrap(CrossOverBottle.read(folder))
        XCTAssertEqual(bottle.name, "Game Bottle")
        XCTAssertTrue(bottle.is64Bit)
        XCTAssertTrue(bottle.isCrossOver)
        XCTAssertEqual(bottle.windowsUser, "crossover")
        let all = CrossOverBottle.list(in: [sandbox.root.appendingPathComponent("Bottles")])
        XCTAssertEqual(all.map(\.name), ["Game Bottle", "Old"])
        XCTAssertEqual(all.map(\.is64Bit), [true, false])
    }

    func testImportCopiesTheBottleAndLeavesItAlone() throws {
        let sandbox = Sandbox()
        let (service, runner, runtime) = makeService(sandbox)
        let bottle = try XCTUnwrap(CrossOverBottle.read(makeBottle(sandbox)))
        let before = contents(of: bottle.directory)

        let prefix = try service.importBottle(bottle, name: "Game", runtime: runtime, userName: "tester")
        XCTAssertEqual(contents(of: bottle.directory), before)

        let fm = FileManager.default
        let dir = prefix.directory
        XCTAssertEqual(try String(contentsOf: dir.appendingPathComponent("drive_c/Program Files/Game/game.exe"), encoding: .utf8), "game")
        // the user folder under this Wine's name, and still reachable under the old one
        XCTAssertEqual(try String(contentsOf: dir.appendingPathComponent("drive_c/users/tester/AppData/Local/Game/save.dat"), encoding: .utf8), "save")
        XCTAssertEqual(try fm.destinationOfSymbolicLink(atPath: dir.appendingPathComponent("drive_c/users/crossover").path), "tester")
        let system = try String(contentsOf: dir.appendingPathComponent("system.reg"), encoding: .utf8)
        XCTAssertTrue(system.contains(#""Path"="C:\\users\\tester\\AppData\\Local\\Game""#))
        XCTAssertFalse(try String(contentsOf: dir.appendingPathComponent("user.reg"), encoding: .utf8).contains("crossover"))
        // only C: and Z:, and none of CrossOver's own files
        XCTAssertEqual(try fm.contentsOfDirectory(atPath: dir.appendingPathComponent("dosdevices").path).sorted(), ["c:", "z:"])
        XCTAssertFalse(fm.fileExists(atPath: dir.appendingPathComponent("cxbottle.conf").path))
        // the bottle's Windows version is kept; the runtime updated the prefix, then the settings went in
        XCTAssertEqual(prefix.metadata.settings.windowsVersion, .win10)
        XCTAssertEqual(prefix.metadata.runtimeID, runtime.id)
        XCTAssertEqual(runner.ran.first?.arguments, ["wineboot", "--update"])
        XCTAssertEqual(runner.ran.first?.environment["WINEPREFIX"], dir.path)
        XCTAssertEqual(runner.ran.dropFirst().first?.arguments.first, "regedit")
        XCTAssertNotNil(prefix.metadata.appliedSettings)
        XCTAssertEqual(service.prefixes.list().map(\.name), ["Game"])
    }

    func testRefusals() throws {
        let sandbox = Sandbox()
        var (service, runner, runtime) = makeService(sandbox)
        let old = try XCTUnwrap(CrossOverBottle.read(makeBottle(sandbox, name: "Old", arch: "win32")))
        XCTAssertThrowsError(try service.importBottle(old, name: "Old", runtime: runtime)) {
            XCTAssertEqual($0.localizedDescription, tr("bottle.err_32bit", "Old"))
        }
        let bottle = try XCTUnwrap(CrossOverBottle.read(makeBottle(sandbox)))
        service.findProcesses = { $0 == bottle.directory ? [4242] : [] }
        XCTAssertThrowsError(try service.importBottle(bottle, name: "Game", runtime: runtime)) {
            XCTAssertEqual($0.localizedDescription, tr("bottle.err_running", "Game Bottle"))
        }
        XCTAssertTrue(runner.ran.isEmpty)
        XCTAssertTrue(service.prefixes.list().isEmpty)
    }

    func testAFailedUpdateLeavesNoPrefixBehind() throws {
        let sandbox = Sandbox()
        let (service, runner, runtime) = makeService(sandbox)
        runner.status = { _ in 1 }
        let bottle = try XCTUnwrap(CrossOverBottle.read(makeBottle(sandbox)))
        let before = contents(of: bottle.directory)
        XCTAssertThrowsError(try service.importBottle(bottle, name: "Game", runtime: runtime, userName: "tester"))
        XCTAssertTrue(service.prefixes.list().isEmpty)
        XCTAssertEqual(contents(of: bottle.directory), before)
    }

    func testACancelledCopyLeavesNoPrefixBehind() throws {
        let sandbox = Sandbox()
        let (service, _, runtime) = makeService(sandbox)
        let bottle = try XCTUnwrap(CrossOverBottle.read(makeBottle(sandbox)))
        let progress = CopyProgress()
        progress.cancel()
        XCTAssertThrowsError(try service.importBottle(bottle, name: "Game", runtime: runtime, progress: progress)) {
            XCTAssertEqual(($0 as? FineWineError)?.message, FolderCopy.cancelledMessage)
        }
        XCTAssertTrue(service.prefixes.list().isEmpty)
    }

    /// With a real bottle and a real runtime: FINEWINE_TEST_BOTTLE and FINEWINE_TEST_RUNTIME
    /// name them. The bottle is only read; the prefix is made in a temporary folder.
    func testRealBottleWithRealRuntime() throws {
        let env = ProcessInfo.processInfo.environment
        guard let bottlePath = env["FINEWINE_TEST_BOTTLE"], let runtimePath = env["FINEWINE_TEST_RUNTIME"] else {
            throw XCTSkip("set FINEWINE_TEST_BOTTLE and FINEWINE_TEST_RUNTIME to run this")
        }
        let sandbox = Sandbox()
        let store = RuntimeStore(paths: sandbox.paths, bundledRoot: URL(fileURLWithPath: runtimePath, isDirectory: true))
        let service = PrefixService(paths: sandbox.paths, runtimes: store)
        let runtime = try XCTUnwrap(store.bundled)
        let bottle = try XCTUnwrap(CrossOverBottle.read(URL(fileURLWithPath: bottlePath, isDirectory: true)))
        let prefix = try service.importBottle(bottle, name: "Imported", runtime: runtime)
        defer { _ = try? service.runner.run(try service.planner(for: prefix).killPlan()) }

        let fm = FileManager.default
        XCTAssertTrue(fm.fileExists(atPath: prefix.directory.appendingPathComponent("drive_c/windows/system32/xtajit64.dll").path))
        XCTAssertTrue(fm.fileExists(atPath: prefix.directory.appendingPathComponent("drive_c/users/\(NSUserName())/AppData").path))
        print("imported programs:", prefix.metadata.programs.map(\.name))
        // a 64-bit program runs in it
        let plan = try service.planner(for: prefix).plan(for: .cmd)
        var echo = plan
        echo.arguments = ["cmd", "/c", "echo", "imported-ok"]
        let result = try service.runner.run(echo)
        XCTAssertTrue(result.output.contains("imported-ok"), result.output)
    }
}
