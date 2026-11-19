import XCTest
import Compression
@testable import FineWineCore

/// Builds small NSIS installers in memory (the real layout: a first header, then a header block
/// with the script and strings, then the files) and has FineWine carry them out.
final class NSISTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("fw-nsis-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("drive_c/users/tester"), withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    // MARK: A tiny installer writer

    private struct Builder {
        var strings: [UInt16] = [0]          // index 0 is the empty string
        var entries: [[Int32]] = []
        var data = Data()

        /// Adds a string; `$INSTDIR` and friends are written the way NSIS encodes variables.
        mutating func string(_ text: String) -> Int32 {
            let index = Int32(strings.count)
            var rest = Substring(text)
            let variables: [(String, UInt16)] = [("$INSTDIR", 21), ("$OUTDIR", 22), ("$PLUGINSDIR", 26), ("$R0", 10), ("$0", 0)]
            outer: while !rest.isEmpty {
                for (name, number) in variables where rest.hasPrefix(name) {
                    strings.append(3)
                    strings.append(0x8080 | number)     // 7 bits per byte, top bits set
                    rest = rest.dropFirst(name.count)
                    continue outer
                }
                strings.append(contentsOf: String(rest.removeFirst()).utf16)
            }
            strings.append(0)
            return index
        }

        mutating func entry(_ which: Int32, _ p: Int32...) {
            entries.append([which] + p + [Int32](repeating: 0, count: 6 - p.count))
        }

        /// Adds a file's bytes and returns the offset an ExtractFile instruction names.
        mutating func file(_ contents: Data) -> Int32 {
            let offset = Int32(data.count)
            var length = UInt32(contents.count).littleEndian
            data.append(Data(bytes: &length, count: 4))
            data.append(contents)
            return offset
        }

        /// The whole installer: a stand-in for the program, then the NSIS data, deflated as one stream.
        func build(onInit: Int32 = -1, sectionCode: Int32) -> Data {
            func le(_ value: Int32) -> Data { var v = value.littleEndian; return Data(bytes: &v, count: 4) }
            let commonSize = 4 + 8 * 8 + 4 * 58          // flags, block table, the header's own fields
            let sectionSize = 24 + 1024 * 2
            let sectionsAt = commonSize, entriesAt = sectionsAt + sectionSize
            let stringsAt = entriesAt + entries.count * 28, langAt = stringsAt + strings.count * 2
            var header = Data()
            header.append(le(0))
            let blocks: [(Int, Int)] = [(0, 0), (sectionsAt, 1), (entriesAt, entries.count), (stringsAt, 0), (langAt, 0), (langAt, 0), (0, 0), (0, 0)]
            for (offset, count) in blocks { header.append(le(Int32(offset))); header.append(le(Int32(count))) }
            var fields = [Int32](repeating: 0, count: 58)
            for i in 10...19 { fields[i] = -1 }           // no callbacks
            fields[10] = onInit
            for field in fields { header.append(le(field)) }
            for value in [0, 0, 1, sectionCode, 0, 0] as [Int32] { header.append(le(value)) }   // one selected section
            header.append(Data(count: 1024 * 2))
            for entry in entries { for value in entry { header.append(le(value)) } }
            for unit in strings { var u = unit.littleEndian; header.append(Data(bytes: &u, count: 2)) }

            var stream = le(Int32(header.count))
            stream.append(header)
            stream.append(data)
            let packed = Self.deflate(stream)
            var installer = Data(count: 1024)             // where the 32-bit program would be
            installer.append(le(0))
            installer.append(Data([0xEF, 0xBE, 0xAD, 0xDE]))
            installer.append(Data("NullsoftInst".utf8))
            installer.append(le(Int32(header.count)))
            installer.append(le(Int32(28 + packed.count)))
            installer.append(packed)
            return installer
        }

        static func deflate(_ data: Data) -> Data {
            let capacity = data.count + 4096
            var out = Data(count: capacity)
            let written = out.withUnsafeMutableBytes { destination in
                data.withUnsafeBytes { source in
                    compression_encode_buffer(destination.bindMemory(to: UInt8.self).baseAddress!, capacity,
                                              source.bindMemory(to: UInt8.self).baseAddress!, data.count, nil, COMPRESSION_ZLIB)
                }
            }
            return out.prefix(written)
        }
    }

    private func install(_ installer: Data) throws -> NSISInstallReport {
        let file = root.appendingPathComponent("Game Setup.exe")
        try installer.write(to: file)
        XCTAssertTrue(NSISArchive.isNSISInstaller(file))
        let archive = try NSISArchive(url: file, temporaryDirectory: root)
        XCTAssertEqual(archive.compression, .deflate)
        XCTAssertTrue(archive.isSolid)
        return try NSISScript(archive: archive, driveC: root.appendingPathComponent("drive_c"), userName: "tester",
                              installer: file, productName: "Game").install()
    }

    /// A 64-bit Windows program's first bytes, which is all that is looked at.
    private var program: Data {
        var data = Data(count: 0x80)
        data[0] = 0x4D; data[1] = 0x5A; data[0x3C] = 0x40
        data[0x40] = 0x50; data[0x41] = 0x45; data[0x44] = 0x64; data[0x45] = 0x86
        return data
    }

    private func exists(_ path: String) -> Bool {
        FileManager.default.fileExists(atPath: root.appendingPathComponent("drive_c/" + path).path)
    }

    // MARK: Tests

    func testAnOrdinaryInstallerIsCarriedOut() throws {
        var b = Builder()
        let dir = b.string("C:\\Program Files\\Game"), exe = b.string("Game.exe"), txt = b.string("readme.txt")
        b.entry(25, 21, dir)                                        // StrCpy $INSTDIR
        b.entry(11, b.string("$INSTDIR"), 1)                        // SetOutPath
        b.entry(20, 0, exe, b.file(program))                        // File Game.exe
        b.entry(20, 0, txt, b.file(Data("hello".utf8)))             // File readme.txt
        b.entry(45, b.string("C:\\users\\tester\\Desktop\\The Game.lnk"), b.string("$INSTDIR\\Game.exe"), b.string("-windowed"))
        b.entry(51, Int32(bitPattern: 0x8000_0001), b.string("Software\\Game"), b.string("Path"), b.string("$INSTDIR"), 1, 1)
        b.entry(1)                                                  // Return
        let report = try install(b.build(sectionCode: 0))

        XCTAssertEqual(report.installDirectory, "C:\\Program Files\\Game")
        XCTAssertEqual(report.filesWritten, 2)
        XCTAssertTrue(exists("Program Files/Game/Game.exe"))
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("drive_c/Program Files/Game/readme.txt"), encoding: .utf8), "hello")
        XCTAssertEqual(report.programs, [.init(name: "The Game", windowsPath: "C:\\Program Files\\Game\\Game.exe", arguments: "-windowed")])
        XCTAssertTrue(report.registryFile.contains("[HKEY_CURRENT_USER\\software\\game]"))
        XCTAssertTrue(report.registryFile.contains("\"Path\"=\"C:\\\\Program Files\\\\Game\""))
        XCTAssertFalse(report.foundInstallRoutineBySearch)
    }

    /// An installer whose own window (a 32-bit add-on) starts the work: the section does
    /// nothing, and the install function is only ever handed to the add-on as a callback. The
    /// add-on would also have copied the launcher up a folder.
    func testAnInstallerDrivenByAnAddOnIsStillInstalled() throws {
        var b = Builder()
        let plugin = b.string("$PLUGINSDIR\\Widget.dll")
        b.entry(1)                                                  // 0: the section, empty
        // 1: .onInit
        b.entry(25, 21, b.string("C:\\Program Files\\Launcher"))    // StrCpy $INSTDIR
        b.entry(25, 10, b.string("6"))                              // GetFunctionAddress $R0 (entry 5, plus one)
        b.entry(44, plugin, b.string("BindNsisFunc"), 0, 1)         // the add-on is given the callback
        b.entry(1)
        // 5: the install function
        b.entry(11, b.string("$INSTDIR\\1.0"), 1)                   // SetOutPath $INSTDIR\1.0
        b.entry(20, 0, b.string("Launcher.exe"), b.file(program))
        b.entry(31, b.string("$INSTDIR\\Launcher.exe"))             // Push, for the add-on's CreateShortcut
        b.entry(44, plugin, b.string("CreateShortcut"), 0, 1)
        b.entry(1)
        let report = try install(b.build(onInit: 1, sectionCode: 0))

        XCTAssertTrue(report.foundInstallRoutineBySearch)
        XCTAssertEqual(report.installDirectory, "C:\\Program Files\\Launcher")
        XCTAssertTrue(exists("Program Files/Launcher/1.0/Launcher.exe"))
        XCTAssertTrue(exists("Program Files/Launcher/Launcher.exe"), "the launcher is copied to where the script expects it")
        XCTAssertEqual(report.repairedFiles, ["C:\\Program Files\\Launcher\\Launcher.exe"])
        XCTAssertEqual(report.programs.map(\.windowsPath), ["C:\\Program Files\\Launcher\\Launcher.exe"])
        XCTAssertEqual(report.skippedPluginCalls["Widget.dll::CreateShortcut"], 1)
    }

    func testAnInstallerThatInstallsNothingIsReportedAsSuch() throws {
        var b = Builder()
        b.entry(1)
        XCTAssertThrowsError(try install(b.build(sectionCode: 0)))
    }

    func testNumbersAndFormatsAreReadAsNSISReadsThem() {
        XCTAssertEqual(NSISScript.int("42"), 42)
        XCTAssertEqual(NSISScript.int("-7 apples"), -7)
        XCTAssertEqual(NSISScript.int("0x1F"), 31)
        XCTAssertEqual(NSISScript.int("010"), 8)
        XCTAssertEqual(NSISScript.int(""), 0)
        XCTAssertEqual(NSISScript.format("%d files", 3), "3 files")
        XCTAssertEqual(NSISScript.format("0x%08X", 255), "0x000000FF")
        XCTAssertEqual(NSISScript.format("100%%", 1), "100%")
    }

    func testWindowsPathsAreFoundWhateverTheirCase() throws {
        let drive = root.appendingPathComponent("drive_c")
        try FileManager.default.createDirectory(at: drive.appendingPathComponent("Program Files/Game"), withIntermediateDirectories: true)
        try Data("x".utf8).write(to: drive.appendingPathComponent("Program Files/Game/Data.pak"))
        let files = WindowsFiles(driveC: drive)
        // (the Mac's own disk may or may not tell cases apart; either way the file is found)
        XCTAssertEqual(files.url("c:\\PROGRAM FILES\\game\\data.PAK").flatMap { try? String(contentsOf: $0, encoding: .utf8) }, "x")
        XCTAssertTrue(files.exists("C:\\Program Files\\Game\\*.pak"))
        XCTAssertEqual(files.matches("C:\\Program Files\\Game\\*.*").count, 1)
        XCTAssertNil(files.url("D:\\elsewhere"))
    }

    func testIniFilesAreWrittenAndReadBack() {
        let file = root.appendingPathComponent("drive_c/config.ini")
        XCTAssertTrue(INIFile.write(section: "Game", key: "Lang", value: "en", at: file))
        XCTAssertTrue(INIFile.write(section: "Game", key: "Size", value: "2", at: file))
        XCTAssertTrue(INIFile.write(section: "Other", key: "A", value: "b", at: file))
        XCTAssertEqual(INIFile.read(section: "game", key: "lang", at: file), "en")
        XCTAssertTrue(INIFile.write(section: "Game", key: "Lang", value: "fr", at: file))
        XCTAssertEqual(INIFile.read(section: "Game", key: "Lang", at: file), "fr")
        XCTAssertEqual(INIFile.read(section: "Other", key: "A", at: file), "b")
        XCTAssertNil(INIFile.read(section: "Game", key: "Missing", at: file))
    }

    func test32BitProgramsAreRecognised() throws {
        var thirtyTwo = program
        thirtyTwo[0x44] = 0x4C; thirtyTwo[0x45] = 0x01
        let a = root.appendingPathComponent("a.exe"), b = root.appendingPathComponent("b.exe")
        try thirtyTwo.write(to: a)
        try program.write(to: b)
        XCTAssertTrue(WindowsExecutable.is32BitProgram(a))
        XCTAssertFalse(WindowsExecutable.is32BitProgram(b))
        XCTAssertFalse(NSISArchive.isNSISInstaller(b))
    }
}

final class GameProfileInstallerTests: XCTestCase {
    func testTheGryphlinkInstallerGetsTheEndfieldProfile() {
        let profiles = GameProfile.builtIn
        let url = URL(fileURLWithPath: "/Users/me/Downloads/GRYPHLINK_v1.6.0.1607_6_6_endfield.exe")
        XCTAssertEqual(GameProfile.forInstaller(url, among: profiles)?.id, "arknights-endfield")
        XCTAssertEqual(GameProfile.forInstaller(url, among: profiles)?.settings.windowsBuild, "26100")
        XCTAssertNil(GameProfile.forInstaller(URL(fileURLWithPath: "/tmp/SomeGameSetup.exe"), among: profiles))
    }
}
