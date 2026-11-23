import Foundation

/// Everything needed to start one process: what to run, with which arguments and environment,
/// and where.
public struct LaunchPlan: Equatable, Sendable {
    public var executable: URL
    public var arguments: [String]
    public var environment: [String: String]
    public var workingDirectory: URL?

    public init(executable: URL, arguments: [String], environment: [String: String], workingDirectory: URL? = nil) {
        self.executable = executable
        self.arguments = arguments
        self.environment = environment
        self.workingDirectory = workingDirectory
    }
}

/// Wine's own configuration and maintenance programs.
public enum WineTool: String, CaseIterable, Identifiable, Sendable {
    case winecfg, regedit, control, uninstaller, taskmgr, winefile, cmd, notepad

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .winecfg: return tr("tool.winecfg.name")
        case .regedit: return tr("tool.regedit.name")
        case .control: return tr("tool.control.name")
        case .uninstaller: return tr("tool.uninstaller.name")
        case .taskmgr: return tr("tool.taskmgr.name")
        case .winefile: return tr("tool.winefile.name")
        case .cmd: return tr("tool.cmd.name")
        case .notepad: return tr("tool.notepad.name")
        }
    }

    public var summary: String {
        switch self {
        case .winecfg: return tr("tool.winecfg.summary")
        case .regedit: return tr("tool.regedit.summary")
        case .control: return tr("tool.control.summary")
        case .uninstaller: return tr("tool.uninstaller.summary")
        case .taskmgr: return tr("tool.taskmgr.summary")
        case .winefile: return tr("tool.winefile.summary")
        case .cmd: return tr("tool.cmd.summary")
        case .notepad: return tr("tool.notepad.summary")
        }
    }

    public var symbol: String {
        switch self {
        case .winecfg: return "slider.horizontal.3"
        case .regedit: return "list.bullet.indent"
        case .control: return "switch.2"
        case .uninstaller: return "trash"
        case .taskmgr: return "waveform.path.ecg"
        case .winefile: return "folder"
        case .cmd: return "terminal"
        case .notepad: return "doc.text"
        }
    }

    /// The arguments to `wine` that start the tool.
    public var wineArguments: [String] {
        switch self {
        case .cmd: return ["start", "cmd.exe"]   // `start` gives it a console window of its own
        default: return [rawValue]
        }
    }
}

public enum WinebootAction: String, Sendable {
    /// Set a new prefix up, or bring an existing one up to date with the runtime.
    case initialize = "--init"
    case update = "--update"
    /// Simulate a Windows restart (some installers ask for one).
    case restart = "--restart"
    /// Ask every program in the prefix to quit, as a Windows shutdown would.
    case shutdown = "--shutdown"
}

/// Builds launch plans for one prefix and runtime.
public struct LaunchPlanner {
    /// Variables copied from FineWine's own environment. Everything else is left behind so a
    /// stray `DYLD_…` or `WINE…` in the user's session can't change how programs run.
    public static let inheritedVariables = ["PATH", "HOME", "USER", "LOGNAME", "TMPDIR", "LANG", "LC_ALL", "SHELL"]

    public let runtime: WineRuntime
    public let prefix: Prefix
    public let profile: GameProfile?
    public let baseEnvironment: [String: String]

    public init(runtime: WineRuntime, prefix: Prefix, profile: GameProfile? = nil,
                baseEnvironment: [String: String] = ProcessInfo.processInfo.environment) {
        self.runtime = runtime
        self.prefix = prefix
        self.profile = profile
        self.baseEnvironment = baseEnvironment
    }

    private func wine() throws -> URL {
        guard let wine = runtime.wineBinary else {
            throw FineWineError("The runtime “\(runtime.name)” has no wine program in its bin folder.")
        }
        return wine
    }

    /// The graphics backend the prefix asks for, if this runtime ships it.
    public var activeGraphicsSpec: GraphicsBackendSpec? {
        runtime.graphicsSpec(for: prefix.metadata.settings.graphicsBackend)
    }

    /// The environment every Wine process in this prefix gets.
    public func environment(extra: [EnvironmentVariable] = []) -> [String: String] {
        var env: [String: String] = [:]
        for name in Self.inheritedVariables {
            if let value = baseEnvironment[name] { env[name] = value }
        }
        env["PATH"] = runtime.binDirectory.path + ":" + (env["PATH"] ?? "/usr/bin:/bin")
        env["WINEPREFIX"] = prefix.directory.path
        if let server = runtime.wineserverBinary { env["WINESERVER"] = server.path }
        // The runtime's own dylibs (MoltenVK, GStreamer, …) first, then the system default.
        env["DYLD_FALLBACK_LIBRARY_PATH"] = (runtime.libraryDirectories.map(\.path) + ["/usr/local/lib", "/usr/lib"])
            .joined(separator: ":")
        // What the runtime's description asks for; the prefix's own variables come after.
        for (name, value) in runtime.manifest.environment ?? [:]
        where EnvironmentVariable.isValidName(name) && !RuntimeManifest.reservedVariables.contains(name) {
            env[name] = runtime.expand(value, prefix: prefix.directory)
        }

        // FineWine makes its own shortcut apps, so Wine's menu builder is switched off.
        var overrides = ["winemenubuilder.exe=d"]
        if let spec = activeGraphicsSpec {
            env["WINEDLLPATH"] = runtime.root.appendingPathComponent(spec.dllPath).path
            overrides += spec.overrides.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }
        }
        // Direct3D 9 and older on DXVK, when the prefix asks for it and the runtime has it: its
        // d3d9.dll is found before Wine's own, and the runtime's MoltenVK reports the features
        // DXVK will not start without (Direct3D 9 uses none of them). DXVK's log files, which
        // it would write next to the game, are off.
        if prefix.metadata.settings.legacyDirect3DOnVulkan, let dxvk = runtime.direct3D9OnVulkanSpec {
            let path = runtime.root.appendingPathComponent(dxvk.dllPath).path
            env["WINEDLLPATH"] = [path, env["WINEDLLPATH"]].compactMap { $0 }.joined(separator: ":")
            env["FINEWINE_DXVK_FEATURES"] = "1"
            env["DXVK_LOG_LEVEL"] = "none"
            // Its shader cache in the prefix, not next to the game (which may be in a Steam
            // library): there FineWine can find it to clear it.
            env["DXVK_STATE_CACHE_PATH"] = WindowsPath.windowsPath(for: ShaderCaches.dxvkDirectory(inPrefix: prefix.directory),
                                                                   inPrefix: prefix.directory)
        }

        // A language for non-Unicode programs is set through LC_CTYPE, which an inherited
        // LC_ALL would override.
        if prefix.metadata.settings.nonUnicodeLanguage.unixLocale != nil { env.removeValue(forKey: "LC_ALL") }

        var userOverrides: String?
        for (name, value) in prefix.metadata.settings.environmentVariables(supporting: runtime.capabilities)
            + extra.map({ ($0.name, $0.value) }) {
            guard EnvironmentVariable.isValidName(name) else { continue }
            if name == "WINEDLLOVERRIDES" { userOverrides = value } else { env[name] = value }
        }
        if let userOverrides, !userOverrides.isEmpty { overrides.append(userOverrides) }
        env["WINEDLLOVERRIDES"] = overrides.joined(separator: ";")
        return env
    }

    // MARK: Memory trace

    /// The environment variable naming the folder the runtime writes memory logs into, one file
    /// per process: every reservation, commit, decommit, release and mapping of 8 MB or more
    /// with the modules that asked for it, and totals every five seconds.
    public static let memoryTraceVariable = "FINEWINE_MEMORY_TRACE"

    // MARK: Game Mode

    /// The environment variable naming the file the runtime creates when a program first uses
    /// Direct3D or Vulkan, and the one naming the loader a program and its children run under.
    public static let gameMarkerVariable = "FINEWINE_GAME_MARKER"
    public static let loaderVariable = "FINEWINE_LOADER"

    /// The file that records that a program, or something it started, rendered with a GPU API.
    public func gameMarker(for program: Program) -> URL {
        prefix.directory.appendingPathComponent(".finewine-games", isDirectory: true)
            .appendingPathComponent("\(program.id.uuidString).rendered")
    }

    /// Whether to start the program as a game: it is a HoYoverse game or HoYoPlay (which only
    /// starts games), it or another entry for the same executable has rendered before (it, or a
    /// game its launcher started), or its executable imports a rendering API.
    ///
    /// macOS decides whether an app is a game when it starts, so the game a launcher starts can
    /// only be in Game Mode if the launcher was started as one. A launcher's own imports say
    /// nothing, and its marker only appears once the game has rendered, too late for that launch.
    public func isGame(_ program: Program) -> Bool {
        if SteamStandIn.appID(forWindowsPath: program.windowsPath) != nil { return true }
        let sameExecutable = prefix.metadata.programs.filter {
            $0.id != program.id && $0.windowsPath.caseInsensitiveCompare(program.windowsPath) == .orderedSame
        }
        for entry in [program] + sameExecutable
        where FileManager.default.fileExists(atPath: gameMarker(for: entry).path) { return true }
        guard let exe = WindowsPath.macURL(for: program.windowsPath, inPrefix: prefix.directory) else { return false }
        return PEImports.usesRenderingAPI(at: exe)
    }

    /// What Game Mode adds to a program's environment. macOS decides from the running
    /// executable whether an app is a game, so a game is run with the loader that says it is;
    /// every program is given the marker to create if it turns out to render after all.
    public func gameModeEnvironment(for program: Program) -> [String: String] {
        guard prefix.metadata.settings.gameMode, runtime.supports(.gameMode), runtime.hasGameLoader else { return [:] }
        var env = [Self.gameMarkerVariable: gameMarker(for: program).path]
        if isGame(program) { env[Self.loaderVariable] = WineRuntime.gameLoaderName }
        return env
    }

    /// The variable that makes the runtime treat a program as DPI aware (Windows: "Override
    /// high DPI scaling behaviour: Application"). See `dpiAwareEnvironment`.
    public static let dpiAwareVariable = "FINEWINE_DPI_AWARE"

    /// A game is run as DPI aware whether it says so or not. One that does not, in a prefix
    /// with a high DPI (a Retina prefix has 192), is told a screen half the size of the display
    /// modes it is offered and sizes its full-screen window by the mode, so the window comes
    /// out twice the screen (Portal). Only for a program that draws with a rendering API
    /// itself: a launcher that starts a game is a desktop program, and scaling is for those.
    public func dpiAwareEnvironment(for program: Program) -> [String: String] {
        guard let exe = WindowsPath.macURL(for: program.windowsPath, inPrefix: prefix.directory),
              PEImports.usesRenderingAPI(at: exe) else { return [:] }
        return [Self.dpiAwareVariable: "1"]
    }

    // MARK: Steam stand-in

    /// The Steam id to start the program with, if it is one that is started through the
    /// runtime's stand-in for Steam, the prefix allows it and the runtime has the stand-in.
    public func steamAppID(for program: Program) -> String? {
        guard prefix.metadata.settings.steamForHoYoverse, runtime.supports(.steamStandIn),
              runtime.steamStandIn != nil else { return nil }
        return SteamStandIn.appID(forWindowsPath: program.windowsPath)
    }

    /// The Steam app id of a program: the prefix's when Steam made it, else what the game's
    /// own files say (`SteamAppIDFinder`).
    public func realSteamAppID(for program: Program) -> String? {
        if let id = prefix.metadata.steamAppID, !id.isEmpty { return id }
        guard let exe = WindowsPath.macURL(for: program.windowsPath, inPrefix: prefix.directory) else { return nil }
        return SteamAppIDFinder.appID(forProgramAt: exe)
    }

    /// The fixes a game gets by itself, if the prefix allows it and the runtime has the switches.
    public func gameFixes(for program: Program) -> GameFixes {
        guard prefix.metadata.settings.gameFixes, runtime.supports(.compatSwitches),
              let id = realSteamAppID(for: program) else { return GameFixes() }
        return GameFixes.fixes(forSteamAppID: id)
    }

    /// Runs a program installed in the prefix.
    ///
    /// With `memoryTraceFolder`, the runtime writes a memory log for the program and everything
    /// it starts into that folder: its large allocations with their likely callers, and running
    /// totals with the memory footprint (see `memoryTraceVariable`).
    public func plan(for program: Program, memoryTraceFolder: URL? = nil) throws -> LaunchPlan {
        var arguments = [program.windowsPath]
        if let profile, profile.matches(windowsPath: program.windowsPath) {
            arguments += profile.launchArguments.filter { !program.arguments.contains($0) }
        }
        arguments += program.arguments

        let windowsDirectory = program.workingDirectory.isEmpty
            ? WindowsPath.directory(program.windowsPath) : program.workingDirectory
        var cwd = WindowsPath.macURL(for: windowsDirectory, inPrefix: prefix.directory)
        var isDir: ObjCBool = false
        if let dir = cwd, !(FileManager.default.fileExists(atPath: dir.path, isDirectory: &isDir) && isDir.boolValue) {
            cwd = nil
        }
        var env = environment(extra: program.environment)
        if let steamID = steamAppID(for: program) {
            arguments.insert(SteamStandIn.windowsPath, at: 0)
            for name in ["SteamGameId", "SteamAppId"] where env[name] == nil { env[name] = steamID }
        }
        // What the game is known to need (Proton's table). The prefix's and the program's own
        // variables keep the last word; a DLL the user has an override for is left alone.
        let fixes = gameFixes(for: program)
        for (name, value) in fixes.environment where env[name] == nil { env[name] = value }
        if !fixes.dllOverrides.isEmpty {
            let existing = env["WINEDLLOVERRIDES"] ?? ""
            let named = Set(existing.split(separator: ";").flatMap { entry in
                entry.split(separator: "=").first.map { $0.split(separator: ",").map { $0.lowercased() } } ?? []
            })
            let added = fixes.dllOverrides.sorted { $0.key < $1.key }
                .filter { !named.contains($0.key.lowercased()) }.map { "\($0.key)=\($0.value)" }
            if !added.isEmpty { env["WINEDLLOVERRIDES"] = ([existing] + added).filter { !$0.isEmpty }.joined(separator: ";") }
        }
        // What macOS calls the program: the name it is listed under here. The runtime uses
        // it for this executable only; anything the program starts names itself.
        if env["FINEWINE_APP_NAME"] == nil, env["FINEWINE_APP_EXE"] == nil {
            env["FINEWINE_APP_NAME"] = program.name
            env["FINEWINE_APP_EXE"] = WindowsPath.lastComponent(program.windowsPath)
        }
        // The program's own variables keep the last word, as everywhere else.
        for (name, value) in gameModeEnvironment(for: program) where env[name] == nil { env[name] = value }
        for (name, value) in dpiAwareEnvironment(for: program) where env[name] == nil { env[name] = value }
        if let memoryTraceFolder { env[Self.memoryTraceVariable] = memoryTraceFolder.path }
        return LaunchPlan(executable: try wine(), arguments: arguments,
                          environment: env, workingDirectory: cwd ?? prefix.directory)
    }

    /// Runs any executable or installer from the Mac filesystem inside the prefix.
    public func plan(forExecutableAt url: URL, arguments: [String] = []) throws -> LaunchPlan {
        let isInstallerPackage = url.pathExtension.lowercased() == "msi"
        let command = isInstallerPackage ? ["msiexec", "/i", url.path] : [url.path]
        return LaunchPlan(executable: try wine(), arguments: command + arguments,
                          environment: environment(), workingDirectory: url.deletingLastPathComponent())
    }

    public func plan(for tool: WineTool) throws -> LaunchPlan {
        LaunchPlan(executable: try wine(), arguments: tool.wineArguments,
                   environment: environment(), workingDirectory: prefix.directory)
    }

    public func plan(for action: WinebootAction) throws -> LaunchPlan {
        var env = environment()
        if action == .initialize || action == .update {
            // Setting a prefix up makes Wine offer to download Wine Mono (.NET) and Wine Gecko
            // (HTML) in dialogs that would sit behind FineWine's own progress display. Turning
            // the two DLLs off for this one run skips the offer; nothing is installed or removed.
            env["WINEDLLOVERRIDES"] = (env["WINEDLLOVERRIDES"].map { $0 + ";" } ?? "") + "mscoree=d;mshtml=d"
        }
        var arguments = ["wineboot", action.rawValue]
        if action == .initialize, let setup = runtime.manifest.prefixSetup, !setup.isEmpty {
            arguments = setup.map { runtime.expand($0, prefix: prefix.directory) }
        }
        return LaunchPlan(executable: try wine(), arguments: arguments,
                          environment: env, workingDirectory: prefix.directory)
    }

    /// Imports a `.reg` file without showing any windows.
    public func plan(importingRegistryFile file: URL) throws -> LaunchPlan {
        LaunchPlan(executable: try wine(), arguments: ["regedit", "/S", file.path],
                   environment: environment(), workingDirectory: prefix.directory)
    }

    /// Stops every process in the prefix at once.
    public func killPlan() throws -> LaunchPlan {
        guard let server = runtime.wineserverBinary else {
            throw FineWineError("The runtime “\(runtime.name)” has no wineserver in its bin folder.")
        }
        return LaunchPlan(executable: server, arguments: ["-k"], environment: environment(),
                          workingDirectory: prefix.directory)
    }
}
