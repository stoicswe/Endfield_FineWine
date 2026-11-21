import Foundation

/// A saved copy of a prefix as it was at one moment, Windows files and FineWine's settings for
/// it included, which the prefix can be put back to.
///
/// A snapshot is an ordinary folder, so it can be found in Finder and copied anywhere:
/// `<FineWine>/Snapshots/<prefix folder>/<date and time>/`, holding `snapshot.json` (this) and
/// `Prefix/` (the copy). `<FineWine>` is FineWine's folder on this Mac, or `FineWine` at the top
/// of a drive. Snapshots stay when their prefix is deleted.
public struct PrefixSnapshot: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var prefixID: UUID
    /// The prefix's name when the snapshot was taken.
    public var prefixName: String
    /// What the user wrote about it; may be empty.
    public var note: String
    public var createdAt: Date
    /// The size of the prefix's files when it was taken.
    public var bytes: Int64

    /// Where it is, filled in when it is read.
    public var directory = URL(fileURLWithPath: "/")
    public var place: PrefixPlace = .thisMac

    enum CodingKeys: String, CodingKey { case id, prefixID, prefixName, note, createdAt, bytes }

    public init(id: UUID = UUID(), prefixID: UUID, prefixName: String, note: String, createdAt: Date, bytes: Int64) {
        self.id = id
        self.prefixID = prefixID
        self.prefixName = prefixName
        self.note = note
        self.createdAt = createdAt
        self.bytes = bytes
    }

    /// The copy of the prefix folder.
    public var contents: URL { directory.appendingPathComponent(PrefixStore.snapshotContentsName, isDirectory: true) }
}

extension PrefixStore {
    public static let snapshotsName = "Snapshots"
    static let snapshotInfoName = "snapshot.json"
    static let snapshotContentsName = "Prefix"
    /// Room kept free beyond the copy itself, so a move or snapshot never fills a drive.
    static let copyMargin: Int64 = 200_000_000

    private static var snapshotEncoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    private static var snapshotDecoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    // MARK: Long operations

    /// Moves, snapshots and restores under way in this app. While one is, the clean-up of
    /// interrupted work leaves the hidden folders alone (one of them is being written).
    private static let activity = ActivityCount()

    final class ActivityCount: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        func begin() { lock.withLock { count += 1 } }
        func end() { lock.withLock { count -= 1 } }
        var isIdle: Bool { lock.withLock { count == 0 } }
    }

    private func longOperation<T>(_ body: () throws -> T) rethrows -> T {
        Self.activity.begin()
        defer { Self.activity.end() }
        return try body()
    }

    /// The name of a place for messages: "This Mac" or the drive's name.
    func placeName(_ place: PrefixPlace) -> String {
        switch place {
        case .thisMac: return tr("drive.this_mac")
        case .drive(let uuid): return drives.drive(uuid)?.name ?? tr("drive.unknown")
        case .customFolder(let url): return url.lastPathComponent
        }
    }

    /// Whether two folders are on the same volume, so that a copy between them is a clone and
    /// a move is a rename.
    func sameVolume(_ a: URL, _ b: URL) -> Bool {
        guard let first = drives.volumes.volume(containing: a), let second = drives.volumes.volume(containing: b) else {
            return false
        }
        if let one = first.uuid, let other = second.uuid { return one == other }
        return first.root.standardizedFileURL == second.root.standardizedFileURL
    }

    /// Refuses a copy that wouldn't fit, with room to spare.
    func checkSpace(for allocated: Int64, in folder: URL, place: PrefixPlace) throws {
        guard let volume = drives.volumes.volume(containing: folder), let free = volume.availableBytes else { return }
        let needed = allocated + Self.copyMargin
        guard free < needed else { return }
        let format = { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) }
        throw FineWineError(tr("move.err_low_space", placeName(place), format(free), format(needed)))
    }

    /// Copies a folder next to where it has to end up, then swaps it in, so a failure or a
    /// cancel at any point leaves the original as it was. `replacing` is put aside while the
    /// swap is made and deleted afterwards.
    private func copyIn(_ source: URL, to final: URL, replacing old: URL?, place: PrefixPlace,
                        progress: CopyProgress) throws {
        let fm = FileManager.default
        let folder = final.deletingLastPathComponent()
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let size = FolderCopy.measure(source)
        progress.setTotal(size.bytes)
        if !sameVolume(source, folder) { try checkSpace(for: size.allocated, in: folder, place: place) }
        let staging = folder.appendingPathComponent(".copying-" + final.lastPathComponent, isDirectory: true)
        try? fm.removeItem(at: staging)
        try FolderCopy.copy(source, to: staging, progress: progress)
        guard let old else {
            do { try fm.moveItem(at: staging, to: final) } catch { try? fm.removeItem(at: staging); throw error }
            return
        }
        let aside = old.deletingLastPathComponent().appendingPathComponent(".leaving-" + old.lastPathComponent,
                                                                            isDirectory: true)
        try? fm.removeItem(at: aside)
        do { try fm.moveItem(at: old, to: aside) } catch { try? fm.removeItem(at: staging); throw error }
        do {
            try fm.moveItem(at: staging, to: final)
        } catch {
            try? fm.moveItem(at: aside, to: old)
            try? fm.removeItem(at: staging)
            throw error
        }
        try? fm.removeItem(at: aside)
    }

    /// Puts right what an interrupted move, snapshot or restore left (FineWine quit, the Mac
    /// lost power, a drive was pulled): a half-made copy is deleted, and a prefix that was put
    /// aside is put back unless its copy made it. Nothing is done while such work is running.
    func recoverInterruptedWork() {
        guard Self.activity.isIdle else { return }
        let fm = FileManager.default
        var folders = availableFolders().map(\.folder)
        for place in [PrefixPlace.thisMac] + drives.drives.map({ PrefixPlace.drive($0.uuid) }) + drives.customFolders.map({ PrefixPlace.customFolder($0) }) {
            guard let snapshots = snapshotsFolder(for: place) else { continue }
            folders.append(snapshots)
            folders += ((try? fm.contentsOfDirectory(at: snapshots, includingPropertiesForKeys: nil)) ?? [])
        }
        let present = Set(list().map(\.id))
        for folder in folders {
            for item in (try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [] {
                let name = item.lastPathComponent
                if name.hasPrefix(".copying-") {
                    try? fm.removeItem(at: item)
                } else if name.hasPrefix(".leaving-") {
                    let original = folder.appendingPathComponent(String(name.dropFirst(".leaving-".count)), isDirectory: true)
                    if let prefix = load(directory: item), !present.contains(prefix.id),
                       !fm.fileExists(atPath: original.path) {
                        try? fm.moveItem(at: item, to: original)
                    } else {
                        try? fm.removeItem(at: item)
                    }
                }
            }
        }
    }

    // MARK: Moving

    /// Moves a prefix to this Mac or to a drive FineWine knows, which must be plugged in. The
    /// prefix keeps its folder name and id, so shortcuts and logs still find it. Between two
    /// volumes the prefix is copied and the original deleted only once the copy is complete.
    public func move(_ prefix: Prefix, to place: PrefixPlace, progress: CopyProgress = CopyProgress()) throws -> Prefix {
        try longOperation {
            guard place != prefix.place else { throw FineWineError(tr("move.err_already_there", prefix.name, placeName(place))) }
            guard let folder = drives.prefixesFolder(for: place) else {
                throw FineWineError(tr("location.err_not_connected", placeName(place)))
            }
            let fm = FileManager.default
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
            let final = folder.appendingPathComponent(prefix.directory.lastPathComponent, isDirectory: true)
            guard !fm.fileExists(atPath: final.path) else {
                throw FineWineError(tr("move.err_exists", placeName(place), final.lastPathComponent))
            }
            if sameVolume(prefix.directory, folder) {
                try fm.moveItem(at: prefix.directory, to: final)
            } else {
                try copyIn(prefix.directory, to: final, replacing: nil, place: place, progress: progress)
                do {
                    try fm.removeItem(at: prefix.directory)
                } catch {
                    // The copy is complete, and two prefixes with one id would confuse
                    // everything; keep the original and drop the copy.
                    try? fm.removeItem(at: final)
                    throw error
                }
            }
            var moved = prefix
            moved.directory = final
            moved.place = place
            return moved
        }
    }

    // MARK: Snapshots

    /// The snapshots folder of a place, if that place is there right now.
    public func snapshotsFolder(for place: PrefixPlace) -> URL? {
        switch place {
        case .thisMac: return paths.root.appendingPathComponent(Self.snapshotsName, isDirectory: true)
        case .drive(let uuid):
            return drives.mountedVolume(uuid).map {
                $0.root.appendingPathComponent(PrefixDriveStore.folderName, isDirectory: true)
                    .appendingPathComponent(Self.snapshotsName, isDirectory: true)
            }
        case .customFolder(let url):
            if let volume = drives.volumes.volume(containing: url) {
                return volume.root.appendingPathComponent(PrefixDriveStore.folderName, isDirectory: true)
                    .appendingPathComponent(Self.snapshotsName, isDirectory: true)
            }
            return paths.root.appendingPathComponent(Self.snapshotsName, isDirectory: true)
        }
    }

    /// Every snapshot on this Mac and on the drives plugged in, newest first.
    public func snapshots() -> [PrefixSnapshot] {
        let fm = FileManager.default
        var out: [PrefixSnapshot] = []
        for place in [PrefixPlace.thisMac] + drives.drives.map({ PrefixPlace.drive($0.uuid) }) + drives.customFolders.map({ PrefixPlace.customFolder($0) }) {
            guard let root = snapshotsFolder(for: place) else { continue }
            for group in (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
            where !group.lastPathComponent.hasPrefix(".") {
                for folder in (try? fm.contentsOfDirectory(at: group, includingPropertiesForKeys: nil)) ?? []
                where !folder.lastPathComponent.hasPrefix(".") {
                    guard let data = try? Data(contentsOf: folder.appendingPathComponent(Self.snapshotInfoName)),
                          var snapshot = try? Self.snapshotDecoder.decode(PrefixSnapshot.self, from: data) else { continue }
                    snapshot.directory = folder
                    snapshot.place = place
                    out.append(snapshot)
                }
            }
        }
        return out.sorted { $0.createdAt > $1.createdAt }
    }

    public func snapshots(of prefixID: UUID) -> [PrefixSnapshot] { snapshots().filter { $0.prefixID == prefixID } }

    /// Saves a copy of the prefix as it is now, on this Mac or a drive that is plugged in. On
    /// the prefix's own APFS volume the copy is a clone: made at once, and taking space only
    /// as the prefix changes afterwards. Elsewhere it is a full copy, which also keeps the
    /// prefix safe if its own drive fails.
    public func takeSnapshot(of prefix: Prefix, note: String = "", on place: PrefixPlace? = nil,
                             progress: CopyProgress = CopyProgress()) throws -> PrefixSnapshot {
        try longOperation {
            let place = place ?? prefix.place
            guard let root = snapshotsFolder(for: place) else {
                throw FineWineError(tr("location.err_not_connected", placeName(place)))
            }
            let fm = FileManager.default
            let group = root.appendingPathComponent(prefix.directory.lastPathComponent, isDirectory: true)
            try fm.createDirectory(at: group, withIntermediateDirectories: true)
            let created = Self.now()
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
            var folderName = formatter.string(from: created)
            var counter = 2
            while fm.fileExists(atPath: group.appendingPathComponent(folderName).path) {
                folderName = formatter.string(from: created) + " \(counter)"
                counter += 1
            }
            let folder = group.appendingPathComponent(folderName, isDirectory: true)
            let staging = group.appendingPathComponent(".copying-" + folderName, isDirectory: true)
            try? fm.removeItem(at: staging)
            try fm.createDirectory(at: staging, withIntermediateDirectories: false)
            let size = FolderCopy.measure(prefix.directory)
            progress.setTotal(size.bytes)
            do {
                if !sameVolume(prefix.directory, group) { try checkSpace(for: size.allocated, in: group, place: place) }
                try FolderCopy.copy(prefix.directory, to: staging.appendingPathComponent(Self.snapshotContentsName),
                                    progress: progress)
                var snapshot = PrefixSnapshot(prefixID: prefix.id, prefixName: prefix.name,
                                              note: note.trimmingCharacters(in: .whitespacesAndNewlines),
                                              createdAt: created, bytes: size.bytes)
                try Self.snapshotEncoder.encode(snapshot).write(to: staging.appendingPathComponent(Self.snapshotInfoName),
                                                                options: .atomic)
                try fm.moveItem(at: staging, to: folder)
                snapshot.directory = folder
                snapshot.place = place
                return snapshot
            } catch {
                try? fm.removeItem(at: staging)
                throw error
            }
        }
    }

    /// Puts a prefix back the way it was in a snapshot: its files, its settings and its
    /// programs. It keeps its current name, id and place. The prefix's current state is
    /// replaced; take a snapshot of it first to keep it.
    public func restore(_ snapshot: PrefixSnapshot, over prefix: Prefix,
                        progress: CopyProgress = CopyProgress()) throws -> Prefix {
        try longOperation {
            guard snapshot.prefixID == prefix.id else { throw FineWineError(tr("snapshot.err_other_prefix")) }
            guard var restored = load(directory: snapshot.contents) else { throw FineWineError(tr("snapshot.err_damaged")) }
            try copyIn(snapshot.contents, to: prefix.directory, replacing: prefix.directory, place: prefix.place,
                       progress: progress)
            restored.directory = prefix.directory
            restored.place = prefix.place
            restored.metadata.name = prefix.name
            try save(restored)
            return restored
        }
    }

    /// Makes a new prefix from a snapshot, next to the snapshot (on its drive, or this Mac),
    /// with its own id. The snapshot's prefix may be gone, or still there unchanged.
    public func restoreAsNew(_ snapshot: PrefixSnapshot, name rawName: String,
                             progress: CopyProgress = CopyProgress()) throws -> Prefix {
        try longOperation {
            let name = try Self.validatedName(rawName)
            guard !takenNames().contains(where: { $0.caseInsensitiveCompare(name) == .orderedSame }) else {
                throw FineWineError("A prefix named “\(name)” already exists.")
            }
            guard var made = load(directory: snapshot.contents) else { throw FineWineError(tr("snapshot.err_damaged")) }
            let place = drives.prefixesFolder(for: snapshot.place) == nil ? PrefixPlace.thisMac : snapshot.place
            guard let folder = drives.prefixesFolder(for: place) else {
                throw FineWineError(tr("location.err_not_connected", placeName(place)))
            }
            made.metadata.id = UUID()
            made.metadata.name = name
            made.metadata.createdAt = Self.now()
            made.metadata.programs = made.metadata.programs.map {
                var program = $0
                program.id = UUID()
                program.shortcutPath = nil
                return program
            }
            let final = folder.appendingPathComponent(Self.folderName(for: name, id: made.id), isDirectory: true)
            try copyIn(snapshot.contents, to: final, replacing: nil, place: place, progress: progress)
            made.directory = final
            made.place = place
            do { try save(made) } catch { try? FileManager.default.removeItem(at: final); throw error }
            return made
        }
    }

    /// Deletes a snapshot for good. Refuses anything outside a Snapshots folder of FineWine's.
    public func deleteSnapshot(_ snapshot: PrefixSnapshot) throws {
        let path = snapshot.directory.standardizedFileURL.path
        let roots = ([PrefixPlace.thisMac] + drives.drives.map { PrefixPlace.drive($0.uuid) } + drives.customFolders.map { PrefixPlace.customFolder($0) }).compactMap(snapshotsFolder(for:))
        guard roots.contains(where: { path.hasPrefix($0.standardizedFileURL.path + "/") }),
              FileManager.default.fileExists(atPath: snapshot.directory.appendingPathComponent(Self.snapshotInfoName).path) else {
            throw FineWineError(tr("snapshot.err_outside"))
        }
        let fm = FileManager.default
        try fm.removeItem(at: snapshot.directory)
        // The prefix's folder in Snapshots goes too once it is empty.
        let group = snapshot.directory.deletingLastPathComponent()
        if ((try? fm.contentsOfDirectory(atPath: group.path)) ?? ["x"]).filter({ $0 != ".DS_Store" }).isEmpty {
            try? fm.removeItem(at: group)
        }
    }
}
