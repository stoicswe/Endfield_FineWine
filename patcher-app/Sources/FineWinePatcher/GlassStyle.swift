import SwiftUI
import AppKit

// The patcher's shared look. On macOS 26 and later it uses Liquid Glass: cards, the header badge
// and the main buttons are glass over a soft tinted backdrop. Earlier systems (the package still
// supports macOS 13) get materials and the standard bordered buttons in the same layout.
//
// The glass APIs only exist in the macOS 26 SDK, so each use is behind `#if compiler(>=6.2)` as
// well as `#available`, which keeps the package building with an older Xcode.

enum FineWineLook {
    static let cardRadius: CGFloat = 16
    static let cardPadding: CGFloat = 12
}

// MARK: - Backdrop

/// The window background: the system window colour with two soft tinted glows, which gives the
/// glass something to pick up without competing with the content.
struct FineWineBackdrop: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let strength = colorScheme == .dark ? 0.30 : 0.20
        ZStack {
            Color(nsColor: .windowBackgroundColor)
            GeometryReader { geo in
                let side = max(geo.size.width, geo.size.height)
                Circle()
                    .fill(Color.accentColor.opacity(strength))
                    .frame(width: side * 0.9, height: side * 0.9)
                    .blur(radius: side * 0.22)
                    .position(x: geo.size.width * 0.08, y: 0)
                Circle()
                    .fill(Color.teal.opacity(strength * 0.7))
                    .frame(width: side * 0.7, height: side * 0.7)
                    .blur(radius: side * 0.22)
                    .position(x: geo.size.width * 1.0, y: geo.size.height * 0.95)
            }
        }
        .ignoresSafeArea()
        .accessibilityHidden(true)
    }
}

// MARK: - Glass surfaces

private struct GlassSurface<S: Shape>: ViewModifier {
    let shape: S
    var tint: Color?

    func body(content: Content) -> some View {
        #if compiler(>=6.2)
        if #available(macOS 26.0, *) {
            content.glassEffect(tint.map { Glass.regular.tint($0.opacity(0.25)) } ?? .regular, in: shape)
        } else {
            fallback(content)
        }
        #else
        fallback(content)
        #endif
    }

    private func fallback(_ content: Content) -> some View {
        content
            .background(.regularMaterial, in: shape)
            .background((tint ?? .clear).opacity(0.12), in: shape)
            .overlay(shape.stroke(Color.primary.opacity(0.08), lineWidth: 1))
    }
}

extension View {
    /// A glass surface in `shape`, optionally tinted (a material on systems before macOS 26).
    func fineWineGlass<S: Shape>(in shape: S, tint: Color? = nil) -> some View {
        modifier(GlassSurface(shape: shape, tint: tint))
    }

    /// The main action of a window or sheet.
    @ViewBuilder
    func prominentGlassButton() -> some View {
        #if compiler(>=6.2)
        if #available(macOS 26.0, *) {
            buttonStyle(.glass).tint(.accentColor).buttonBorderShape(.capsule)
        } else {
            buttonStyle(.borderedProminent)
        }
        #else
        buttonStyle(.borderedProminent)
        #endif
    }

    /// A secondary action that sits directly on the backdrop, next to a prominent one.
    @ViewBuilder
    func glassButton() -> some View {
        #if compiler(>=6.2)
        if #available(macOS 26.0, *) {
            buttonStyle(.glass).buttonBorderShape(.capsule)
        } else {
            buttonStyle(.bordered)
        }
        #else
        buttonStyle(.bordered)
        #endif
    }

    /// Applied once at the root of every window and sheet: the backdrop, and glass cards for
    /// every `GroupBox` inside.
    func fineWineChrome() -> some View {
        self
            .groupBoxStyle(GlassGroupBoxStyle())
            .background { FineWineBackdrop() }
    }
}

/// Draws a `GroupBox` as a glass card.
struct GlassGroupBoxStyle: GroupBoxStyle {
    func makeBody(configuration: Configuration) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            configuration.label.font(.headline)
            configuration.content
        }
        .padding(FineWineLook.cardPadding)
        .fineWineGlass(in: RoundedRectangle(cornerRadius: FineWineLook.cardRadius, style: .continuous))
    }
}

// MARK: - Shared pieces

/// The title block at the top of each window and sheet: a glass badge, the title and a subtitle.
struct PageHeader<Accessory: View>: View {
    let title: String
    let subtitle: String
    /// An SF Symbol for the badge; `nil` shows the app icon.
    var symbol: String?
    @ViewBuilder var accessory: () -> Accessory

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            badge
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.title2.weight(.semibold))
                Text(subtitle)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                accessory()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var badge: some View {
        if let symbol {
            Image(systemName: symbol)
                .font(.system(size: 20, weight: .medium))
                .foregroundStyle(.tint)
                .frame(width: 44, height: 44)
                .fineWineGlass(in: RoundedRectangle(cornerRadius: 12, style: .continuous), tint: .accentColor)
                .accessibilityHidden(true)
        } else {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 48, height: 48)
                .shadow(color: .black.opacity(0.18), radius: 6, y: 3)
                .accessibilityHidden(true)
        }
    }
}

extension PageHeader where Accessory == EmptyView {
    init(title: String, subtitle: String, symbol: String? = nil) {
        self.init(title: title, subtitle: subtitle, symbol: symbol, accessory: { EmptyView() })
    }
}

/// A small tinted capsule for a state such as "applied" or "experimental".
struct StatusPill: View {
    let text: String
    let symbol: String
    let tint: Color

    var body: some View {
        Label(text, systemImage: symbol)
            .font(.caption.weight(.medium))
            .foregroundStyle(tint)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(tint.opacity(0.14), in: Capsule())
            .fixedSize(horizontal: false, vertical: true)
    }
}
