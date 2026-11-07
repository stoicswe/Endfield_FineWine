import SwiftUI
import AppKit

/// Tools window: per-bottle settings editor + app alias creation + GPTK upgrade.
///
/// Reads and writes the `[EnvironmentVariables]` section of `cxbottle.conf` for the selected
/// bottle. Reuses the existing `BottleConf` editor (in MetalHUD.swift) and `BottleSettings`
/// (in AutomatedSetup.swift).
struct BottleSettingsView: View {
    @EnvironmentObject private var engine: PatcherEngine
    @EnvironmentObject private var l10n: LanguageManager

    @State private var bottles: [BottleInfo] = []
    @State private var selected: BottleInfo?
    @State private var manualBottles: [BottleInfo] = []

    // Settings state — loaded from cxbottle.conf
    @State private var backend: BottleBackend = .d3dmetal
    @State private var msync = true
    @State private var upscaling = true
    @State private var metalHUD = false
    @State private var fpsCap: String = "uncapped"

    // Alias
    @State private var aliasExists = false
    @State private var aliasCreated = false

    // GPTK
    @State private var gptkSources: [GPTKSource] = []
    @State private var selectedGPTK: GPTKSource?

    // Status
    @State private var saved = false
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            bottlePicker
            if selected != nil {
                settingsBox
                Divider()
                aliasBox
                Divider()
                gptkUpgradeBox
            }
            if let error = errorMessage {
                ErrorBox(message: error)
            }
        }
        .padding(20)
        .frame(width: 520)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear {
            refreshBottles()
            refreshGPTK()
            checkAlias()
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(l10n.tr("bottle.title"))
                .font(.title2.weight(.semibold))
            Text(l10n.tr("setup.bottle.desc"))
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Bottle Picker

    private var bottlePicker: some View {
        GroupBox {
            HStack {
                if bottles.isEmpty {
                    Text(l10n.tr("bottle.none_found"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Picker("Bottle:", selection: $selected) {
                        ForEach(bottles) { bottle in
                            Text(bottleDisplayName(bottle)).tag(Optional(bottle))
                        }
                    }
                    .labelsHidden()
                    .onChange(of: selected) { _ in loadSettings() }
                }
                Spacer()
                Button(l10n.tr("app.choose"), action: chooseBottle)
            }
            .padding(4)
        }
    }

    // MARK: - Settings

    private var settingsBox: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                Label(l10n.tr("bottle.graphics_section"), systemImage: "gearshape.2")
                    .font(.callout.weight(.medium))

                // Backend
                Picker(l10n.tr("bottle.backend_label"), selection: $backend) {
                    ForEach(BottleBackend.allCases) { b in
                        Text(b.displayName).tag(b)
                    }
                }

                // MSync
                Toggle(l10n.tr("bottle.msync_toggle"), isOn: $msync)
                    .font(.callout)

                // Upscaler
                if backend.supportsUpscaling {
                    Toggle(l10n.tr("bottle.upscaler_toggle", backend.upscalerKey ?? "MetalFX"), isOn: $upscaling)
                        .font(.callout)
                }

                // Metal HUD
                Toggle(l10n.tr("bottle.metal_hud_toggle"), isOn: $metalHUD)
                    .font(.callout)

                // FPS Cap
                HStack {
                    Text(l10n.tr("bottle.fps_cap_label"))
                        .font(.callout)
                    Picker("", selection: $fpsCap) {
                        Text(l10n.tr("bottle.fps.uncapped")).tag("uncapped")
                        Text(l10n.tr("bottle.fps.60")).tag("60")
                        Text(l10n.tr("bottle.fps.120")).tag("120")
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(width: 150)
                }

                // Actions
                HStack {
                    Button(l10n.tr("app.apply")) { saveSettings() }
                        .buttonStyle(.borderedProminent)

                    if saved {
                        Label(l10n.tr("app.saved"), systemImage: "checkmark.circle.fill")
                            .font(.caption)
                            .foregroundStyle(.green)
                    }

                    Spacer()

                    Button(l10n.tr("bottle.btn.stop")) {
                        if let bottle = selected {
                            engine.stopBottle(bottle: bottle.url)
                        }
                    }
                    .disabled(selected == nil)
                    .help(l10n.tr("bottle.stop_help"))
                }

                Text(l10n.tr("bottle.restart_notice"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(4)
        }
    }

    // MARK: - App Alias

    private var aliasBox: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                Label(l10n.tr("bottle.alias.title"), systemImage: "dock.rectangle")
                    .font(.callout.weight(.medium))

                Text(l10n.tr("bottle.alias.desc"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                HStack {
                    Button(aliasExists ? l10n.tr("bottle.alias.recreate") : l10n.tr("bottle.alias.create")) {
                        createAlias()
                    }
                    .buttonStyle(.bordered)
                    .disabled(selected == nil)

                    if aliasCreated {
                        Label(l10n.tr("app.created"), systemImage: "checkmark.circle.fill")
                            .font(.caption)
                            .foregroundStyle(.green)
                    }

                    if aliasExists {
                        Button(l10n.tr("app.reveal_finder")) {
                            if let url = AppAlias.existingAlias() {
                                NSWorkspace.shared.selectFile(url.path, inFileViewerRootedAtPath: url.deletingLastPathComponent().path)
                            }
                        }
                        .font(.caption)

                        Button(l10n.tr("app.remove")) {
                            try? AppAlias.remove()
                            checkAlias()
                            aliasCreated = false
                        }
                        .font(.caption)
                        .foregroundStyle(.red)
                    }
                }
            }
            .padding(4)
        }
    }

    // MARK: - GPTK Upgrade

    private var gptkUpgradeBox: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                Label("Upgrade GPTK / D3DMetal", systemImage: "arrow.triangle.2.circlepath")
                    .font(.callout.weight(.medium))

                Text("Replace the D3DMetal in an already-patched CrossOver with a newer GPTK version, without re-running the full patch.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                HStack {
                    Picker("GPTK Source:", selection: $selectedGPTK) {
                        Text("None selected").tag(GPTKSource?.none)
                        ForEach(gptkSources) { source in
                            Text(source.displayName).tag(GPTKSource?.some(source))
                        }
                    }
                    .labelsHidden()
                    .frame(maxWidth: .infinity)

                    Button("Rescan") { refreshGPTK() }

                    Button("Download…") {
                        NSWorkspace.shared.open(URL(string: "https://developer.apple.com/games/game-porting-toolkit/")!)
                    }
                }

                HStack {
                    Button("Upgrade GPTK In Place") {
                        upgradeGPTK()
                    }
                    .buttonStyle(.bordered)
                    .disabled(selectedGPTK == nil || engine.isRunning)

                    if engine.isRunning {
                        ProgressView()
                            .scaleEffect(0.7)
                    }
                }

                if !engine.hudSteps.isEmpty {
                    StepsListView(steps: engine.hudSteps)
                }
            }
            .padding(4)
        }
    }

    // MARK: - Actions

    private func refreshBottles() {
        var detected = BottleInfo.detectAll()
        let detectedIDs = Set(detected.map { $0.url.standardizedFileURL.path })
        for manual in manualBottles {
            if !detectedIDs.contains(manual.url.standardizedFileURL.path) {
                detected.append(manual)
            }
        }
        bottles = detected.sorted { $0.name < $1.name }
        if selected == nil || !bottles.contains(where: { $0.id == selected?.id }) {
            selected = bottles.first { $0.name == "Arknights Endfield" } ?? bottles.first
        }
        loadSettings()
    }

    private func loadSettings() {
        saved = false
        errorMessage = nil
        guard let bottle = selected else { return }
        guard let settings = BottleSettings.read(from: bottle.url) else {
            errorMessage = "Could not read cxbottle.conf for \(bottle.name)."
            return
        }
        backend = settings.backend
        msync = settings.msync
        upscaling = settings.upscaling
        metalHUD = settings.metalHUD

        let fps = BottleSettings.readFPSCap(from: bottle.url)
        fpsCap = fps ?? "uncapped"
    }

    private func saveSettings() {
        guard let bottle = selected else { return }
        saved = false
        errorMessage = nil

        var settings = BottleSettings()
        settings.name = bottle.name
        settings.backend = backend
        settings.msync = msync
        settings.upscaling = upscaling
        settings.metalHUD = metalHUD

        let fpsValue = fpsCap == "uncapped" ? nil : fpsCap

        do {
            try settings.write(to: bottle.url, fpsCap: fpsValue)
            saved = true
            // Clear the saved indicator after a few seconds
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { saved = false }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func createAlias() {
        guard let bottle = selected else { return }
        aliasCreated = false
        errorMessage = nil

        // Gather env vars from current settings
        var env: [String: String] = [:]
        if metalHUD { env["MTL_HUD_ENABLED"] = "1" }
        let fpsValue = fpsCap == "uncapped" ? nil : fpsCap
        if let fps = fpsValue { env["D3DM_MAX_FPS"] = fps }

        let config = AppAlias.Config(
            appName: AppAlias.defaultAppName,
            bottleName: bottle.name,
            bottlePath: bottle.url.path,
            lnkName: "Arknights+Endfield.lnk",
            environment: env
        )

        do {
            try AppAlias.create(config: config)
            aliasCreated = true
            checkAlias()
        } catch {
            errorMessage = "Failed to create app alias: \(error.localizedDescription)"
        }
    }

    private func checkAlias() {
        aliasExists = AppAlias.existingAlias() != nil
    }

    private func upgradeGPTK() {
        guard let gptk = selectedGPTK else { return }
        errorMessage = nil

        // Find the patched CrossOver app
        let patchedApps = SetupValidation.findPatchedCrossOvers()
        guard let patchedApp = patchedApps.first else {
            errorMessage = "No patched CrossOver found. Run 'Create Patched Copy' first."
            return
        }

        engine.upgradeGPTK(in: patchedApp, from: gptk)
    }

    private func refreshGPTK() {
        gptkSources = GPTKSource.detectMounted()
        if selectedGPTK == nil, let gptk4 = gptkSources.first(where: { $0.isVersion4 && $0.installProblem == nil }) {
            selectedGPTK = gptk4
        }
    }

    private func chooseBottle() {
        let panel = NSOpenPanel()
        panel.title = "Choose a CrossOver bottle"
        panel.message = "Point at a bottle folder (contains cxbottle.conf) or a Bottles directory."
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: "/Volumes")
        guard panel.runModal() == .OK, let url = panel.url else { return }

        let found = BottleInfo.bottlesFromManualChoice(url)
        if found.isEmpty {
            errorMessage = "No CrossOver bottles found at \(url.path)."
            return
        }
        manualBottles.append(contentsOf: found)
        refreshBottles()
        if let first = found.first {
            selected = first
            loadSettings()
        }
    }

    private func bottleDisplayName(_ bottle: BottleInfo) -> String {
        let parts = bottle.url.standardizedFileURL.pathComponents
        if parts.count >= 3, parts[1] == "Volumes" {
            return "\(bottle.name) (\(parts[2]))"
        }
        return bottle.name
    }
}

// ErrorBox and StepsListView are defined in PatchProgressViews.swift
