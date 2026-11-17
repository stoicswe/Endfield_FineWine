import SwiftUI
import AppKit
import FineWineCore

/// The prefix manager: prefixes in the sidebar, the selected one's programs and settings beside it.
struct MainWindow: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject private var l10n = LanguageManager.shared
    @Environment(\.openSettings) private var openSettings
    @State private var showingNewPrefix = false

    var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            ZStack {
                Backdrop()
                detail
            }
            // A prefix being made for a file opened from Finder: it takes a few seconds before
            // the program appears, and without this nothing would say why.
            .overlay(alignment: .bottom) {
                if let name = model.settingUpPrefixName {
                    HStack(spacing: 10) {
                        ProgressView().controlSize(.small)
                        Text(l10n.tr("menu.setting_up_prefix", name))
                    }
                    .padding(.horizontal, 16).padding(.vertical, 10)
                    .fwGlass(in: Capsule())
                    .padding(.bottom, 18)
                }
            }
        }
        .frame(minWidth: 860, minHeight: 560)
        .sheet(isPresented: $showingNewPrefix) {
            NewPrefixSheet().environmentObject(model)
        }
        .alert(item: $model.alert) { alert in
            Alert(title: Text(alert.title), message: Text(alert.message), dismissButton: .default(Text(l10n.tr("app.ok"))))
        }
        // While the manager is open FineWine behaves like a regular app (Dock icon, ⌘-Tab);
        // with it closed it goes back to being only a menu bar item.
        .onAppear {
            NSApp.setActivationPolicy(.regular)
            NSApp.activate()
            model.reload()
        }
        .onDisappear { NSApp.setActivationPolicy(.accessory) }
    }

    private var sidebar: some View {
        List(selection: $model.selection) {
            Section(l10n.tr("main.prefixes")) {
                ForEach(model.prefixes) { prefix in
                    HStack(spacing: 8) {
                        Image(systemName: "shippingbox")
                            .foregroundStyle(Look.accent)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(prefix.name).lineLimit(1)
                            Text(subtitle(for: prefix)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer()
                        if model.busy[prefix.id] != nil {
                            ProgressView().controlSize(.small)
                        } else if model.isRunning(prefix) {
                            Circle().fill(.green).frame(width: 8, height: 8)
                                .accessibilityLabel(l10n.tr("app.running"))
                        }
                    }
                    .tag(prefix.id)
                    .contextMenu { PrefixContextMenu(prefix: prefix) }
                }
            }
        }
        .navigationSplitViewColumnWidth(min: 210, ideal: 240, max: 320)
        .safeAreaInset(edge: .bottom) {
            HStack {
                Button {
                    showingNewPrefix = true
                } label: {
                    Label(l10n.tr("main.new_prefix"), systemImage: "plus")
                }
                .fwButton()
                Spacer()
                Button {
                    openSettings()
                } label: {
                    Image(systemName: "gearshape")
                }
                .fwButton()
                .help(l10n.tr("main.settings_tooltip"))
            }
            .padding(12)
        }
    }

    private func subtitle(for prefix: Prefix) -> String {
        let count = prefix.metadata.programs.count
        let programs = count == 1 ? l10n.tr("main.program_count_single") : l10n.tr("main.program_count_multiple", count)
        return model.profile(for: prefix).map { "\($0.name) · \(programs)" } ?? programs
    }

    @ViewBuilder
    private var detail: some View {
        if let prefix = model.prefix(model.selection) {
            PrefixDetailView(prefix: prefix).id(prefix.id)
        } else if model.usableRuntimes.isEmpty {
            EmptyState(symbol: "wineglass", title: l10n.tr("main.add_runtime_title"),
                       message: l10n.tr("main.add_runtime_desc")) {
                Button(l10n.tr("main.add_runtime_btn")) {
                    if let folder = Panels.chooseFolder(message: l10n.tr("dialog.choose_runtime_folder")) { model.addRuntime(from: folder) }
                }
                .fwProminentButton().tint(Look.wine)
                .controlSize(.large)
            }
        } else {
            EmptyState(symbol: "shippingbox", title: l10n.tr("main.first_prefix_title"),
                       message: l10n.tr("main.first_prefix_desc")) {
                Button(l10n.tr("main.first_prefix_btn")) { showingNewPrefix = true }
                    .fwProminentButton().tint(Look.wine)
                    .controlSize(.large)
            }
        }
    }
}

/// Asks for a name, runtime and profile, then creates the prefix.
struct NewPrefixSheet: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject private var l10n = LanguageManager.shared
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var runtimeID: String?
    @State private var profileID = GameProfile.generic.id

    private var profile: GameProfile? { model.profiles.first { $0.id == profileID } }
    private var runtime: WineRuntime? { model.usableRuntimes.first { $0.id == runtimeID } ?? model.usableRuntimes.first }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(l10n.tr("sheet.new_prefix_title")).font(.title2.weight(.semibold))

            Card(title: l10n.tr("sheet.name_title"), symbol: "textformat") {
                TextField(l10n.tr("sheet.name_placeholder"), text: $name)
                    .textFieldStyle(.roundedBorder)
            }

            Card(title: l10n.tr("sheet.setup_title"), symbol: "slider.horizontal.3") {
                Row(label: l10n.tr("sheet.profile_label"), detail: profile?.summary) {
                    Picker(l10n.tr("sheet.profile_label"), selection: $profileID) {
                        ForEach(model.profiles) { Text($0.name).tag($0.id) }
                    }
                    .labelsHidden()
                    .fixedSize()
                }
                if let notes = profile?.notes, !notes.isEmpty {
                    ForEach(notes, id: \.self) { note in
                        Label(note, systemImage: "info.circle").font(.footnote).foregroundStyle(.secondary)
                    }
                }
                Divider()
                if model.usableRuntimes.isEmpty {
                    Label(l10n.tr("sheet.no_runtime_warning"), systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                } else {
                    Row(label: l10n.tr("sheet.runtime_label")) {
                        Picker(l10n.tr("sheet.runtime_label"), selection: Binding(get: { runtime?.id }, set: { runtimeID = $0 })) {
                            ForEach(model.usableRuntimes) { Text($0.name).tag(Optional($0.id)) }
                        }
                        .labelsHidden()
                        .fixedSize()
                    }
                }
            }

            HStack {
                if model.isCreatingPrefix {
                    ProgressView().controlSize(.small)
                    Text(l10n.tr("sheet.setting_up_windows")).foregroundStyle(.secondary)
                }
                Spacer()
                Button(l10n.tr("app.cancel")) { dismiss() }
                    .fwButton()
                    .keyboardShortcut(.cancelAction)
                    .disabled(model.isCreatingPrefix)
                Button(l10n.tr("app.create")) {
                    guard let runtime else { return }
                    Task {
                        if await model.createPrefix(name: name, runtime: runtime, profile: profile) { dismiss() }
                    }
                }
                .fwProminentButton().tint(Look.wine)
                .keyboardShortcut(.defaultAction)
                .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || runtime == nil || model.isCreatingPrefix)
            }
        }
        .padding(22)
        .frame(width: 480)
        .background { Backdrop() }
        .interactiveDismissDisabled(model.isCreatingPrefix)
    }
}

/// App-wide settings: the Wine runtimes and whether FineWine starts at login.
struct SettingsView: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject private var l10n = LanguageManager.shared

    private var discordStatus: String {
        if !model.showsDiscordPresence { return l10n.tr("settings.discord_status_off") }
        if model.discordApplicationID.isEmpty { return l10n.tr("settings.discord_status_needed") }
        switch model.discordState {
        case .idle: return l10n.tr("settings.discord_status_ready")
        case .noDiscord: return l10n.tr("settings.discord_status_not_running")
        case .refused: return l10n.tr("settings.discord_status_refused")
        case .showing(let game): return l10n.tr("settings.discord_status_showing", game)
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Card(title: l10n.tr("settings.language_card"), symbol: "globe") {
                    Row(label: l10n.tr("settings.language_label")) {
                        Picker(l10n.tr("settings.language_label"), selection: $l10n.selectedLanguage) {
                            ForEach(AppLanguage.allCases) { lang in
                                Text(lang.displayName).tag(lang)
                            }
                        }
                        .labelsHidden().fixedSize()
                    }
                }

                Card(title: l10n.tr("settings.runtimes_card"), symbol: "cpu",
                     footnote: l10n.tr("settings.runtimes_footnote")) {
                    if model.runtimes.isEmpty {
                        Text(l10n.tr("settings.no_runtimes")).foregroundStyle(.secondary)
                    }
                    ForEach(model.runtimes) { runtime in
                        RuntimeRow(runtime: runtime)
                        if runtime.id != model.runtimes.last?.id { Divider() }
                    }
                    Button(l10n.tr("main.add_runtime_btn")) {
                        if let folder = Panels.chooseFolder(message: l10n.tr("dialog.choose_runtime_folder")) { model.addRuntime(from: folder) }
                    }
                    .fwButton()
                }

                Card(title: l10n.tr("settings.discord_card"), symbol: "bubble.left.and.bubble.right",
                     footnote: l10n.tr("settings.discord_footnote")) {
                    Toggle(isOn: Binding(get: { model.showsDiscordPresence }, set: { model.showsDiscordPresence = $0 })) {
                        Text(l10n.tr("settings.discord_toggle_title"))
                        Text(l10n.tr("settings.discord_toggle_desc"))
                    }
                    Divider()
                    Row(label: l10n.tr("settings.discord_app_id"), detail: discordStatus) {
                        TextField(l10n.tr("settings.discord_app_id"), text: Binding(get: { model.discordApplicationID },
                                                                 set: { model.discordApplicationID = $0 }))
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 200)
                            .labelsHidden()
                    }
                }

                Card(title: l10n.tr("settings.support_card"), symbol: "heart",
                     footnote: l10n.tr("settings.support_footnote")) {
                    Row(label: l10n.tr("settings.donate_row_label"), detail: l10n.tr("settings.donate_row_desc")) {
                        Button(l10n.tr("menu.donate")) { NSWorkspace.shared.open(Links.wineDonate) }
                            .fwProminentButton().tint(Look.wine)
                            .help(l10n.tr("settings.donate_tooltip"))
                    }
                }

                Card(title: l10n.tr("settings.status_card"), symbol: "hourglass") {
                    Toggle(isOn: Binding(get: { model.showsStatusWindow }, set: { model.showsStatusWindow = $0 })) {
                        Text(l10n.tr("settings.status_toggle_title"))
                        Text(l10n.tr("settings.status_toggle_desc"))
                    }
                }

                Card(title: l10n.tr("settings.win_files_card"), symbol: "doc.badge.gearshape",
                     footnote: l10n.tr("settings.win_files_footnote")) {
                    Row(label: l10n.tr("settings.when_opened_label"), detail: l10n.tr("settings.when_opened_desc")) {
                        Picker(l10n.tr("settings.when_opened_label"), selection: Binding(get: { model.openedFilePolicy },
                                                                             set: { model.openedFilePolicy = $0 })) {
                            ForEach(OpenedFilePolicy.allCases, id: \.self) { Text($0.displayName).tag($0) }
                        }
                        .labelsHidden().fixedSize()
                    }
                    Divider()
                    Toggle(isOn: Binding(get: { model.opensWindowsExecutables },
                                         set: { enabled in Task { await model.setOpensWindowsExecutables(enabled) } })) {
                        Text(l10n.tr("settings.open_with_finewine_title"))
                        Text(l10n.tr("settings.open_with_finewine_desc"))
                    }
                    if !model.opensWindowsExecutables, let handler = model.currentExecutableHandlerName {
                        Text(l10n.tr("settings.currently_opens_with", handler)).font(.footnote).foregroundStyle(.secondary)
                    }
                }

                Card(title: l10n.tr("settings.general_card"), symbol: "gearshape") {
                    Toggle(l10n.tr("settings.login_item"), isOn: Binding(get: { model.launchesAtLogin },
                                                                   set: { model.setLaunchesAtLogin($0) }))
                    Divider()
                    Row(label: l10n.tr("settings.shortcuts_row"), detail: model.service.paths.shortcuts.path) {
                        Button(l10n.tr("app.show_in_finder")) { reveal(model.service.paths.shortcuts) }.fwButton()
                    }
                    Row(label: l10n.tr("settings.prefixes_logs_row"), detail: model.service.paths.root.path) {
                        Button(l10n.tr("app.show_in_finder")) { reveal(model.service.paths.root) }.fwButton()
                    }
                }
            }
            .padding(20)
        }
        .frame(width: 560, height: 560)
        .background { Backdrop() }
        .onAppear { model.reload() }
        .alert(item: $model.alert) { alert in
            Alert(title: Text(alert.title), message: Text(alert.message), dismissButton: .default(Text(l10n.tr("app.ok"))))
        }
    }

    private func reveal(_ url: URL) {
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        NSWorkspace.shared.open(url)
    }
}

private struct RuntimeRow: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject private var l10n = LanguageManager.shared
    let runtime: WineRuntime
    @State private var confirmingRemoval = false

    var body: some View {
        let problems = runtime.problems()
        let users = model.prefixesUsing(runtime)
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(runtime.name).fontWeight(.medium)
                    if !runtime.manifest.wineVersion.isEmpty { Pill(text: "Wine \(runtime.manifest.wineVersion)") }
                    if runtime.kind == .external { Pill(text: l10n.tr("settings.external"), symbol: "folder") }
                    if runtime.kind == .bundled { Pill(text: l10n.tr("settings.builtin"), symbol: "shippingbox") }
                }
                Text(runtime.root.path).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                ForEach(problems, id: \.self) { problem in
                    Label(problem, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange)
                }
            }
            Spacer()
            if runtime.kind != .bundled {
                Button(l10n.tr("app.remove")) { confirmingRemoval = true }
                    .fwButton()
                    .controlSize(.small)
            }
        }
        .confirmationDialog(l10n.tr("settings.remove_runtime_confirm_title", runtime.name), isPresented: $confirmingRemoval) {
            Button(l10n.tr("app.remove"), role: .destructive) { model.remove(runtime) }
        } message: {
            Text(removalMessage(users: users))
        }
    }

    private func removalMessage(users: [Prefix]) -> String {
        let effect = runtime.kind == .managed
            ? l10n.tr("settings.remove_managed_msg")
            : l10n.tr("settings.remove_external_msg")
        guard !users.isEmpty else { return effect }
        let names = users.map(\.name).joined(separator: ", ")
        return effect + l10n.tr("settings.remove_users_prefix", names)
    }
}

enum Links {
    /// Where the Wine project takes donations.
    static let wineDonate = URL(string: "https://www.winehq.org/donate")!
}

/// What a right-click on a prefix in the sidebar offers: the things done to a prefix as a
/// whole, without first selecting it and finding the right tab.
struct PrefixContextMenu: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject private var l10n = LanguageManager.shared
    let prefix: Prefix

    var body: some View {
        let busy = model.busy[prefix.id] != nil
        Button(l10n.tr("context.run_installer")) {
            if let url = Panels.chooseExecutable(message: l10n.tr("dialog.choose_executable", prefix.name)) {
                model.selection = prefix.id
                model.runInstaller(url, in: prefix)
            }
        }
        .disabled(busy)
        Button(l10n.tr("context.find_programs")) {
            model.selection = prefix.id
            model.findInstalledPrograms(in: prefix)
        }
        .disabled(busy)
        Divider()
        Button(l10n.tr("context.configure")) { model.show(prefixID: prefix.id, section: "configuration") }
        Menu(l10n.tr("context.wine_tools")) {
            ForEach(WineTool.allCases) { tool in
                Button(tool.displayName) { Task { await model.open(tool, in: prefix) } }
            }
        }
        .disabled(busy)
        Divider()
        Button(l10n.tr("context.show_drive_c")) { NSWorkspace.shared.open(prefix.driveC) }
        Button(l10n.tr("context.show_logs")) {
            let logs = model.service.logFile(for: prefix, name: "x").deletingLastPathComponent()
            try? FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
            NSWorkspace.shared.open(logs)
        }
        Divider()
        Button(l10n.tr("context.shut_down")) { Task { await model.shutDown(prefix) } }.disabled(busy || !model.isRunning(prefix))
        Button(l10n.tr("context.force_shut_down")) { Task { await model.forceShutDown(prefix) } }.disabled(busy)
        Divider()
        Button(l10n.tr("context.rename")) {
            if let name = Panels.askForName(title: l10n.tr("dialog.rename_title", prefix.name), current: prefix.name) { model.rename(prefix, to: name) }
        }
        .disabled(busy)
        Button(l10n.tr("context.duplicate")) { Task { await model.duplicate(prefix) } }.disabled(busy)
        Button(l10n.tr("context.delete"), role: .destructive) {
            if Panels.confirm(title: l10n.tr("context.delete_confirm_title", prefix.name),
                              message: l10n.tr("context.delete_confirm_msg"),
                              action: l10n.tr("context.delete_action")) {
                Task { await model.delete(prefix) }
            }
        }
        .disabled(busy)
    }
}
