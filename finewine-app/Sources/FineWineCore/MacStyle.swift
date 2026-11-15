import Foundation

/// The parts of the Mac's look that Windows controls are made to follow.
public struct MacAppearance: Codable, Equatable, Sendable {
    public var isDark: Bool
    /// The accent colour, each component 0–255.
    public var accentRed: Int
    public var accentGreen: Int
    public var accentBlue: Int

    public init(isDark: Bool, accentRed: Int, accentGreen: Int, accentBlue: Int) {
        self.isDark = isDark
        self.accentRed = min(max(accentRed, 0), 255)
        self.accentGreen = min(max(accentGreen, 0), 255)
        self.accentBlue = min(max(accentBlue, 0), 255)
    }

    /// macOS's default blue accent in light mode.
    public static let standard = MacAppearance(isDark: false, accentRed: 0, accentGreen: 122, accentBlue: 255)
}

/// Makes Wine's own controls (in winecfg, the registry editor, installers, launchers) look at
/// home on a Mac. Window frames and title bars are already drawn by macOS; this covers what is
/// inside them:
///
/// - **Colours.** The Windows system colours are set to macOS's window, control, text and
///   selection colours, with the Mac's accent colour for selections and links.
/// - **Font.** Dialogs and menus use Helvetica Neue instead of Tahoma, smoothed the way macOS
///   smooths text.
/// - **Theme.** In light mode Wine's flat built-in theme stays on. It has no dark variant, so in
///   dark mode it is switched off and controls are drawn from the dark system colours.
public enum MacStyle {
    public static let fontName = "Helvetica Neue"

    static let colorsKey = #"HKEY_CURRENT_USER\Control Panel\Colors"#
    static let desktopKey = #"HKEY_CURRENT_USER\Control Panel\Desktop"#
    static let metricsKey = #"HKEY_CURRENT_USER\Control Panel\Desktop\WindowMetrics"#
    static let themeKey = #"HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\ThemeManager"#
    static let substitutesKey = #"HKEY_LOCAL_MACHINE\Software\Microsoft\Windows NT\CurrentVersion\FontSubstitutes"#

    /// The Windows dialog fonts that are redirected to `fontName`.
    static let substitutedFonts = ["MS Shell Dlg", "MS Shell Dlg 2", "Tahoma"]
    /// The window-metric fonts (captions aside, which macOS draws) set to `fontName`.
    static let metricFonts = ["MenuFont", "MessageFont", "StatusFont", "IconFont", "SmCaptionFont", "CaptionFont"]

    /// The Windows system colours for a Mac appearance, as `name → (r, g, b)`.
    public static func colors(for appearance: MacAppearance) -> [String: (Int, Int, Int)] {
        let accent = (appearance.accentRed, appearance.accentGreen, appearance.accentBlue)
        let white = (255, 255, 255)
        if appearance.isDark {
            let window = (30, 30, 30), control = (50, 50, 50), text = (223, 223, 223)
            return [
                "Window": window, "WindowText": text, "WindowFrame": (70, 70, 70),
                "ButtonFace": control, "ButtonText": text, "ButtonHilight": (84, 84, 84),
                "ButtonLight": (66, 66, 66), "ButtonShadow": (32, 32, 32), "ButtonDkShadow": (16, 16, 16),
                "ButtonAlternateFace": control,
                "Menu": (42, 42, 42), "MenuBar": (42, 42, 42), "MenuText": text, "MenuHilight": accent,
                "Hilight": accent, "HilightText": white, "HotTrackingColor": accent,
                "GrayText": (120, 120, 120), "AppWorkSpace": (38, 38, 38), "Background": (30, 30, 30),
                "Scrollbar": (50, 50, 50), "InfoWindow": (60, 60, 60), "InfoText": text,
                "ActiveBorder": control, "InactiveBorder": control,
                "ActiveTitle": (58, 58, 58), "GradientActiveTitle": (58, 58, 58), "TitleText": text,
                "InactiveTitle": (44, 44, 44), "GradientInactiveTitle": (44, 44, 44),
                "InactiveTitleText": (140, 140, 140)
            ]
        }
        let window = (255, 255, 255), control = (236, 236, 236), text = (38, 38, 38)
        return [
            "Window": window, "WindowText": text, "WindowFrame": (198, 198, 198),
            "ButtonFace": control, "ButtonText": text, "ButtonHilight": white,
            "ButtonLight": (246, 246, 246), "ButtonShadow": (198, 198, 198), "ButtonDkShadow": (150, 150, 150),
            "ButtonAlternateFace": control,
            "Menu": (246, 246, 246), "MenuBar": (246, 246, 246), "MenuText": text, "MenuHilight": accent,
            "Hilight": accent, "HilightText": white, "HotTrackingColor": accent,
            "GrayText": (150, 150, 150), "AppWorkSpace": (226, 226, 226), "Background": (236, 236, 236),
            "Scrollbar": (236, 236, 236), "InfoWindow": (246, 246, 246), "InfoText": text,
            "ActiveBorder": control, "InactiveBorder": control,
            "ActiveTitle": (222, 222, 222), "GradientActiveTitle": (222, 222, 222), "TitleText": text,
            "InactiveTitle": (240, 240, 240), "GradientInactiveTitle": (240, 240, 240),
            "InactiveTitleText": (150, 150, 150)
        ]
    }

    /// A Windows `LOGFONTW` structure (92 bytes) for a regular-weight font.
    /// `height` is in pixels at 96 DPI and negative, meaning character height.
    static func logFont(face: String, height: Int32 = -12, weight: Int32 = 400) -> [UInt8] {
        var bytes: [UInt8] = []
        func append(_ value: Int32) {
            let v = UInt32(bitPattern: value)
            bytes += [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8((v >> 24) & 0xFF)]
        }
        append(height)      // lfHeight
        append(0)           // lfWidth
        append(0)           // lfEscapement
        append(0)           // lfOrientation
        append(weight)      // lfWeight
        bytes += [0, 0, 0]  // italic, underline, strike-out
        bytes += [1]        // lfCharSet: DEFAULT_CHARSET
        bytes += [0, 0]     // output and clip precision
        bytes += [5]        // lfQuality: CLEARTYPE_QUALITY
        bytes += [0]        // pitch and family
        // lfFaceName: 32 UTF-16 units, null-terminated.
        let units = Array(face.utf16.prefix(31))
        for i in 0..<32 {
            let unit = i < units.count ? units[i] : 0
            bytes += [UInt8(unit & 0xFF), UInt8(unit >> 8)]
        }
        return bytes
    }

    /// The edits that style a prefix for `appearance`.
    public static func registryEdits(for appearance: MacAppearance) -> [RegistryEdit] {
        var edits: [RegistryEdit] = []
        for (name, rgb) in colors(for: appearance).sorted(by: { $0.key < $1.key }) {
            edits.append(.string(colorsKey, name, "\(rgb.0) \(rgb.1) \(rgb.2)"))
        }
        let font = logFont(face: fontName)
        for name in metricFonts {
            edits.append(.binary(metricsKey, name, font))
        }
        for name in substitutedFonts {
            edits.append(.string(substitutesKey, name, fontName))
        }
        // Smooth text, greyscale rather than coloured sub-pixels, as macOS does.
        edits.append(.string(desktopKey, "FontSmoothing", "2"))
        edits.append(.dword(desktopKey, "FontSmoothingType", 1))
        // Wine's built-in theme only exists in a light version.
        edits.append(.string(themeKey, "ThemeActive", appearance.isDark ? "0" : "1"))
        return edits
    }

    /// The edits that hand the prefix back to Wine's own look.
    public static func removalEdits() -> [RegistryEdit] {
        var edits: [RegistryEdit] = []
        for name in colors(for: .standard).keys.sorted() { edits.append(.delete(colorsKey, name)) }
        for name in metricFonts { edits.append(.delete(metricsKey, name)) }
        for name in substitutedFonts { edits.append(.delete(substitutesKey, name)) }
        edits.append(.string(themeKey, "ThemeActive", "1"))
        return edits
    }
}
