import Foundation

/// What carrying out an NSIS installer's script did.
public struct NSISInstallReport: Sendable, Equatable {
    public struct FoundProgram: Sendable, Equatable {
        /// The name the installer gave its shortcut, when it made one itself.
        public var name: String?
        public var windowsPath: String
        public var arguments: String
    }

    /// Where the program was installed, as Windows sees it (`C:\Program Files\Game`).
    public var installDirectory = ""
    public var filesWritten = 0
    /// Programs the installer would have made shortcuts for or started.
    public var programs: [FoundProgram] = []
    /// Registry entries the installer wrote, as a file `regedit` can import; empty when none.
    public var registryFile = ""
    /// Calls into the installer's add-ons (32-bit code, which cannot run), by name, and how often.
    public var skippedPluginCalls: [String: Int] = [:]
    /// Programs the installer would have run during installation, which were not run.
    public var skippedCommands: [String] = []
    /// Files copied to where the installer's add-ons would have put them.
    public var repairedFiles: [String] = []
    /// True when the install routine had to be looked for, because the installer's own
    /// window (an add-on) is what would have started it.
    public var foundInstallRoutineBySearch = false
}

/// Carries out the script of an NSIS installer against a prefix's C: drive, in place of the
/// installer's own 32-bit program.
///
/// What it does is what an installer run with `/S` (silently) does: the start-up function, then
/// every selected section, with files written under `drive_c`. Registry writes are collected
/// for `regedit`; shortcuts are collected for FineWine to turn into apps.
///
/// What it cannot do is run the installer's add-ons ("plugins"), which are 32-bit DLLs. A few
/// common ones are stood in for (7-Zip extraction, 64-bit arithmetic, "is this process
/// running"); calls to the rest are skipped and counted. Installers that put their real work
/// in an add-on of their own, usually a custom window that then calls back into the script,
/// are handled by two fallbacks:
/// - if the normal run installed nothing, the script functions handed to add-ons as
///   callbacks are tried, the one that unpacks the most files first;
/// - a program the script refers to (in a shortcut, or to start it) that is not where the
///   script says, but is somewhere below, is copied to where it should be.
public final class NSISScript {
    private struct Entry { var which: Int; var p: [Int] }
    private enum Step { case next, jump(Int), ret, error }

    private let archive: NSISArchive
    private let header: Data
    private let fs: WindowsFiles
    private let userName: String
    private let productName: String

    private var entries: [Entry] = []
    private var stringsOffset = 0
    private var stringsEnd = 0
    private var langTablesOffset = 0
    private var langTableCount = 0
    private var langTableSize = 0
    private var sections: [[Int]] = []      // name_ptr, install_types, flags, code, code_size, size_kb

    private var vars: [Int: String] = [:]
    private var stack: [String] = []
    private var flags = [Int](repeating: 0, count: 16)
    private var lastFlags = [Int](repeating: 0, count: 16)
    private var steps = 0
    private var quit = false
    private var registry: [String: String] = [:]
    private var registryLines: [(key: String, line: String)] = []
    private var openFiles: [Int: FileHandle] = [:]
    private var finds: [Int: [String]] = [:]
    private var nextHandle = 100
    private var written: [String] = []
    private var shortcuts: [NSISInstallReport.FoundProgram] = []
    private var report = NSISInstallReport()
    private var progress: ((String) -> Void)?
    private var lastProgress = Date.distantPast

    /// Enough for any real installer; a script sent in circles by a skipped add-on stops here.
    private static let stepLimit = 20_000_000

    // Opcodes of NSIS 3. Unicode builds add two more after the last one here.
    private enum Op {
        static let ret = 1, jump = 2, abort = 3, quit = 4, call = 5, setFileAttributes = 10,
                   createDir = 11, ifFileExists = 12, setFlag = 13, ifFlag = 14, getFlag = 15, rename = 16,
                   getFullPathName = 17, searchPath = 18, getTempFileName = 19, extractFile = 20,
                   deleteFile = 21, messageBox = 22, rmDir = 23, strLen = 24, assignVar = 25, strCmp = 26,
                   readEnv = 27, intCmp = 28, intOp = 29, intFmt = 30, pushPop = 31, findWindow = 32,
                   sendMessage = 33, isWindow = 34, getDlgItem = 35, shellExec = 40, execute = 41,
                   getFileTime = 42, getDLLVersion = 43, registerDLL = 44, createShortcut = 45,
                   copyFiles = 46, writeINI = 48, readINI = 49, deleteReg = 50, writeReg = 51, readReg = 52,
                   regEnum = 53, fileClose = 54, fileOpen = 55, filePuts = 56, fileGets = 57, fileSeek = 58,
                   findClose = 59, findNext = 60, findFirst = 61, writeUninstaller = 62, sectionSet = 63,
                   getOSInfo = 65, filePutsW = 68, fileGetsW = 69
    }

    private enum Var {
        static let cmdLine = 20, instDir = 21, outDir = 22, exeDir = 23, language = 24, temp = 25,
                   pluginsDir = 26, exePath = 27, exeFile = 28, hwndParent = 29
    }

    private enum Flag { static let allUsers = 1, error = 2, silent = 8, regView = 12 }

    // MARK: Set-up

    /// - Parameters:
    ///   - driveC: the prefix's `drive_c` folder.
    ///   - userName: the Windows user the prefix has (the folder under `drive_c/users`).
    ///   - installer: the installer file, for the script's `$EXEPATH`.
    ///   - productName: used for the install folder when the script names none.
    public init(archive: NSISArchive, driveC: URL, userName: String, installer: URL, productName: String) throws {
        self.archive = archive
        header = archive.header
        fs = WindowsFiles(driveC: driveC)
        self.userName = userName
        self.productName = productName
        guard header.count >= 300 else { throw NSISArchive.Unsupported(reason: "The installer's header is too short.") }

        func block(_ index: Int) -> (offset: Int, count: Int) {
            (header.leInt32(at: 4 + 8 * index), header.leInt32(at: 8 + 8 * index))
        }
        let sectionBlock = block(1), entryBlock = block(2), stringBlock = block(3), langBlock = block(4)
        guard entryBlock.offset > 0, entryBlock.count >= 0, stringBlock.offset >= entryBlock.offset + entryBlock.count * 28,
              langBlock.offset >= stringBlock.offset, langBlock.offset <= header.count else {
            throw NSISArchive.Unsupported(reason: "The installer's script is laid out in a way FineWine does not know.")
        }
        if sectionBlock.count > 0 {
            let size = (entryBlock.offset - sectionBlock.offset) / sectionBlock.count
            guard size == 24 + 1024 * 2 || size == 24 + 8192 * 2 else {
                throw NSISArchive.Unsupported(reason: "This installer was made with an ANSI build of NSIS, which FineWine cannot read yet.")
            }
            for i in 0..<sectionBlock.count {
                sections.append((0..<6).map { header.leInt32(at: sectionBlock.offset + i * size + 4 * $0) })
            }
        }
        for i in 0..<entryBlock.count {
            let at = entryBlock.offset + i * 28
            entries.append(Entry(which: header.leInt32(at: at), p: (1...6).map { header.leInt32(at: at + 4 * $0) }))
        }
        stringsOffset = stringBlock.offset
        stringsEnd = langBlock.offset
        langTablesOffset = langBlock.offset
        langTableCount = langBlock.count
        langTableSize = header.leInt32(at: 68 + 4 * 8)

        let unixPath = installer.path
        let windowsExe = "Z:" + unixPath.replacingOccurrences(of: "/", with: "\\")
        vars[Var.exePath] = windowsExe
        vars[Var.exeDir] = Self.parent(windowsExe)
        vars[Var.exeFile] = installer.lastPathComponent
        vars[Var.cmdLine] = "\"\(windowsExe)\" /S"
        vars[Var.temp] = "C:\\users\\\(userName)\\Temp"
        vars[Var.hwndParent] = "0"
        if langTableCount > 0, langTablesOffset + 2 <= header.count {
            vars[Var.language] = String(header.le16(at: langTablesOffset))
        }
        flags[Flag.silent] = 1
        let directory = header.leInt32(at: 68 + 4 * 53)
        if directory > 0 { vars[Var.instDir] = string(directory) }
    }

    // MARK: Running

    /// Installs. `progress` is told what is being written, a few times a second.
    public func install(progress: ((String) -> Void)? = nil) throws -> NSISInstallReport {
        self.progress = progress
        try? FileManager.default.createDirectory(at: fs.url(vars[Var.temp] ?? "") ?? fs.driveC, withIntermediateDirectories: true)

        let onInit = header.leInt32(at: 68 + 4 * 10)
        var initialised = true
        if onInit >= 0 { initialised = run(onInit) }
        if initialised, !quit {
            for index in sections.indices where sections[index][2] & 1 != 0 && sections[index][3] >= 0 {
                if !run(sections[index][3]) || quit { break }
            }
            let onSuccess = header.leInt32(at: 68 + 4 * 11)
            if onSuccess >= 0, !quit { _ = run(onSuccess) }
        }

        if installedFiles.isEmpty {
            // Nothing was installed: the installer's own window would have started the work.
            ensureInstallDirectory()
            for start in callbackFunctions().prefix(4) {
                quit = false
                steps = 0
                _ = run(start)
                if !installedFiles.isEmpty { report.foundInstallRoutineBySearch = true; break }
            }
        }
        for handle in openFiles.values { try? handle.close() }
        guard !installedFiles.isEmpty else {
            cleanUp()
            throw NSISArchive.Unsupported(reason: "FineWine read this installer's script but could not find the part that installs the program. The installer does its work in 32-bit add-ons, which cannot run here.")
        }

        report.installDirectory = installDirectory()
        report.filesWritten = installedFiles.count
        findPrograms()
        report.registryFile = registryLines.isEmpty ? "" : registryFileText()
        cleanUp()
        return report
    }

    /// Files written to somewhere that lasts: not the installer's temporary folders.
    private var installedFiles: [String] {
        let temporary = [vars[Var.pluginsDir], vars[Var.temp]].compactMap { $0?.lowercased() }.filter { !$0.isEmpty }
        return written.filter { path in !temporary.contains { path.lowercased().hasPrefix($0 + "\\") } }
    }

    private func ensureInstallDirectory() {
        if (vars[Var.instDir] ?? "").isEmpty {
            let safe = productName.components(separatedBy: CharacterSet(charactersIn: "\\/:*?\"<>|")).joined(separator: " ")
            vars[Var.instDir] = "C:\\Program Files\\" + (safe.isEmpty ? "Program" : safe)
        }
    }

    private func installDirectory() -> String {
        let files = installedFiles
        if let dir = vars[Var.instDir], !dir.isEmpty,
           files.contains(where: { $0.lowercased().hasPrefix(dir.lowercased() + "\\") }) { return dir }
        // otherwise the folder all the files share
        var common = files.first.map { Self.parent($0).components(separatedBy: "\\") } ?? []
        for file in files {
            let parts = Self.parent(file).components(separatedBy: "\\")
            var same = 0
            while same < min(common.count, parts.count), common[same].lowercased() == parts[same].lowercased() { same += 1 }
            common = Array(common.prefix(same))
        }
        return common.joined(separator: "\\")
    }

    private func cleanUp() {
        if let plugins = vars[Var.pluginsDir], !plugins.isEmpty, let url = fs.url(plugins),
           url.path.hasPrefix(fs.driveC.path + "/") {
            try? FileManager.default.removeItem(at: url)
        }
    }

    private func run(_ start: Int) -> Bool {
        var position = start
        while position >= 0, position < entries.count {
            steps += 1
            if steps > Self.stepLimit { quit = true; return false }
            switch step(entries[position]) {
            case .ret: return true
            case .error: return false
            case .next: position += 1
            case .jump(let raw):
                let target = address(raw)
                position = target == 0 ? position + 1 : target - 1
            }
        }
        return true
    }

    /// A jump or call target: an entry number plus one, or (negative) a variable holding it.
    private func address(_ raw: Int) -> Int {
        raw < 0 ? Self.int(vars[-(raw + 1)] ?? "") : raw
    }

    // MARK: Strings

    private func string(_ index: Int, depth: Int = 0) -> String {
        if index < 0 { return languageString(-(index + 1), depth: depth) }
        var position = stringsOffset + index * 2
        var units: [UInt16] = []
        var out = ""
        func flush() {
            if !units.isEmpty { out += String(decoding: units, as: UTF16.self); units.removeAll() }
        }
        while position + 1 < stringsEnd {
            let unit = header.le16(at: position)
            position += 2
            if unit == 0 { break }
            if unit > 4 { units.append(unit); continue }
            guard position + 1 < stringsEnd else { break }
            let parameter = header.le16(at: position)
            position += 2
            let packed = Int(parameter & 0x7F) | Int((parameter >> 8) & 0x7F) << 7
            flush()
            switch unit {
            case 1: if depth < 8 { out += languageString(packed, depth: depth + 1) }
            case 2: out += shellFolder(Int(parameter & 0xFF), Int(parameter >> 8))
            case 3: out += vars[packed] ?? ""
            default: units.append(parameter)
            }
        }
        flush()
        return out
    }

    private func languageString(_ index: Int, depth: Int) -> String {
        guard langTableCount > 0, langTableSize >= 10, index >= 0, 10 + 4 * index + 4 <= langTableSize else { return "" }
        var table = 0
        let wanted = Self.int(vars[Var.language] ?? "")
        for i in 0..<langTableCount where Int(header.le16(at: langTablesOffset + i * langTableSize)) == wanted { table = i; break }
        let at = langTablesOffset + table * langTableSize + 10 + 4 * index
        guard at + 4 <= header.count else { return "" }
        let pointer = header.leInt32(at: at)
        return pointer > 0 ? string(pointer, depth: depth + 1) : ""
    }

    /// A Windows folder by number, as the script names `$PROGRAMFILES`, `$DESKTOP` and so on.
    private func shellFolder(_ first: Int, _ second: Int) -> String {
        if first & 0x80 != 0 {
            // named by a registry value: the Program Files folders
            let name = string(second).lowercased()
            let base = first & 0x40 != 0 ? "C:\\Program Files" : "C:\\Program Files (x86)"
            return name.contains("common") ? base + "\\Common Files" : base
        }
        let id = flags[Flag.allUsers] != 0 ? second : first
        let user = "C:\\users\\\(userName)"
        switch id {
        case 0x00, 0x10: return user + "\\Desktop"
        case 0x19: return "C:\\users\\Public\\Desktop"
        case 0x02, 0x0B: return user + "\\AppData\\Roaming\\Microsoft\\Windows\\Start Menu" + (id == 0x02 ? "\\Programs" : "")
        case 0x17, 0x16: return "C:\\ProgramData\\Microsoft\\Windows\\Start Menu" + (id == 0x17 ? "\\Programs" : "")
        case 0x07: return user + "\\AppData\\Roaming\\Microsoft\\Windows\\Start Menu\\Programs\\Startup"
        case 0x18: return "C:\\ProgramData\\Microsoft\\Windows\\Start Menu\\Programs\\Startup"
        case 0x05: return user + "\\Documents"
        case 0x1A: return user + "\\AppData\\Roaming"
        case 0x1C: return user + "\\AppData\\Local"
        case 0x23: return "C:\\ProgramData"
        case 0x24: return "C:\\windows"
        case 0x25: return "C:\\windows\\system32"
        case 0x26: return "C:\\Program Files (x86)"
        case 0x2B: return "C:\\Program Files (x86)\\Common Files"
        case 0x14: return "C:\\windows\\Fonts"
        case 0x28: return user
        case 0x0D: return user + "\\Music"
        case 0x0E: return user + "\\Videos"
        case 0x27: return user + "\\Pictures"
        default: return user + "\\AppData\\Roaming"
        }
    }

    /// NSIS's reading of a number: decimal, 0x hexadecimal or 0 octal, a sign, and whatever
    /// follows the digits ignored. Arithmetic is 32-bit.
    static func int(_ text: String) -> Int {
        var scalars = Substring(text.trimmingCharacters(in: .whitespaces)).unicodeScalars[...]
        var negative = false
        if let first = scalars.first, first == "-" || first == "+" { negative = first == "-"; scalars = scalars.dropFirst() }
        var value: Int64 = 0
        var base: Int64 = 10
        if scalars.first == "0" {
            scalars = scalars.dropFirst()
            if let next = scalars.first, next == "x" || next == "X" { base = 16; scalars = scalars.dropFirst() } else { base = 8 }
        }
        for scalar in scalars {
            guard let digit = Character(scalar).hexDigitValue, Int64(digit) < base else { break }
            value = (value &* base &+ Int64(digit)) & 0xFFFF_FFFF
        }
        let result = Int32(truncatingIfNeeded: negative ? -value : value)
        return Int(result)
    }

    private static func parent(_ path: String) -> String {
        guard let slash = path.lastIndex(of: "\\") else { return "" }
        return String(path[..<slash])
    }

    private static func fileName(_ path: String) -> String {
        path.split(separator: "\\").last.map(String.init) ?? path
    }

    private func isAbsolute(_ path: String) -> Bool {
        let chars = Array(path.prefix(3))
        return (chars.count >= 2 && chars[1] == ":") || path.hasPrefix("\\\\")
    }

    private func setError() { flags[Flag.error] += 1 }

    private func note(_ text: String) {
        guard let progress, Date().timeIntervalSince(lastProgress) > 0.25 else { return }
        lastProgress = Date()
        progress(text)
    }

    // MARK: One instruction

    private func step(_ entry: Entry) -> Step {
        let p = entry.p
        func s(_ i: Int) -> String { string(p[i]) }
        func n(_ i: Int) -> Int { Self.int(string(p[i])) }
        func set(_ variable: Int, _ value: String) { if variable >= 0 { vars[variable] = value } }
        let manager = FileManager.default

        switch entry.which {
        case Op.ret: return .ret
        case Op.jump: return .jump(p[0])
        case Op.abort: return .error
        case Op.quit: quit = true; return .error
        case Op.call:
            let target = address(p[0]) - 1
            if target < 0 || !run(target) { return .error }
            if quit { return .error }

        case Op.createDir:
            let path = s(0)
            if p[1] != 0 { vars[Var.outDir] = path }
            if let url = fs.url(path) {
                do { try manager.createDirectory(at: url, withIntermediateDirectories: true) } catch { setError() }
            } else { setError() }

        case Op.ifFileExists:
            return .jump(fs.exists(s(0)) ? p[1] : p[2])

        case Op.setFlag:
            guard p[0] >= 0, p[0] < flags.count else { break }
            if p[2] == 0 { lastFlags[p[0]] = flags[p[0]]; flags[p[0]] = n(1) } else { flags[p[0]] = lastFlags[p[0]] }

        case Op.ifFlag:
            guard p[2] >= 0, p[2] < flags.count else { break }
            let target = flags[p[2]] != 0 ? p[0] : p[1]
            flags[p[2]] &= p[3]
            return .jump(target)

        case Op.getFlag:
            set(p[0], p[1] >= 0 && p[1] < flags.count ? String(flags[p[1]]) : "0")

        case Op.rename:
            if let from = fs.url(s(0)), let to = fs.url(s(1)), manager.fileExists(atPath: from.path),
               !manager.fileExists(atPath: to.path) {
                do {
                    try manager.createDirectory(at: to.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try manager.moveItem(at: from, to: to)
                    renameWritten(from: s(0), to: s(1))
                } catch { setError() }
            } else { setError() }

        case Op.getFullPathName:
            let path = s(0)
            set(p[1], isAbsolute(path) ? path : (vars[Var.outDir] ?? "") + "\\" + path)

        case Op.searchPath:
            set(p[0], ""); setError()

        case Op.getTempFileName:
            let directory = s(1).isEmpty ? (vars[Var.temp] ?? "") : s(1)
            let name = directory + "\\ns" + String(UUID().uuidString.prefix(5)).lowercased() + ".tmp"
            if let url = fs.url(name) {
                try? manager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                manager.createFile(atPath: url.path, contents: nil)
                set(p[0], name)
            } else { set(p[0], ""); setError() }

        case Op.extractFile:
            let name = s(1)
            let path = isAbsolute(name) ? name : (vars[Var.outDir] ?? "") + "\\" + name
            guard let url = fs.url(path) else { setError(); break }
            let mode = p[0] & 7
            if mode == 1, manager.fileExists(atPath: url.path) { break }   // SetOverwrite off
            do {
                try manager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                if manager.fileExists(atPath: url.path) { try manager.removeItem(at: url) }
                try archive.extract(dataOffset: p[2], to: url)
                written.append(path)
                note(Self.fileName(path))
            } catch { setError() }

        case Op.deleteFile:
            for url in fs.matches(s(0)) { try? manager.removeItem(at: url) }

        case Op.messageBox:
            var answer = p[0] >> 21
            if answer == 0 {
                switch p[0] & 0xF {       // the button a user would most likely press
                case 2: answer = 5        // Abort/Retry/Ignore: Ignore
                case 3, 4: answer = 6     // Yes/No(/Cancel): Yes
                case 5: answer = 2        // Retry/Cancel: Cancel
                default: answer = 1       // OK
                }
            }
            if answer == p[2] { return .jump(p[3]) }
            if answer == p[4] { return .jump(p[5]) }

        case Op.rmDir:
            if let url = fs.url(s(0)), manager.fileExists(atPath: url.path) {
                if p[1] & 2 != 0 { try? manager.removeItem(at: url) }
                else if (try? manager.contentsOfDirectory(atPath: url.path))?.isEmpty == true { try? manager.removeItem(at: url) }
                else { setError() }
            }

        case Op.strLen:
            set(p[0], String(s(1).utf16.count))

        case Op.assignVar:
            let source = Array(s(1).utf16)
            var length = p[2] == 0 ? Int.max : n(2)
            var start = n(3)
            if start < 0 { start = source.count + start }
            guard start >= 0 else { set(p[0], ""); break }
            var result = Array(source[min(start, source.count)...])
            if length != Int.max {
                if length < 0 { length = max(0, result.count + length) }
                result = Array(result.prefix(length))
            }
            set(p[0], String(decoding: result, as: UTF16.self))

        case Op.strCmp:
            let a = s(0), b = s(1)
            let equal = p[4] != 0 ? a == b : a.caseInsensitiveCompare(b) == .orderedSame
            return .jump(equal ? p[2] : p[3])

        case Op.readEnv:
            if p[2] != 0 { set(p[0], ""); setError() } else { set(p[0], s(1)) }

        case Op.intCmp:
            let a = n(0), b = n(1)
            if p[5] != 0 {
                let ua = UInt32(truncatingIfNeeded: a), ub = UInt32(truncatingIfNeeded: b)
                return .jump(ua < ub ? p[3] : ua > ub ? p[4] : p[2])
            }
            return .jump(a < b ? p[3] : a > b ? p[4] : p[2])

        case Op.intOp:
            let a = Int32(truncatingIfNeeded: n(1)), b = Int32(truncatingIfNeeded: n(2))
            var value: Int32 = 0
            switch p[3] {
            case 0: value = a &+ b
            case 1: value = a &- b
            case 2: value = a &* b
            case 3: if b == 0 { setError() } else { value = a / b }
            case 4: value = a | b
            case 5: value = a & b
            case 6: value = a ^ b
            case 7: value = a == 0 ? 1 : 0
            case 8: value = (a != 0 || b != 0) ? 1 : 0
            case 9: value = (a != 0 && b != 0) ? 1 : 0
            case 10: if b == 0 { setError() } else { value = a % b }
            case 11: value = a << (b & 31)
            case 12: value = a >> (b & 31)
            case 13: value = Int32(bitPattern: UInt32(bitPattern: a) >> UInt32(b & 31))
            default: break
            }
            set(p[0], String(value))

        case Op.intFmt:
            set(p[0], Self.format(s(1), n(2)))

        case Op.pushPop:
            if p[2] != 0 {
                let depth = p[2]
                if stack.count > depth { stack.swapAt(stack.count - 1, stack.count - 1 - depth) } else { setError(); return .error }
            } else if p[1] != 0 {
                if let top = stack.popLast() { set(p[0], top) } else { setError() }
            } else {
                stack.append(s(0))
            }

        case Op.findWindow:
            set(p[0], "0")
            return .jump(p[5])
        case Op.sendMessage, Op.getDlgItem:
            set(p[0], "0")
        case Op.isWindow:
            return .jump(p[2])

        case Op.shellExec:
            report.skippedCommands.append((s(1) + " " + s(2)).trimmingCharacters(in: .whitespaces))
        case Op.execute:
            report.skippedCommands.append(s(0))
            if p[2] != 0 { set(p[1], "0") }

        case Op.getFileTime, Op.getDLLVersion:
            set(p[0], ""); set(p[1], ""); setError()

        case Op.registerDLL:
            if p[3] != 0 { callPlugin(dll: s(0), function: s(1)) }

        case Op.createShortcut:
            shortcuts.append(.init(name: String(Self.fileName(s(0)).dropLast(4)), windowsPath: s(1), arguments: s(2)))

        case Op.copyFiles:
            copyFiles(from: s(0), to: s(1))

        case Op.writeINI:
            if !INIFile.write(section: s(0), key: p[1] == 0 ? nil : s(1), value: p[2] == 0 ? nil : s(2), at: fs.url(s(3))) { setError() }
        case Op.readINI:
            if let value = INIFile.read(section: s(1), key: s(2), at: fs.url(s(3))) { set(p[0], value) } else { set(p[0], ""); setError() }

        case Op.deleteReg:
            break
        case Op.writeReg:
            writeRegistry(root: p[0], key: s(1), name: s(2), data: p[4] == 3 ? "" : s(3), type: p[4], stringType: p[5])
        case Op.readReg:
            if let value = registry[registryPath(root: p[1], key: s(2)) + "\\" + s(3).lowercased()] { set(p[0], value) }
            else { set(p[0], ""); setError() }
        case Op.regEnum:
            set(p[0], ""); setError()

        case Op.fileOpen:
            guard let url = fs.url(s(3)) else { set(p[0], ""); setError(); break }
            let wantsWrite = UInt32(truncatingIfNeeded: p[1]) & 0x4000_0000 != 0
            if wantsWrite {
                try? manager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                // CREATE_ALWAYS (2) starts the file afresh; OPEN_ALWAYS (4) keeps it
                if p[2] == 2 || !manager.fileExists(atPath: url.path) { manager.createFile(atPath: url.path, contents: nil) }
            }
            if let handle = wantsWrite ? try? FileHandle(forUpdating: url) : try? FileHandle(forReadingFrom: url) {
                nextHandle += 1
                openFiles[nextHandle] = handle
                set(p[0], String(nextHandle))
                if wantsWrite { written.append(s(3)) }
            } else { set(p[0], ""); setError() }
        case Op.fileClose:
            if let handle = openFiles.removeValue(forKey: Self.int(vars[p[0]] ?? "")) { try? handle.close() }
        case Op.filePuts, Op.filePutsW:
            guard let handle = openFiles[Self.int(vars[p[0]] ?? "")] else { setError(); break }
            let data: Data
            if p[2] != 0 { data = Data([UInt8(truncatingIfNeeded: n(1))]) }
            else if entry.which == Op.filePutsW { data = s(1).data(using: .utf16LittleEndian) ?? Data() }
            else { data = s(1).data(using: .utf8) ?? Data() }
            do { try handle.write(contentsOf: data) } catch { setError() }
        case Op.fileGets, Op.fileGetsW:
            guard let handle = openFiles[Self.int(vars[p[0]] ?? "")] else { set(p[1], ""); setError(); break }
            var bytes = Data()
            let wide = entry.which == Op.fileGetsW
            let limit = max(1, min(n(2), 8192))
            while bytes.count < limit * (wide ? 2 : 1) {
                guard let chunk = try? handle.read(upToCount: wide ? 2 : 1), !chunk.isEmpty else { break }
                bytes.append(chunk)
                if p[3] != 0 { break }   // one byte, as a number
                if chunk.first == 0x0A { break }
            }
            if bytes.isEmpty { set(p[1], ""); setError() }
            else if p[3] != 0 { set(p[1], String(bytes[bytes.startIndex])) }
            else { set(p[1], wide ? String(decoding: bytes.withUnsafeBytes { Array($0.bindMemory(to: UInt16.self)) }, as: UTF16.self)
                                  : String(decoding: bytes, as: UTF8.self)) }
        case Op.fileSeek:
            guard let handle = openFiles[Self.int(vars[p[0]] ?? "")] else { setError(); break }
            let offset = n(2)
            let size = Int((try? handle.seekToEnd()) ?? 0)
            let current = Int((try? handle.offset()) ?? 0)
            let target = p[3] == 0 ? offset : p[3] == 2 ? size + offset : current + offset
            try? handle.seek(toOffset: UInt64(max(0, target)))
            if p[1] >= 0 { set(p[1], String(max(0, target))) }

        case Op.findFirst:
            var names = fs.matches(s(2)).map(\.lastPathComponent)
            if names.isEmpty { set(p[0], ""); set(p[1], ""); setError(); break }
            set(p[0], names.removeFirst())
            nextHandle += 1
            finds[nextHandle] = names
            set(p[1], String(nextHandle))
        case Op.findNext:
            let id = Self.int(vars[p[1]] ?? "")
            if var names = finds[id], !names.isEmpty { set(p[0], names.removeFirst()); finds[id] = names }
            else { set(p[0], ""); setError() }
        case Op.findClose:
            finds[Self.int(vars[p[0]] ?? "")] = nil

        case Op.sectionSet:
            let index = n(0)
            guard sections.indices.contains(index) else { setError(); break }
            if p[2] >= 0 { set(p[1], p[2] < 6 && p[2] > 0 ? String(sections[index][p[2]]) : "") }
            else if -p[2] - 1 < 6, -p[2] - 1 > 0 { sections[index][-p[2] - 1] = n(1) }

        case Op.getOSInfo:
            set(p[0], ""); setError()

        default:
            break     // windows, fonts, sleeps, the uninstaller: nothing to do without a window
        }
        return .next
    }

    private func renameWritten(from: String, to: String) {
        let prefix = from.lowercased()
        written = written.map { path in
            let lower = path.lowercased()
            if lower == prefix { return to }
            if lower.hasPrefix(prefix + "\\") { return to + path.dropFirst(from.count) }
            return path
        }
    }

    /// `wsprintf` with one number, which is all the script's IntFmt can ask for.
    static func format(_ format: String, _ value: Int) -> String {
        var out = ""
        var rest = Substring(format)
        var used = false
        while let percent = rest.firstIndex(of: "%") {
            out += rest[..<percent]
            var index = rest.index(after: percent)
            var spec = "%"
            while index < rest.endIndex, "-+0 #123456789.lh".contains(rest[index]) {
                if !"lh".contains(rest[index]) { spec.append(rest[index]) }
                index = rest.index(after: index)
            }
            guard index < rest.endIndex else { out += rest[percent...]; rest = ""; break }
            let kind = rest[index]
            rest = rest[rest.index(after: index)...]
            if kind == "%" { out += "%"; continue }
            if used { continue }
            used = true
            switch kind {
            case "d", "i": out += String(format: spec + "d", Int32(truncatingIfNeeded: value))
            case "u": out += String(format: spec + "u", UInt32(truncatingIfNeeded: value))
            case "x": out += String(format: spec + "x", UInt32(truncatingIfNeeded: value))
            case "X": out += String(format: spec + "X", UInt32(truncatingIfNeeded: value))
            case "o": out += String(format: spec + "o", UInt32(truncatingIfNeeded: value))
            case "c": if let scalar = Unicode.Scalar(UInt32(truncatingIfNeeded: value)) { out.unicodeScalars.append(scalar) }
            case "s", "S": out += String(value)
            default: break
            }
        }
        return out + rest
    }

    private func copyFiles(from source: String, to destination: String) {
        let manager = FileManager.default
        let sources = fs.matches(source)
        guard !sources.isEmpty, let target = fs.url(destination) else { setError(); return }
        var isDirectory: ObjCBool = false
        let targetIsFolder = (manager.fileExists(atPath: target.path, isDirectory: &isDirectory) && isDirectory.boolValue)
            || sources.count > 1 || source.contains("*") || source.contains("?")
        for item in sources {
            let to = targetIsFolder ? target.appendingPathComponent(item.lastPathComponent) : target
            do {
                try manager.createDirectory(at: to.deletingLastPathComponent(), withIntermediateDirectories: true)
                if manager.fileExists(atPath: to.path) { try manager.removeItem(at: to) }
                try manager.copyItem(at: item, to: to)
                written.append(targetIsFolder ? destination + "\\" + item.lastPathComponent : destination)
            } catch { setError() }
        }
    }

    // MARK: Registry

    private func registryPath(root: Int, key: String) -> String {
        let name: String
        switch UInt32(truncatingIfNeeded: root) {
        case 0x8000_0000: name = "HKEY_CLASSES_ROOT"
        case 0x8000_0001: name = "HKEY_CURRENT_USER"
        case 0x8000_0003: name = "HKEY_USERS"
        case 0x8000_0002: name = "HKEY_LOCAL_MACHINE"
        default: name = flags[Flag.allUsers] != 0 ? "HKEY_LOCAL_MACHINE" : "HKEY_CURRENT_USER"   // "shell context"
        }
        var path = key.trimmingCharacters(in: CharacterSet(charactersIn: "\\"))
        // A 32-bit installer's view of the machine's Software key, unless it asked for the 64-bit one.
        if name == "HKEY_LOCAL_MACHINE", flags[Flag.regView] & 0x100 == 0,
           path.lowercased().hasPrefix("software\\"), !path.lowercased().hasPrefix("software\\wow6432node\\"),
           !path.lowercased().hasPrefix("software\\microsoft\\windows\\currentversion\\uninstall") {
            path = "Software\\WOW6432Node\\" + path.dropFirst("software\\".count)
        }
        return (name + "\\" + path).lowercased()
    }

    private func writeRegistry(root: Int, key: String, name: String, data: String, type: Int, stringType: Int) {
        guard type == 1 || type == 4 else { return }    // binary values are not carried over
        let path = registryPath(root: root, key: key)
        registry[path + "\\" + name.lowercased()] = data
        func quoted(_ text: String) -> String {
            "\"" + text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
        }
        let value = type == 4 ? String(format: "dword:%08x", UInt32(truncatingIfNeeded: Self.int(data))) : quoted(data)
        registryLines.append((path, (name.isEmpty ? "@" : quoted(name)) + "=" + value))
    }

    private func registryFileText() -> String {
        var text = "Windows Registry Editor Version 5.00\r\n"
        var current = ""
        for (key, line) in registryLines {
            if key != current {
                // the root's name goes back to capitals; the rest of a key is not case-sensitive
                let parts = key.split(separator: "\\", maxSplits: 1)
                text += "\r\n[" + parts[0].uppercased() + (parts.count > 1 ? "\\" + parts[1] : "") + "]\r\n"
                current = key
            }
            text += line + "\r\n"
        }
        return text
    }

    // MARK: Add-ons

    private func callPlugin(dll: String, function: String) {
        let library = Self.fileName(dll).lowercased().replacingOccurrences(of: ".dll", with: "")
        let call = function.lowercased()
        switch (library, call) {
        case ("system", "int64op"):
            // a, operator, b pushed in that order
            guard stack.count >= 2 else { break }
            let op = stack.count >= 3 ? stack[stack.count - 2] : ""
            if stack.count >= 3, ["+", "-", "*", "/", "%", "<", ">", "=", "|", "&", "^", "<<", ">>"].contains(op) {
                let a = Int64(stack[stack.count - 1]) ?? 0, b = Int64(stack[stack.count - 3]) ?? 0
                stack.removeLast(3)
                var value: Int64 = 0
                switch op {
                case "+": value = a &+ b
                case "-": value = a &- b
                case "*": value = a &* b
                case "/": value = b == 0 ? 0 : a / b
                case "%": value = b == 0 ? 0 : a % b
                case "<": value = a < b ? 1 : 0
                case ">": value = a > b ? 1 : 0
                case "=": value = a == b ? 1 : 0
                case "|": value = a | b
                case "&": value = a & b
                case "^": value = a ^ b
                case "<<": value = a << (b & 63)
                default: value = a >> (b & 63)
                }
                stack.append(String(value))
                return
            }
        case ("nsis7z", _) where call.hasPrefix("extract"):
            if let archivePath = stack.popLast(), let source = fs.url(archivePath), let target = fs.url(vars[Var.outDir] ?? "") {
                if call != "extract", !stack.isEmpty { stack.removeLast() }   // the progress text or callback
                extract7z(source, into: target)
                return
            }
        case ("nsexec", _):
            if let command = stack.popLast() { report.skippedCommands.append(command) }
            if call == "exectostack" { stack.append("") }
            stack.append("0")
            return
        case ("userinfo", "getaccounttype"): stack.append("Admin"); return
        case ("userinfo", "getname"): stack.append(userName); return
        case ("nsprocess", "_findprocess"), ("nsprocess", "findprocess"):
            _ = stack.popLast()
            stack.append("603")     // not running
            return
        default: break
        }
        report.skippedPluginCalls[Self.fileName(dll) + "::" + function, default: 0] += 1
    }

    /// Unpacks a 7-Zip archive the installer carries (electron-builder's `app-64.7z`) with the
    /// Mac's own archive tool.
    private func extract7z(_ archive: URL, into directory: URL) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let before = Set((FileManager.default.enumerator(atPath: directory.path)?.allObjects as? [String]) ?? [])
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/bsdtar")
        process.arguments = ["-x", "-f", archive.path, "-C", directory.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        note("Unpacking " + archive.lastPathComponent)
        guard (try? process.run()) != nil else { setError(); return }
        process.waitUntilExit()
        if process.terminationStatus != 0 { setError() }
        let base = vars[Var.outDir] ?? ""
        for case let path as String in FileManager.default.enumerator(atPath: directory.path) ?? .init() where !before.contains(path) {
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: directory.appendingPathComponent(path).path, isDirectory: &isDirectory),
               !isDirectory.boolValue {
                written.append(base + "\\" + path.replacingOccurrences(of: "/", with: "\\"))
            }
        }
    }

    // MARK: Finding the install routine

    /// Script functions whose address the script hands to something else (an add-on, as a
    /// callback), the one that unpacks the most files first. A function's address is stored as
    /// its entry number plus one, in text.
    private func callbackFunctions() -> [Int] {
        var starts = Set<Int>()
        for entry in entries where entry.which == Op.assignVar && entry.p[2] == 0 && entry.p[3] == 0 {
            guard let text = literal(entry.p[1]), !text.isEmpty, text.allSatisfy(\.isNumber), let value = Int(text),
                  value >= 2, value <= entries.count, entries[value - 2].which == Op.ret else { continue }
            starts.insert(value - 1)
        }
        let scored = starts.map { ($0, extractions(reachableFrom: $0)) }.filter { $0.1 > 0 }
        return scored.sorted { $0.1 != $1.1 ? $0.1 > $1.1 : $0.0 < $1.0 }.map(\.0)
    }

    /// A string with no variables in it, or nil.
    private func literal(_ index: Int) -> String? {
        guard index >= 0 else { return nil }
        var position = stringsOffset + index * 2
        var units: [UInt16] = []
        while position + 1 < stringsEnd {
            let unit = header.le16(at: position)
            position += 2
            if unit == 0 { break }
            if unit <= 4 { return nil }
            units.append(unit)
        }
        return String(decoding: units, as: UTF16.self)
    }

    private func extractions(reachableFrom start: Int) -> Int {
        var seen = Set<Int>()
        var pending = [start]
        var count = 0
        func target(_ raw: Int) -> Int? { raw > 0 && raw <= entries.count ? raw - 1 : nil }
        while let position = pending.popLast() {
            guard position >= 0, position < entries.count, seen.insert(position).inserted else { continue }
            let entry = entries[position]
            var jumps: [Int] = []
            switch entry.which {
            case Op.ret, Op.abort, Op.quit: continue
            case Op.jump:
                if let t = target(entry.p[0]) { pending.append(t); continue }
            case Op.call: jumps = [entry.p[0]]
            case Op.strCmp: jumps = [entry.p[2], entry.p[3]]
            case Op.intCmp: jumps = [entry.p[2], entry.p[3], entry.p[4]]
            case Op.ifFileExists: jumps = [entry.p[1], entry.p[2]]
            case Op.ifFlag: jumps = [entry.p[0], entry.p[1]]
            case Op.messageBox: jumps = [entry.p[3], entry.p[5]]
            case Op.isWindow: jumps = [entry.p[1], entry.p[2]]
            case Op.extractFile: count += 1
            default: break
            }
            pending.append(position + 1)
            pending.append(contentsOf: jumps.compactMap(target))
        }
        return count
    }

    // MARK: Finding the programs

    private func findPrograms() {
        let root = report.installDirectory
        guard !root.isEmpty else { return }
        let prefix = root.lowercased() + "\\"
        var found: [NSISInstallReport.FoundProgram] = shortcuts
        // Programs the script names anywhere: pushed to an add-on, started, opened.
        for entry in entries {
            switch entry.which {
            case Op.pushPop where entry.p[1] == 0 && entry.p[2] == 0:
                found.append(.init(name: nil, windowsPath: string(entry.p[0]), arguments: ""))
            case Op.shellExec:
                found.append(.init(name: nil, windowsPath: string(entry.p[1]), arguments: ""))
            case Op.execute:
                let command = string(entry.p[0])
                let path = command.hasPrefix("\"") ? String(command.dropFirst().prefix { $0 != "\"" }) : command
                found.append(.init(name: nil, windowsPath: path, arguments: ""))
            default: break
            }
        }
        var seen = Set<String>()
        for candidate in found {
            let path = candidate.windowsPath
            let lower = path.lowercased()
            guard lower.hasSuffix(".exe"), lower.hasPrefix(prefix), !lower.contains("*"),
                  !Self.fileName(lower).contains("unins"), seen.insert(lower).inserted,
                  let url = fs.url(path) else { continue }
            if !FileManager.default.fileExists(atPath: url.path), !repair(path, at: url) { continue }
            guard Self.is64BitProgram(url) else { continue }
            report.programs.append(candidate)
        }
        guard report.programs.isEmpty, let folder = fs.url(root) else { return }
        // The script names none: the programs at the top of the install folder, then.
        let helpers = ["unins", "crash", "helper", "update", "7z", "webengine", "setup", "vc_redist", "vcredist", "dxsetup", "report"]
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).sorted()
        for name in names where name.lowercased().hasSuffix(".exe") && !helpers.contains(where: name.lowercased().contains) {
            if Self.is64BitProgram(folder.appendingPathComponent(name)) {
                report.programs.append(.init(name: nil, windowsPath: root + "\\" + name, arguments: ""))
            }
            if report.programs.count == 3 { break }
        }
    }

    /// A program the script expects at `path` that an add-on would have put there: if exactly
    /// one file of that name is somewhere below the install folder, it is copied.
    private func repair(_ path: String, at url: URL) -> Bool {
        guard let root = fs.url(report.installDirectory) else { return false }
        let wanted = url.lastPathComponent.lowercased()
        var matches: [URL] = []
        let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)
        while let item = enumerator?.nextObject() as? URL {
            if (enumerator?.level ?? 0) > 3 { enumerator?.skipDescendants(); continue }
            if item.lastPathComponent.lowercased() == wanted { matches.append(item) }
        }
        guard matches.count == 1 else { return false }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: matches[0], to: url)
            report.repairedFiles.append(path)
            return true
        } catch { return false }
    }

    static func is64BitProgram(_ url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        guard let dos = try? handle.read(upToCount: 64), dos.count == 64, dos[0] == 0x4D, dos[1] == 0x5A else { return false }
        try? handle.seek(toOffset: UInt64(dos.le32(at: 0x3C)))
        guard let pe = try? handle.read(upToCount: 6), pe.count == 6, pe.le32(at: 0) == 0x4550 else { return false }
        let machine = pe.le16(at: 4)
        return machine == 0x8664 || machine == 0xAA64
    }
}

/// Windows paths on a prefix's drives: `C:` is the prefix's `drive_c`, `Z:` the Mac's root.
/// Names are matched without regard to case, as Windows does.
struct WindowsFiles {
    let driveC: URL

    func url(_ windowsPath: String) -> URL? {
        let path = windowsPath.replacingOccurrences(of: "/", with: "\\")
        let chars = Array(path.prefix(2))
        guard chars.count == 2, chars[1] == ":" else { return nil }
        var url: URL
        switch chars[0].lowercased() {
        case "c": url = driveC
        case "z": url = URL(fileURLWithPath: "/")
        default: return nil
        }
        for part in path.dropFirst(2).split(separator: "\\") where part != "." {
            if part == ".." { url.deleteLastPathComponent(); continue }
            let exact = url.appendingPathComponent(String(part))
            if FileManager.default.fileExists(atPath: exact.path) { url = exact; continue }
            let existing = (try? FileManager.default.contentsOfDirectory(atPath: url.path))?
                .first { $0.caseInsensitiveCompare(String(part)) == .orderedSame }
            url = url.appendingPathComponent(existing ?? String(part))
        }
        return url
    }

    func exists(_ windowsPath: String) -> Bool {
        if windowsPath.contains("*") || windowsPath.contains("?") { return !matches(windowsPath).isEmpty }
        guard let url = url(windowsPath) else { return false }
        return FileManager.default.fileExists(atPath: url.path)
    }

    /// The files a path names: one, or several when its last part has `*` or `?` in it.
    func matches(_ windowsPath: String) -> [URL] {
        let path = windowsPath.replacingOccurrences(of: "/", with: "\\")
        guard let slash = path.lastIndex(of: "\\") else { return [] }
        let pattern = String(path[path.index(after: slash)...])
        guard pattern.contains("*") || pattern.contains("?") else {
            guard let url = url(path), FileManager.default.fileExists(atPath: url.path) else { return [] }
            return [url]
        }
        guard let folder = url(String(path[..<slash])) else { return [] }
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        // "*.*" means everything on Windows, names without a dot included
        let glob = pattern == "*.*" ? "*" : pattern
        return names.sorted().filter { fnmatch(glob.lowercased(), $0.lowercased(), 0) == 0 }
            .map { folder.appendingPathComponent($0) }
    }
}

/// Just enough of Windows' .ini files for an installer's WriteINIStr and ReadINIStr.
enum INIFile {
    private static func load(_ url: URL) -> (lines: [String], wide: Bool) {
        guard let data = try? Data(contentsOf: url) else { return ([], false) }
        let wide = data.starts(with: [0xFF, 0xFE])
        let text = wide ? String(data: data.dropFirst(2), encoding: .utf16LittleEndian)
                        : String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1)
        var lines = (text ?? "").replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        if lines.last == "" { lines.removeLast() }
        return (lines, wide)
    }

    private static func range(of section: String, in lines: [String]) -> Range<Int>? {
        guard let start = lines.firstIndex(where: {
            $0.trimmingCharacters(in: .whitespaces).caseInsensitiveCompare("[\(section)]") == .orderedSame
        }) else { return nil }
        let end = lines[(start + 1)...].firstIndex { $0.trimmingCharacters(in: .whitespaces).hasPrefix("[") } ?? lines.count
        return (start + 1)..<end
    }

    private static func key(of line: String) -> String? {
        guard let equals = line.firstIndex(of: "=") else { return nil }
        return line[..<equals].trimmingCharacters(in: .whitespaces)
    }

    static func read(section: String, key: String, at url: URL?) -> String? {
        guard let url else { return nil }
        let lines = load(url).lines
        guard let range = range(of: section, in: lines),
              let line = lines[range].first(where: { self.key(of: $0)?.caseInsensitiveCompare(key) == .orderedSame }),
              let equals = line.firstIndex(of: "=") else { return nil }
        return line[line.index(after: equals)...].trimmingCharacters(in: .whitespaces)
    }

    /// Sets a value; a nil value removes the key, a nil key removes the section.
    static func write(section: String, key: String?, value: String?, at url: URL?) -> Bool {
        guard let url else { return false }
        var (lines, wide) = load(url)
        if let range = range(of: section, in: lines) {
            if let key {
                let index = lines[range].firstIndex { self.key(of: $0)?.caseInsensitiveCompare(key) == .orderedSame }
                if let value {
                    if let index { lines[index] = "\(key)=\(value)" } else { lines.insert("\(key)=\(value)", at: range.upperBound) }
                } else if let index { lines.remove(at: index) }
            } else {
                lines.removeSubrange((range.lowerBound - 1)..<range.upperBound)
            }
        } else if let key, let value {
            lines.append("[\(section)]")
            lines.append("\(key)=\(value)")
        }
        let text = lines.joined(separator: "\r\n") + "\r\n"
        let data = wide ? Data([0xFF, 0xFE]) + (text.data(using: .utf16LittleEndian) ?? Data()) : Data(text.utf8)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        return (try? data.write(to: url)) != nil
    }
}
