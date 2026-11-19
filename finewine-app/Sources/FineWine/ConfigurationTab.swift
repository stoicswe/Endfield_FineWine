import SwiftUI
import FineWineCore

/// The prefix's settings. Edits go to a draft; Apply stores them and writes them to the registry.
struct ConfigurationTab: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject private var l10n = LanguageManager.shared
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

    /// Whether the chosen runtime is without a FineWine feature: its settings are greyed out,
    /// as nothing in that runtime would act on them.
    private func lacks(_ capability: RuntimeCapability) -> Bool {
        selectedRuntime.map { !$0.supports(capability) } ?? false
    }

    private var limitedRuntimeNote: String? {
        guard let runtime = selectedRuntime, runtime.capabilities.count < RuntimeCapability.allCases.count else { return nil }
        return l10n.tr("config.runtime_limited", runtime.name)
    }

    var body: some View {
        let problems = edited.validationProblems()
        VStack(alignment: .leading, spacing: 16) {
            applyBar(problems: problems)

            if let note = limitedRuntimeNote {
                Label(note, systemImage: "info.circle")
                    .font(.callout).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .glassCard(padding: 14)
            }

            Card(title: l10n.tr("config.windows_card"), symbol: "macwindow") {
                Row(label: l10n.tr("config.win_version_label")) {
                    Picker(l10n.tr("config.win_version_label"), selection: $draft.windowsVersion) {
                        ForEach(WindowsVersion.allCases, id: \.self) { Text($0.displayName).tag($0) }
                    }
                    .labelsHidden().fixedSize()
                }
                Divider()
                Row(label: l10n.tr("config.build_number_label"), detail: l10n.tr("config.build_number_detail")) {
                    TextField(l10n.tr("app.default"), text: $draft.windowsBuild)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 110)
                }
                Divider()
                Row(label: l10n.tr("config.nonunicode_label"), detail: l10n.tr("config.nonunicode_detail")) {
                    Picker(l10n.tr("config.nonunicode_label"), selection: $draft.nonUnicodeLanguage) {
                        ForEach(NonUnicodeLanguage.allCases, id: \.self) { Text($0.displayName).tag($0) }
                    }
                    .labelsHidden().fixedSize()
                }
                Divider()
                Row(label: l10n.tr("config.runtime_label")) {
                    Picker(l10n.tr("config.runtime_label"), selection: $runtimeID) {
                        if selectedRuntime == nil { Text(l10n.tr("app.none")).tag(String?.none) }
                        ForEach(model.runtimes) { Text($0.name).tag(Optional($0.id)) }
                    }
                    .labelsHidden().fixedSize()
                }
            }

            Card(title: l10n.tr("config.graphics_card"), symbol: "display", footnote: graphicsNote) {
                Row(label: l10n.tr("config.direct3d_label"), detail: GraphicsBackend.scopeNote) {
                    Picker(l10n.tr("config.direct3d_label"), selection: $draft.graphicsBackend) {
                        ForEach(GraphicsBackend.allCases, id: \.self) { Text($0.displayName).tag($0) }
                    }
                    .labelsHidden().fixedSize()
                }
                Divider()
                Toggle(isOn: $draft.retinaMode) {
                    Text(l10n.tr("config.retina_title"))
                    Text(l10n.tr("config.retina_desc"))
                }
                Divider()
                Toggle(isOn: $draft.metalFXUpscaling) {
                    Text(l10n.tr("config.metalfx_upscale_title"))
                    Text(l10n.tr("config.metalfx_upscale_desc"))
                }
                .disabled(lacks(.upscaling))
                Divider()
                Toggle(isOn: $draft.renderSizeEnabled) {
                    Text(l10n.tr("config.render_size_title"))
                    Text(l10n.tr("config.render_size_desc"))
                }
                .disabled(draft.metalFXUpscaling || lacks(.upscaling))
                if !draft.metalFXUpscaling && draft.renderSizeEnabled {
                    HStack(spacing: 12) {
                        Slider(value: Binding(get: { Double(draft.renderScale) },
                                              set: { draft.renderScale = Int(($0 / 5).rounded()) * 5 }),
                               in: Double(PrefixSettings.renderScaleRange.lowerBound)...Double(PrefixSettings.renderScaleRange.upperBound),
                               step: 5)
                        Text(renderSizeLabel(draft.renderScale))
                            .font(.callout.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .frame(minWidth: 190, alignment: .trailing)
                    }
                }
                Divider()
                Toggle(isOn: $draft.automaticDPI) {
                    Text(l10n.tr("config.auto_dpi_title"))
                    Text(draft.retinaMode
                         ? l10n.tr("config.auto_dpi_desc_retina", "\(draft.effectiveDPI(displayScale: model.currentAppearance.displayScale))")
                         : l10n.tr("config.auto_dpi_desc_normal"))
                }
                if !draft.automaticDPI {
                    Row(label: l10n.tr("config.screen_dpi_label"), detail: l10n.tr("config.screen_dpi_detail")) {
                        Stepper(value: $draft.dpi, in: 72...480, step: 12) {
                            Text("\(draft.dpi)").monospacedDigit()
                        }
                    }
                }
                Divider()
                Toggle(isOn: $desktopEnabled) {
                    Text(l10n.tr("config.virtual_desktop_title"))
                    Text(l10n.tr("config.virtual_desktop_desc"))
                }
                if desktopEnabled {
                    HStack {
                        TextField(l10n.tr("config.width_label"), value: $desktopWidth, format: .number.grouping(.never))
                            .textFieldStyle(.roundedBorder).frame(width: 80)
                        Text("×").foregroundStyle(.secondary)
                        TextField(l10n.tr("config.height_label"), value: $desktopHeight, format: .number.grouping(.never))
                            .textFieldStyle(.roundedBorder).frame(width: 80)
                    }
                }
                Divider()
                Toggle(isOn: $draft.dlssThroughMetalFX) {
                    Text(l10n.tr("config.dlss_metalfx_title"))
                    Text(draft.graphicsBackend == .dxmt
                         ? l10n.tr("config.dlss_metalfx_dxmt_desc")
                         : l10n.tr("config.dlss_metalfx_general_desc"))
                }
                .disabled(lacks(.dlss))
                Toggle(isOn: $draft.reportNvidiaGPU) {
                    Text(l10n.tr("config.report_nvidia_title"))
                    Text(l10n.tr("config.report_nvidia_desc", PrefixSettings.reportedGPUName))
                }
                .disabled(lacks(.gpuIdentity))
                Row(label: l10n.tr("config.fullscreen_label"), detail: l10n.tr("config.fullscreen_detail")) {
                    Picker(l10n.tr("config.fullscreen_label"), selection: $draft.fullScreenMode) {
                        ForEach(FullScreenMode.allCases, id: \.self) { Text($0.displayName).tag($0) }
                    }
                    .labelsHidden().fixedSize()
                }
                .disabled(lacks(.fullScreenModes))
                Toggle(isOn: $draft.roundedWindows) {
                    Text(l10n.tr("config.rounded_windows_title"))
                    Text(l10n.tr("config.rounded_windows_desc"))
                }
                .disabled(lacks(.roundedWindows))
                Toggle(isOn: $draft.gameMode) {
                    Text(l10n.tr("config.game_mode_title"))
                    Text(l10n.tr("config.game_mode_desc"))
                }
                .disabled(lacks(.gameMode))
                Toggle(isOn: $draft.steamForHoYoverse) {
                    Text(l10n.tr("config.hoyoverse_steam_title"))
                    Text(l10n.tr("config.hoyoverse_steam_desc"))
                }
                .disabled(lacks(.steamStandIn))
                Divider()
                Toggle(isOn: $draft.metalHUD) {
                    Text(l10n.tr("config.metal_hud_title"))
                    Text(l10n.tr("config.metal_hud_desc"))
                }
                .disabled(lacks(.metalHUD))
            }

            Card(title: l10n.tr("config.perf_card"), symbol: "speedometer", footnote: syncNote) {
                Row(label: l10n.tr("config.sync_label"), detail: l10n.tr("config.sync_detail")) {
                    Picker(l10n.tr("config.sync_label"), selection: $draft.syncMode) {
                        ForEach(SyncMode.allCases, id: \.self) { Text($0.displayName).tag($0) }
                    }
                    .labelsHidden().fixedSize()
                }
                .disabled(lacks(.msync))
                Divider()
                Toggle(isOn: $draft.hideHypervisor) {
                    Text(l10n.tr("config.hide_hypervisor_title"))
                    Text(l10n.tr("config.hide_hypervisor_desc"))
                }
                .disabled(lacks(.emulator))
                Divider()
                Toggle(isOn: $draft.zeroPages) {
                    Text(l10n.tr("config.zero_pages_title"))
                    Text(l10n.tr("config.zero_pages_desc"))
                }
                .disabled(lacks(.zeroPages))
                Divider()
                Toggle(isOn: $draft.compactBlockRecords) {
                    Text(l10n.tr("config.compact_records_title"))
                    Text(l10n.tr("config.compact_records_desc"))
                }
                .disabled(lacks(.emulator))
            }

            Card(title: l10n.tr("config.appearance_card"), symbol: "paintbrush",
                 footnote: l10n.tr("config.appearance_footnote")) {
                Toggle(isOn: $draft.macAppearance) {
                    Text(l10n.tr("config.mac_appearance_title"))
                    Text(l10n.tr("config.mac_appearance_desc"))
                }
                Divider()
                Toggle(isOn: $draft.macStyleIcons) {
                    Text(l10n.tr("config.mac_icons_title"))
                    Text(l10n.tr("config.mac_icons_desc"))
                }
                .disabled(lacks(.macIcons))
            }

            Card(title: l10n.tr("config.keyboard_card"), symbol: "keyboard") {
                Toggle(l10n.tr("config.left_opt_alt"), isOn: $draft.leftOptionIsAlt)
                Toggle(l10n.tr("config.right_opt_alt"), isOn: $draft.rightOptionIsAlt)
            }

            Card(title: l10n.tr("config.dll_overrides_card"), symbol: "puzzlepiece.extension",
                 footnote: l10n.tr("config.dll_overrides_footnote")) {
                ForEach($draft.dllOverrides) { $override in
                    HStack {
                        TextField("d3d11", text: $override.name)
                            .textFieldStyle(.roundedBorder)
                            .font(.body.monospaced())
                            .frame(width: 200)
                        Picker(l10n.tr("config.order_label"), selection: $override.order) {
                            ForEach(DLLLoadOrder.allCases, id: \.self) { Text($0.displayName).tag($0) }
                        }
                        .labelsHidden()
                        Button {
                            draft.dllOverrides.removeAll { $0.id == override.id }
                        } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.plain).foregroundStyle(.secondary)
                        .help(l10n.tr("config.remove_override"))
                    }
                }
                Button {
                    draft.dllOverrides.append(DLLOverride(name: "", order: .nativeThenBuiltin))
                } label: {
                    Label(l10n.tr("config.add_override"), systemImage: "plus")
                }
                .fwButton().controlSize(.small)
            }

            Card(title: l10n.tr("config.env_card"), symbol: "terminal",
                 footnote: l10n.tr("config.env_footnote")) {
                EnvironmentEditor(variables: $draft.environment)
            }

            Card(title: l10n.tr("config.debug_card"), symbol: "ladybug",
                 footnote: l10n.tr("config.debug_footnote")) {
                TextField("-all", text: $draft.debugChannels)
                    .textFieldStyle(.roundedBorder)
                    .font(.body.monospaced())
                Divider()
                Toggle(isOn: $draft.streamlineLog) {
                    Text(l10n.tr("config.streamline_log_title"))
                    Text(l10n.tr("config.streamline_log_desc", PrefixSettings.streamlineLogName))
                }
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
            ? l10n.tr("config.msync_note")
            : nil
    }

    private var graphicsNote: String? {
        guard draft.graphicsBackend != .wined3d, let runtime = selectedRuntime else { return nil }
        if runtime.graphicsSpec(for: draft.graphicsBackend) == nil {
            return l10n.tr("config.graphics_note", runtime.name, draft.graphicsBackend.rawValue.uppercased())
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
                          ? l10n.tr("config.changes_running")
                          : l10n.tr("config.changes_pending"),
                          systemImage: "pencil.circle")
                } else {
                    Label(l10n.tr("config.settings_applied"), systemImage: "checkmark.circle").foregroundStyle(.secondary)
                }
            }
            .font(.callout)
            Spacer()
            Button(l10n.tr("app.revert")) {
                draft = prefix.metadata.settings
                runtimeID = prefix.metadata.runtimeID
                desktopEnabled = draft.virtualDesktop != nil
            }
            .fwButton()
            .disabled(edited == prefix.metadata.settings && runtimeID == prefix.metadata.runtimeID)
            Button(l10n.tr("app.apply")) {
                Task { await model.apply(edited, runtimeID: runtimeID, to: prefix) }
            }
            .fwProminentButton().tint(Look.wine)
            .disabled(!hasChanges || !problems.isEmpty)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard(padding: 14, tint: problems.isEmpty && hasChanges ? Look.wine : nil)
    }
}


/// "75% · about 2268 × 1473": the screen a program sees at a render size, on the main display.
@MainActor
private func renderSizeLabel(_ percent: Int) -> String {
    guard let screen = NSScreen.main else { return "\(percent)%" }
    let scale = screen.backingScaleFactor
    let width = Int((screen.frame.width * scale * Double(percent) / 100).rounded())
    let height = Int((screen.frame.height * scale * Double(percent) / 100).rounded())
    return LanguageManager.shared.tr("config.render_size_value", percent, width, height)
}
