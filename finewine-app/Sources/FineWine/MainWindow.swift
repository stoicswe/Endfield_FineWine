import SwiftUI
import AppKit
import FineWineCore

/// The prefix manager: prefixes in the sidebar, the selected one's programs and settings beside it.
struct MainWindow: View {
    @EnvironmentObject private var model: AppModel
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
                        Text("Setting up the prefix “\(name)”…")
                    }
                    .padding(.horizontal, 16).padding(.vertical, 10)
                    .glassEffect()
                    .padding(.bottom, 18)
                }
            }
        }
        .frame(minWidth: 860, minHeight: 560)
        .sheet(isPresented: $showingNewPrefix) {
            NewPrefixSheet().environmentObject(model)
        }
        .alert(item: $model.alert) { alert in
            Alert(title: Text(alert.title), message: Text(alert.message), dismissButton: .default(Text("OK")))
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
            Section("Prefixes") {
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
                                .accessibilityLabel("Running")
                        }
                    }
                    .tag(prefix.id)
                }
            }
        }
        .navigationSplitViewColumnWidth(min: 210, ideal: 240, max: 320)
        .safeAreaInset(edge: .bottom) {
            HStack {
                Button {
                    showingNewPrefix = true
                } label: {
                    Label("New Prefix", systemImage: "plus")
                }
                .buttonStyle(.glass)
                Spacer()
                Button {
                    openSettings()
                } label: {
                    Image(systemName: "gearshape")
                }
                .buttonStyle(.glass)
                .help("Runtimes and settings")
            }
            .padding(12)
        }
    }

    private func subtitle(for prefix: Prefix) -> String {
        let count = prefix.metadata.programs.count
        let programs = count == 1 ? "1 program" : "\(count) programs"
        return model.profile(for: prefix).map { "\($0.name) · \(programs)" } ?? programs
    }

    @ViewBuilder
    private var detail: some View {
        if let prefix = model.prefix(model.selection) {
            PrefixDetailView(prefix: prefix).id(prefix.id)
        } else if model.usableRuntimes.isEmpty {
            EmptyState(symbol: "wineglass", title: "Add a Wine runtime",
                       message: "FineWine runs Windows programs with a Wine runtime. Add a FineWine runtime folder, or any folder that holds a Wine build (with bin/wine inside), to get started.") {
                Button("Add Runtime…") {
                    if let folder = Panels.chooseFolder(message: "Choose a Wine runtime folder") { model.addRuntime(from: folder) }
                }
                .buttonStyle(.glassProminent).tint(Look.wine)
                .controlSize(.large)
            }
        } else {
            EmptyState(symbol: "shippingbox", title: "Create your first prefix",
                       message: "A prefix is a self-contained Windows environment. Each game or program can have its own, with its own settings.") {
                Button("New Prefix…") { showingNewPrefix = true }
                    .buttonStyle(.glassProminent).tint(Look.wine)
                    .controlSize(.large)
            }
        }
    }
}

/// Asks for a name, runtime and profile, then creates the prefix.
struct NewPrefixSheet: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var runtimeID: String?
    @State private var profileID = GameProfile.generic.id

    private var profile: GameProfile? { model.profiles.first { $0.id == profileID } }
    private var runtime: WineRuntime? { model.usableRuntimes.first { $0.id == runtimeID } ?? model.usableRuntimes.first }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("New Prefix").font(.title2.weight(.semibold))

            Card(title: "Name", symbol: "textformat") {
                TextField("For example, the game's name", text: $name)
                    .textFieldStyle(.roundedBorder)
            }

            Card(title: "Setup", symbol: "slider.horizontal.3") {
                Row(label: "Profile", detail: profile?.summary) {
                    Picker("Profile", selection: $profileID) {
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
                    Label("No usable Wine runtime is installed. Add one in Settings first.", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                } else {
                    Row(label: "Runtime") {
                        Picker("Runtime", selection: Binding(get: { runtime?.id }, set: { runtimeID = $0 })) {
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
                    Text("Setting up Windows… this can take a minute.").foregroundStyle(.secondary)
                }
                Spacer()
                Button("Cancel") { dismiss() }
                    .buttonStyle(.glass)
                    .keyboardShortcut(.cancelAction)
                    .disabled(model.isCreatingPrefix)
                Button("Create") {
                    guard let runtime else { return }
                    Task {
                        if await model.createPrefix(name: name, runtime: runtime, profile: profile) { dismiss() }
                    }
                }
                .buttonStyle(.glassProminent).tint(Look.wine)
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

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Card(title: "Wine Runtimes", symbol: "cpu",
                     footnote: "A folder with a runtime.json is copied into FineWine. Any other Wine folder is used where it is.") {
                    if model.runtimes.isEmpty {
                        Text("No runtimes yet.").foregroundStyle(.secondary)
                    }
                    ForEach(model.runtimes) { runtime in
                        RuntimeRow(runtime: runtime)
                        if runtime.id != model.runtimes.last?.id { Divider() }
                    }
                    Button("Add Runtime…") {
                        if let folder = Panels.chooseFolder(message: "Choose a Wine runtime folder") { model.addRuntime(from: folder) }
                    }
                    .buttonStyle(.glass)
                }

                Card(title: "Windows files", symbol: "doc.badge.gearshape",
                     footnote: "A program that is already inside a prefix always runs there. FineWine appears under Open With for these files whether or not it is their default app.") {
                    Row(label: "When a program is opened", detail: "A .exe or .msi from outside any prefix, such as a downloaded installer. FineWine can make a prefix for it, named after what it installs, or ask whether to make one or use a prefix you have.") {
                        Picker("When a program is opened", selection: Binding(get: { model.openedFilePolicy },
                                                                             set: { model.openedFilePolicy = $0 })) {
                            ForEach(OpenedFilePolicy.allCases, id: \.self) { Text($0.displayName).tag($0) }
                        }
                        .labelsHidden().fixedSize()
                    }
                    Divider()
                    Toggle(isOn: Binding(get: { model.opensWindowsExecutables },
                                         set: { enabled in Task { await model.setOpensWindowsExecutables(enabled) } })) {
                        Text("Open Windows programs with FineWine")
                        Text("Makes FineWine the default app for .exe and .msi files, so double-clicking one in Finder runs it.")
                    }
                    if !model.opensWindowsExecutables, let handler = model.currentExecutableHandlerName {
                        Text("They currently open with \(handler).").font(.footnote).foregroundStyle(.secondary)
                    }
                }

                Card(title: "General", symbol: "gearshape") {
                    Toggle("Open FineWine at login", isOn: Binding(get: { model.launchesAtLogin },
                                                                   set: { model.setLaunchesAtLogin($0) }))
                    Divider()
                    Row(label: "Shortcut apps", detail: model.service.paths.shortcuts.path) {
                        Button("Show in Finder") { reveal(model.service.paths.shortcuts) }.buttonStyle(.glass)
                    }
                    Row(label: "Prefixes and logs", detail: model.service.paths.root.path) {
                        Button("Show in Finder") { reveal(model.service.paths.root) }.buttonStyle(.glass)
                    }
                }
            }
            .padding(20)
        }
        .frame(width: 560, height: 560)
        .background { Backdrop() }
        .onAppear { model.reload() }
        .alert(item: $model.alert) { alert in
            Alert(title: Text(alert.title), message: Text(alert.message), dismissButton: .default(Text("OK")))
        }
    }

    private func reveal(_ url: URL) {
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        NSWorkspace.shared.open(url)
    }
}

private struct RuntimeRow: View {
    @EnvironmentObject private var model: AppModel
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
                    if runtime.kind == .external { Pill(text: "External", symbol: "folder") }
                    if runtime.kind == .bundled { Pill(text: "Built in", symbol: "shippingbox") }
                }
                Text(runtime.root.path).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                ForEach(problems, id: \.self) { problem in
                    Label(problem, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange)
                }
            }
            Spacer()
            if runtime.kind != .bundled {
                Button("Remove") { confirmingRemoval = true }
                    .buttonStyle(.glass)
                    .controlSize(.small)
            }
        }
        .confirmationDialog("Remove “\(runtime.name)”?", isPresented: $confirmingRemoval) {
            Button("Remove", role: .destructive) { model.remove(runtime) }
        } message: {
            Text(removalMessage(users: users))
        }
    }

    private func removalMessage(users: [Prefix]) -> String {
        let effect = runtime.kind == .managed
            ? "Its files will be deleted from FineWine."
            : "FineWine will forget this folder; the folder itself is not deleted."
        guard !users.isEmpty else { return effect }
        let names = users.map(\.name).joined(separator: ", ")
        return effect + " These prefixes use it and will need another runtime: \(names)."
    }
}
