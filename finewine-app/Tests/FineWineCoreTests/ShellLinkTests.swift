import XCTest
@testable import FineWineCore

final class ShellLinkTests: XCTestCase {
    func testParsesTargetAndStrings() throws {
        let data = LinkBuilder.make(target: #"C:\Program Files\Game\Game.exe"#, name: "The Game",
                                    workingDirectory: #"C:\Program Files\Game"#, arguments: "-windowed \"my save\"")
        let link = try XCTUnwrap(ShellLink(data: data))
        XCTAssertEqual(link.target, #"C:\Program Files\Game\Game.exe"#)
        XCTAssertEqual(link.description, "The Game")
        XCTAssertEqual(link.workingDirectory, #"C:\Program Files\Game"#)
        XCTAssertEqual(link.arguments, "-windowed \"my save\"")
    }

    func testAnsiStringsAndNoIDList() throws {
        let data = LinkBuilder.make(target: #"C:\a.exe"#, arguments: "/x", unicode: false, withIDList: false)
        let link = try XCTUnwrap(ShellLink(data: data))
        XCTAssertEqual(link.target, #"C:\a.exe"#)
        XCTAssertEqual(link.arguments, "/x")
        XCTAssertEqual(link.workingDirectory, "")
    }

    func testPrefersTheUnicodePathWhenPresent() throws {
        let data = LinkBuilder.make(target: #"C:\ゲーム\起動.exe"#, unicodeLinkInfo: true)
        XCTAssertEqual(try XCTUnwrap(ShellLink(data: data)).target, #"C:\ゲーム\起動.exe"#)
    }

    func testRejectsDataThatIsNotAShortcut() {
        XCTAssertNil(ShellLink(data: Data()))
        XCTAssertNil(ShellLink(data: Data(repeating: 0, count: 200)))
        var wrongClass = [UInt8](LinkBuilder.make(target: #"C:\a.exe"#))
        wrongClass[4] = 0xFF
        XCTAssertNil(ShellLink(data: Data(wrongClass)))
    }

    func testTruncatedDataNeverCrashes() {
        let data = LinkBuilder.make(target: #"C:\Program Files\Game\Game.exe"#, name: "n", workingDirectory: "w", arguments: "a")
        for length in 0..<data.count {
            _ = ShellLink(data: data.prefix(length))
        }
    }

    func testSplitArguments() {
        XCTAssertEqual(ProgramScanner.splitArguments(""), [])
        XCTAssertEqual(ProgramScanner.splitArguments("  -a   -b "), ["-a", "-b"])
        XCTAssertEqual(ProgramScanner.splitArguments(#"-file "C:\My Saves\one.sav" -x"#), ["-file", #"C:\My Saves\one.sav"#, "-x"])
        XCTAssertEqual(ProgramScanner.splitArguments(#"--name="two words" """#), ["--name=two words", ""])
    }
}

final class ProgramScannerTests: XCTestCase {
    func testFindsProgramsFromStartMenuAndDesktop() {
        let sandbox = Sandbox()
        let prefix = sandbox.root.appendingPathComponent("pfx")
        let startMenu = prefix.appendingPathComponent("drive_c/ProgramData/Microsoft/Windows/Start Menu/Programs")
        let userDesktop = prefix.appendingPathComponent("drive_c/users/me/Desktop")
        sandbox.write(LinkBuilder.make(target: #"C:\Game\Game.exe"#, arguments: "-fast"),
                      to: startMenu.appendingPathComponent("Studio/The Game.lnk"))
        sandbox.write(LinkBuilder.make(target: #"C:\Game\unins000.exe"#),
                      to: startMenu.appendingPathComponent("Studio/Uninstall The Game.lnk"))
        sandbox.write(LinkBuilder.make(target: #"C:\Game\Readme.txt"#),
                      to: startMenu.appendingPathComponent("Studio/Readme.lnk"))
        sandbox.write(LinkBuilder.make(target: #"C:\GAME\game.exe"#),
                      to: userDesktop.appendingPathComponent("Game (desktop).lnk"))
        sandbox.write(LinkBuilder.make(target: #"C:\Tools\Launcher.exe"#),
                      to: userDesktop.appendingPathComponent("Launcher.lnk"))
        sandbox.write("garbage", to: userDesktop.appendingPathComponent("Broken.lnk"))

        let found = ProgramScanner.scan(prefix: prefix)
        XCTAssertEqual(found.map(\.windowsPath).map { $0.lowercased() }.sorted(),
                       [#"c:\game\game.exe"#, #"c:\tools\launcher.exe"#])
        XCTAssertEqual(found.first { $0.name == "The Game" }?.arguments, "-fast")
    }

    func testEmptyPrefixHasNoPrograms() {
        XCTAssertEqual(ProgramScanner.scan(prefix: URL(fileURLWithPath: "/nonexistent")), [])
    }

    func testUninstallersAreFilteredByNameOrTarget() {
        XCTAssertTrue(ProgramScanner.isProgram(name: "Game", target: #"C:\g.exe"#))
        XCTAssertFalse(ProgramScanner.isProgram(name: "Uninstall Game", target: #"C:\g.exe"#))
        XCTAssertFalse(ProgramScanner.isProgram(name: "Remove", target: #"C:\unins000.exe"#))
        XCTAssertFalse(ProgramScanner.isProgram(name: "Manual", target: #"C:\manual.pdf"#))
    }
}
