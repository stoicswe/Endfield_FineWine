import SwiftUI
import AppKit

/// Tools window: Installs the FineWine Sikarugir engine into Sikarugir's Engines directory.
///
/// Sikarugir (a free Wineskin successor) manages Wine engines independently of CrossOver.
/// This window lets the user locate the engine tarball built by `scripts/build-wine.sh engine`
/// and install it with one click, without needing the Terminal.
struct SikarugirView: View {
    @EnvironmentObject private var engine: PatcherEngine
    @EnvironmentObject private var l10n: LanguageManager

    @State private var status: Sikarugir.Status?
    @State private var selectedTarball: URL?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            statusBox
            actionsBox
            if !engine.sikarugirSteps.isEmpty {
                StepsListView(steps: engine.sikarugirSteps)
            }
            if let error = engine.sikarugirError {
                ErrorBox(message: error)
            }
            instructionsBox
        }
        .padding(20)
        .frame(width: 520)
        .fixedSize(horizontal: false, vertical: true)
        .fineWineChrome()
        .onAppear { refresh() }
        .onChange(of: engine.sikarugirIsRunning) { running in
            if !running { refresh() }
        }
    }

    // MARK: - Sections

    private var header: some View {
        PageHeader(title: l10n.tr("sikarugir.title"), subtitle: l10n.tr("sikarugir.desc"), symbol: "shippingbox")
    }

    private var statusBox: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Label("Engine Status", systemImage: "cpu")
                        .font(.callout.weight(.medium))
                    Spacer()
                    if status?.engineInstalled == true {
                        Label("Installed", systemImage: "checkmark.seal.fill")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.green)
                    } else {
                        Label("Not Installed", systemImage: "circle.dashed")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Divider()

                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("Sikarugir:")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        if status?.sikarugirInstalled == true {
                            Text("Detected")
                                .font(.caption)
                                .foregroundStyle(.green)
                        } else {
                            Text("Not Found")
                                .font(.caption)
                                .foregroundStyle(.orange)
                        }
                    }

                    HStack {
                        Text("Engine Tarball:")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        if let tb = activeTarball {
                            Text(tb.lastPathComponent)
                                .font(.caption.weight(.medium))
                                .lineLimit(1)
                                .truncationMode(.middle)
                        } else {
                            Text("Not Found")
                                .font(.caption)
                                .foregroundStyle(.orange)
                        }
                    }

                    if status?.engineInstalled == true {
                        HStack {
                            Text("Engine:")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Spacer()
                            Text(Sikarugir.engineName)
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
            if status?.engineInstalled == true {
                Button(role: .destructive, action: removeEngine) {
                    Text("Remove Engine")
                        .frame(maxWidth: .infinity)
                }
                .controlSize(.large)
                .disabled(engine.sikarugirIsRunning)

                Button(action: installEngine) {
                    Text(engine.sikarugirIsRunning ? "Reinstalling…" : "Reinstall Engine")
                        .frame(maxWidth: .infinity)
                }
                .prominentGlassButton()
                .controlSize(.large)
                .disabled(engine.sikarugirIsRunning || activeTarball == nil)
            } else {
                Button(action: installEngine) {
                    Text(engine.sikarugirIsRunning ? "Installing…" : "Install Engine")
                        .frame(maxWidth: .infinity)
                }
                .prominentGlassButton()
                .controlSize(.large)
                .disabled(engine.sikarugirIsRunning || activeTarball == nil)

                Button("Choose Tarball…", action: chooseTarball)
                    .controlSize(.large)
                    .disabled(engine.sikarugirIsRunning)
            }
        }
    }

    private var instructionsBox: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 6) {
                Label("Getting Started", systemImage: "info.circle")
                    .font(.caption.weight(.medium))

                Text("""
                    1. Build the engine tarball on your Mac:
                       `scripts/build-wine.sh engine && scripts/package-sikarugir-engine.sh`
                    2. The patcher auto-detects it in Downloads / Desktop. Or click "Choose Tarball…".
                    3. Click "Install Engine" — the engine appears in Sikarugir's Engine list.
                    4. In Sikarugir, create a new wrapper and select "WS12WineFineWine26.3.0_1".
                    5. For the Steam version, set the program to Steam and launch options to `-silent -applaunch 4732690`.
                    6. Add `-force-d3d11` to the game's Steam launch options.
                    """)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if Sikarugir.sikarugirApp == nil {
                    Divider()
                    HStack {
                        Text("Sikarugir not found — install it with:")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Button("brew install --cask sikarugir") {
                            NSWorkspace.shared.open(URL(string: "https://github.com/Sikarugir-App/Sikarugir")!)
                        }
                        .font(.caption)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(4)
        }
    }

    // MARK: - Actions

    private var activeTarball: URL? {
        selectedTarball ?? status?.engineTarball
    }

    private func refresh() {
        status = Sikarugir.detectStatus(customTarball: selectedTarball)
    }

    private func installEngine() {
        guard let tarball = activeTarball else { return }
        engine.installSikarugirEngine(tarball: tarball)
    }

    private func removeEngine() {
        engine.removeSikarugirEngine()
    }

    private func chooseTarball() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.init(filenameExtension: "xz")].compactMap { $0 }
        panel.prompt = "Select"
        panel.message = "Select the FineWine Sikarugir engine tarball (\(Sikarugir.engineName).tar.xz)"
        panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Downloads")
        if panel.runModal() == .OK, let url = panel.url {
            if url.lastPathComponent.hasSuffix(".tar.xz") || url.pathExtension == "xz" {
                selectedTarball = url
                refresh()
            } else {
                let alert = NSAlert()
                alert.messageText = "Not a .tar.xz file"
                alert.informativeText = "Please select the \(Sikarugir.engineName).tar.xz engine tarball built by scripts/package-sikarugir-engine.sh."
                alert.runModal()
            }
        }
    }
}

