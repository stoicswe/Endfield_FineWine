import XCTest
@testable import FineWineCore

final class WindowsExecutableTests: XCTestCase {
    private func prefix(_ name: String, in sandbox: Sandbox) -> Prefix {
        let dir = sandbox.root.appendingPathComponent(name, isDirectory: true)
        try! FileManager.default.createDirectory(at: dir.appendingPathComponent("drive_c"), withIntermediateDirectories: true)
        return Prefix(metadata: PrefixMetadata(name: name), directory: dir)
    }

    func testSupportedFiles() {
        XCTAssertTrue(WindowsExecutable.isSupported(URL(fileURLWithPath: "/a/Setup.exe")))
        XCTAssertTrue(WindowsExecutable.isSupported(URL(fileURLWithPath: "/a/Thing.MSI")))
        XCTAssertFalse(WindowsExecutable.isSupported(URL(fileURLWithPath: "/a/readme.txt")))
        XCTAssertFalse(WindowsExecutable.isSupported(URL(fileURLWithPath: "/a/exe")))
        XCTAssertFalse(WindowsExecutable.isSupported(URL(string: "https://example.com/Setup.exe")!))
        XCTAssertFalse(WindowsExecutable.isSupported(URL(string: "finewine://launch")!))
    }

    func testOwningPrefix() {
        let sandbox = Sandbox()
        let games = prefix("games", in: sandbox), tools = prefix("tools", in: sandbox)
        let inside = tools.driveC.appendingPathComponent("App/app.exe")
        sandbox.write("x", to: inside)
        XCTAssertEqual(WindowsExecutable.owningPrefix(of: inside, among: [games, tools]), tools)
        XCTAssertNil(WindowsExecutable.owningPrefix(of: sandbox.root.appendingPathComponent("Setup.exe"), among: [games, tools]))
        // A sibling folder whose name merely starts the same way is not inside the prefix.
        let lookalike = sandbox.root.appendingPathComponent("tools-backup/app.exe")
        sandbox.write("x", to: lookalike)
        XCTAssertNil(WindowsExecutable.owningPrefix(of: lookalike, among: [games, tools]))
    }

    func testRoutes() {
        let sandbox = Sandbox()
        let games = prefix("games", in: sandbox), tools = prefix("tools", in: sandbox)
        let download = sandbox.root.appendingPathComponent("Downloads/Setup.exe")
        let installed = games.driveC.appendingPathComponent("Game/game.exe")
        sandbox.write("x", to: download)
        sandbox.write("x", to: installed)

        XCTAssertEqual(WindowsExecutable.route(for: URL(fileURLWithPath: "/a/notes.txt"), prefixes: [games]), .unsupported)
        XCTAssertEqual(WindowsExecutable.route(for: download, prefixes: []), .needsPrefix)
        XCTAssertEqual(WindowsExecutable.route(for: download, prefixes: [games]), .choose(from: [games]),
                       "a file from outside is confirmed even when there is only one prefix")
        XCTAssertEqual(WindowsExecutable.route(for: download, prefixes: [games, tools]), .choose(from: [games, tools]))
        XCTAssertEqual(WindowsExecutable.route(for: installed, prefixes: [tools, games]), .run(in: games))
    }

    func testTypeIdentifiersCoverEveryExtension() {
        XCTAssertEqual(WindowsExecutable.typeIdentifiers.count, WindowsExecutable.extensions.count)
        XCTAssertEqual(WindowsExecutable.exeTypeIdentifier, "com.microsoft.windows-executable")
    }
}
