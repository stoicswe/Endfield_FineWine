import Foundation

/// The operations the app performs on prefixes, combining the stores, the launch planner and a
/// process runner. Calls that run Wine block until it finishes, so the app makes them off the
/// main thread.
public struct PrefixService {
    /// How processes are listed and killed for `forceShutDown`. Replaced in tests.
    public var findProcesses: @Sendable (URL) -> [Int32] = { PrefixProcesses.systemPIDs(prefixDirectory: $0) }
    public var killProcess: @Sendable (Int32) -> Void = { _ = kill($0, SIGKILL) }

    public let paths: FineWinePaths
    public let prefixes: PrefixStore
    public let runtimes: RuntimeStore
    public let profiles: ProfileStore
    public let shortcuts: ShortcutAppBuilder
    public let runner: ProcessRunning

    public init(paths: FineWinePaths, runner: ProcessRunning = SystemProcessRunner()) {
        self.paths = paths
        self.prefixes = PrefixStore(paths: paths)
        self.runtimes = RuntimeStore(paths: paths)
        self.profiles = ProfileStore(paths: paths)
        self.shortcuts = ShortcutAppBuilder(directory: paths.shortcuts)
        self.runner = runner
    }

    // MARK: Planning

    public func runtime(for prefix: Prefix) throws -> WineRuntime {
        guard let id = prefix.metadata.runtimeID else {
            throw FineWineError("“\(prefix.name)” has no runtime chosen. Pick one in its settings.")
        }
        guard let runtime = runtimes.runtime(id: id) else {
            throw FineWineError("The runtime “\(prefix.name)” uses is no longer installed. Pick another in its settings.")
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

    private func runChecked(_ plan: LaunchPlan, what: String) throws {
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
                             appearance: MacAppearance? = nil) throws -> Prefix {
        let problems = runtime.problems()
        guard problems.isEmpty else {
            throw FineWineError("The runtime “\(runtime.name)” can't be used: " + problems.joined(separator: " "))
        }
        let prefix = try prefixes.create(name: name, runtimeID: runtime.id, profile: profile)
        do {
            try runChecked(try planner(for: prefix).plan(for: .initialize), what: "Setting up the prefix")
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
        var updated = prefix
        var added = 0
        let known = Set(prefix.metadata.programs.map { $0.windowsPath.lowercased() })
        for found in ProgramScanner.scan(prefix: prefix.directory) where !known.contains(found.windowsPath.lowercased()) {
            updated.metadata.programs.append(Program(
                name: found.name, windowsPath: found.windowsPath,
                arguments: ProgramScanner.splitArguments(found.arguments),
                workingDirectory: found.workingDirectory))
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
        let icon = WindowsPath.macURL(for: program.windowsPath, inPrefix: prefix.directory)
            .flatMap(ICNS.data(fromExecutable:))
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

    /// Starts a program and returns its pid.
    @discardableResult
    public func launch(programID: UUID, in prefix: Prefix,
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
        return try runner.start(try planner.plan(for: program),
                                logFile: logFile(for: prefix, name: program.name), onExit: onExit)
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
        try runner.start(try planner(for: prefix).plan(forExecutableAt: executable),
                         logFile: logFile(for: prefix, name: executable.lastPathComponent), onExit: onExit)
    }

    public func runWineboot(_ action: WinebootAction, in prefix: Prefix) throws {
        try runChecked(try planner(for: prefix).plan(for: action), what: "wineboot \(action.rawValue)")
    }
}
