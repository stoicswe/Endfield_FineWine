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
    @Environment(\.dismiss) private var dismiss

    /// The CrossOver selected in the main window — the source of the patched copy.
    let source: CrossOverInfo?
    /// The GPTK / D3DMetal selection from the main window.
    let gptk: GPTKSource?

    private static let defaultName = "CrossOver_Endfield_Patch.app"

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
        .interactiveDismissDisabled(isPatching || setup.isRunning)
        .onAppear {
            existingPatched = engine.patchedApp ?? Self.detectDefaultPatchedApp()
            patchedApp = existingPatched
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
        VStack(alignment: .leading, spacing: 4) {
            Text("Automated Setup")
                .font(.title2.weight(.semibold))
            Text("Creates the patched copy, a Windows 11 bottle, and starts the Gryphline installer.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
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
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Continue") { page = .graphics }
                    .buttonStyle(.borderedProminent)
                    .disabled(!canContinue)
            case .graphics:
                if isPatching {
                    Spacer()
                    Button("Patching…") {}
                        .buttonStyle(.borderedProminent)
                        .disabled(true)
                } else {
                    Button("Back") { page = .crossOver }
                    Spacer()
                    Button(needsPatch ? "Create Patched Copy & Continue" : "Continue") {
                        applyGraphicsAndContinue()
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!canContinue)
                }
            case .installer:
                Button("Back") { page = .graphics }
                Spacer()
                if installer == nil {
                    Button("Choose Installer…") { chooseInstaller() }
                        .buttonStyle(.borderedProminent)
                } else {
                    Button("Continue") { page = .bottle }
                        .buttonStyle(.borderedProminent)
                        .disabled(SetupValidation.installerError(installer) != nil)
                }
            case .bottle:
                Button("Back") { page = .installer }
                    .disabled(setup.isRunning)
                Spacer()
                Button("Create Bottle & Install…") { createBottle() }
                    .buttonStyle(.borderedProminent)
                    .disabled(setup.isRunning || nameError != nil || installer == nil || patchedApp == nil)
            case .progress:
                Spacer()
                if !setup.logFiles.isEmpty {
                    Button("Show Logs") { revealLogs() }
                }
                Button(setup.isRunning ? "Working…" : "Close") { dismiss() }
                    .buttonStyle(.borderedProminent)
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
                            Label("Will create \(destination.path)", systemImage: "plus.square.on.square")
                                .font(.callout)
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                            if existingPatched != nil {
                                Toggle("Re-create the existing patched copy", isOn: $reCreate)
                            }
                        } else if let patchedApp {
                            Label("Using \(patchedApp.path)", systemImage: "checkmark.seal.fill")
                                .font(.callout)
                                .foregroundStyle(.green)
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                            Toggle("Re-create it from the selected CrossOver", isOn: $reCreate)
                            Button("Reveal in Finder") {
                                NSWorkspace.shared.activateFileViewerSelecting([patchedApp])
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(4)
                }

                if let source, !source.isExpectedVersion {
                    Text("CrossOver \(source.displayVersion) is not \(CrossOverInfo.expectedVersion) — the bundled modules need that Wine ABI. Install CrossOver \(CrossOverInfo.expectedVersion), or use “Create Patched Copy…” on the main window to patch anyway.")
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
                Text("Creating the patched copy\(selectedGPTK != nil ? " with GPTK4 / D3DMetal 4" : "") — copying CrossOver, installing the modules, re-sealing and verifying it. This can take about a minute.")
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                if !engine.steps.isEmpty { StepsListView(steps: engine.steps) }
                if let error = engine.errorMessage { ErrorBox(message: error) }
            }
        } else {
            VStack(alignment: .leading, spacing: 10) {
                GroupBox {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Replace the bundled D3DMetal with Apple's GPTK4 (optional)")
                            .font(.callout.weight(.medium))
                        Text("GPTK4 upgrades CrossOver's D3DMetal 3.0 to D3DMetal 4 (Metal 4 / MetalFX — DLSS and frame generation). Apple's Game Porting Toolkit is **never bundled or redistributed**: download the “Evaluation environment for Windows games 4.0” DMG from Apple's developer page yourself, mount it, then pick it here.")
                            .font(.callout)
                            .fixedSize(horizontal: false, vertical: true)
                        HStack(spacing: 8) {
                            Button("Open Apple's GPTK page") {
                                NSWorkspace.shared.open(gptkPage)
                            }
                            Button("Rescan") { refreshGPTK() }
                            Button("Choose…") { chooseGPTK() }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(4)
                }

                Picker("D3DMetal", selection: $selectedGPTK) {
                    Text("Keep CrossOver's bundled D3DMetal").tag(GPTKSource?.none)
                    ForEach(gptkSources) { source in
                        Text(source.displayName).tag(GPTKSource?.some(source))
                    }
                }
                .labelsHidden()
                .disabled(gptkSources.isEmpty)

                if let selectedGPTK {
                    if selectedGPTK.isVersion4 {
                        Text("Installs \(selectedGPTK.displayName) over CrossOver's D3DMetal 3.0 when the patched copy is created.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    } else {
                        Text("Selected \(selectedGPTK.displayName). Only GPTK4 (D3DMetal 4.x) adds the Metal 4 / MetalFX features — this looks like an older version.")
                            .font(.caption)
                            .foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if !needsPatch {
                        Text("The existing patched copy is reused as-is — selecting a GPTK re-creates it so the new D3DMetal is installed.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                } else if gptkSources.isEmpty {
                    Text("No GPTK redist found. Mount Apple's “Evaluation environment for Windows games …” DMG, then click Rescan — or Choose… the redist/lib/external folder.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Text("Keeping CrossOver's bundled D3DMetal 3.0. The GPTK upgrade is optional.")
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
                    Text("Download the Gryphline installer")
                        .font(.callout.weight(.medium))
                    Text("1. Open the official Endfield download page and download the **Windows** launcher installer (`GRYPHLINK_….exe`, about 170 MB).")
                        .font(.callout)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Open endfield.gryphline.com") {
                        NSWorkspace.shared.open(downloadPage)
                    }
                    Text("2. When the download has finished, click **Find Installer…** and select that `.exe` in the file prompt. Then click **Continue**.")
                        .font(.callout)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(4)
            }

            HStack(spacing: 8) {
                Button("Find Installer…") { chooseInstaller() }
                    .buttonStyle(.borderedProminent)
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
                    Text("No installer selected yet")
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
                        Text("Bottle name")
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
                        Text("Graphics backend")
                        Spacer()
                        Picker("", selection: $settings.backend) {
                            ForEach(BottleBackend.allCases) { backend in
                                Text(backend.displayName).tag(backend)
                            }
                        }
                        .labelsHidden()
                        .frame(width: 260)
                    }

                    Toggle("MSync", isOn: $settings.msync)
                    Text("Recommended on. Turn it off if the launcher or game crashes with leftover Wine processes.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    Toggle("DLSS via MetalFX / NVEXT", isOn: $settings.upscaling)
                        .disabled(!settings.backend.supportsUpscaling)
                    Text(settings.backend.supportsUpscaling
                         ? "Uses the backend's upscaler toggle (D3DMetal → MetalFX, DXMT → NVEXT)."
                         : "Only applies to D3DMetal and DXMT bottles.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(4)
            }

            Text("Windows 11 64-bit · High Resolution Mode off · these defaults match `scripts/create-bottle.sh`. In the game's launcher, DirectX 11 is the most-tested renderer (DirectX 12 renders a white screen); Vulkan is also supported.")
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
                        Label("Bottle “\(bottle)” created", systemImage: "checkmark.seal.fill")
                            .font(.callout.weight(.medium))
                            .foregroundStyle(.green)
                        if setup.installerRunning {
                            Text("The Gryphline installer is open. Finish it in the window behind this sheet — log in and let it download the game. When it exits, this app registers the launcher's menu entries.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        } else if let exit = setup.installerExit {
                            Text(exit == 0
                                 ? "The installer finished. GRYPHLINK should now be listed in the bottle's page in the patched CrossOver."
                                 : "The installer exited with status \(exit). Check the log — you can start it again from the bottle's page.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Text("Afterwards: launch the game with the bottle's **Start** button (DirectX 11 is the most-tested renderer; “Launch with DirectX 11” is in the dropdown), or run `scripts/launch-endfield.sh` from the repository.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        HStack {
                            Button("Reveal Bottle in Finder") {
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
        let applications = URL(fileURLWithPath: "/Applications", isDirectory: true)
        if fm.isWritableFile(atPath: applications.path) {
            return applications.appendingPathComponent(Self.defaultName, isDirectory: true)
        }
        let userApplications = fm.homeDirectoryForCurrentUser
            .appendingPathComponent("Applications", isDirectory: true)
        try? fm.createDirectory(at: userApplications, withIntermediateDirectories: true)
        return userApplications.appendingPathComponent(Self.defaultName, isDirectory: true)
    }

    private static func detectDefaultPatchedApp() -> URL? {
        let apps = SetupValidation.findPatchedCrossOvers()
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
        guard let source else { return }
        if needsPatch {
            isPatching = true
            // The Automated Setup report at the end covers this run; a separate patch report
            // inside the wizard would duplicate it.
            engine.patch(source: source.url, destination: destination, gptk: selectedGPTK, reportTelemetry: false)
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
