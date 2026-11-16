import Foundation

/// What FineWine does with a Windows program or installer opened from outside any prefix.
public enum OpenedFilePolicy: String, CaseIterable, Sendable {
    /// Make a prefix for it, named after it, and run it there.
    case autoCreate
    /// Ask: a new prefix, or one that exists.
    case ask

    public var displayName: String {
        switch self {
        case .autoCreate: return "Auto create prefix"
        case .ask: return "Ask Me"
        }
    }
}

/// Names a new prefix after the program or installer that is about to be run in it.
public enum InstallName {
    public static let fallback = "New Prefix"
    static let maxLength = 60

    /// Words that say what kind of file it is, not what it installs.
    static let noiseWords: Set<String> = [
        "setup", "install", "installer", "installation", "launcher", "bootstrapper", "web", "online", "offline",
        "x64", "x86", "x86_64", "amd64", "arm64", "win", "win32", "win64", "windows", "64bit", "32bit",
        "global", "latest", "release", "final", "full", "exe", "msi",
    ]

    /// A name, and how much it can be trusted: one the installer states about itself is kept;
    /// one guessed from a file name is replaced once the installer has shown what it installs.
    public struct Hint: Equatable, Sendable {
        public var name: String
        public var isFromInstaller: Bool
    }

    /// The name for a prefix made for `url`, different from every name in `existing`.
    public static func prefixName(for url: URL, existing: [String]) -> String {
        prefixHint(for: url, existing: existing).name
    }

    /// The order of trust:
    ///  1. a file name that spells a name out in words (`ZenlessZoneZero_install_ua_4a4c…` is
    ///     Zenless Zone Zero). It is what the user chose to download, and it is more exact than
    ///     the installer's own name when one launcher's installer serves several games;
    ///  2. what the installer says it installs (its version information);
    ///  3. whatever the file name gives, as a guess to be corrected after the installation.
    public static func prefixHint(for url: URL, existing: [String]) -> Hint {
        let fromFile = cleaned(fileName: url.deletingPathExtension().lastPathComponent)
        if fromFile != fallback, isSpelledOut(fromFile) { return Hint(name: unique(fromFile, among: existing), isFromInstaller: true) }
        if url.pathExtension.lowercased() == "exe", let name = statedName(at: url) {
            return Hint(name: unique(name, among: existing), isFromInstaller: true)
        }
        return Hint(name: unique(fromFile, among: existing), isFromInstaller: false)
    }

    /// Two or more words, each a real word: letters only, three or more of them.
    static func isSpelledOut(_ name: String) -> Bool {
        let words = name.split(separator: " ")
        return words.count >= 2 && words.allSatisfy { $0.count >= 3 && $0.allSatisfy(\.isLetter) }
    }

    /// What the installer says it installs: the first of its product name, its description and
    /// its internal name that is more than a word for "installer".
    public static func statedName(at url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        let version = versionResource { offset, count in
            guard (try? handle.seek(toOffset: UInt64(offset))) != nil else { return nil }
            return try? handle.read(upToCount: count)
        }
        guard let version else { return nil }
        for key in ["ProductName", "FileDescription", "InternalName"] {
            if let raw = versionString(key, in: version), let name = cleaned(productName: raw) { return name }
        }
        return nil
    }

    // MARK: After the installer has run

    /// Shortcuts an installer leaves that are not the program itself.
    static let sideShortcutWords = ["uninstall", "readme", "read me", "help", "manual", "website", "web site",
                                    "license", "licence", "documentation", "release notes", "support", "repair"]
    /// Folders that say nothing about what is in them.
    static let genericFolders: Set<String> = ["program files", "program files (x86)", "programdata", "users", "windows",
                                              "games", "bin", "binaries", "win64", "win32", "x64", "x86", "app", "apps",
                                              "appdata", "local", "roaming", "programs", "public", "desktop"]

    /// A name from what an installer installed: the one program's name; for several, the
    /// words their names start with in common, else the folder they were all installed into.
    public static func installedName(programs: [(name: String, windowsPath: String)]) -> String? {
        let main = programs.filter { program in
            !sideShortcutWords.contains { program.name.lowercased().contains($0) }
        }
        guard !main.isEmpty else { return nil }
        if main.count == 1 { return nonEmpty(tidy(main[0].name)) }

        let wordLists = main.map { $0.name.split(separator: " ").map(String.init) }
        var common: [String] = []
        for (index, word) in wordLists[0].enumerated() {
            guard wordLists.allSatisfy({ $0.count > index && $0[index].lowercased() == word.lowercased() }) else { break }
            common.append(word)
        }
        if let name = nonEmpty(tidy(common.joined(separator: " "))), name.count >= 3 { return name }

        let folders = main.map { Array($0.windowsPath.split(whereSeparator: { $0 == "\\" || $0 == "/" }).map(String.init).dropLast()) }
        var shared: [String] = []
        for (index, part) in folders[0].enumerated() {
            guard folders.allSatisfy({ $0.count > index && $0[index].lowercased() == part.lowercased() }) else { break }
            shared.append(part)
        }
        // The deepest folder they share that names something; never the drive.
        for part in shared.dropFirst().reversed() where !genericFolders.contains(part.lowercased()) {
            return nonEmpty(tidy(part))
        }
        return nil
    }

    private static func nonEmpty(_ s: String) -> String? { s.isEmpty ? nil : s }

    /// `base`, or `base 2`, `base 3`, …: the first that no prefix has. Names compare without case.
    public static func unique(_ base: String, among existing: [String]) -> String {
        let taken = Set(existing.map { $0.lowercased() })
        if !taken.contains(base.lowercased()) { return base }
        var n = 2
        while taken.contains("\(base) \(n)".lowercased()) { n += 1 }
        return "\(base) \(n)"
    }

    /// Words an installer uses about itself, wherever they stand in its product name.
    static let installerWords: Set<String> = [
        "setup", "install", "installer", "installation", "wizard", "bootstrapper", "uninstaller", "stub",
        "x64", "x86", "amd64", "arm64", "64-bit", "32-bit", "64bit", "32bit", "win32", "win64",
    ]

    /// A product name from a program's version information, if it says anything:
    /// "Some Game Setup", "Setup for Some Game (64-bit) 1.2.3" and "Some Game Web Installer"
    /// are all Some Game.
    static func cleaned(productName raw: String) -> String? {
        let bare = CharacterSet(charactersIn: "()[],;:")
        var words = raw.split(whereSeparator: { $0.isWhitespace || $0.isNewline })
            .map { String($0).trimmingCharacters(in: bare) }
            .filter { !$0.isEmpty && !installerWords.contains($0.lowercased()) && !isVersion($0.lowercased()) }
        // What is left dangling once those are gone: "for X", "X web", "X version".
        let leading: Set<String> = ["for", "of", "the", "-"], trailing: Set<String> = ["web", "online", "offline", "version", "for", "-", "windows"]
        while let first = words.first, leading.contains(first.lowercased()), words.count > 1 { words.removeFirst() }
        while let last = words.last, trailing.contains(last.lowercased()) { words.removeLast() }
        let name = tidy(words.joined(separator: " "))
        return name.count >= 2 ? name : nil
    }

    /// A name from a file name such as `Some_Game-Setup_v1.2.3_x64` or
    /// `SomeGame_install_ua_4a4c7a42c0e9`. The name is what comes before the first word that
    /// says "installer" or gives a version: what follows is a channel, a build, a hash.
    static func cleaned(fileName raw: String) -> String {
        let separators = CharacterSet(charactersIn: "_-+()[]{},").union(.whitespaces)
        var parts = raw.components(separatedBy: separators).filter { !$0.isEmpty }
        // Dots separate words only when nothing else does ("Some.Game.Setup").
        if parts.count == 1, parts[0].contains(".") { parts = parts[0].split(separator: ".").map(String.init) }
        func isNoise(_ word: String) -> Bool {
            let lower = word.lowercased()
            return noiseWords.contains(lower) || isVersion(lower) || isHash(lower)
        }
        // Words run together are taken apart first, so that "ChromeSetup" loses its "Setup" too.
        parts = parts.flatMap { splitJoinedWords($0).split(separator: " ").map(String.init) }
        var words = Array(parts.prefix { !isNoise($0) })
        // A file that starts with such a word ("Setup_SomeGame_1.2") has its name after it.
        if words.isEmpty { words = parts.filter { !isNoise($0) } }
        let name = tidy(words.joined(separator: " "))
        return name.isEmpty ? fallback : name
    }

    /// `4a4c7a42c0e9`: a build hash, not a word.
    static func isHash(_ word: String) -> Bool {
        word.count >= 6 && word.contains(where: \.isNumber) && word.allSatisfy(\.isHexDigit)
    }

    /// `SomeGameName` → `Some Game Name`, when it plainly is words run together: every piece
    /// a capital followed by at least two small letters. `HoYoPlay` and `iTunes` stay as they are.
    static func splitJoinedWords(_ word: String) -> String {
        var pieces: [String] = []
        for ch in word {
            if ch.isUppercase || pieces.isEmpty { pieces.append(String(ch)) } else { pieces[pieces.count - 1].append(ch) }
        }
        guard pieces.count > 1, pieces.allSatisfy({ piece in
            piece.count >= 3 && piece.first!.isUppercase && piece.dropFirst().allSatisfy { $0.isLowercase }
        }) else { return word }
        return pieces.joined(separator: " ")
    }

    /// `1.2.3`, `v2`, `v1.0.4b`, `2024`, `20261115`: a version or build number. A short bare
    /// number is not one: it is the 2 of a sequel.
    static func isVersion(_ word: String) -> Bool {
        var w = Substring(word)
        let marked = w.hasPrefix("v") && w.count > 1
        if marked { w = w.dropFirst() }
        guard let first = w.first, first.isNumber else { return false }
        let numeric = w.allSatisfy { $0.isNumber || $0 == "." }
        let numericButLast = w.count > 1 && w.dropLast().allSatisfy { $0.isNumber || $0 == "." }
        guard numeric || numericButLast else { return false }
        return marked || w.contains(".") || (numeric && w.count >= 4)
    }

    private static func tidy(_ name: String) -> String {
        // Characters that are trouble in a name shown in menus and used for a shortcut app.
        let cleaned = String(name.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) && !"/:\\".unicodeScalars.contains($0) })
            .trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: ".-_")))
        return String(cleaned.prefix(maxLength)).trimmingCharacters(in: .whitespaces)
    }

    // MARK: Version information

    /// The program's own version resource. It is found through the program's resource table
    /// and not by searching the file: an installer carries other programs inside it, and their
    /// names are not its name. `read(offset, count)` gives bytes of the file.
    static func versionResource(read: (Int, Int) -> Data?) -> Data? {
        func bytes(_ offset: Int, _ count: Int) -> [UInt8]? {
            guard offset >= 0, count > 0, let d = read(offset, count), d.count == count else { return nil }
            return [UInt8](d)
        }
        func u16(_ b: [UInt8], _ o: Int) -> Int? { o >= 0 && o + 2 <= b.count ? Int(b[o]) | Int(b[o + 1]) << 8 : nil }
        func u32(_ b: [UInt8], _ o: Int) -> Int? {
            guard let lo = u16(b, o), let hi = u16(b, o + 2) else { return nil }
            return lo | hi << 16
        }
        guard let dos = bytes(0, 64), u16(dos, 0) == 0x5A4D, let pe = u32(dos, 0x3C),
              let head = bytes(pe, 24), u32(head, 0) == 0x4550,
              let sectionCount = u16(head, 6), let optionalSize = u16(head, 20), sectionCount <= 96,
              let optional = bytes(pe + 24, optionalSize + sectionCount * 40) else { return nil }
        let directories: Int
        switch u16(optional, 0) {
        case 0x10B: directories = 96
        case 0x20B: directories = 112
        default: return nil
        }
        guard let resourceRVA = u32(optional, directories + 2 * 8), resourceRVA != 0 else { return nil }
        func fileOffset(rva: Int) -> Int? {
            for i in 0..<sectionCount {
                let s = optionalSize + i * 40
                guard let vsize = u32(optional, s + 8), let va = u32(optional, s + 12),
                      let rawSize = u32(optional, s + 16), let raw = u32(optional, s + 20) else { return nil }
                if rva >= va && rva < va + max(vsize, rawSize) { return raw + (rva - va) }
            }
            return nil
        }
        guard let root = fileOffset(rva: resourceRVA) else { return nil }
        /// The entries of one resource directory: (id, target offset in the table, is a directory).
        func entries(at directory: Int) -> [(id: Int, target: Int, isDirectory: Bool)] {
            guard let header = bytes(root + directory, 16), let named = u16(header, 12), let ids = u16(header, 14),
                  named + ids > 0, named + ids <= 4096,
                  let table = bytes(root + directory + 16, (named + ids) * 8) else { return [] }
            return (0..<(named + ids)).compactMap { i in
                guard let name = u32(table, i * 8), let target = u32(table, i * 8 + 4) else { return nil }
                return (name, target & 0x7FFF_FFFF, target & 0x8000_0000 != 0)
            }
        }
        // Type 16 is version information; under it one name, under that one language.
        guard let type = entries(at: 0).first(where: { $0.id == 16 && $0.isDirectory }),
              let name = entries(at: type.target).first, name.isDirectory,
              let language = entries(at: name.target).first, !language.isDirectory,
              let leaf = bytes(root + language.target, 8), let rva = u32(leaf, 0), let size = u32(leaf, 4),
              size > 0, size <= 1 << 20, let offset = fileOffset(rva: rva) else { return nil }
        return read(offset, size)
    }


    /// The value of one string in a program's version resource. Each is stored as
    /// { length, value length in characters, type, key, padding, value }, all UTF-16.
    static func versionString(_ key: String, in data: Data) -> String? {
        let needle = Data(key.utf16.flatMap { [UInt8($0 & 0xff), UInt8($0 >> 8)] } + [0, 0])
        var from = data.startIndex
        while let found = data.range(of: needle, in: from..<data.endIndex) {
            from = found.lowerBound + 2
            let keyStart = found.lowerBound - data.startIndex
            guard keyStart >= 6 else { continue }
            func u16(_ o: Int) -> Int { Int(data[data.startIndex + o]) | Int(data[data.startIndex + o + 1]) << 8 }
            let valueLength = u16(keyStart - 4), type = u16(keyStart - 2)
            guard type == 1, valueLength > 1, valueLength <= 256 else { continue }
            // The value starts on a 4-byte boundary counted from the start of the entry.
            var value = keyStart + needle.count
            if (value - (keyStart - 6)) % 4 != 0 { value += 2 }
            var units: [UInt16] = []
            for i in 0..<(valueLength - 1) {
                let o = value + i * 2
                guard o + 2 <= data.count else { break }
                let unit = UInt16(u16(o))
                if unit == 0 { break }
                units.append(unit)
            }
            let text = String(decoding: units, as: UTF16.self).trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { return text }
        }
        return nil
    }
}
