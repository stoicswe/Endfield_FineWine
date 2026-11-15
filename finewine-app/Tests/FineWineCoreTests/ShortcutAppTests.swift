import XCTest
@testable import FineWineCore

final class LaunchURLTests: XCTestCase {
    let prefix = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
    let program = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!

    func testLaunchRoundTrip() {
        let url = LaunchURL.launch(prefix: prefix, program: program).url
        XCTAssertEqual(url.absoluteString,
                       "finewine://launch?prefix=11111111-2222-3333-4444-555555555555&program=AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")
        XCTAssertEqual(LaunchURL(url: url), .launch(prefix: prefix, program: program))
    }

    func testShowRoundTrip() {
        let url = LaunchURL.show(prefix: prefix).url
        XCTAssertEqual(LaunchURL(url: url), .show(prefix: prefix))
    }

    func testShowCanNameASection() {
        let url = LaunchURL.show(prefix: prefix, section: "configuration").url
        XCTAssertTrue(url.absoluteString.hasSuffix("&section=configuration"))
        XCTAssertEqual(LaunchURL(url: url), .show(prefix: prefix, section: "configuration"))
        // A section that isn't a plain lowercase word is dropped.
        let odd = URL(string: "finewine://show?prefix=\(prefix)&section=../Etc")!
        XCTAssertEqual(LaunchURL(url: odd), .show(prefix: prefix, section: nil))
    }

    func testParsingIsForgivingAboutCaseAndOrder() {
        let url = URL(string: "FineWine://LAUNCH?program=\(program.uuidString.lowercased())&prefix=\(prefix.uuidString.lowercased())")!
        XCTAssertEqual(LaunchURL(url: url), .launch(prefix: prefix, program: program))
    }

    func testRejectsAnythingElse() {
        for text in ["https://launch?prefix=\(prefix)&program=\(program)",
                     "finewine://launch?prefix=\(prefix)",
                     "finewine://launch?prefix=nope&program=\(program)",
                     "finewine://delete?prefix=\(prefix)",
                     "finewine://launch",
                     "finewine:"] {
            XCTAssertNil(LaunchURL(url: URL(string: text)!), text)
        }
    }

    func testFirstDuplicateParameterWins() {
        let other = UUID()
        let url = URL(string: "finewine://show?prefix=\(prefix)&prefix=\(other)")!
        XCTAssertEqual(LaunchURL(url: url), .show(prefix: prefix))
    }
}

final class ShortcutAppBuilderTests: XCTestCase {
    private func fixture() -> (Sandbox, ShortcutAppBuilder, Prefix, Program) {
        let sandbox = Sandbox()
        let builder = ShortcutAppBuilder(directory: sandbox.paths.shortcuts)
        let prefix = Prefix(metadata: PrefixMetadata(name: "Games"), directory: sandbox.root.appendingPathComponent("pfx"))
        let program = Program(name: "The Game", windowsPath: #"C:\Game\Game.exe"#)
        return (sandbox, builder, prefix, program)
    }

    private func plist(_ app: URL) throws -> [String: Any] {
        let data = try Data(contentsOf: app.appendingPathComponent("Contents/Info.plist"))
        return try XCTUnwrap(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
    }

    func testBuildsARunnableBundle() throws {
        let (_, builder, prefix, program) = fixture()
        let app = try builder.build(for: program, in: prefix, icon: Data("icns-bytes".utf8))
        XCTAssertEqual(app.lastPathComponent, "The Game.app")

        let info = try plist(app)
        XCTAssertEqual(info["CFBundleName"] as? String, "The Game")
        XCTAssertEqual(info["CFBundleExecutable"] as? String, "launcher")
        XCTAssertEqual(info["CFBundlePackageType"] as? String, "APPL")
        XCTAssertEqual(info["CFBundleIconFile"] as? String, "AppIcon")
        XCTAssertEqual(info["LSUIElement"] as? Bool, true)
        XCTAssertEqual(info["CFBundleIdentifier"] as? String,
                       "io.github.stoicswe.FineWine.shortcut." + program.id.uuidString.lowercased())

        let launcher = app.appendingPathComponent("Contents/MacOS/launcher")
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: launcher.path))
        let script = try String(contentsOf: launcher, encoding: .utf8)
        XCTAssertTrue(script.hasPrefix("#!/bin/sh\n"))
        XCTAssertTrue(script.contains("exec /usr/bin/open '\(LaunchURL.launch(prefix: prefix.id, program: program.id).url.absoluteString)'"))
        XCTAssertEqual(try Data(contentsOf: app.appendingPathComponent("Contents/Resources/AppIcon.icns")),
                       Data("icns-bytes".utf8))
    }

    func testTheLauncherScriptIsValidShell() throws {
        let (_, builder, prefix, _) = fixture()
        // A hostile program name must stay inside the comment line.
        let program = Program(name: "Evil'\n rm -rf ~ #", windowsPath: #"C:\e.exe"#)
        let app = try builder.build(for: program, in: prefix, icon: nil)
        let launcher = app.appendingPathComponent("Contents/MacOS/launcher")
        let script = try String(contentsOf: launcher, encoding: .utf8)
        XCTAssertEqual(script.split(separator: "\n").count, 3)
        let check = Process()
        check.executableURL = URL(fileURLWithPath: "/bin/sh")
        check.arguments = ["-n", launcher.path]
        try check.run()
        check.waitUntilExit()
        XCTAssertEqual(check.terminationStatus, 0)
    }

    func testWithoutAnIconThereIsNoIconKey() throws {
        let (_, builder, prefix, program) = fixture()
        let app = try builder.build(for: program, in: prefix, icon: nil)
        XCTAssertNil(try plist(app)["CFBundleIconFile"])
    }

    func testRebuildingReplacesTheSameShortcut() throws {
        let (_, builder, prefix, program) = fixture()
        let first = try builder.build(for: program, in: prefix, icon: nil)
        var renamed = program
        renamed.name = "Renamed"
        let second = try builder.build(for: renamed, in: prefix, icon: nil)
        XCTAssertEqual(first, second, "the shortcut keeps its place so Dock entries stay valid")
        XCTAssertEqual(try plist(second)["CFBundleName"] as? String, "Renamed")
        XCTAssertEqual(builder.list().count, 1)
    }

    func testDifferentProgramsWithTheSameNameGetDifferentShortcuts() throws {
        let (_, builder, prefix, program) = fixture()
        let twin = Program(name: program.name, windowsPath: #"C:\Other\Game.exe"#)
        let a = try builder.build(for: program, in: prefix, icon: nil)
        let b = try builder.build(for: twin, in: prefix, icon: nil)
        XCTAssertEqual(a.lastPathComponent, "The Game.app")
        XCTAssertEqual(b.lastPathComponent, "The Game 2.app")
    }

    func testListReadsBackOnlyFineWineShortcuts() throws {
        let (sandbox, builder, prefix, program) = fixture()
        let app = try builder.build(for: program, in: prefix, icon: nil)
        sandbox.write("<plist><dict/></plist>", to: sandbox.paths.shortcuts.appendingPathComponent("Other.app/Contents/Info.plist"))
        sandbox.write("x", to: sandbox.paths.shortcuts.appendingPathComponent("notes.txt"))
        XCTAssertEqual(builder.list(), [ShortcutAppBuilder.Shortcut(url: app, prefixID: prefix.id, programID: program.id)])
    }

    func testRemoveByProgramAndByPrefix() throws {
        let (sandbox, builder, prefix, program) = fixture()
        let other = Prefix(metadata: PrefixMetadata(name: "Other"), directory: sandbox.root.appendingPathComponent("other"))
        try builder.build(for: program, in: prefix, icon: nil)
        try builder.build(for: Program(name: "Second", windowsPath: #"C:\2.exe"#), in: prefix, icon: nil)
        let keep = try builder.build(for: Program(name: "Keep", windowsPath: #"C:\k.exe"#), in: other, icon: nil)
        let foreign = sandbox.paths.shortcuts.appendingPathComponent("Other.app/Contents/Info.plist")
        sandbox.write("<plist><dict/></plist>", to: foreign)

        try builder.remove(programID: program.id)
        XCTAssertEqual(builder.list().count, 2)
        XCTAssertEqual(try builder.removeAll(prefixID: prefix.id), 1)
        XCTAssertEqual(builder.list().map(\.url), [keep])
        XCTAssertTrue(FileManager.default.fileExists(atPath: foreign.path), "apps FineWine didn't make are never removed")
    }

    func testSanitizedNames() {
        XCTAssertEqual(ShortcutAppBuilder.sanitizedName("A/B: C"), "A-B- C")
        XCTAssertEqual(ShortcutAppBuilder.sanitizedName("..hidden"), "hidden")
        XCTAssertEqual(ShortcutAppBuilder.sanitizedName("  \n "), "Windows Program")
        XCTAssertEqual(ShortcutAppBuilder.sanitizedName("two\nlines"), "two lines")
        XCTAssertEqual(ShortcutAppBuilder.sanitizedName(String(repeating: "x", count: 300)).count, 100)
    }

    func testNoStagingFoldersAreLeftBehind() throws {
        let (sandbox, builder, prefix, program) = fixture()
        try builder.build(for: program, in: prefix, icon: nil)
        let names = try FileManager.default.contentsOfDirectory(atPath: sandbox.paths.shortcuts.path)
        XCTAssertEqual(names, ["The Game.app"])
    }
}
