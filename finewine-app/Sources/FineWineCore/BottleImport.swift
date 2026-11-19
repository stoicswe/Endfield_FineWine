import Foundation

/// A CrossOver bottle (or any other Wine prefix) on disk, as something a FineWine prefix can
/// be made from. It is only ever read.
public struct CrossOverBottle: Identifiable, Equatable, Sendable {
    public var directory: URL
    public var name: String
    /// False for a 32-bit bottle, which no 64-bit Wine can open.
    public var is64Bit: Bool
    /// Whether it has CrossOver's own files; a plain Wine prefix has not.
    public var isCrossOver: Bool

    public var id: String { directory.path }
    public var driveC: URL { directory.appendingPathComponent("drive_c", isDirectory: true) }

    /// The registry files a prefix keeps at its top.
    public static let registryFiles = ["system.reg", "user.reg", "userdef.reg"]

    /// The bottle in a folder, or nil when the folder is not a Wine prefix.
    public static func read(_ directory: URL) -> CrossOverBottle? {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        let directory = directory.standardizedFileURL
        guard fm.fileExists(atPath: directory.appendingPathComponent("drive_c").path, isDirectory: &isDir), isDir.boolValue,
              let handle = try? FileHandle(forReadingFrom: directory.appendingPathComponent("system.reg")) else { return nil }
        defer { try? handle.close() }
        // "#arch=win32" or "#arch=win64" is in the first lines of system.reg.
        let head = String(decoding: (try? handle.read(upToCount: 1024)) ?? Data(), as: UTF8.self)
        return CrossOverBottle(directory: directory, name: directory.lastPathComponent,
                               is64Bit: !head.contains("#arch=win32"),
                               isCrossOver: fm.fileExists(atPath: directory.appendingPathComponent("cxbottle.conf").path))
    }

    /// Where CrossOver keeps bottles: its usual folder, and the one set in its preferences.
    public static func defaultFolders(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> [URL] {
        var folders = [home.appendingPathComponent("Library/Application Support/CrossOver/Bottles", isDirectory: true)]
        if let custom = UserDefaults(suiteName: "com.codeweavers.CrossOver")?.string(forKey: "BottleDir"), !custom.isEmpty {
            let url = URL(fileURLWithPath: (custom as NSString).expandingTildeInPath, isDirectory: true).standardizedFileURL
            if !folders.contains(where: { $0.standardizedFileURL.path == url.path }) { folders.append(url) }
        }
        return folders
    }

    /// The bottles in those folders, by name.
    public static func list(in folders: [URL] = defaultFolders()) -> [CrossOverBottle] {
        folders.flatMap { folder in
            ((try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [])
                .compactMap(read)
        }
        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// The Windows user the bottle's files belong to: CrossOver always calls it "crossover",
    /// another Wine uses the Mac user's name.
    public var windowsUser: String? {
        let users = driveC.appendingPathComponent("users")
        let names = ((try? FileManager.default.contentsOfDirectory(at: users, includingPropertiesForKeys: [.isSymbolicLinkKey])) ?? [])
            .filter { (try? $0.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true && $0.hasDirectoryPath }
            .map(\.lastPathComponent)
            .filter { $0.caseInsensitiveCompare("Public") != .orderedSame && !$0.hasPrefix(".") }
            .sorted()
        return names.first { $0 == "crossover" } ?? names.first
    }
}

extension PrefixService {
    /// Makes a FineWine prefix out of a CrossOver bottle. The bottle is copied (on the same
    /// APFS volume as a clone, which takes no time or space) and never changed.
    ///
    /// What comes over: the whole C: drive, with the installed programs and their data, and
    /// the registry. What changes in the copy:
    /// - the Windows user folder gets the name this Wine uses (the Mac user's; CrossOver's is
    ///   "crossover"), in the files and in the registry, with a link under the old name for
    ///   programs that wrote the old path into their own files;
    /// - the runtime then brings the prefix up to date, as Wine does for a prefix made by an
    ///   older version: its own system files replace CrossOver's;
    /// - the prefix's settings are FineWine's defaults, except the Windows version, which is
    ///   the bottle's;
    /// - only C: and Z: are set up: other drive letters of the bottle are not carried over.
    public func importBottle(_ bottle: CrossOverBottle, name: String, runtime: WineRuntime,
                             place: PrefixPlace = .thisMac, appearance: MacAppearance? = nil,
                             userName: String = NSUserName(), progress: CopyProgress = CopyProgress(),
                             stage: (@Sendable (String) -> Void)? = nil) throws -> Prefix {
        let fm = FileManager.default
        let problems = runtime.problems()
        guard problems.isEmpty else {
            throw FineWineError("The runtime “\(runtime.name)” can't be used: " + problems.joined(separator: " "))
        }
        guard bottle.is64Bit else { throw FineWineError(tr("bottle.err_32bit", bottle.name)) }
        // The registry files of a bottle in use are behind what its programs have changed.
        guard findProcesses(bottle.directory).isEmpty else { throw FineWineError(tr("bottle.err_running", bottle.name)) }

        stage?(tr("bottle.stage_measuring"))
        let size = FolderCopy.measure(bottle.driveC)
        progress.setTotal(size.bytes)

        let prefix = try prefixes.create(name: name, runtimeID: runtime.id, profile: nil, place: place)
        do {
            // A clone needs no room; a copy to another volume needs all of it.
            let volumes = prefixes.drives.volumes
            if let target = volumes.volume(containing: prefix.directory),
               target.root.standardizedFileURL != volumes.volume(containing: bottle.directory)?.root.standardizedFileURL,
               let free = target.availableBytes, free < size.allocated + PrefixStore.minimumFreeBytes {
                let format = { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) }
                throw FineWineError(tr("bottle.err_space", bottle.name, format(size.allocated), format(free)))
            }

            stage?(tr("bottle.stage_copying"))
            try FolderCopy.copy(bottle.driveC, to: prefix.directory.appendingPathComponent("drive_c"), progress: progress)
            for file in CrossOverBottle.registryFiles {
                let source = bottle.directory.appendingPathComponent(file)
                guard fm.fileExists(atPath: source.path) else { continue }
                try fm.copyItem(at: source, to: prefix.directory.appendingPathComponent(file))
            }
            let devices = prefix.directory.appendingPathComponent("dosdevices", isDirectory: true)
            try fm.createDirectory(at: devices, withIntermediateDirectories: true)
            try fm.createSymbolicLink(atPath: devices.appendingPathComponent("c:").path, withDestinationPath: "../drive_c")
            try fm.createSymbolicLink(atPath: devices.appendingPathComponent("z:").path, withDestinationPath: "/")

            if let old = bottle.windowsUser { try Self.renameWindowsUser(old, to: userName, in: prefix.directory) }

            var imported = prefix
            if let version = PrefixRegistrySnapshot.read(prefix: prefix.directory).windowsVersion
                .flatMap(WindowsVersion.init(rawValue:)) {
                imported.metadata.settings.windowsVersion = version
                try prefixes.save(imported)
            }

            stage?(tr("bottle.stage_updating"))
            try runChecked(try planner(for: imported).plan(for: .update), what: "Updating the imported bottle")
            installEmulatorIfMissing(in: imported, from: runtime)
            keepDesktopInPrefix(imported)
            stage?(tr("setup.applying_settings"))
            imported = try applySettings(to: imported, appearance: appearance)
            // The programs the bottle's installers left shortcuts for.
            return (try? importDiscoveredPrograms(into: imported).prefix) ?? imported
        } catch {
            try? prefixes.delete(prefix)
            throw error
        }
    }

    /// Gives the Windows user folder another name: the folder, a link under the old name, and
    /// the paths in the registry files. Nothing happens when the names are the same or a
    /// folder with the new name is there already.
    static func renameWindowsUser(_ old: String, to new: String, in prefix: URL) throws {
        let fm = FileManager.default
        let users = prefix.appendingPathComponent("drive_c/users")
        let from = users.appendingPathComponent(old), to = users.appendingPathComponent(new)
        guard old.caseInsensitiveCompare(new) != .orderedSame, !new.isEmpty, !new.contains("/"),
              fm.fileExists(atPath: from.path), !fm.fileExists(atPath: to.path) else { return }
        try fm.moveItem(at: from, to: to)
        try fm.createSymbolicLink(atPath: from.path, withDestinationPath: new)

        // Wine's registry files hold other characters as escapes, so a name that needs none
        // can be put in as it is; any other name is left to the link.
        let plain = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._- ")
        guard new.unicodeScalars.allSatisfy(plain.contains), old.unicodeScalars.allSatisfy(plain.contains) else { return }
        for file in CrossOverBottle.registryFiles {
            let url = prefix.appendingPathComponent(file)
            guard let data = try? Data(contentsOf: url) else { continue }
            let text = String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
            // In the file a backslash is written twice: C:\\users\\crossover
            let changed = text.replacingOccurrences(of: "\\\\users\\\\\(old)", with: "\\\\users\\\\\(new)",
                                                    options: .caseInsensitive)
            if changed != text { try Data(changed.utf8).write(to: url, options: .atomic) }
        }
    }

    /// The x64 emulator goes into a prefix when Wine sets it up; a prefix that came from
    /// elsewhere and still lacks it after the update gets the runtime's.
    func installEmulatorIfMissing(in prefix: Prefix, from runtime: WineRuntime) {
        let fm = FileManager.default
        let source = runtime.root.appendingPathComponent("lib/wine/aarch64-windows/xtajit64.dll")
        let target = prefix.directory.appendingPathComponent("drive_c/windows/system32/xtajit64.dll")
        guard fm.fileExists(atPath: source.path), !fm.fileExists(atPath: target.path),
              fm.fileExists(atPath: target.deletingLastPathComponent().path) else { return }
        try? fm.copyItem(at: source, to: target)
    }
}
