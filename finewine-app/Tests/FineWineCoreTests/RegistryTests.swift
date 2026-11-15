import XCTest
@testable import FineWineCore

final class RegistryFileTests: XCTestCase {
    func testRendersHeaderAndGroupsEditsByKey() {
        let text = RegistryFile.render([
            .string(#"HKEY_CURRENT_USER\Software\Wine"#, "Version", "win11"),
            .dword(#"HKEY_CURRENT_USER\Control Panel\Desktop"#, "LogPixels", 96),
            .string(#"HKEY_CURRENT_USER\Software\Wine"#, "Other", "x")
        ])
        XCTAssertEqual(text, """
        Windows Registry Editor Version 5.00\r
        \r
        [HKEY_CURRENT_USER\\Software\\Wine]\r
        "Version"="win11"\r
        "Other"="x"\r
        \r
        [HKEY_CURRENT_USER\\Control Panel\\Desktop]\r
        "LogPixels"=dword:00000060\r

        """)
    }

    func testEscapesBackslashesAndQuotes() {
        let text = RegistryFile.render([.string("HKEY_CURRENT_USER\\K", "pa\"th", #"C:\dir\"x""#)])
        XCTAssertTrue(text.contains(#""pa\"th"="C:\\dir\\\"x\"""#), text)
    }

    func testDeleteValueDefaultValueAndDeleteKey() {
        let text = RegistryFile.render([
            .delete("HKEY_CURRENT_USER\\A", "gone"),
            RegistryEdit(key: "HKEY_CURRENT_USER\\A", name: nil, action: .setString("default")),
            RegistryEdit(key: "HKEY_CURRENT_USER\\B", name: nil, action: .deleteKey)
        ])
        XCTAssertTrue(text.contains("\"gone\"=-\r\n"))
        XCTAssertTrue(text.contains("@=\"default\"\r\n"))
        XCTAssertTrue(text.contains("[-HKEY_CURRENT_USER\\B]\r\n"))
    }

    func testBinaryValues() {
        let text = RegistryFile.render([.binary("HKEY_CURRENT_USER\\K", "blob", [0x00, 0x0A, 0xFF])])
        XCTAssertTrue(text.contains("\"blob\"=hex:00,0a,ff\r\n"), text)
        XCTAssertTrue(RegistryFile.render([.binary("HKEY_CURRENT_USER\\K", "empty", [])]).contains("\"empty\"=hex:\r\n"))
    }

    func testDataIsUTF16WithByteOrderMark() {
        let data = RegistryFile.data([.string("HKEY_CURRENT_USER\\K", "名前", "値")])
        XCTAssertEqual(Array(data.prefix(2)), [0xFF, 0xFE])
        let decoded = String(data: data.dropFirst(2), encoding: .utf16LittleEndian)
        XCTAssertEqual(decoded, RegistryFile.render([.string("HKEY_CURRENT_USER\\K", "名前", "値")]))
    }
}

final class WineRegistryReaderTests: XCTestCase {
    static let sample = """
    WINE REGISTRY Version 2
    ;; All keys relative to \\\\User\\\\S-1-5-21-0-0-0-1000

    #arch=win64

    [Control Panel\\\\Desktop] 1731500000
    #time=1dc35a0c0a0b0c0
    "LogPixels"=dword:00000078
    "Wallpaper"=""

    [Software\\\\Wine\\\\DllOverrides] 1731500001
    "d3d11"="native,builtin"
    "winemenubuilder.exe"=""

    [Software\\\\Wine] 1731500002
    "Version"="win10"
    @="the default"
    "Quoted \\"name\\""="C:\\\\Program Files\\\\X"
    "Binary"=hex:01,02
    """

    func testReadsStringsDWordsAndDefaults() {
        let reader = WineRegistryReader(text: Self.sample)
        XCTAssertEqual(reader.string(key: #"Software\Wine"#, name: "Version"), "win10")
        XCTAssertEqual(reader.string(key: #"Software\Wine"#, name: nil), "the default")
        XCTAssertEqual(reader.dword(key: #"Control Panel\Desktop"#, name: "LogPixels"), 120)
        XCTAssertEqual(reader.string(key: #"Control Panel\Desktop"#, name: "Wallpaper"), "")
    }

    func testKeysAndNamesIgnoreCase() {
        let reader = WineRegistryReader(text: Self.sample)
        XCTAssertEqual(reader.string(key: #"SOFTWARE\wine\dlloverrides"#, name: "D3D11"), "native,builtin")
        XCTAssertTrue(reader.hasKey(#"software\WINE"#))
        XCTAssertFalse(reader.hasKey(#"Software\Missing"#))
    }

    func testUnescapesNamesAndValues() {
        let reader = WineRegistryReader(text: Self.sample)
        XCTAssertEqual(reader.string(key: #"Software\Wine"#, name: #"Quoted "name""#), #"C:\Program Files\X"#)
    }

    func testOtherValueTypesAreKeptButNotDecoded() {
        let reader = WineRegistryReader(text: Self.sample)
        XCTAssertEqual(reader.value(key: #"Software\Wine"#, name: "Binary"), .other("hex:01,02"))
        XCTAssertNil(reader.string(key: #"Software\Wine"#, name: "Binary"))
    }

    func testValuesListsAKey() {
        let reader = WineRegistryReader(text: Self.sample)
        XCTAssertEqual(reader.values(key: #"Software\Wine\DllOverrides"#),
                       ["d3d11": .string("native,builtin"), "winemenubuilder.exe": .string("")])
    }

    func testHandlesCRLFAndGarbage() {
        let reader = WineRegistryReader(text: "[A\\\\B] 1\r\n\"x\"=\"1\"\r\nnot a value line\r\n\"broken\r\n")
        XCTAssertEqual(reader.string(key: #"A\B"#, name: "x"), "1")
        XCTAssertNil(reader.value(key: #"A\B"#, name: "broken"))
    }

    func testRoundTripsWhatRegistryFileWrites() {
        // The two formats differ in header and key syntax, but values are written the same way.
        let edits: [RegistryEdit] = [.string("K\\Sub", "name", #"va"l\ue"#), .dword("K\\Sub", "n", 0xDEADBEEF)]
        let body = RegistryFile.render(edits).replacingOccurrences(of: "[K\\Sub]", with: "[K\\\\Sub] 1")
        let reader = WineRegistryReader(text: body)
        XCTAssertEqual(reader.string(key: #"K\Sub"#, name: "name"), #"va"l\ue"#)
        XCTAssertEqual(reader.dword(key: #"K\Sub"#, name: "n"), 0xDEADBEEF)
    }
}
