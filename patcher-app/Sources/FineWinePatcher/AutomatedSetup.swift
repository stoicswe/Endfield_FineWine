import Foundation

// MARK: - Bottle settings

/// Graphics backend choices for a new bottle. The raw values are the `CX_GRAPHICS_BACKEND`
/// values CrossOver 26 understands (see docs/project-information/06-graphics-and-gptk.md).
enum BottleBackend: String, CaseIterable, Identifiable, Hashable {
    case d3dmetal, dxmt, dxvk, wined3d, auto

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .d3dmetal: return "D3DMetal (recommended)"
        case .dxmt:     return "DXMT"
        case .dxvk:     return "DXVK"
        case .wined3d:  return "WineD3D"
        case .auto:     return "Automatic (CrossOver chooses)"
        }
    }

    /// Value written for `CX_GRAPHICS_BACKEND`. nil leaves the key out, which is CrossOver's Auto.
    var bottleValue: String? {
        self == .auto ? nil : rawValue
    }

    /// The backend-specific upscaler key `scripts/create-bottle.sh` sets.
    var upscalerKey: String? {
        switch self {
        case .d3dmetal: return "D3DM_ENABLE_METALFX"
        case .dxmt:     return "DXMT_ENABLE_NVEXT"
        default:        return nil
        }
    }

    var supportsUpscaling: Bool { upscalerKey != nil }
}

/// The settings the Automated Setup wizard writes into a new bottle. These mirror
/// `scripts/create-bottle.sh` (Windows 11 64-bit, D3DMetal, MetalFX/DLSS, MSync) — the
/// configuration the project's reference bottle uses — and every value is overridable in the UI.
struct BottleSettings: Equatable {
    var name = "Arknights Endfield"
    var backend: BottleBackend = .d3dmetal
    var msync = true
    var upscaling = true
    /// CrossOver bottle template; only Windows 11 64-bit is supported by this project.
    var template = "win11_64"

    /// `[EnvironmentVariables]` entries for `cxbottle --param EnvironmentVariables:KEY=VALUE`.
    var environment: [(key: String, value: String)] {
        var pairs: [(String, String)] = []
        if let backend = backend.bottleValue {
            pairs.append(("CX_GRAPHICS_BACKEND", backend))
        }
        pairs.append(("WINEMSYNC", msync ? "1" : "0"))
        if upscaling, let key = backend.upscalerKey {
            pairs.append((key, "1"))
        }
        return pairs
    }

    var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }
}

// MARK: - Validation

enum SetupValidation {
    /// CrossOver rejects these characters in a bottle name (its own GUI validates the same set).
    private static let forbiddenNameCharacters = CharacterSet(charactersIn: "/\\:*?|\"<>'{}")

    static func bottleNameError(_ raw: String, existing: Set<String>) -> String? {
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty { return "Enter a name for the bottle." }
        if name == "." || name == ".." { return "“\(name)” is not a valid bottle name." }
        if name.count > 64 { return "Keep the bottle name under 64 characters." }
        if name.rangeOfCharacter(from: forbiddenNameCharacters) != nil {
            return "A bottle name cannot contain any of: / \\ : * ? | \" < > ' { }"
        }
        if existing.contains(name) {
            return "A bottle named “\(name)” already exists — choose another name."
        }
        return nil
    }

    static func installerError(_ url: URL?) -> String? {
        guard let url else { return "Choose the Gryphline installer you downloaded." }
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDir), !isDir.boolValue else {
            return "That file no longer exists — download the installer again or choose another file."
        }
        guard url.pathExtension.lowercased() == "exe" else {
            return "That is not a Windows .exe — choose the Gryphline installer (GRYPHLINK_….exe)."
        }
        return nil
    }

    /// A patched CrossOver must carry the patched bundle identifier and a real Wine tree.
    static func isPatchedCrossOver(_ app: URL) -> Bool {
        let plist = app.appendingPathComponent("Contents/Info.plist")
        guard let data = try? Data(contentsOf: plist),
              let parsed = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              parsed["CFBundleIdentifier"] as? String == PatcherEngine.patchedBundleIdentifier
        else { return false }
        return FileManager.default.isExecutableFile(
            atPath: app.appendingPathComponent("Contents/SharedSupport/CrossOver/bin/wine").path)
    }

    /// Patched CrossOver copies found in the usual install locations.
    static func findPatchedCrossOvers() -> [URL] {
        let fm = FileManager.default
        let roots = [
            URL(fileURLWithPath: "/Applications", isDirectory: true),
            fm.homeDirectoryForCurrentUser.appendingPathComponent("Applications", isDirectory: true),
        ]
        var seen = Set<String>()
        var apps: [URL] = []
        for root in roots {
            guard let entries = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else { continue }
            for url in entries where url.pathExtension == "app" {
                guard seen.insert(url.standardizedFileURL.path).inserted else { continue }
                if isPatchedCrossOver(url) { apps.append(url) }
            }
        }
        return apps.sorted { $0.lastPathComponent.localizedCaseInsensitiveCompare($1.lastPathComponent) == .orderedAscending }
    }

    /// Every bottle name CrossOver currently knows about (including bottles on external volumes).
    static func existingBottleNames() -> Set<String> {
        let fm = FileManager.default
        var names = Set(BottleInfo.detectAll().map(\.name))
        for root in BottleInfo.allBottlesRoots() {
            guard let entries = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else { continue }
            for url in entries where (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
                names.insert(url.lastPathComponent)
            }
        }
        return names
    }
}

// MARK: - Engine

/// Creates a bottle with an already-patched CrossOver and starts the Gryphline installer in it.
///
/// This is the bottle half of the Automated Setup wizard. Patching CrossOver stays in
/// `PatcherEngine` (the "Create Patched Copy…" flow) — this engine only needs the resulting app.
@MainActor
final class SetupEngine: ObservableObject {
    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    @Published private(set) var steps: [PatcherEngine.Step] = []
    @Published private(set) var isRunning = false
    @Published var errorMessage: String?
    /// Set once the bottle exists; the wizard shows it on the finished screen.
    @Published private(set) var createdBottle: String?
    /// True while the (interactive) Gryphline installer is up.
    @Published private(set) var installerRunning = false
    /// Exit status of the installer once it finishes, for the finished screen.
    @Published private(set) var installerExit: Int32?
    /// Logs written by this run, so the user can inspect a failure or attach it to a report.
    @Published private(set) var logFiles: [URL] = []
    /// The redacted, unsent report for this setup run. The wizard presents it when it appears;
    /// nothing is sent unless the user chooses Send Statistics there.
    @Published var telemetryPrompt: UsageTelemetry.Prompt?

    private var installerProcess: Process?
    /// Identifies the current run so a delayed prompt from a previous run cannot appear over a
    /// new one (the prompt is created a few seconds after the installer starts).
    private var runID = UUID()

    private static let labels = [
        "Creating the bottle with the patched CrossOver",
        "Starting the Gryphline installer",
    ]

    func reset() {
        steps = []
        errorMessage = nil
        createdBottle = nil
        installerExit = nil
        logFiles = []
        telemetryPrompt = nil
        runID = UUID()
    }

    /// Validates everything, then creates the bottle and launches the installer. The installer is
    /// interactive: this returns as soon as it has *started*, and `installerRunning`/`installerExit`
    /// report its progress afterwards.
    func start(patchedApp: URL, settings: BottleSettings, installer: URL) {
        guard !isRunning else { return }
        reset()

        if let error = SetupValidation.bottleNameError(settings.trimmedName, existing: SetupValidation.existingBottleNames()) {
            errorMessage = error
            return
        }
        if let error = SetupValidation.installerError(installer) {
            errorMessage = error
            return
        }
        let bottle = settings.trimmedName
        let cxr = patchedApp.appendingPathComponent("Contents/SharedSupport/CrossOver", isDirectory: true)
        guard FileManager.default.isExecutableFile(atPath: cxr.appendingPathComponent("bin/cxbottle").path),
              FileManager.default.isExecutableFile(atPath: cxr.appendingPathComponent("bin/wine").path) else {
            errorMessage = "\(patchedApp.lastPathComponent) is not a patched CrossOver app. Create the patched copy first."
            return
        }
        guard settings.template == "win11_64" else {
            errorMessage = "Only the Windows 11 64-bit bottle template is supported."
            return
        }

        isRunning = true
        installerExit = nil
        let runID = UUID()
        self.runID = runID
        steps = Self.labels.enumerated().map { PatcherEngine.Step(id: $0.offset, label: $0.element) }
        let startedAt = Date()

        Task.detached(priority: .userInitiated) {
            var current = 0
            func begin(_ index: Int) async {
                current = index
                await MainActor.run { self.steps[index].status = .running }
            }
            func finish(_ index: Int) async {
                await MainActor.run { self.steps[index].status = .done }
            }
            do {
                let bottleLog = Self.logURL("bottle-\(Self.slug(bottle))")
                await MainActor.run { self.logFiles.append(bottleLog) }

                await begin(0)
                var args = [
                    "--bottle", bottle,
                    "--create",
                    "--template", settings.template,
                    "--description", "Arknights: Endfield (Endfield_FineWine)",
                ]
                for (key, value) in settings.environment {
                    args += ["--param", "EnvironmentVariables:\(key)=\(value)"]
                }
                try Self.runToCompletion(executable: cxr.appendingPathComponent("bin/cxbottle"), args, log: bottleLog)
                await finish(0)

                await begin(1)
                let installerLog = Self.logURL("installer-\(Self.slug(bottle))")
                await MainActor.run {
                    self.logFiles.append(installerLog)
                    self.createdBottle = bottle
                }
                let process = try Self.startInstaller(cxr: cxr, bottle: bottle, installer: installer, log: installerLog)
                let (started, logHandle) = process
                started.terminationHandler = { finished in
                    let status = finished.terminationStatus
                    try? logHandle.close()
                    // Register the launcher's Start-menu entries so the bottle page lists GRYPHLINK.
                    let menuLog = Self.logURL("cxmenu-\(Self.slug(bottle))")
                    _ = try? Self.runToCompletion(
                        executable: cxr.appendingPathComponent("bin/cxmenu"),
                        ["--bottle", bottle, "--install"],
                        log: menuLog
                    )
                    Task { @MainActor in
                        self.installerProcess = nil
                        self.installerRunning = false
                        self.installerExit = status
                        self.logFiles.append(menuLog)
                    }
                }
                await MainActor.run {
                    self.installerProcess = started
                    self.installerRunning = true
                    self.steps[1].status = .done
                    self.isRunning = false
                }

                // Give an installer that dies immediately a moment to do so: a crash before the
                // window appears is reported as a failed setup (with its status and log), not as
                // a success. A longer-running installer is reported as "started".
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                let snapshot = await MainActor.run {
                    (logs: self.logFiles, exit: self.installerExit, current: self.runID == runID)
                }
                guard snapshot.current else { return }
                let failed = snapshot.exit.map { $0 != 0 } ?? false
                let prompt = UsageTelemetry.makeSetupPrompt(
                    succeeded: !failed,
                    failedStep: failed ? 1 : nil,
                    durationSeconds: Int(Date().timeIntervalSince(startedAt)),
                    settings: settings,
                    installerStarted: true,
                    installerExit: snapshot.exit,
                    bottleName: bottle,
                    logs: snapshot.logs.map { ($0.lastPathComponent, $0) }
                )
                await MainActor.run { self.telemetryPrompt = prompt }
            } catch {
                let failed = current
                let logs = await MainActor.run { self.logFiles }
                let prompt = UsageTelemetry.makeSetupPrompt(
                    succeeded: false,
                    failedStep: failed,
                    durationSeconds: Int(Date().timeIntervalSince(startedAt)),
                    settings: settings,
                    installerStarted: false,
                    installerExit: nil,
                    bottleName: bottle,
                    logs: logs.map { ($0.lastPathComponent, $0) }
                )
                await MainActor.run {
                    guard self.runID == runID else { return }
                    if failed < self.steps.count { self.steps[failed].status = .failed }
                    self.errorMessage = error.localizedDescription
                    self.isRunning = false
                    self.telemetryPrompt = prompt
                }
            }
        }
    }

    /// Writes a timestamped log under `~/Library/Logs/FineWinePatcher/`.
    nonisolated static func logURL(_ prefix: String) -> URL {
        let fm = FileManager.default
        let dir = fm.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/FineWinePatcher", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let stamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        return dir.appendingPathComponent("\(prefix)-\(stamp).log")
    }

    private nonisolated static func slug(_ name: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        var slug = name.unicodeScalars.map { allowed.contains($0) ? String($0) : "-" }.joined()
        while slug.contains("--") { slug = slug.replacingOccurrences(of: "--", with: "-") }
        return slug
    }

    /// Runs a helper to completion, capturing stdout/stderr in `log`. Throws with the tail of the
    /// log on a non-zero exit, so the UI can show why the bottle was not created.
    private nonisolated static func runToCompletion(executable: URL, _ args: [String], log: URL) throws {
        let fm = FileManager.default
        let header = "$ \(executable.path) \(args.joined(separator: " "))\n\n"
        fm.createFile(atPath: log.path, contents: header.data(using: .utf8))
        guard let handle = FileHandle(forWritingAtPath: log.path) else {
            throw Failure(message: "Could not write \(log.lastPathComponent).")
        }
        handle.seekToEndOfFile()
        defer { try? handle.close() }

        let process = Process()
        process.executableURL = executable
        process.arguments = args
        process.standardOutput = handle
        process.standardError = handle
        do {
            try process.run()
        } catch {
            throw Failure(message: "Could not run \(executable.lastPathComponent): \(error.localizedDescription)")
        }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw Failure(message: "\(executable.lastPathComponent) failed (exit \(process.terminationStatus)).\n\(logTail(log))")
        }
    }

    /// Starts the installer without waiting for it (it is an interactive GUI application).
    /// Returns the process and the log handle, which the caller closes when the process exits.
    private nonisolated static func startInstaller(cxr: URL, bottle: String, installer: URL, log: URL) throws -> (Process, FileHandle) {
        let fm = FileManager.default
        let header = "$ bin/wine --bottle \"\(bottle)\" --wait-children --enable-alt-loader macdrv -- \(installer.path)\n\n"
        fm.createFile(atPath: log.path, contents: header.data(using: .utf8))
        guard let handle = FileHandle(forWritingAtPath: log.path) else {
            throw Failure(message: "Could not write \(log.lastPathComponent).")
        }
        handle.seekToEndOfFile()

        let process = Process()
        process.executableURL = cxr.appendingPathComponent("bin/wine")
        process.arguments = [
            "--bottle", bottle,
            "--wait-children",
            "--enable-alt-loader", "macdrv",
            "--", installer.path,
        ]
        process.standardOutput = handle
        process.standardError = handle
        do {
            try process.run()
        } catch {
            try? handle.close()
            throw Failure(message: "Could not start the installer: \(error.localizedDescription)")
        }
        return (process, handle)
    }

    private nonisolated static func logTail(_ log: URL, limit: Int = 1200) -> String {
        guard let text = try? String(contentsOf: log, encoding: .utf8) else { return "" }
        let tail = text.suffix(limit)
        return tail.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
