import XCTest
@testable import FineWineCore

final class PrefixStoreTests: XCTestCase {
    func testCreateWritesMetadataAndLists() throws {
        let sandbox = Sandbox()
        let store = PrefixStore(paths: sandbox.paths)
        let prefix = try store.create(name: "  My Games  ", runtimeID: "r1")
        XCTAssertEqual(prefix.name, "My Games")
        XCTAssertEqual(prefix.metadata.runtimeID, "r1")
        XCTAssertTrue(prefix.directory.path.hasPrefix(sandbox.paths.prefixes.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: prefix.directory.appendingPathComponent("finewine.json").path))
        XCTAssertFalse(prefix.isInitialized)
        XCTAssertEqual(store.list(), [prefix])
        XCTAssertEqual(store.prefix(id: prefix.id), prefix)
    }

    func testCreateFromProfileCopiesItsSettings() throws {
        let store = PrefixStore(paths: Sandbox().paths)
        let prefix = try store.create(name: "Endfield", runtimeID: "r", profile: .endfield)
        XCTAssertEqual(prefix.metadata.profileID, "arknights-endfield")
        XCTAssertEqual(prefix.metadata.settings.windowsBuild, "26100")
        XCTAssertTrue(prefix.metadata.settings.hideHypervisor)
    }

    func testNamesMustBeUniqueIgnoringCaseAndNotEmpty() throws {
        let store = PrefixStore(paths: Sandbox().paths)
        _ = try store.create(name: "Games", runtimeID: nil)
        XCTAssertThrowsError(try store.create(name: "games", runtimeID: nil))
        XCTAssertThrowsError(try store.create(name: "   ", runtimeID: nil))
        XCTAssertThrowsError(try store.create(name: String(repeating: "x", count: 81), runtimeID: nil))
        XCTAssertEqual(store.list().count, 1)
    }

    func testFolderNamesAreSafeAndDistinct() {
        let id = UUID(uuidString: "ABCDEF12-0000-0000-0000-000000000000")!
        XCTAssertEqual(PrefixStore.folderName(for: "Arknights: Endfield / ARM", id: id), "Arknights-Endfield-ARM-abcdef12")
        XCTAssertEqual(PrefixStore.folderName(for: "../..", id: id), "prefix-abcdef12")
        XCTAssertEqual(PrefixStore.folderName(for: "明日方舟", id: id), "明日方舟-abcdef12")
        XCTAssertNotEqual(PrefixStore.folderName(for: "a", id: id), PrefixStore.folderName(for: "a", id: UUID()))
    }

    func testListIsSortedAndSkipsForeignFolders() throws {
        let sandbox = Sandbox()
        let store = PrefixStore(paths: sandbox.paths)
        _ = try store.create(name: "Zeta", runtimeID: nil)
        _ = try store.create(name: "alpha", runtimeID: nil)
        _ = try store.create(name: "Game 10", runtimeID: nil)
        _ = try store.create(name: "Game 9", runtimeID: nil)
        try FileManager.default.createDirectory(at: sandbox.paths.prefixes.appendingPathComponent("stray"),
                                                withIntermediateDirectories: true)
        sandbox.write("not json", to: sandbox.paths.prefixes.appendingPathComponent("broken/finewine.json"))
        XCTAssertEqual(store.list().map(\.name), ["alpha", "Game 9", "Game 10", "Zeta"])
    }

    func testSaveRoundTripsProgramsAndSettings() throws {
        let store = PrefixStore(paths: Sandbox().paths)
        var prefix = try store.create(name: "P", runtimeID: nil)
        prefix.metadata.settings.dpi = 144
        prefix.metadata.programs = [Program(name: "Game", windowsPath: #"C:\Game\game.exe"#, arguments: ["-x"])]
        try store.save(prefix)
        let loaded = try XCTUnwrap(store.prefix(id: prefix.id))
        XCTAssertEqual(loaded.metadata.settings.dpi, 144)
        XCTAssertEqual(loaded.metadata.programs, prefix.metadata.programs)
        XCTAssertEqual(loaded.program(id: prefix.metadata.programs[0].id)?.name, "Game")
    }

    func testRenameKeepsTheFolder() throws {
        let store = PrefixStore(paths: Sandbox().paths)
        let prefix = try store.create(name: "Old", runtimeID: nil)
        _ = try store.create(name: "Taken", runtimeID: nil)
        let renamed = try store.rename(prefix, to: "New")
        XCTAssertEqual(renamed.directory, prefix.directory)
        XCTAssertEqual(store.prefix(id: prefix.id)?.name, "New")
        XCTAssertThrowsError(try store.rename(renamed, to: "taken"))
        XCTAssertNoThrow(try store.rename(renamed, to: "NEW"), "changing only the case of its own name is fine")
    }

    func testDuplicateCopiesFilesAndDropsShortcuts() throws {
        let sandbox = Sandbox()
        let store = PrefixStore(paths: sandbox.paths)
        var prefix = try store.create(name: "Original", runtimeID: "r")
        prefix.metadata.programs = [Program(name: "G", windowsPath: #"C:\g.exe"#, shortcutPath: "/Apps/G.app")]
        try store.save(prefix)
        sandbox.write("data", to: prefix.driveC.appendingPathComponent("file.txt"))

        let copy = try store.duplicate(prefix, as: "Copy")
        XCTAssertNotEqual(copy.id, prefix.id)
        XCTAssertNotEqual(copy.directory, prefix.directory)
        XCTAssertTrue(FileManager.default.fileExists(atPath: copy.driveC.appendingPathComponent("file.txt").path))
        XCTAssertEqual(copy.metadata.programs.count, 1)
        XCTAssertNil(copy.metadata.programs[0].shortcutPath)
        XCTAssertNotEqual(copy.metadata.programs[0].id, prefix.metadata.programs[0].id)
        XCTAssertEqual(store.list().count, 2)
        XCTAssertThrowsError(try store.duplicate(prefix, as: "copy"))
    }

    func testDeleteRemovesTheFolder() throws {
        let store = PrefixStore(paths: Sandbox().paths)
        let prefix = try store.create(name: "Doomed", runtimeID: nil)
        try store.delete(prefix)
        XCTAssertFalse(FileManager.default.fileExists(atPath: prefix.directory.path))
        XCTAssertEqual(store.list(), [])
    }

    func testDeleteRefusesFoldersOutsideThePrefixesFolder() throws {
        let sandbox = Sandbox()
        let store = PrefixStore(paths: sandbox.paths)
        let outside = sandbox.root.appendingPathComponent("precious", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let fake = Prefix(metadata: PrefixMetadata(name: "x"), directory: outside)
        XCTAssertThrowsError(try store.delete(fake))
        XCTAssertTrue(FileManager.default.fileExists(atPath: outside.path))
        // A path that climbs out with ".." is refused too.
        let sneaky = Prefix(metadata: PrefixMetadata(name: "y"),
                            directory: sandbox.paths.prefixes.appendingPathComponent("../../precious"))
        XCTAssertThrowsError(try store.delete(sneaky))
        XCTAssertTrue(FileManager.default.fileExists(atPath: outside.path))
    }

    func testIsInitializedOnceWineHasWrittenItsRegistry() throws {
        let sandbox = Sandbox()
        let prefix = try PrefixStore(paths: sandbox.paths).create(name: "P", runtimeID: nil)
        sandbox.write("WINE REGISTRY Version 2\n", to: prefix.directory.appendingPathComponent("system.reg"))
        XCTAssertTrue(prefix.isInitialized)
    }
}

final class GameProfileTests: XCTestCase {
    func testBuiltInProfilesAreValidAndUnique() {
        XCTAssertEqual(Set(GameProfile.builtIn.map(\.id)).count, GameProfile.builtIn.count)
        for profile in GameProfile.builtIn {
            XCTAssertEqual(profile.settings.validationProblems(), [], profile.id)
            XCTAssertFalse(profile.name.isEmpty)
        }
    }

    func testEndfieldProfile() {
        let profile = GameProfile.endfield
        XCTAssertTrue(profile.matches(windowsPath: #"C:\Program Files\GRYPHLINK\games\EndField Game\endfield.EXE"#))
        XCTAssertFalse(profile.matches(windowsPath: #"C:\Program Files\GRYPHLINK\Launcher.exe"#))
        XCTAssertEqual(profile.launchArguments, ["-force-d3d11"])
        XCTAssertEqual(profile.settings.windowsBuild, "26100")
    }

    func testGenericProfileMatchesNothing() {
        XCTAssertFalse(GameProfile.generic.matches(windowsPath: #"C:\x.exe"#))
    }

    func testUserProfilesAreLoadedAndCanReplaceBuiltIns() throws {
        let sandbox = Sandbox()
        let store = ProfileStore(paths: sandbox.paths)
        XCTAssertEqual(store.list(), GameProfile.builtIn)

        sandbox.write(#"{"id":"my-game","name":"My Game","executables":["Game.exe"],"launchArguments":["-dx11"]}"#,
                      to: sandbox.paths.profiles.appendingPathComponent("my-game.json"))
        sandbox.write(#"{"id":"generic","name":"House default","settings":{"dpi":120}}"#,
                      to: sandbox.paths.profiles.appendingPathComponent("generic.json"))
        sandbox.write("{ nope", to: sandbox.paths.profiles.appendingPathComponent("broken.json"))
        sandbox.write("ignored", to: sandbox.paths.profiles.appendingPathComponent("notes.txt"))

        let list = store.list()
        XCTAssertEqual(list.map(\.id), ["generic", "arknights-endfield", "my-game"])
        XCTAssertEqual(list[0].name, "House default")
        XCTAssertEqual(list[0].settings.dpi, 120)
        XCTAssertEqual(store.profile(id: "my-game")?.launchArguments, ["-dx11"])
        XCTAssertNil(store.profile(id: nil))
        XCTAssertNil(store.profile(id: "missing"))
    }
}
