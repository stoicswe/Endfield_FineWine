import Foundation

/// The operations the app performs on prefixes, combining the stores, the launch planner and a
/// process runner. Calls that run Wine block until it finishes, so the app makes them off the
/// main thread.
public struct PrefixService {
    /// How processes are listed and killed for `forceShutDown`. Replaced in tests.
    public var findProcesses: @Sendable (URL) -> [Int32] = { PrefixProcesses.systemPIDs(prefixDirectory: $0) }
    public var killProcess: @Sendable (Int32) -> Void = { _ = kill($0, SIGKILL) }
    public var commandsOfProcesses: @Sendable ([Int32]) -> [String] = { RunningPrograms.systemCommands(of: $0) }

    public let paths: FineWinePaths
    public let prefixes: PrefixStore
    public let runtimes: RuntimeStore
    public let profiles: ProfileStore
    public let shortcuts: ShortcutAppBuilder
    public let runner: ProcessRunning

    public init(paths: FineWinePaths, runner: ProcessRunning = SystemProcessRunner(), runtimes: RuntimeStore? = nil,
                volumes: VolumeProviding = SystemVolumes()) {
        self.paths = paths
        self.prefixes = PrefixStore(paths: paths, volumes: volumes)
        self.runtimes = runtimes ?? RuntimeStore(paths: paths)
        self.profiles = ProfileStore(paths: paths)
        self.shortcuts = ShortcutAppBuilder(directory: paths.shortcuts)
        self.runner = runner
    }

    // MARK: Planning

    public func runtime(for prefix: Prefix) throws -> WineRuntime {
        // A prefix with no runtime, or whose runtime is gone, uses the one built into the app.
        let chosen = prefix.metadata.runtimeID.flatMap { runtimes.runtime(id: $0) }
        guard let runtime = chosen ?? runtimes.bundled else {
            throw FineWineError(prefix.metadata.runtimeID == nil
                ? "“\(prefix.name)” has no runtime chosen. Pick one in its settings."
                : "The runtime “\(prefix.name)” uses is no longer installed. Pick another in its settings.")
        }
        let problems = runtime.problems()
        guard problems.isEmpty else {
            throw FineWineError("The runtime “\(runtime.name)” can't be used: " + problems.joined(separator: " "))
        }
        return runtime
    }

    public func planner(for prefix: Prefix) throws -> LaunchPlanner {
        LaunchPlanner(runtime: try runtime(for: prefix), prefix: prefix,
                      profile: profiles.profile(id: prefix.metadata.profileID))
    }

    func runChecked(_ plan: LaunchPlan, what: String) throws {
        let result = try runner.run(plan)
        guard result.status == 0 else {
            let tail = result.output.split(separator: "\n").suffix(6).joined(separator: "\n")
            throw FineWineError("\(what) failed (exit status \(result.status))." + (tail.isEmpty ? "" : "\n\(tail)"))
        }
    }

    // MARK: Prefix lifecycle

    /// Creates a prefix, has Wine set it up, and applies its settings. If Wine fails, the
    /// half-made prefix is removed so the name can be used again.
    public func createPrefix(name: String, runtime: WineRuntime, profile: GameProfile?,
                             place: PrefixPlace = .thisMac,
                             appearance: MacAppearance? = nil,
                             progress: (@Sendable (String) -> Void)? = nil) throws -> Prefix {
        let problems = runtime.problems()
        guard problems.isEmpty else {
            throw FineWineError("The runtime “\(runtime.name)” can't be used: " + problems.joined(separator: " "))
        }
        let prefix = try prefixes.create(name: name, runtimeID: runtime.id, profile: profile, place: place)
        do {
            progress?(tr("setup.creating_windows_env"))
            try runChecked(try planner(for: prefix).plan(for: .initialize), what: "Setting up the prefix")
            keepDesktopInPrefix(prefix)
            progress?(tr("setup.applying_settings"))
            return try applySettings(to: prefix, appearance: appearance)
        } catch {
            try? prefixes.delete(prefix)
            throw error
        }
    }

    /// Writes the prefix's settings into its registry and records them as applied.
    /// `appearance` is the Mac's current look, used when the prefix has macOS styling on.
    @discardableResult
    public func applySettings(to prefix: Prefix, appearance: MacAppearance? = nil) throws -> Prefix {
        let problems = prefix.metadata.settings.validationProblems()
        guard problems.isEmpty else { throw FineWineError(problems.joined(separator: "\n")) }

        let edits = prefix.metadata.settings.registryEdits(replacing: prefix.metadata.appliedSettings,
                                                           appearance: appearance,
                                                           displayScale: appearance?.displayScale ?? 2)
        // A prefix's server and its programs must agree on how synchronisation is done: a
        // program started with MSync cannot join a server started without it, and fails to
        // start. Changing the mode therefore stops whatever is still running in the prefix.
        if let applied = prefix.metadata.appliedSettings, applied.syncMode != prefix.metadata.settings.syncMode,
           let stop = try? planner(for: prefix).killPlan() {
            _ = try? runner.run(stop)
        }

        let file = prefix.directory.appendingPathComponent(".finewine-settings.reg")
        try RegistryFile.data(edits).write(to: file, options: .atomic)
        defer { try? FileManager.default.removeItem(at: file) }
        try runChecked(try planner(for: prefix).plan(importingRegistryFile: file), what: "Applying the settings")

        var updated = prefix
        updated.metadata.appliedSettings = prefix.metadata.settings
        // Recorded whenever it was used: for the styling, or for the automatic DPI.
        if let appearance { updated.metadata.appliedAppearance = appearance }
        try prefixes.save(updated)
        return updated
    }

    /// Whether the prefix's styling or automatic DPI was written for a different Mac appearance
    /// or display scale than the current one, and should be applied again.
    public func needsAppearanceRefresh(_ prefix: Prefix, current: MacAppearance) -> Bool {
        let settings = prefix.metadata.settings
        guard let applied = prefix.metadata.appliedAppearance else {
            return settings.macAppearance || (settings.automaticDPI && settings.retinaMode)
        }
        if settings.macAppearance {
            var a = applied, b = current
            a.displayScale = 1; b.displayScale = 1
            if a != b { return true }
        }
        // Moved to a display with a different scale: the automatic DPI is out of date.
        return settings.automaticDPI && settings.retinaMode && applied.displayScale != current.displayScale
    }

    /// Stops the prefix's processes, removes its shortcut apps, then deletes it.
    public func deletePrefix(_ prefix: Prefix) throws {
        if let plan = try? planner(for: prefix).killPlan() { _ = try? runner.run(plan) }
        try shortcuts.removeAll(prefixID: prefix.id)
        try prefixes.delete(prefix)
    }

    public func stopAll(in prefix: Prefix) throws {
        _ = try runner.run(try planner(for: prefix).killPlan())
    }

    /// Shuts the prefix down the way Windows shuts down: every program is asked to close
    /// (and may ask to save), then Wine's own processes end. Returns once that has been
    /// started; a program that does not answer is not waited for. See `forceShutDown`.
    public func shutDown(_ prefix: Prefix) throws {
        _ = try runner.start(try planner(for: prefix).plan(for: .shutdown),
                             logFile: logFile(for: prefix, name: "Shut down"), onExit: { _ in })
    }

    /// Ends everything in the prefix at once, without asking: Wine's server is told to end
    /// its processes, and whatever is still there afterwards, which is what a frozen program
    /// looks like, is killed directly. Unsaved work in those programs is lost.
    /// Returns how many processes had to be killed directly.
    @discardableResult
    public func forceShutDown(_ prefix: Prefix) throws -> Int {
        if let plan = try? planner(for: prefix).killPlan() { _ = try? runner.run(plan) }
        let left = findProcesses(prefix.directory)
        left.forEach(killProcess)
        return left.count
    }

    /// The programs running in the prefix right now, by name; empty when there are none
    /// (Wine's own background processes do not count).
    public func runningProgramNames(in prefix: Prefix) -> [String] {
        RunningPrograms.names(commands: commandsOfProcesses(findProcesses(prefix.directory)),
                              programs: prefix.metadata.programs)
    }

    /// Closes everything in the given prefixes: every program is asked to close, as a Windows
    /// shut down asks; whatever is still there once `grace` seconds have passed is ended
    /// without asking. Returns the prefixes that had to be forced.
    @discardableResult
    public func closeEverything(in prefixes: [Prefix], grace: TimeInterval = 5,
                                pause: @Sendable (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) }) -> [Prefix] {
        for prefix in prefixes { try? shutDown(prefix) }
        var waited: TimeInterval = 0
        let step: TimeInterval = 0.25
        var left = prefixes
        while true {
            left = left.filter { !findProcesses($0.directory).isEmpty }
            if left.isEmpty || waited >= grace { break }
            pause(step)
            waited += step
        }
        for prefix in left { _ = try? forceShutDown(prefix) }
        return left
    }

    // MARK: Installers FineWine carries out itself

    /// Installs from an NSIS installer by carrying out its script, in place of running the
    /// installer, which is a 32-bit program (see `NSISScript`). The programs it finds are
    /// added to the prefix. Returns the prefix as it is afterwards, and what was done.
    public func installNSIS(_ installer: URL, in prefix: Prefix,
                            progress: (@Sendable (String) -> Void)? = nil) throws -> (prefix: Prefix, report: NSISInstallReport) {
        let users = prefix.driveC.appendingPathComponent("users")
        let user = ((try? FileManager.default.contentsOfDirectory(atPath: users.path)) ?? [])
            .filter { $0.lowercased() != "public" && !$0.hasPrefix(".") }.sorted().first ?? NSUserName()
        progress?(tr("nsis.reading"))
        let archive = try NSISArchive(url: installer) { fraction in
            progress?(tr("nsis.unpacking", Int(fraction * 100)))
        }
        let script = try NSISScript(archive: archive, driveC: prefix.driveC, userName: user, installer: installer,
                                    productName: InstallName.prefixName(for: installer, existing: []))
        let report = try script.install { file in progress?(tr("nsis.installing_file", file)) }

        if !report.registryFile.isEmpty {
            progress?(tr("nsis.writing_registry"))
            let file = prefix.driveC.appendingPathComponent("users/\(user)/Temp/finewine-install.reg")
            try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            // regedit reads UTF-16 with a byte-order mark
            var data = Data([0xFF, 0xFE])
            data.append(report.registryFile.data(using: .utf16LittleEndian) ?? Data())
            if (try? data.write(to: file)) != nil, let plan = try? planner(for: prefix).plan(importingRegistryFile: file) {
                _ = try? runner.run(plan)
            }
            try? FileManager.default.removeItem(at: file)
        }

        var updated = prefix
        for found in report.programs {
            let stem = String((found.windowsPath.split(separator: "\\").last ?? "Program").dropLast(4))
            let name = found.name ?? (report.programs.count == 1 ? prefix.name : stem)
            let folder = found.windowsPath.split(separator: "\\").dropLast().joined(separator: "\\")
            updated = try addProgram(Program(name: name, windowsPath: found.windowsPath,
                                             arguments: found.arguments.isEmpty ? [] : found.arguments.split(separator: " ").map(String.init),
                                             workingDirectory: folder), to: updated)
        }
        return (updated, report)
    }

    // MARK: Programs

    /// Adds a program to the prefix's list; one with the same executable is updated instead.
    @discardableResult
    public func addProgram(_ program: Program, to prefix: Prefix) throws -> Prefix {
        var updated = prefix
        if let index = updated.metadata.programs.firstIndex(where: {
            $0.windowsPath.caseInsensitiveCompare(program.windowsPath) == .orderedSame
        }) {
            var merged = program
            merged.id = updated.metadata.programs[index].id
            merged.shortcutPath = updated.metadata.programs[index].shortcutPath
            updated.metadata.programs[index] = merged
        } else {
            updated.metadata.programs.append(program)
        }
        try prefixes.save(updated)
        return updated
    }

    /// Adds every program the installers' shortcuts point at and that isn't listed yet.
    /// Returns the updated prefix and how many programs were new.
    public func importDiscoveredPrograms(into prefix: Prefix) throws -> (prefix: Prefix, added: Int) {
        // A prefix from before FineWine kept the desktop inside it has its shortcuts on the Mac desktop.
        keepDesktopInPrefix(prefix)
        var updated = prefix
        var added = 0
        // The same executable with other arguments is another program (a launcher, and the
        // launcher opened on one game).
        func key(_ path: String, _ arguments: [String]) -> String { ([path.lowercased()] + arguments).joined(separator: "\u{0}") }
        var known = Set(prefix.metadata.programs.map { key($0.windowsPath, $0.arguments) })
        for found in ProgramScanner.scan(prefix: prefix.directory) {
            let arguments = ProgramScanner.splitArguments(found.arguments)
            guard known.insert(key(found.windowsPath, arguments)).inserted else { continue }
            updated.metadata.programs.append(Program(
                name: found.name, windowsPath: found.windowsPath,
                arguments: arguments,
                workingDirectory: found.workingDirectory,
                iconPath: found.iconPath.isEmpty ? nil : found.iconPath))
            added += 1
        }
        if added > 0 { try prefixes.save(updated) }
        return (updated, added)
    }

    @discardableResult
    public func removeProgram(id: UUID, from prefix: Prefix) throws -> Prefix {
        try shortcuts.remove(programID: id)
        var updated = prefix
        updated.metadata.programs.removeAll { $0.id == id }
        try prefixes.save(updated)
        return updated
    }

    // MARK: Shortcuts

    /// Makes the program's shortcut app, with the executable's own icon when it has one.
    @discardableResult
    public func createShortcut(for programID: UUID, in prefix: Prefix) throws -> Prefix {
        guard let index = prefix.metadata.programs.firstIndex(where: { $0.id == programID }) else {
            throw FineWineError("That program is no longer in “\(prefix.name)”.")
        }
        let program = prefix.metadata.programs[index]
        // The icon the installer's shortcut named, if it named one; else the program's own.
        // Drawn as a Mac app icon when the prefix's programs are, so the shortcut and the
        // program it starts look alike in the Dock.
        let macStyle = prefix.metadata.settings.macStyleIcons
        let icon = program.iconPath.flatMap { WindowsPath.macURL(for: $0, inPrefix: prefix.directory) }
            .flatMap { ICNS.data(fromIconFile: $0, macStyle: macStyle) }
            ?? WindowsPath.macURL(for: program.windowsPath, inPrefix: prefix.directory)
            .flatMap { ICNS.data(fromExecutable: $0, macStyle: macStyle) }
        let url = try shortcuts.build(for: program, in: prefix, icon: icon)
        var updated = prefix
        updated.metadata.programs[index].shortcutPath = url.path
        try prefixes.save(updated)
        return updated
    }

    @discardableResult
    public func removeShortcut(for programID: UUID, in prefix: Prefix) throws -> Prefix {
        try shortcuts.remove(programID: programID)
        var updated = prefix
        if let index = updated.metadata.programs.firstIndex(where: { $0.id == programID }) {
            updated.metadata.programs[index].shortcutPath = nil
            try prefixes.save(updated)
        }
        return updated
    }

    // MARK: Launching

    /// A log file for one launch: `Logs/<prefix folder>/<timestamp> <name>.log`.
    public func logFile(for prefix: Prefix, name: String, date: Date = Date()) -> URL {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
        let safe = ShortcutAppBuilder.sanitizedName(name)
        return paths.logs.appendingPathComponent(prefix.directory.lastPathComponent, isDirectory: true)
            .appendingPathComponent("\(formatter.string(from: date)) \(safe).log")
    }

    /// Where the memory logs of a launch go: a folder named after its log file,
    /// `<timestamp> <name> memory`.
    public func memoryTraceFolder(forLog log: URL) -> URL {
        log.deletingLastPathComponent()
            .appendingPathComponent(log.deletingPathExtension().lastPathComponent + " memory", isDirectory: true)
    }

    /// Puts the runtime's stand-in for Steam where Steam is in a prefix, unless that very file
    /// is there already. A real Steam installed in the prefix is left alone and used instead.
    func installSteamStandIn(from runtime: WineRuntime, in prefix: Prefix) throws {
        guard let source = runtime.steamStandIn,
              let target = WindowsPath.macURL(for: SteamStandIn.windowsPath, inPrefix: prefix.directory) else { return }
        let fm = FileManager.default
        let folder = target.deletingLastPathComponent()
        if fm.fileExists(atPath: target.path) {
            if fm.contentsEqual(atPath: source.path, andPath: target.path) { return }
            // Only a stand-in from another runtime version is replaced; it is alone in its folder.
            let others = (try? fm.contentsOfDirectory(atPath: folder.path))?.filter { $0 != target.lastPathComponent } ?? []
            guard others.isEmpty else { return }
            try fm.removeItem(at: target)
        }
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        try fm.copyItem(at: source, to: target)
    }

    /// Starts a program and returns its pid.
    @discardableResult
    ///
    /// With `memoryTrace`, the launch also gets a folder beside its log file
    /// (`memoryTraceFolder`) that the runtime fills with memory logs.
    public func launch(programID: UUID, in prefix: Prefix, memoryTrace: Bool = false,
                       onExit: @escaping @Sendable (Int32) -> Void = { _ in }) throws -> Int32 {
        guard let program = prefix.program(id: programID) else {
            throw FineWineError("That program is no longer in “\(prefix.name)”.")
        }
        guard let exe = WindowsPath.macURL(for: program.windowsPath, inPrefix: prefix.directory),
              FileManager.default.fileExists(atPath: exe.path) else {
            throw FineWineError("“\(program.windowsPath)” doesn't exist in “\(prefix.name)”. It may have been moved or uninstalled.")
        }
        let planner = try planner(for: prefix)
        // The folder the runtime writes its "this program rendered" marker into.
        try? FileManager.default.createDirectory(at: planner.gameMarker(for: program).deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        keepDesktopInPrefix(prefix)
        refreshEmulator(in: prefix, from: planner.runtime)
        if planner.steamAppID(for: program) != nil { try installSteamStandIn(from: planner.runtime, in: prefix) }
        let log = logFile(for: prefix, name: program.name)
        var traceFolder: URL?
        if memoryTrace {
            let folder = memoryTraceFolder(forLog: log)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            traceFolder = folder
        }
        return try runner.start(try planner.plan(for: program, memoryTraceFolder: traceFolder),
                                logFile: log, onExit: onExit)
    }

    @discardableResult
    public func launch(tool: WineTool, in prefix: Prefix,
                       onExit: @escaping @Sendable (Int32) -> Void = { _ in }) throws -> Int32 {
        try runner.start(try planner(for: prefix).plan(for: tool),
                         logFile: logFile(for: prefix, name: tool.rawValue), onExit: onExit)
    }

    /// Runs an installer or any other executable from the Mac filesystem in the prefix.
    @discardableResult
    public func launch(executable: URL, in prefix: Prefix,
                       onExit: @escaping @Sendable (Int32) -> Void = { _ in }) throws -> Int32 {
        keepDesktopInPrefix(prefix)
        let planner = try planner(for: prefix)
        refreshEmulator(in: prefix, from: planner.runtime)
        return try runner.start(try planner.plan(forExecutableAt: executable),
                                logFile: logFile(for: prefix, name: executable.lastPathComponent), onExit: onExit)
    }

    // MARK: The x64 emulator

    /// A prefix keeps its own copy of the x64 emulator (FEX, `xtajit64.dll`) in its system
    /// folder, made when the prefix was set up, and Wine loads that copy. It is not a Wine
    /// library, so updating the prefix does not replace it: a prefix would go on running the
    /// emulator of the runtime it was created with. This brings it up to date.
    @discardableResult
    public func refreshEmulator(in prefix: Prefix, from runtime: WineRuntime) -> Bool {
        let fm = FileManager.default
        let source = runtime.root.appendingPathComponent("lib/wine/aarch64-windows/xtajit64.dll")
        let target = prefix.directory.appendingPathComponent("drive_c/windows/system32/xtajit64.dll")
        guard fm.fileExists(atPath: source.path), fm.fileExists(atPath: target.path),
              !fm.contentsEqual(atPath: source.path, andPath: target.path) else { return false }
        let staging = target.appendingPathExtension("new")
        try? fm.removeItem(at: staging)
        guard (try? fm.copyItem(at: source, to: staging)) != nil,
              (try? fm.replaceItemAt(target, withItemAt: staging)) != nil else { return false }
        return true
    }

    // MARK: The Windows desktop

    /// Wine makes the Windows desktop folder a link to the Mac's Desktop, so an installer's
    /// "desktop shortcut" lands on the Mac desktop as a `.lnk` file nothing can open. FineWine
    /// gives the prefix a desktop folder of its own instead: shortcuts stay inside the prefix,
    /// where they are found and turned into programs (and shortcut apps).
    ///
    /// For a prefix made before this, shortcuts already on the Mac desktop that point at
    /// programs in this prefix are moved into it. Returns how many were moved.
    @discardableResult
    public func keepDesktopInPrefix(_ prefix: Prefix) -> Int {
        let fm = FileManager.default
        let usersFolder = prefix.directory.appendingPathComponent("drive_c/users")
        var moved = 0
        for user in (try? fm.contentsOfDirectory(at: usersFolder, includingPropertiesForKeys: nil)) ?? [] {
            let desktop = user.appendingPathComponent("Desktop")
            guard let linked = try? fm.destinationOfSymbolicLink(atPath: desktop.path) else { continue }
            let macDesktop = URL(fileURLWithPath: linked, relativeTo: user)
            guard (try? fm.removeItem(at: desktop)) != nil,
                  (try? fm.createDirectory(at: desktop, withIntermediateDirectories: false)) != nil else { continue }
            // Only shortcuts lying directly on the Mac desktop, and only ones whose program is
            // in this prefix: nothing else there is FineWine's to touch.
            for file in (try? fm.contentsOfDirectory(at: macDesktop, includingPropertiesForKeys: nil)) ?? []
            where file.pathExtension.lowercased() == "lnk" {
                guard let data = try? Data(contentsOf: file), let link = ShellLink(data: data),
                      let target = WindowsPath.macURL(for: link.target, inPrefix: prefix.directory),
                      fm.fileExists(atPath: target.path),
                      target.resolvingSymlinksInPath().path.hasPrefix(prefix.directory.resolvingSymlinksInPath().path + "/") else { continue }
                if (try? fm.moveItem(at: file, to: desktop.appendingPathComponent(file.lastPathComponent))) != nil { moved += 1 }
            }
        }
        return moved
    }

    public func runWineboot(_ action: WinebootAction, in prefix: Prefix) throws {
        try runChecked(try planner(for: prefix).plan(for: action), what: "wineboot \(action.rawValue)")
    }
}
