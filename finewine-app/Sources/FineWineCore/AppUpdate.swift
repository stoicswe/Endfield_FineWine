import Foundation
import CryptoKit

/// Which builds of FineWine a user wants to be offered.
///
/// The project publishes three kinds of release on GitHub: releases, betas (tags that start
/// with `beta_`) and nightly snapshots (`nightly_`). A channel takes its own kind and every
/// steadier one, so someone on betas is also offered a release that comes out after their
/// beta, and someone on nightlies is offered whatever is newest.
public enum UpdateChannel: String, CaseIterable, Identifiable, Sendable {
    case release, beta, nightly

    public var id: String { rawValue }

    public func includes(_ kind: ReleaseKind) -> Bool {
        switch self {
        case .release: return kind == .release
        case .beta: return kind == .release || kind == .beta
        case .nightly: return true
        }
    }

    /// The channel a build belongs on when the user has not chosen one: the kind of build it is.
    public static func natural(for buildChannel: String) -> UpdateChannel {
        UpdateChannel(rawValue: buildChannel.lowercased()) ?? .beta
    }
}

public enum ReleaseKind: String, Sendable {
    case release, beta, nightly
}

/// One release as GitHub's API describes it; only what the updater uses.
public struct ReleaseInfo: Decodable, Equatable, Sendable {
    public struct Asset: Decodable, Equatable, Sendable {
        public var name: String
        public var size: Int64
        public var downloadURL: URL

        enum CodingKeys: String, CodingKey {
            case name, size
            case downloadURL = "browser_download_url"
        }

        public init(name: String, size: Int64, downloadURL: URL) {
            self.name = name
            self.size = size
            self.downloadURL = downloadURL
        }
    }

    public var tag: String
    public var name: String
    public var notes: String
    public var isPrerelease: Bool
    public var isDraft: Bool
    public var publishedAt: Date?
    public var pageURL: URL?
    public var assets: [Asset]

    enum CodingKeys: String, CodingKey {
        case tag = "tag_name", name, notes = "body", isPrerelease = "prerelease", isDraft = "draft"
        case publishedAt = "published_at", pageURL = "html_url", assets
    }

    public init(tag: String, name: String, notes: String = "", isPrerelease: Bool = false, isDraft: Bool = false,
                publishedAt: Date? = nil, pageURL: URL? = nil, assets: [Asset] = []) {
        self.tag = tag
        self.name = name
        self.notes = notes
        self.isPrerelease = isPrerelease
        self.isDraft = isDraft
        self.publishedAt = publishedAt
        self.pageURL = pageURL
        self.assets = assets
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        tag = try c.decode(String.self, forKey: .tag)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? tag
        notes = try c.decodeIfPresent(String.self, forKey: .notes) ?? ""
        isPrerelease = try c.decodeIfPresent(Bool.self, forKey: .isPrerelease) ?? false
        isDraft = try c.decodeIfPresent(Bool.self, forKey: .isDraft) ?? false
        publishedAt = try c.decodeIfPresent(Date.self, forKey: .publishedAt)
        pageURL = try c.decodeIfPresent(URL.self, forKey: .pageURL)
        assets = try c.decodeIfPresent([Asset].self, forKey: .assets) ?? []
        if name.isEmpty { name = tag }
    }

    /// What kind of release this is, by its tag; a pre-release with another tag counts as a beta.
    public var kind: ReleaseKind {
        let lower = tag.lowercased()
        if lower.hasPrefix("nightly") { return .nightly }
        if lower.hasPrefix("beta") { return .beta }
        return isPrerelease ? .beta : .release
    }

    /// FineWine.app's zip among the assets ("FineWine-0.1.0-453b18c3.zip"). The patcher's zip
    /// ("finewine-patcher-…", "FineWine.Patcher.app.zip") is not it.
    public var appAsset: Asset? {
        assets.first { asset in
            asset.name.hasPrefix("FineWine-") && asset.name.lowercased().hasSuffix(".zip")
                && !asset.name.lowercased().contains("patcher")
        }
    }

    public var checksumsAsset: Asset? { assets.first { $0.name == "SHA256SUMS.txt" } }

    /// The commit the app's zip was built from, as far as its name says ("453b18c3").
    public var appCommitPrefix: String? {
        guard let name = appAsset?.name.dropLast(4) else { return nil }     // without ".zip"
        guard let last = name.split(separator: "-").last, last.count >= 7,
              last.allSatisfy({ $0.isHexDigit }) else { return nil }
        return last.lowercased()
    }

    /// Reads the JSON GitHub returns for a list of releases.
    public static func list(fromJSON data: Data) throws -> [ReleaseInfo] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode([ReleaseInfo].self, from: data)
    }
}

/// What the running app is: the build script writes these into its Info.plist.
public struct BuildIdentity: Equatable, Sendable {
    /// "0.1.0"
    public var version: String
    /// The commit it was built from, empty when not recorded (a build made by hand long ago).
    public var commit: String
    /// When it was built.
    public var builtAt: Date
    /// "release", "beta", "nightly", or "dev" for a build made on someone's own Mac.
    public var channel: String

    public init(version: String, commit: String, builtAt: Date, channel: String) {
        self.version = version
        self.commit = commit
        self.builtAt = builtAt
        self.channel = channel
    }

    public static func of(bundle: Bundle = .main) -> BuildIdentity {
        let info = bundle.infoDictionary ?? [:]
        let version = info["CFBundleShortVersionString"] as? String ?? "0"
        let commit = (info["FineWineCommit"] as? String ?? "").lowercased()
        let channel = info["FineWineChannel"] as? String ?? "dev"
        var builtAt: Date?
        if let text = info["FineWineBuildDate"] as? String { builtAt = ISO8601DateFormatter().date(from: text) }
        if builtAt == nil, let executable = bundle.executableURL {
            builtAt = (try? executable.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        }
        return BuildIdentity(version: version, commit: commit, builtAt: builtAt ?? .distantPast, channel: channel)
    }

    /// "0.1.0 (453b18c3, beta)"
    public var summary: String {
        var parts: [String] = []
        if !commit.isEmpty { parts.append(String(commit.prefix(8))) }
        if !channel.isEmpty { parts.append(channel) }
        return parts.isEmpty ? version : "\(version) (\(parts.joined(separator: ", ")))"
    }
}

/// An update that can be installed.
public struct UpdateOffer: Equatable, Sendable {
    public var release: ReleaseInfo
    public var asset: ReleaseInfo.Asset
    public var checksums: ReleaseInfo.Asset?
}

public enum UpdateChecker {
    /// The repository whose releases are FineWine's.
    public static let repository = "stoicswe/Endfield_FineWine"
    public static var feedURL: URL { URL(string: "https://api.github.com/repos/\(repository)/releases?per_page=40")! }
    public static var releasesPageURL: URL { URL(string: "https://github.com/\(repository)/releases")! }

    /// Whether a release is a newer build than the running one: published after this build was
    /// made, and not built from the same commit (a build is made before the release that
    /// carries it is published, so the date alone would offer a build to itself).
    public static func isNewer(_ release: ReleaseInfo, than current: BuildIdentity) -> Bool {
        guard let published = release.publishedAt, published > current.builtAt else { return false }
        if let prefix = release.appCommitPrefix, !current.commit.isEmpty, current.commit.hasPrefix(prefix) { return false }
        return true
    }

    /// The update to offer, if any: the newest release of the channel that carries the app and
    /// is newer than the running build. A release the user skipped is passed over unless they
    /// asked for the check themselves (`includingSkipped`).
    public static func offer(from releases: [ReleaseInfo], channel: UpdateChannel, current: BuildIdentity,
                             skippedTag: String? = nil, includingSkipped: Bool = false) -> UpdateOffer? {
        let candidates = releases
            .filter { !$0.isDraft && channel.includes($0.kind) && $0.appAsset != nil && $0.publishedAt != nil }
            .sorted { ($0.publishedAt ?? .distantPast) > ($1.publishedAt ?? .distantPast) }
        guard let newest = candidates.first, isNewer(newest, than: current), let asset = newest.appAsset else { return nil }
        if !includingSkipped, let skippedTag, skippedTag == newest.tag { return nil }
        return UpdateOffer(release: newest, asset: asset, checksums: newest.checksumsAsset)
    }

    /// The SHA-256 a `SHA256SUMS.txt` gives for a file: lines of "<hex>  <name>", where the
    /// name may have "./" or "*" in front.
    public static func checksum(for fileName: String, inSums text: String) -> String? {
        for line in text.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
            guard parts.count == 2, parts[0].count == 64, parts[0].allSatisfy({ $0.isHexDigit }) else { continue }
            var name = parts[1].trimmingCharacters(in: .whitespaces)
            if name.hasPrefix("*") { name.removeFirst() }
            if name.hasPrefix("./") { name.removeFirst(2) }
            if name == fileName { return parts[0].lowercased() }
        }
        return nil
    }

    /// Fetches the releases from GitHub. Nothing about the user or the Mac is sent.
    public static func fetchReleases(session: URLSession = .shared) async throws -> [ReleaseInfo] {
        var request = URLRequest(url: feedURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("FineWine-Updater", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            if http.statusCode == 403 || http.statusCode == 429 { throw FineWineError(tr("update.err_rate_limited")) }
            throw FineWineError(tr("update.err_feed_status", http.statusCode))
        }
        return try ReleaseInfo.list(fromJSON: data)
    }

    public static func fetchText(_ url: URL, session: URLSession = .shared) async throws -> String {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        request.setValue("FineWine-Updater", forHTTPHeaderField: "User-Agent")
        let (data, _) = try await session.data(for: request)
        return String(decoding: data, as: UTF8.self)
    }
}

/// Downloads a file and says how far it is.
public final class UpdateDownload: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let onProgress: @Sendable (_ received: Int64, _ expected: Int64) -> Void
    private var continuation: CheckedContinuation<URL, Error>?
    private var session: URLSession?
    private var task: URLSessionDownloadTask?
    private let destination: URL
    private let expectedSize: Int64

    public init(destination: URL, expectedSize: Int64,
                onProgress: @escaping @Sendable (_ received: Int64, _ expected: Int64) -> Void) {
        self.destination = destination
        self.expectedSize = expectedSize
        self.onProgress = onProgress
    }

    /// Downloads `url` to the destination and returns it.
    public func run(_ url: URL) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = 60
            let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
            self.session = session
            var request = URLRequest(url: url)
            request.setValue("FineWine-Updater", forHTTPHeaderField: "User-Agent")
            let task = session.downloadTask(with: request)
            self.task = task
            task.resume()
        }
    }

    public func cancel() { task?.cancel() }

    public func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                           totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        onProgress(totalBytesWritten, totalBytesExpectedToWrite > 0 ? totalBytesExpectedToWrite : expectedSize)
    }

    public func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        // The file at `location` is gone when this returns, so it is moved now.
        do {
            if let http = downloadTask.response as? HTTPURLResponse, http.statusCode != 200 {
                throw FineWineError(tr("update.err_download_status", http.statusCode))
            }
            let fm = FileManager.default
            try? fm.removeItem(at: destination)
            try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fm.moveItem(at: location, to: destination)
            finish(.success(destination))
        } catch {
            finish(.failure(error))
        }
    }

    public func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error { finish(.failure(error)) }
    }

    private func finish(_ result: Result<URL, Error>) {
        guard let continuation else { return }
        self.continuation = nil
        session?.finishTasksAndInvalidate()
        continuation.resume(with: result)
    }
}

/// Puts a downloaded FineWine.app in place of the running one.
public enum UpdateInstaller {
    public static let bundleIdentifier = "io.github.stoicswe.FineWine"

    /// The SHA-256 of a file, read in pieces (the zip is over 150 MB).
    public static func sha256(of file: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            let chunk = try handle.read(upToCount: 4 << 20) ?? Data()
            if chunk.isEmpty { break }
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Checks the zip against the release's checksum, when the release has one for it.
    public static func verify(zip: URL, expectedSHA256: String?, log: (String) -> Void) throws {
        guard let expectedSHA256 else {
            log(tr("update.log_no_checksum"))
            return
        }
        let actual = try sha256(of: zip)
        guard actual == expectedSHA256.lowercased() else {
            throw FineWineError(tr("update.err_checksum", zip.lastPathComponent))
        }
        log(tr("update.log_checksum_ok", String(actual.prefix(16))))
    }

    private static func run(_ tool: String, _ arguments: [String]) throws -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// Unpacks the zip into `folder` and returns the FineWine.app inside, after checking that it
    /// is FineWine, that its signature is whole, and that this macOS can run it.
    public static func unpack(zip: URL, into folder: URL, log: (String) -> Void) throws -> URL {
        let fm = FileManager.default
        try? fm.removeItem(at: folder)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        log(tr("update.log_unpacking"))
        // ditto keeps the code signature and the symbolic links inside the bundle intact
        let unzip = try run("/usr/bin/ditto", ["-x", "-k", zip.path, folder.path])
        guard unzip.status == 0 else { throw FineWineError(tr("update.err_unpack", unzip.output)) }

        let found = (try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil))?
            .first { $0.pathExtension == "app" }
        guard let app = found, let bundle = Bundle(url: app) else { throw FineWineError(tr("update.err_no_app")) }
        guard bundle.bundleIdentifier == bundleIdentifier else {
            throw FineWineError(tr("update.err_wrong_app", bundle.bundleIdentifier ?? "?"))
        }
        if let minimum = bundle.infoDictionary?["LSMinimumSystemVersion"] as? String {
            let parts = minimum.split(separator: ".").compactMap { Int($0) }
            let needed = OperatingSystemVersion(majorVersion: parts.first ?? 0, minorVersion: parts.count > 1 ? parts[1] : 0,
                                                patchVersion: parts.count > 2 ? parts[2] : 0)
            guard ProcessInfo.processInfo.isOperatingSystemAtLeast(needed) else {
                throw FineWineError(tr("update.err_needs_macos", minimum))
            }
        }
        log(tr("update.log_checking_signature"))
        let sign = try run("/usr/bin/codesign", ["--verify", "--deep", "--strict", app.path])
        guard sign.status == 0 else { throw FineWineError(tr("update.err_signature", sign.output)) }
        // It came from FineWine's own download, not through a browser: nothing to be asked about.
        _ = try? run("/usr/bin/xattr", ["-dr", "com.apple.quarantine", app.path])
        let version = bundle.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let commit = (bundle.infoDictionary?["FineWineCommit"] as? String).map { String($0.prefix(8)) } ?? ""
        log(tr("update.log_unpacked", commit.isEmpty ? version : "\(version) (\(commit))"))
        return app
    }

    /// Puts `newApp` where `installed` is. The old app is moved aside first and put back if the
    /// new one cannot be moved in; when all went well it goes to the Trash.
    public static func replace(installed: URL, with newApp: URL, log: (String) -> Void) throws {
        let fm = FileManager.default
        let parent = installed.deletingLastPathComponent()
        guard fm.isWritableFile(atPath: parent.path) else {
            throw FineWineError(tr("update.err_not_writable", parent.path))
        }
        let aside = parent.appendingPathComponent(".FineWine-previous-\(ProcessInfo.processInfo.processIdentifier).app")
        try? fm.removeItem(at: aside)
        log(tr("update.log_replacing", installed.path))
        try fm.moveItem(at: installed, to: aside)
        do {
            // A move within one volume is a rename; from another volume it is a copy.
            if (try? fm.moveItem(at: newApp, to: installed)) == nil {
                try fm.copyItem(at: newApp, to: installed)
            }
        } catch {
            try? fm.removeItem(at: installed)
            try? fm.moveItem(at: aside, to: installed)
            throw FineWineError(tr("update.err_replace", error.localizedDescription))
        }
        if (try? fm.trashItem(at: aside, resultingItemURL: nil)) == nil { try? fm.removeItem(at: aside) }
        log(tr("update.log_replaced"))
    }

    /// Starts `app` once the process `pid` has ended, from a process of its own.
    public static func relaunch(_ app: URL, afterExitOf pid: Int32) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "while /bin/kill -0 \"$0\" 2>/dev/null; do /bin/sleep 0.2; done; /usr/bin/open \"$1\"",
                             String(pid), app.path]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
    }
}
