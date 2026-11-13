import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// The Automated Setup wizard: create the patched CrossOver copy from the selected CrossOver,
/// point at the Gryphline installer you downloaded, choose the bottle settings, then create the
/// bottle and start the installer.
///
/// The embedded patch runs through `PatcherEngine` (the same module swap / re-seal / verify as
/// "Create Patched Copy…"); this wizard only adds the bottle + installer steps.
struct AutomatedSetupView: View {
    @EnvironmentObject private var engine: PatcherEngine
    @EnvironmentObject private var setup: SetupEngine
    @EnvironmentObject private var l10n: LanguageManager
    @Environment(\.dismiss) private var dismiss

    /// The CrossOver selected in the main window — the source of the patched copy.
    let source: CrossOverInfo?
    /// The GPTK / D3DMetal selection from the main window.
    let gptk: GPTKSource?


    private enum Page: Int, Equatable {
        case crossOver, graphics, installer, bottle, progress
    }

    @State private var page: Page = .crossOver
    @State private var existingPatched: URL?
    @State private var patchedApp: URL?
    @State private var isPatching = false
    @State private var reCreate = false
    @State private var selectedGPTK: GPTKSource?
    @State private var gptkSources: [GPTKSource] = []
    @State private var gptkError: String?
    @State private var installer: URL?
    @State private var settings = BottleSettings()
    @State private var existingBottles: Set<String> = []

    private let downloadPage = URL(string: "https://endfield.gryphline.com")!
    private let gptkPage = URL(string: "https://developer.apple.com/games/game-porting-toolkit/")!

    var body: some View {
        // The statistics question is the wizard's final screen: it appears when the setup run
        // finishes (successful or failed) and its own buttons close the wizard. Nothing is ever
        // sent automatically.
        if let prompt = setup.telemetryPrompt {
            PatchTelemetryPromptView(
                prompt: prompt,
                onSend: { UsageTelemetry.send(prompt) },
                onFinished: { setup.telemetryPrompt = nil }
            )
        } else {
            wizard
        }
    }

    private var wizard: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            if page != .progress {
                ProgressView(value: Double(page.rawValue + 1), total: 4)
                    .progressViewStyle(.linear)
            }
            Group {
                switch page {
                case .crossOver: crossOverPage
                case .graphics:  graphicsPage
                case .installer: installerPage
                case .bottle:    bottlePage
                case .progress:  progressPage
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Divider()
            footer
        }
        .padding(20)
        .frame(width: 580)
        .fixedSize(horizontal: false, vertical: true)
        .fineWineChrome()
        .interactiveDismissDisabled(isPatching || setup.isRunning)
        .onAppear {
            let variant = source?.variant
            let engineCopy = engine.patchedApp.flatMap { CrossOverInfo(url: $0).variant == variant ? $0 : nil }
            existingPatched = engineCopy ?? Self.detectDefaultPatchedApp(variant: variant)
            patchedApp = existingPatched
            if !BottleBackend.available(for: variant).contains(settings.backend) { settings.backend = .dxmt }
            // Reusing an existing copy keeps whatever GPTK it already has; only preselect the
            // main window's GPTK when a fresh copy is going to be created.
            selectedGPTK = existingPatched == nil ? gptk : nil
            gptkSources = GPTKSource.detectMounted()
            existingBottles = SetupValidation.existingBottleNames()
            // A previous run's result is stale once the wizard is reopened (unless its installer
            // is still on screen — then keep its state visible).
            if !setup.isRunning && !setup.installerRunning { setup.reset() }
        }
        .onChange(of: page) { newPage in
            if newPage == .bottle { existingBottles = SetupValidation.existingBottleNames() }
            if newPage == .graphics { refreshGPTK() }
        }
        .onChange(of: selectedGPTK) { newGPTK in
            // Choosing a GPTK only takes effect when the patched copy is (re)created.
            if newGPTK != nil, existingPatched != nil { reCreate = true }
        }
        .onChange(of: engine.isRunning) { running in
            // The wizard-driven patch finished: continue to the installer page on success.
            guard isPatching, !running else { return }
            isPatching = false
            if let patched = engine.patchedApp {
                patchedApp = patched
                reCreate = false
                page = .installer
            }
        }
    }

    // MARK: - Header / footer

    private var header: some View {
        PageHeader(title: l10n.tr("setup.title"), subtitle: l10n.tr("setup.subtitle"), symbol: "wand.and.stars") {
            if page != .progress {
                Text("Step \(page.rawValue + 1) of 4")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    @ViewBuilder
    private var footer: some View {
        HStack {
            switch page {
            case .crossOver:
                Button(l10n.tr("app.cancel")) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button(l10n.tr("app.next")) { page = .graphics }
                    .prominentGlassButton()
                    .disabled(!canContinue)
            case .graphics:
                if isPatching {
                    Spacer()
                    Button(l10n.tr("content.btn.patching")) {}
                        .prominentGlassButton()
                        .disabled(true)
                } else {
                    Button(l10n.tr("app.back")) { page = .crossOver }
                    Spacer()
                    Button(needsPatch ? l10n.tr("content.btn.create_patch") : l10n.tr("app.next")) {
                        applyGraphicsAndContinue()
                    }
                    .prominentGlassButton()
                    .disabled(!canContinue)
                }
            case .installer:
                Button(l10n.tr("app.back")) { page = .graphics }
                Spacer()
                if installer == nil {
                    Button(l10n.tr("setup.installer.choose_button")) { chooseInstaller() }
                        .prominentGlassButton()
                } else {
                    Button(l10n.tr("app.next")) { page = .bottle }
                        .prominentGlassButton()
                        .disabled(SetupValidation.installerError(installer) != nil)
                }
            case .bottle:
                Button(l10n.tr("app.back")) { page = .installer }
                    .disabled(setup.isRunning)
                Spacer()
                Button(l10n.tr("setup.btn.start")) { createBottle() }
                    .prominentGlassButton()
                    .disabled(setup.isRunning || nameError != nil || installer == nil || patchedApp == nil)
            case .progress:
                Spacer()
                if !setup.logFiles.isEmpty {
                    Button("Show Logs") { revealLogs() }
                }
                Button(setup.isRunning ? "Working…" : l10n.tr("app.close")) { dismiss() }
                    .prominentGlassButton()
                    .disabled(setup.isRunning)
            }
        }
    }

    // MARK: - Page 1: patched copy

    private var crossOverPage: some View {
            VStack(alignment: .leading, spacing: 10) {
                GroupBox {
                    VStack(alignment: .leading, spacing: 8) {
                        if let source {
                            labeledRow("Source", source.displayName)
                            labeledRow("Version", source.displayVersion)
                        } else {
                            Label("Choose CrossOver in the main window first.", systemImage: "exclamationmark.triangle.fill")
                                .font(.callout)
                                .foregroundStyle(.orange)
                        }
                        Divider()
                        if needsPatch {
                            Label(l10n.tr("setup.crossover.will_create", destination.path), systemImage: "plus.square.on.square")
                                .font(.callout)
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                            if existingPatched != nil {
                                Toggle(l10n.tr("setup.crossover.recreate_existing"), isOn: $reCreate)
                            }
                        } else if let patchedApp {
                            Label(l10n.tr("setup.crossover.using_existing", patchedApp.path), systemImage: "checkmark.seal.fill")
                                .font(.callout)
                                .foregroundStyle(.green)
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                            Toggle(l10n.tr("setup.crossover.recreate_from_source"), isOn: $reCreate)
                            Button(l10n.tr("app.reveal_finder")) {
                                NSWorkspace.shared.activateFileViewerSelecting([patchedApp])
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(4)
                }

                if let source, !source.isExpectedVersion {
                    Text(l10n.tr("setup.crossover.version_warning", source.displayVersion, CrossOverVariant.x64.expectedVersion))
                        .font(.caption)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
    }

    private func labeledRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .multilineTextAlignment(.trailing)
                .textSelection(.enabled)
        }
        .font(.callout)
    }

    // MARK: - Page 2: GPTK / D3DMetal

    @ViewBuilder
    private var graphicsPage: some View {
        if isPatching {
            VStack(alignment: .leading, spacing: 10) {
                Text(l10n.tr("setup.graphics.creating", selectedGPTK != nil ? " with GPTK4 / D3DMetal 4" : ""))
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                if !engine.steps.isEmpty { StepsListView(steps: engine.steps) }
                if let error = engine.errorMessage { ErrorBox(message: error) }
            }
        } else if source?.variant?.supportsD3DMetal == false {
            Text("D3DMetal is x86_64-only, so it isn't used on ARM CrossOver. The bottle uses DXMT by default, with no Rosetta 2 needed.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            VStack(alignment: .leading, spacing: 10) {
                GroupBox {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(l10n.tr("setup.graphics.title"))
                            .font(.callout.weight(.medium))
                        Text(l10n.tr("setup.graphics.desc"))
                            .font(.callout)
                            .fixedSize(horizontal: false, vertical: true)
                        HStack(spacing: 8) {
                            Button(l10n.tr("setup.graphics.open_page")) {
                                NSWorkspace.shared.open(gptkPage)
                            }
                            Button(l10n.tr("app.rescan")) { refreshGPTK() }
                            Button(l10n.tr("app.choose")) { chooseGPTK() }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(4)
                }

                Picker("D3DMetal", selection: $selectedGPTK) {
                    Text(l10n.tr("content.gptk.keep_bundled")).tag(GPTKSource?.none)
                    ForEach(gptkSources) { source in
                        Text(source.displayName).tag(GPTKSource?.some(source))
                    }
                }
                .labelsHidden()
                .disabled(gptkSources.isEmpty)

                if let selectedGPTK {
                    if let problem = selectedGPTK.installProblem {
                        Text(problem)
                            .font(.caption)
                            .foregroundStyle(.red)
                            .fixedSize(horizontal: false, vertical: true)
                    } else if selectedGPTK.isVersion4 {
                        Text(l10n.tr("content.gptk.hint.v4", selectedGPTK.version ?? "3.0", selectedGPTK.displayName))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    } else {
                        Text(l10n.tr("content.gptk.hint.older", selectedGPTK.displayName))
                            .font(.caption)
                            .foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                } else if gptkSources.isEmpty {
                    Text(l10n.tr("content.gptk.hint.not_found"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Text(l10n.tr("content.gptk.hint.not_bundled"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if let gptkError {
                    Text(gptkError)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let error = engine.errorMessage { ErrorBox(message: error) }
            }
        }
    }

    // MARK: - Page 3: installer download

    private var installerPage: some View {
        VStack(alignment: .leading, spacing: 10) {
            GroupBox {
                VStack(alignment: .leading, spacing: 8) {
                    Text(l10n.tr("setup.installer.title"))
                        .font(.callout.weight(.medium))
                    Text(l10n.tr("setup.installer.desc"))
                        .font(.callout)
                        .fixedSize(horizontal: false, vertical: true)
                    Button(l10n.tr("setup.installer.open_page")) {
                        NSWorkspace.shared.open(downloadPage)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(4)
            }

            HStack(spacing: 8) {
                Button(l10n.tr("setup.installer.choose_button")) { chooseInstaller() }
                    .prominentGlassButton()
                if let installer {
                    Text(installer.lastPathComponent)
                        .font(.callout)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    Text(fileSize(installer))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text(l10n.tr("setup.installer.drop_or_choose"))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
            }
            if let error = SetupValidation.installerError(installer), installer != nil {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
            Text("The installer is a 32-bit NSIS application; it installs into `C:\\Program Files\\GRYPHLINK` inside the new bottle.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Page 4: bottle settings

    private var bottlePage: some View {
        VStack(alignment: .leading, spacing: 10) {
            GroupBox {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text(l10n.tr("setup.bottle.name_label"))
                        Spacer()
                        TextField("Arknights Endfield", text: $settings.name)
                            .frame(width: 260)
                            .textFieldStyle(.roundedBorder)
                    }
                    if let nameError {
                        Text(nameError)
                            .font(.caption)
                            .foregroundStyle(.red)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    HStack {
                        Text(l10n.tr("setup.bottle.backend_label"))
                        Spacer()
                        Picker("", selection: $settings.backend) {
                            ForEach(BottleBackend.available(for: source?.variant)) { backend in
                                Text(backend.displayName).tag(backend)
                            }
                        }
                        .labelsHidden()
                        .frame(width: 260)
                    }

                    Toggle(l10n.tr("setup.bottle.msync_label"), isOn: $settings.msync)
                    Text(l10n.tr("setup.bottle.msync_hint"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    Toggle(l10n.tr("setup.bottle.upscaler_label"), isOn: $settings.upscaling)
                        .disabled(!settings.backend.supportsUpscaling)
                    Text(settings.backend.supportsUpscaling
                         ? l10n.tr("setup.bottle.upscaler_hint_active")
                         : l10n.tr("setup.bottle.upscaler_hint_inactive"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    Toggle(l10n.tr("setup.bottle.hud_label"), isOn: $settings.metalHUD)
                    Text(l10n.tr("setup.bottle.hud_hint"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(4)
            }

            Text(l10n.tr("setup.bottle.footer_notes"))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Page 5: progress / result

    @ViewBuilder
    private var progressPage: some View {
        VStack(alignment: .leading, spacing: 12) {
            if !setup.steps.isEmpty {
                StepsListView(steps: setup.steps)
            }
            if let error = setup.errorMessage {
                ErrorBox(message: error)
            }
            if let bottle = setup.createdBottle {
                GroupBox {
                    VStack(alignment: .leading, spacing: 6) {
                        Label(l10n.tr("setup.progress.created", bottle), systemImage: "checkmark.seal.fill")
                            .font(.callout.weight(.medium))
                            .foregroundStyle(.green)
                        if setup.msyncFallback {
                            Text(l10n.tr("setup.progress.msync_fallback"))
                                .font(.caption)
                                .foregroundStyle(.orange)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        if setup.installerRunning {
                            Text(l10n.tr("setup.progress.installer_running"))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        } else if let exit = setup.installerExit {
                            Text(exit == 0
                                 ? l10n.tr("setup.progress.installer_success")
                                 : l10n.tr("setup.progress.installer_failed", "\(exit)"))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Text("Afterwards: launch the game with the bottle's **Start** button (DirectX 11 is the most-tested renderer; “Launch with DirectX 11” is in the dropdown).")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        HStack {
                            Button(l10n.tr("app.reveal_finder")) {
                                NSWorkspace.shared.activateFileViewerSelecting([bottleURL(bottle)])
                            }
                            if !setup.logFiles.isEmpty {
                                Button("Show Logs") { revealLogs() }
                            }
                        }
                        .padding(.top, 2)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(4)
                }
            } else if setup.isRunning {
                Text("Creating the bottle with the patched CrossOver — this takes a few seconds.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Derived state

    private var nameError: String? {
        SetupValidation.bottleNameError(settings.name, existing: existingBottles)
    }

    /// A patch run is needed when there is no reusable patched copy, or the user asked to rebuild it.
    private var needsPatch: Bool {
        reCreate || patchedApp == nil
    }

    private var canContinue: Bool {
        guard let source, source.hasWineModules else { return false }
        return needsPatch ? source.isExpectedVersion : patchedApp != nil
    }

    /// The patched copy lives next to the apps (`/Applications`, falling back to `~/Applications`).
    private var destination: URL {
        let fm = FileManager.default
        let name = "\((source?.variant ?? .x64).patchedAppName).app"
        let applications = URL(fileURLWithPath: "/Applications", isDirectory: true)
        if fm.isWritableFile(atPath: applications.path) {
            return applications.appendingPathComponent(name, isDirectory: true)
        }
        let userApplications = fm.homeDirectoryForCurrentUser
            .appendingPathComponent("Applications", isDirectory: true)
        try? fm.createDirectory(at: userApplications, withIntermediateDirectories: true)
        return userApplications.appendingPathComponent(name, isDirectory: true)
    }

    /// Finds a patched copy of the selected variant; the other variant's copy can't be reused.
    private static func detectDefaultPatchedApp(variant: CrossOverVariant?) -> URL? {
        let apps = SetupValidation.findPatchedCrossOvers().filter { CrossOverInfo(url: $0).variant == variant }
        let defaultName = "\((variant ?? .x64).patchedAppName).app"
        let standard = URL(fileURLWithPath: "/Applications", isDirectory: true)
            .appendingPathComponent(defaultName, isDirectory: true)
        if apps.contains(standard) { return standard }
        let user = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Applications/\(defaultName)", isDirectory: true)
        if apps.contains(user) { return user }
        return apps.first
    }

    // MARK: - Actions

    /// Runs the patch (if one is needed) with the chosen GPTK, then continues to the installer.
    private func applyGraphicsAndContinue() {
        guard let source, let variant = source.variant else { return }
        if needsPatch {
            isPatching = true
            // The Automated Setup report at the end covers this run; a separate patch report
            // inside the wizard would duplicate it.
            engine.patch(source: source.url, variant: variant, destination: destination, gptk: selectedGPTK, reportTelemetry: false)
        } else {
            page = .installer
        }
    }

    private func refreshGPTK() {
        gptkError = nil
        var detected = GPTKSource.detectMounted()
        // Keep a hand-picked redist that isn't a mounted DMG (e.g. a folder on disk).
        if let selectedGPTK, !detected.contains(selectedGPTK),
           FileManager.default.fileExists(atPath: selectedGPTK.url.path) {
            detected.append(selectedGPTK)
        }
        gptkSources = detected.sorted {
            $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
        }
        if let selectedGPTK, !gptkSources.contains(selectedGPTK) { self.selectedGPTK = nil }
    }

    private func chooseGPTK() {
        let panel = NSOpenPanel()
        panel.title = "Choose the GPTK redist or DMG"
        panel.message = "Select a mounted volume (e.g. Game Porting Toolkit), an Evaluation Environment .dmg, or the redist/lib/external folder."
        panel.prompt = "Select"
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowedContentTypes = [.folder, .diskImage]
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: "/Volumes")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        if let source = GPTKSource.resolve(from: url) {
            gptkError = nil
            if !gptkSources.contains(source) { gptkSources.append(source) }
            gptkSources.sort {
                $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
            }
            selectedGPTK = source
        } else {
            gptkError = "Could not find D3DMetal in “\(url.lastPathComponent)”. Expected a GPTK redist folder (…/redist/lib/external) or an Evaluation Environment DMG."
        }
    }

    private func createBottle() {
        guard let patchedApp, let installer else { return }
        page = .progress
        setup.start(patchedApp: patchedApp, settings: settings, installer: installer)
    }

    private func chooseInstaller() {
        let panel = NSOpenPanel()
        panel.title = "Find the Gryphline installer"
        panel.message = "Select the Windows installer you downloaded from endfield.gryphline.com (GRYPHLINK_….exe)."
        panel.prompt = "Select Installer"
        // Show every file and validate the extension afterwards: downloaded installers do not all
        // have a declared UTI, and hiding them behind a content-type filter would be worse.
        panel.allowedContentTypes = [.item]
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        guard panel.runModal() == .OK, let url = panel.url else { return }
        installer = url
    }

    private func revealLogs() {
        let files = setup.logFiles.filter { FileManager.default.fileExists(atPath: $0.path) }
        guard !files.isEmpty else { return }
        NSWorkspace.shared.activateFileViewerSelecting(files)
    }

    private func bottleURL(_ name: String) -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/CrossOver/Bottles", isDirectory: true)
            .appendingPathComponent(name, isDirectory: true)
    }

    private func fileSize(_ url: URL) -> String {
        guard let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize else { return "" }
        return ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)
    }
}
