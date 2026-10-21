import SwiftUI
import AppKit

/// The "Create Patched Copy…" dialog: the patch actually runs while this is open, so the step list,
/// errors, result, and the first-install guidance live here — not on the main window.
struct PatchProgressView: View {
    @EnvironmentObject private var engine: PatcherEngine
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            firstInstallNote
            if !engine.steps.isEmpty { StepsListView(steps: engine.steps) }
            if let error = engine.errorMessage { ErrorBox(message: error) }
            if let patched = engine.patchedApp { successBox(patched) }
            Divider()
            footer
        }
        .padding(20)
        .frame(width: 520)
        .fixedSize(horizontal: false, vertical: true)
        // A patch run cannot be cancelled safely: keep the dialog (and its status) open until it ends.
        .interactiveDismissDisabled(engine.isRunning)
    }

    // MARK: - Sections

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Creating the patched CrossOver")
                .font(.title2.weight(.semibold))
            Text("Copies CrossOver \(CrossOverInfo.expectedVersion), swaps in the patched Wine modules and MoltenVK, re-seals the copy and verifies it. Your original CrossOver is never touched.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Only shown here: this is the moment a first-time installer needs to understand that the
    /// bottle and its program launchers must come from the patched app, not the stock one.
    private var firstInstallNote: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 4) {
                Label("First time installing?", systemImage: "info.circle")
                    .font(.caption.weight(.semibold))
                Text("1. Create the patched copy.  2. Quit CrossOver.  3. Delete per-program launchers the stock CrossOver created (in ~/Applications/CrossOver).  4. Create the bottle and install Gryphline **from the patched app** — those launchers stay bound to the CrossOver that created them.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(2)
        }
    }

    private func successBox(_ url: URL) -> some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 6) {
                Label("Created \(url.lastPathComponent)", systemImage: "checkmark.seal.fill")
                    .font(.callout.weight(.medium))
                    .foregroundStyle(.green)
                Text("Important: in the game's launcher settings, set the rendering API to DirectX 11 — DirectX 12 renders a white screen under CrossOver \(CrossOverInfo.expectedVersion). Re-check after game updates.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(4)
        }
    }

    private var footer: some View {
        HStack {
            if engine.patchedApp != nil {
                Button("Reveal in Finder") {
                    if let patched = engine.patchedApp {
                        NSWorkspace.shared.activateFileViewerSelecting([patched])
                    }
                }
            }
            Spacer()
            Button(engine.isRunning ? "Patching…" : "Done") { dismiss() }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(engine.isRunning)
        }
    }
}
