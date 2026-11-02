import SwiftUI
import AppKit

/// Optional Tools window: Apple's Metal Performance HUD, per bottle.
///
/// The HUD is a Unix environment variable (`MTL_HUD_ENABLED=1`). CrossOver injects the
/// bottle's `[EnvironmentVariables]` into every Wine process, so enabling it here covers
/// `Endfield.exe`, Gryphline's `Games.exe` / `Launcher.exe`, XXMI, and any other Metal
/// client in that bottle. Matching macOS launcher stubs get the same key in `LSEnvironment`.
struct MetalHUDView: View {
    @EnvironmentObject private var engine: PatcherEngine

    @State private var bottles: [BottleInfo] = []
    @State private var selected: BottleInfo?
    @State private var manualBottles: [BottleInfo] = []
    @State private var plan: MetalHUD.Plan?
    @State private var setupError: String?
    @State private var stoppedNotice = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            hudBox
            if !engine.hudSteps.isEmpty { StepsListView(steps: engine.hudSteps) }
            if let error = engine.hudError { ErrorBox(message: error) }
        }
        .padding(20)
        .frame(width: 520)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear { refresh() }
        .onChange(of: engine.hudIsRunning) { running in
            if !running { refresh() }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Metal HUD")
                .font(.title2.weight(.semibold))
            Text("Optional Apple performance overlay (FPS, memory, encoder time) on the D3DMetal / DXMT / MoltenVK Metal device. Off by default — enable it here when you want it, then restart the bottle.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var hudBox: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Label("Bottle HUD", systemImage: "speedometer")
                        .font(.callout.weight(.medium))
                    Spacer()
                    if plan?.currentlyEnabled == true {
                        Label("enabled", systemImage: "checkmark.circle.fill")
                            .font(.caption)
                            .foregroundStyle(.green)
                    }
                }

                Text("Writes `MTL_HUD_ENABLED=1` into the bottle's cxbottle.conf. CrossOver passes that Unix environment to every Wine process in the bottle, so the overlay follows Endfield, Games.exe, and the other related apps listed below — not just one EXE.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                HStack {
                    if bottles.isEmpty {
                        Text("No CrossOver bottles found.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Picker("Bottle:", selection: $selected) {
                            ForEach(bottles) { bottle in
                                Text(bottleDisplayName(bottle)).tag(Optional(bottle))
                            }
                        }
                        .labelsHidden()
                        .onChange(of: selected) { _ in refresh() }
                    }
                    Spacer()
                    Button("Choose Bottle…", action: chooseBottle)
                        .disabled(engine.hudIsRunning)
                }

                if let plan {
                    HStack {
                        Text("D3DMetal FPS Cap:")
                            .font(.caption)
                        Picker("FPS Cap", selection: Binding(
                            get: { plan.maxFPS ?? "uncapped" },
                            set: { newFPS in
                                if let bottle = selected {
                                    engine.setMetalHUDFPS(bottle: bottle.url, fps: newFPS == "uncapped" ? nil : newFPS)
                                    refresh()
                                }
                            }
                        )) {
                            Text("Uncapped").tag("uncapped")
                            Text("60 FPS (Recommended)").tag("60")
                            Text("120 FPS").tag("120")
                        }
                        .pickerStyle(.menu)
                        .labelsHidden()
                        .disabled(engine.hudIsRunning)
                        Spacer()
                    }
                }

                if let error = setupError {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if let plan {
                    relatedList(plan.related)
                    if !plan.macLaunchers.isEmpty {
                        macList(plan.macLaunchers)
                    }
                }

                HStack {
                    Button(engine.hudIsRunning ? "Working…" : "Enable HUD") {
                        if let plan { engine.applyMetalHUD(plan: plan) }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(plan == nil || engine.hudIsRunning || engine.isRunning || plan?.currentlyEnabled == true)

                    Button("Disable HUD") {
                        if let bottle = selected { engine.revertMetalHUD(bottle: bottle.url) }
                    }
                    .disabled(plan == nil || engine.hudIsRunning || engine.isRunning || plan?.currentlyEnabled != true)

                    Spacer()

                    Button("Stop Bottle") {
                        if let bottle = selected {
                            engine.stopBottle(bottle: bottle.url)
                            stoppedNotice = true
                        }
                    }
                    .disabled(selected == nil || engine.hudIsRunning)
                    .help("Kills running Wine/wineserver processes in this bottle so environment changes take effect immediately.")
                }

                if stoppedNotice {
                    Label("Stopped Wine processes in bottle.", systemImage: "checkmark.circle")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(4)
        }
    }

    @ViewBuilder
    private func relatedList(_ apps: [MetalHUD.RelatedApp]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Related Windows apps in this bottle")
                .font(.caption.weight(.medium))
            if apps.isEmpty {
                Text("No Endfield.exe / Games.exe / GRYPHLINK / XXMI binaries found yet. The bottle-wide key still applies to whatever you launch later.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ForEach(apps) { app in
                    Text("\(app.fileName) · \(app.displayKind)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text(app.windowsPath)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                }
            }
        }
    }

    @ViewBuilder
    private func macList(_ launchers: [MetalHUD.MacLauncher]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Matching macOS launchers")
                .font(.caption.weight(.medium))
            ForEach(launchers) { launcher in
                Text("\(launcher.name).app — \(launcher.reason)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .truncationMode(.middle)
            }
        }
    }

    private func refresh() {
        setupError = nil
        plan = nil

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
        guard let bottle = selected else {
            setupError = "No CrossOver bottle found."
            return
        }
        guard let next = MetalHUD.plan(for: bottle.url) else {
            setupError = "Could not read cxbottle.conf for \(bottle.name)."
            return
        }
        plan = next
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
            setupError = "No CrossOver bottles found at \(url.path) — expected a folder containing cxbottle.conf, or a Bottles directory."
            return
        }
        setupError = nil
        manualBottles.append(contentsOf: found)
        refresh()
        if let first = found.first {
            selected = first
            refresh()
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
