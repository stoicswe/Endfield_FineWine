import XCTest
@testable import FineWineCore

final class LogCollectorTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func setDate(_ date: Date, of url: URL) {
        try! FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
    }

    private func makePrefix(in sandbox: Sandbox) -> Prefix {
        let dir = sandbox.paths.prefixes.appendingPathComponent("Game-1234")
        var metadata = PrefixMetadata(name: "My Game", runtimeID: "r")
        metadata.programs = [Program(name: "Launcher", windowsPath: #"C:\Program Files\Launcher\launcher.exe"#)]
        sandbox.write(#"{"note":"/Users/alice/x"}"#, to: dir.appendingPathComponent(PrefixStore.metadataName))
        return Prefix(metadata: metadata, directory: dir)
    }

    func testTakesProgramLogsAndLeavesBrowserStorageBinaryAndOldFilesOut() throws {
        let sandbox = Sandbox()
        let prefix = makePrefix(in: sandbox)
        let appData = prefix.driveC.appendingPathComponent("users/alice/AppData")
        let wanted = appData.appendingPathComponent("Roaming/Vendor/HYP/1_0/logs/launcher.log")
        let unity = appData.appendingPathComponent("LocalLow/Vendor/Game/output_log.txt")
        let beside = prefix.driveC.appendingPathComponent("Program Files/Launcher/logs/run.log")
        let storage = appData.appendingPathComponent("Roaming/Vendor/HYP/1_0/fedata/Local Storage/leveldb/000003.log")
        let indexed = appData.appendingPathComponent("Roaming/Vendor/x.indexeddb.leveldb/000004.log")
        let binary = appData.appendingPathComponent("Roaming/Vendor/binary.log")
        let old = appData.appendingPathComponent("Roaming/Vendor/old.log")
        let other = appData.appendingPathComponent("Roaming/Vendor/readme.txt")
        for file in [wanted, unity, beside, storage, indexed, old, other] { sandbox.write("line\n", to: file) }
        sandbox.write(Data([0x4D, 0x5A, 0, 0, 1, 2]), to: binary)
        let journal = appData.appendingPathComponent("Roaming/Vendor/GCM Store/000003.log")
        sandbox.write("x", to: journal)
        sandbox.write("", to: appData.appendingPathComponent("Roaming/Vendor/empty.log"))
        for file in [wanted, unity, beside, storage, indexed, binary, other] { setDate(now.addingTimeInterval(-3600), of: file) }
        setDate(now.addingTimeInterval(-40 * 24 * 3600), of: old)

        let collector = LogCollector(paths: sandbox.paths, userName: "alice", diagnosticReports: nil, now: now)
        let folder = sandbox.root.appendingPathComponent("out")
        let written = try collector.write(for: prefix, runtime: nil, appVersion: "9.9", to: folder)
        XCTAssertEqual(Set(written), ["summary.txt", "prefix-settings.json",
                                      "programs/AppData/Roaming/Vendor/HYP/1_0/logs/launcher.log",
                                      "programs/AppData/LocalLow/Vendor/Game/output_log.txt",
                                      "programs/Launcher/logs/run.log"])
        let summary = try String(contentsOf: folder.appendingPathComponent("summary.txt"), encoding: .utf8)
        XCTAssertTrue(summary.contains("FineWine:  9.9"))
        XCTAssertTrue(summary.contains("Launcher: C:\\Program Files\\Launcher\\launcher.exe"))
        XCTAssertTrue(summary.contains("programs/Launcher/logs/run.log"))
        let settings = try String(contentsOf: folder.appendingPathComponent("prefix-settings.json"), encoding: .utf8)
        XCTAssertEqual(settings, #"{"note":"/Users/USER/x"}"#)
    }

    func testTakesTheNewestLaunchLogsTheSteamLogAndWineCrashReports() throws {
        let sandbox = Sandbox()
        var prefix = makePrefix(in: sandbox)
        let logs = sandbox.paths.logs.appendingPathComponent("Game-1234")
        for index in 0..<5 {
            let file = logs.appendingPathComponent("log \(index).log")
            sandbox.write(String(repeating: "launch \(index)\n", count: 40), to: file)
            setDate(now.addingTimeInterval(Double(-index) * 60), of: file)
        }
        sandbox.write("quiet\n", to: logs.appendingPathComponent("log 9 Shut down.log"))
        sandbox.write("memory", to: logs.appendingPathComponent("log 0 memory/trace.txt"))
        sandbox.write("steam\n", to: sandbox.paths.logs.appendingPathComponent("steam-tool.log"))
        let reports = sandbox.root.appendingPathComponent("reports")
        let crash = reports.appendingPathComponent("wine-game-2026-11-22.ips")
        let unrelated = reports.appendingPathComponent("Finder-2026-11-22.ips")
        for file in [crash, unrelated] { sandbox.write("{}", to: file); setDate(now, of: file) }

        var collector = LogCollector(paths: sandbox.paths, userName: "alice", diagnosticReports: reports, now: now)
        collector.launchLogLimit = 2
        XCTAssertEqual(collector.items(for: prefix).map(\.path),
                       ["finewine/log 0.log", "finewine/log 1.log", "crash-reports/wine-game-2026-11-22.ips"])
        prefix.metadata.steamAppID = "620"
        XCTAssertTrue(collector.items(for: prefix).map(\.path).contains("finewine/steam-tool.log"))
    }

    func testCutsLongFilesAndReplacesTheAccountName() throws {
        let sandbox = Sandbox()
        var collector = LogCollector(paths: sandbox.paths, userName: "alice", diagnosticReports: nil, now: now)
        collector.maximumFileSize = 80
        let file = sandbox.root.appendingPathComponent("long.log")
        sandbox.write("START " + String(repeating: "x", count: 500) + " END\n", to: file)
        let tail = try XCTUnwrap(collector.text(of: file))
        XCTAssertTrue(tail.hasSuffix(" END\n"))
        XCTAssertFalse(tail.contains("START"))
        XCTAssertTrue(tail.contains("bytes left out"))
        let both = try XCTUnwrap(collector.text(of: file, keepStart: true))
        XCTAssertTrue(both.hasPrefix("START ") && both.hasSuffix(" END\n"))

        XCTAssertEqual(collector.redacted(#"/Users/alice/Library C:\users\alice\AppData Z:\Users\alice /Users/alicia Z:\\Users\\alice\\x"#),
                       #"/Users/USER/Library C:\users\USER\AppData Z:\Users\USER /Users/alicia Z:\\Users\\USER\\x"#)
        let wide = sandbox.root.appendingPathComponent("wide.log")
        sandbox.write("hello /Users/alice".data(using: .utf16)!, to: wide)
        XCTAssertEqual(collector.text(of: wide), "hello /Users/USER")
    }

    func testCollectWritesAZipWithTheFolderInside() throws {
        let sandbox = Sandbox()
        let prefix = makePrefix(in: sandbox)
        let collector = LogCollector(paths: sandbox.paths, userName: "alice", diagnosticReports: nil, now: now)
        XCTAssertTrue(collector.suggestedFileName(for: prefix).hasPrefix("FineWine logs My Game "))
        let zip = sandbox.root.appendingPathComponent("FineWine logs.zip")
        try collector.collect(for: prefix, runtime: nil, appVersion: "9.9", into: zip)
        let unzip = Process()
        unzip.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        unzip.arguments = ["-Z1", zip.path]
        let pipe = Pipe()
        unzip.standardOutput = pipe
        try unzip.run()
        let listing = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        unzip.waitUntilExit()
        XCTAssertTrue(listing.contains("FineWine logs/summary.txt"), listing)
    }
}
