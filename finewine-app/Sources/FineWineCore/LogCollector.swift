import Foundation

/// Gathers what is useful for looking into a problem with a prefix into one zip file, so that
/// it can be attached to a bug report.
///
/// What goes in:
/// - `summary.txt`: the versions of FineWine, macOS and the runtime, the Mac's model, the
///   prefix's programs, and the list of files that follow.
/// - `prefix-settings.json`: the prefix's `finewine.json`.
/// - `finewine/`: FineWine's logs of the most recent launches (Wine's and the graphics layers'
///   output), and the Steam tool's log for a prefix Steam made.
/// - `programs/`: the logs the Windows programs wrote themselves, found in the prefix's
///   `AppData` folders and beside its programs. A launcher or a game that catches its own
///   crashes writes them here and nothing reaches Wine.
/// - `crash-reports/`: macOS' reports of crashed Wine processes.
///
/// What stays out: anything that is not text (crash dumps hold a program's memory), browser
/// storage of embedded web views (it has sign-in data, in files named `.log`), files older
/// than `maximumAge`, and all but the end of a long file. The user's account name in paths is
/// replaced, since the result is meant for a public page. What a game writes into its own logs
/// (an account id, for one) is not known here and stays; the app says so beside the button.
public struct LogCollector {
    public var paths: FineWinePaths
    /// The user's account name, replaced in `/Users/<name>` and `\users\<name>`.
    public var userName: String
    /// `~/Library/Logs/DiagnosticReports`, or nil to leave crash reports out.
    public var diagnosticReports: URL?
    public var now: Date

    /// How many of FineWine's own launch logs are taken, newest first.
    public var launchLogLimit = 8
    /// How many logs of the programs are taken, newest first.
    public var programLogLimit = 40
    /// How many crash reports are taken, newest first.
    public var crashReportLimit = 10
    /// Files changed longer ago than this are left out (launch logs excepted).
    public var maximumAge: TimeInterval = 14 * 24 * 3600
    /// The most that is kept of one file: its end, and for a launch log also its start.
    public var maximumFileSize = 2 * 1024 * 1024

    public init(paths: FineWinePaths, userName: String = NSUserName(),
                diagnosticReports: URL? = FileManager.default.homeDirectoryForCurrentUser
                    .appendingPathComponent("Library/Logs/DiagnosticReports", isDirectory: true),
                now: Date = Date()) {
        self.paths = paths
        self.userName = userName
        self.diagnosticReports = diagnosticReports
        self.now = now
    }

    /// One file that goes into the collection.
    public struct Item: Equatable {
        public var source: URL
        /// Where it goes inside the collection, e.g. `programs/AppData/Roaming/X/launcher.log`.
        public var path: String
    }

    // MARK: What is collected

    /// Folders whose `.log` files are a browser's storage, not logs.
    static let skippedFolders: Set<String> = [
        "cache", "code cache", "gpucache", "dawncache", "local storage", "session storage",
        "indexeddb", "leveldb", "service worker", "blob_storage", "fedata", "webcache", "cef_cache",
        "shadercache", "crashpad",
    ]
    /// Log files that do not end in `.log`: Unity's older player log.
    static let extraNames: Set<String> = ["output_log.txt", "output_log_prev.txt"]

    static func isLogName(_ name: String) -> Bool {
        let lower = name.lowercased()
        return lower.hasSuffix(".log") || extraNames.contains(lower)
    }

    private func modified(_ url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
    }

    /// FineWine's logs of the prefix's launches, newest first.
    public func launchLogs(for prefix: Prefix) -> [URL] {
        let folder = paths.logs.appendingPathComponent(prefix.directory.lastPathComponent, isDirectory: true)
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        // A log of a few bytes is a tool that ran and said nothing ("Shut down").
        return Array(files.filter { $0.pathExtension == "log" && ((try? $0.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) >= 256 }
            .sorted { modified($0) > modified($1) }
            .prefix(launchLogLimit))
    }

    /// The log files under `root`, no deeper than `depth` folders, that are recent enough.
    private func logFiles(under root: URL, depth: Int) -> [URL] {
        let keys: [URLResourceKey] = [.isRegularFileKey, .isSymbolicLinkKey, .contentModificationDateKey, .fileSizeKey]
        guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys,
                                                          options: [.skipsPackageDescendants]) else { return [] }
        var out: [URL] = []
        for case let url as URL in walker {
            let name = url.lastPathComponent
            let values = try? url.resourceValues(forKeys: Set(keys))
            if values?.isSymbolicLink == true { walker.skipDescendants(); continue }
            if values?.isRegularFile != true {
                if walker.level > depth || Self.skippedFolders.contains(name.lowercased()) || name.lowercased().hasSuffix(".leveldb") {
                    walker.skipDescendants()
                }
                continue
            }
            guard Self.isLogName(name), (values?.fileSize ?? 0) > 0,
                  name.range(of: #"^\d{6}\.log$"#, options: .regularExpression) == nil,   // a database's journal
                  let date = values?.contentModificationDate, now.timeIntervalSince(date) <= maximumAge else { continue }
            out.append(url)
        }
        return out
    }

    /// The logs the prefix's programs wrote: in the `AppData` folders of its users, and in the
    /// folders of the programs FineWine knows. Newest first.
    public func programLogs(for prefix: Prefix) -> [Item] {
        let fm = FileManager.default
        var found: [URL: String] = [:]
        let users = prefix.driveC.appendingPathComponent("users", isDirectory: true)
        for user in (try? fm.contentsOfDirectory(at: users, includingPropertiesForKeys: nil)) ?? [] {
            let appData = user.appendingPathComponent("AppData", isDirectory: true)
            for file in logFiles(under: appData, depth: 8) {
                found[file] = "AppData/" + Self.relativePath(of: file, under: appData)
            }
        }
        var folders = Set<URL>()
        for program in prefix.metadata.programs {
            guard let exe = WindowsPath.macURL(for: program.windowsPath, inPrefix: prefix.directory) else { continue }
            folders.insert(exe.deletingLastPathComponent().standardizedFileURL)
        }
        for folder in folders {
            for file in logFiles(under: folder, depth: 4) where found[file] == nil {
                found[file] = folder.lastPathComponent + "/" + Self.relativePath(of: file, under: folder)
            }
        }
        return found.sorted { modified($0.key) > modified($1.key) }
            .prefix(programLogLimit)
            .map { Item(source: $0.key, path: "programs/" + $0.value) }
    }

    /// macOS' reports of crashed Wine processes, newest first.
    public func crashReports() -> [URL] {
        guard let diagnosticReports else { return [] }
        let files = (try? FileManager.default.contentsOfDirectory(at: diagnosticReports, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        return Array(files.filter { file in
            let name = file.lastPathComponent.lowercased()
            return (name.hasPrefix("wine") || name.hasPrefix("finewine")) && ["ips", "crash"].contains(file.pathExtension)
                && now.timeIntervalSince(modified(file)) <= maximumAge
        }
        .sorted { modified($0) > modified($1) }
        .prefix(crashReportLimit))
    }

    /// Every file that goes into the collection for `prefix`, apart from the two written here.
    public func items(for prefix: Prefix) -> [Item] {
        var out = launchLogs(for: prefix).map { Item(source: $0, path: "finewine/" + $0.lastPathComponent) }
        if prefix.metadata.steamAppID != nil {
            let steam = paths.logs.appendingPathComponent("steam-tool.log")
            if FileManager.default.fileExists(atPath: steam.path) { out.append(Item(source: steam, path: "finewine/steam-tool.log")) }
        }
        out += programLogs(for: prefix)
        out += crashReports().map { Item(source: $0, path: "crash-reports/" + $0.lastPathComponent) }
        return out
    }

    static func relativePath(of file: URL, under root: URL) -> String {
        let base = root.standardizedFileURL.path, full = file.standardizedFileURL.path
        guard full.hasPrefix(base + "/") else { return file.lastPathComponent }
        return String(full.dropFirst(base.count + 1))
    }

    // MARK: Text

    /// The account name taken out of home folder paths, Mac and Windows.
    public func redacted(_ text: String) -> String {
        guard !userName.isEmpty else { return text }
        // "users", either slash (doubled in JSON), the name, and then nothing a longer name has
        let pattern = #"(?i)([/\\]users[/\\]{1,2})"# + NSRegularExpression.escapedPattern(for: userName) + #"(?![A-Za-z0-9_.-])"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        return regex.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: "$1USER")
    }

    /// The text of a log, cut to `maximumFileSize` and with the account name replaced, or nil
    /// for a file that is not text. `keepStart` keeps the beginning as well as the end, for
    /// logs whose first lines say what was started.
    public func text(of url: URL, keepStart: Bool = false) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        try? handle.seek(toOffset: 0)
        var data: Data
        var note = ""
        if size > UInt64(maximumFileSize) {
            let head = keepStart ? maximumFileSize / 8 : 0
            let start = (try? handle.read(upToCount: head)) ?? Data()
            let tail = maximumFileSize - head
            try? handle.seek(toOffset: size - UInt64(tail))
            let end = (try? handle.readToEnd()) ?? Data()
            note = "\n[FineWine: \(size - UInt64(maximumFileSize)) bytes left out here; the file is \(size) bytes]\n"
            if head == 0 {
                data = end
                return decode(data).map { note + redacted($0) }
            }
            guard let first = decode(start), let last = decode(end) else { return nil }
            return redacted(first) + note + redacted(last)
        }
        data = (try? handle.readToEnd()) ?? Data()
        return decode(data).map(redacted)
    }

    /// UTF-8 (lossy), or UTF-16 with a byte order mark; nil for binary data.
    private func decode(_ data: Data) -> String? {
        if data.starts(with: [0xFF, 0xFE]) || data.starts(with: [0xFE, 0xFF]) {
            return String(data: data, encoding: .utf16)
        }
        if data.prefix(4096).contains(0) { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    // MARK: Writing

    static func sysctlString(_ name: String) -> String {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return "?" }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return "?" }
        return String(cString: buffer)
    }

    func summary(for prefix: Prefix, runtime: WineRuntime?, appVersion: String, files: [(String, Int)]) -> String {
        let stamp = ISO8601DateFormatter().string(from: now)
        var lines = [
            "FineWine log collection, \(stamp)",
            "",
            "FineWine:  \(appVersion)",
            "macOS:     \(ProcessInfo.processInfo.operatingSystemVersionString)",
            "Mac:       \(Self.sysctlString("hw.model")), \(Self.sysctlString("machdep.cpu.brand_string")), "
                + "\(ProcessInfo.processInfo.physicalMemory / (1024 * 1024 * 1024)) GB",
        ]
        if let runtime {
            lines.append("Runtime:   \(runtime.name) \(runtime.manifest.version) (\(runtime.id)), Wine \(runtime.manifest.wineVersion)")
        } else {
            lines.append("Runtime:   none found (\(prefix.metadata.runtimeID ?? "not set"))")
        }
        lines += ["Prefix:    \(prefix.name) (\(prefix.directory.lastPathComponent))",
                  "Graphics:  \(prefix.metadata.settings.graphicsBackend.rawValue)"
                    + (prefix.metadata.settings.legacyDirect3DOnVulkan ? ", Direct3D 9 on Vulkan" : ""),
                  "", "Programs:"]
        lines += prefix.metadata.programs.map { "  \($0.name): \($0.windowsPath)" + ($0.arguments.isEmpty ? "" : " " + $0.arguments.joined(separator: " ")) }
        if prefix.metadata.programs.isEmpty { lines.append("  none") }
        lines += ["", "Files:"]
        lines += files.map { "  \($0.0) (\($0.1) bytes)" }
        if files.isEmpty { lines.append("  none: no logs were found for this prefix") }
        return redacted(lines.joined(separator: "\n")) + "\n"
    }

    /// Writes the collection for `prefix` as a folder at `folder` (which must not exist).
    /// Returns the paths written, relative to the folder.
    @discardableResult
    public func write(for prefix: Prefix, runtime: WineRuntime?, appVersion: String, to folder: URL) throws -> [String] {
        let fm = FileManager.default
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        var written: [(String, Int)] = []
        var taken = Set<String>()
        for item in items(for: prefix) {
            guard let text = text(of: item.source, keepStart: item.path.hasPrefix("finewine/")),
                  taken.insert(item.path.lowercased()).inserted else { continue }
            let target = folder.appendingPathComponent(item.path)
            try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = Data(text.utf8)
            try data.write(to: target)
            written.append((item.path, data.count))
        }
        let settings = prefix.directory.appendingPathComponent(PrefixStore.metadataName)
        if let text = text(of: settings) {
            try Data(text.utf8).write(to: folder.appendingPathComponent("prefix-settings.json"))
        }
        try Data(summary(for: prefix, runtime: runtime, appVersion: appVersion, files: written).utf8)
            .write(to: folder.appendingPathComponent("summary.txt"))
        return ["summary.txt", "prefix-settings.json"] + written.map(\.0)
    }

    /// The name a collection's zip file gets: `FineWine logs <prefix> <date>.zip`.
    public func suggestedFileName(for prefix: Prefix) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH.mm"
        return "FineWine logs \(ShortcutAppBuilder.sanitizedName(prefix.name)) \(formatter.string(from: now)).zip"
    }

    /// Collects for `prefix` and writes the zip file at `zip`, replacing a file that is there.
    /// Returns the paths inside it.
    @discardableResult
    public func collect(for prefix: Prefix, runtime: WineRuntime?, appVersion: String, into zip: URL) throws -> [String] {
        let fm = FileManager.default
        let stage = fm.temporaryDirectory.appendingPathComponent("finewine-logs-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: stage) }
        let folder = stage.appendingPathComponent(zip.deletingPathExtension().lastPathComponent, isDirectory: true)
        let written = try write(for: prefix, runtime: runtime, appVersion: appVersion, to: folder)

        let packed = stage.appendingPathComponent("logs.zip")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-c", "-k", "--keepParent", folder.path, packed.path]
        process.standardOutput = FileHandle.nullDevice
        let errors = Pipe()
        process.standardError = errors
        try process.run()
        let message = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw FineWineError(message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "ditto failed" : message)
        }
        if fm.fileExists(atPath: zip.path) { try fm.removeItem(at: zip) }
        try fm.moveItem(at: packed, to: zip)
        return written
    }
}
