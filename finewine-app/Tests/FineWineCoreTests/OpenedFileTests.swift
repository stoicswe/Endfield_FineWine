import XCTest
@testable import FineWineCore

final class OpenedFileTests: XCTestCase {
    /// One entry of a version resource: { length, value length, type 1, key, padding, value }.
    static func versionEntry(_ key: String, _ value: String) -> Data {
        func utf16(_ s: String) -> [UInt8] { (Array(s.utf16) + [0]).flatMap { [UInt8($0 & 0xff), UInt8($0 >> 8)] } }
        var body = utf16(key)
        if (6 + body.count) % 4 != 0 { body += [0, 0] }
        let v = utf16(value)
        let total = 6 + body.count + v.count
        return Data([UInt8(total & 0xff), UInt8(total >> 8), UInt8(value.utf16.count + 1), 0, 1, 0] + body + v)
    }

    /// The smallest program that has the given version entries as its version resource, with
    /// `payload` (other programs an installer carries, say) after it.
    static func program(version entries: [(String, String)], payload: Data = Data()) -> Data {
        func le16(_ v: Int) -> [UInt8] { [UInt8(v & 0xff), UInt8(v >> 8 & 0xff)] }
        func le32(_ v: Int) -> [UInt8] { le16(v & 0xffff) + le16(v >> 16) }
        let blob = entries.reduce(Data()) { $0 + versionEntry($1.0, $1.1) }
        let raw = 0x200, rva = 0x1000
        // Three directory levels of one entry each (type 16, name 1, language 0x409), then the data entry.
        var rsrc: [UInt8] = []
        func directory(id: Int, target: Int, isDirectory: Bool) {
            rsrc += [UInt8](repeating: 0, count: 12) + le16(0) + le16(1) + le32(id) + le32(target | (isDirectory ? 0x8000_0000 : 0))
        }
        directory(id: 16, target: 24, isDirectory: true)
        directory(id: 1, target: 48, isDirectory: true)
        directory(id: 0x409, target: 72, isDirectory: false)
        rsrc += le32(rva + 88) + le32(blob.count) + le32(0) + le32(0)
        rsrc += [UInt8](blob)
        var file = [UInt8](repeating: 0, count: 0x40)
        file[0] = 0x4D; file[1] = 0x5A; file[0x3C] = 0x40
        file += [0x50, 0x45, 0, 0] + le16(0x8664) + le16(1) + [UInt8](repeating: 0, count: 12) + le16(240) + le16(0)
        var optional = [UInt8](repeating: 0, count: 240)
        optional[0] = 0x0B; optional[1] = 0x02
        optional.replaceSubrange((112 + 16)..<(112 + 24), with: le32(rva) + le32(rsrc.count))
        file += optional
        file += Array(".rsrc".utf8) + [0, 0, 0] + le32(rsrc.count) + le32(rva) + le32(rsrc.count) + le32(raw) + [UInt8](repeating: 0, count: 16)
        file += [UInt8](repeating: 0, count: raw - file.count)
        return Data(file + rsrc) + payload
    }

    func testAnInstallerIsNotNamedAfterAProgramItCarries() {
        let sandbox = Sandbox()
        let carried = Self.versionEntry("ProductName", "7-Zip")
        let file = sandbox.root.appendingPathComponent("SomeGame_install_ua_4a4c7a42c0e9.exe")
        let file2 = sandbox.root.appendingPathComponent("dl_8841.exe")
        sandbox.write(Self.program(version: [("ProductName", "Some Game")], payload: carried), to: file2)
        XCTAssertEqual(InstallName.statedName(at: file2), "Some Game")
        // With no version information of its own, the carried program's is still not used.
        sandbox.write(Data("MZ".utf8) + carried, to: file2)
        XCTAssertNil(InstallName.statedName(at: file2))
        _ = file
    }

    func testTheProductNameIsReadFromVersionInformation() {
        var data = Data(repeating: 0x90, count: 37)          // any offset, not aligned
        data += Self.versionEntry("CompanyName", "Somebody")
        data += Self.versionEntry("FileDescription", "Zenless Zone Zero Installer")
        data += Self.versionEntry("ProductName", "Zenless Zone Zero")
        XCTAssertEqual(InstallName.versionString("ProductName", in: data), "Zenless Zone Zero")
        XCTAssertEqual(InstallName.versionString("FileDescription", in: data), "Zenless Zone Zero Installer")
        XCTAssertNil(InstallName.versionString("LegalCopyright", in: data))
        XCTAssertNil(InstallName.versionString("ProductName", in: Data("ProductName".utf8)))
    }

    func testAPrefixIsNamedAfterTheProgramOrElseItsFile() throws {
        let sandbox = Sandbox()
        let withInfo = sandbox.root.appendingPathComponent("zzz_setup_202611.exe")
        sandbox.write(Self.program(version: [("ProductName", "Zenless Zone Zero Setup")]), to: withInfo)
        XCTAssertEqual(InstallName.prefixName(for: withInfo, existing: []), "Zenless Zone Zero")

        let generic = sandbox.root.appendingPathComponent("Cool_Game-Setup_v1.2.3_x64.exe")
        sandbox.write(Self.program(version: [("ProductName", "Setup")]), to: generic)
        XCTAssertEqual(InstallName.prefixName(for: generic, existing: []), "Cool Game", "a product name that says nothing is not used")

        let plain = sandbox.root.appendingPathComponent("My.Tool.Installer.msi")
        sandbox.write(Data(), to: plain)
        XCTAssertEqual(InstallName.prefixName(for: plain, existing: []), "My Tool")
        XCTAssertEqual(InstallName.prefixName(for: sandbox.root.appendingPathComponent("setup.exe"), existing: []), InstallName.fallback)
    }

    func testFileNamesAreCleanedUp() {
        XCTAssertEqual(InstallName.cleaned(fileName: "HoYoPlay_install_global_1.4.5"), "HoYoPlay")
        XCTAssertEqual(InstallName.cleaned(fileName: "Notepad++ Installer (x64)"), "Notepad")
        XCTAssertEqual(InstallName.cleaned(fileName: "7z2409-x64"), "7z2409")
        XCTAssertEqual(InstallName.cleaned(fileName: "ZenlessZoneZero_install_ua_4a4c7a42c0e9"), "Zenless Zone Zero")
        XCTAssertEqual(InstallName.cleaned(fileName: "GRYPHLINK_v1.6.0.1607_6_6_endfield"), "GRYPHLINK")
        XCTAssertEqual(InstallName.cleaned(fileName: "Setup_SomeGame_1.2"), "Some Game")
        XCTAssertEqual(InstallName.splitJoinedWords("HoYoPlay"), "HoYoPlay")
        XCTAssertEqual(InstallName.cleaned(fileName: "ChromeSetup"), "Chrome")
    }

    func testAFileNameThatSpellsTheNameOutWinsOverTheInstallersOwnName() {
        let sandbox = Sandbox()
        // One launcher's installer, downloaded for one game.
        let game = sandbox.root.appendingPathComponent("ZenlessZoneZero_install_ua_4a4c7a42c0e9.exe")
        sandbox.write(Self.program(version: [("ProductName", "HoYoPlay")]), to: game)
        XCTAssertEqual(InstallName.prefixHint(for: game, existing: []), .init(name: "Zenless Zone Zero", isFromInstaller: true))
        // A file name that is one word, or not words, leaves it to the installer.
        let chrome = sandbox.root.appendingPathComponent("ChromeSetup.exe")
        sandbox.write(Self.program(version: [("ProductName", "Google Chrome Installer")]), to: chrome)
        XCTAssertEqual(InstallName.prefixHint(for: chrome, existing: []).name, "Google Chrome")
        let zip = sandbox.root.appendingPathComponent("7z2409-x64.exe")
        sandbox.write(Self.program(version: [("ProductName", "7-Zip")]), to: zip)
        XCTAssertEqual(InstallName.prefixHint(for: zip, existing: []).name, "7-Zip")
        XCTAssertEqual(InstallName.cleaned(fileName: "Game 2 Setup 2026"), "Game 2", "the 2 of a sequel stays, a year goes")
        XCTAssertTrue(InstallName.isVersion("v1.0.4b"))
        XCTAssertFalse(InstallName.isVersion("vulkan"))
    }

    func testNamesNeverCollideWithExistingPrefixes() {
        XCTAssertEqual(InstallName.unique("Game", among: ["Other"]), "Game")
        XCTAssertEqual(InstallName.unique("Game", among: ["game"]), "Game 2")
        XCTAssertEqual(InstallName.unique("Game", among: ["Game", "GAME 2"]), "Game 3")
    }

    func testAnInstallersOwnWordsAreTakenOutOfItsName() {
        XCTAssertEqual(InstallName.cleaned(productName: "Some Game Setup"), "Some Game")
        XCTAssertEqual(InstallName.cleaned(productName: "Setup for Some Game (64-bit) 1.2.3"), "Some Game")
        XCTAssertEqual(InstallName.cleaned(productName: "Some Game Web Installer"), "Some Game")
        XCTAssertEqual(InstallName.cleaned(productName: "Half-Life 2"), "Half-Life 2")
        XCTAssertNil(InstallName.cleaned(productName: "Setup"))
        XCTAssertNil(InstallName.cleaned(productName: "Installer x64"))
    }

    func testADescriptionIsUsedWhenTheProductNameSaysNothing() {
        let sandbox = Sandbox()
        let file = sandbox.root.appendingPathComponent("a1b2c3.exe")
        sandbox.write(Self.program(version: [("ProductName", "Setup"), ("FileDescription", "Cool Game Installer")]), to: file)
        XCTAssertEqual(InstallName.prefixHint(for: file, existing: []), .init(name: "Cool Game", isFromInstaller: true))
        let bare = sandbox.root.appendingPathComponent("coolgame_setup.exe")
        sandbox.write(Data("MZ".utf8), to: bare)
        XCTAssertEqual(InstallName.prefixHint(for: bare, existing: []), .init(name: "coolgame", isFromInstaller: false))
    }

    func testWhatWasInstalledNamesThePrefix() {
        XCTAssertEqual(InstallName.installedName(programs: [("Cool Game", #"C:\Program Files\CG\cg.exe"#),
                                                            ("Uninstall Cool Game", #"C:\Program Files\CG\unins000.exe"#)]), "Cool Game")
        XCTAssertEqual(InstallName.installedName(programs: [("Battle Thing", #"C:\a\b.exe"#), ("Battle Thing Launcher", #"C:\a\l.exe"#)]), "Battle Thing")
        XCTAssertEqual(InstallName.installedName(programs: [("Word", #"C:\Program Files\Office Suite\bin\w.exe"#),
                                                            ("Sheets", #"C:\Program Files\Office Suite\bin\s.exe"#)]), "Office Suite")
        XCTAssertNil(InstallName.installedName(programs: [("One", #"C:\Program Files\A\a.exe"#), ("Two", #"C:\Program Files\B\b.exe"#)]))
        XCTAssertNil(InstallName.installedName(programs: []))
    }
}
