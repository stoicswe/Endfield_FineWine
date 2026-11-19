import Foundation

/// A prefix that was on a drive the last time FineWine saw it, kept so the prefix can be listed
/// (as not connected) while the drive is unplugged.
public struct KnownPrefix: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var programCount: Int

    public init(id: UUID, name: String, programCount: Int) {
        self.id = id
        self.name = name
        self.programCount = programCount
    }
}

/// A drive FineWine has put prefixes on. It is known by its volume UUID, so it is found again
/// when it is plugged back in, whatever it is called and wherever macOS mounts it.
public struct PrefixDrive: Codable, Equatable, Identifiable, Sendable {
    public var uuid: String
    /// The drive's name when FineWine last saw it.
    public var name: String
    /// Where it was mounted then, shown while it is unplugged.
    public var lastMountPath: String
    /// The prefixes on it then.
    public var prefixes: [KnownPrefix]

    public var id: String { uuid }

    public init(uuid: String, name: String, lastMountPath: String, prefixes: [KnownPrefix] = []) {
        self.uuid = uuid
        self.name = name
        self.lastMountPath = lastMountPath
        self.prefixes = prefixes
    }
}

/// Where a prefix is kept: this Mac (FineWine's own folder, as always) or a drive.
public enum PrefixPlace: Hashable, Sendable {
    case thisMac
    /// A drive, by volume UUID.
    case drive(String)
}

/// The drives FineWine keeps prefixes on, and which one new prefixes go to.
///
/// Users choose a drive, never a folder: on a drive, prefixes are always in
/// `<drive>/FineWine/Prefixes/<prefix>`, the same layout as on the Mac
/// (`~/Library/Application Support/FineWine/Prefixes`), so anyone can find them in Finder. The
/// list of drives is `<FineWine>/prefix-drives.json`; each drive also carries a note in its
/// `FineWine` folder, so a drive moved from another Mac is recognised.
public struct PrefixDriveStore: Sendable {
    /// The folder FineWine owns on a drive, and the prefixes folder inside it.
    public static let folderName = "FineWine"
    public static let prefixesName = "Prefixes"
    static let markerName = ".finewine-drive.json"

    public let paths: FineWinePaths
    public let volumes: VolumeProviding

    public init(paths: FineWinePaths, volumes: VolumeProviding = SystemVolumes()) {
        self.paths = paths
        self.volumes = volumes
    }

    struct Saved: Codable {
        var drives: [PrefixDrive] = []
        /// The drive new prefixes go to; nil for this Mac.
        var defaultDrive: String?
    }

    var file: URL { paths.root.appendingPathComponent("prefix-drives.json") }

    func load() -> Saved {
        guard let data = try? Data(contentsOf: file),
              let saved = try? JSONDecoder().decode(Saved.self, from: data) else { return Saved() }
        return saved
    }

    func save(_ saved: Saved) throws {
        try FileManager.default.createDirectory(at: paths.root, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(saved).write(to: file, options: .atomic)
    }

    // MARK: Drives

    /// Every drive FineWine has used, connected or not, by name.
    public var drives: [PrefixDrive] {
        load().drives.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    public func drive(_ uuid: String) -> PrefixDrive? { load().drives.first { $0.uuid == uuid } }

    /// Where new prefixes go. Falls back to this Mac when the default drive is unplugged, so
    /// a new prefix is never refused for it.
    public var defaultPlace: PrefixPlace {
        guard let uuid = load().defaultDrive else { return .thisMac }
        return mountedVolume(uuid) == nil ? .thisMac : .drive(uuid)
    }

    /// The default as the user set it, plugged in or not.
    public var preferredPlace: PrefixPlace {
        load().defaultDrive.map(PrefixPlace.drive) ?? .thisMac
    }

    public func setDefault(_ place: PrefixPlace) throws {
        var saved = load()
        switch place {
        case .thisMac: saved.defaultDrive = nil
        case .drive(let uuid):
            guard saved.drives.contains(where: { $0.uuid == uuid }) else {
                throw FineWineError(tr("location.err_unknown_drive"))
            }
            saved.defaultDrive = uuid
        }
        try save(saved)
    }

    /// The mounted volume of a drive, if it is plugged in.
    public func mountedVolume(_ uuid: String) -> VolumeInfo? {
        volumes.mounted().first { $0.uuid == uuid }
    }

    /// Volumes a user could put prefixes on: every mounted drive but the Mac's startup disk
    /// (that is "This Mac"), each with the reason it can't be used, if it can't.
    public func candidateVolumes() -> [(volume: VolumeInfo, problem: String?)] {
        volumes.mounted()
            .filter { $0.root.standardizedFileURL.path != "/" }
            .map { volume in (volume, volume.uuid == nil ? tr("location.err_no_uuid", volume.name) : volume.prefixProblem) }
            .sorted { $0.volume.name.localizedStandardCompare($1.volume.name) == .orderedAscending }
    }

    /// The prefixes folder on a mounted volume.
    public static func prefixesFolder(on volume: VolumeInfo) -> URL {
        volume.root.appendingPathComponent(folderName, isDirectory: true)
            .appendingPathComponent(prefixesName, isDirectory: true)
    }

    /// The prefixes folder of a place, if that place is there right now.
    public func prefixesFolder(for place: PrefixPlace) -> URL? {
        switch place {
        case .thisMac: return paths.prefixes
        case .drive(let uuid): return mountedVolume(uuid).map(Self.prefixesFolder(on:))
        }
    }

    /// Makes a drive ready for prefixes: checks it can hold them, creates
    /// `FineWine/Prefixes` on it, and remembers it. Returns the place.
    @discardableResult
    public func use(_ volume: VolumeInfo) throws -> PrefixPlace {
        guard let uuid = volume.uuid else { throw FineWineError(tr("location.err_no_uuid", volume.name)) }
        if let problem = volume.prefixProblem { throw FineWineError(problem) }
        let folder = Self.prefixesFolder(on: volume)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        } catch {
            throw FineWineError(tr("location.err_cannot_write", volume.name, error.localizedDescription))
        }
        try writeMarker(on: volume)
        var saved = load()
        if let index = saved.drives.firstIndex(where: { $0.uuid == uuid }) {
            saved.drives[index].name = volume.name
            saved.drives[index].lastMountPath = volume.root.path
        } else {
            saved.drives.append(PrefixDrive(uuid: uuid, name: volume.name, lastMountPath: volume.root.path))
        }
        try save(saved)
        return .drive(uuid)
    }

    /// Forgets a drive. Its prefixes stay on it; plugging it in again brings them back
    /// (`discover`). The default goes back to this Mac if it was that drive.
    public func forget(_ uuid: String) throws {
        var saved = load()
        saved.drives.removeAll { $0.uuid == uuid }
        if saved.defaultDrive == uuid { saved.defaultDrive = nil }
        try save(saved)
    }

    /// Remembers every mounted drive that has FineWine prefixes on it but isn't known yet: a
    /// drive set up on another Mac, or one forgotten here. Returns the drives it added.
    @discardableResult
    public func discover() -> [PrefixDrive] {
        var saved = load()
        var added: [PrefixDrive] = []
        for volume in volumes.mounted() where volume.root.standardizedFileURL.path != "/" {
            guard let uuid = volume.uuid, volume.prefixProblem == nil,
                  !saved.drives.contains(where: { $0.uuid == uuid }),
                  FileManager.default.fileExists(atPath: volume.root.appendingPathComponent(Self.folderName)
                    .appendingPathComponent(Self.markerName).path) else { continue }
            let drive = PrefixDrive(uuid: uuid, name: volume.name, lastMountPath: volume.root.path)
            saved.drives.append(drive)
            added.append(drive)
        }
        if !added.isEmpty { try? save(saved) }
        return added
    }

    /// Records what is on each connected drive (its name, mount point and prefixes), for
    /// listing them while it is unplugged.
    public func record(_ prefixesByDrive: [String: [Prefix]]) {
        var saved = load()
        var changed = false
        for index in saved.drives.indices {
            let uuid = saved.drives[index].uuid
            guard let volume = mountedVolume(uuid) else { continue }
            let known = (prefixesByDrive[uuid] ?? []).map {
                KnownPrefix(id: $0.id, name: $0.name, programCount: $0.metadata.programs.count)
            }
            let updated = PrefixDrive(uuid: uuid, name: volume.name, lastMountPath: volume.root.path, prefixes: known)
            if updated != saved.drives[index] {
                saved.drives[index] = updated
                changed = true
            }
        }
        if changed { try? save(saved) }
    }

    /// A short note on the drive saying what the folder is, which also lets FineWine on any
    /// Mac recognise the drive.
    func writeMarker(on volume: VolumeInfo) throws {
        let url = volume.root.appendingPathComponent(Self.folderName).appendingPathComponent(Self.markerName)
        guard !FileManager.default.fileExists(atPath: url.path) else { return }
        let note: [String: String] = [
            "about": "Wine prefixes made by FineWine. Each folder in Prefixes is one prefix (a Windows environment).",
            "volume": volume.uuid ?? ""
        ]
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(note).write(to: url, options: .atomic)
    }
}
