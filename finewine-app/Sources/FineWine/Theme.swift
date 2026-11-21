import SwiftUI
import AppKit

// FineWine's look: Liquid Glass surfaces over a soft wine-coloured backdrop. Controls that float
// (cards, pills, buttons) are glass; content inside them stays plain so it reads clearly.

enum Look {
    static let cardRadius: CGFloat = 20
    /// The app-level colour choice, independently persisted from macOS's system accent.
    /// Keeping it here means the background, glass tints and prominent controls all change
    /// together rather than only recolouring one kind of button.
    static var palette: AccentPalette { AccentPalette.stored }
    static var wine: Color { palette.primary }
    static var rose: Color { palette.secondary }
    /// The third backdrop glow used to be a fixed indigo, which made the background remain
    /// pink/purple after choosing another accent. It is now part of every palette too.
    static var backdropHighlight: Color { palette.backdropHighlight }
    /// For symbols and small accents: wine on light backgrounds, a lighter rose on dark ones,
    /// where wine itself is too dim to read.
    static var accent: Color { Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? palette.darkAccent
            : palette.lightAccent
    }) }
}

/// FineWine's own palette. Unlike `NSColor.controlAccentColor`, this only changes FineWine and
/// does not alter the user's macOS-wide preference.
///
/// Wine is FineWine's own and the default. The others are the accent colours of Minimalist
/// (the same author's editor), by the same names. Each is one base colour there; here every
/// use needs a deep tone (a button's fill under white text, symbols on a light window) and a
/// light one (symbols on a dark window), so both are worked out from the base.
enum AccentPalette: String, CaseIterable, Identifiable {
    case wine, matcha, sakura, ai, kintsugi, hinoki, yugen, shibui, sumi, ataraxia

    static let defaultsKey = "FineWineAccentPalette"
    /// A stored name that is no longer a palette (the first set had other names) gives Wine.
    static var stored: AccentPalette {
        AccentPalette(rawValue: UserDefaults.standard.string(forKey: defaultsKey) ?? "") ?? .wine
    }

    var id: String { rawValue }
    var name: String {
        switch self {
        case .wine: return "Wine"
        case .matcha: return "Matcha"
        case .sakura: return "Sakura"
        case .ai: return "Ai"
        case .kintsugi: return "Kintsugi"
        case .hinoki: return "Hinoki"
        case .yugen: return "Yūgen"
        case .shibui: return "Shibui"
        case .sumi: return "Sumi"
        case .ataraxia: return "Ataraxia"
        }
    }

    /// The colour as Minimalist has it (Wine: the tone its two accents are drawn from).
    var base: NSColor {
        func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat) -> NSColor { NSColor(srgbRed: r, green: g, blue: b, alpha: 1) }
        switch self {
        case .wine: return rgb(0.62, 0.13, 0.29)
        case .matcha: return rgb(0.55, 0.72, 0.42)
        case .sakura: return rgb(0.91, 0.65, 0.71)
        case .ai: return rgb(0.36, 0.49, 0.65)
        case .kintsugi: return rgb(0.83, 0.63, 0.33)
        case .hinoki: return rgb(0.79, 0.57, 0.37)
        case .yugen: return rgb(0.48, 0.42, 0.58)
        case .shibui: return rgb(0.43, 0.64, 0.59)
        case .sumi: return rgb(0.30, 0.32, 0.36)
        case .ataraxia: return rgb(0.50, 0.62, 0.72)
        }
    }

    /// What a picker shows for the palette.
    var swatch: Color { Color(nsColor: base) }
    var primary: Color { Color(nsColor: lightAccent) }
    var secondary: Color { Color(nsColor: darkAccent) }

    private func toned(saturation: (CGFloat) -> CGFloat, brightness: (CGFloat) -> CGFloat, hueShift: CGFloat = 0) -> NSColor {
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        base.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
        let hue = (h + hueShift).truncatingRemainder(dividingBy: 1)
        return NSColor(colorSpace: .sRGB, hue: hue, saturation: min(max(saturation(s), 0), 1),
                       brightness: min(max(brightness(b), 0), 1), alpha: 1)
    }

    /// The third glow of the window background, a neighbour of the accent.
    var backdropHighlight: Color {
        if self == .wine { return .indigo }
        return Color(nsColor: toned(saturation: { $0 * 1.2 }, brightness: { max($0, 0.6) }, hueShift: 0.08))
    }
    /// Deep enough for white text on it and to read on a light window.
    var lightAccent: NSColor {
        if self == .wine { return base }
        return toned(saturation: { $0 * 1.45 }, brightness: { min($0, 0.50) })
    }
    /// Light enough to read on a dark window.
    var darkAccent: NSColor {
        if self == .wine { return NSColor(srgbRed: 0.96, green: 0.52, blue: 0.62, alpha: 1) }
        // Sumi is an ink grey: it stays a grey rather than turning into a pale blue
        if self == .sumi { return toned(saturation: { $0 }, brightness: { _ in 0.80 }) }
        return toned(saturation: { min($0, 0.50) }, brightness: { _ in 0.92 })
    }
}

/// The window background: the system colour with two blurred glows for the glass to refract.
struct Backdrop: View {
    @Environment(\.colorScheme) private var colorScheme
    // read so the glows are drawn again when another accent is chosen
    @AppStorage(AccentPalette.defaultsKey) private var accentPalette = AccentPalette.wine.rawValue
    /// Off where there is a material behind already (the menu bar panel): only the glows.
    var opaque = true

    var body: some View {
        let strength = colorScheme == .dark ? 0.42 : 0.26
        ZStack {
            if opaque { Color(nsColor: .windowBackgroundColor) }
            GeometryReader { geo in
                let side = max(geo.size.width, geo.size.height)
                Circle().fill(Look.wine.opacity(strength))
                    .frame(width: side * 0.9, height: side * 0.9)
                    .blur(radius: side * 0.2)
                    .position(x: geo.size.width * 0.1, y: 0)
                Circle().fill(Look.rose.opacity(strength * 0.6))
                    .frame(width: side * 0.6, height: side * 0.6)
                    .blur(radius: side * 0.2)
                    .position(x: geo.size.width, y: geo.size.height)
                Circle().fill(Look.backdropHighlight.opacity(strength * 0.45))
                    .frame(width: side * 0.5, height: side * 0.5)
                    .blur(radius: side * 0.18)
                    .position(x: geo.size.width * 0.75, y: geo.size.height * 0.1)
            }
        }
        .ignoresSafeArea()
        .accessibilityHidden(true)
    }
}

// MARK: Liquid Glass
//
// FineWine runs on macOS 26 and later (the user's decision, 2026-11-17), so it uses Liquid Glass
// throughout. Every use of glass goes through these few helpers, so its look is set in one place.

extension View {
    /// A glass card around the view.
    func glassCard(padding: CGFloat = 16, tint: Color? = nil, interactive: Bool = false) -> some View {
        self
            .padding(padding)
            .fwGlass(tint: tint.map { $0.opacity(0.22) }, interactive: interactive,
                     in: RoundedRectangle(cornerRadius: Look.cardRadius, style: .continuous))
    }

    /// Liquid Glass in `shape`.
    func fwGlass<S: Shape>(tint: Color? = nil, interactive: Bool = false, in shape: S) -> some View {
        self.glassEffect(Self.fwGlassKind(tint: tint, interactive: interactive), in: shape)
    }

    private static func fwGlassKind(tint: Color?, interactive: Bool) -> Glass {
        var glass = Glass.regular
        if let tint { glass = glass.tint(tint) }
        if interactive { glass = glass.interactive() }
        return glass
    }

    /// A glass button. Plain glass whatever the accent: the window's tint would fill it with
    /// the accent's light tone, next to prominent buttons in its deep one.
    func fwButton() -> some View { self.buttonStyle(.glass).tint(nil) }

    /// A prominent glass button, in the accent's deep tone everywhere.
    func fwProminentButton() -> some View { self.buttonStyle(.glassProminent).tint(Look.wine) }
}

/// Groups glass shapes so they blend into each other.
struct FWGlassContainer<Content: View>: View {
    var spacing: CGFloat
    @ViewBuilder var content: () -> Content

    var body: some View {
        GlassEffectContainer(spacing: spacing) { content() }
    }
}

/// A titled glass card, used for each group of settings.
struct Card<Content: View>: View {
    let title: String
    var symbol: String?
    var footnote: String?
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label {
                Text(title).font(.headline)
            } icon: {
                if let symbol { Image(systemName: symbol).foregroundStyle(Look.accent) }
            }
            content()
            if let footnote {
                Text(footnote).font(.footnote).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard()
    }
}

/// A label on the left and a control on the right.
struct Row<Content: View>: View {
    let label: String
    var detail: String?
    @ViewBuilder var content: () -> Content

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                if let detail {
                    Text(detail).font(.footnote).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 12)
            content()
        }
    }
}

/// A small capsule for a state such as "Running".
struct Pill: View {
    let text: String
    var symbol: String?
    var tint: Color = .secondary

    var body: some View {
        HStack(spacing: 4) {
            if let symbol { Image(systemName: symbol) }
            Text(text)
        }
        .font(.caption.weight(.medium))
        .foregroundStyle(tint)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .fwGlass(tint: tint.opacity(0.18), in: Capsule())
    }
}

/// The icon for a program: its shortcut app's icon when there is one, otherwise a placeholder.
struct ProgramIcon: View {
    let shortcutPath: String?
    var size: CGFloat = 36
    // Read so the icon is looked up again when a shortcut app is made again.
    @ObservedObject private var model = AppModel.shared

    var body: some View {
        if let shortcutPath, FileManager.default.fileExists(atPath: shortcutPath) {
            Image(nsImage: ProgramIcon.image(ofShortcut: shortcutPath))
                .resizable()
                .frame(width: size, height: size)
                .id(model.iconRevision)
        } else {
            Image(systemName: "macwindow")
                .font(.system(size: size * 0.5, weight: .medium))
                .foregroundStyle(Look.accent)
                .frame(width: size, height: size)
                .fwGlass(tint: Look.wine.opacity(0.2), in: RoundedRectangle(cornerRadius: size * 0.28, style: .continuous))
        }
    }
}

extension ProgramIcon {
    /// The shortcut app's own icon file when it has one: the system's icon for the app can
    /// be a remembered one for a while after the app was made again.
    static func image(ofShortcut path: String) -> NSImage {
        NSImage(contentsOfFile: path + "/Contents/Resources/AppIcon.icns") ?? NSWorkspace.shared.icon(forFile: path)
    }
}

/// Shown where there is nothing to list yet.
struct EmptyState<Actions: View>: View {
    let symbol: String
    let title: String
    let message: String
    @ViewBuilder var actions: () -> Actions

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: symbol)
                .font(.system(size: 34, weight: .medium))
                .foregroundStyle(Look.accent)
                .frame(width: 76, height: 76)
                .fwGlass(tint: Look.wine.opacity(0.2), in: Circle())
            Text(title).font(.title2.weight(.semibold))
            Text(message)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
                .fixedSize(horizontal: false, vertical: true)
            actions()
        }
        .padding(32)
        // The sizes are stated: asked how tall it would like to be at a narrow width, the
        // message (one word a line) answered some 1650 points, a split view took that as the
        // height of its columns, and what sits at the bottom of the sidebar was pushed out
        // of the window (2026-11-21).
        .frame(minWidth: 0, idealWidth: 480, maxWidth: .infinity, minHeight: 0, idealHeight: 360, maxHeight: .infinity)
    }
}
