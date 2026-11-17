import XCTest
@testable import FineWineCore

/// Drives that come and go, each a temporary folder standing in for a mounted volume.
final class FakeVolumes: VolumeProviding, @unchecked Sendable {
    var list: [VolumeInfo] = []
    func mounted() -> [VolumeInfo] { list }
    func volume(containing url: URL) -> VolumeInfo? {
        // the deepest mount point the path is under, as macOS answers
        list.filter { url.standardizedFileURL.path.hasPrefix($0.root.standardizedFileURL.path) }
            .max { $0.root.path.count < $1.root.path.count }
    }
}

final class PrefixDriveTests: XCTestCase {
    private var base: URL!
    private var volumes: FakeVolumes!
    private var store: PrefixStore!

    override func setUpWithError() throws {
        base = FileManager.default.temporaryDirectory.appendingPathComponent("fw-drives-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        volumes = FakeVolumes()
        let paths = FineWinePaths(root: base.appendingPathComponent("Support"), shortcuts: base.appendingPathComponent("Shortcuts"))
        store = PrefixStore(paths: paths, volumes: volumes)
        // The startup disk, which is "This Mac" and never offered as a drive.
        volumes.list = [VolumeInfo(root: URL(fileURLWithPath: "/"), uuid: "STARTUP", name: "Macintosh HD",
                                   fileSystem: "apfs", isInternal: true)]
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: base)
    }

    /// Plugs in a drive: a folder mounted at `mountName`.
    @discardableResult
    private func plug(_ name: String, uuid: String, fs: String = "apfs", mountName: String? = nil,
                      local: Bool = true) throws -> VolumeInfo {
        let root = base.appendingPathComponent("Volumes/\(mountName ?? name)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let volume = VolumeInfo(root: root, uuid: uuid, name: name, fileSystem: fs, isInternal: false, isLocal: local)
        volumes.list.append(volume)
        return volume
    }

    private func unplug(_ uuid: String) { volumes.list.removeAll { $0.uuid == uuid } }

    func testOnlyMacFileSystemsCanHoldPrefixes() throws {
        try plug("T7", uuid: "A")
        try plug("Old Stick", uuid: "B", fs: "exfat")
        try plug("NAS", uuid: "C", fs: "smbfs", local: false)
        try plug("Backup", uuid: "D", fs: "hfs")
        let candidates = store.drives.candidateVolumes()
        XCTAssertFalse(candidates.contains { $0.volume.root.path == "/" }, "the startup disk is This Mac, not a drive")
        XCTAssertNil(candidates.first { $0.volume.name == "T7" }?.problem)
        XCTAssertNil(candidates.first { $0.volume.name == "Backup" }?.problem)
        XCTAssertNotNil(candidates.first { $0.volume.name == "Old Stick" }?.problem)
        XCTAssertNotNil(candidates.first { $0.volume.name == "NAS" }?.problem)
        XCTAssertThrowsError(try store.drives.use(candidates.first { $0.volume.name == "Old Stick" }!.volume))
        XCTAssertTrue(store.drives.drives.isEmpty)
    }

    func testAPrefixOnADriveLivesInFineWinePrefixes() throws {
        let t7 = try plug("T7", uuid: "A")
        let place = try store.drives.use(t7)
        XCTAssertEqual(place, .drive("A"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: t7.root.appendingPathComponent("FineWine/.finewine-drive.json").path))
        let prefix = try store.create(name: "Game", runtimeID: nil, place: place)
        XCTAssertEqual(prefix.directory.deletingLastPathComponent().path,
                       t7.root.appendingPathComponent("FineWine/Prefixes").path)
        XCTAssertEqual(store.list().map(\.place), [.drive("A")])
        // and on This Mac, as before
        let local = try store.create(name: "Local", runtimeID: nil)
        XCTAssertEqual(local.place, .thisMac)
        XCTAssertEqual(local.directory.deletingLastPathComponent(), store.paths.prefixes)
    }

    func testAnUnpluggedDrivesPrefixesAreRememberedAndComeBack() throws {
        let t7 = try plug("T7", uuid: "A")
        let game = try store.create(name: "Game", runtimeID: nil, place: try store.drives.use(t7))
        store.refreshDrives()
        unplug("A")
        XCTAssertTrue(store.list().isEmpty)
        XCTAssertEqual(store.drives.drive("A")?.prefixes.map(\.id), [game.id], "listed while unplugged")
        // its name stays taken while the drive is away
        XCTAssertThrowsError(try store.create(name: "game", runtimeID: nil))
        // plugged back in somewhere else, under another mount name: found by its UUID
        let moved = base.appendingPathComponent("Volumes/T7 1")
        try FileManager.default.moveItem(at: t7.root, to: moved)
        volumes.list.append(VolumeInfo(root: moved, uuid: "A", name: "T7", fileSystem: "apfs", isInternal: false))
        XCTAssertEqual(store.list().map(\.id), [game.id])
        store.refreshDrives()
        XCTAssertEqual(store.drives.drive("A")?.lastMountPath, moved.path)
    }

    func testTheDefaultDriveFallsBackToThisMacWhileUnplugged() throws {
        let t7 = try plug("T7", uuid: "A")
        try store.drives.setDefault(try store.drives.use(t7))
        XCTAssertEqual(store.drives.defaultPlace, .drive("A"))
        unplug("A")
        XCTAssertEqual(store.drives.defaultPlace, .thisMac)
        XCTAssertEqual(store.drives.preferredPlace, .drive("A"), "the setting itself is kept")
        XCTAssertThrowsError(try store.create(name: "X", runtimeID: nil, place: .drive("A")))
        XCTAssertThrowsError(try store.drives.setDefault(.drive("nope")))
    }

    func testForgettingADriveLeavesItsPrefixesAndADriveFromAnotherMacIsFound() throws {
        let t7 = try plug("T7", uuid: "A")
        try store.drives.setDefault(try store.drives.use(t7))
        let game = try store.create(name: "Game", runtimeID: nil, place: .drive("A"))
        try store.drives.forget("A")
        XCTAssertNil(store.drives.drive("A"))
        XCTAssertEqual(store.drives.preferredPlace, .thisMac)
        XCTAssertTrue(FileManager.default.fileExists(atPath: game.directory.path), "the prefix stays on the drive")
        // FineWine finds it again (as it would a drive set up on another Mac)
        XCTAssertEqual(store.refreshDrives().map(\.uuid), ["A"])
        XCTAssertEqual(store.list().map(\.id), [game.id])
        // a drive without FineWine's folder is not taken over
        try plug("Photos", uuid: "P")
        XCTAssertTrue(store.refreshDrives().isEmpty)
    }

    func testAFullDriveIsRefusedBeforeWineStarts() throws {
        var t7 = try plug("T7", uuid: "A")
        let place = try store.drives.use(t7)
        t7.availableBytes = 500_000_000
        volumes.list = volumes.list.map { $0.uuid == "A" ? t7 : $0 }
        XCTAssertThrowsError(try store.create(name: "Game", runtimeID: nil, place: place)) {
            XCTAssertTrue($0.localizedDescription.contains("T7"), $0.localizedDescription)
        }
        XCTAssertTrue(store.list().isEmpty, "nothing half-made is left behind")
        t7.availableBytes = 50_000_000_000
        volumes.list = volumes.list.map { $0.uuid == "A" ? t7 : $0 }
        XCTAssertNoThrow(try store.create(name: "Game", runtimeID: nil, place: place))
    }

    func testDeleteAndDuplicateStayOnTheDrive() throws {
        let t7 = try plug("T7", uuid: "A")
        let game = try store.create(name: "Game", runtimeID: nil, place: try store.drives.use(t7))
        let copy = try store.duplicate(game, as: "Game 2")
        XCTAssertEqual(copy.place, .drive("A"))
        XCTAssertEqual(copy.directory.deletingLastPathComponent(), game.directory.deletingLastPathComponent())
        try store.delete(copy)
        XCTAssertFalse(FileManager.default.fileExists(atPath: copy.directory.path))
        // nothing outside a Prefixes folder of FineWine's
        let stray = Prefix(metadata: PrefixMetadata(name: "Stray"), directory: t7.root.appendingPathComponent("Stray"))
        XCTAssertThrowsError(try store.delete(stray))
    }
}

/// Against a real drive: FINEWINE_TEST_VOLUME=/Volumes/<name> swift test --filter SystemVolumeTests
/// (an attached disk image will do). Skipped otherwise.
final class SystemVolumeTests: XCTestCase {
    func testARealDriveIsFoundAndRecognisedAgain() throws {
        guard let path = ProcessInfo.processInfo.environment["FINEWINE_TEST_VOLUME"] else {
            throw XCTSkip("set FINEWINE_TEST_VOLUME to a mounted drive to run this")
        }
        let volumes = SystemVolumes()
        let volume = try XCTUnwrap(volumes.mounted().first { $0.root.path == path }, "mounted() lists \(path)")
        XCTAssertNotNil(volume.uuid)
        XCTAssertFalse(volume.isInternal)
        XCTAssertNotNil(volume.availableBytes)
        XCTAssertEqual(volumes.volume(containing: volume.root.appendingPathComponent("FineWine/Prefixes/x"))?.uuid, volume.uuid,
                       "a folder that doesn't exist yet is placed on its drive")
        let startup = try XCTUnwrap(volumes.mounted().first { $0.root.path == "/" })
        XCTAssertTrue(startup.isInternal)
        print("volume: \(volume.name) uuid \(volume.uuid ?? "-") fs \(volume.fileSystem) problem \(volume.prefixProblem ?? "none")")
    }
}

/// The whole cycle on a real drive, in three runs with the drive ejected and re-attached in
/// between (see docs/project-information/27-prefixes-on-external-drives.md):
///   FINEWINE_TEST_VOLUME=/Volumes/<name> FINEWINE_TEST_RUNTIME=<runtime> FINEWINE_TEST_HOME=<empty dir>
///   FINEWINE_TEST_PHASE=create | unplugged | replugged  swift test --filter RealDriveCycleTests
final class RealDriveCycleTests: XCTestCase {
    func testPhase() throws {
        let env = ProcessInfo.processInfo.environment
        guard let phase = env["FINEWINE_TEST_PHASE"], let home = env["FINEWINE_TEST_HOME"] else {
            throw XCTSkip("set FINEWINE_TEST_PHASE, FINEWINE_TEST_HOME (and the volume and runtime) to run this")
        }
        let base = URL(fileURLWithPath: home)
        let paths = FineWinePaths(root: base.appendingPathComponent("Support"), shortcuts: base.appendingPathComponent("Shortcuts"))
        let service = PrefixService(paths: paths)
        switch phase {
        case "create":
            let volume = try XCTUnwrap(SystemVolumes().mounted().first { $0.root.path == env["FINEWINE_TEST_VOLUME"] })
            let place = try service.prefixes.drives.use(volume)
            try service.prefixes.drives.setDefault(place)
            let runtimeRoot = URL(fileURLWithPath: try XCTUnwrap(env["FINEWINE_TEST_RUNTIME"]))
            let runtime = try service.runtimes.addExternal(runtimeRoot)
            let prefix = try service.createPrefix(name: "On The Drive", runtime: runtime, profile: nil,
                                                  place: service.prefixes.drives.defaultPlace)
            XCTAssertEqual(prefix.place, place)
            XCTAssertTrue(prefix.directory.path.hasPrefix(volume.root.path + "/FineWine/Prefixes/"), prefix.directory.path)
            XCTAssertTrue(prefix.isInitialized)
            service.prefixes.refreshDrives()
            print("created \(prefix.directory.path)")
        case "unplugged":
            XCTAssertTrue(service.prefixes.list().isEmpty)
            let drive = try XCTUnwrap(service.prefixes.drives.drives.first)
            XCTAssertEqual(drive.prefixes.map(\.name), ["On The Drive"])
            XCTAssertEqual(service.prefixes.drives.defaultPlace, .thisMac)
            print("while unplugged: remembered \(drive.prefixes.map(\.name)) on \(drive.name)")
        case "replugged":
            let prefix = try XCTUnwrap(service.prefixes.list().first)
            XCTAssertEqual(prefix.name, "On The Drive")
            XCTAssertTrue(prefix.isInitialized)
            XCTAssertEqual(service.prefixes.drives.defaultPlace, prefix.place)
            print("back: \(prefix.directory.path)")
        default: XCTFail("unknown phase \(phase)")
        }
    }
}
