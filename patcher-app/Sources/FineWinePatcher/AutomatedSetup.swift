import Foundation

// MARK: - Bottle settings

/// Graphics backend choices for a new bottle. The raw values are the `CX_GRAPHICS_BACKEND`
/// values CrossOver 26 understands (see docs/project-information/06-graphics-and-gptk.md).
enum BottleBackend: String, CaseIterable, Identifiable, Hashable {
    case d3dmetal, dxmt, dxvk, wined3d, auto

    var id: String { rawValue }

    /// The backends a variant can run. D3DMetal is x86_64-only.
    static func available(for variant: CrossOverVariant?) -> [BottleBackend] {
        variant?.supportsD3DMetal == false ? allCases.filter { $0 != .d3dmetal } : allCases
    }

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
    var metalHUD = false
    /// CrossOver bottle template; only Windows 11 64-bit is supported by this project.
    var template = "win11_64"

    /// `[EnvironmentVariables]` entries for `cxbottle --param EnvironmentVariables:KEY=VALUE`.
    var environment: [(key: String, value: String)] {
        environment(msyncOverride: msync)
    }

    /// `environment` with an override for the WINEMSYNC value — the setup's MSync-off fallback
    /// retry uses this. The Metal 4 guard applies the same way.
    func environment(msyncOverride: Bool) -> [(key: String, value: String)] {
        var pairs: [(String, String)] = []
        if let backend = backend.bottleValue {
            pairs.append(("CX_GRAPHICS_BACKEND", backend))
        }
        pairs.append(("WINEMSYNC", msyncOverride ? "1" : "0"))
        if upscaling, let key = backend.upscalerKey {
            pairs.append((key, "1"))
        }
        if metalHUD {
            pairs.append(("MTL_HUD_ENABLED", "1"))
        }
        return Self.withoutUnsupportedMetal4Properties(pairs)
    }

    /// The D3DMetal property keys that select the Metal 4 backend. GPTK4 (D3DMetal 4) guides
    /// write them as `D3DM_MTL4=1` or as a `"D3D_MTL_4" = "1"` line in cxbottle.conf, and
    /// GPTK4 beta 2 even makes Metal 4 the DirectX 12 default — but only on macOS 27+.
    static let metal4PropertyKeys: Set<String> = ["D3DM_MTL4", "D3D_MTL_4"]

    /// The first macOS release whose D3DMetal supports Metal 4.
    static let metal4OSMajor = 27

    /// Drops Metal 4 property keys when this Mac cannot use them. Metal 4 is macOS 27-era
    /// software: on macOS 26 such keys would force D3DMetal 4 down an unsupported backend, so
    /// they must never reach a bottle config — whatever asked for them.
    static func withoutUnsupportedMetal4Properties(
        _ pairs: [(key: String, value: String)],
        osMajor: Int = ProcessInfo.processInfo.operatingSystemVersion.majorVersion
    ) -> [(key: String, value: String)] {
        guard osMajor < metal4OSMajor else { return pairs }
        return pairs.filter { !metal4PropertyKeys.contains($0.key.uppercased()) }
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
              let identifier = parsed["CFBundleIdentifier"] as? String,
              CrossOverVariant.allCases.contains(where: { $0.patchedBundleIdentifier == identifier })
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
    /// True when the bottle only created after the MSync-off fallback retry; the finished screen
    /// tells the user MSync was disabled (a per-bottle performance-relevant change).
    @Published private(set) var msyncFallback = false
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
        msyncFallback = false
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
        let variant = CrossOverInfo(url: patchedApp).variant
        guard BottleBackend.available(for: variant).contains(settings.backend) else {
            errorMessage = "\(settings.backend.displayName) can't run on the ARM variant of CrossOver."
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
            var msyncFallbackUsed = false
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
                // A copy patched with a GPTK whose D3DMetal DLLs weren't installed crashes every
                // DirectX 11 program, the Gryphline launcher included — fix it before using it.
                if let mismatch = D3DMetalRepair.mismatch(in: patchedApp) {
                    Self.append(log: bottleLog, text: "D3DMetal mismatch: \(mismatch.summary)\n")
                    let result = try PatcherEngine.repairD3DMetalNow(in: patchedApp)
                    Self.append(log: bottleLog, text: "D3DMetal repaired: \(result)\n")
                }
                // Preflight: prove the machine can exec this x86_64 Wine at all (Rosetta 2, dyld,
                // the winetemp ntdll.so loader path) before cxbottle starts. A loader-level kill
                // — the macOS 26 silent-failure class — then reports an actionable message with
                // its stderr instead of a cryptic 'win11Install crossover.inf failed'.
                let preflightLog = Self.logURL("preflight-\(Self.slug(bottle))")
                await MainActor.run { self.logFiles.append(preflightLog) }
                try Self.runPreflight(cxr: cxr, log: preflightLog,
                                      requiresRosetta: variant?.requiresRosetta ?? true)

                do {
                    try Self.runToCompletion(
                        executable: cxr.appendingPathComponent("bin/cxbottle"),
                        Self.cxbottleArguments(bottle: bottle, template: settings.template,
                                               wineArch: variant?.bottleWineArch,
                                               environment: settings.environment),
                        log: bottleLog)
                } catch let firstError {
                    // WineHQ bug 59595's macOS 26 class can kill bottle creation with MSync on
                    // while it succeeds without it — the same MSYNC=0 workaround
                    // scripts/create-bottle.sh documents. Remove the partial bottle and retry
                    // once with MSync off; only a real MSync interaction can be recovered here.
                    guard settings.msync else { throw firstError }
                    msyncFallbackUsed = true
                    await MainActor.run { self.msyncFallback = true }
                    Self.append(log: bottleLog, text: """
                        \nfirst cxbottle attempt failed: \(firstError.localizedDescription)
                        retrying once with WINEMSYNC=0 (MSync-off fallback)

                        """)
                    Self.removePartialBottle(named: bottle, log: bottleLog)
                    try Self.runToCompletion(
                        executable: cxr.appendingPathComponent("bin/cxbottle"),
                        Self.cxbottleArguments(bottle: bottle, template: settings.template,
                                               wineArch: variant?.bottleWineArch,
                                               environment: settings.environment(msyncOverride: false)),
                        log: bottleLog)
                }
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
                    msyncFallback: msyncFallbackUsed,
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
                    msyncFallback: msyncFallbackUsed,
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

    /// The cxbottle argument vector, in one place so the first attempt, the MSync-off fallback
    /// retry and the tests all build it the same way.
    nonisolated static func cxbottleArguments(bottle: String, template: String, wineArch: String? = nil,
                                              environment: [(key: String, value: String)]) -> [String] {
        var args = [
            "--bottle", bottle,
            "--create",
            "--template", template,
            "--description", "Arknights: Endfield (Endfield_FineWine)",
        ]
        if let wineArch {
            args += ["--winearch", wineArch]
        }
        for (key, value) in environment {
            args += ["--param", "EnvironmentVariables:\(key)=\(value)"]
        }
        return args
    }

    /// Runs before cxbottle so a machine that cannot exec this x86_64 Wine fails with an
    /// actionable message (and a log) instead of a cryptic 'win11Install crossover.inf failed'
    /// two steps later. Both checks capture output into `log`, which rides along in the setup
    /// report:
    ///
    /// 1. Rosetta 2 present (Apple Silicon only): the Wine we ship is x86_64. The wizard never
    ///    launches stock CrossOver first, so nothing else triggers the Rosetta install prompt.
    /// 2. `wine --version` really runs: it exercises the Rosetta exec, dyld and the winetemp
    ///    ntdll.so loader path end to end (the macOS 26 loader-kill class shows up here).
    /// `requiresRosetta` is false for the native ARM variant, which skips step 1.
    /// `archPath` is injectable so tests can stay hermetic (no real Rosetta required).
    nonisolated static func runPreflight(cxr: URL, log: URL, requiresRosetta: Bool = true,
                                         archPath: String = "/usr/bin/arch") throws {
        append(log: log, text: "$ preflight: \(requiresRosetta ? "Rosetta 2 + " : "")bin/wine --version\n")
        if requiresRosetta, isAppleSilicon() {
            let rosetta = runCaptured(archPath, ["-x86_64", "/usr/bin/true"])
            append(log: log, text: "$ /usr/bin/arch -x86_64 /usr/bin/true -> exit \(rosetta.status)\n\(rosetta.output)")
            guard rosetta.status == 0 else {
                throw Failure(message: """
                    Rosetta 2 is not installed — the patched Wine is x86_64 and needs it on Apple Silicon. \
                    Install it in Terminal with: softwareupdate --install-rosetta --agree-to-license
                    """)
            }
        }
        let wine = runCaptured(cxr.appendingPathComponent("bin/wine").path, ["--version"])
        append(log: log, text: "$ bin/wine --version -> exit \(wine.status)\n\(wine.output)")
        guard wine.status == 0, wineVersionLooksValid(wine.output) else {
            throw Failure(message: """
                wine failed to start (exit \(wine.status)) — the patched CrossOver copy is broken \
                or the machine cannot run its binaries. See the preflight log for output.
                """)
        }
        append(log: log, text: "preflight ok: \(wine.output.trimmingCharacters(in: .whitespacesAndNewlines))\n")
    }

    /// Whether `wine --version` output proves that Wine actually ran.
    ///
    /// WineHQ builds print `wine-11.0`, but the CrossOver trees this project patches print
    /// CrossOver's banner instead (`Product Name: CrossOver`, `Public Version: 26.3.0`, …),
    /// which contains neither "wine" nor a version on its first line. Any non-empty output
    /// naming Wine or CrossOver counts as healthy; empty output stays the silent-kill
    /// signature that must fail.
    nonisolated static func wineVersionLooksValid(_ output: String) -> Bool {
        let text = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return false }
        let lower = text.lowercased()
        return lower.contains("wine") || lower.contains("crossover") || lower.contains("cxoffice")
    }

    /// Removes the partial bottle directory a failed `cxbottle --create` leaves behind (it can
    /// exist with a conf but no working prefix). The setup's own validation guarantees no bottle
    /// with this name existed when the setup started, so anything found now is this run's.
    private nonisolated static func removePartialBottle(named name: String, log: URL) {
        let fm = FileManager.default
        var removed = false
        for root in BottleInfo.allBottlesRoots() {
            let dir = root.appendingPathComponent(name, isDirectory: true)
            guard fm.fileExists(atPath: dir.path) else { continue }
            if (try? fm.removeItem(at: dir)) != nil { removed = true }
        }
        append(log: log, text: removed ? "removed the partial bottle directory\n" : "no partial bottle directory found\n")
    }

    /// Appends text to a log file, creating it if needed (best effort — logging must never fail
    /// the setup).
    private nonisolated static func append(log: URL, text: String) {
        let fm = FileManager.default
        if !fm.fileExists(atPath: log.path) {
            fm.createFile(atPath: log.path, contents: Data())
        }
        guard let handle = FileHandle(forWritingAtPath: log.path) else { return }
        defer { try? handle.close() }
        handle.seekToEndOfFile()
        handle.write(Data(text.utf8))
    }

    /// Runs a short command, capturing its combined output; used by the preflight checks.
    private nonisolated static func runCaptured(_ launchPath: String, _ args: [String]) -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = args
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
        } catch {
            return (127, "could not launch \(launchPath): \(error.localizedDescription)\n")
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(data: data, encoding: .utf8) ?? "")
    }

    /// True on Apple Silicon Macs (the only machines that need Rosetta 2 for this x86_64 Wine).
    private nonisolated static func isAppleSilicon() -> Bool {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        return sysctlbyname("hw.optional.arm64", &value, &size, nil, 0) == 0 && value == 1
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
