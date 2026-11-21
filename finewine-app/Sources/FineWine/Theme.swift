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
enum AccentPalette: String, CaseIterable, Identifiable {
    case wine, grape, ocean, emerald, sunset

    static let defaultsKey = "FineWineAccentPalette"
    static var stored: AccentPalette {
        AccentPalette(rawValue: UserDefaults.standard.string(forKey: defaultsKey) ?? "") ?? .wine
    }

    var id: String { rawValue }
    var name: String {
        switch self {
        case .wine: return "Wine"
        case .grape: return "Grape"
        case .ocean: return "Ocean"
        case .emerald: return "Emerald"
        case .sunset: return "Sunset"
        }
    }

    var primary: Color { Color(nsColor: lightAccent) }
    var secondary: Color { Color(nsColor: darkAccent) }
    var backdropHighlight: Color {
        switch self {
        case .wine: return .indigo
        case .grape: return Color(red: 0.26, green: 0.16, blue: 0.62)
        case .ocean: return Color(red: 0.00, green: 0.60, blue: 0.70)
        case .emerald: return Color(red: 0.08, green: 0.63, blue: 0.52)
        case .sunset: return Color(red: 0.96, green: 0.54, blue: 0.04)
        }
    }
    var lightAccent: NSColor {
        switch self {
        case .wine: return NSColor(red: 0.62, green: 0.13, blue: 0.29, alpha: 1)
        case .grape: return NSColor(red: 0.38, green: 0.20, blue: 0.70, alpha: 1)
        case .ocean: return NSColor(red: 0.00, green: 0.39, blue: 0.68, alpha: 1)
        case .emerald: return NSColor(red: 0.00, green: 0.43, blue: 0.31, alpha: 1)
        case .sunset: return NSColor(red: 0.75, green: 0.24, blue: 0.08, alpha: 1)
        }
    }
    var darkAccent: NSColor {
        switch self {
        case .wine: return NSColor(red: 0.96, green: 0.52, blue: 0.62, alpha: 1)
        case .grape: return NSColor(red: 0.72, green: 0.59, blue: 1.00, alpha: 1)
        case .ocean: return NSColor(red: 0.36, green: 0.73, blue: 1.00, alpha: 1)
        case .emerald: return NSColor(red: 0.28, green: 0.83, blue: 0.61, alpha: 1)
        case .sunset: return NSColor(red: 1.00, green: 0.64, blue: 0.34, alpha: 1)
        }
    }
}

/// The window background: the system colour with two blurred glows for the glass to refract.
struct Backdrop: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let strength = colorScheme == .dark ? 0.42 : 0.26
        ZStack {
            Color(nsColor: .windowBackgroundColor)
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

    /// A glass button.
    func fwButton() -> some View { self.buttonStyle(.glass) }

    /// A prominent glass button.
    func fwProminentButton() -> some View { self.buttonStyle(.glassProminent) }
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
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
