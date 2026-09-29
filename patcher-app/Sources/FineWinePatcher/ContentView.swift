import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct ContentView: View {
    @StateObject private var engine = PatcherEngine()
    @State private var crossover: CrossOverInfo?
    @State private var showLicenses = false
    @State private var showVersionWarning = false
    @State private var pendingDestination: URL?
    @State private var gptkSources: [GPTKSource] = []
    @State private var selectedGPTK: GPTKSource?
    @State private var gptkAutoSelected = false

    private let payloadReady = Payload.isComplete

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            crossoverBox
            gptkBox
            if !payloadReady { payloadMissingBox }
            patchButton
            if !engine.steps.isEmpty { stepsList }
            if let error = engine.errorMessage { errorBox(error) }
            if let patched = engine.patchedApp { successBox(patched) }
            Divider()
            footer
        }
        .padding(20)
        .frame(width: 460)
        .fixedSize(horizontal: false, vertical: true)
        .sheet(isPresented: $showLicenses) { LicensesView() }
        .confirmationDialog("CrossOver version mismatch", isPresented: $showVersionWarning, titleVisibility: .visible) {
            Button("Patch Anyway", role: .destructive) {
                if let destination = pendingDestination, let cx = crossover {
                    engine.patch(source: cx.url, destination: destination, gptk: selectedGPTK)
                }
                pendingDestination = nil
            }
            Button("Cancel", role: .cancel) { pendingDestination = nil }
        } message: {
            Text("This CrossOver reports version \(crossover?.version ?? "unknown"), but the bundled modules are built against CrossOver \(CrossOverInfo.expectedVersion)'s Wine ABI. Patching a different version will almost certainly not work.")
        }
        .onAppear {
            detectDefaultCrossOver()
            refreshGPTK()
        }
    }

    // MARK: - Sections

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("FineWine Patcher")
                .font(.title2.weight(.semibold))
            Text("Creates a patched copy of CrossOver \(CrossOverInfo.expectedVersion) so Arknights: Endfield runs on Apple Silicon.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    private var crossoverBox: some View {
        GroupBox {
            Group {
                if let cx = crossover {
                    HStack(spacing: 10) {
                        Image(nsImage: NSWorkspace.shared.icon(forFile: cx.url.path))
                            .resizable()
                            .frame(width: 36, height: 36)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(cx.displayName).font(.body.weight(.medium))
                            statusLine(for: cx)
                        }
                        Spacer()
                        Button("Change…", action: chooseCrossOver)
                            .disabled(engine.isRunning)
                    }
                } else {
                    HStack(spacing: 8) {
                        Image(systemName: "app.dashed")
                            .font(.title2)
                            .foregroundStyle(.secondary)
                        Text("Drop CrossOver.app here, or")
                            .foregroundStyle(.secondary)
                        Button("Choose…", action: chooseCrossOver)
                        Spacer()
                    }
                    .padding(.vertical, 6)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(4)
        }
        .dropDestination(for: URL.self) { urls, _ in
            guard !engine.isRunning, let url = urls.first, url.pathExtension == "app" else { return false }
            select(url)
            return true
        }
    }

    private var gptkBox: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("GPTK4 / D3DMetal (optional)")
                        .font(.callout.weight(.medium))
                    Spacer()
                    Button("Choose…", action: chooseGPTKFolder)
                        .disabled(engine.isRunning)
                    Button("Rescan", action: refreshGPTK)
                        .disabled(engine.isRunning)
                }
                Picker("D3DMetal", selection: $selectedGPTK) {
                    Text("Keep CrossOver's bundled D3DMetal").tag(GPTKSource?.none)
                    ForEach(gptkSources) { source in
                        Text(source.displayName).tag(GPTKSource?.some(source))
                    }
                }
                .labelsHidden()
                .disabled(engine.isRunning)
                Text(gptkHint)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(4)
        }
    }

    private var gptkHint: String {
        if let selected = selectedGPTK {
            if selected.isVersion4 {
                return "Replaces CrossOver's D3DMetal \(selected.version ?? "3.0") with \(selected.displayName). D3DMetal 4 adds the Metal 4 / MetalFX features (DLSS and frame generation)."
            }
            return "Selected \(selected.displayName). Note: only GPTK4 (D3DMetal 4.x) adds the Metal 4 / MetalFX features — this looks like an older version."
        }
        if gptkSources.isEmpty {
            return "Mount Apple's “Evaluation environment for Windows games …” DMG, then Rescan, or Choose… the redist/lib/external folder. Apple's GPTK is not bundled or redistributed by this app."
        }
        return "Apple's GPTK is not bundled — the app only installs the copy you supply."
    }

    @ViewBuilder
    private func statusLine(for cx: CrossOverInfo) -> some View {
        if !cx.hasWineModules {
            Label("No Wine modules found — not a CrossOver app?", systemImage: "xmark.circle.fill")
                .font(.caption).foregroundStyle(.red)
        } else if cx.isExpectedVersion {
            Label("Version \(cx.version ?? "?")", systemImage: "checkmark.seal.fill")
                .font(.caption).foregroundStyle(.green)
        } else {
            Label("Version \(cx.version ?? "unknown") — expected \(CrossOverInfo.expectedVersion) (Wine ABI must match)",
                  systemImage: "exclamationmark.triangle.fill")
                .font(.caption).foregroundStyle(.orange)
        }
    }

    private var payloadMissingBox: some View {
        Label("This build of the patcher has no module payload (Wine + MoltenVK) — rebuild it with patcher-app/scripts/build-app.sh after scripts/build-wine.sh all and scripts/build-moltenvk.sh all.",
              systemImage: "exclamationmark.triangle.fill")
            .font(.caption)
            .foregroundStyle(.orange)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var patchButton: some View {
        Button(action: startPatch) {
            Text(engine.isRunning ? "Patching…" : "Create Patched Copy…")
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .disabled(!payloadReady || engine.isRunning || crossover?.hasWineModules != true)
    }

    private var stepsList: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(engine.steps) { step in
                HStack(spacing: 8) {
                    stepIcon(step.status)
                        .frame(width: 16, height: 16)
                    Text(step.label)
                        .font(.callout)
                        .foregroundStyle(step.status == .pending ? .secondary : .primary)
                }
            }
        }
        .padding(.leading, 4)
    }

    @ViewBuilder
    private func stepIcon(_ status: PatcherEngine.Step.Status) -> some View {
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

    private func errorBox(_ message: String) -> some View {
        Label(message, systemImage: "xmark.octagon.fill")
            .font(.caption)
            .foregroundStyle(.red)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func successBox(_ url: URL) -> some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Label("Created \(url.lastPathComponent)", systemImage: "checkmark.seal.fill")
                        .font(.callout.weight(.medium))
                        .foregroundStyle(.green)
                    Spacer()
                    Button("Reveal in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([url])
                    }
                }
                Text("Important: in the game's launcher settings, set the rendering API to DirectX 11 — Vulkan and DirectX 12 do not work under CrossOver \(CrossOverInfo.expectedVersion). Re-check after game updates.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(4)
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Button("Licenses…") { showLicenses = true }
                Spacer()
                Button("Buy CrossOver…") {
                    NSWorkspace.shared.open(URL(string: "https://www.codeweavers.com/store")!)
                }
            }
            Text("Unofficial software — not affiliated with CodeWeavers, Gryphline/Hypergryph, Tencent, or Apple. Requires your own licensed copy of CrossOver \(CrossOverInfo.expectedVersion) and your own copy of the game.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Actions

    private func detectDefaultCrossOver() {
        guard crossover == nil else { return }
        let standard = URL(fileURLWithPath: "/Applications/CrossOver.app")
        if FileManager.default.fileExists(atPath: standard.path) {
            select(standard)
        }
    }

    private func select(_ url: URL) {
        crossover = CrossOverInfo(url: url)
        engine.reset()
    }

    private func chooseCrossOver() {
        let panel = NSOpenPanel()
        panel.title = "Choose CrossOver.app"
        panel.allowedContentTypes = [.applicationBundle]
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        if panel.runModal() == .OK, let url = panel.url {
            select(url)
        }
    }

    private func startPatch() {
        guard let cx = crossover else { return }
        let panel = NSSavePanel()
        panel.title = "Save the patched copy"
        panel.nameFieldLabel = "Save As:"
        panel.nameFieldStringValue = "CrossOver_Endfield_Patch"
        panel.allowedContentTypes = [.applicationBundle]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.canCreateDirectories = true
        panel.showsTagField = false
        guard panel.runModal() == .OK, let destination = panel.url else { return }

        if cx.isExpectedVersion {
            engine.patch(source: cx.url, destination: destination, gptk: selectedGPTK)
        } else {
            pendingDestination = destination
            showVersionWarning = true
        }
    }

    // MARK: - GPTK

    /// Refresh the list of GPTK redists mounted under /Volumes, keeping a hand-picked one.
    private func refreshGPTK() {
        var detected = GPTKSource.detectMounted()
        // Keep a manually chosen GPTK that isn't a mounted DMG (e.g. a folder on disk).
        if let selected = selectedGPTK, !detected.contains(selected),
           FileManager.default.fileExists(atPath: selected.url.path) {
            detected.append(selected)
        }
        gptkSources = detected.sorted {
            $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
        }
        if let selected = selectedGPTK, !gptkSources.contains(selected) { selectedGPTK = nil }
        // Automatically apply a mounted GPTK4 the first time one is seen; the picker still lets
        // the user fall back to CrossOver's bundled D3DMetal.
        if !gptkAutoSelected, let gptk4 = gptkSources.first(where: { $0.isVersion4 }) {
            gptkAutoSelected = true
            selectedGPTK = gptk4
        }
    }

    private func chooseGPTKFolder() {
        let panel = NSOpenPanel()
        panel.title = "Choose the GPTK redist/lib/external folder"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: "/Volumes")
        guard panel.runModal() == .OK, let url = panel.url else { return }

        // Accept …/redist/lib/external, its parent redist/lib, redist, or the volume root.
        let candidates = [
            url,
            url.appendingPathComponent("redist/lib/external", isDirectory: true),
            url.appendingPathComponent("lib/external", isDirectory: true),
        ]
        if let source = candidates.compactMap({ GPTKSource(url: $0) }).first {
            selectGPTK(source)
        } else {
            engine.errorMessage = "That folder isn't a GPTK redist — expected D3DMetal.framework and libd3dshared.dylib (…/redist/lib/external)."
        }
    }

    private func selectGPTK(_ source: GPTKSource) {
        if !gptkSources.contains(source) { gptkSources.append(source) }
        gptkSources.sort {
            $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
        }
        selectedGPTK = source
        gptkAutoSelected = true   // respect the explicit choice on later rescans
    }
}
