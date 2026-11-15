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
        case .winecfg: return "Wine Configuration"
        case .regedit: return "Registry Editor"
        case .control: return "Control Panel"
        case .uninstaller: return "Add or Remove Programs"
        case .taskmgr: return "Task Manager"
        case .winefile: return "File Manager"
        case .cmd: return "Command Prompt"
        case .notepad: return "Notepad"
        }
    }

    public var summary: String {
        switch self {
        case .winecfg: return "Libraries, graphics, audio, drives and per-program Windows versions."
        case .regedit: return "Browse and edit the prefix's registry."
        case .control: return "Windows control panel applets, such as game controllers."
        case .uninstaller: return "Remove programs installed in this prefix."
        case .taskmgr: return "See and end the Windows processes running in this prefix."
        case .winefile: return "Browse the prefix's drives."
        case .cmd: return "A Windows command line in this prefix."
        case .notepad: return "A plain text editor, handy for checking the prefix works."
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
        env["DYLD_FALLBACK_LIBRARY_PATH"] = runtime.root.appendingPathComponent("lib").path + ":/usr/local/lib:/usr/lib"

        // FineWine makes its own shortcut apps, so Wine's menu builder is switched off.
        var overrides = ["winemenubuilder.exe=d"]
        if let spec = activeGraphicsSpec {
            env["WINEDLLPATH"] = runtime.root.appendingPathComponent(spec.dllPath).path
            overrides += spec.overrides.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }
        }

        var userOverrides: String?
        for (name, value) in prefix.metadata.settings.environmentVariables() + extra.map({ ($0.name, $0.value) }) {
            guard EnvironmentVariable.isValidName(name) else { continue }
            if name == "WINEDLLOVERRIDES" { userOverrides = value } else { env[name] = value }
        }
        if let userOverrides, !userOverrides.isEmpty { overrides.append(userOverrides) }
        env["WINEDLLOVERRIDES"] = overrides.joined(separator: ";")
        return env
    }

    /// Runs a program installed in the prefix.
    public func plan(for program: Program) throws -> LaunchPlan {
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
        return LaunchPlan(executable: try wine(), arguments: arguments,
                          environment: environment(extra: program.environment),
                          workingDirectory: cwd ?? prefix.directory)
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
        LaunchPlan(executable: try wine(), arguments: ["wineboot", action.rawValue],
                   environment: environment(), workingDirectory: prefix.directory)
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
