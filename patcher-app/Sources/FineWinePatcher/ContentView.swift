import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct ContentView: View {
    @EnvironmentObject var engine: PatcherEngine
    @EnvironmentObject var setup: SetupEngine
    @EnvironmentObject var l10n: LanguageManager
    @State private var crossover: CrossOverInfo?
    @State private var showLicenses = false
    @State private var showAutomatedSetup = false
    @State private var showPatchProgress = false
    @State private var showPatchTelemetry = false
    @State private var showVersionWarning = false
    @State private var pendingDestination: URL?
    @State private var gptkSources: [GPTKSource] = []
    @State private var selectedGPTK: GPTKSource?
    @State private var gptkAutoSelected = false
    /// Patched copies whose D3DMetal framework and DLLs don't match (see D3DMetalRepair).
    @State private var brokenD3DMetal: [(app: URL, mismatch: D3DMetalRepair.Mismatch)] = []

    /// The variant of the currently selected CrossOver (`nil` = unrecognized layout).
    private var selectedVariant: CrossOverVariant? { crossover?.variant }
    /// Whether the payload for the selected variant is bundled in this build.
    private var payloadReady: Bool { selectedVariant.map { Payload.isComplete(for: $0) } ?? false }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            if !brokenD3DMetal.isEmpty || engine.d3dMetalRepairResult != nil || engine.d3dMetalRepairError != nil {
                d3dMetalRepairBox
            }
            crossoverBox
            if selectedVariant?.supportsD3DMetal != false { gptkBox }
            if !payloadReady { payloadMissingBox }
            actionButtons
            Divider()
            footer
        }
        .padding(20)
        .frame(width: 460)
        .fixedSize(horizontal: false, vertical: true)
        .sheet(isPresented: $showPatchProgress, onDismiss: {
            // Offer the run report once the result window has closed, so the two sheets never
            // overlap. Nothing is sent unless the user chooses it in this dialog.
            guard engine.telemetryPrompt != nil else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { showPatchTelemetry = true }
        }) {
            PatchProgressView()
                .environmentObject(engine)
        }
        .sheet(isPresented: $showAutomatedSetup) {
            AutomatedSetupView(source: crossover, gptk: selectedGPTK)
                .environmentObject(engine)
                .environmentObject(setup)
                .environmentObject(l10n)
        }
        .sheet(isPresented: $showLicenses) { LicensesView() }
        .sheet(isPresented: $showPatchTelemetry, onDismiss: { engine.telemetryPrompt = nil }) {
            if let prompt = engine.telemetryPrompt {
                PatchTelemetryPromptView(
                    prompt: prompt,
                    onSend: { UsageTelemetry.send(prompt) },
                    onFinished: { engine.telemetryPrompt = nil }
                )
            }
        }
        .confirmationDialog(l10n.tr("content.mismatch.title"), isPresented: $showVersionWarning, titleVisibility: .visible) {
            Button(l10n.tr("content.mismatch.patch_anyway"), role: .destructive) {
                if let destination = pendingDestination, let cx = crossover, let variant = cx.variant {
                    engine.patch(source: cx.url, variant: variant, destination: destination, gptk: selectedGPTK)
                    showPatchTelemetry = false
                    showPatchProgress = true
                }
                pendingDestination = nil
            }
            Button(l10n.tr("app.cancel"), role: .cancel) { pendingDestination = nil }
        } message: {
            Text(l10n.tr("content.mismatch.message", crossover?.version ?? "unknown", selectedVariant?.expectedVersion ?? CrossOverVariant.x64.expectedVersion))
        }
        .onAppear {
            detectDefaultCrossOver()
            refreshGPTK()
            refreshD3DMetalCheck()
        }
        .onChange(of: engine.d3dMetalRepairIsRunning) { running in
            if !running { refreshD3DMetalCheck() }
        }
        .onChange(of: engine.isRunning) { running in
            if !running { refreshD3DMetalCheck() }
        }
    }

    // MARK: - Sections

    private var d3dMetalRepairBox: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(brokenD3DMetal, id: \.app) { item in
                    Label("\(item.app.lastPathComponent): \(item.mismatch.summary)", systemImage: "exclamationmark.triangle.fill")
                        .font(.callout)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack {
                        Button("Repair D3DMetal") { engine.repairD3DMetal(in: item.app) }
                            .disabled(engine.isRunning || engine.d3dMetalRepairIsRunning)
                        if engine.d3dMetalRepairIsRunning { ProgressView().scaleEffect(0.7) }
                    }
                }
                if let result = engine.d3dMetalRepairResult {
                    Label(result, systemImage: "checkmark.seal.fill")
                        .font(.caption)
                        .foregroundStyle(.green)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let error = engine.d3dMetalRepairError {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if !brokenD3DMetal.isEmpty {
                    Text("Repair installs the D3DMetal DLLs that match (from a mounted GPTK DMG or a CrossOver 27 app), or restores CrossOver's bundled D3DMetal 3.0.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(4)
        }
    }

    private func refreshD3DMetalCheck() {
        brokenD3DMetal = SetupValidation.findPatchedCrossOvers().compactMap { app in
            D3DMetalRepair.mismatch(in: app).map { (app, $0) }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(l10n.tr("app.title"))
                .font(.title2.weight(.semibold))
            Text(l10n.tr("app.subtitle", selectedVariant?.expectedVersion ?? CrossOverVariant.x64.expectedVersion))
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
                        Button(l10n.tr("app.change"), action: chooseCrossOver)
                            .disabled(engine.isRunning)
                    }
                } else {
                    HStack(spacing: 8) {
                        Image(systemName: "app.dashed")
                            .font(.title2)
                            .foregroundStyle(.secondary)
                        Text(l10n.tr("content.drop_crossover"))
                            .foregroundStyle(.secondary)
                        Button(l10n.tr("app.choose"), action: chooseCrossOver)
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
                    Text(l10n.tr("content.gptk.title"))
                        .font(.callout.weight(.medium))
                    Spacer()
                    Button(l10n.tr("app.choose"), action: chooseGPTKFolder)
                        .disabled(engine.isRunning)
                    Button(l10n.tr("app.rescan"), action: refreshGPTK)
                        .disabled(engine.isRunning)
                    Button(l10n.tr("content.gptk.download")) {
                        NSWorkspace.shared.open(URL(string: "https://developer.apple.com/games/game-porting-toolkit/")!)
                    }
                }
                Picker("D3DMetal", selection: $selectedGPTK) {
                    Text(l10n.tr("content.gptk.keep_bundled")).tag(GPTKSource?.none)
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
        .dropDestination(for: URL.self) { urls, _ in
            guard !engine.isRunning, let url = urls.first else { return false }
            if let src = GPTKSource.resolve(from: url) {
                selectGPTK(src)
                return true
            }
            return false
        }
    }

    private var gptkHint: String {
        if let selected = selectedGPTK {
            if let problem = selected.installProblem { return problem }
            if selected.isVersion4 {
                return l10n.tr("content.gptk.hint.v4", selected.version ?? "3.0", selected.displayName)
            }
            return l10n.tr("content.gptk.hint.older", selected.displayName)
        }
        if gptkSources.isEmpty {
            return l10n.tr("content.gptk.hint.not_found")
        }
        return l10n.tr("content.gptk.hint.not_bundled")
    }

    @ViewBuilder
    private func statusLine(for cx: CrossOverInfo) -> some View {
        if cx.variant == nil || !cx.hasWineModules {
            Label(l10n.tr("content.status.no_modules"), systemImage: "xmark.circle.fill")
                .font(.caption).foregroundStyle(.red)
        } else if cx.variant == .arm {
            Label("ARM (aarch64) · version \(cx.version ?? "?") · experimental", systemImage: "cpu")
                .font(.caption).foregroundStyle(.orange)
        } else if cx.isExpectedVersion {
            Label("x64 · " + l10n.tr("content.status.valid", cx.displayVersion), systemImage: "checkmark.seal.fill")
                .font(.caption).foregroundStyle(.green)
        } else {
            Label("x64 · " + l10n.tr("content.status.mismatch", cx.displayVersion, CrossOverVariant.x64.expectedVersion),
                  systemImage: "exclamationmark.triangle.fill")
                .font(.caption).foregroundStyle(.orange)
        }
    }

    private var payloadMissingBox: some View {
        Label(payloadMissingMessage,
              systemImage: "exclamationmark.triangle.fill")
            .font(.caption)
            .foregroundStyle(.orange)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var payloadMissingMessage: String {
        switch selectedVariant {
        case .arm:
            return "This build has no ARM (aarch64) module payload. Build it with scripts/build-wine-arm.sh, then restage with build-app.sh. The x64 payload is unaffected."
        default:
            return l10n.tr("content.payload_missing")
        }
    }

    private var actionButtons: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Button(action: startPatch) {
                    Text(engine.isRunning ? l10n.tr("content.btn.patching") : l10n.tr("content.btn.create_patch"))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(!payloadReady || engine.isRunning || crossover?.hasWineModules != true)

                Button {
                    showAutomatedSetup = true
                } label: {
                    Label(l10n.tr("content.btn.automated_setup"), systemImage: "wand.and.stars")
                        .frame(maxWidth: .infinity)
                }
                .controlSize(.large)
                .disabled(engine.isRunning || crossover?.hasWineModules != true)
            }
            Text(l10n.tr("content.automated_setup_desc"))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(l10n.tr("app.telemetry_notice"))
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button(l10n.tr("app.licenses")) { showLicenses = true }
                Spacer()
                Menu {
                    ForEach(AppLanguage.allCases) { lang in
                        Button {
                            l10n.selectedLanguage = lang
                        } label: {
                            HStack {
                                Text(lang.displayName)
                                if l10n.selectedLanguage == lang {
                                    Spacer()
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                    }
                } label: {
                    Label(l10n.selectedLanguage.displayName, systemImage: "globe")
                        .font(.caption)
                }
                .menuStyle(.borderlessButton)
                Spacer()
                Button(l10n.tr("app.buy_crossover")) {
                    NSWorkspace.shared.open(URL(string: "https://www.codeweavers.com/store")!)
                }
            }
            Text(l10n.tr("app.unofficial_disclaimer", CrossOverVariant.x64.expectedVersion))
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Actions

    private func detectDefaultCrossOver() {
        guard crossover == nil else { return }
        // Prefer the first well-known install that looks like a patchable CrossOver (x64 or ARM).
        let candidates = [
            "/Applications/CrossOver.app",
            "/Applications/CrossOver ARM Preview.app",
        ].map { URL(fileURLWithPath: $0) }
        if let match = candidates.first(where: {
            FileManager.default.fileExists(atPath: $0.path) && CrossOverInfo(url: $0).variant != nil
        }) {
            select(match)
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
        panel.nameFieldStringValue = cx.variant?.patchedAppName ?? CrossOverVariant.x64.patchedAppName
        panel.allowedContentTypes = [.applicationBundle]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.canCreateDirectories = true
        panel.showsTagField = false
        guard panel.runModal() == .OK, let destination = panel.url else { return }

        guard let variant = cx.variant else { return }
        if cx.isExpectedVersion {
            engine.patch(source: cx.url, variant: variant, destination: destination, gptk: selectedGPTK)
            showPatchTelemetry = false
            showPatchProgress = true
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
        if !gptkAutoSelected, let gptk4 = gptkSources.first(where: { $0.isVersion4 && $0.installProblem == nil }) {
            gptkAutoSelected = true
            selectedGPTK = gptk4
        }
    }

    private func chooseGPTKFolder() {
        let panel = NSOpenPanel()
        panel.title = "Choose GPTK Folder or Disk Image (.dmg)"
        panel.message = "Point at a mounted volume (e.g. Game Porting Toolkit), an Evaluation Environment .dmg, or the redist/lib/external folder."
        panel.prompt = "Select"
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowedContentTypes = [.folder, .diskImage]
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: "/Volumes")
        guard panel.runModal() == .OK, let url = panel.url else { return }

        if let source = GPTKSource.resolve(from: url) {
            selectGPTK(source)
        } else {
            engine.errorMessage = "Could not find D3DMetal in '\(url.lastPathComponent)'. Expected a GPTK redist folder (…/redist/lib/external) or an Evaluation Environment DMG."
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
