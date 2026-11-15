import XCTest
@testable import FineWineCore

final class PathsTests: XCTestCase {
    func testStandardLocations() {
        let paths = FineWinePaths.standard(environment: [:], home: URL(fileURLWithPath: "/Users/me"))
        XCTAssertEqual(paths.root.path, "/Users/me/Library/Application Support/FineWine")
        XCTAssertEqual(paths.shortcuts.path, "/Users/me/Applications/FineWine")
        XCTAssertEqual(paths.prefixes.path, "/Users/me/Library/Application Support/FineWine/Prefixes")
        XCTAssertEqual(paths.runtimes.lastPathComponent, "Runtimes")
        XCTAssertEqual(paths.logs.lastPathComponent, "Logs")
        XCTAssertEqual(paths.profiles.lastPathComponent, "Profiles")
    }

    func testHomeOverrideMovesEverything() {
        let paths = FineWinePaths.standard(environment: ["FINEWINE_HOME": "/tmp/fw"], home: URL(fileURLWithPath: "/Users/me"))
        XCTAssertEqual(paths.root.path, "/tmp/fw/Support")
        XCTAssertEqual(paths.shortcuts.path, "/tmp/fw/Shortcuts")
    }

    func testRelativeOverrideIsIgnored() {
        let paths = FineWinePaths.standard(environment: ["FINEWINE_HOME": "relative"], home: URL(fileURLWithPath: "/Users/me"))
        XCTAssertEqual(paths.root.path, "/Users/me/Library/Application Support/FineWine")
    }

    func testEnsureDirectoriesCreatesTheTree() throws {
        let sandbox = Sandbox()
        try sandbox.paths.ensureDirectories()
        for dir in [sandbox.paths.prefixes, sandbox.paths.runtimes, sandbox.paths.profiles, sandbox.paths.logs] {
            var isDir: ObjCBool = false
            XCTAssertTrue(FileManager.default.fileExists(atPath: dir.path, isDirectory: &isDir) && isDir.boolValue)
        }
        XCTAssertNoThrow(try sandbox.paths.ensureDirectories(), "safe to call again")
    }
}
