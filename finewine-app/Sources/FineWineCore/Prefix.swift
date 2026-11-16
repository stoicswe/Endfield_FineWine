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

    public init(metadata: PrefixMetadata, directory: URL) {
        self.metadata = metadata
        self.directory = directory
    }

    public func program(id: UUID) -> Program? { metadata.programs.first { $0.id == id } }
}

/// Creates, lists, saves and deletes prefixes.
public struct PrefixStore {
    public static let metadataName = "finewine.json"

    public let paths: FineWinePaths
    private let fm = FileManager.default

    public init(paths: FineWinePaths) { self.paths = paths }

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

    /// Every prefix, sorted by name. Folders without readable metadata are skipped.
    public func list() -> [Prefix] {
        let dirs = (try? fm.contentsOfDirectory(at: paths.prefixes, includingPropertiesForKeys: nil)) ?? []
        return dirs.compactMap(load(directory:))
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    public func prefix(id: UUID) -> Prefix? { list().first { $0.id == id } }

    public func load(directory: URL) -> Prefix? {
        guard let data = try? Data(contentsOf: directory.appendingPathComponent(Self.metadataName)),
              let metadata = try? Self.decoder.decode(PrefixMetadata.self, from: data) else { return nil }
        return Prefix(metadata: metadata, directory: directory)
    }

    /// Creates the prefix folder and its metadata. Wine itself fills the folder in when
    /// `wineboot` first runs against it.
    public func create(name: String, runtimeID: String?, profile: GameProfile? = nil) throws -> Prefix {
        let name = try Self.validatedName(name)
        guard !list().contains(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) else {
            throw FineWineError("A prefix named “\(name)” already exists.")
        }
        try paths.ensureDirectories()
        let metadata = PrefixMetadata(name: name, runtimeID: runtimeID, profileID: profile?.id,
                                      createdAt: Self.now(), settings: profile?.settings ?? PrefixSettings())
        let directory = paths.prefixes.appendingPathComponent(
            Self.folderName(for: name, id: metadata.id), isDirectory: true)
        try fm.createDirectory(at: directory, withIntermediateDirectories: false)
        let prefix = Prefix(metadata: metadata, directory: directory)
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
        guard !list().contains(where: { $0.id != prefix.id && $0.name.caseInsensitiveCompare(name) == .orderedSame }) else {
            throw FineWineError("A prefix named “\(name)” already exists.")
        }
        var renamed = prefix
        renamed.metadata.name = name
        try save(renamed)
        return renamed
    }

    /// Copies a prefix, Windows files included, under a new name and id. Programs come along
    /// without their shortcuts, which still point at the original.
    public func duplicate(_ prefix: Prefix, as newName: String) throws -> Prefix {
        let name = try Self.validatedName(newName)
        guard !list().contains(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) else {
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
        let directory = paths.prefixes.appendingPathComponent(
            Self.folderName(for: name, id: metadata.id), isDirectory: true)
        try fm.copyItem(at: prefix.directory, to: directory)
        let copy = Prefix(metadata: metadata, directory: directory)
        try save(copy)
        return copy
    }

    /// Deletes the prefix folder for good. Refuses anything outside the Prefixes folder.
    public func delete(_ prefix: Prefix) throws {
        let base = paths.prefixes.standardizedFileURL.path + "/"
        guard prefix.directory.standardizedFileURL.path.hasPrefix(base) else {
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
