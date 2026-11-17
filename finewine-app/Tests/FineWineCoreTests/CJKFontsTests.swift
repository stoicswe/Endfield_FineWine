import XCTest
@testable import FineWineCore

final class CJKFontsTests: XCTestCase {
    /// The English names and their Mac fonts, as the runtime's wine.inf sets them
    /// (patches/runtime/0029), read from the patch.
    static func wineInfReplacements() throws -> [String: [String]] {
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let patches = try FileManager.default.contentsOfDirectory(at: repo.appendingPathComponent("patches/runtime"),
                                                                  includingPropertiesForKeys: nil)
        let patch = try XCTUnwrap(patches.first { $0.lastPathComponent.hasPrefix("0029-") })
        var out: [String: [String]] = [:]
        for line in try String(contentsOf: patch, encoding: .utf8).split(separator: "\n")
        where line.hasPrefix(#"+HKCU,Software\Wine\Fonts\Replacements,""#) {
            // +HKCU,Software\Wine\Fonts\Replacements,"Name",0x10000,"A","B"
            let fields = line.dropFirst().split(separator: ",", omittingEmptySubsequences: false).map {
                $0.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            }
            out[fields[2]] = Array(fields[4...])
        }
        return out
    }

    func testEnglishNamesMatchTheRuntimesWineInf() throws {
        let inf = try Self.wineInfReplacements()
        XCTAssertFalse(inf.isEmpty)
        let table = Dictionary(uniqueKeysWithValues: CJKFonts.groups.flatMap { g in g.windowsNames.map { ($0, g.macFonts) } })
        XCTAssertEqual(table, inf)
    }

    func testEveryNameIsListedOnce() {
        let names = CJKFonts.replacements.map(\.name)
        XCTAssertEqual(Set(names).count, names.count)
        XCTAssertTrue(names.contains("宋体"))
        XCTAssertTrue(names.contains("맑은 고딕"))
    }

    func testPrefixesGetTheLocalizedNames() {
        let edits = PrefixSettings().registryEdits()
        let fonts = edits.filter { $0.key == CJKFonts.replacementsKey }
        XCTAssertEqual(Set(fonts.compactMap(\.name)), Set(CJKFonts.groups.flatMap(\.localizedNames)))
        XCTAssertEqual(fonts.first { $0.name == "微软雅黑" }?.action,
                       .setMultiString(CJKFonts.groups.first { $0.windowsNames.contains("Microsoft YaHei") }!.macFonts))
    }

    func testMultiStringRendersAsHex7() {
        let text = RegistryFile.render([.multiString(#"HKEY_CURRENT_USER\X"#, "宋体", ["Ab", "C"])])
        // "Ab\0C\0\0" in UTF-16LE
        XCTAssertTrue(text.contains("\"宋体\"=hex(7):41,00,62,00,00,00,43,00,00,00,00,00\r\n"), text)
    }
}
