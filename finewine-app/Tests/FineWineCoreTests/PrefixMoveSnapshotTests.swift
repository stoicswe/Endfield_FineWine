import XCTest
@testable import FineWineCore

/// Moving prefixes between this Mac and drives, and snapshots, against stand-in drives
/// (`FakeVolumes`): each drive is a folder, so a move between "volumes" is a real copy.
final class PrefixMoveSnapshotTests: XCTestCase {
    private var base: URL!
    private var volumes: FakeVolumes!
    private var store: PrefixStore!
    private let fm = FileManager.default

    override func setUpWithError() throws {
        base = fm.temporaryDirectory.appendingPathComponent("fw-moves-\(UUID().uuidString)")
        try fm.createDirectory(at: base, withIntermediateDirectories: true)
        volumes = FakeVolumes()
        let paths = FineWinePaths(root: base.appendingPathComponent("Support"), shortcuts: base.appendingPathComponent("Shortcuts"))
        store = PrefixStore(paths: paths, volumes: volumes)
        volumes.list = [VolumeInfo(root: URL(fileURLWithPath: "/"), uuid: "STARTUP", name: "Macintosh HD",
                                   fileSystem: "apfs", isInternal: true)]
    }

    override func tearDownWithError() throws {
        try? fm.removeItem(at: base)
    }

    @discardableResult
    private func plug(_ name: String, uuid: String, free: Int64? = nil) throws -> VolumeInfo {
        let root = base.appendingPathComponent("Volumes/\(name)", isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        let volume = VolumeInfo(root: root, uuid: uuid, name: name, fileSystem: "apfs", isInternal: false,
                                availableBytes: free)
        volumes.list.append(volume)
        try store.drives.use(volume)
        return volume
    }

    private func setFree(_ uuid: String, _ bytes: Int64?) {
        if let index = volumes.list.firstIndex(where: { $0.uuid == uuid }) { volumes.list[index].availableBytes = bytes }
    }

    /// A prefix with what Wine makes: drive letters as links (z: to the whole Mac), a registry
    /// file, an executable and a large file.
    private func makePrefix(_ name: String, place: PrefixPlace = .thisMac) throws -> Prefix {
        var prefix = try store.create(name: name, runtimeID: "fw", place: place)
        let dir = prefix.directory
        try fm.createDirectory(at: dir.appendingPathComponent("drive_c/Game"), withIntermediateDirectories: true)
        try fm.createDirectory(at: dir.appendingPathComponent("dosdevices"), withIntermediateDirectories: true)
        try fm.createSymbolicLink(atPath: dir.appendingPathComponent("dosdevices/c:").path, withDestinationPath: "../drive_c")
        try fm.createSymbolicLink(atPath: dir.appendingPathComponent("dosdevices/z:").path, withDestinationPath: "/")
        try Data("WINE REGISTRY Version 2\n".utf8).write(to: dir.appendingPathComponent("system.reg"))
        let exe = dir.appendingPathComponent("drive_c/Game/Game.exe")
        try Data("MZ".utf8).write(to: exe)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: exe.path)
        try Data(repeating: 7, count: 3_000_000).write(to: dir.appendingPathComponent("drive_c/Game/data.pak"))
        prefix.metadata.programs = [Program(name: "Game", windowsPath: #"C:\Game\Game.exe"#, shortcutPath: "/nowhere/Game.app")]
        try store.save(prefix)
        return prefix
    }

    private func assertLooksLikeTheGame(_ dir: URL, file: StaticString = #filePath, line: UInt = #line) throws {
        XCTAssertEqual(try fm.destinationOfSymbolicLink(atPath: dir.appendingPathComponent("dosdevices/z:").path), "/",
                       file: file, line: line)
        XCTAssertEqual(try fm.destinationOfSymbolicLink(atPath: dir.appendingPathComponent("dosdevices/c:").path), "../drive_c",
                       file: file, line: line)
        XCTAssertEqual(try Data(contentsOf: dir.appendingPathComponent("drive_c/Game/data.pak")).count, 3_000_000,
                       file: file, line: line)
        let mode = try fm.attributesOfItem(atPath: dir.appendingPathComponent("drive_c/Game/Game.exe").path)[.posixPermissions] as? Int
        XCTAssertEqual(mode, 0o755, file: file, line: line)
    }

    // MARK: Copying

    func testCopyKeepsLinksAsLinksAndReportsProgress() throws {
        let prefix = try makePrefix("Game")
        let progress = CopyProgress()
        let copy = base.appendingPathComponent("copy")
        try FolderCopy.copy(prefix.directory, to: copy, progress: progress)
        try assertLooksLikeTheGame(copy)
        // z: was copied as a link, not followed into the whole Mac.
        XCTAssertLessThan(FolderCopy.measure(copy).bytes, 4_000_000)
        XCTAssertEqual(progress.copiedBytes, progress.totalBytes)
        XCTAssertEqual(progress.fraction, 1)
    }

    func testCancelledCopyLeavesNothingBehind() throws {
        let prefix = try makePrefix("Game")
        let progress = CopyProgress()
        progress.cancel()
        let copy = base.appendingPathComponent("copy")
        XCTAssertThrowsError(try FolderCopy.copy(prefix.directory, to: copy, progress: progress)) {
            XCTAssertEqual(($0 as? FineWineError)?.message, FolderCopy.cancelledMessage)
        }
        XCTAssertFalse(fm.fileExists(atPath: copy.path))
        XCTAssertTrue(fm.fileExists(atPath: prefix.directory.appendingPathComponent("drive_c/Game/data.pak").path))
    }

    // MARK: Moving

    func testMoveToADriveAndBack() throws {
        let drive = try plug("T7", uuid: "T7-UUID")
        let prefix = try makePrefix("Game")
        let folderName = prefix.directory.lastPathComponent

        let moved = try store.move(prefix, to: .drive("T7-UUID"))
        XCTAssertEqual(moved.directory.path,
                       PrefixDriveStore.prefixesFolder(on: drive).appendingPathComponent(folderName).path)
        XCTAssertFalse(fm.fileExists(atPath: prefix.directory.path), "the original is gone once the copy is complete")
        try assertLooksLikeTheGame(moved.directory)
        let listed = store.list()
        XCTAssertEqual(listed.map(\.id), [prefix.id])
        XCTAssertEqual(listed.first?.place, .drive("T7-UUID"))
        XCTAssertEqual(listed.first?.metadata.programs.first?.shortcutPath, "/nowhere/Game.app", "shortcuts go by id")
        // nothing hidden left on either side
        XCTAssertEqual(try fm.contentsOfDirectory(atPath: moved.directory.deletingLastPathComponent().path), [folderName])
        XCTAssertEqual(try fm.contentsOfDirectory(atPath: store.paths.prefixes.path), [])

        let back = try store.move(moved, to: .thisMac)
        XCTAssertEqual(back.directory.path, prefix.directory.path)
        XCTAssertEqual(store.list().first?.place, .thisMac)
        try assertLooksLikeTheGame(back.directory)
    }

    func testMoveIsRefusedWhenItWouldNotFitOrTheDriveIsAway() throws {
        try plug("Small", uuid: "S", free: 50_000_000)
        try plug("Away", uuid: "A")
        let prefix = try makePrefix("Game")
        XCTAssertThrowsError(try store.move(prefix, to: .drive("S"))) {
            XCTAssertTrue($0.localizedDescription.contains("Small"), $0.localizedDescription)
        }
        volumes.list.removeAll { $0.uuid == "A" }
        XCTAssertThrowsError(try store.move(prefix, to: .drive("A")))
        XCTAssertThrowsError(try store.move(prefix, to: .thisMac), "already there")
        try assertLooksLikeTheGame(prefix.directory)
        XCTAssertEqual(store.list().map(\.place), [.thisMac])
    }

    func testCancelledMoveKeepsThePrefixWhereItWas() throws {
        let drive = try plug("T7", uuid: "T7")
        let prefix = try makePrefix("Game")
        let progress = CopyProgress()
        progress.cancel()
        XCTAssertThrowsError(try store.move(prefix, to: .drive("T7"), progress: progress))
        try assertLooksLikeTheGame(prefix.directory)
        XCTAssertEqual(try fm.contentsOfDirectory(atPath: PrefixDriveStore.prefixesFolder(on: drive).path), [])
        XCTAssertEqual(store.list().map(\.place), [.thisMac])
    }

    // MARK: Snapshots

    func testSnapshotThenRestore() throws {
        var prefix = try makePrefix("Game")
        let snapshot = try store.takeSnapshot(of: prefix, note: "  before the update ")
        XCTAssertEqual(snapshot.note, "before the update")
        XCTAssertEqual(snapshot.place, .thisMac)
        XCTAssertEqual(snapshot.directory.deletingLastPathComponent().lastPathComponent, prefix.directory.lastPathComponent)
        XCTAssertEqual(snapshot.directory.deletingLastPathComponent().deletingLastPathComponent().path,
                       store.paths.root.appendingPathComponent("Snapshots").path)
        try assertLooksLikeTheGame(snapshot.contents)
        XCTAssertEqual(store.snapshots(of: prefix.id).map(\.id), [snapshot.id])
        XCTAssertEqual(store.list().count, 1, "a snapshot is not listed as a prefix")

        // Things change after the snapshot...
        try Data("patched".utf8).write(to: prefix.directory.appendingPathComponent("drive_c/Game/patch.dll"))
        prefix.metadata.programs.append(Program(name: "Launcher", windowsPath: #"C:\Game\Launcher.exe"#))
        prefix.metadata.settings.dpi = 192
        try store.save(prefix)
        prefix = try store.rename(prefix, to: "Game (renamed)")

        // ...and the restore puts them back, keeping the name it has now.
        let restored = try store.restore(snapshot, over: prefix)
        XCTAssertFalse(fm.fileExists(atPath: prefix.directory.appendingPathComponent("drive_c/Game/patch.dll").path))
        try assertLooksLikeTheGame(prefix.directory)
        XCTAssertEqual(restored.metadata.programs.map(\.name), ["Game"])
        XCTAssertNotEqual(restored.metadata.settings.dpi, 192)
        XCTAssertEqual(restored.name, "Game (renamed)")
        XCTAssertEqual(store.prefix(id: prefix.id)?.name, "Game (renamed)")
        XCTAssertEqual(try fm.contentsOfDirectory(atPath: store.paths.prefixes.path), [prefix.directory.lastPathComponent])
        try assertLooksLikeTheGame(snapshot.contents)
    }

    func testSnapshotOnAnotherDriveOutlivesThePrefix() throws {
        let drive = try plug("Backup", uuid: "B")
        let prefix = try makePrefix("Game")
        let first = try store.takeSnapshot(of: prefix, on: .drive("B"))
        let second = try store.takeSnapshot(of: prefix, on: .drive("B"))
        XCTAssertNotEqual(first.directory, second.directory, "two in the same second get their own folders")
        XCTAssertTrue(first.directory.path.hasPrefix(drive.root.appendingPathComponent("FineWine/Snapshots").path))
        try assertLooksLikeTheGame(first.contents)

        try store.delete(prefix)
        XCTAssertEqual(Set(store.snapshots().map(\.id)), [first.id, second.id], "snapshots stay when the prefix goes")

        let made = try store.restoreAsNew(first, name: "Game (restored)")
        XCTAssertNotEqual(made.id, prefix.id)
        XCTAssertEqual(made.place, .drive("B"), "made next to the snapshot")
        XCTAssertEqual(made.metadata.programs.map(\.name), ["Game"])
        XCTAssertNil(made.metadata.programs.first?.shortcutPath, "the old shortcut was the deleted prefix's")
        try assertLooksLikeTheGame(made.directory)
        XCTAssertEqual(store.list().map(\.name), ["Game (restored)"])

        // Unplugged, its snapshots aren't listed; back, they are.
        volumes.list.removeAll { $0.uuid == "B" }
        XCTAssertTrue(store.snapshots().isEmpty)
        volumes.list.append(drive)
        XCTAssertEqual(store.snapshots().count, 2)

        try store.deleteSnapshot(first)
        try store.deleteSnapshot(second)
        XCTAssertTrue(store.snapshots().isEmpty)
        XCTAssertFalse(fm.fileExists(atPath: first.directory.deletingLastPathComponent().path), "the empty group goes too")
    }

    func testSnapshotIsRefusedWhenTheDriveIsTooFull() throws {
        try plug("Small", uuid: "S", free: 10_000_000)
        let prefix = try makePrefix("Game")
        XCTAssertThrowsError(try store.takeSnapshot(of: prefix, on: .drive("S")))
        XCTAssertTrue(store.snapshots().isEmpty)
        // Nothing half-made is left in the drive's Snapshots folder.
        let group = store.snapshotsFolder(for: .drive("S"))!.appendingPathComponent(prefix.directory.lastPathComponent)
        XCTAssertEqual((try? fm.contentsOfDirectory(atPath: group.path)) ?? [], [])
    }

    func testDeleteSnapshotRefusesOtherFolders() throws {
        let elsewhere = base.appendingPathComponent("Documents/Important")
        try fm.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        var fake = PrefixSnapshot(prefixID: UUID(), prefixName: "x", note: "", createdAt: Date(), bytes: 0)
        fake.directory = elsewhere
        XCTAssertThrowsError(try store.deleteSnapshot(fake))
        XCTAssertTrue(fm.fileExists(atPath: elsewhere.path))
    }

    // MARK: Interrupted work

    func testInterruptedWorkIsPutRight() throws {
        let prefix = try makePrefix("Game")
        let folder = prefix.directory.deletingLastPathComponent()
        let name = prefix.directory.lastPathComponent
        // FineWine stopped between putting the prefix aside and swapping its copy in.
        try fm.moveItem(at: prefix.directory, to: folder.appendingPathComponent(".leaving-" + name))
        try fm.createDirectory(at: folder.appendingPathComponent(".copying-" + name + "/drive_c"), withIntermediateDirectories: true)
        XCTAssertTrue(store.list().isEmpty)

        store.refreshDrives()
        XCTAssertEqual(store.list().map(\.id), [prefix.id])
        XCTAssertEqual(try fm.contentsOfDirectory(atPath: folder.path), [name])
        try assertLooksLikeTheGame(prefix.directory)

        // A put-aside copy whose prefix made it is just removed.
        try FolderCopy.copy(prefix.directory, to: folder.appendingPathComponent(".leaving-" + name))
        store.refreshDrives()
        XCTAssertEqual(try fm.contentsOfDirectory(atPath: folder.path), [name])
    }

    // MARK: Service

    func testRunningProgramsStopAMoveOrSnapshot() throws {
        let sandbox = Sandbox()
        var service = PrefixService(paths: sandbox.paths, runner: RecordingRunner(), volumes: volumes)
        service.findProcesses = { _ in [4242] }
        service.commandsOfProcesses = { _ in [#"C:\Game\Game.exe"#] }
        let prefix = try service.prefixes.create(name: "Busy", runtimeID: nil)
        XCTAssertThrowsError(try service.takeSnapshot(of: prefix)) {
            XCTAssertTrue($0.localizedDescription.contains("Game"), $0.localizedDescription)
        }
        XCTAssertThrowsError(try service.movePrefix(prefix, to: .thisMac))
        XCTAssertTrue(service.prefixes.snapshots().isEmpty)
    }

    func testRestoreKeepsShortcutsOfProgramsThatComeBack() throws {
        let sandbox = Sandbox()
        var service = PrefixService(paths: sandbox.paths, runner: RecordingRunner(), volumes: volumes)
        service.findProcesses = { _ in [] }
        var prefix = try service.prefixes.create(name: "Games", runtimeID: nil)
        let game = Program(name: "Game", windowsPath: #"C:\Game.exe"#)
        prefix.metadata.programs = [game]
        try service.prefixes.save(prefix)
        let snapshot = try service.takeSnapshot(of: prefix)

        // Later: a shortcut for the game, and a second program with its own shortcut.
        let gameApp = try service.shortcuts.build(for: game, in: prefix, icon: nil)
        let tool = Program(name: "Tool", windowsPath: #"C:\Tool.exe"#)
        prefix.metadata.programs = [game, tool]
        let toolApp = try service.shortcuts.build(for: tool, in: prefix, icon: nil)
        try service.prefixes.save(prefix)

        let (restored, kept) = try service.restoreSnapshot(snapshot, over: prefix, keepingCurrent: true)
        XCTAssertEqual(restored.metadata.programs.map(\.name), ["Game"])
        XCTAssertEqual(restored.metadata.programs.first?.shortcutPath, gameApp.path)
        XCTAssertTrue(fm.fileExists(atPath: gameApp.path))
        XCTAssertFalse(fm.fileExists(atPath: toolApp.path), "the shortcut of a program that is gone goes too")
        // The state before the restore was kept, with both programs.
        let before = try XCTUnwrap(kept)
        XCTAssertEqual(service.prefixes.load(directory: before.contents)?.metadata.programs.map(\.name), ["Game", "Tool"])
        XCTAssertEqual(service.prefixes.snapshots(of: prefix.id).count, 2)
    }
}
