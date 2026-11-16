import Foundation

/// The Windows file types FineWine can be asked to open from Finder, and where such a file
/// should run.
public enum WindowsExecutable {
    /// File extensions FineWine opens, lower-cased.
    public static let extensions = ["exe", "msi"]

    /// The uniform type identifiers for `extensions`. `.exe` has a system-declared type; the
    /// one for `.msi` is declared in FineWine's Info.plist.
    public static let exeTypeIdentifier = "com.microsoft.windows-executable"
    public static let msiTypeIdentifier = "io.github.stoicswe.finewine.msi-installer"
    public static let typeIdentifiers = [exeTypeIdentifier, msiTypeIdentifier]

    /// True when the file is a 32-bit Windows program, which FineWine's runtime cannot run (a
    /// native Apple silicon process has no memory below 4 GB to give one).
    public static func is32BitProgram(_ url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        guard let dos = try? handle.read(upToCount: 64), dos.count == 64, dos[0] == 0x4D, dos[1] == 0x5A else { return false }
        try? handle.seek(toOffset: UInt64(dos.le32(at: 0x3C)))
        guard let pe = try? handle.read(upToCount: 6), pe.count == 6, pe.le32(at: 0) == 0x4550 else { return false }
        return pe.le16(at: 4) == 0x014C
    }

    public static func isSupported(_ url: URL) -> Bool {
        url.isFileURL && extensions.contains(url.pathExtension.lowercased())
    }

    /// The prefix whose folder contains the file, if any. A program that already lives in a
    /// prefix runs there without asking.
    public static func owningPrefix(of url: URL, among prefixes: [Prefix]) -> Prefix? {
        let file = url.resolvingSymlinksInPath().path
        return prefixes.first { prefix in
            file.hasPrefix(prefix.directory.resolvingSymlinksInPath().path + "/")
        }
    }

    /// How a file opened from Finder should be handled.
    public enum Route: Equatable {
        /// Not a file FineWine opens.
        case unsupported
        /// There is nowhere to run it yet.
        case needsPrefix
        /// Run it in this prefix straight away.
        case run(in: Prefix)
        /// Ask which of these prefixes to run it in.
        case choose(from: [Prefix])
    }

    public static func route(for url: URL, prefixes: [Prefix]) -> Route {
        guard isSupported(url) else { return .unsupported }
        if let owner = owningPrefix(of: url, among: prefixes) { return .run(in: owner) }
        // Anything from outside a prefix (a download, say) gets a prefix of its own or a
        // question, as the user has set (OpenedFilePolicy); the app decides which.
        return prefixes.isEmpty ? .needsPrefix : .choose(from: prefixes)
    }
}
