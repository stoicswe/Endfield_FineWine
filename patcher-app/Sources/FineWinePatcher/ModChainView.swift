import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// The Mod Framework window — opened from the menu bar (Tools → Mod Framework (EFMI)…).
///
/// This is deliberately **not** part of the main page: the XXMI/EFMI mod chain is an advanced,
/// independent, bottle-side phase (docs/mod-injection/08-patcher-integration-plan.md), so the
/// main window stays focused on creating the patched app. This window manages the whole mod
/// framework: bottle + EFMI discovery, applying the chain, re-applying after EFMI updates,
/// and reverting.
struct ModChainView: View {
    @EnvironmentObject private var engine: PatcherEngine
    @EnvironmentObject private var l10n: LanguageManager

    @State private var bottles: [BottleInfo] = []
    @State private var chainBottle: BottleInfo?
    @State private var chainApp: URL?
    @State private var chainImporterOverride: URL?
    @State private var chainPlan: ChainPlan?
    @State private var chainSetupError: String?
    @State private var chainState: ChainState?
    @State private var manualBottles: [BottleInfo] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            modChainBox
            if !engine.modSteps.isEmpty { StepsListView(steps: engine.modSteps) }
            if let error = engine.modError { ErrorBox(message: error) }
        }
        .padding(20)
        .frame(width: 520)
        .fixedSize(horizontal: false, vertical: true)
        .fineWineChrome()
        .onAppear { refreshChain() }
        .onChange(of: engine.patchedApp) { _ in refreshChain() }
    }

    // MARK: - Sections

    private var header: some View {
        PageHeader(title: l10n.tr("mod.title"), subtitle: l10n.tr("mod.desc"), symbol: "puzzlepiece.extension")
    }

    private var modChainBox: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Label("Mod chain", systemImage: "puzzlepiece.extension")
                        .font(.callout.weight(.medium))
                    Spacer()
                    if let state = chainState {
                        Label("applied · \(state.backend)", systemImage: "checkmark.circle.fill")
                            .font(.caption)
                            .foregroundStyle(.green)
                    }
                }
                Text("Chains EFMI's d3d11.dll onto the patched app's D3D11→Metal backend (proxy_d3d11), so mods hand off to Metal instead of Wine's wined3d. Requires XXMI Launcher + EFMI installed in the bottle.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                HStack {
                    if bottles.isEmpty {
                        Text("No CrossOver bottles found.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Picker("Bottle:", selection: $chainBottle) {
                            ForEach(bottles) { bottle in
                                Text(bottleDisplayName(bottle)).tag(Optional(bottle))
                            }
                        }
                        .labelsHidden()
                        .onChange(of: chainBottle) { _ in refreshChain() }
                    }
                    Spacer()
                    Button("Choose Bottle…", action: chooseBottle)
                        .disabled(engine.modIsRunning)
                    Button("Choose EFMI…", action: chooseImporter)
                        .disabled(engine.modIsRunning)
                }

                if let override = chainImporterOverride {
                    HStack {
                        Label("EFMI override: \(override.lastPathComponent)", systemImage: "folder.badge.gearshape")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Reset to Auto") {
                            chainImporterOverride = nil
                            refreshChain()
                        }
                        .font(.caption)
                        .disabled(engine.modIsRunning)
                    }
                }

                if bottles.isEmpty {
                    Label("No CrossOver bottle found.", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                } else if let bottle = chainBottle {
                    Text("Backend: \(bottle.backend?.displayName ?? "wined3d (none)") — \(bottle.backend != nil ? "chain possible" : "the default chain is already correct here, nothing to do")")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if let plan = chainPlan {
                    Text("target: \(plan.target)")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(2)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                }
                if let error = chainSetupError {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }

                // Always-visible primary action: applying the mod framework to the bottle is the
                // whole point of this window, and it runs independently of the main window's
                // CrossOver patch (which only needs to exist so the chain has a target). Disabled
                // until a bottle + EFMI + patched app resolve into a plan.
                HStack {
                    Button(engine.modIsRunning ? "Applying…" : "Apply") {
                        if let plan = chainPlan { engine.applyModChain(plan: plan) }
                    }
                    .prominentGlassButton()
                    .disabled(chainPlan == nil || engine.modIsRunning || engine.isRunning)

                    Button("Revert") {
                        if let plan = chainPlan { engine.revertModChain(importerDir: plan.importerDir) }
                    }
                    .disabled(chainPlan == nil || engine.modIsRunning || engine.isRunning || chainState == nil)

                    Spacer()
                    Button("Choose EFMI folder…", action: chooseImporter)
                        .disabled(engine.modIsRunning)
                    Button("Choose patched app…", action: choosePatchedApp)
                        .disabled(engine.modIsRunning)
                }
            }
            .padding(4)
        }
    }

    // MARK: - Chain resolution

    private func refreshChain() {
        chainSetupError = nil
        chainPlan = nil
        chainState = nil

        // Merge auto-detected bottles with any the user added manually.
        var detected = BottleInfo.detectAll()
        let detectedIDs = Set(detected.map { $0.url.standardizedFileURL.path })
        for manual in manualBottles {
            if !detectedIDs.contains(manual.url.standardizedFileURL.path) {
                detected.append(manual)
            }
        }
        bottles = detected.sorted { $0.name < $1.name }
        if chainBottle == nil || !bottles.contains(where: { $0.id == chainBottle?.id }) {
            chainBottle = bottles.first { $0.name == "Arknights Endfield" } ?? bottles.first
        }
        let app = chainApp ?? engine.patchedApp ?? ModChain.defaultPatchedApp()
        guard let app, ModChain.isPatchedCrossOver(app) else {
            chainSetupError = "No patched CrossOver app yet — create one in the main window (or use Choose patched app… to point at an existing one)."
            return
        }
        guard let bottle = chainBottle else {
            chainSetupError = "No CrossOver bottle found."
            return
        }
        guard let backend = bottle.backend else { return }   // wined3d: nothing to chain, by design

        do {
            guard let importer = ModChain.locateImporter(bottle: bottle.url, override: chainImporterOverride) else {
                chainSetupError = "Could not find an EFMI folder in this bottle (looked in XXMI Launcher's config and its default location). Install EFMI first, or use Choose EFMI folder…."
                return
            }
            chainPlan = try ModChain.plan(patchedApp: app, bottle: bottle.url,
                                          backend: backend, importerDir: importer)
            chainState = ModChain.readState(importerDir: importer)
        } catch {
            chainSetupError = error.localizedDescription
        }
    }

    // MARK: - Actions

    private func choosePatchedApp() {
        let panel = NSOpenPanel()
        panel.title = "Choose the patched CrossOver app"
        panel.message = "The app the mod chain should point at (e.g. CrossOver_Endfield_Patch.app)."
        panel.allowedContentTypes = [.applicationBundle]
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        if panel.runModal() == .OK, let url = panel.url, ModChain.isPatchedCrossOver(url) {
            chainApp = url
            refreshChain()
        }
    }

    private func chooseBottle() {
        let panel = NSOpenPanel()
        panel.title = "Choose a CrossOver bottle or Bottles folder"
        panel.message = "Point at a single bottle folder (contains cxbottle.conf) or a Bottles directory containing multiple bottles."
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: "/Volumes")
        guard panel.runModal() == .OK, let url = panel.url else { return }

        let found = BottleInfo.bottlesFromManualChoice(url)
        if found.isEmpty {
            chainSetupError = "No CrossOver bottles found at \(url.path) — expected a folder containing cxbottle.conf, or a Bottles directory."
            return
        }
        chainSetupError = nil
        manualBottles.append(contentsOf: found)
        refreshChain()
        // Auto-select the first newly added bottle.
        if let first = found.first {
            chainBottle = first
            refreshChain()
        }
    }

    private func chooseImporter() {
        let panel = NSOpenPanel()
        panel.title = "Choose the EFMI folder"
        panel.message = "The folder that contains EFMI's d3dx.ini (e.g. …\\XXMI Launcher\\EFMI)."
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = chainBottle.map { $0.url.appendingPathComponent("drive_c") }
        if panel.runModal() == .OK, let url = panel.url {
            chainImporterOverride = url
            refreshChain()
        }
    }

    /// Display name for a bottle — includes the volume name if it's on an external drive.
    private func bottleDisplayName(_ bottle: BottleInfo) -> String {
        let parts = bottle.url.standardizedFileURL.pathComponents
        // If it's under /Volumes/<VolumeName>/..., show the volume name.
        if parts.count >= 3, parts[1] == "Volumes" {
            let volume = parts[2]
            return "\(bottle.name) (\(volume))"
        }
        return bottle.name
    }
}
