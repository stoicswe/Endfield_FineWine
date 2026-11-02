import SwiftUI
import AppKit

/// Tools window: Registers the FineWine-patched CrossOver as a NotProton runner for Steam Play.
struct NotProtonView: View {
    @EnvironmentObject private var engine: PatcherEngine

    @State private var status: NotProton.Status?
    @State private var selectedApp: URL?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            statusBox
            actionsBox
            if !engine.notProtonSteps.isEmpty {
                StepsListView(steps: engine.notProtonSteps)
            }
            if let error = engine.notProtonError {
                ErrorBox(message: error)
            }
            instructionsBox
        }
        .padding(20)
        .frame(width: 520)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear { refresh() }
        .onChange(of: engine.notProtonIsRunning) { running in
            if !running { refresh() }
        }
    }

    // MARK: - Sections

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Steam / NotProton")
                .font(.title2.weight(.semibold))
            Text("Registers your FineWine-patched CrossOver into NotProton so Arknights: Endfield can launch directly via Steam Play on macOS.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var statusBox: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Label("Integration Status", systemImage: "steamlogo")
                        .font(.callout.weight(.medium))
                    Spacer()
                    if status?.isRegistered == true {
                        Label("Registered", systemImage: "checkmark.seal.fill")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.green)
                    } else {
                        Label("Not Registered", systemImage: "circle.dashed")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Divider()

                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("Patched CrossOver:")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        if let app = activeApp {
                            Text(app.lastPathComponent)
                                .font(.caption.weight(.medium))
                        } else {
                            Text("Not Found")
                                .font(.caption)
                                .foregroundStyle(.red)
                        }
                    }

                    HStack {
                        Text("Steam Directory:")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        if status?.steamInstalled == true {
                            Text("Detected")
                                .font(.caption)
                                .foregroundStyle(.green)
                        } else {
                            Text("Not Found")
                                .font(.caption)
                                .foregroundStyle(.orange)
                        }
                    }

                    if let st = status, st.isRegistered {
                        HStack {
                            Text("Steam Tool Entry:")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Spacer()
                            Text(st.displayName)
                                .font(.caption.weight(.medium))
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(4)
        }
    }

    private var actionsBox: some View {
        HStack(spacing: 12) {
            if status?.isRegistered == true {
                Button(role: .destructive, action: unregister) {
                    Text("Unregister from Steam")
                        .frame(maxWidth: .infinity)
                }
                .controlSize(.large)
                .disabled(engine.notProtonIsRunning)

                Button(action: register) {
                    Text(engine.notProtonIsRunning ? "Updating…" : "Re-register / Update")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(engine.notProtonIsRunning || activeApp == nil)
            } else {
                Button(action: register) {
                    Text(engine.notProtonIsRunning ? "Registering…" : "Register in Steam Play")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(engine.notProtonIsRunning || activeApp == nil)

                Button("Choose Patched App…", action: choosePatchedApp)
                    .controlSize(.large)
                    .disabled(engine.notProtonIsRunning)
            }
        }
    }

    private var instructionsBox: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 6) {
                Label("After Registering", systemImage: "info.circle")
                    .font(.caption.weight(.medium))

                Text("1. Restart Steam (`⌘Q` and reopen).\n2. Right-click Arknights: Endfield → Properties… → Compatibility.\n3. Check “Force the use of a specific Steam Play compatibility tool” and choose “CrossOver 26.3 - Endfield FineWine - Rosetta”.\n4. Under Properties… → General → Launch Options, add `-force-d3d11`.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(4)
        }
    }

    // MARK: - Actions

    private var activeApp: URL? {
        selectedApp ?? engine.patchedApp ?? status?.patchedApp
    }

    private func refresh() {
        status = NotProton.detectStatus(customPatchedApp: selectedApp ?? engine.patchedApp)
    }

    private func register() {
        guard let app = activeApp else { return }
        engine.registerNotProton(app: app)
    }

    private func unregister() {
        engine.unregisterNotProton()
    }

    private func choosePatchedApp() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.application]
        panel.prompt = "Choose"
        panel.message = "Select the FineWine-patched CrossOver app (CrossOver_Endfield_Patch.app)"
        if panel.runModal() == .OK, let url = panel.url {
            if NotProton.isPatchedCrossOver(url) {
                selectedApp = url
                refresh()
            } else {
                let alert = NSAlert()
                alert.messageText = "Not a patched CrossOver app"
                alert.informativeText = "The selected application does not appear to be a FineWine-patched CrossOver."
                alert.runModal()
            }
        }
    }
}
