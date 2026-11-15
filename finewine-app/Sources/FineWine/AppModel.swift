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
    /// A tab of the prefix view to switch to (`configuration`, …), consumed by that view.
    @Published var requestedSection: String?

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
    private func work<T: Sendable>(on prefixID: UUID?, _ status: String, failure: String,
                                   _ body: @escaping @Sendable (PrefixService) throws -> T) async -> T? {
        if let prefixID { busy[prefixID] = status }
        defer { if let prefixID { busy[prefixID] = nil } }
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
        let created = await work(on: nil, "", failure: "The prefix couldn't be created") {
            try $0.createPrefix(name: name, runtime: runtime, profile: profile, appearance: appearance)
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
        if let applied = await work(on: prefix.id, "Applying settings…", failure: "The settings couldn't be applied", {
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
        if let copy = await work(on: prefix.id, "Duplicating…", failure: "The prefix couldn't be duplicated", {
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

    func wineboot(_ action: WinebootAction, in prefix: Prefix, status: String) async {
        _ = await work(on: prefix.id, status, failure: "Wine reported a problem") {
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

    func launch(_ program: Program, in prefix: Prefix) {
        let box = PIDBox()
        do {
            let pid = try service.launch(programID: program.id, in: prefix, onExit: exitHandler(prefixID: prefix.id, pidBox: box))
            box.pid = pid
            track(pid, in: prefix.id)
        } catch { show(error, title: "“\(program.name)” couldn't be started") }
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
                                       failure: "The appearance couldn't be updated") {
                try $0.applySettings(to: prefix, appearance: appearance)
            }
            if let refreshed { replace(refreshed); current = refreshed }
        }
        launch(tool, in: current)
    }

    func launch(_ tool: WineTool, in prefix: Prefix) {
        let box = PIDBox()
        do {
            let pid = try service.launch(tool: tool, in: prefix, onExit: exitHandler(prefixID: prefix.id, pidBox: box))
            box.pid = pid
            track(pid, in: prefix.id)
        } catch { show(error, title: "\(tool.displayName) couldn't be started") }
    }

    /// Runs an installer, then looks for the programs it added.
    func runInstaller(_ url: URL, in prefix: Prefix) {
        let box = PIDBox()
        let prefixID = prefix.id
        do {
            let pid = try service.launch(executable: url, in: prefix, onExit: exitHandler(prefixID: prefixID, pidBox: box) {
                if let current = AppModel.shared.prefix(prefixID) {
                    AppModel.shared.findInstalledPrograms(in: current, quietly: true)
                }
            })
            box.pid = pid
            track(pid, in: prefix.id)
        } catch { show(error, title: "“\(url.lastPathComponent)” couldn't be started") }
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

    // MARK: Opening files from Finder

    /// Runs a Windows executable or installer opened from Finder: straight away when it lives
    /// in a prefix, otherwise after asking which prefix to use.
    func open(executable url: URL) {
        reload()
        switch WindowsExecutable.route(for: url, prefixes: prefixes) {
        case .unsupported:
            alert = AppAlert(title: "FineWine can't open “\(url.lastPathComponent)”",
                             message: "It opens Windows programs and installers (.exe and .msi files).")
            openMainWindow()
        case .needsPrefix:
            alert = AppAlert(title: "Create a prefix first",
                             message: "“\(url.lastPathComponent)” needs a prefix to run in. Create one, then open the file again.")
            openMainWindow()
        case .run(let prefix):
            runInstaller(url, in: prefix)
            if alert != nil { openMainWindow() }
        case .choose(let candidates):
            guard let prefix = Panels.choosePrefix(for: url, from: candidates, preselected: selection) else { return }
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

    /// Asks which prefix a file opened from Finder should run in. Returns `nil` on Cancel.
    @MainActor static func choosePrefix(for file: URL, from prefixes: [Prefix], preselected: UUID?) -> Prefix? {
        let alert = NSAlert()
        alert.messageText = "Run “\(file.lastPathComponent)” with FineWine?"
        alert.informativeText = "Choose the prefix to run it in. Only run programs you trust: they get the same access to your files as FineWine has."
        alert.addButton(withTitle: "Run")
        alert.addButton(withTitle: "Cancel")
        let popup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 280, height: 26), pullsDown: false)
        popup.addItems(withTitles: prefixes.map(\.name))
        if let index = prefixes.firstIndex(where: { $0.id == preselected }) { popup.selectItem(at: index) }
        alert.accessoryView = popup
        NSApp.activate()
        guard alert.runModal() == .alertFirstButtonReturn,
              prefixes.indices.contains(popup.indexOfSelectedItem) else { return nil }
        return prefixes[popup.indexOfSelectedItem]
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
