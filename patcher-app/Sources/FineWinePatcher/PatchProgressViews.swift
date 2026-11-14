import SwiftUI

/// Shared patch-progress UI, used by both the main window (app-patch steps) and the
/// Mod Framework window (mod-chain steps).

/// The step checklist for a running (or finished) patch / mod-chain phase.
struct StepsListView: View {
    let steps: [PatcherEngine.Step]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(steps) { step in
                HStack(spacing: 8) {
                    StepIcon(status: step.status)
                        .frame(width: 16, height: 16)
                    Text(step.label)
                        .font(.callout)
                        .foregroundStyle(step.status == .pending ? .secondary : .primary)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(FineWineLook.cardPadding)
        .fineWineGlass(in: RoundedRectangle(cornerRadius: FineWineLook.cardRadius, style: .continuous))
    }
}

/// The per-step status icon (pending / running / done / failed).
struct StepIcon: View {
    let status: PatcherEngine.Step.Status

    var body: some View {
        switch status {
        case .pending:
            Image(systemName: "circle").foregroundStyle(.tertiary)
        case .running:
            ProgressView().controlSize(.small)
        case .done:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .failed:
            Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
        }
    }
}

/// A red error label with selectable text.
struct ErrorBox: View {
    let message: String

    var body: some View {
        Label(message, systemImage: "xmark.octagon.fill")
            .font(.caption)
            .foregroundStyle(.red)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
            .background(Color.red.opacity(0.10), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}
