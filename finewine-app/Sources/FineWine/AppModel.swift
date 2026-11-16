import SwiftUI
import AppKit
import ServiceManagement
import UniformTypeIdentifiers
import FineWineCore

struct AppAlert: Identifiable {
    let id = UUID()
    var title: String
    var message: String
}

/// The app's state: the prefixes, runtimes and profiles on disk, what is running, and the
/// actions the views trigger. Wine work happens off the main thread; results come back here.
@MainActor
final class AppModel: ObservableObject {
    static let shared = AppModel()

    let service: PrefixService

    @Published var prefixes: [Prefix] = []
    @Published var runtimes: [WineRuntime] = []
    @Published var profiles: [GameProfile] = []
    @Published var selection: UUID?
    /// Live process ids started from FineWine, per prefix.
    @Published var running: [UUID: Set<Int32>] = [:]
    /// What a prefix is busy with ("Setting up…"), shown in place of its controls.
    @Published var busy: [UUID: String] = [:]
    @Published var alert: AppAlert?
    @Published var isCreatingPrefix = false
    /// The prefix being made for a file opened from Finder, shown while it is set up.
    @Published var settingUpPrefixName: String?
    /// A tab of the prefix view to switch to (`configuration`, …), consumed by that view.
    @Published var requestedSection: String?

    /// True once a file or link has been handed to FineWine to open. A first run that starts
    /// that way does not show the manager window.
    var wasAskedToOpenSomething = false

    /// Set by the menu bar label, which is the one view that always exists.
    var openMainWindow: () -> Void = {}

    init(service: PrefixService = PrefixService(paths: .standard())) {
        self.service = service
        try? service.paths.ensureDirectories()
        reload()
    }

    /// The Mac's current look: light or dark, and the accent colour.
    var currentAppearance: MacAppearance {
        let isDark = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        var accent = MacAppearance.standard
        // Resolve the dynamic accent colour under the app's own appearance.
        NSApp.effectiveAppearance.performAsCurrentDrawingAppearance {
            if let rgb = NSColor.controlAccentColor.usingColorSpace(.sRGB) {
                accent = MacAppearance(isDark: isDark,
                                       accentRed: Int((rgb.redComponent * 255).rounded()),
                                       accentGreen: Int((rgb.greenComponent * 255).rounded()),
                                       accentBlue: Int((rgb.blueComponent * 255).rounded()))
            }
        }
        accent.isDark = isDark
        // The sharpest attached display decides: a window dragged onto it should not look soft.
        accent.displayScale = Double(NSScreen.screens.map(\.backingScaleFactor).max() ?? 2)
        return accent
    }

    // MARK: State

    func reload() {
        prefixes = service.prefixes.list()
        runtimes = service.runtimes.list()
        profiles = service.profiles.list()
        if selection == nil || !prefixes.contains(where: { $0.id == selection }) {
            selection = prefixes.first?.id
        }
    }

    var usableRuntimes: [WineRuntime] { runtimes.filter(\.isUsable) }

    func prefix(_ id: UUID?) -> Prefix? { prefixes.first { $0.id == id } }
    func runtime(for prefix: Prefix) -> WineRuntime? { runtimes.first { $0.id == prefix.metadata.runtimeID } }
    func profile(for prefix: Prefix) -> GameProfile? { profiles.first { $0.id == prefix.metadata.profileID } }
    func isRunning(_ prefix: Prefix) -> Bool { !(running[prefix.id] ?? []).isEmpty }
    var runningCount: Int { running.values.reduce(0) { $0 + $1.count } }

    private func replace(_ prefix: Prefix) {
        if let index = prefixes.firstIndex(where: { $0.id == prefix.id }) {
            prefixes[index] = prefix
        } else {
            reload()
        }
    }

    func show(_ error: Error, title: String) {
        alert = AppAlert(title: title, message: error.localizedDescription)
    }

    /// Runs blocking work off the main thread, with the prefix marked busy meanwhile.
    /// With `splash`, the status window says so too: for work the user is left waiting on.
    private func work<T: Sendable>(on prefixID: UUID?, _ status: String, failure: String, splash: Bool = false,
                                   _ body: @escaping @Sendable (PrefixService) throws -> T) async -> T? {
        if let prefixID { busy[prefixID] = status }
        let token = splash ? StatusSplash.shared.show(title: prefix(prefixID)?.name ?? "FineWine", message: status) : nil
        defer {
            if let prefixID { busy[prefixID] = nil }
            StatusSplash.shared.hide(token)
        }
        let service = UncheckedBox(service)
        do {
            return try await Task.detached(priority: .userInitiated) { try body(service.value) }.value
        } catch {
            show(error, title: failure)
            return nil
        }
    }

    // MARK: Prefixes

    func createPrefix(name: String, runtime: WineRuntime, profile: GameProfile?) async -> Bool {
        isCreatingPrefix = true
        defer { isCreatingPrefix = false }
        let appearance = currentAppearance
        let token = StatusSplash.shared.show(title: "Setting up “\(name)”", message: "Creating the prefix…")
        defer { StatusSplash.shared.hide(token) }
        let created = await work(on: nil, "", failure: "The prefix couldn't be created") {
            try $0.createPrefix(name: name, runtime: runtime, profile: profile, appearance: appearance) { stage in
                Task { @MainActor in StatusSplash.shared.update(token, message: stage) }
            }
        }
        reload()
        if let created { selection = created.id }
        return created != nil
    }

    /// Stores new settings and writes them into the prefix's registry.
    func apply(_ settings: PrefixSettings, runtimeID: String?, to prefix: Prefix) async {
        var updated = prefix
        updated.metadata.settings = settings
        updated.metadata.runtimeID = runtimeID
        do { try service.prefixes.save(updated) } catch { return show(error, title: "The settings couldn't be saved") }
        replace(updated)
        let toApply = updated
        let appearance = currentAppearance
        if let applied = await work(on: prefix.id, "Applying settings…", failure: "The settings couldn't be applied", splash: true, {
            try $0.applySettings(to: toApply, appearance: appearance)
        }) {
            replace(applied)
        }
    }

    func rename(_ prefix: Prefix, to name: String) {
        do { replace(try service.prefixes.rename(prefix, to: name)); reload() }
        catch { show(error, title: "The prefix couldn't be renamed") }
    }

    func duplicate(_ prefix: Prefix) async {
        let name = prefix.name + " copy"
        if let copy = await work(on: prefix.id, "Duplicating…", failure: "The prefix couldn't be duplicated", splash: true, {
            try $0.prefixes.duplicate(prefix, as: name)
        }) {
            reload()
            selection = copy.id
        }
    }

    func delete(_ prefix: Prefix) async {
        _ = await work(on: prefix.id, "Deleting…", failure: "The prefix couldn't be deleted") {
            try $0.deletePrefix(prefix)
        }
        running[prefix.id] = nil
        reload()
    }

    func stopAll(in prefix: Prefix) async {
        _ = await work(on: prefix.id, "Stopping…", failure: "The prefix's programs couldn't be stopped") {
            try $0.stopAll(in: prefix)
        }
        running[prefix.id] = nil
    }

    /// Asks every program in the prefix to close, as shutting Windows down does.
    func shutDown(_ prefix: Prefix) async {
        _ = await work(on: prefix.id, "Shutting down…", failure: "The prefix couldn't be shut down") {
            try $0.shutDown(prefix)
        }
        running[prefix.id] = nil
    }

    /// Ends everything in the prefix at once, frozen programs included.
    func forceShutDown(_ prefix: Prefix) async {
        _ = await work(on: prefix.id, "Forcing shut down…", failure: "The prefix couldn't be forced to shut down") {
            try $0.forceShutDown(prefix)
        }
        running[prefix.id] = nil
    }

    // MARK: Quitting

    /// Decides whether FineWine may quit. With nothing running it may. Otherwise the user is
    /// shown what is running and asked; on a yes every program is asked to close, and what has
    /// not closed after five seconds is ended. Returns false when the user said no.
    func confirmQuit() async -> Bool {
        let all = prefixes
        let service = UncheckedBox(service)
        let runningNow = await Task.detached(priority: .userInitiated) {
            all.compactMap { prefix -> (Prefix, [String])? in
                let names = service.value.runningProgramNames(in: prefix)
                return names.isEmpty ? nil : (prefix, names)
            }
        }.value
        guard !runningNow.isEmpty else { return true }

        let count = runningNow.reduce(0) { $0 + $1.1.count }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = count == 1 ? "Quit FineWine and close 1 running program?"
                                       : "Quit FineWine and close \(count) running programs?"
        let list = runningNow.map { prefix, names in
            names.count == 1 && names[0] == prefix.name ? "•  \(prefix.name)"
                                                        : "•  \(prefix.name): " + names.joined(separator: ", ")
        }.joined(separator: "\n")
        alert.informativeText = "These are still running:\n\n\(list)\n\nThey will be asked to close. Any that have not closed after 5 seconds are ended, and unsaved work in them is lost."
        alert.addButton(withTitle: "Close and Quit")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate()
        guard alert.runModal() == .alertFirstButtonReturn else { return false }

        let token = StatusSplash.shared.show(title: "Quitting FineWine",
                                             message: count == 1 ? "Closing 1 program…" : "Closing \(count) programs…")
        let toClose = runningNow.map(\.0)
        _ = await Task.detached(priority: .userInitiated) {
            service.value.closeEverything(in: toClose, grace: 5).map(\.id)
        }.value
        StatusSplash.shared.hide(token)
        running.removeAll()
        return true
    }

    func wineboot(_ action: WinebootAction, in prefix: Prefix, status: String) async {
        _ = await work(on: prefix.id, status, failure: "Wine reported a problem", splash: true) {
            try $0.runWineboot(action, in: prefix)
        }
    }

    // MARK: Programs and shortcuts

    func addProgram(_ program: Program, to prefix: Prefix) {
        do { replace(try service.addProgram(program, to: prefix)) }
        catch { show(error, title: "The program couldn't be added") }
    }

    func update(_ program: Program, in prefix: Prefix) {
        var updated = prefix
        guard let index = updated.metadata.programs.firstIndex(where: { $0.id == program.id }) else { return }
        updated.metadata.programs[index] = program
        do {
            try service.prefixes.save(updated)
            replace(updated)
            // Keep the shortcut's name in step with the program's.
            if program.shortcutPath != nil { createShortcut(for: program.id, in: updated) }
        } catch { show(error, title: "The program couldn't be saved") }
    }

    func removeProgram(_ program: Program, from prefix: Prefix) {
        do { replace(try service.removeProgram(id: program.id, from: prefix)) }
        catch { show(error, title: "The program couldn't be removed") }
    }

    @discardableResult
    func findInstalledPrograms(in prefix: Prefix, quietly: Bool = false) -> Int {
        do {
            let result = try service.importDiscoveredPrograms(into: prefix)
            replace(result.prefix)
            if !quietly, result.added == 0 {
                alert = AppAlert(title: "No new programs found",
                                 message: "FineWine looks at the shortcuts installers leave in the Start menu and on the desktop. A program that made none can be added with Add Program.")
            }
            return result.added
        } catch {
            show(error, title: "The prefix couldn't be searched")
            return 0
        }
    }

    func createShortcut(for programID: UUID, in prefix: Prefix) {
        do {
            let updated = try service.createShortcut(for: programID, in: prefix)
            replace(updated)
            // An ad-hoc signature keeps macOS from treating the generated app as damaged.
            if let path = updated.program(id: programID)?.shortcutPath {
                let sign = Process()
                sign.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
                sign.arguments = ["--force", "--sign", "-", path]
                sign.standardOutput = FileHandle.nullDevice
                sign.standardError = FileHandle.nullDevice
                try? sign.run()
            }
        } catch { show(error, title: "The shortcut couldn't be made") }
    }

    func removeShortcut(for programID: UUID, in prefix: Prefix) {
        do { replace(try service.removeShortcut(for: programID, in: prefix)) }
        catch { show(error, title: "The shortcut couldn't be removed") }
    }

    // MARK: Launching

    private func track(_ pid: Int32, in prefixID: UUID) {
        running[prefixID, default: []].insert(pid)
    }

    private func exitHandler(prefixID: UUID, pidBox: PIDBox, then: (@MainActor @Sendable () -> Void)? = nil) -> @Sendable (Int32) -> Void {
        { _ in
            Task { @MainActor in
                if let pid = pidBox.pid { AppModel.shared.running[prefixID]?.remove(pid) }
                then?()
            }
        }
    }

    /// Looks for programs that have appeared in a prefix since it was last looked at, lists
    /// them, and gives each a Mac app: what a Windows installer does with shortcuts, done the
    /// Mac way. Run when an installer finishes, and when any program does, because launchers
    /// install games and make their shortcuts long after their own installer has gone.
    func adoptNewPrograms(in prefixID: UUID) {
        guard let current = prefix(prefixID) else { return }
        let before = Set(current.metadata.programs.map(\.id))
        findInstalledPrograms(in: current, quietly: true)
        let added = prefix(prefixID)?.metadata.programs.filter { !before.contains($0.id) } ?? []
        nameAfterInstalledPrograms(prefixID, added: added)
        for program in added {
            if let prefix = prefix(prefixID) { createShortcut(for: program.id, in: prefix) }
        }
    }

    /// The status window for something that is being started in a prefix. The token it
    /// returns ends it when the program ends before showing a window.
    private func startingStatus(_ name: String, icon: NSImage? = nil, in prefix: Prefix) -> UUID? {
        let updating = (try? service.runtime(for: prefix)).map {
            StartupStatus.prefixNeedsWineUpdate(prefix: prefix.directory, runtimeRoot: $0.root)
        } ?? false
        return StatusSplash.shared.showLaunch(title: "Starting \(name)", icon: icon, updatingPrefix: updating)
    }

    func launch(_ program: Program, in prefix: Prefix) {
        let box = PIDBox()
        let prefixID = prefix.id
        // The icon of the program's shortcut app, when it has one: that is the program's own.
        let icon = program.shortcutPath.flatMap { FileManager.default.fileExists(atPath: $0) ? NSWorkspace.shared.icon(forFile: $0) : nil }
        let status = startingStatus(program.name, icon: icon, in: prefix)
        do {
            let pid = try service.launch(programID: program.id, in: prefix, onExit: exitHandler(prefixID: prefix.id, pidBox: box) {
                StatusSplash.shared.hide(status)
                AppModel.shared.adoptNewPrograms(in: prefixID)
            })
            box.pid = pid
            track(pid, in: prefix.id)
        } catch {
            StatusSplash.shared.hide(status)
            show(error, title: "“\(program.name)” couldn't be started")
        }
    }

    /// Opens a Wine tool. If the Mac's appearance has changed since the prefix was last styled
    /// (light to dark, or a new accent colour), the styling is brought up to date first so the
    /// tool opens matching the Mac.
    func open(_ tool: WineTool, in prefix: Prefix) async {
        var current = prefix
        let appearance = currentAppearance
        if service.needsAppearanceRefresh(prefix, current: appearance),
           prefix.metadata.settings == prefix.metadata.appliedSettings {
            let refreshed = await work(on: prefix.id, "Matching the Mac's appearance…",
                                       failure: "The appearance couldn't be updated", splash: true) {
                try $0.applySettings(to: prefix, appearance: appearance)
            }
            if let refreshed { replace(refreshed); current = refreshed }
        }
        launch(tool, in: current)
    }

    func launch(_ tool: WineTool, in prefix: Prefix) {
        let box = PIDBox()
        let status = startingStatus(tool.displayName, in: prefix)
        do {
            let pid = try service.launch(tool: tool, in: prefix, onExit: exitHandler(prefixID: prefix.id, pidBox: box) {
                StatusSplash.shared.hide(status)
            })
            box.pid = pid
            track(pid, in: prefix.id)
        } catch {
            StatusSplash.shared.hide(status)
            show(error, title: "\(tool.displayName) couldn't be started")
        }
    }

    /// Runs an installer, then looks for the programs it added.
    func runInstaller(_ url: URL, in prefix: Prefix) {
        let box = PIDBox()
        let prefixID = prefix.id
        let status = startingStatus(url.deletingPathExtension().lastPathComponent, in: prefix)
        do {
            let pid = try service.launch(executable: url, in: prefix, onExit: exitHandler(prefixID: prefixID, pidBox: box) {
                StatusSplash.shared.hide(status)
                AppModel.shared.adoptNewPrograms(in: prefixID)
            })
            box.pid = pid
            track(pid, in: prefix.id)
        } catch {
            StatusSplash.shared.hide(status)
            show(error, title: "“\(url.lastPathComponent)” couldn't be started")
        }
    }

    /// Handles a `finewine://` link from a shortcut app.
    func handle(_ url: URL) {
        guard let link = LaunchURL(url: url) else { return }
        reload()
        switch link {
        case .launch(let prefixID, let programID):
            guard let prefix = prefix(prefixID), let program = prefix.program(id: programID) else {
                alert = AppAlert(title: "That shortcut no longer works",
                                 message: "The program it starts has been removed from FineWine. You can delete the shortcut.")
                openMainWindow()
                return
            }
            launch(program, in: prefix)
            if alert != nil { openMainWindow() }
        case .show(let prefixID, let section):
            show(prefixID: prefixID, section: section)
        }
    }

    /// Brings the manager window forward on one prefix, optionally on a particular tab.
    func show(prefixID: UUID, section: String? = nil) {
        selection = prefixID
        requestedSection = section
        openMainWindow()
    }

    // MARK: Runtimes

    func addRuntime(from folder: URL) {
        do {
            // A folder with a runtime.json is a packaged FineWine runtime and is copied in;
            // any other Wine folder is used where it is.
            if FileManager.default.fileExists(atPath: folder.appendingPathComponent(RuntimeStore.manifestName).path) {
                try service.runtimes.installManaged(from: folder)
            } else {
                try service.runtimes.addExternal(folder)
            }
            reload()
        } catch { show(error, title: "The runtime couldn't be added") }
    }

    func remove(_ runtime: WineRuntime) {
        do {
            switch runtime.kind {
            case .managed: try service.runtimes.removeManaged(id: runtime.id)
            case .external: try service.runtimes.removeExternal(runtime.root)
            case .bundled: break   // part of the app; the list offers no way to remove it
            }
            reload()
        } catch { show(error, title: "The runtime couldn't be removed") }
    }

    func prefixesUsing(_ runtime: WineRuntime) -> [Prefix] {
        prefixes.filter { $0.metadata.runtimeID == runtime.id }
    }

    /// Whether the status window is shown while prefixes are set up and programs start.
    var showsStatusWindow: Bool {
        get { StatusSplash.shared.isEnabled }
        set {
            objectWillChange.send()
            StatusSplash.shared.isEnabled = newValue
        }
    }

    // MARK: Opening files from Finder

    private static let openedFilePolicyKey = "OpenedFilePolicy"

    /// What happens to a file opened from outside any prefix: a prefix of its own, made without
    /// asking, or a question.
    var openedFilePolicy: OpenedFilePolicy {
        get { UserDefaults.standard.string(forKey: Self.openedFilePolicyKey).flatMap(OpenedFilePolicy.init) ?? .autoCreate }
        set {
            objectWillChange.send()
            UserDefaults.standard.set(newValue.rawValue, forKey: Self.openedFilePolicyKey)
        }
    }

    /// Names of prefixes that are being made for opened files, so that two files opened at
    /// once don't get the same name.
    private var pendingPrefixNames: [String] = []
    /// Prefixes made for an opened file whose name was only guessed from the file's name. Once
    /// the installer has finished, such a prefix is named after what it installed.
    private var guessedPrefixNames: [UUID: String] = [:]

    /// Gives a prefix with a guessed name the name of what was installed into it, unless the
    /// user has renamed it meanwhile or nothing recognisable was installed.
    private func nameAfterInstalledPrograms(_ prefixID: UUID, added: [Program]) {
        guard let guessed = guessedPrefixNames.removeValue(forKey: prefixID),
              let prefix = prefix(prefixID), prefix.name == guessed,
              let found = InstallName.installedName(programs: added.map { ($0.name, $0.windowsPath) }) else { return }
        let name = InstallName.unique(found, among: prefixes.filter { $0.id != prefixID }.map(\.name))
        guard name != prefix.name, let renamed = try? service.prefixes.rename(prefix, to: name) else { return }
        replace(renamed)
    }

    /// Runs a Windows executable or installer opened from Finder: straight away when it lives
    /// in a prefix; otherwise in a new prefix named after it, or wherever the user says,
    /// depending on `openedFilePolicy`.
    func open(executable url: URL) {
        reload()
        switch WindowsExecutable.route(for: url, prefixes: prefixes) {
        case .unsupported:
            alert = AppAlert(title: "FineWine can't open “\(url.lastPathComponent)”",
                             message: "It opens Windows programs and installers (.exe and .msi files).")
            openMainWindow()
        case .run(let prefix):
            runInstaller(url, in: prefix)
            if alert != nil { openMainWindow() }
        case .needsPrefix, .choose:
            let hint = InstallName.prefixHint(for: url, existing: prefixes.map(\.name) + pendingPrefixNames)
            let name = hint.name
            if openedFilePolicy == .autoCreate {
                run(url, inNewPrefixNamed: name, renameAfterInstall: !hint.isFromInstaller)
            } else {
                switch Panels.choosePrefix(for: url, newPrefixName: name, from: prefixes, preselected: selection) {
                case .none: return
                case .new: run(url, inNewPrefixNamed: name, renameAfterInstall: !hint.isFromInstaller)
                case .existing(let prefix):
                    runInstaller(url, in: prefix)
                    if alert != nil { openMainWindow() }
                }
            }
        }
    }

    /// Makes a prefix for an opened file, with the first usable runtime (the built-in one when
    /// the app has it), and runs the file in it. No window is opened for this: the program's
    /// own window is what the user is waiting for. The menu bar panel, and the manager window
    /// if it happens to be open, say what is being set up; only a failure opens the manager.
    private func run(_ url: URL, inNewPrefixNamed name: String, renameAfterInstall: Bool) {
        guard let runtime = usableRuntimes.first else {
            alert = AppAlert(title: "No Wine runtime",
                             message: "“\(url.lastPathComponent)” needs a prefix to run in, and there is no usable runtime to make one with. Add one in Settings, then open the file again.")
            openMainWindow()
            return
        }
        pendingPrefixNames.append(name)
        Task { @MainActor in
            settingUpPrefixName = name
            let created = await createPrefix(name: name, runtime: runtime, profile: nil)
            pendingPrefixNames.removeAll { $0 == name }
            settingUpPrefixName = pendingPrefixNames.first
            guard created, let prefix = prefixes.first(where: { $0.name == name }) else {
                openMainWindow()      // the reason is in an alert, which the manager window shows
                return
            }
            selection = prefix.id
            if renameAfterInstall { guessedPrefixNames[prefix.id] = name }
            runInstaller(url, in: prefix)
            if alert != nil { openMainWindow() }
        }
    }

    // MARK: File association

    private static let previousHandlersKey = "PreviousExecutableHandlers"

    private var executableTypes: [UTType] {
        WindowsExecutable.typeIdentifiers.compactMap { UTType($0) }
    }

    private func isFineWine(_ app: URL?) -> Bool {
        app?.resolvingSymlinksInPath().path == Bundle.main.bundleURL.resolvingSymlinksInPath().path
    }

    /// Whether double-clicking a Windows executable opens FineWine.
    var opensWindowsExecutables: Bool {
        guard let exe = UTType(WindowsExecutable.exeTypeIdentifier) else { return false }
        return isFineWine(NSWorkspace.shared.urlForApplication(toOpen: exe))
    }

    /// The app that opens `.exe` files now, for showing in Settings.
    var currentExecutableHandlerName: String? {
        guard let exe = UTType(WindowsExecutable.exeTypeIdentifier),
              let app = NSWorkspace.shared.urlForApplication(toOpen: exe) else { return nil }
        return FileManager.default.displayName(atPath: app.path)
    }

    /// Makes FineWine the default app for Windows executables, or hands them back to the app
    /// that had them before. macOS has no way to leave a file type with no default, so when
    /// nothing had them before, turning this off can only explain how to pick another app.
    func setOpensWindowsExecutables(_ enabled: Bool) async {
        let defaults = UserDefaults.standard
        var previous = defaults.dictionary(forKey: Self.previousHandlersKey) as? [String: String] ?? [:]
        do {
            if enabled {
                for type in executableTypes {
                    let current = NSWorkspace.shared.urlForApplication(toOpen: type)
                    if let current, !isFineWine(current) { previous[type.identifier] = current.path }
                    try await NSWorkspace.shared.setDefaultApplication(at: Bundle.main.bundleURL, toOpen: type)
                }
                defaults.set(previous, forKey: Self.previousHandlersKey)
            } else {
                var unrestored = false
                for type in executableTypes where isFineWine(NSWorkspace.shared.urlForApplication(toOpen: type)) {
                    if let path = previous[type.identifier], FileManager.default.fileExists(atPath: path) {
                        try await NSWorkspace.shared.setDefaultApplication(at: URL(fileURLWithPath: path), toOpen: type)
                    } else {
                        unrestored = true
                    }
                }
                if unrestored {
                    alert = AppAlert(title: "Choose another app in Finder",
                                     message: "No other app was opening these files before FineWine, so there is nothing to switch back to. To change it, select a .exe file in Finder, choose File > Get Info, pick an app under “Open with”, and click Change All.")
                }
            }
        } catch {
            show(error, title: "The default app couldn't be changed")
        }
        objectWillChange.send()
    }

    // MARK: Login item

    var launchesAtLogin: Bool { SMAppService.mainApp.status == .enabled }

    func setLaunchesAtLogin(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch { show(error, title: "The login setting couldn't be changed") }
        objectWillChange.send()
    }
}

/// Carries a value the compiler can't prove is safe to send across threads. `PrefixService` only
/// reads immutable configuration and talks to the file system, so sharing it is fine.
struct UncheckedBox<T>: @unchecked Sendable {
    let value: T
    init(_ value: T) { self.value = value }
}

/// Lets an exit handler learn the pid of the process it belongs to, which is only known after
/// the handler has been handed over.
final class PIDBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Int32?
    var pid: Int32? {
        get { lock.lock(); defer { lock.unlock() }; return stored }
        set { lock.lock(); stored = newValue; lock.unlock() }
    }
}

enum Panels {
    /// Asks for an installer or other Windows executable.
    @MainActor static func chooseExecutable(in directory: URL? = nil, message: String) -> URL? {
        let panel = NSOpenPanel()
        panel.message = message
        panel.allowedContentTypes = ["exe", "msi", "bat"].compactMap { .init(filenameExtension: $0) }
        panel.allowsOtherFileTypes = true
        panel.canChooseDirectories = false
        panel.directoryURL = directory
        return panel.runModal() == .OK ? panel.url : nil
    }

    enum PrefixChoice {
        case new
        case existing(Prefix)
    }

    /// Asks where a file opened from Finder should run: in a new prefix with the given name
    /// (the first choice, and the one selected), or in one that exists. Returns `nil` on Cancel.
    @MainActor static func choosePrefix(for file: URL, newPrefixName: String, from prefixes: [Prefix],
                                        preselected: UUID?) -> PrefixChoice? {
        let alert = NSAlert()
        alert.messageText = "Run “\(file.lastPathComponent)” with FineWine?"
        alert.informativeText = "Choose the prefix to run it in. Only run programs you trust: they get the same access to your files as FineWine has."
        alert.addButton(withTitle: "Run")
        alert.addButton(withTitle: "Cancel")
        let popup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 320, height: 26), pullsDown: false)
        // Items are added one by one: addItems(withTitles:) drops titles that repeat.
        popup.menu?.addItem(NSMenuItem(title: "New prefix “\(newPrefixName)”", action: nil, keyEquivalent: ""))
        if !prefixes.isEmpty { popup.menu?.addItem(.separator()) }
        for prefix in prefixes {
            let item = NSMenuItem(title: prefix.name, action: nil, keyEquivalent: "")
            item.representedObject = prefix.id
            popup.menu?.addItem(item)
        }
        popup.selectItem(at: 0)
        alert.accessoryView = popup
        NSApp.activate()
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        guard let id = popup.selectedItem?.representedObject as? UUID,
              let prefix = prefixes.first(where: { $0.id == id }) else { return .new }
        return .existing(prefix)
    }

    @MainActor static func chooseFolder(message: String) -> URL? {
        let panel = NSOpenPanel()
        panel.message = message
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.treatsFilePackagesAsDirectories = true
        return panel.runModal() == .OK ? panel.url : nil
    }
}
