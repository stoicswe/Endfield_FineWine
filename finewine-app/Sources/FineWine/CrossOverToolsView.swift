import SwiftUI
import AppKit
import UniformTypeIdentifiers

enum CrossOverTool: String {
    case bottleSettings, efmi, notProton, metalHUD

    var title: String {
        switch self {
        case .bottleSettings: return "Bottle Settings"
        case .efmi: return "Mod Framework (EFMI)"
        case .notProton: return "Steam / NotProton"
        case .metalHUD: return "Metal HUD"
        }
    }
    var symbol: String {
        switch self {
        case .bottleSettings: return "slider.horizontal.3"
        case .efmi: return "puzzlepiece.extension"
        case .notProton: return "gamecontroller"
        case .metalHUD: return "speedometer"
        }
    }
}

/// Standalone CrossOver tooling windows. Their scope is made explicit in the copy: actions edit
/// only the selected live CrossOver bottle, never a FineWine-managed prefix.
struct CrossOverToolsView: View {
    let tool: CrossOverTool
    @State private var bottles: [CrossOverToolBottle] = []
    @State private var selectedBottle: CrossOverToolBottle?
    @State private var settings = CrossOverBottleSettings()
    @State private var efmiFolder: URL?
    @State private var patchedApp: URL?
    @State private var notice: String?
    @State private var error: String?
    @State private var working = false

    var body: some View {
        ZStack {
            Backdrop()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    header
                    bottlePicker
                    switch tool {
                    case .bottleSettings: settingsContent
                    case .efmi: efmiContent
                    case .notProton: notProtonContent
                    case .metalHUD: hudContent
                    }
                    result
                }
                .padding(20)
            }
        }
        .frame(minWidth: 560, minHeight: 430)
        .onAppear(perform: refresh)
        .onChange(of: selectedBottle) { _, _ in loadBottleState() }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: tool.symbol)
                .font(.title2)
                .foregroundStyle(Look.accent)
                .frame(width: 44, height: 44)
                .fwGlass(tint: Look.wine.opacity(0.2), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            VStack(alignment: .leading, spacing: 3) {
                Text(tool.title).font(.title2.weight(.semibold))
                Text("Works with a selected CrossOver bottle. FineWine prefixes are not changed.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
        }
    }

    private var bottlePicker: some View {
        Card(title: "CrossOver bottle", symbol: "shippingbox") {
            HStack {
                if bottles.isEmpty {
                    Text("No CrossOver bottles found automatically.").foregroundStyle(.secondary)
                } else {
                    Picker("Bottle", selection: $selectedBottle) {
                        ForEach(bottles) { bottle in
                            Text(bottle.name).tag(Optional(bottle))
                        }
                    }
                    .labelsHidden()
                    .frame(maxWidth: .infinity)
                }
                Button("Choose…", action: chooseBottle).fwButton()
                Button { refresh() } label: { Image(systemName: "arrow.clockwise") }
                    .fwButton().help("Rescan CrossOver bottles")
            }
        }
    }

    private var settingsContent: some View {
        Card(title: "Graphics and performance", symbol: "display") {
            Picker("Graphics backend", selection: $settings.backend) {
                ForEach(CrossOverBackend.allCases) { backend in
                    Text(backend.title).tag(backend)
                }
            }
            Toggle("Enable MSync", isOn: $settings.msync)
            if let key = settings.backend.upscalerKey {
                Toggle("Enable \(key == "D3DM_ENABLE_METALFX" ? "MetalFX" : "NV extension") upscaling", isOn: $settings.upscaling)
            }
            Toggle("Enable Metal Performance HUD", isOn: $settings.metalHUD)
            Picker("D3DMetal FPS cap", selection: Binding(get: { settings.fpsCap ?? "uncapped" }, set: { settings.fpsCap = $0 == "uncapped" ? nil : $0 })) {
                Text("Uncapped").tag("uncapped")
                Text("60 FPS").tag("60")
                Text("120 FPS").tag("120")
            }
            Divider()
            HStack {
                Button("Apply to Bottle", action: saveSettings)
                    .fwProminentButton().tint(Look.wine)
                    .disabled(selectedBottle == nil || working)
                Text("A backup is kept beside cxbottle.conf before the first change.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var efmiContent: some View {
        Card(title: "EFMI D3D11 chain", symbol: "puzzlepiece.extension",
             footnote: "This points EFMI's proxy at the selected patched CrossOver backend, avoiding WineD3D. Reapply after updating EFMI or CrossOver.") {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("EFMI folder")
                    Text(efmiFolder?.path ?? "Not found").font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
                Spacer()
                Button("Choose…", action: chooseEFMI).fwButton()
            }
            Divider()
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Patched CrossOver app")
                    Text(patchedApp?.path ?? "Choose the app containing the backend DLL").font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
                Spacer()
                Button("Choose…", action: choosePatchedApp).fwButton()
            }
            Divider()
            HStack {
                Button(efmiFolder.map(CrossOverTools.efmiApplied) == true ? "Reapply chain" : "Apply chain", action: applyEFMI)
                    .fwProminentButton().tint(Look.wine)
                    .disabled(selectedBottle == nil || efmiFolder == nil || patchedApp == nil || working)
                Button("Revert", action: revertEFMI)
                    .fwButton()
                    .disabled(efmiFolder.map(CrossOverTools.efmiApplied) != true || working)
            }
        }
    }

    private var hudContent: some View {
        Card(title: "Metal Performance HUD", symbol: "speedometer",
             footnote: "Adds MTL_HUD_ENABLED=1 to this bottle. Restart its Wine processes after changing it.") {
            let enabled = settings.metalHUD
            HStack {
                Label(enabled ? "HUD enabled" : "HUD disabled", systemImage: enabled ? "checkmark.circle.fill" : "circle.dashed")
                    .foregroundStyle(enabled ? .green : .secondary)
                Spacer()
                Button(enabled ? "Disable HUD" : "Enable HUD") {
                    settings.metalHUD.toggle(); saveSettings()
                }
                .fwProminentButton().tint(Look.wine)
                .disabled(selectedBottle == nil || working)
            }
            Picker("D3DMetal FPS cap", selection: Binding(get: { settings.fpsCap ?? "uncapped" }, set: { settings.fpsCap = $0 == "uncapped" ? nil : $0 })) {
                Text("Uncapped").tag("uncapped")
                Text("60 FPS").tag("60")
                Text("120 FPS").tag("120")
            }
            Button("Save FPS cap", action: saveSettings).fwButton().disabled(selectedBottle == nil || working)
        }
    }

    private var notProtonContent: some View {
        Card(title: "NotProton runner", symbol: "steamlogo",
             footnote: "Installs a dedicated FineWine-patched CrossOver runner into NotProton and a Steam compatibility-tool entry. Restart Steam after registering.") {
            let status = CrossOverTools.notProtonStatus()
            LabeledContent("Steam", value: status.steamInstalled ? "Detected" : "Not installed")
            LabeledContent("NotProton", value: status.notProtonInstalled ? "Detected" : "Not installed")
            LabeledContent("Runner", value: status.isRegistered ? "Registered" : "Not registered")
            Divider()
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Patched CrossOver app")
                    Text(patchedApp?.path ?? "Choose the app to register").font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
                Spacer()
                Button("Choose…", action: choosePatchedApp).fwButton()
            }
            HStack {
                Button(status.isRegistered ? "Update registration" : "Register in Steam Play", action: registerNotProton)
                    .fwProminentButton().tint(Look.wine)
                    .disabled(patchedApp == nil || !status.steamInstalled || working)
                if status.isRegistered {
                    Button("Unregister", role: .destructive, action: unregisterNotProton).fwButton().disabled(working)
                }
            }
        }
    }

    @ViewBuilder private var result: some View {
        if working { HStack { ProgressView(); Text("Working…").foregroundStyle(.secondary) }.glassCard(padding: 12) }
        if let notice { Label(notice, systemImage: "checkmark.circle.fill").foregroundStyle(.green).glassCard(padding: 12) }
        if let error { Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange).glassCard(padding: 12) }
    }

    private func refresh() {
        let found = CrossOverToolBottle.detected()
        bottles = found
        if selectedBottle == nil || !found.contains(selectedBottle!) {
            selectedBottle = found.first { $0.name.localizedCaseInsensitiveContains("endfield") } ?? found.first
        }
        loadBottleState()
    }

    private func loadBottleState() {
        notice = nil; error = nil
        guard let bottle = selectedBottle else { return }
        do {
            settings = try CrossOverBottleSettings.read(bottle.url)
            if tool == .efmi { efmiFolder = CrossOverTools.locateEFMI(in: bottle.url) }
        } catch { self.error = error.localizedDescription }
    }

    private func chooseBottle() {
        let panel = NSOpenPanel()
        panel.title = "Choose a CrossOver bottle or Bottles folder"
        panel.message = "Choose a bottle containing cxbottle.conf, or its Bottles folder."
        panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let found = CrossOverToolBottle.fromSelection(url)
        guard !found.isEmpty else { error = "No CrossOver bottle was found at \(url.path)."; return }
        for bottle in found where !bottles.contains(bottle) { bottles.append(bottle) }
        bottles.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        selectedBottle = found.first
    }

    private func chooseEFMI() {
        let panel = NSOpenPanel()
        panel.title = "Choose the EFMI folder"; panel.message = "Choose the folder that contains d3dx.ini."
        panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            guard FileManager.default.fileExists(atPath: url.appendingPathComponent("d3dx.ini").path) else { error = "That folder does not contain d3dx.ini."; return }
            efmiFolder = url; error = nil
        }
    }

    private func choosePatchedApp() {
        let panel = NSOpenPanel()
        panel.title = "Choose a patched CrossOver app"; panel.message = "Choose the CrossOver app that contains the FineWine backend."
        panel.allowedContentTypes = [.applicationBundle]; panel.canChooseFiles = false; panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            guard CrossOverTools.patchedAppIsUsable(url) else { error = "That app does not contain an executable CrossOver Wine runner."; return }
            patchedApp = url; error = nil
        }
    }

    private func saveSettings() {
        guard let bottle = selectedBottle else { return }
        do { try settings.write(to: bottle.url); notice = "Saved settings for \(bottle.name). Restart the bottle for changes to take effect."; error = nil }
        catch { self.error = error.localizedDescription }
    }

    private func applyEFMI() {
        guard let bottle = selectedBottle, let importer = efmiFolder, let app = patchedApp else { return }
        do { try CrossOverTools.applyEFMI(bottle: bottle.url, importer: importer, patchedApp: app); notice = "Applied the EFMI chain. Reapply after EFMI or CrossOver updates."; error = nil }
        catch { self.error = error.localizedDescription }
    }

    private func revertEFMI() {
        guard let importer = efmiFolder else { return }
        do { try CrossOverTools.revertEFMI(importer: importer); notice = "Removed FineWine's EFMI chain; existing EFMI settings were left in place."; error = nil }
        catch { self.error = error.localizedDescription }
    }

    private func registerNotProton() {
        guard let app = patchedApp else { return }
        working = true; error = nil; notice = nil
        Task.detached {
            do {
                try CrossOverTools.registerNotProton(patchedApp: app)
                await MainActor.run { working = false; notice = "Registered. Quit and reopen Steam, then choose the FineWine tool in Compatibility." }
            } catch { await MainActor.run { working = false; self.error = error.localizedDescription } }
        }
    }

    private func unregisterNotProton() {
        do { try CrossOverTools.unregisterNotProton(); notice = "Removed FineWine's NotProton runner and Steam tool."; error = nil }
        catch { self.error = error.localizedDescription }
    }
}
