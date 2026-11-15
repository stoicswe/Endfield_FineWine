import XCTest
@testable import FineWineCore

final class WindowsPathTests: XCTestCase {
    func testLastComponentAndDirectory() {
        XCTAssertEqual(WindowsPath.lastComponent(#"C:\Program Files\Game\Game.exe"#), "Game.exe")
        XCTAssertEqual(WindowsPath.lastComponent("C:/a/b.exe"), "b.exe")
        XCTAssertEqual(WindowsPath.lastComponent(""), "")
        XCTAssertEqual(WindowsPath.directory(#"C:\Program Files\Game\Game.exe"#), #"C:\Program Files\Game"#)
        XCTAssertEqual(WindowsPath.directory(#"C:\Game.exe"#), #"C:\"#)
        XCTAssertEqual(WindowsPath.directory("Game.exe"), "")
    }

    func testDriveLetter() {
        XCTAssertEqual(WindowsPath.driveLetter(#"C:\x"#), "c")
        XCTAssertEqual(WindowsPath.driveLetter("z:"), "z")
        XCTAssertNil(WindowsPath.driveLetter(#"\\server\share"#))
        XCTAssertNil(WindowsPath.driveLetter("relative\\path"))
        XCTAssertNil(WindowsPath.driveLetter("1:\\x"))
    }

    func testMacURLFallsBackToDriveCAndMatchesCaseInsensitively() throws {
        let sandbox = Sandbox()
        let prefix = sandbox.root.appendingPathComponent("pfx")
        sandbox.write("x", to: prefix.appendingPathComponent("drive_c/Program Files/Game/Game.exe"))
        let url = try XCTUnwrap(WindowsPath.macURL(for: #"C:\PROGRAM FILES\game\GAME.EXE"#, inPrefix: prefix))
        XCTAssertEqual(url.path, prefix.appendingPathComponent("drive_c/Program Files/Game/Game.exe").resolvingSymlinksInPath().path)
    }

    func testMacURLKeepsMissingComponentsAsWritten() throws {
        let sandbox = Sandbox()
        let prefix = sandbox.root.appendingPathComponent("pfx")
        try FileManager.default.createDirectory(at: prefix.appendingPathComponent("drive_c"), withIntermediateDirectories: true)
        let url = try XCTUnwrap(WindowsPath.macURL(for: #"C:\Nope\file.exe"#, inPrefix: prefix))
        XCTAssertTrue(url.path.hasSuffix("drive_c/Nope/file.exe"))
    }

    func testMacURLFollowsDosdevicesAndRejectsUnmappedDrives() throws {
        let sandbox = Sandbox()
        let prefix = sandbox.root.appendingPathComponent("pfx")
        let games = sandbox.root.appendingPathComponent("ExternalGames")
        sandbox.write("x", to: games.appendingPathComponent("a.exe"))
        try FileManager.default.createDirectory(at: prefix.appendingPathComponent("dosdevices"), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: prefix.appendingPathComponent("dosdevices/d:"),
                                                   withDestinationURL: games)
        let url = try XCTUnwrap(WindowsPath.macURL(for: #"D:\a.exe"#, inPrefix: prefix))
        XCTAssertEqual(url.path, games.appendingPathComponent("a.exe").resolvingSymlinksInPath().path)
        XCTAssertNil(WindowsPath.macURL(for: #"E:\a.exe"#, inPrefix: prefix))
        XCTAssertNil(WindowsPath.macURL(for: "relative.exe", inPrefix: prefix))
    }

    func testMacURLHandlesDotComponents() throws {
        let sandbox = Sandbox()
        let prefix = sandbox.root.appendingPathComponent("pfx")
        sandbox.write("x", to: prefix.appendingPathComponent("drive_c/a/b.exe"))
        let url = try XCTUnwrap(WindowsPath.macURL(for: #"C:\a\sub\..\.\b.exe"#, inPrefix: prefix))
        XCTAssertTrue(url.path.hasSuffix("drive_c/a/b.exe"))
    }

    func testWindowsPathForMacFiles() throws {
        let sandbox = Sandbox()
        let prefix = sandbox.root.appendingPathComponent("pfx")
        let inside = prefix.appendingPathComponent("drive_c/Games/a.exe")
        sandbox.write("x", to: inside)
        XCTAssertEqual(WindowsPath.windowsPath(for: inside, inPrefix: prefix), #"C:\Games\a.exe"#)
        XCTAssertEqual(WindowsPath.windowsPath(for: prefix.appendingPathComponent("drive_c"), inPrefix: prefix), #"C:\"#)
        XCTAssertEqual(WindowsPath.windowsPath(for: URL(fileURLWithPath: "/Applications/Setup.exe"), inPrefix: prefix),
                       #"Z:\Applications\Setup.exe"#)
    }

    func testRoundTrip() throws {
        let sandbox = Sandbox()
        let prefix = sandbox.root.appendingPathComponent("pfx")
        let file = prefix.appendingPathComponent("drive_c/Program Files/My Game/run.exe")
        sandbox.write("x", to: file)
        let windows = WindowsPath.windowsPath(for: file, inPrefix: prefix)
        XCTAssertEqual(WindowsPath.macURL(for: windows, inPrefix: prefix)?.path, file.resolvingSymlinksInPath().path)
    }
}
