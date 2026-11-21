import Foundation

/// Conversions between Windows paths inside a prefix and Mac paths.
public enum WindowsPath {
    /// The last component of a Windows path (`C:\a\b.exe` → `b.exe`). Forward slashes count as
    /// separators too, as they do on Windows.
    public static func lastComponent(_ path: String) -> String {
        components(path).last ?? ""
    }

    /// The path without its last component (`C:\a\b.exe` → `C:\a`).
    public static func directory(_ path: String) -> String {
        guard let index = path.lastIndex(where: { $0 == "\\" || $0 == "/" }) else { return "" }
        let dir = String(path[..<index])
        return dir.count == 2 && dir.hasSuffix(":") ? dir + "\\" : dir
    }

    static func components(_ path: String) -> [String] {
        path.split(whereSeparator: { $0 == "\\" || $0 == "/" }).map(String.init)
    }

    /// The drive letter of an absolute Windows path, lower-cased.
    public static func driveLetter(_ path: String) -> Character? {
        let chars = Array(path.prefix(2))
        guard chars.count == 2, chars[1] == ":", chars[0].isLetter, chars[0].isASCII else { return nil }
        return Character(chars[0].lowercased())
    }

    /// The Mac location of a Windows path in a prefix. Drives are looked up through
    /// `dosdevices`, the way Wine does, and each component is matched without regard to case
    /// when an exact match doesn't exist. Returns `nil` for relative paths and unmapped drives.
    public static func macURL(for windowsPath: String, inPrefix prefix: URL) -> URL? {
        guard let drive = driveLetter(windowsPath) else { return nil }
        let fm = FileManager.default
        var url = prefix.appendingPathComponent("dosdevices/\(drive):")
        if !fm.fileExists(atPath: url.path) {
            // What Wine sets these two up as, for a prefix whose links are not there (yet):
            // `windowsPath(for:inPrefix:)` writes paths with them either way.
            switch drive {
            case "c": url = prefix.appendingPathComponent("drive_c", isDirectory: true)
            case "z": url = URL(fileURLWithPath: "/", isDirectory: true)
            default: return nil
            }
        }
        url = url.resolvingSymlinksInPath()
        for component in components(String(windowsPath.dropFirst(2))) {
            if component == "." { continue }
            if component == ".." { url.deleteLastPathComponent(); continue }
            // Match against the folder's real entries, so the result carries the names as they
            // are on disk even on a case-insensitive volume.
            let entries = (try? fm.contentsOfDirectory(atPath: url.path)) ?? []
            let match = entries.first { $0 == component }
                ?? entries.first { $0.caseInsensitiveCompare(component) == .orderedSame }
            url = url.appendingPathComponent(match ?? component)
        }
        return url
    }

    /// The folder a file panel should open in to replace a Windows path: the folder the path
    /// is in, or the nearest one above it that exists, or `drive_c` when the path leads nowhere.
    public static func folderToBrowse(from windowsPath: String, inPrefix prefix: URL) -> URL {
        let fm = FileManager.default
        let driveC = prefix.appendingPathComponent("drive_c", isDirectory: true)
        guard var url = macURL(for: windowsPath.trimmingCharacters(in: .whitespaces), inPrefix: prefix) else { return driveC }
        var isDir: ObjCBool = false
        while url.path != "/" {
            if fm.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue { return url }
            url.deleteLastPathComponent()
        }
        return driveC
    }

    /// The Windows path for a Mac file: `C:\…` when it is inside the prefix's `drive_c`,
    /// otherwise through Wine's `Z:` drive, which maps the whole Mac filesystem.
    public static func windowsPath(for url: URL, inPrefix prefix: URL) -> String {
        let file = url.resolvingSymlinksInPath().path
        let driveC = prefix.appendingPathComponent("drive_c").resolvingSymlinksInPath().path
        if file == driveC { return "C:\\" }
        if file.hasPrefix(driveC + "/") {
            return "C:" + file.dropFirst(driveC.count).replacingOccurrences(of: "/", with: "\\")
        }
        return "Z:" + file.replacingOccurrences(of: "/", with: "\\")
    }
}
