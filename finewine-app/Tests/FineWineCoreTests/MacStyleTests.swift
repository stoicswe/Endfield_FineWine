import XCTest
@testable import FineWineCore

final class MacStyleTests: XCTestCase {
    private let light = MacAppearance(isDark: false, accentRed: 255, accentGreen: 45, accentBlue: 85)
    private let dark = MacAppearance(isDark: true, accentRed: 255, accentGreen: 45, accentBlue: 85)

    private func action(_ edits: [RegistryEdit], _ key: String, _ name: String) -> RegistryEdit.Action? {
        edits.last { $0.key == key && $0.name == name }?.action
    }

    func testAccentColourDrivesSelectionsInBothModes() {
        for appearance in [light, dark] {
            let edits = MacStyle.registryEdits(for: appearance)
            XCTAssertEqual(action(edits, MacStyle.colorsKey, "Hilight"), .setString("255 45 85"))
            XCTAssertEqual(action(edits, MacStyle.colorsKey, "MenuHilight"), .setString("255 45 85"))
            XCTAssertEqual(action(edits, MacStyle.colorsKey, "HotTrackingColor"), .setString("255 45 85"))
            XCTAssertEqual(action(edits, MacStyle.colorsKey, "HilightText"), .setString("255 255 255"))
        }
    }

    func testLightAndDarkPalettes() {
        let lightEdits = MacStyle.registryEdits(for: light), darkEdits = MacStyle.registryEdits(for: dark)
        XCTAssertEqual(action(lightEdits, MacStyle.colorsKey, "Window"), .setString("255 255 255"))
        XCTAssertEqual(action(lightEdits, MacStyle.colorsKey, "ButtonFace"), .setString("236 236 236"))
        XCTAssertEqual(action(darkEdits, MacStyle.colorsKey, "Window"), .setString("30 30 30"))
        XCTAssertEqual(action(darkEdits, MacStyle.colorsKey, "WindowText"), .setString("223 223 223"))
    }

    func testBothPalettesDefineTheSameColoursAndStayReadable() {
        let lightColors = MacStyle.colors(for: light), darkColors = MacStyle.colors(for: dark)
        XCTAssertEqual(Set(lightColors.keys), Set(darkColors.keys))
        func luminance(_ c: (Int, Int, Int)) -> Double { 0.2126 * Double(c.0) + 0.7152 * Double(c.1) + 0.0722 * Double(c.2) }
        for colors in [lightColors, darkColors] {
            for (background, text) in [("Window", "WindowText"), ("ButtonFace", "ButtonText"), ("Menu", "MenuText"), ("InfoWindow", "InfoText")] {
                XCTAssertGreaterThan(abs(luminance(colors[background]!) - luminance(colors[text]!)), 120, "\(text) on \(background)")
            }
        }
    }

    func testThemeIsOnlyKeptInLightMode() {
        XCTAssertEqual(action(MacStyle.registryEdits(for: light), MacStyle.themeKey, "ThemeActive"), .setString("1"))
        XCTAssertEqual(action(MacStyle.registryEdits(for: dark), MacStyle.themeKey, "ThemeActive"), .setString("0"))
    }

    func testDialogFontsAreRedirected() {
        let edits = MacStyle.registryEdits(for: light)
        for name in ["MS Shell Dlg", "MS Shell Dlg 2", "Tahoma"] {
            XCTAssertEqual(action(edits, MacStyle.substitutesKey, name), .setString("Helvetica Neue"))
        }
        XCTAssertEqual(action(edits, MacStyle.desktopKey, "FontSmoothing"), .setString("2"))
        XCTAssertEqual(action(edits, MacStyle.desktopKey, "FontSmoothingType"), .setDWord(1))
    }

    func testLogFontLayout() {
        let font = MacStyle.logFont(face: "Helvetica Neue", height: -12, weight: 400)
        XCTAssertEqual(font.count, 92, "sizeof(LOGFONTW)")
        XCTAssertEqual(Array(font[0..<4]), [0xF4, 0xFF, 0xFF, 0xFF], "lfHeight = -12, little-endian")
        XCTAssertEqual(Array(font[16..<20]), [0x90, 0x01, 0, 0], "lfWeight = 400")
        XCTAssertEqual(font[23], 1, "DEFAULT_CHARSET")
        let units = stride(from: 28, to: 92, by: 2).map { UInt16(font[$0]) | UInt16(font[$0 + 1]) << 8 }
        XCTAssertEqual(String(decoding: units.prefix { $0 != 0 }, as: UTF16.self), "Helvetica Neue")
    }

    func testLongFaceNamesAreTruncatedAndStayTerminated() {
        let font = MacStyle.logFont(face: String(repeating: "x", count: 80))
        XCTAssertEqual(font.count, 92)
        XCTAssertEqual(Array(font[90..<92]), [0, 0])
    }

    func testMetricFontsAreWrittenAsBinary() {
        let edits = MacStyle.registryEdits(for: light)
        guard case .setBinary(let bytes)? = action(edits, MacStyle.metricsKey, "MessageFont") else { return XCTFail("no font") }
        XCTAssertEqual(bytes.count, 92)
        XCTAssertTrue(RegistryFile.render(edits).contains("\"MessageFont\"=hex:f4,ff,ff,ff,00,"))
    }

    func testRemovalDeletesEverythingStylingSets() {
        let set = MacStyle.registryEdits(for: dark), removed = MacStyle.removalEdits()
        for edit in set where edit.key != MacStyle.desktopKey && edit.key != MacStyle.themeKey {
            XCTAssertEqual(action(removed, edit.key, edit.name!), .deleteValue, "\(edit.key) \(edit.name!)")
        }
        XCTAssertEqual(action(removed, MacStyle.themeKey, "ThemeActive"), .setString("1"))
    }

    func testAppearanceClampsComponents() {
        let appearance = MacAppearance(isDark: false, accentRed: 300, accentGreen: -5, accentBlue: 128)
        XCTAssertEqual([appearance.accentRed, appearance.accentGreen, appearance.accentBlue], [255, 0, 128])
    }

    func testSettingsIncludeStylingOnlyWhenOnAndAnAppearanceIsKnown() {
        var settings = PrefixSettings()
        XCTAssertTrue(settings.macAppearance)
        XCTAssertNil(action(settings.registryEdits(), MacStyle.colorsKey, "Hilight"), "no appearance given")
        XCTAssertNotNil(action(settings.registryEdits(appearance: dark), MacStyle.colorsKey, "Hilight"))

        let before = settings
        settings.macAppearance = false
        XCTAssertNil(action(settings.registryEdits(appearance: dark), MacStyle.colorsKey, "Hilight"))
        XCTAssertEqual(action(settings.registryEdits(replacing: before, appearance: dark), MacStyle.colorsKey, "Hilight"),
                       .deleteValue, "turning it off hands the colours back to Wine")
        XCTAssertNil(action(settings.registryEdits(replacing: settings, appearance: dark), MacStyle.colorsKey, "Hilight"),
                     "already off: nothing to undo")
    }

    func testOlderMetadataDefaultsToStylingOnAndOldESyncFallsBack() throws {
        let settings = try JSONDecoder().decode(PrefixSettings.self, from: Data(#"{"syncMode":"esync"}"#.utf8))
        XCTAssertTrue(settings.macAppearance)
        XCTAssertEqual(settings.syncMode, .standard)
        XCTAssertEqual(try JSONDecoder().decode(PrefixSettings.self, from: Data(#"{"syncMode":"msync"}"#.utf8)).syncMode, .msync)
    }
}
