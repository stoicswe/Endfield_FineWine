import Foundation

/// A Windows shortcut (`.lnk`), reduced to what FineWine needs to offer the program it points at.
public struct ShellLink: Equatable, Sendable {
    public var target: String
    public var arguments: String
    public var workingDirectory: String
    public var description: String

    /// Parses the Shell Link binary format ([MS-SHLLINK]). Returns `nil` for data that isn't a
    /// shortcut or that doesn't name a local file.
    public init?(data: Data) {
        let bytes = [UInt8](data)
        func u16(_ offset: Int) -> Int? {
            guard offset >= 0, offset + 2 <= bytes.count else { return nil }
            return Int(bytes[offset]) | Int(bytes[offset + 1]) << 8
        }
        func u32(_ offset: Int) -> Int? {
            guard offset >= 0, offset + 4 <= bytes.count else { return nil }
            return Int(bytes[offset]) | Int(bytes[offset + 1]) << 8 | Int(bytes[offset + 2]) << 16 | Int(bytes[offset + 3]) << 24
        }
        func ansiString(at offset: Int) -> String? {
            guard offset >= 0, offset < bytes.count else { return nil }
            let end = bytes[offset...].firstIndex(of: 0) ?? bytes.count
            return String(bytes: bytes[offset..<end], encoding: .windowsCP1252)
        }
        func unicodeString(at offset: Int) -> String? {
            var units: [UInt16] = []
            var position = offset
            while let unit = u16(position), unit != 0 {
                units.append(UInt16(unit))
                position += 2
            }
            return String(decoding: units, as: UTF16.self)
        }

        guard u32(0) == 0x4C, bytes.count >= 0x4C,
              // The shortcut class id, {00021401-0000-0000-C000-000000000046}.
              Array(bytes[4..<20]) == [0x01, 0x14, 0x02, 0x00, 0x00, 0x00, 0x00, 0x00,
                                       0xC0, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x46],
              let flags = u32(0x14) else { return nil }
        let hasIDList = flags & 0x01 != 0
        let hasLinkInfo = flags & 0x02 != 0
        let isUnicode = flags & 0x80 != 0

        var offset = 0x4C
        if hasIDList {
            guard let size = u16(offset) else { return nil }
            offset += 2 + size
        }

        var localPath: String?
        if hasLinkInfo {
            guard let size = u32(offset), let headerSize = u32(offset + 4),
                  let infoFlags = u32(offset + 8), size >= 0x1C, offset + size <= bytes.count else { return nil }
            if infoFlags & 0x01 != 0 {   // VolumeIDAndLocalBasePath
                var base: String?
                if headerSize >= 0x24, let unicodeOffset = u32(offset + 0x1C), unicodeOffset != 0 {
                    base = unicodeString(at: offset + unicodeOffset)
                } else if let baseOffset = u32(offset + 0x10) {
                    base = ansiString(at: offset + baseOffset)
                }
                var suffix = ""
                if headerSize >= 0x24, let unicodeSuffix = u32(offset + 0x20), unicodeSuffix != 0 {
                    suffix = unicodeString(at: offset + unicodeSuffix) ?? ""
                } else if let suffixOffset = u32(offset + 0x18) {
                    suffix = ansiString(at: offset + suffixOffset) ?? ""
                }
                if let base { localPath = base + suffix }
            }
            offset += size
        }

        // StringData: counted strings, present in this order when their flag is set.
        func readString() -> String? {
            guard let count = u16(offset) else { return nil }
            offset += 2
            if isUnicode {
                guard offset + count * 2 <= bytes.count else { return nil }
                var units: [UInt16] = []
                for i in 0..<count { units.append(UInt16(u16(offset + i * 2) ?? 0)) }
                offset += count * 2
                return String(decoding: units, as: UTF16.self)
            }
            guard offset + count <= bytes.count else { return nil }
            defer { offset += count }
            return String(bytes: bytes[offset..<offset + count], encoding: .windowsCP1252)
        }
        var strings: [Int: String] = [:]
        for bit in [0x04, 0x08, 0x10, 0x20, 0x40] where flags & bit != 0 {
            guard let string = readString() else { break }
            strings[bit] = string
        }

        guard let target = localPath, !target.isEmpty else { return nil }
        self.target = target
        self.description = strings[0x04] ?? ""
        self.workingDirectory = strings[0x10] ?? ""
        self.arguments = strings[0x20] ?? ""
    }
}

/// A program found by reading the shortcuts an installer left in a prefix.
public struct DiscoveredProgram: Equatable, Sendable {
    public var name: String
    public var windowsPath: String
    public var arguments: String
    public var workingDirectory: String
}

public enum ProgramScanner {
    /// Folders, relative to `drive_c`, where installers put shortcuts.
    static func shortcutFolders(driveC: URL) -> [URL] {
        var folders = [driveC.appendingPathComponent("ProgramData/Microsoft/Windows/Start Menu"),
                       driveC.appendingPathComponent("users/Public/Desktop")]
        let users = (try? FileManager.default.contentsOfDirectory(
            at: driveC.appendingPathComponent("users"), includingPropertiesForKeys: nil)) ?? []
        for user in users where user.lastPathComponent != "Public" {
            folders.append(user.appendingPathComponent("AppData/Roaming/Microsoft/Windows/Start Menu"))
            folders.append(user.appendingPathComponent("Desktop"))
        }
        return folders
    }

    /// Programs that shortcuts in the prefix point at: `.exe` targets only, one entry per
    /// executable, uninstallers left out, sorted by name.
    public static func scan(prefix: URL) -> [DiscoveredProgram] {
        let fm = FileManager.default
        var found: [String: DiscoveredProgram] = [:]
        for folder in shortcutFolders(driveC: prefix.appendingPathComponent("drive_c")) {
            guard let walker = fm.enumerator(at: folder, includingPropertiesForKeys: nil) else { continue }
            for case let file as URL in walker where file.pathExtension.lowercased() == "lnk" {
                guard let data = try? Data(contentsOf: file), let link = ShellLink(data: data) else { continue }
                let name = file.deletingPathExtension().lastPathComponent
                guard isProgram(name: name, target: link.target) else { continue }
                let key = link.target.lowercased()
                if found[key] == nil {
                    found[key] = DiscoveredProgram(name: name, windowsPath: link.target,
                                                   arguments: link.arguments,
                                                   workingDirectory: link.workingDirectory)
                }
            }
        }
        return found.values.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    static func isProgram(name: String, target: String) -> Bool {
        guard target.lowercased().hasSuffix(".exe") else { return false }
        let haystack = (name + " " + WindowsPath.lastComponent(target)).lowercased()
        return !["uninstall", "unins0", "uninst"].contains(where: haystack.contains)
    }

    /// Splits a Windows command-line argument string into arguments, honouring double quotes.
    public static func splitArguments(_ text: String) -> [String] {
        var out: [String] = []
        var current = ""
        var inQuotes = false
        var hasToken = false
        for ch in text {
            if ch == "\"" {
                inQuotes.toggle()
                hasToken = true
            } else if ch == " " || ch == "\t", !inQuotes {
                if hasToken { out.append(current); current = ""; hasToken = false }
            } else {
                current.append(ch)
                hasToken = true
            }
        }
        if hasToken { out.append(current) }
        return out
    }
}
