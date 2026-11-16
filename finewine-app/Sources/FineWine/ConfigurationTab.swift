import SwiftUI
import FineWineCore

/// The prefix's settings. Edits go to a draft; Apply stores them and writes them to the registry.
struct ConfigurationTab: View {
    @EnvironmentObject private var model: AppModel
    let prefix: Prefix
    @State private var draft: PrefixSettings
    @State private var runtimeID: String?
    @State private var desktopEnabled: Bool
    @State private var desktopWidth: Int
    @State private var desktopHeight: Int

    init(prefix: Prefix) {
        self.prefix = prefix
        _draft = State(initialValue: prefix.metadata.settings)
        _runtimeID = State(initialValue: prefix.metadata.runtimeID)
        _desktopEnabled = State(initialValue: prefix.metadata.settings.virtualDesktop != nil)
        _desktopWidth = State(initialValue: prefix.metadata.settings.virtualDesktop?.width ?? 1920)
        _desktopHeight = State(initialValue: prefix.metadata.settings.virtualDesktop?.height ?? 1080)
    }

    /// The draft with the virtual desktop fields folded in.
    private var edited: PrefixSettings {
        var settings = draft
        settings.virtualDesktop = desktopEnabled ? VirtualDesktop(width: desktopWidth, height: desktopHeight) : nil
        return settings
    }

    private var hasChanges: Bool {
        edited != prefix.metadata.settings || runtimeID != prefix.metadata.runtimeID
            || prefix.metadata.settings != prefix.metadata.appliedSettings
    }

    private var selectedRuntime: WineRuntime? { model.runtimes.first { $0.id == runtimeID } }

    var body: some View {
        let problems = edited.validationProblems()
        VStack(alignment: .leading, spacing: 16) {
            applyBar(problems: problems)

            Card(title: "Windows", symbol: "macwindow") {
                Row(label: "Windows version") {
                    Picker("Windows version", selection: $draft.windowsVersion) {
                        ForEach(WindowsVersion.allCases, id: \.self) { Text($0.displayName).tag($0) }
                    }
                    .labelsHidden().fixedSize()
                }
                Divider()
                Row(label: "Build number", detail: "Leave empty for Wine's own. Some games want a specific build, such as 26100.") {
                    TextField("Default", text: $draft.windowsBuild)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 110)
                }
                Divider()
                Row(label: "Wine runtime") {
                    Picker("Runtime", selection: $runtimeID) {
                        if selectedRuntime == nil { Text("None").tag(String?.none) }
                        ForEach(model.runtimes) { Text($0.name).tag(Optional($0.id)) }
                    }
                    .labelsHidden().fixedSize()
                }
            }

            Card(title: "Graphics", symbol: "display", footnote: graphicsNote) {
                Row(label: "Direct3D", detail: GraphicsBackend.scopeNote) {
                    Picker("Direct3D", selection: $draft.graphicsBackend) {
                        ForEach(GraphicsBackend.allCases, id: \.self) { Text($0.displayName).tag($0) }
                    }
                    .labelsHidden().fixedSize()
                }
                Divider()
                Toggle(isOn: $draft.retinaMode) {
                    Text("High-resolution mode")
                    Text("Programs draw at the display's real pixel resolution, so they are as sharp as Mac apps. Turn it off if a program runs too slowly at full resolution.")
                }
                Divider()
                Toggle(isOn: $draft.automaticDPI) {
                    Text("Scale automatically")
                    Text(draft.retinaMode
                         ? "Sets the Windows DPI from the display (\(draft.effectiveDPI(displayScale: model.currentAppearance.displayScale)) on this Mac), so text and controls keep their normal size."
                         : "Keeps the Windows DPI at 96, which matches macOS when high-resolution mode is off.")
                }
                if !draft.automaticDPI {
                    Row(label: "Screen DPI", detail: "96 is 100% scaling; 192 suits high-resolution mode on a Retina display.") {
                        Stepper(value: $draft.dpi, in: 72...480, step: 12) {
                            Text("\(draft.dpi)").monospacedDigit()
                        }
                    }
                }
                Divider()
                Toggle(isOn: $desktopEnabled) {
                    Text("Virtual desktop")
                    Text("Keeps the prefix's windows inside one window. Helps programs that misbehave in full screen.")
                }
                if desktopEnabled {
                    HStack {
                        TextField("Width", value: $desktopWidth, format: .number.grouping(.never))
                            .textFieldStyle(.roundedBorder).frame(width: 80)
                        Text("×").foregroundStyle(.secondary)
                        TextField("Height", value: $desktopHeight, format: .number.grouping(.never))
                            .textFieldStyle(.roundedBorder).frame(width: 80)
                    }
                }
                Divider()
                Toggle(isOn: $draft.dlssThroughMetalFX) {
                    Text("DLSS through MetalFX")
                    Text(draft.graphicsBackend == .dxmt
                         ? "Games that offer NVIDIA DLSS use Apple's MetalFX instead, for upscaling and for frame generation. FSR is unaffected: it runs as the game ships it."
                         : "Direct3D 12 and Vulkan games that offer NVIDIA DLSS use Apple's MetalFX instead. Direct3D 11 games need DXMT as the Direct3D layer. FSR is unaffected.")
                }
                Toggle(isOn: $draft.reportNvidiaGPU) {
                    Text("Report an NVIDIA GPU")
                    Text("Tells Windows programs the GPU is an \(PrefixSettings.reportedGPUName), by name and by id. Most games only show DLSS options on an NVIDIA GPU. Leave it off for games with NVIDIA-specific code paths you do not want.")
                }
                Row(label: "Full screen", detail: "How a game's full-screen window is shown. With its own Space the menu bar appears at the top edge, a swipe goes back to the desktop, and notifications show over the game.") {
                    Picker("Full screen", selection: $draft.fullScreenMode) {
                        ForEach(FullScreenMode.allCases, id: \.self) { Text($0.displayName).tag($0) }
                    }
                    .labelsHidden().fixedSize()
                }
                Toggle(isOn: $draft.roundedWindows) {
                    Text("Round window corners")
                    Text("Windows that draw their own title bar, as launchers and many games do, get the round corners of a Mac window. Full-screen windows, menus and windows with a shape of their own are left as they are.")
                }
                Toggle(isOn: $draft.gameMode) {
                    Text("Game Mode")
                    Text("Programs that use Direct3D, Vulkan or OpenGL are started as games, so macOS turns Game Mode on while one is full screen. A program started by a launcher is recognised from its second run on.")
                }
                Toggle(isOn: $draft.steamForHoYoverse) {
                    Text("Start HoYoverse games as Steam does")
                    Text("Genshin Impact, Zenless Zone Zero, Honkai Impact 3rd and the HoYoPlay launcher are started through a stand-in for the Steam client, the way they are run on Linux. The game is told it was started by Steam, which is not a platform HoYoverse supports on a Mac; use it at your own account's risk.")
                }
                Divider()
                Toggle(isOn: $draft.metalHUD) {
                    Text("Start with the Metal performance overlay shown")
                    Text("Frame rate and GPU statistics over the game. Either way it can be shown and hidden while a game runs: View > Metal HUD in the menu bar, or Option-F12.")
                }
            }

            Card(title: "Performance and compatibility", symbol: "speedometer", footnote: syncNote) {
                Row(label: "Synchronisation", detail: "How Windows events, mutexes and semaphores are handled.") {
                    Picker("Synchronisation", selection: $draft.syncMode) {
                        ForEach(SyncMode.allCases, id: \.self) { Text($0.displayName).tag($0) }
                    }
                    .labelsHidden().fixedSize()
                }
                Divider()
                Toggle(isOn: $draft.hideHypervisor) {
                    Text("Hide the hypervisor flag")
                    Text("Stops x64 programs from seeing that they run under emulation. Some games refuse to start otherwise.")
                }
            }

            Card(title: "Appearance", symbol: "paintbrush",
                 footnote: "Applies to anything in this prefix that uses standard Windows controls, including the Wine tools. Window frames and title bars are always drawn by macOS. Games that draw their own interface are not affected.") {
                Toggle(isOn: $draft.macAppearance) {
                    Text("Match macOS")
                    Text("Windows controls take the Mac's light or dark colours, its accent colour and a Mac font. It is refreshed when a Wine tool is opened after the Mac's appearance changes.")
                }
            }

            Card(title: "Keyboard", symbol: "keyboard") {
                Toggle("Left Option key acts as Alt", isOn: $draft.leftOptionIsAlt)
                Toggle("Right Option key acts as Alt", isOn: $draft.rightOptionIsAlt)
            }

            Card(title: "DLL overrides", symbol: "puzzlepiece.extension",
                 footnote: "Chooses between a DLL that came with a program (native) and Wine's own (built in).") {
                ForEach($draft.dllOverrides) { $override in
                    HStack {
                        TextField("d3d11", text: $override.name)
                            .textFieldStyle(.roundedBorder)
                            .font(.body.monospaced())
                            .frame(width: 200)
                        Picker("Order", selection: $override.order) {
                            ForEach(DLLLoadOrder.allCases, id: \.self) { Text($0.displayName).tag($0) }
                        }
                        .labelsHidden()
                        Button {
                            draft.dllOverrides.removeAll { $0.id == override.id }
                        } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.plain).foregroundStyle(.secondary)
                        .help("Remove this override")
                    }
                }
                Button {
                    draft.dllOverrides.append(DLLOverride(name: "", order: .nativeThenBuiltin))
                } label: {
                    Label("Add Override", systemImage: "plus")
                }
                .buttonStyle(.glass).controlSize(.small)
            }

            Card(title: "Environment variables", symbol: "terminal",
                 footnote: "Set for every program in this prefix.") {
                EnvironmentEditor(variables: $draft.environment)
            }

            Card(title: "Debugging", symbol: "ladybug",
                 footnote: "Wine debug channels (WINEDEBUG). “-all” is silent and fastest; “err+all” logs errors. Output goes to the prefix's logs.") {
                TextField("-all", text: $draft.debugChannels)
                    .textFieldStyle(.roundedBorder)
                    .font(.body.monospaced())
            }
        }
        .onChange(of: prefix.metadata.settings) { _, new in
            // Applied elsewhere (or just now): take the stored settings as the new baseline.
            draft = new
            desktopEnabled = new.virtualDesktop != nil
        }
    }

    private var syncNote: String? {
        draft.syncMode == .msync
            ? "MSync needs a runtime built with it; FineWine's own runtime is. Every program in a prefix must use the same setting, so stop running programs before changing it."
            : nil
    }

    private var graphicsNote: String? {
        guard draft.graphicsBackend != .wined3d, let runtime = selectedRuntime else { return nil }
        if runtime.graphicsSpec(for: draft.graphicsBackend) == nil {
            return "“\(runtime.name)” doesn't include \(draft.graphicsBackend.rawValue.uppercased()), so programs will use WineD3D until a runtime that has it is chosen."
        }
        return nil
    }

    private func applyBar(problems: [String]) -> some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                if !problems.isEmpty {
                    ForEach(problems, id: \.self) { problem in
                        Label(problem, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                    }
                } else if hasChanges {
                    Label(model.isRunning(prefix)
                          ? "Changes apply to programs started after this. Running ones keep their old settings."
                          : "You have changes that aren't applied yet.",
                          systemImage: "pencil.circle")
                } else {
                    Label("These settings are applied.", systemImage: "checkmark.circle").foregroundStyle(.secondary)
                }
            }
            .font(.callout)
            Spacer()
            Button("Revert") {
                draft = prefix.metadata.settings
                runtimeID = prefix.metadata.runtimeID
                desktopEnabled = draft.virtualDesktop != nil
            }
            .buttonStyle(.glass)
            .disabled(edited == prefix.metadata.settings && runtimeID == prefix.metadata.runtimeID)
            Button("Apply") {
                Task { await model.apply(edited, runtimeID: runtimeID, to: prefix) }
            }
            .buttonStyle(.glassProminent).tint(Look.wine)
            .disabled(!hasChanges || !problems.isEmpty)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard(padding: 14, tint: problems.isEmpty && hasChanges ? Look.wine : nil)
    }
}
