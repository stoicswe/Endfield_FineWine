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
    }

    @EnvironmentObject private var model: AppModel
    let prefix: Prefix
    @State private var tab: Tab = .programs

    var body: some View {
        VStack(spacing: 0) {
            header
                .onAppear { takeRequestedTab() }
                .onChange(of: model.requestedSection) { takeRequestedTab() }
            ScrollView {
                Group {
                    switch tab {
                    case .programs: ProgramsTab(prefix: prefix)
                    case .configuration: ConfigurationTab(prefix: prefix)
                    case .tools: ToolsTab(prefix: prefix)
                    case .details: DetailsTab(prefix: prefix)
                    }
                }
                .padding(20)
                .frame(maxWidth: 760)
                .frame(maxWidth: .infinity)
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
                            Pill(text: "No runtime", symbol: "exclamationmark.triangle", tint: .orange)
                        }
                        if let profile = model.profile(for: prefix) { Pill(text: profile.name, symbol: "gamecontroller") }
                        if model.isRunning(prefix) { Pill(text: "Running", symbol: "play.fill", tint: .green) }
                        if prefix.metadata.settings != prefix.metadata.appliedSettings {
                            Pill(text: "Settings not applied", symbol: "clock.arrow.circlepath", tint: .orange)
                        }
                    }
                }
                Spacer()
                if let status = model.busy[prefix.id] {
                    ProgressView().controlSize(.small)
                    Text(status).foregroundStyle(.secondary)
                } else if model.isRunning(prefix) {
                    Button {
                        Task { await model.stopAll(in: prefix) }
                    } label: {
                        Label("Stop All", systemImage: "stop.fill")
                    }
                    .buttonStyle(.glass)
                    .help("Stop every program running in this prefix")
                }
            }
            Picker("Section", selection: $tab) {
                ForEach(Tab.allCases) { Text($0.rawValue).tag($0) }
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
    let prefix: Prefix
    @State private var editing: Program?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Button {
                    if let url = Panels.chooseExecutable(message: "Choose a Windows installer or program to run in “\(prefix.name)”") {
                        model.runInstaller(url, in: prefix)
                    }
                } label: {
                    Label("Run Installer…", systemImage: "arrow.down.circle")
                }
                .buttonStyle(.glassProminent).tint(Look.wine)
                Button {
                    addProgram()
                } label: {
                    Label("Add Program…", systemImage: "plus")
                }
                .buttonStyle(.glass)
                Button {
                    model.findInstalledPrograms(in: prefix)
                } label: {
                    Label("Find Installed", systemImage: "magnifyingglass")
                }
                .buttonStyle(.glass)
                .help("Look for programs that installers added to this prefix")
                Spacer()
            }

            if prefix.metadata.programs.isEmpty {
                EmptyState(symbol: "macwindow.badge.plus", title: "No programs yet",
                           message: "Run an installer to put a Windows program in this prefix. When it finishes, FineWine lists what it installed here.") { EmptyView() }
                    .frame(minHeight: 260)
            } else {
                GlassEffectContainer(spacing: 12) {
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
        guard let url = Panels.chooseExecutable(in: prefix.driveC, message: "Choose a program inside this prefix") else { return }
        let name = url.deletingPathExtension().lastPathComponent
        model.addProgram(Program(name: name, windowsPath: WindowsPath.windowsPath(for: url, inPrefix: prefix.directory)), to: prefix)
    }
}

private struct ProgramCard: View {
    @EnvironmentObject private var model: AppModel
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
                if hasShortcut { Pill(text: "In Applications", symbol: "checkmark", tint: .green) }
            }
            Spacer(minLength: 8)
            Menu {
                if hasShortcut {
                    Button("Show Shortcut in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: program.shortcutPath!)])
                    }
                    Button("Remove Shortcut App") { model.removeShortcut(for: program.id, in: prefix) }
                } else {
                    Button("Make Shortcut App") { model.createShortcut(for: program.id, in: prefix) }
                }
                Button("Edit…", action: edit)
                Divider()
                Button("Remove from FineWine…", role: .destructive) { confirmingRemoval = true }
            } label: {
                Image(systemName: "ellipsis")
            }
            .menuStyle(.button)
            .menuIndicator(.hidden)
            .buttonStyle(.glass)
            .help("More actions")
            .fixedSize()
            Button {
                model.launch(program, in: prefix)
            } label: {
                Label("Play", systemImage: "play.fill")
            }
            .buttonStyle(.glassProminent).tint(Look.wine)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard(padding: 14)
        .confirmationDialog("Remove “\(program.name)” from FineWine?", isPresented: $confirmingRemoval) {
            Button("Remove", role: .destructive) { model.removeProgram(program, from: prefix) }
        } message: {
            Text("Its entry and shortcut app are removed. The program's files stay in the prefix; use Add or Remove Programs under Wine Tools to uninstall it.")
        }
    }
}

private struct ProgramEditor: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let prefix: Prefix
    @State var program: Program
    @State private var arguments: String

    init(prefix: Prefix, program: Program) {
        self.prefix = prefix
        _program = State(initialValue: program)
        _arguments = State(initialValue: program.arguments.map { $0.contains(" ") ? "\"\($0)\"" : $0 }.joined(separator: " "))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Edit Program").font(.title2.weight(.semibold))
            Card(title: "Program", symbol: "macwindow") {
                LabeledField("Name", text: $program.name)
                LabeledField("Executable", text: $program.windowsPath)
                LabeledField("Arguments", text: $arguments, prompt: "Optional")
                LabeledField("Start in", text: $program.workingDirectory, prompt: "The executable's folder")
            }
            Card(title: "Environment", symbol: "terminal",
                 footnote: "Variables for this program only, on top of the prefix's own.") {
                EnvironmentEditor(variables: $program.environment)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.buttonStyle(.glass).keyboardShortcut(.cancelAction)
                Button("Save") {
                    program.arguments = ProgramScanner.splitArguments(arguments)
                    program.name = program.name.trimmingCharacters(in: .whitespaces)
                    model.update(program, in: prefix)
                    dismiss()
                }
                .buttonStyle(.glassProminent).tint(Look.wine)
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
                    .help("Remove this variable")
                }
            }
            Button {
                variables.append(EnvironmentVariable(name: "", value: ""))
            } label: {
                Label("Add Variable", systemImage: "plus")
            }
            .buttonStyle(.glass)
            .controlSize(.small)
        }
    }
}

// MARK: - Wine tools

private struct ToolsTab: View {
    @EnvironmentObject private var model: AppModel
    let prefix: Prefix

    private let columns = [GridItem(.adaptive(minimum: 220), spacing: 12)]

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            GlassEffectContainer(spacing: 12) {
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

            Card(title: "Maintenance", symbol: "wrench.and.screwdriver") {
                Row(label: "Restart Windows", detail: "What some installers ask for when they finish.") {
                    Button("Restart") { Task { await model.wineboot(.restart, in: prefix, status: "Restarting Windows…") } }
                        .buttonStyle(.glass)
                }
                Divider()
                Row(label: "Update the prefix", detail: "Brings its Windows files up to date after the runtime changes.") {
                    Button("Update") { Task { await model.wineboot(.update, in: prefix, status: "Updating…") } }
                        .buttonStyle(.glass)
                }
                Divider()
                Row(label: "Stop everything", detail: "Ends every Windows process in this prefix at once.") {
                    Button("Stop All") { Task { await model.stopAll(in: prefix) } }.buttonStyle(.glass)
                }
            }

            Card(title: "Files", symbol: "folder") {
                Row(label: "C: drive") {
                    Button("Show in Finder") { NSWorkspace.shared.open(prefix.driveC) }.buttonStyle(.glass)
                }
                Divider()
                Row(label: "Logs", detail: "Wine's output from each launch.") {
                    Button("Show in Finder") {
                        let logs = model.service.paths.logs.appendingPathComponent(prefix.directory.lastPathComponent)
                        try? FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
                        NSWorkspace.shared.open(logs)
                    }
                    .buttonStyle(.glass)
                }
            }
        }
    }
}

// MARK: - Details

private struct DetailsTab: View {
    @EnvironmentObject private var model: AppModel
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
            Card(title: "Name", symbol: "textformat") {
                HStack {
                    TextField("Name", text: $name).textFieldStyle(.roundedBorder)
                    Button("Rename") { model.rename(prefix, to: name) }
                        .buttonStyle(.glass)
                        .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || name == prefix.name)
                }
            }

            Card(title: "What Windows reports", symbol: "doc.text.magnifyingglass",
                 footnote: "Read from the prefix's registry, so it also shows changes made in Wine Configuration.") {
                info("Windows version", snapshot.windowsVersion.flatMap { WindowsVersion(rawValue: $0)?.displayName } ?? snapshot.windowsVersion ?? "Wine default")
                info("Build", snapshot.windowsBuild ?? "—")
                info("DPI", snapshot.dpi.map(String.init) ?? "—")
                info("Retina mode", snapshot.retinaMode.map { $0 ? "On" : "Off" } ?? "—")
                info("Virtual desktop", snapshot.virtualDesktop ?? "Off")
                info("DLL overrides", snapshot.dllOverrides.isEmpty ? "None"
                     : snapshot.dllOverrides.sorted { $0.key < $1.key }.map { "\($0.key) = \($0.value.isEmpty ? "disabled" : $0.value)" }.joined(separator: "\n"))
            }

            Card(title: "About this prefix", symbol: "info.circle") {
                info("Created", prefix.metadata.createdAt.formatted(date: .abbreviated, time: .shortened))
                info("Location", prefix.directory.path)
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([prefix.directory]) }
                    .buttonStyle(.glass)
            }

            Card(title: "Duplicate or delete", symbol: "square.on.square") {
                Row(label: "Duplicate", detail: "Copies the whole prefix, installed programs included.") {
                    Button("Duplicate") { Task { await model.duplicate(prefix) } }.buttonStyle(.glass)
                }
                Divider()
                Row(label: "Delete", detail: "Removes the prefix, everything installed in it, and its shortcut apps.") {
                    Button("Delete…", role: .destructive) { confirmingDelete = true }.buttonStyle(.glass)
                }
            }
        }
        .onAppear { snapshot = PrefixRegistrySnapshot.read(prefix: prefix.directory) }
        .onChange(of: prefix.metadata.appliedSettings) { snapshot = PrefixRegistrySnapshot.read(prefix: prefix.directory) }
        .confirmationDialog("Delete “\(prefix.name)”?", isPresented: $confirmingDelete) {
            Button("Delete Prefix", role: .destructive) { Task { await model.delete(prefix) } }
        } message: {
            Text("Everything installed in this prefix, including saved games stored inside it, will be deleted. This can't be undone.")
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
