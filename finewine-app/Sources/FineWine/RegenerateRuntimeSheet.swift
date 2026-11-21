import SwiftUI
import AppKit
import FineWineCore

/// Sheet allowing the user to regenerate, rebuild, or package the Wine runtime and choose
/// where it sits on disk (This Mac, external drive, or custom folder).
struct RegenerateRuntimeSheet: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject private var l10n = LanguageManager.shared
    @Environment(\.dismiss) private var dismiss

    var initialPlace: RuntimePlace?

    @State private var repoURL: URL?
    @State private var repoInfo: RuntimeRepoInfo?
    @State private var mode: RuntimeRegenerationMode = .quickPackage

    // Destination choice: "" for This Mac, drive UUID, or "custom"
    @State private var placeChoiceID = ""
    @State private var customFolderURL: URL?

    @State private var isRunning = false
    @State private var statusMessage = ""
    @State private var logLines: [String] = []
    @State private var finishedSuccessfully = false
    @State private var errorMessage: String?
    @State private var showLogs = true

    @State private var regenerator = RuntimeRegenerator()

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if let error = errorMessage {
                        errorBanner(error)
                    }

                    if finishedSuccessfully {
                        successView
                    } else if isRunning {
                        runningView
                    } else {
                        configView
                    }
                }
                .padding(20)
            }
            Divider()
            footer
        }
        .frame(width: 620, height: 600)
        .background { Backdrop() }
        .onAppear { setup() }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "arrow.triangle.2.circlepath.circle.fill")
                .font(.system(size: 32))
                .foregroundStyle(Look.accent)
            VStack(alignment: .leading, spacing: 2) {
                Text(l10n.tr("runtime_regen.title"))
                    .font(.title3.weight(.semibold))
                Text(l10n.tr("runtime_regen.subtitle"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(16)
    }

    private var configView: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Section 1: Source Repository
            Card(title: l10n.tr("runtime_regen.repo_card"), symbol: "folder.badge.gearshape") {
                if let repo = repoURL {
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(repo.lastPathComponent).fontWeight(.medium)
                            Text(repo.path).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                            HStack(spacing: 6) {
                                if repoInfo?.hasPackagedRuntime == true {
                                    Pill(text: l10n.tr("runtime_regen.has_packaged"), symbol: "checkmark.circle.fill")
                                }
                                if repoInfo?.hasBuiltWine == true {
                                    Pill(text: l10n.tr("runtime_regen.has_built"), symbol: "hammer.fill")
                                }
                            }
                            .padding(.top, 2)
                        }
                        Spacer()
                        Button(l10n.tr("runtime_regen.change_repo")) {
                            if let folder = Panels.chooseFolder(message: l10n.tr("runtime_regen.choose_repo")) {
                                selectRepo(folder)
                            }
                        }
                        .fwButton()
                        .controlSize(.small)
                    }
                } else {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(l10n.tr("runtime_regen.repo_not_found"))
                            .font(.callout)
                            .foregroundStyle(.secondary)
                        Button(l10n.tr("runtime_regen.locate_repo")) {
                            if let folder = Panels.chooseFolder(message: l10n.tr("runtime_regen.choose_repo")) {
                                selectRepo(folder)
                            }
                        }
                        .fwButton()
                    }
                }
            }

            // Section 2: Generation Mode
            Card(title: l10n.tr("runtime_regen.mode_card"), symbol: "gearshape.2") {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(availableModes) { m in
                        Button {
                            mode = m
                        } label: {
                            HStack(alignment: .top, spacing: 10) {
                                Image(systemName: mode == m ? "largecircle.fill.circle" : "circle")
                                    .foregroundStyle(mode == m ? Look.accent : .secondary)
                                    .font(.system(size: 14))
                                    .padding(.top, 2)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(m.displayName)
                                        .fontWeight(mode == m ? .medium : .regular)
                                        .foregroundStyle(.primary)
                                    Text(m.description)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                                Spacer()
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        if m.id != availableModes.last?.id { Divider() }
                    }
                }
            }

            // Section 3: Where it can sit (Destination Disk / Place)
            Card(title: l10n.tr("runtime_regen.destination_card"), symbol: "externaldrive",
                 footnote: l10n.tr("runtime_regen.destination_footnote")) {
                Row(label: l10n.tr("runtime_regen.destination_label")) {
                    Picker(l10n.tr("runtime_regen.destination_label"), selection: $placeChoiceID) {
                        Label(l10n.tr("drive.this_mac"), systemImage: "desktopcomputer").tag("")
                        ForEach(model.placeChoices().filter { !$0.id.isEmpty }) { choice in
                            Label(choiceText(choice), systemImage: choice.symbol).tag(choice.id)
                        }
                        Label(l10n.tr("runtime_regen.custom_folder"), systemImage: "folder").tag("custom")
                    }
                    .labelsHidden().fixedSize()
                }

                if placeChoiceID == "custom" {
                    Divider()
                    Row(label: l10n.tr("runtime_regen.custom_path_label"), detail: customFolderURL?.path ?? l10n.tr("app.none")) {
                        Button(l10n.tr("runtime_regen.choose_folder")) {
                            if let folder = Panels.chooseFolder(message: l10n.tr("runtime_regen.choose_custom_dest")) {
                                customFolderURL = folder
                            }
                        }
                        .fwButton()
                    }
                }
            }
        }
    }

    private var runningView: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                ProgressView().controlSize(.regular)
                VStack(alignment: .leading, spacing: 2) {
                    Text(statusMessage.isEmpty ? l10n.tr("runtime_regen.working") : statusMessage)
                        .fontWeight(.medium)
                    Text(l10n.tr("runtime_regen.keep_open_notice"))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .glassCard(padding: 14)

            consoleView
        }
    }

    private var successView: some View {
        VStack(spacing: 16) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 48))
                .foregroundStyle(.green)
            Text(l10n.tr("runtime_regen.success_title"))
                .font(.title3.weight(.semibold))
            Text(l10n.tr("runtime_regen.success_message"))
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 20)

            consoleView
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
    }

    private var consoleView: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(l10n.tr("runtime_regen.console_output"))
                    .font(.caption.weight(.medium)).foregroundStyle(.secondary)
                Spacer()
                Button(showLogs ? l10n.tr("app.hide") : l10n.tr("app.show")) {
                    showLogs.toggle()
                }
                .font(.caption)
                .buttonStyle(.plain)
                .foregroundStyle(Look.accent)
            }
            if showLogs {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 2) {
                            ForEach(Array(logLines.enumerated()), id: \.offset) { idx, line in
                                Text(line)
                                    .font(.system(.caption2, design: .monospaced))
                                    .foregroundStyle(.secondary)
                                    .id(idx)
                            }
                        }
                        .padding(8)
                    }
                    .frame(height: 180)
                    .background(Color.black.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
                    .onChange(of: logLines.count) {
                        if let last = logLines.indices.last {
                            proxy.scrollTo(last, anchor: .bottom)
                        }
                    }
                }
            }
        }
    }

    private func errorBanner(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
            Text(message)
                .font(.caption)
                .foregroundStyle(.red)
            Spacer()
        }
        .padding(10)
        .background(Color.red.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
    }

    private var footer: some View {
        HStack {
            if isRunning {
                Button(l10n.tr("app.cancel")) {
                    Task {
                        await regenerator.cancel()
                        isRunning = false
                        statusMessage = l10n.tr("runtime_regen.cancelled")
                    }
                }
                .fwButton()
            } else if finishedSuccessfully {
                Spacer()
                Button(l10n.tr("app.done")) { dismiss() }
                    .fwProminentButton().tint(Look.accent)
            } else {
                Button(l10n.tr("app.cancel")) { dismiss() }
                    .fwButton()
                Spacer()
                Button(l10n.tr("runtime_regen.start_button")) { startRegeneration() }
                    .fwProminentButton().tint(Look.accent)
                    .disabled(repoURL == nil || (placeChoiceID == "custom" && customFolderURL == nil))
            }
        }
        .padding(16)
    }

    private var availableModes: [RuntimeRegenerationMode] {
        var modes: [RuntimeRegenerationMode] = []
        if repoInfo?.hasPackagedRuntime == true {
            modes.append(.copyExisting)
        }
        if repoInfo?.hasBuiltWine == true {
            modes.append(.quickPackage)
            modes.append(.rebuildAndPackage)
        }
        modes.append(.fullBuild)
        return modes
    }

    private func choiceText(_ choice: PlaceChoice) -> String {
        guard let bytes = choice.freeBytes else { return choice.name }
        return "\(choice.name) (\(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)) free)"
    }

    private func setup() {
        if let detected = RuntimeRegenerator.locateRepository() {
            selectRepo(detected)
        }
        if let initialPlace {
            switch initialPlace {
            case .thisMac: placeChoiceID = ""
            case .drive(let uuid): placeChoiceID = uuid
            case .customFolder(let url):
                placeChoiceID = "custom"
                customFolderURL = url
            }
        }
    }

    private func selectRepo(_ url: URL) {
        repoURL = url
        repoInfo = RuntimeRegenerator.inspectRepository(at: url)
        if repoInfo?.hasBuiltWine == true && repoInfo?.hasPackagedRuntime == true {
            mode = .quickPackage
        } else if repoInfo?.hasPackagedRuntime == true {
            mode = .copyExisting
        } else if repoInfo?.hasBuiltWine == true {
            mode = .quickPackage
        } else {
            mode = .fullBuild
        }
    }

    private func resolvePlace() -> RuntimePlace? {
        if placeChoiceID.isEmpty { return .thisMac }
        if placeChoiceID == "custom" {
            guard let url = customFolderURL else { return nil }
            return .customFolder(url)
        }
        return .drive(placeChoiceID)
    }

    private func startRegeneration() {
        guard let repo = repoURL, let place = resolvePlace() else { return }
        isRunning = true
        errorMessage = nil
        logLines.removeAll()
        statusMessage = l10n.tr("runtime_regen.starting")

        Task {
            do {
                _ = try await regenerator.regenerate(
                    mode: mode,
                    repo: repo,
                    destinationPlace: place,
                    runtimeStore: model.service.runtimes,
                    volumes: model.service.prefixes.drives.volumes
                ) { line in
                    Task { @MainActor in
                        logLines.append(line)
                        if line.hasPrefix("==>") {
                            statusMessage = line.replacingOccurrences(of: "==>", with: "").trimmingCharacters(in: .whitespaces)
                        }
                    }
                }
                await MainActor.run {
                    model.reload()
                    isRunning = false
                    finishedSuccessfully = true
                    statusMessage = l10n.tr("runtime_regen.completed")
                }
            } catch {
                await MainActor.run {
                    isRunning = false
                    errorMessage = error.localizedDescription
                    statusMessage = l10n.tr("runtime_regen.failed")
                }
            }
        }
    }
}
