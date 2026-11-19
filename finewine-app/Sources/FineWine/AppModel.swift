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
    /// Every drive FineWine keeps prefixes on, plugged in or not.
    @Published var drives: [PrefixDrive] = []
    /// The UUIDs of the drives among them that are plugged in now.
    @Published var connectedDrives: Set<String> = []
    @Published var runtimes: [WineRuntime] = []
    @Published var profiles: [GameProfile] = []
    @Published var selection: UUID?
    /// Live process ids started from FineWine, per prefix.
    @Published var running: [UUID: Set<Int32>] = [:]
    /// The prefixes that have processes right now, however they were started: a launcher
    /// FineWine started ends once it has started the game, and programs are also started from
    /// their Mac apps or were running before FineWine was opened. Looked up every few seconds.
    @Published var alive: Set<UUID> = []
    /// MetalFX upscaling as it was switched from FineWine's menu while a prefix runs; a
    /// prefix that is not here goes by its settings. Forgotten when the prefix stops.
    @Published var liveUpscaling: [UUID: Bool] = [:]
    /// The space each prefix takes on its drive, in bytes, once it has been measured. Walking
    /// a prefix with a large game in it takes a few seconds, so it is done in the background,
    /// one prefix at a time, and again only after a while.
    @Published var prefixSizes: [UUID: Int64] = [:]
    private var sizesMeasuredAt: [UUID: Date] = [:]
    private var sizeMeasuringUnderWay = false
    private var aliveTimer: Timer?
    private var aliveLookupUnderWay = false
    /// What a prefix is busy with ("Setting up…"), shown in place of its controls.
    @Published var busy: [UUID: String] = [:]
    /// Copies under way (a move, snapshot or restore), by prefix, so they can be cancelled.
    @Published var copies: [UUID: CopyProgress] = [:]
    /// Every snapshot on this Mac and on the drives plugged in, newest first.
    @Published var snapshots: [PrefixSnapshot] = []
    @Published var alert: AppAlert?
    @Published var isCreatingPrefix = false
    /// The prefix being made for a file opened from Finder, shown while it is set up.
    @Published var settingUpPrefixName: String?
    /// A tab of the prefix view to switch to (`configuration`, …), consumed by that view.
    @Published var requestedSection: String?

    /// What Discord was last told, for the settings to show.
    @Published var discordState: DiscordConnection.State = .idle
    /// The program last started in each prefix, and when: what "is being played" there.
    private var playing: [UUID: (name: String, since: Date)] = [:]
    private var discordTimer: Timer?
    private lazy var discord = DiscordConnection { state in
        Task { @MainActor in AppModel.shared.discordState = state }
    }

    /// True once a file or link has been handed to FineWine to open. A first run that starts
    /// that way does not show the manager window.
    var wasAskedToOpenSomething = false

    /// Set by the menu bar label, which is the one view that always exists.
    var openMainWindow: () -> Void = {}

    init(service: PrefixService = PrefixService(paths: .standard())) {
        self.service = service
        try? service.paths.ensureDirectories()
        reload()
        watchDrives()
    }

    // MARK: Drives

    /// Reloads when drives are plugged in, ejected or renamed. A drive FineWine has used comes
    /// back with its prefixes ready to run, and says so.
    private func watchDrives() {
        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(forName: NSWorkspace.didMountNotification, object: nil, queue: .main) { note in
            let root = note.userInfo?[NSWorkspace.volumeURLUserInfoKey] as? URL
            Task { @MainActor in AppModel.shared.driveMounted(at: root) }
        }
        for name in [NSWorkspace.didUnmountNotification, NSWorkspace.didRenameVolumeNotification] {
            center.addObserver(forName: name, object: nil, queue: .main) { _ in
                Task { @MainActor in AppModel.shared.reload() }
            }
        }
    }

    private func driveMounted(at root: URL?) {
        let before = Set(prefixes.map(\.id))
        reload()
        let arrived = prefixes.filter { !before.contains($0.id) }
        guard !arrived.isEmpty else { return }
        let drive = arrived.first.map { placeName($0.place) } ?? root?.lastPathComponent ?? ""
        let names = arrived.map(\.name).joined(separator: ", ")
        if let token = StatusSplash.shared.show(title: tr("drive.connected_title", drive), message: tr("drive.connected_msg", names)) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { StatusSplash.shared.hide(token) }
        }
    }

    /// Show prefixes on drives that are not plugged in (greyed out, saying which drive to
    /// connect), or leave them out until the drive is back.
    static let showDisconnectedKey = "ShowPrefixesOnDisconnectedDrives"
    var showsDisconnectedPrefixes: Bool {
        get { UserDefaults.standard.object(forKey: Self.showDisconnectedKey) as? Bool ?? true }
        set {
            objectWillChange.send()
            UserDefaults.standard.set(newValue, forKey: Self.showDisconnectedKey)
        }
    }

    /// Prefixes on drives that are not plugged in, as FineWine last saw them.
    var disconnectedPrefixes: [(drive: PrefixDrive, prefix: KnownPrefix)] {
        drives.filter { !connectedDrives.contains($0.uuid) }
            .flatMap { drive in drive.prefixes.map { (drive, $0) } }
            .sorted { $0.prefix.name.localizedStandardCompare($1.prefix.name) == .orderedAscending }
    }

    /// "This Mac", or the drive's name.
    func placeName(_ place: PrefixPlace) -> String {
        switch place {
        case .thisMac: return tr("drive.this_mac")
        case .drive(let uuid): return drives.first { $0.uuid == uuid }?.name ?? tr("drive.unknown")
        }
    }

    func placeSymbol(_ place: PrefixPlace) -> String {
        if case .drive = place { return "externaldrive" }
        return "desktopcomputer"
    }

    /// Where new prefixes go, as the user set it (the default drive may be unplugged).
    var preferredPlace: PrefixPlace { service.prefixes.drives.preferredPlace }

    /// Drives a prefix could be put on now, each with the reason it can't, if it can't.
    func candidateVolumes() -> [(volume: VolumeInfo, problem: String?)] { service.prefixes.drives.candidateVolumes() }

    /// Gets a drive ready for prefixes (`FineWine/Prefixes` on it) and remembers it.
    func useDrive(_ volume: VolumeInfo) -> PrefixPlace? {
        do {
            let place = try service.prefixes.drives.use(volume)
            reload()
            return place
        } catch {
            show(error, title: tr("drive.err_title"))
            return nil
        }
    }

    func setDefaultPlace(_ place: PrefixPlace) {
        do { try service.prefixes.drives.setDefault(place) } catch { show(error, title: tr("drive.err_title")) }
        objectWillChange.send()
    }

    /// Forgets a drive. Its prefixes stay on it, and come back if it is plugged in again.
    func forgetDrive(_ uuid: String) {
        do { try service.prefixes.drives.forget(uuid) } catch { show(error, title: tr("drive.err_title")) }
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
        defer { watchRunningPrefixes(); measurePrefixSizes() }
        service.prefixes.refreshDrives()
        prefixes = service.prefixes.list()
        drives = service.prefixes.drives.drives
        connectedDrives = Set(drives.map(\.uuid).filter { service.prefixes.drives.mountedVolume($0) != nil })
        runtimes = service.runtimes.list()
        profiles = service.profiles.list()
        snapshots = service.prefixes.snapshots()
        if selection == nil || !prefixes.contains(where: { $0.id == selection }) {
            selection = prefixes.first?.id
        }
        repairShortcutIcons()
    }

    /// Shortcut apps made before 2026-11-17 have icons macOS draws as noise at small sizes
    /// (`ICNS.hasMisreadSlots`). Each is made again, once, with an icon it reads correctly.
    private func repairShortcutIcons() {
        for prefix in prefixes {
            for program in prefix.metadata.programs {
                guard let path = program.shortcutPath else { continue }
                let icon = URL(fileURLWithPath: path).appendingPathComponent("Contents/Resources/AppIcon.icns")
                guard ICNS.hasMisreadSlots(at: icon), let current = self.prefix(prefix.id) else { continue }
                createShortcut(for: program.id, in: current)
            }
        }
    }

    var usableRuntimes: [WineRuntime] { runtimes.filter(\.isUsable) }

    func prefix(_ id: UUID?) -> Prefix? { prefixes.first { $0.id == id } }
    func runtime(for prefix: Prefix) -> WineRuntime? { runtimes.first { $0.id == prefix.metadata.runtimeID } }
    func profile(for prefix: Prefix) -> GameProfile? { profiles.first { $0.id == prefix.metadata.profileID } }
    func isRunning(_ prefix: Prefix) -> Bool { !(running[prefix.id] ?? []).isEmpty || alive.contains(prefix.id) }

    /// Whether MetalFX upscaling is on in a prefix's running programs, as far as FineWine
    /// knows: what its menu last switched it to, else how the prefix starts programs. (A
    /// program's own View menu can switch it too; that is not followed here.)
    func isUpscalingOn(_ prefix: Prefix) -> Bool {
        liveUpscaling[prefix.id] ?? prefix.metadata.settings.upscalesAtStart
    }

    /// Switches MetalFX upscaling in everything the prefix is running, without restarting it.
    func toggleUpscaling(_ prefix: Prefix) {
        let on = !isUpscalingOn(prefix)
        liveUpscaling[prefix.id] = on
        let service = UncheckedBox(service)
        Task.detached(priority: .userInitiated) {
            LiveUpscaling.set(on, processIDs: service.value.findProcesses(prefix.directory))
        }
    }

    /// A prefix's size as text ("12.4 GB"), nil until it has been measured.
    func sizeText(for prefix: Prefix) -> String? {
        prefixSizes[prefix.id].map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) }
    }

    /// Measures the prefixes that have not been measured in the last `maxAge` seconds (all of
    /// them with 0). Links are not followed: a prefix's z: drive points at the whole Mac.
    func measurePrefixSizes(maxAge: TimeInterval = 300) {
        guard !sizeMeasuringUnderWay else { return }
        let now = Date()
        let due = prefixes.filter { prefix in
            guard let last = sizesMeasuredAt[prefix.id] else { return true }
            return now.timeIntervalSince(last) >= maxAge
        }
        for id in prefixSizes.keys where !prefixes.contains(where: { $0.id == id }) {
            prefixSizes[id] = nil
            sizesMeasuredAt[id] = nil
        }
        guard !due.isEmpty else { return }
        sizeMeasuringUnderWay = true
        Task { @MainActor in
            for prefix in due {
                let folder = prefix.directory
                let bytes = await Task.detached(priority: .utility) { FolderCopy.measure(folder).allocated }.value
                // a prefix that was deleted or unplugged meanwhile measures as nothing
                if FileManager.default.fileExists(atPath: folder.path) { prefixSizes[prefix.id] = bytes }
                sizesMeasuredAt[prefix.id] = Date()
            }
            sizeMeasuringUnderWay = false
        }
    }

    /// Whether anything is running in any prefix, however it was started.
    var hasRunningPrograms: Bool { !alive.isEmpty || runningCount > 0 }

    /// Closes everything in every prefix, as quitting FineWine does, so that the app (and the
    /// Wine runtime inside it, which the programs run from) can be replaced by an update.
    func closeEverythingForUpdate() async {
        let all = prefixes
        let service = UncheckedBox(service)
        await Task.detached(priority: .userInitiated) {
            let running = all.filter { !service.value.findProcesses($0.directory).isEmpty }
            if !running.isEmpty { service.value.closeEverything(in: running) }
        }.value
        running = [:]
        alive = []
    }

    /// Starts looking, every few seconds, for which prefixes have processes.
    func watchRunningPrefixes() {
        guard aliveTimer == nil else { return }
        let timer = Timer(timeInterval: 4, repeats: true) { _ in
            Task { @MainActor in AppModel.shared.refreshAlive() }
        }
        RunLoop.main.add(timer, forMode: .common)
        aliveTimer = timer
        refreshAlive()
    }

    /// Looks once for which prefixes have processes. The looking runs `lsof` and `ps`, so it
    /// is done off the main thread, and never twice at the same time.
    func refreshAlive() {
        guard !aliveLookupUnderWay else { return }
        aliveLookupUnderWay = true
        let all = prefixes
        let service = UncheckedBox(service)
        Task { @MainActor in
            let switched = liveUpscaling
            let found = await Task.detached(priority: .utility) { () -> Set<UUID> in
                var found: Set<UUID> = []
                for prefix in all {
                    let pids = service.value.findProcesses(prefix.directory)
                    guard !pids.isEmpty else { continue }
                    found.insert(prefix.id)
                    // programs started since the switch was thrown are told as well
                    if let on = switched[prefix.id] { LiveUpscaling.set(on, processIDs: pids) }
                }
                return found
            }.value
            aliveLookupUnderWay = false
            if found != alive { alive = found }
            for id in liveUpscaling.keys where !found.contains(id) { liveUpscaling[id] = nil }
        }
    }
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

    func createPrefix(name: String, runtime: WineRuntime, profile: GameProfile?, place: PrefixPlace? = nil) async -> Bool {
        let place = place ?? service.prefixes.drives.defaultPlace
        isCreatingPrefix = true
        defer { isCreatingPrefix = false }
        let appearance = currentAppearance
        let token = StatusSplash.shared.show(title: tr("splash.setting_up", name), message: tr("splash.creating_prefix"))
        defer { StatusSplash.shared.hide(token) }
        let created = await work(on: nil, "", failure: tr("dialog.err_prefix_create")) {
            try $0.createPrefix(name: name, runtime: runtime, profile: profile, place: place, appearance: appearance) { stage in
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
        do { try service.prefixes.save(updated) } catch { return show(error, title: tr("dialog.err_settings_save")) }
        replace(updated)
        let toApply = updated
        let appearance = currentAppearance
        if let applied = await work(on: prefix.id, tr("splash.applying_settings"), failure: tr("dialog.err_settings_apply"), splash: true, {
            try $0.applySettings(to: toApply, appearance: appearance)
        }) {
            replace(applied)
        }
    }

    func rename(_ prefix: Prefix, to name: String) {
        do { replace(try service.prefixes.rename(prefix, to: name)); reload() }
        catch { show(error, title: tr("dialog.err_prefix_rename")) }
    }

    func duplicate(_ prefix: Prefix) async {
        let name = prefix.name + " copy"
        if let copy = await work(on: prefix.id, tr("splash.duplicating"), failure: tr("dialog.err_prefix_duplicate"), splash: true, {
            try $0.prefixes.duplicate(prefix, as: name)
        }) {
            reload()
            selection = copy.id
        }
    }

    func delete(_ prefix: Prefix) async {
        _ = await work(on: prefix.id, tr("splash.deleting"), failure: tr("dialog.err_prefix_delete")) {
            try $0.deletePrefix(prefix)
        }
        running[prefix.id] = nil
        alive.remove(prefix.id)
        refreshAlive()
        reload()
    }

    func stopAll(in prefix: Prefix) async {
        _ = await work(on: prefix.id, tr("splash.stopping"), failure: tr("dialog.err_programs_stop")) {
            try $0.stopAll(in: prefix)
        }
        running[prefix.id] = nil
        alive.remove(prefix.id)
        refreshAlive()
    }

    /// Asks every program in the prefix to close, as shutting Windows down does.
    func shutDown(_ prefix: Prefix) async {
        _ = await work(on: prefix.id, tr("splash.shutting_down"), failure: tr("dialog.err_prefix_shutdown")) {
            try $0.shutDown(prefix)
        }
        running[prefix.id] = nil
        alive.remove(prefix.id)
        refreshAlive()
    }

    /// Ends everything in the prefix at once, frozen programs included.
    func forceShutDown(_ prefix: Prefix) async {
        _ = await work(on: prefix.id, tr("splash.forcing_shut_down"), failure: tr("dialog.err_prefix_force_shutdown")) {
            try $0.forceShutDown(prefix)
        }
        running[prefix.id] = nil
        alive.remove(prefix.id)
        refreshAlive()
    }

    // MARK: Discord

    private static let discordEnabledKey = "DiscordPresence"
    private static let discordApplicationKey = "DiscordApplicationID"

    /// Whether the game being played is shown as the user's Discord activity. Off until the
    /// user turns it on: it tells other people what they are doing.
    var showsDiscordPresence: Bool {
        get { UserDefaults.standard.bool(forKey: Self.discordEnabledKey) }
        set {
            objectWillChange.send()
            UserDefaults.standard.set(newValue, forKey: Self.discordEnabledKey)
            refreshDiscord()
        }
    }

    /// FineWine's own Discord application (its name and icon are what Discord shows).
    static let builtInDiscordApplicationID = "1572416361274015815"

    /// The id of the Discord application the activity is filed under: the user's own if they
    /// entered one in Settings, else FineWine's.
    var discordApplicationID: String {
        let custom = customDiscordApplicationID
        return custom.isEmpty ? Self.builtInDiscordApplicationID : custom
    }

    /// An application id the user entered instead of FineWine's; empty for FineWine's.
    var customDiscordApplicationID: String {
        get { UserDefaults.standard.string(forKey: Self.discordApplicationKey) ?? "" }
        set {
            objectWillChange.send()
            UserDefaults.standard.set(newValue.filter(\.isNumber), forKey: Self.discordApplicationKey)
            refreshDiscord()
        }
    }

    /// A program was started from FineWine: it is what is being played in its prefix until
    /// nothing runs there any more.
    private func notePlaying(_ program: Program, in prefix: Prefix) {
        playing[prefix.id] = (program.name, Date())
        refreshDiscord()
        guard discordTimer == nil else { return }
        let timer = Timer(timeInterval: 15, repeats: true) { _ in
            Task { @MainActor in AppModel.shared.refreshDiscord() }
        }
        RunLoop.main.add(timer, forMode: .common)
        discordTimer = timer
    }

    /// Works out what is being played now and tells Discord, or clears the activity.
    func refreshDiscord() {
        guard showsDiscordPresence, !discordApplicationID.isEmpty, !playing.isEmpty else {
            discord.show(game: nil, since: nil, others: 0, applicationID: "")
            if playing.isEmpty { discordTimer?.invalidate(); discordTimer = nil }
            if !showsDiscordPresence || discordApplicationID.isEmpty { discordState = .idle }
            return
        }
        let sessions = playing
        let known = prefixes
        let service = UncheckedBox(service)
        let applicationID = discordApplicationID
        Task { @MainActor in
            // Which sessions still have something running, and what: a launcher may have
            // started the game and gone.
            let current = await Task.detached(priority: .utility) { () -> [(id: UUID, game: String, since: Date)] in
                sessions.compactMap { id, session in
                    guard let prefix = known.first(where: { $0.id == id }) else { return nil }
                    let running = service.value.runningProgramNames(in: prefix)
                    // a program takes a while to appear after it is started
                    if running.isEmpty { return Date().timeIntervalSince(session.since) < 60 ? (id, session.name, session.since) : nil }
                    guard let game = DiscordPresence.game(started: session.name, running: running,
                                                          listed: prefix.metadata.programs.map(\.name)) else { return nil }
                    return (id, game, session.since)
                }
            }.value
            for id in sessions.keys where !current.contains(where: { $0.id == id }) {
                // only forget a session nobody restarted meanwhile
                if playing[id]?.since == sessions[id]?.since { playing[id] = nil }
            }
            guard let latest = current.max(by: { $0.since < $1.since }) else {
                discord.show(game: nil, since: nil, others: 0, applicationID: "")
                discordTimer?.invalidate(); discordTimer = nil
                return
            }
            discord.show(game: latest.game, since: latest.since, others: current.count - 1, applicationID: applicationID)
        }
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
        alert.messageText = count == 1 ? tr("dialog.quit_title_single")
                                       : tr("dialog.quit_title_multiple", count)
        let list = runningNow.map { prefix, names in
            names.count == 1 && names[0] == prefix.name ? "•  \(prefix.name)"
                                                        : "•  \(prefix.name): " + names.joined(separator: ", ")
        }.joined(separator: "\n")
        alert.informativeText = tr("dialog.quit_info", list)
        alert.addButton(withTitle: tr("dialog.close_and_quit"))
        alert.addButton(withTitle: tr("app.cancel"))
        NSApp.activate()
        guard alert.runModal() == .alertFirstButtonReturn else { return false }

        let token = StatusSplash.shared.show(title: tr("splash.quitting_title"),
                                             message: count == 1 ? tr("splash.closing_single") : tr("splash.closing_multiple", count))
        let toClose = runningNow.map(\.0)
        _ = await Task.detached(priority: .userInitiated) {
            service.value.closeEverything(in: toClose, grace: 5).map(\.id)
        }.value
        StatusSplash.shared.hide(token)
        running.removeAll()
        return true
    }

    func wineboot(_ action: WinebootAction, in prefix: Prefix, status: String) async {
        _ = await work(on: prefix.id, status, failure: tr("dialog.wine_problem"), splash: true) {
            try $0.runWineboot(action, in: prefix)
        }
    }

    // MARK: Programs and shortcuts

    func addProgram(_ program: Program, to prefix: Prefix) {
        do { replace(try service.addProgram(program, to: prefix)) }
        catch { show(error, title: tr("dialog.err_prog_add")) }
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
        } catch { show(error, title: tr("dialog.err_prog_save")) }
    }

    func removeProgram(_ program: Program, from prefix: Prefix) {
        do { replace(try service.removeProgram(id: program.id, from: prefix)) }
        catch { show(error, title: tr("dialog.err_prog_remove")) }
    }

    @discardableResult
    func findInstalledPrograms(in prefix: Prefix, quietly: Bool = false) -> Int {
        do {
            let result = try service.importDiscoveredPrograms(into: prefix)
            replace(result.prefix)
            if !quietly, result.added == 0 {
                alert = AppAlert(title: tr("dialog.no_new_programs_title"),
                                 message: tr("dialog.no_new_programs_msg"))
            }
            return result.added
        } catch {
            show(error, title: tr("dialog.err_prefix_search"))
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
        } catch { show(error, title: tr("dialog.err_shortcut_make")) }
    }

    func removeShortcut(for programID: UUID, in prefix: Prefix) {
        do { replace(try service.removeShortcut(for: programID, in: prefix)) }
        catch { show(error, title: tr("dialog.err_shortcut_remove")) }
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
        return StatusSplash.shared.showLaunch(title: tr("splash.starting_program", name), icon: icon, updatingPrefix: updating)
    }

    func launch(_ program: Program, in prefix: Prefix, memoryTrace: Bool = false) {
        let box = PIDBox()
        let prefixID = prefix.id
        // The icon of the program's shortcut app, when it has one: that is the program's own.
        let icon = program.shortcutPath.flatMap { FileManager.default.fileExists(atPath: $0) ? NSWorkspace.shared.icon(forFile: $0) : nil }
        let status = startingStatus(program.name, icon: icon, in: prefix)
        do {
            let pid = try service.launch(programID: program.id, in: prefix, memoryTrace: memoryTrace, onExit: exitHandler(prefixID: prefix.id, pidBox: box) {
                StatusSplash.shared.hide(status)
                AppModel.shared.adoptNewPrograms(in: prefixID)
            })
            box.pid = pid
            track(pid, in: prefix.id)
            notePlaying(program, in: prefix)
        } catch {
            StatusSplash.shared.hide(status)
            show(error, title: tr("dialog.err_prog_start", program.name))
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
            let refreshed = await work(on: prefix.id, tr("splash.matching_appearance"),
                                       failure: tr("dialog.err_appearance_update"), splash: true) {
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
            show(error, title: tr("dialog.err_prog_start", tool.displayName))
        }
    }

    /// Runs an installer, then looks for the programs it added.
    func runInstaller(_ url: URL, in prefix: Prefix) {
        if WindowsExecutable.is32BitProgram(url) { return install32Bit(url, in: prefix) }
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
            show(error, title: tr("dialog.err_prog_start", url.lastPathComponent))
        }
    }

    /// A 32-bit program cannot run in FineWine's runtime. Most installers are 32-bit all the
    /// same, whatever they install; one made with NSIS is carried out by FineWine itself, from
    /// the script inside it. Anything else is explained to the user.
    private func install32Bit(_ url: URL, in prefix: Prefix) {
        let name = url.deletingPathExtension().lastPathComponent
        guard NSISArchive.isNSISInstaller(url) else {
            alert = AppAlert(title: tr("dialog.32bit_title", url.lastPathComponent),
                             message: tr("dialog.32bit_msg"))
            openMainWindow()
            return
        }
        let prefixID = prefix.id
        Task { @MainActor in
            busy[prefixID] = tr("splash.installing")
            let token = StatusSplash.shared.show(title: tr("splash.installing_program", prefix.name),
                                                 message: tr("splash.reading_installer"))
            let service = UncheckedBox(service)
            let outcome: Result<(prefix: Prefix, report: NSISInstallReport), Error> = await Task.detached(priority: .userInitiated) {
                Result { try service.value.installNSIS(url, in: prefix) { stage in
                    Task { @MainActor in StatusSplash.shared.update(token, message: stage) }
                } }
            }.value
            busy[prefixID] = nil
            switch outcome {
            case .failure(let error):
                StatusSplash.shared.hide(token)
                alert = AppAlert(title: tr("dialog.32bit_install_failed_title", name),
                                 message: tr("dialog.32bit_install_failed_msg", error.localizedDescription))
                openMainWindow()
            case .success(let result):
                let before = Set(prefix.metadata.programs.map(\.id))
                replace(result.prefix)
                let added = result.prefix.metadata.programs.filter { !before.contains($0.id) }
                nameAfterInstalledPrograms(prefixID, added: added)
                for program in added {
                    if let current = self.prefix(prefixID) { createShortcut(for: program.id, in: current) }
                }
                let installed = self.prefix(prefixID)?.name ?? prefix.name
                StatusSplash.shared.update(token, message: added.isEmpty
                    ? tr("splash.installed_no_programs")
                    : tr("splash.installed_success"))
                StatusSplash.shared.retitle(token, tr("splash.installed_title", installed))
                try? await Task.sleep(nanoseconds: 4_000_000_000)
                StatusSplash.shared.hide(token)
                if added.isEmpty { show(prefixID: prefixID) }
            }
        }
    }

    /// Handles a `finewine://` link from a shortcut app.
    func handle(_ url: URL) {
        guard let link = LaunchURL(url: url) else { return }
        reload()
        switch link {
        case .launch(let prefixID, let programID):
            guard let prefix = prefix(prefixID), let program = prefix.program(id: programID) else {
                // A prefix on a drive that is unplugged: say which drive to connect.
                if let away = disconnectedPrefixes.first(where: { $0.prefix.id == prefixID }) {
                    alert = AppAlert(title: tr("drive.not_connected_title", away.drive.name),
                                     message: tr("drive.not_connected_msg", away.prefix.name, away.drive.name))
                    openMainWindow()
                    return
                }
                alert = AppAlert(title: tr("dialog.dead_shortcut_title"),
                                 message: tr("dialog.dead_shortcut_msg"))
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
        } catch { show(error, title: tr("dialog.err_runtime_add")) }
    }

    func remove(_ runtime: WineRuntime) {
        do {
            switch runtime.kind {
            case .managed: try service.runtimes.removeManaged(id: runtime.id)
            case .external: try service.runtimes.removeExternal(runtime.root)
            case .bundled: break   // part of the app; the list offers no way to remove it
            }
            reload()
        } catch { show(error, title: tr("dialog.err_runtime_remove")) }
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
            alert = AppAlert(title: tr("dialog.cant_open_title", url.lastPathComponent),
                             message: tr("dialog.cant_open_msg"))
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
            alert = AppAlert(title: tr("dialog.no_runtime_title"),
                             message: tr("dialog.no_runtime_msg", url.lastPathComponent))
            openMainWindow()
            return
        }
        pendingPrefixNames.append(name)
        Task { @MainActor in
            settingUpPrefixName = name
            // A game this app has a profile for (the GRYPHLINK installer: Arknights: Endfield)
            // gets that profile's settings.
            let created = await createPrefix(name: name, runtime: runtime,
                                             profile: GameProfile.forInstaller(url, among: profiles))
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
                    alert = AppAlert(title: tr("dialog.choose_another_app_title"),
                                     message: tr("dialog.choose_another_app_msg"))
                }
            }
        } catch {
            show(error, title: tr("dialog.err_default_app"))
        }
        objectWillChange.send()
    }

    // MARK: Login item

    var launchesAtLogin: Bool { SMAppService.mainApp.status == .enabled }

    func setLaunchesAtLogin(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch { show(error, title: tr("dialog.err_login_setting")) }
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
    /// Asks for a name in a small dialog. Nil when cancelled or left empty.
    @MainActor static func askForName(title: String, current: String) -> String? {
        let alert = NSAlert()
        alert.messageText = title
        let field = NSTextField(string: current)
        field.frame = NSRect(x: 0, y: 0, width: 260, height: 24)
        alert.accessoryView = field
        alert.addButton(withTitle: tr("app.rename"))
        alert.addButton(withTitle: tr("app.cancel"))
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty || name == current ? nil : name
    }

    /// Asks before something that cannot be undone.
    @MainActor static func confirm(title: String, message: String, action: String) -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: action).hasDestructiveAction = true
        alert.addButton(withTitle: tr("app.cancel"))
        return alert.runModal() == .alertFirstButtonReturn
    }

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
        alert.messageText = tr("dialog.run_with_finewine_title", file.lastPathComponent)
        alert.informativeText = tr("dialog.run_with_finewine_msg")
        alert.addButton(withTitle: tr("dialog.run_btn"))
        alert.addButton(withTitle: tr("app.cancel"))
        let popup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 320, height: 26), pullsDown: false)
        // Items are added one by one: addItems(withTitles:) drops titles that repeat.
        popup.menu?.addItem(NSMenuItem(title: tr("dialog.new_prefix_popup", newPrefixName), action: nil, keyEquivalent: ""))
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
