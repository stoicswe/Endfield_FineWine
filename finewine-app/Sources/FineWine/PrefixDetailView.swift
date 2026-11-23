import SwiftUI
import AppKit
import FineWineCore

/// Everything about one prefix, in four tabs.
struct PrefixDetailView: View {
    enum Tab: String, CaseIterable, Identifiable {
        case programs = "Programs", configuration = "Configuration", tools = "Wine Tools", details = "Details"
        var id: String { rawValue }
        /// The tab's name in a `finewine://show` link.
        var linkName: String {
            switch self {
            case .programs: return "programs"
            case .configuration: return "configuration"
            case .tools: return "tools"
            case .details: return "details"
            }
        }
        var localizedTitle: String {
            switch self {
            case .programs: return tr("detail.tab_programs")
            case .configuration: return tr("detail.tab_config")
            case .tools: return tr("detail.tab_tools")
            case .details: return tr("detail.tab_details")
            }
        }
    }

    @EnvironmentObject private var model: AppModel
    @ObservedObject private var l10n = LanguageManager.shared
    let prefix: Prefix
    @State private var tab: Tab = .programs

    var body: some View {
        VStack(spacing: 0) {
            header
                .onAppear { takeRequestedTab() }
                .onChange(of: model.requestedSection) { takeRequestedTab() }
            Group {
                if tab == .configuration {
                    // scrolls by itself: its Apply button floats over the settings
                    ConfigurationTab(prefix: prefix)
                } else {
                    ScrollView {
                        Group {
                            switch tab {
                            case .programs: ProgramsTab(prefix: prefix)
                            case .configuration: EmptyView()
                            case .tools: ToolsTab(prefix: prefix)
                            case .details: DetailsTab(prefix: prefix)
                            }
                        }
                        .padding(20)
                        .frame(maxWidth: 760)
                        .frame(maxWidth: .infinity)
                    }
                }
            }
            .disabled(model.busy[prefix.id] != nil)
        }
    }

    /// Switches to the tab a link or the menu bar asked for, once.
    private func takeRequestedTab() {
        guard let section = model.requestedSection else { return }
        model.requestedSection = nil
        if let wanted = Tab.allCases.first(where: { $0.linkName == section }) { tab = wanted }
    }

    private var header: some View {
        VStack(spacing: 12) {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(prefix.name).font(.title.weight(.semibold)).lineLimit(1)
                    HStack(spacing: 6) {
                        if let runtime = model.runtime(for: prefix) {
                            Pill(text: runtime.name, symbol: "cpu")
                        } else {
                            Pill(text: l10n.tr("detail.no_runtime"), symbol: "exclamationmark.triangle", tint: .orange)
                        }
                        if let profile = model.profile(for: prefix) { Pill(text: profile.name, symbol: "gamecontroller") }
                        if let appID = prefix.metadata.steamAppID {
                            // made by the Steam tool for a game in the Steam library
                            Pill(text: l10n.tr("steam.prefix_pill"), symbol: "gamecontroller.fill", tint: Look.accent)
                                .help(l10n.tr("steam.prefix_pill_help", appID))
                        }
                        if let size = model.sizeText(for: prefix) {
                            Pill(text: size, symbol: "internaldrive").help(l10n.tr("prefix.size_help"))
                        }
                        if model.isRunning(prefix) { Pill(text: l10n.tr("app.running"), symbol: "play.fill", tint: .green) }
                        if prefix.metadata.settings != prefix.metadata.appliedSettings {
                            Pill(text: l10n.tr("detail.settings_not_applied"), symbol: "clock.arrow.circlepath", tint: .orange)
                        }
                    }
                }
                Spacer()
                if let status = model.busy[prefix.id] {
                    if let copy = model.copies[prefix.id] {
                        ProgressView(value: copy.fraction).frame(width: 90)
                    } else {
                        ProgressView().controlSize(.small)
                    }
                    Text(status).foregroundStyle(.secondary).monospacedDigit()
                    if model.copies[prefix.id] != nil {
                        Button(l10n.tr("app.cancel")) { model.cancelCopy(prefix.id) }.fwButton()
                    }
                } else if model.isRunning(prefix) {
                    Menu {
                        Button(l10n.tr("menu.shut_down")) { Task { await model.shutDown(prefix) } }
                        Button(l10n.tr("menu.force_shut_down"), role: .destructive) { Task { await model.forceShutDown(prefix) } }
                    } label: {
                        Label(l10n.tr("menu.shut_down"), systemImage: "power")
                    } primaryAction: {
                        Task { await model.shutDown(prefix) }
                    }
                    .menuStyle(.button)
                    .fwButton()
                    .fixedSize()
                    .help(l10n.tr("menu.shut_down_help"))
                    .help(l10n.tr("detail.stop_prefix_help"))
                }
            }
            Picker("Section", selection: $tab) {
                ForEach(Tab.allCases) { Text($0.localizedTitle).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .tint(Look.wine)
            .frame(maxWidth: 520)
        }
        .padding(.horizontal, 24)
        .padding(.top, 8)
        .padding(.bottom, 12)
    }
}

// MARK: - Programs

private struct ProgramsTab: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject private var l10n = LanguageManager.shared
    let prefix: Prefix
    @State private var editing: Program?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Button {
                    if let url = Panels.chooseExecutable(message: l10n.tr("dialog.choose_executable", prefix.name)) {
                        model.runInstaller(url, in: prefix)
                    }
                } label: {
                    Label(l10n.tr("detail.run_installer"), systemImage: "arrow.down.circle")
                }
                .fwProminentButton()
                Button {
                    addProgram()
                } label: {
                    Label(l10n.tr("detail.add_program"), systemImage: "plus")
                }
                .fwButton()
                Button {
                    model.findInstalledPrograms(in: prefix)
                } label: {
                    Label(l10n.tr("detail.find_installed"), systemImage: "magnifyingglass")
                }
                .fwButton()
                .help(l10n.tr("detail.find_installed_help"))
                Spacer()
            }

            if prefix.metadata.programs.isEmpty {
                EmptyState(symbol: "macwindow.badge.plus", title: l10n.tr("detail.no_programs_title"),
                           message: l10n.tr("detail.no_programs_desc")) { EmptyView() }
                    .frame(minHeight: 260)
            } else {
                FWGlassContainer(spacing: 12) {
                    VStack(spacing: 12) {
                        ForEach(prefix.metadata.programs) { program in
                            ProgramCard(prefix: prefix, program: program) { editing = program }
                        }
                    }
                }
            }
        }
        .sheet(item: $editing) { program in
            ProgramEditor(prefix: prefix, program: program).environmentObject(model)
        }
    }

    private func addProgram() {
        guard let url = Panels.chooseExecutable(in: prefix.driveC, message: l10n.tr("dialog.choose_program_in_prefix")) else { return }
        let name = url.deletingPathExtension().lastPathComponent
        model.addProgram(Program(name: name, windowsPath: WindowsPath.windowsPath(for: url, inPrefix: prefix.directory)), to: prefix)
    }
}

private struct ProgramCard: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject private var l10n = LanguageManager.shared
    let prefix: Prefix
    let program: Program
    let edit: () -> Void
    @State private var confirmingRemoval = false

    private var hasShortcut: Bool {
        program.shortcutPath.map { FileManager.default.fileExists(atPath: $0) } ?? false
    }

    var body: some View {
        HStack(spacing: 12) {
            ProgramIcon(shortcutPath: program.shortcutPath, size: 44)
            VStack(alignment: .leading, spacing: 3) {
                Text(program.name).font(.headline).lineLimit(1)
                Text(program.windowsPath).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                if hasShortcut { Pill(text: l10n.tr("detail.in_applications"), symbol: "checkmark", tint: .green) }
            }
            Spacer(minLength: 8)
            Menu {
                if hasShortcut {
                    Button(l10n.tr("detail.show_shortcut")) {
                        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: program.shortcutPath!)])
                    }
                    Button(l10n.tr("detail.remove_shortcut")) { model.removeShortcut(for: program.id, in: prefix) }
                } else {
                    Button(l10n.tr("detail.make_shortcut")) { model.createShortcut(for: program.id, in: prefix) }
                }
                Button(l10n.tr("app.edit"), action: edit)
                Menu(l10n.tr("detail.diagnostics")) {
                    Button(l10n.tr("detail.play_memory_log")) { model.launch(program, in: prefix, memoryTrace: true) }
                    Button(l10n.tr("context.show_logs")) {
                        let logs = model.service.paths.logs.appendingPathComponent(prefix.directory.lastPathComponent)
                        try? FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
                        NSWorkspace.shared.open(logs)
                    }
                    Button(l10n.tr("context.collect_logs")) { Task { await model.collectLogs(for: prefix) } }
                }
                Divider()
                Button(l10n.tr("detail.remove_from_finewine"), role: .destructive) { confirmingRemoval = true }
            } label: {
                Image(systemName: "ellipsis")
            }
            .menuStyle(.button)
            .menuIndicator(.hidden)
            .fwButton()
            .help(l10n.tr("detail.more_actions"))
            .fixedSize()
            Button {
                model.launch(program, in: prefix)
            } label: {
                Label(l10n.tr("app.play"), systemImage: "play.fill")
            }
            .fwProminentButton()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard(padding: 14)
        .confirmationDialog(l10n.tr("detail.remove_program_title", program.name), isPresented: $confirmingRemoval) {
            Button(l10n.tr("app.remove"), role: .destructive) { model.removeProgram(program, from: prefix) }
        } message: {
            Text(l10n.tr("detail.remove_program_msg"))
        }
    }
}

private struct ProgramEditor: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject private var l10n = LanguageManager.shared
    @Environment(\.dismiss) private var dismiss
    let prefix: Prefix
    @State var program: Program
    @State private var arguments: String
    @State private var icon: NSImage?
    private let original: Program

    init(prefix: Prefix, program: Program) {
        self.prefix = prefix
        original = program
        _program = State(initialValue: program)
        _arguments = State(initialValue: program.arguments.map { $0.contains(" ") ? "\"\($0)\"" : $0 }.joined(separator: " "))
    }

    /// Finder's panel, opened where the executable is now. The field stays editable for a
    /// path that cannot be picked.
    private func chooseExecutable() {
        let start = WindowsPath.folderToBrowse(from: program.windowsPath, inPrefix: prefix.directory)
        guard let url = Panels.chooseExecutable(in: start, message: l10n.tr("dialog.choose_program_in_prefix")) else { return }
        program.windowsPath = WindowsPath.windowsPath(for: url, inPrefix: prefix.directory)
    }

    /// The program as it will be saved. A new executable brings its own icon: the icon file
    /// the old one had is let go, unless another was chosen in this sheet.
    private var edited: Program {
        var result = program
        if result.windowsPath != original.windowsPath, result.iconPath == original.iconPath { result.iconPath = nil }
        return result
    }

    /// Finder's panel for an icon file, opened at the current icon file, else at the executable.
    private func chooseIcon() {
        let start = WindowsPath.folderToBrowse(from: edited.iconPath ?? program.windowsPath, inPrefix: prefix.directory)
        guard let url = Panels.chooseIcon(in: start, message: l10n.tr("editor.choose_icon_msg")) else { return }
        guard ICNS.data(fromIconFile: url) != nil else {
            model.alert = AppAlert(title: l10n.tr("editor.no_icon_title"), message: l10n.tr("editor.no_icon_msg", url.lastPathComponent))
            return
        }
        program.iconPath = WindowsPath.windowsPath(for: url, inPrefix: prefix.directory)
    }

    private var iconRow: some View {
        HStack {
            Text(l10n.tr("editor.icon_label")).frame(width: 90, alignment: .leading)
            Group {
                if let icon {
                    Image(nsImage: icon).resizable()
                } else {
                    Image(systemName: "macwindow").font(.system(size: 20, weight: .medium)).foregroundStyle(Look.accent)
                }
            }
            .frame(width: 40, height: 40)
            Text(edited.iconPath.map(WindowsPath.lastComponent) ?? l10n.tr("editor.icon_own"))
                .foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            Spacer()
            if edited.iconPath != nil {
                Button(l10n.tr("editor.icon_reset")) { program.iconPath = nil }.fwButton()
            }
            Button(l10n.tr("editor.choose_executable")) { chooseIcon() }.fwButton()
        }
        .task(id: [edited.iconPath ?? "", edited.windowsPath]) {
            let program = edited, prefix = prefix
            let data = await Task.detached(priority: .userInitiated) { PrefixService.iconData(for: program, in: prefix) }.value
            icon = data.flatMap(NSImage.init(data:))
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(l10n.tr("editor.title")).font(.title2.weight(.semibold))
            Card(title: l10n.tr("editor.program_card"), symbol: "macwindow") {
                LabeledField(l10n.tr("editor.name_label"), text: $program.name)
                HStack {
                    LabeledField(l10n.tr("editor.executable_label"), text: $program.windowsPath)
                    Button(l10n.tr("editor.choose_executable")) { chooseExecutable() }.fwButton()
                }
                iconRow
                LabeledField(l10n.tr("editor.args_label"), text: $arguments, prompt: l10n.tr("editor.args_prompt"))
                LabeledField(l10n.tr("editor.start_in_label"), text: $program.workingDirectory, prompt: l10n.tr("editor.start_in_prompt"))
            }
            Card(title: l10n.tr("editor.environment_card"), symbol: "terminal",
                 footnote: l10n.tr("editor.environment_footnote")) {
                EnvironmentEditor(variables: $program.environment)
            }
            HStack {
                Spacer()
                Button(l10n.tr("app.cancel")) { dismiss() }.fwButton().keyboardShortcut(.cancelAction)
                Button(l10n.tr("app.save")) {
                    var program = edited
                    program.arguments = ProgramScanner.splitArguments(arguments)
                    program.name = program.name.trimmingCharacters(in: .whitespaces)
                    model.update(program, in: prefix)
                    dismiss()
                }
                .fwProminentButton()
                .keyboardShortcut(.defaultAction)
                .disabled(program.name.trimmingCharacters(in: .whitespaces).isEmpty || program.windowsPath.isEmpty)
            }
        }
        .padding(22)
        .frame(width: 540)
        .background { Backdrop() }
    }
}

struct LabeledField: View {
    let label: String
    @Binding var text: String
    var prompt: String = ""

    init(_ label: String, text: Binding<String>, prompt: String = "") {
        self.label = label
        _text = text
        self.prompt = prompt
    }

    var body: some View {
        HStack {
            Text(label).frame(width: 90, alignment: .leading)
            TextField(prompt, text: $text).textFieldStyle(.roundedBorder)
        }
    }
}

/// Edits a list of name/value pairs.
struct EnvironmentEditor: View {
    @ObservedObject private var l10n = LanguageManager.shared
    @Binding var variables: [EnvironmentVariable]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach($variables) { $variable in
                HStack {
                    TextField("NAME", text: $variable.name)
                        .textFieldStyle(.roundedBorder)
                        .font(.body.monospaced())
                        .frame(width: 190)
                        .foregroundStyle(variable.name.isEmpty || EnvironmentVariable.isValidName(variable.name) ? Color.primary : Color.red)
                    Text("=").foregroundStyle(.secondary)
                    TextField("value", text: $variable.value)
                        .textFieldStyle(.roundedBorder)
                        .font(.body.monospaced())
                    Button {
                        variables.removeAll { $0.id == variable.id }
                    } label: {
                        Image(systemName: "minus.circle")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help(l10n.tr("editor.remove_variable"))
                }
            }
            Button {
                variables.append(EnvironmentVariable(name: "", value: ""))
            } label: {
                Label(l10n.tr("editor.add_variable"), systemImage: "plus")
            }
            .fwButton()
            .controlSize(.small)
        }
    }
}

// MARK: - Wine tools

private struct ToolsTab: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject private var l10n = LanguageManager.shared
    let prefix: Prefix

    private let columns = [GridItem(.adaptive(minimum: 220), spacing: 12)]

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            FWGlassContainer(spacing: 12) {
                LazyVGrid(columns: columns, spacing: 12) {
                    ForEach(WineTool.allCases) { tool in
                        Button {
                            Task { await model.open(tool, in: prefix) }
                        } label: {
                            VStack(alignment: .leading, spacing: 6) {
                                Image(systemName: tool.symbol).font(.title2).foregroundStyle(Look.accent)
                                Text(tool.displayName).font(.headline)
                                Text(tool.summary).font(.footnote).foregroundStyle(.secondary)
                                    .multilineTextAlignment(.leading)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            .frame(maxWidth: .infinity, minHeight: 104, alignment: .topLeading)
                            .glassCard(padding: 14, interactive: true)
                            .contentShape(.rect(cornerRadius: Look.cardRadius))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            Card(title: l10n.tr("tools.maintenance_card"), symbol: "wrench.and.screwdriver") {
                Row(label: l10n.tr("tools.restart_win_label"), detail: l10n.tr("tools.restart_win_detail")) {
                    Button(l10n.tr("tools.restart_win_btn")) { Task { await model.wineboot(.restart, in: prefix, status: l10n.tr("splash.restarting_windows")) } }
                        .fwButton()
                }
                Divider()
                Row(label: l10n.tr("tools.update_prefix_label"), detail: l10n.tr("tools.update_prefix_detail")) {
                    Button(l10n.tr("tools.update_prefix_btn")) { Task { await model.wineboot(.update, in: prefix, status: l10n.tr("splash.updating")) } }
                        .fwButton()
                }
                Divider()
                Row(label: l10n.tr("tools.shut_down_label"), detail: l10n.tr("tools.shut_down_detail")) {
                    Button(l10n.tr("menu.shut_down")) { Task { await model.shutDown(prefix) } }.fwButton()
                }
                Divider()
                Row(label: l10n.tr("tools.force_shut_down_label"), detail: l10n.tr("tools.force_shut_down_detail")) {
                    Button(l10n.tr("menu.force_shut_down"), role: .destructive) { Task { await model.forceShutDown(prefix) } }.fwButton()
                }
            }

            Card(title: l10n.tr("tools.files_card"), symbol: "folder") {
                Row(label: l10n.tr("tools.c_drive_label")) {
                    Button(l10n.tr("app.show_in_finder")) { NSWorkspace.shared.open(prefix.driveC) }.fwButton()
                }
                Divider()
                Row(label: l10n.tr("tools.logs_label"), detail: l10n.tr("tools.logs_detail")) {
                    Button(l10n.tr("app.show_in_finder")) {
                        let logs = model.service.paths.logs.appendingPathComponent(prefix.directory.lastPathComponent)
                        try? FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
                        NSWorkspace.shared.open(logs)
                    }
                    .fwButton()
                }
                Divider()
                Row(label: l10n.tr("tools.collect_logs_label"), detail: l10n.tr("tools.collect_logs_detail")) {
                    Button(l10n.tr("tools.collect_logs_btn")) { Task { await model.collectLogs(for: prefix) } }
                        .fwButton()
                }
            }
        }
    }
}

// MARK: - Details

private struct DetailsTab: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject private var l10n = LanguageManager.shared
    let prefix: Prefix
    @State private var name: String
    @State private var confirmingDelete = false
    @State private var snapshot = PrefixRegistrySnapshot()

    init(prefix: Prefix) {
        self.prefix = prefix
        _name = State(initialValue: prefix.name)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Card(title: l10n.tr("details.name_card"), symbol: "textformat") {
                HStack {
                    TextField(l10n.tr("details.name_card"), text: $name).textFieldStyle(.roundedBorder)
                    Button(l10n.tr("app.rename")) { model.rename(prefix, to: name) }
                        .fwButton()
                        .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || name == prefix.name)
                }
            }

            Card(title: l10n.tr("details.reports_card"), symbol: "doc.text.magnifyingglass",
                 footnote: l10n.tr("details.reports_footnote")) {
                info(l10n.tr("details.win_version"), snapshot.windowsVersion.flatMap { WindowsVersion(rawValue: $0)?.displayName } ?? snapshot.windowsVersion ?? l10n.tr("details.wine_default"))
                info(l10n.tr("details.build"), snapshot.windowsBuild ?? "—")
                info(l10n.tr("details.dpi"), snapshot.dpi.map(String.init) ?? "—")
                info(l10n.tr("details.retina_mode"), snapshot.retinaMode.map { $0 ? l10n.tr("app.on") : l10n.tr("app.off") } ?? "—")
                info(l10n.tr("details.virtual_desktop"), snapshot.virtualDesktop ?? l10n.tr("app.off"))
                info(l10n.tr("details.dll_overrides"), snapshot.dllOverrides.isEmpty ? l10n.tr("app.none")
                     : snapshot.dllOverrides.sorted { $0.key < $1.key }.map { "\($0.key) = \($0.value.isEmpty ? l10n.tr("details.disabled") : $0.value)" }.joined(separator: "\n"))
            }

            Card(title: l10n.tr("details.about_card"), symbol: "info.circle") {
                info(l10n.tr("details.created"), prefix.metadata.createdAt.formatted(date: .abbreviated, time: .shortened))
                info(l10n.tr("drive.stored_on_label"), model.placeName(prefix.place))
                info(l10n.tr("details.location"), prefix.directory.path)
                HStack {
                    Button(l10n.tr("app.show_in_finder")) { NSWorkspace.shared.activateFileViewerSelecting([prefix.directory]) }
                        .fwButton()
                    MoveMenu(prefix: prefix)
                }
            }

            SnapshotsCard(prefix: prefix)

            Card(title: l10n.tr("details.duplicate_delete_card"), symbol: "square.on.square") {
                Row(label: l10n.tr("details.duplicate_label"), detail: l10n.tr("details.duplicate_detail")) {
                    Button(l10n.tr("app.duplicate")) { Task { await model.duplicate(prefix) } }.fwButton()
                }
                Divider()
                Row(label: l10n.tr("details.delete_label"), detail: l10n.tr("details.delete_detail")) {
                    Button(l10n.tr("app.delete"), role: .destructive) { confirmingDelete = true }.fwButton()
                }
            }
        }
        .onAppear { snapshot = PrefixRegistrySnapshot.read(prefix: prefix.directory) }
        .onChange(of: prefix.metadata.appliedSettings) { snapshot = PrefixRegistrySnapshot.read(prefix: prefix.directory) }
        .confirmationDialog(l10n.tr("details.delete_confirm_title", prefix.name), isPresented: $confirmingDelete) {
            Button(l10n.tr("context.delete_action"), role: .destructive) { Task { await model.delete(prefix) } }
        } message: {
            Text(l10n.tr("details.delete_confirm_msg"))
        }
    }

    private func info(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label).foregroundStyle(.secondary).frame(width: 130, alignment: .leading)
            Text(value).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            Spacer()
        }
    }
}
