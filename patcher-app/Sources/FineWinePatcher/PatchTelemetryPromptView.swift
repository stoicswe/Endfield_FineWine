import SwiftUI

/// Shown once after a patch or Automated Setup run finishes. The user sees the exact payload and
/// actively chooses whether this run's anonymous report is sent.
struct PatchTelemetryPromptView: View {
    let prompt: UsageTelemetry.Prompt
    let onSend: () -> Void
    let onFinished: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var sent = false

    private var title: String {
        if prompt.isSetup {
            return prompt.isSuccess
                ? "Send anonymous statistics for this setup?"
                : "Send anonymous statistics for this failed setup?"
        }
        return prompt.isSuccess
            ? "Send anonymous statistics for this successful patch?"
            : "Send anonymous statistics for this failed patch?"
    }

    var body: some View {
        Group {
            if sent {
                TelemetryThankYouView {
                    onFinished()
                    dismiss()
                }
            } else {
                promptContent
            }
        }
        .frame(width: 620, height: prompt.isSetup ? 600 : 500)
    }

    private var promptContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.title3.weight(.semibold))

            Text("""
            This report is optional and is the only thing the patcher would send for this run. \
            It helps us see which macOS and CrossOver versions, graphics backends, and steps fail \
            most often, so we can prioritise compatibility and performance fixes. \
            Nothing has been sent yet; it is only sent if you choose Send Statistics.
            """)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if prompt.isSetup {
                Text("This setup report also includes an excerpt of this run's logs (bottle creation, the Gryphline installer and menu registration). The excerpts are redacted before this preview is built.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Text("Preview — exactly what would be sent")
                .font(.caption.weight(.semibold))

            ScrollView {
                Text(prompt.json)
                    .font(.system(size: 11, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
            }
            .frame(maxHeight: prompt.isSetup ? 280 : 260)

            Text(prompt.isSetup
                 ? "The logs are automatically redacted: your home folder and user names, the bottle name, host name, e-mail, IP and MAC addresses, UUIDs, tokens and similar identifiers are replaced with placeholders. Automatic redaction cannot catch everything — review the preview before sending. The statistics server can still see ordinary network metadata such as your IP address, as with any HTTPS request."
                 : "No file paths, bottle names, game or account data, usernames, hardware serials, or persistent identifiers are included. The statistics server can still see ordinary network metadata such as your IP address, as with any HTTPS request.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Button("Don't Send") {
                    onFinished()
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Send Statistics") {
                    onSend()
                    withAnimation(.easeInOut(duration: 0.2)) { sent = true }
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(20)
    }
}
