import Foundation

/// A Windows program installed in a prefix that FineWine can launch.
public struct Program: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    /// The executable as Windows sees it, e.g. `C:\Program Files\Game\Game.exe`.
    public var windowsPath: String
    /// Extra command-line arguments, one per element.
    public var arguments: [String]
    /// Windows working directory; empty uses the executable's folder.
    public var workingDirectory: String
    /// Variables for this program only, on top of the prefix's.
    public var environment: [EnvironmentVariable]
    /// The generated shortcut app's path, if one exists.
    public var shortcutPath: String?
    /// A Windows file to take the icon from in place of the executable's own: what the
    /// installer's shortcut named, when it named one.
    public var iconPath: String?

    public init(id: UUID = UUID(), name: String, windowsPath: String, arguments: [String] = [],
                workingDirectory: String = "", environment: [EnvironmentVariable] = [],
                shortcutPath: String? = nil, iconPath: String? = nil) {
        self.iconPath = iconPath
        self.id = id
        self.name = name
        self.windowsPath = windowsPath
        self.arguments = arguments
        self.workingDirectory = workingDirectory
        self.environment = environment
        self.shortcutPath = shortcutPath
    }
}

/// `finewine.json` inside a prefix folder: what FineWine knows about the prefix beyond what Wine
/// stores in it.
public struct PrefixMetadata: Codable, Equatable, Sendable {
    public var id: UUID
    public var name: String
    public var runtimeID: String?
    public var profileID: String?
    public var createdAt: Date
    public var settings: PrefixSettings
    /// The settings as last written to the registry, used to remove overrides that were deleted.
    public var appliedSettings: PrefixSettings?
    /// The Mac appearance the styling was last written for, so it can be refreshed when the
    /// Mac switches between light and dark or its accent colour changes.
    public var appliedAppearance: MacAppearance?
    public var programs: [Program]
    /// The Steam app this prefix was made for, when the Mac Steam client started the game
    /// through FineWine's Steam tool. Each Steam game gets a prefix of its own.
    public var steamAppID: String?

    public init(id: UUID = UUID(), name: String, runtimeID: String? = nil, profileID: String? = nil,
                createdAt: Date = Date(), settings: PrefixSettings = PrefixSettings(),
                appliedSettings: PrefixSettings? = nil, programs: [Program] = []) {
        self.id = id
        self.name = name
        self.runtimeID = runtimeID
        self.profileID = profileID
        self.createdAt = createdAt
        self.settings = settings
        self.appliedSettings = appliedSettings
        self.programs = programs
    }
}

/// A prefix on disk: its folder (which is the `WINEPREFIX`) and its metadata.
public struct Prefix: Equatable, Identifiable, Sendable {
    public var metadata: PrefixMetadata
    public var directory: URL
    /// Where it is kept: this Mac, or a drive (see `PrefixDriveStore`).
    public var place: PrefixPlace

    public var id: UUID { metadata.id }
    public var name: String { metadata.name }
    public var driveC: URL { directory.appendingPathComponent("drive_c", isDirectory: true) }

    /// True once Wine has set the prefix up (wineboot has run). Wine writes `.update-timestamp`
    /// straight away; the registry files only appear when its server exits, so either counts.
    public var isInitialized: Bool {
        [".update-timestamp", "system.reg"].contains {
            FileManager.default.fileExists(atPath: directory.appendingPathComponent($0).path)
        }
    }

    public init(metadata: PrefixMetadata, directory: URL, place: PrefixPlace = .thisMac) {
        self.metadata = metadata
        self.directory = directory
        self.place = place
    }

    public func program(id: UUID) -> Program? { metadata.programs.first { $0.id == id } }
}

/// Creates, lists, saves and deletes prefixes.
public struct PrefixStore {
    public static let metadataName = "finewine.json"
    /// The free space a new prefix needs: about 750 MB for the prefix, and room to install.
    public static let minimumFreeBytes: Int64 = 1_500_000_000

    public let paths: FineWinePaths
    /// The drives prefixes can also be kept on.
    public let drives: PrefixDriveStore
    private let fm = FileManager.default

    public init(paths: FineWinePaths, volumes: VolumeProviding = SystemVolumes()) {
        self.paths = paths
        self.drives = PrefixDriveStore(paths: paths, volumes: volumes)
    }

    /// Every place with a prefixes folder there right now: this Mac, and each known drive
    /// that is plugged in.
    func availableFolders() -> [(place: PrefixPlace, folder: URL)] {
        var out: [(PrefixPlace, URL)] = [(.thisMac, paths.prefixes)]
        for drive in drives.drives {
            if let folder = drives.prefixesFolder(for: .drive(drive.uuid)) { out.append((.drive(drive.uuid), folder)) }
        }
        return out
    }

    private static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    private static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    /// Every prefix on this Mac and on the drives plugged in, sorted by name. Folders without
    /// readable metadata are skipped.
    public func list() -> [Prefix] {
        availableFolders().flatMap { place, folder in
            // Hidden folders are a move, snapshot restore or copy under way (see `recoverInterruptedWork`).
            ((try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [])
                .filter { !$0.lastPathComponent.hasPrefix(".") }.compactMap {
                load(directory: $0).map { var prefix = $0; prefix.place = place; return prefix }
            }
        }
        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// Names taken: by the prefixes here, and by those on drives that are unplugged (a name
    /// used twice would be confusing once the drive is back).
    func takenNames(except id: UUID? = nil) -> [String] {
        let here = list().filter { $0.id != id }
        let hereIDs = Set(here.map(\.id))
        let away = drives.drives.flatMap(\.prefixes).filter { $0.id != id && !hereIDs.contains($0.id) }
        return here.map(\.name) + away.map(\.name)
    }

    /// Looks for drives with FineWine prefixes that aren't known yet, and records what is on
    /// each one plugged in. Call it when drives come and go.
    @discardableResult
    public func refreshDrives() -> [PrefixDrive] {
        let added = drives.discover()
        recoverInterruptedWork()
        var byDrive: [String: [Prefix]] = [:]
        for prefix in list() {
            if case .drive(let uuid) = prefix.place { byDrive[uuid, default: []].append(prefix) }
        }
        drives.record(byDrive)
        return added
    }

    public func prefix(id: UUID) -> Prefix? { list().first { $0.id == id } }

    public func load(directory: URL) -> Prefix? {
        guard let data = try? Data(contentsOf: directory.appendingPathComponent(Self.metadataName)),
              let metadata = try? Self.decoder.decode(PrefixMetadata.self, from: data) else { return nil }
        return Prefix(metadata: metadata, directory: directory)
    }

    /// Creates the prefix folder and its metadata. Wine itself fills the folder in when
    /// `wineboot` first runs against it.
    /// `place` is this Mac or a drive FineWine knows (`PrefixDriveStore.use`); a drive must be
    /// plugged in.
    public func create(name: String, runtimeID: String?, profile: GameProfile? = nil,
                       place: PrefixPlace = .thisMac) throws -> Prefix {
        let name = try Self.validatedName(name)
        guard !takenNames().contains(where: { $0.caseInsensitiveCompare(name) == .orderedSame }) else {
            throw FineWineError("A prefix named “\(name)” already exists.")
        }
        try paths.ensureDirectories()
        guard let folder = drives.prefixesFolder(for: place) else {
            let driveName = { if case .drive(let uuid) = place { return drives.drive(uuid)?.name ?? "" }; return "" }()
            throw FineWineError(tr("location.err_not_connected", driveName))
        }
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        // A new prefix is about 750 MB before anything is installed in it. On a full drive Wine
        // fails part way with errors that never mention space, so say so first.
        if let volume = drives.volumes.volume(containing: folder), let free = volume.availableBytes,
           free < Self.minimumFreeBytes {
            let format = { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) }
            let where_ = place == .thisMac ? tr("drive.this_mac") : volume.name
            throw FineWineError(tr("location.err_low_space", where_, format(free), format(Self.minimumFreeBytes)))
        }
        let metadata = PrefixMetadata(name: name, runtimeID: runtimeID, profileID: profile?.id,
                                      createdAt: Self.now(), settings: profile?.settings ?? PrefixSettings())
        let directory = folder.appendingPathComponent(Self.folderName(for: name, id: metadata.id), isDirectory: true)
        try fm.createDirectory(at: directory, withIntermediateDirectories: false)
        let prefix = Prefix(metadata: metadata, directory: directory, place: place)
        try save(prefix)
        return prefix
    }

    public func save(_ prefix: Prefix) throws {
        let data = try Self.encoder.encode(prefix.metadata)
        try data.write(to: prefix.directory.appendingPathComponent(Self.metadataName), options: .atomic)
    }

    /// Renames the prefix. The folder keeps its name, so paths baked into shortcuts stay valid.
    public func rename(_ prefix: Prefix, to newName: String) throws -> Prefix {
        let name = try Self.validatedName(newName)
        guard !takenNames(except: prefix.id).contains(where: { $0.caseInsensitiveCompare(name) == .orderedSame }) else {
            throw FineWineError("A prefix named “\(name)” already exists.")
        }
        var renamed = prefix
        renamed.metadata.name = name
        try save(renamed)
        return renamed
    }

    /// Copies a prefix, Windows files included, under a new name and id, on the same drive.
    /// Programs come along without their shortcuts, which still point at the original.
    public func duplicate(_ prefix: Prefix, as newName: String) throws -> Prefix {
        let name = try Self.validatedName(newName)
        guard !takenNames().contains(where: { $0.caseInsensitiveCompare(name) == .orderedSame }) else {
            throw FineWineError("A prefix named “\(name)” already exists.")
        }
        var metadata = prefix.metadata
        metadata.id = UUID()
        metadata.name = name
        metadata.createdAt = Self.now()
        metadata.programs = metadata.programs.map {
            var program = $0
            program.id = UUID()
            program.shortcutPath = nil
            return program
        }
        let directory = prefix.directory.deletingLastPathComponent().appendingPathComponent(
            Self.folderName(for: name, id: metadata.id), isDirectory: true)
        try fm.copyItem(at: prefix.directory, to: directory)
        let copy = Prefix(metadata: metadata, directory: directory, place: prefix.place)
        try save(copy)
        return copy
    }

    /// Deletes the prefix folder for good. Refuses anything outside a Prefixes folder of
    /// FineWine's (this Mac's, or `FineWine/Prefixes` on a drive plugged in).
    public func delete(_ prefix: Prefix) throws {
        let path = prefix.directory.standardizedFileURL.path
        guard availableFolders().contains(where: { path.hasPrefix($0.folder.standardizedFileURL.path + "/") }) else {
            throw FineWineError("“\(prefix.name)” is not inside FineWine's Prefixes folder, so it was left alone.")
        }
        try fm.removeItem(at: prefix.directory)
    }

    /// The current time to the whole second, which is what the metadata file stores; a prefix
    /// then compares equal to itself after being read back.
    static func now() -> Date { Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded(.down)) }

    // MARK: Names

    static func validatedName(_ raw: String) throws -> String {
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw FineWineError("The prefix needs a name.") }
        guard name.count <= 80 else { throw FineWineError("The prefix name is too long (80 characters at most).") }
        return name
    }

    /// A readable, filesystem-safe folder name: the name reduced to letters, digits and dashes,
    /// plus the start of the id so two similar names never collide.
    static func folderName(for name: String, id: UUID) -> String {
        var slug = ""
        for scalar in name.unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) {
                slug.unicodeScalars.append(scalar)
            } else if !slug.hasSuffix("-") {
                slug.append("-")
            }
        }
        slug = slug.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        if slug.isEmpty { slug = "prefix" }
        return String(slug.prefix(40)) + "-" + id.uuidString.prefix(8).lowercased()
    }
}
