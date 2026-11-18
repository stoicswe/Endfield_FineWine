import Foundation
import Darwin

/// How far a long copy has got, and a way to stop it. Shared between the copy (on a worker
/// thread) and whoever shows it.
public final class CopyProgress: @unchecked Sendable {
    private let lock = NSLock()
    private var _total: Int64 = 0
    private var _done: Int64 = 0
    private var _current: Int64 = 0
    private var _cancelled = false

    public init() {}

    /// Bytes to copy (the files' sizes), known once the folder has been measured.
    public var totalBytes: Int64 { lock.withLock { _total } }
    /// Bytes copied so far.
    public var copiedBytes: Int64 { lock.withLock { _done + _current } }
    public var fraction: Double {
        lock.withLock { _total > 0 ? min(1, Double(_done + _current) / Double(_total)) : 0 }
    }
    public var isCancelled: Bool { lock.withLock { _cancelled } }

    /// Asks the copy to stop. What was copied is removed; the original is untouched.
    public func cancel() { lock.withLock { _cancelled = true } }

    func setTotal(_ bytes: Int64) { lock.withLock { _total = bytes } }
    func finishFile(_ bytes: Int64) { lock.withLock { _done += bytes; _current = 0 } }
    func setCurrent(_ bytes: Int64) { lock.withLock { _current = bytes } }
}

/// Copies a prefix folder the way a prefix has to be copied.
///
/// - Symbolic links are copied as links and never followed. A prefix's `dosdevices/z:` points
///   at `/`; following it would copy the whole Mac.
/// - On APFS, a copy on the same volume is a clone. It is made at once and takes no space
///   until one side changes.
/// - Progress is reported file by file and inside large files, and the copy can be cancelled.
public enum FolderCopy {
    public static let cancelledMessage = "cancelled"

    /// The files' sizes (for progress) and the space they take on disk (for the free-space
    /// check), without following links.
    public static func measure(_ folder: URL) -> (bytes: Int64, allocated: Int64) {
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey, .totalFileAllocatedSizeKey]
        guard let walk = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: keys,
                                                         options: [], errorHandler: { _, _ in true }) else { return (0, 0) }
        var bytes: Int64 = 0, allocated: Int64 = 0
        for case let url as URL in walk {
            guard let values = try? url.resourceValues(forKeys: Set(keys)), values.isRegularFile == true else { continue }
            bytes += Int64(values.fileSize ?? 0)
            allocated += Int64(values.totalFileAllocatedSize ?? values.fileSize ?? 0)
        }
        return (bytes, allocated)
    }

    /// Copies `source` (a folder) to `destination`, which must not exist yet. On failure or
    /// cancellation the partial copy is removed and the error is thrown; a cancelled copy
    /// throws `FineWineError(cancelledMessage)`.
    public static func copy(_ source: URL, to destination: URL, progress: CopyProgress = CopyProgress()) throws {
        let fm = FileManager.default
        if progress.totalBytes == 0 { progress.setTotal(measure(source).bytes) }
        guard !fm.fileExists(atPath: destination.path) else {
            throw FineWineError("“\(destination.path)” already exists.")
        }
        do {
            try copyTree(source, to: destination, progress: progress)
        } catch {
            try? fm.removeItem(at: destination)
            throw progress.isCancelled ? FineWineError(cancelledMessage) : error
        }
    }

    static func copyTree(_ source: URL, to destination: URL, progress: CopyProgress) throws {
        let fm = FileManager.default
        var directories: [(URL, URL)] = []
        try makeDirectory(destination, like: source)
        directories.append((source, destination))
        let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey, .isRegularFileKey, .fileSizeKey]
        // The enumerator does not go into linked folders.
        guard let walk = fm.enumerator(at: source, includingPropertiesForKeys: keys, options: [],
                                       errorHandler: { _, _ in false }) else {
            throw FineWineError("“\(source.path)” can't be read.")
        }
        let base = source.standardizedFileURL.path
        for case let url as URL in walk {
            if progress.isCancelled { throw FineWineError(cancelledMessage) }
            let relative = String(url.standardizedFileURL.path.dropFirst(base.count + 1))
            let target = destination.appendingPathComponent(relative)
            let values = try url.resourceValues(forKeys: Set(keys))
            if values.isSymbolicLink == true {
                try fm.createSymbolicLink(atPath: target.path,
                                          withDestinationPath: fm.destinationOfSymbolicLink(atPath: url.path))
            } else if values.isDirectory == true {
                try makeDirectory(target, like: url)
                directories.append((url, target))
            } else if values.isRegularFile == true {
                try copyFile(url, to: target, progress: progress)
                progress.finishFile(Int64(values.fileSize ?? 0))
            }
            // Anything else (a socket, a pipe) is not part of a prefix and is left out.
        }
        // Folder dates last, since filling a folder changes its date.
        for (from, to) in directories.reversed() {
            guard let attributes = try? fm.attributesOfItem(atPath: from.path) else { continue }
            var keep: [FileAttributeKey: Any] = [:]
            if let date = attributes[.modificationDate] { keep[.modificationDate] = date }
            if let mode = attributes[.posixPermissions] { keep[.posixPermissions] = mode }
            try? fm.setAttributes(keep, ofItemAtPath: to.path)
        }
    }

    private static func makeDirectory(_ url: URL, like source: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        // Writable while being filled; the original permissions are put back at the end.
        chmod(url.path, 0o755)
    }

    /// Copies one file: a clone where the file system allows it, else a copy of the data,
    /// with its permissions, dates and extended attributes.
    private static func copyFile(_ source: URL, to destination: URL, progress: CopyProgress) throws {
        guard let state = copyfile_state_alloc() else { throw FineWineError("Out of memory.") }
        defer { copyfile_state_free(state) }
        let context = Unmanaged.passUnretained(progress).toOpaque()
        copyfile_state_set(state, UInt32(COPYFILE_STATE_STATUS_CTX), context)
        let callback: copyfile_callback_t = { what, stage, state, _, _, context in
            guard let context else { return COPYFILE_CONTINUE }
            let progress = Unmanaged<CopyProgress>.fromOpaque(context).takeUnretainedValue()
            if progress.isCancelled { return COPYFILE_QUIT }
            if what == COPYFILE_COPY_DATA, stage == COPYFILE_PROGRESS {
                var copied: off_t = 0
                copyfile_state_get(state, UInt32(COPYFILE_STATE_COPIED), &copied)
                progress.setCurrent(Int64(copied))
            }
            return COPYFILE_CONTINUE
        }
        copyfile_state_set(state, UInt32(COPYFILE_STATE_STATUS_CB), unsafeBitCast(callback, to: UnsafeRawPointer.self))
        let flags = copyfile_flags_t(COPYFILE_CLONE) | copyfile_flags_t(COPYFILE_ALL)
        if copyfile(source.path, destination.path, state, flags) != 0 {
            let code = errno
            if progress.isCancelled { throw FineWineError(cancelledMessage) }
            throw FineWineError("“\(source.lastPathComponent)” couldn't be copied: \(String(cString: strerror(code))).")
        }
    }
}
