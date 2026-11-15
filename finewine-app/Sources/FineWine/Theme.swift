import SwiftUI
import AppKit

// FineWine's look: Liquid Glass surfaces over a soft wine-coloured backdrop. Controls that float
// (cards, pills, buttons) are glass; content inside them stays plain so it reads clearly.

enum Look {
    static let cardRadius: CGFloat = 20
    static let wine = Color(red: 0.62, green: 0.13, blue: 0.29)
    static let rose = Color(red: 0.93, green: 0.42, blue: 0.52)
    /// For symbols and small accents: wine on light backgrounds, a lighter rose on dark ones,
    /// where wine itself is too dim to read.
    static let accent = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(red: 0.96, green: 0.52, blue: 0.62, alpha: 1)
            : NSColor(red: 0.62, green: 0.13, blue: 0.29, alpha: 1)
    })
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
                Circle().fill(Color.indigo.opacity(strength * 0.45))
                    .frame(width: side * 0.5, height: side * 0.5)
                    .blur(radius: side * 0.18)
                    .position(x: geo.size.width * 0.75, y: geo.size.height * 0.1)
            }
        }
        .ignoresSafeArea()
        .accessibilityHidden(true)
    }
}

extension View {
    /// A glass card around the view.
    func glassCard(padding: CGFloat = 16, tint: Color? = nil, interactive: Bool = false) -> some View {
        var glass = Glass.regular
        if let tint { glass = glass.tint(tint.opacity(0.22)) }
        if interactive { glass = glass.interactive() }
        return self
            .padding(padding)
            .glassEffect(glass, in: .rect(cornerRadius: Look.cardRadius))
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
        .glassEffect(.regular.tint(tint.opacity(0.18)), in: .capsule)
    }
}

/// The icon for a program: its shortcut app's icon when there is one, otherwise a placeholder.
struct ProgramIcon: View {
    let shortcutPath: String?
    var size: CGFloat = 36

    var body: some View {
        if let shortcutPath, FileManager.default.fileExists(atPath: shortcutPath) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: shortcutPath))
                .resizable()
                .frame(width: size, height: size)
        } else {
            Image(systemName: "macwindow")
                .font(.system(size: size * 0.5, weight: .medium))
                .foregroundStyle(Look.accent)
                .frame(width: size, height: size)
                .glassEffect(.regular.tint(Look.wine.opacity(0.2)), in: .rect(cornerRadius: size * 0.28))
        }
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
                .glassEffect(.regular.tint(Look.wine.opacity(0.2)), in: .circle)
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
