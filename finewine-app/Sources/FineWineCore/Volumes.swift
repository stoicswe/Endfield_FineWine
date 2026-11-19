import Foundation

/// A mounted volume (an internal or external drive, a disk image), as far as FineWine cares.
public struct VolumeInfo: Equatable, Sendable {
    /// Where it is mounted: `/` for the startup disk, `/Volumes/<name>` for others.
    public var root: URL
    /// The volume's UUID. It identifies the drive wherever and under whatever name it is
    /// mounted next time; nil for volumes that have none (some network shares).
    public var uuid: String?
    public var name: String
    /// The file system, as `statfs` names it: `apfs`, `hfs`, `exfat`, `msdos`, `ntfs`, `smbfs`, ...
    public var fileSystem: String
    /// The Mac's own disk rather than one plugged in.
    public var isInternal: Bool
    public var isLocal: Bool
    public var availableBytes: Int64?

    public init(root: URL, uuid: String?, name: String, fileSystem: String, isInternal: Bool,
                isLocal: Bool = true, availableBytes: Int64? = nil) {
        self.root = root
        self.uuid = uuid
        self.name = name
        self.fileSystem = fileSystem
        self.isInternal = isInternal
        self.isLocal = isLocal
        self.availableBytes = availableBytes
    }

    /// Why a Wine prefix can't live on this volume, or nil if it can. A prefix needs Unix
    /// symbolic links (its drive letters are links in `dosdevices`) and Unix permissions, which
    /// only the Mac's own file systems have: APFS and Mac OS Extended (HFS+). On exFAT, FAT or
    /// NTFS Wine cannot set a prefix up; a network share is too slow and can vanish mid-game.
    public var prefixProblem: String? {
        guard isLocal else { return tr("location.err_network", name) }
        switch fileSystem.lowercased() {
        case "apfs", "hfs": return nil
        default: return tr("location.err_filesystem", name, Self.fileSystemName(fileSystem))
        }
    }

    /// The name Disk Utility shows for a file system.
    public static func fileSystemName(_ type: String) -> String {
        switch type.lowercased() {
        case "apfs": return "APFS"
        case "hfs": return "Mac OS Extended"
        case "exfat": return "ExFAT"
        case "msdos": return "MS-DOS (FAT)"
        case "ntfs": return "NTFS"
        case "smbfs", "afpfs", "nfs", "webdav": return tr("location.fs_network")
        default: return type
        }
    }
}

/// What FineWine knows about the volumes mounted right now. A protocol so tests can stand in
/// for real drives.
public protocol VolumeProviding: Sendable {
    /// Every mounted volume a user would see in Finder.
    func mounted() -> [VolumeInfo]
    /// The volume a file or folder is on.
    func volume(containing url: URL) -> VolumeInfo?
}

/// The volumes macOS reports.
public struct SystemVolumes: VolumeProviding {
    public init() {}

    static let keys: [URLResourceKey] = [.volumeUUIDStringKey, .volumeLocalizedNameKey, .volumeIsInternalKey,
                                         .volumeIsLocalKey, .volumeAvailableCapacityForImportantUsageKey,
                                         .volumeURLKey]

    public func mounted() -> [VolumeInfo] {
        let urls = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: Self.keys,
                                                         options: [.skipHiddenVolumes]) ?? []
        return urls.compactMap(info(forRoot:))
    }

    public func volume(containing url: URL) -> VolumeInfo? {
        // The folder may not exist yet; ask about the nearest one that does.
        var probe = url.standardizedFileURL
        while !FileManager.default.fileExists(atPath: probe.path), probe.path != "/" {
            probe = probe.deletingLastPathComponent()
        }
        guard let root = (try? probe.resourceValues(forKeys: [.volumeURLKey]))?.volume else { return nil }
        return info(forRoot: root)
    }

    func info(forRoot root: URL) -> VolumeInfo? {
        let values = try? root.resourceValues(forKeys: Set(Self.keys))
        var fs = statfs()
        let type: String = statfs(root.path, &fs) == 0
            ? withUnsafeBytes(of: fs.f_fstypename) { String(cString: $0.bindMemory(to: CChar.self).baseAddress!) }
            : ""
        return VolumeInfo(root: root, uuid: values?.volumeUUIDString,
                          name: values?.volumeLocalizedName ?? root.lastPathComponent,
                          fileSystem: type, isInternal: values?.volumeIsInternal ?? false,
                          isLocal: values?.volumeIsLocal ?? true,
                          availableBytes: values?.volumeAvailableCapacityForImportantUsage)
    }
}
