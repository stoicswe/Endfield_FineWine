import SwiftUI

/// Celebration shown after the user explicitly chooses to send a patch-run report.
struct TelemetryThankYouView: View {
    let onClose: () -> Void

    @State private var appeared = false
    @State private var pieces = ConfettiPiece.makePieces()

    var body: some View {
        ZStack {
            CelebrationConfetti(pieces: pieces)
                .allowsHitTesting(false)

            VStack(spacing: 16) {
                Image(systemName: "sparkles")
                    .font(.system(size: 56, weight: .semibold))
                    .foregroundStyle(.yellow)
                    .scaleEffect(appeared ? 1 : 0.6)
                    .rotationEffect(.degrees(appeared ? 0 : -15))

                Text("Thank you!")
                    .font(.system(size: 34, weight: .bold, design: .rounded))

                Text("Your anonymous report helps us find compatibility and performance problems across macOS and CrossOver versions, so we can make Endfield run better for everyone.")
                    .font(.body)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Text("We sincerely appreciate you contributing to the project.")
                    .font(.callout.weight(.medium))
                    .multilineTextAlignment(.center)

                Button("Close") { onClose() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .padding(.top, 4)
            }
            .padding(30)
            .frame(maxWidth: 480)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20))
            .shadow(color: .black.opacity(0.2), radius: 24, y: 8)
            .scaleEffect(appeared ? 1 : 0.92)
            .opacity(appeared ? 1 : 0)
        }
        .onAppear {
            withAnimation(.spring(response: 0.5, dampingFraction: 0.75)) {
                appeared = true
            }
        }
    }
}

private struct CelebrationConfetti: View {
    let pieces: [ConfettiPiece]
    @State private var animate = false

    var body: some View {
        GeometryReader { geo in
            ZStack {
                ForEach(pieces) { piece in
                    RoundedRectangle(cornerRadius: piece.isCircle ? piece.width / 2 : 2)
                    .fill(piece.color)
                    .frame(width: piece.width, height: piece.height)
                    .rotationEffect(.degrees(animate ? piece.spin : 0))
                    .position(
                        x: (animate ? piece.endX : piece.startX) * geo.size.width,
                        y: animate ? geo.size.height + 120 : -50
                    )
                    .animation(
                        .easeIn(duration: piece.duration).delay(piece.delay),
                        value: animate
                    )
                }
            }
            .onAppear { animate = true }
        }
    }
}

private struct ConfettiPiece: Identifiable {
    let id = UUID()
    let startX: CGFloat
    let endX: CGFloat
    let color: Color
    let width: CGFloat
    let height: CGFloat
    let delay: Double
    let duration: Double
    let spin: Double
    let isCircle: Bool

    static func makePieces() -> [ConfettiPiece] {
        let colors: [Color] = [.red, .orange, .yellow, .green, .blue, .purple, .pink]
        return (0..<70).map { _ in
            let startX = CGFloat.random(in: 0...1)
            return ConfettiPiece(
                startX: startX,
                endX: startX + CGFloat.random(in: -0.22...0.22),
                color: colors.randomElement() ?? .yellow,
                width: CGFloat.random(in: 5...11),
                height: CGFloat.random(in: 8...18),
                delay: Double.random(in: 0...1.4),
                duration: Double.random(in: 2.2...3.8),
                spin: Double.random(in: 360...1_080),
                isCircle: Bool.random()
            )
        }
    }
}
