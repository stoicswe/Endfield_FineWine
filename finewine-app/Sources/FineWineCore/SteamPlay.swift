import Foundation
import CryptoKit

// Starting Windows games from the Mac Steam client with FineWine's runtime.
//
// The Mac Steam client only offers "compatibility tools" once NotProton or Bridgeplay has
// switched that on (they patch the client; FineWine does not). A tool is a folder in Steam's
// `compatibilitytools.d` with two descriptions and a `run` script. FineWine's tool sits beside
// theirs: its script starts FineWine itself with `--steam-run`, which finds or makes the
// game's prefix and starts the game through the runtime's bridge to Steam
// (runtime-extras/steam-bridge, runtime patch 0042).

/// The Mac Steam client's own folder.
public struct SteamClient: Equatable, Sendable {
    public var root: URL
    /// The user's Application Support folder, where the tools that switch Steam Play on live.
    public var applicationSupport: URL

    public init(root: URL, applicationSupport: URL) {
        self.root = root
        self.applicationSupport = applicationSupport
    }

    public static func standard(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> SteamClient {
        let support = home.appendingPathComponent("Library/Application Support", isDirectory: true)
        return SteamClient(root: support.appendingPathComponent("Steam", isDirectory: true), applicationSupport: support)
    }

    public var isInstalled: Bool { FileManager.default.fileExists(atPath: root.appendingPathComponent("steamapps").path) }
    public var toolsDirectory: URL { root.appendingPathComponent("compatibilitytools.d", isDirectory: true) }

    /// The apps that switch Steam Play on in the Mac client, as far as their traces show:
    /// their support folder, or a tool of theirs in Steam's tools folder.
    public var steamPlayEnablers: [String] {
        let fm = FileManager.default
        let tools = (try? fm.contentsOfDirectory(atPath: toolsDirectory.path)) ?? []
        var found: [String] = []
        if fm.fileExists(atPath: applicationSupport.appendingPathComponent("notproton").path)
            || tools.contains(where: { $0.hasPrefix("notproton") }) { found.append("NotProton") }
        if fm.fileExists(atPath: applicationSupport.appendingPathComponent("Bridgeplay").path)
            || fm.fileExists(atPath: applicationSupport.appendingPathComponent("bridgeplay").path)
            || tools.contains(where: { $0.hasPrefix("bridgeplay") }) { found.append("Bridgeplay") }
        return found
    }

    /// Folders where another tool keeps Valve's Windows client files, to copy them from.
    public var valveFileSources: [URL] {
        ["notproton/bridge", "Bridgeplay/bridge", "bridgeplay/bridge"].map { applicationSupport.appendingPathComponent($0) }
    }

    /// A game's name from its `appmanifest_<id>.acf`, looked for beside the game's folder
    /// (`…/steamapps/common/<game>`) and in the client's own library.
    public func appName(appID: String, installPath: URL?) -> String? {
        var libraries = [root.appendingPathComponent("steamapps")]
        if let installPath { libraries.insert(installPath.deletingLastPathComponent().deletingLastPathComponent(), at: 0) }
        for library in libraries {
            let manifest = library.appendingPathComponent("appmanifest_\(appID).acf")
            guard let text = try? String(contentsOf: manifest, encoding: .utf8) else { continue }
            if let name = Self.value(of: "name", inACF: text), !name.isEmpty { return name }
        }
        return nil
    }

    /// The value of a top-level `"key"  "value"` line in Valve's text format.
    static func value(of key: String, inACF text: String) -> String? {
        for line in text.components(separatedBy: .newlines) {
            let parts = line.components(separatedBy: "\"")
            // "key" <tabs> "value"  →  ["", key, tabs, value, ""]
            if parts.count >= 5, parts[1].caseInsensitiveCompare(key) == .orderedSame,
               parts[2].trimmingCharacters(in: .whitespaces).isEmpty {
                return parts[3].replacingOccurrences(of: "\\\\", with: "\\")
            }
        }
        return nil
    }
}

/// FineWine's compatibility tool in Steam's tools folder.
public struct SteamTool: Sendable {
    /// The folder's name is the tool's name. Not one of the names NotProton or Bridgeplay
    /// treat as theirs (they remove folders starting "notproton" or "bridgeplay-proton" that
    /// they did not list), and with "proton" in it: Steam maps Steam Cloud's Windows folders
    /// only for a tool so named.
    public static let name = "finewine-proton"
    public static let displayName = "FineWine"
    /// The file that marks the folder as made by FineWine and says which app it starts.
    static let markerFile = "finewine-app"

    public let client: SteamClient
    public init(client: SteamClient) { self.client = client }

    public var directory: URL { client.toolsDirectory.appendingPathComponent(Self.name, isDirectory: true) }
    public var isInstalled: Bool { FileManager.default.fileExists(atPath: directory.appendingPathComponent("run").path) }

    /// The FineWine.app the installed tool starts.
    public var appPath: String? {
        (try? String(contentsOf: directory.appendingPathComponent(Self.markerFile), encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static let manifest = "\"manifest\"\n{\n  \"version\" \"2\"\n  \"commandline\" \"/run %verb%\"\n}\n"

    static var declaration: String {
        """
        "compatibilitytools"
        {
          "compat_tools"
          {
            "\(name)"
            {
              "install_path" "."
              "display_name" "\(displayName)"
              "from_oslist" "windows"
              "to_oslist" "macos"
            }
          }
        }

        """
    }

    /// The script Steam runs. It only hands over to FineWine, which does the work
    /// (`SteamRun`): the app it was installed from, or FineWine wherever else it is.
    static func runScript(app: URL) -> String {
        let quoted = "'" + app.path.replacingOccurrences(of: "'", with: "'\\''") + "'"
        return """
        #!/bin/sh
        # FineWine's Steam compatibility tool. Made by FineWine; remove it from FineWine's settings.
        case "$1" in
          getcompatpath) printf '%s\\n' "$STEAM_COMPAT_DATA_PATH"; exit 0 ;;
        esac
        for app in \(quoted) "/Applications/FineWine.app" "$HOME/Applications/FineWine.app"; do
          if [ -x "$app/Contents/MacOS/FineWine" ]; then
            exec "$app/Contents/MacOS/FineWine" --steam-run "$@"
          fi
        done
        /usr/bin/osascript -e 'display alert "FineWine was not found" message "This Steam tool starts games with FineWine, which is no longer where it was. Open FineWine and install the Steam tool again from its settings."' >/dev/null 2>&1
        exit 1

        """
    }

    /// Writes the tool (again). Steam reads its tools folder when it starts, so a running
    /// Steam shows the tool after it is restarted.
    public func install(app: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data(Self.declaration.utf8).write(to: directory.appendingPathComponent("compatibilitytool.vdf"), options: .atomic)
        try Data(Self.manifest.utf8).write(to: directory.appendingPathComponent("toolmanifest.vdf"), options: .atomic)
        let run = directory.appendingPathComponent("run")
        try Data(Self.runScript(app: app).utf8).write(to: run, options: .atomic)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: run.path)
        try Data((app.path + "\n").utf8).write(to: directory.appendingPathComponent(Self.markerFile), options: .atomic)
    }

    /// Removes the tool: only the files FineWine wrote, and the folder if nothing else is in it.
    public func remove() throws {
        let fm = FileManager.default
        for file in ["compatibilitytool.vdf", "toolmanifest.vdf", "run", Self.markerFile] {
            let url = directory.appendingPathComponent(file)
            if fm.fileExists(atPath: url.path) { try fm.removeItem(at: url) }
        }
        if let left = try? fm.contentsOfDirectory(atPath: directory.path), left.isEmpty {
            try fm.removeItem(at: directory)
        }
    }
}

/// Valve's own Windows client files, which a game's `steam_api64.dll` loads from the Steam
/// folder in the prefix. They are Valve's: FineWine does not ship them. They are copied from
/// another tool's folder when one has exactly these files, or downloaded from Valve's servers,
/// and checked against the hashes below either way.
public struct ValveClientFiles: Sendable {
    public struct File: Equatable, Sendable {
        public var name: String
        public var package: String
        public var pathInPackage: String
        public var sha256: String
    }
    public struct Package: Equatable, Sendable {
        public var id: String
        public var fileName: String
        public var sha256: String
    }

    /// Valve's servers for client packages, tried in order.
    public static let servers = ["https://client-update.akamai.steamstatic.com",
                                 "https://steamcdn-a.akamaihd.net/client",
                                 "https://media.steampowered.com/client"]
    public static let packages = [
        Package(id: "linux", fileName: "bins_misc_ubuntu12.zip.3f92810725ee673827371a0470cd4f8c7ea8cfae",
                sha256: "026b984726c728bbf81ae3ba16623bcd96e2bf837a859c235acf0ee279d940fd"),
        Package(id: "win64", fileName: "bins_win64.zip.36f5d9202e79ab2aa3e3c5902e84bbd799d31fc0",
                sha256: "93f5b6bea0267fd85dc8cc823fdab5c5fb55d7f3a1deab0598acefef0e133bce"),
    ]
    public static let files = [
        File(name: "steamclient64.dll", package: "linux", pathInPackage: "steamclient64.dll",
             sha256: "caba4826aa3501039d095aee1843a6bfb270fb43a3ab4455b2d6733223579fee"),
        File(name: "steamclient.dll", package: "linux", pathInPackage: "legacycompat/steamclient.dll",
             sha256: "e9e961c914a418b6a3c597822bdc920bdea62c842ff42de23dc306331da563f8"),
        File(name: "tier0_s64.dll", package: "win64", pathInPackage: "tier0_s64.dll",
             sha256: "30f7bb8d9b86006852493c26124ba253bd9e7ffd40a8b3c7254f86a9032c3be3"),
        File(name: "vstdlib_s64.dll", package: "win64", pathInPackage: "vstdlib_s64.dll",
             sha256: "99efb4c2ad47f90c803b5ee0bd6424916b28facb9fa2568845b1b1f58a36062a"),
    ]

    public let directory: URL
    public var files: [File] = ValveClientFiles.files
    public var packages: [Package] = ValveClientFiles.packages
    /// Fetches a URL into a file. Replaced in tests.
    public var download: @Sendable (URL, URL) throws -> Void = ValveClientFiles.systemDownload

    public init(directory: URL) { self.directory = directory }

    public static func sha256(of url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try? handle.read(upToCount: 1 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// The files that are missing or are not the ones named above.
    public func missing() -> [File] {
        files.filter { Self.sha256(of: directory.appendingPathComponent($0.name)) != $0.sha256 }
    }
    public var isComplete: Bool { missing().isEmpty }

    /// Copies whichever missing files another tool already has, when they are exactly these.
    /// Returns how many were copied.
    @discardableResult
    public func adopt(from folders: [URL]) throws -> Int {
        let fm = FileManager.default
        var copied = 0
        for file in missing() {
            for folder in folders {
                let source = folder.appendingPathComponent(file.name)
                guard Self.sha256(of: source) == file.sha256 else { continue }
                try fm.createDirectory(at: directory, withIntermediateDirectories: true)
                let target = directory.appendingPathComponent(file.name)
                try? fm.removeItem(at: target)
                try fm.copyItem(at: source, to: target)
                copied += 1
                break
            }
        }
        return copied
    }

    /// Downloads the packages that hold the missing files from Valve, checks them, and takes
    /// the files out. `progress` is told what is being fetched.
    public func fetch(progress: (@Sendable (String) -> Void)? = nil) throws {
        let fm = FileManager.default
        let needed = missing()
        guard !needed.isEmpty else { return }
        let work = directory.appendingPathComponent(".fetch-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: work) }

        for package in packages where needed.contains(where: { $0.package == package.id }) {
            progress?(package.fileName)
            let archive = work.appendingPathComponent(package.id + ".zip")
            var lastError: Error = FineWineError(tr("steam.err_valve_download", package.fileName))
            var fetched = false
            for server in Self.servers {
                guard let url = URL(string: server + "/" + package.fileName) else { continue }
                do {
                    try? fm.removeItem(at: archive)
                    try download(url, archive)
                    guard Self.sha256(of: archive) == package.sha256 else {
                        lastError = FineWineError(tr("steam.err_valve_checksum", package.fileName))
                        continue
                    }
                    fetched = true
                    break
                } catch { lastError = error }
            }
            guard fetched else { throw lastError }

            for file in needed where file.package == package.id {
                let unzip = Process()
                unzip.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
                unzip.arguments = ["-q", "-o", archive.path, file.pathInPackage, "-d", work.appendingPathComponent(package.id).path]
                unzip.standardOutput = FileHandle.nullDevice
                unzip.standardError = FileHandle.nullDevice
                try unzip.run()
                unzip.waitUntilExit()
                let extracted = work.appendingPathComponent(package.id).appendingPathComponent(file.pathInPackage)
                guard Self.sha256(of: extracted) == file.sha256 else {
                    throw FineWineError(tr("steam.err_valve_checksum", file.name))
                }
                try fm.createDirectory(at: directory, withIntermediateDirectories: true)
                let target = directory.appendingPathComponent(file.name)
                try? fm.removeItem(at: target)
                try fm.moveItem(at: extracted, to: target)
            }
        }
    }

    /// Makes sure the files are there: from another tool's copy if it has them, else from Valve.
    public func ensure(adoptingFrom folders: [URL], progress: (@Sendable (String) -> Void)? = nil) throws {
        if isComplete { return }
        try adopt(from: folders)
        if isComplete { return }
        try fetch(progress: progress)
    }

    public static func systemDownload(_ url: URL, to file: URL) throws {
        let done = DispatchSemaphore(value: 0)
        let result = LockedBox<Result<Void, Error>>(.failure(FineWineError("The download did not finish.")))
        let task = URLSession.shared.downloadTask(with: url) { location, response, error in
            defer { done.signal() }
            if let error { result.set(.failure(error)); return }
            guard let location, (response as? HTTPURLResponse)?.statusCode == 200 else {
                result.set(.failure(FineWineError("The server answered \((response as? HTTPURLResponse)?.statusCode ?? 0) for \(url.lastPathComponent).")))
                return
            }
            do {
                try? FileManager.default.removeItem(at: file)
                try FileManager.default.moveItem(at: location, to: file)
                result.set(.success(()))
            } catch { result.set(.failure(error)) }
        }
        task.resume()
        done.wait()
        try result.get().get()
    }
}

final class LockedBox<Value>: @unchecked Sendable {
    private var value: Value
    private let lock = NSLock()
    init(_ value: Value) { self.value = value }
    func set(_ new: Value) { lock.lock(); value = new; lock.unlock() }
    func get() -> Value { lock.lock(); defer { lock.unlock() }; return value }
}

extension WineRuntime {
    /// The runtime's bridge to the Mac's Steam (`scripts/build-steam-bridge.sh`), if it has one.
    public var steamBridge: URL? {
        let folder = root.appendingPathComponent("lib/steam-bridge", isDirectory: true)
        let fm = FileManager.default
        guard fm.fileExists(atPath: folder.appendingPathComponent("wine/lsteamclient.dll").path),
              fm.fileExists(atPath: folder.appendingPathComponent("wine/lsteamclient.so").path),
              fm.fileExists(atPath: folder.appendingPathComponent("steam/steam.exe").path) else { return nil }
        return folder
    }
}

extension FineWinePaths {
    /// What FineWine keeps for Steam: Valve's Windows client files.
    public var steam: URL { root.appendingPathComponent("Steam", isDirectory: true) }
    public var valveClientFiles: URL { steam.appendingPathComponent("valve", isDirectory: true) }
}

/// One launch asked for by Steam: `run <verb> <program> [arguments…]`, with what Steam says
/// about the game in the environment.
public struct SteamRun: Equatable, Sendable {
    public enum Verb: String, Sendable { case run, waitForExitAndRun = "waitforexitandrun" }

    public var verb: Verb
    public var appID: String
    public var executable: URL
    public var arguments: [String]
    public var installPath: URL?
    public var environment: [String: String]

    /// The switch the loader looks for before it sends Steam's client library to the bridge.
    public static let bridgeVariable = "FINEWINE_STEAM_BRIDGE"
    /// The name lsteamclient reads the overlay helper's path from (NotProton's port, unchanged).
    public static let overlayShimVariable = "NOTPROTON_OVERLAY_SHIM"
    public static let steamFolderInPrefix = "drive_c/Program Files (x86)/Steam"
    public static let helperWindowsPath = #"C:\Program Files (x86)\Steam\steam.exe"#

    /// Reads a launch from the tool's arguments. `nil` for a verb that starts nothing.
    public static func parse(arguments: [String], environment: [String: String]) throws -> SteamRun? {
        guard let first = arguments.first, let verb = Verb(rawValue: first) else { return nil }
        guard arguments.count >= 2 else { throw FineWineError(tr("steam.err_no_program")) }
        guard let appID = [environment["SteamAppId"], environment["STEAM_COMPAT_APP_ID"], environment["SteamGameId"]]
            .compactMap({ $0 }).first(where: { !$0.isEmpty && $0.allSatisfy(\.isNumber) }) else {
            throw FineWineError(tr("steam.err_no_app_id"))
        }
        return SteamRun(verb: verb, appID: appID, executable: URL(fileURLWithPath: arguments[1]),
                        arguments: Array(arguments.dropFirst(2)),
                        installPath: environment["STEAM_COMPAT_INSTALL_PATH"].map { URL(fileURLWithPath: $0, isDirectory: true) },
                        environment: environment)
    }

    /// The variables Steam sets for a game that have to reach it: who and what is running,
    /// where the Mac client is, and the overlay's libraries.
    public var steamEnvironment: [String: String] {
        environment.filter { name, _ in
            name.hasPrefix("Steam") || name.hasPrefix("STEAM") || name.hasPrefix("ENABLE_VK_LAYER_VALVE")
        }
    }

    /// A prefix name for the game that the store accepts and that is free.
    static func prefixName(for game: String?, appID: String, taken: [String]) -> String {
        let cleaned = (game ?? "").components(separatedBy: CharacterSet(charactersIn: "/:\\\n\r")).joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)
        let base = cleaned.isEmpty ? "Steam \(appID)" : cleaned
        let isTaken = { (name: String) in taken.contains { $0.caseInsensitiveCompare(name) == .orderedSame } }
        if !isTaken(base) { return base }
        if !isTaken(base + " (Steam)") { return base + " (Steam)" }
        var n = 2
        while isTaken("\(base) (Steam \(n))") { n += 1 }
        return "\(base) (Steam \(n))"
    }
}

extension PrefixService {
    /// The prefix a Steam game runs in, if it has been started before.
    public func steamPrefix(appID: String) -> Prefix? {
        prefixes.list().first { $0.metadata.steamAppID == appID }
    }

    /// The runtime new Steam prefixes get: the first usable one that has the bridge.
    public func steamRuntime() -> WineRuntime? {
        runtimes.list().first { $0.problems().isEmpty && $0.steamBridge != nil }
    }

    /// Finds the game's prefix or makes one, named after the game, and lists the game in it.
    public func prepareSteamPrefix(for run: SteamRun, client: SteamClient,
                                   progress: (@Sendable (String) -> Void)? = nil) throws -> (prefix: Prefix, program: Program) {
        var prefix: Prefix
        if let existing = steamPrefix(appID: run.appID) {
            prefix = existing
        } else {
            guard let runtime = steamRuntime() else { throw FineWineError(tr("steam.err_no_runtime")) }
            let game = client.appName(appID: run.appID, installPath: run.installPath)
            let name = SteamRun.prefixName(for: game, appID: run.appID, taken: prefixes.list().map(\.name))
            prefix = try createPrefix(name: name, runtime: runtime, profile: nil, progress: progress)
            prefix.metadata.steamAppID = run.appID
            try prefixes.save(prefix)
        }
        let windowsPath = WindowsPath.windowsPath(for: run.executable, inPrefix: prefix.directory)
        if let program = prefix.metadata.programs.first(where: {
            $0.windowsPath.caseInsensitiveCompare(windowsPath) == .orderedSame }) {
            return (prefix, program)
        }
        let name = client.appName(appID: run.appID, installPath: run.installPath)
            ?? run.executable.deletingPathExtension().lastPathComponent
        let program = Program(name: name, windowsPath: windowsPath)
        prefix = try addProgram(program, to: prefix)
        return (prefix, prefix.metadata.programs.first { $0.id == program.id } ?? program)
    }

    /// Puts what the game needs to find Steam into the prefix's Steam folder: the bridge's
    /// Windows half (Wine only loads it from a file) with the helper, and Valve's client files.
    public func stageSteamBridge(from runtime: WineRuntime, valve: ValveClientFiles, in prefix: Prefix) throws {
        guard let bridge = runtime.steamBridge else { throw FineWineError(tr("steam.err_no_runtime")) }
        let fm = FileManager.default
        let folder = prefix.directory.appendingPathComponent(SteamRun.steamFolderInPrefix, isDirectory: true)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let sources = ((try? fm.contentsOfDirectory(at: bridge.appendingPathComponent("steam"), includingPropertiesForKeys: nil)) ?? [])
            + valve.files.map { valve.directory.appendingPathComponent($0.name) }
        for source in sources {
            let target = folder.appendingPathComponent(source.lastPathComponent)
            if fm.contentsEqual(atPath: source.path, andPath: target.path) { continue }
            try? fm.removeItem(at: target)
            try fm.copyItem(at: source, to: target)
        }
        // 32-bit games load the 32-bit bridge. It has the same file name as the 64-bit one, so
        // it goes where only 32-bit programs look: the prefix's 32-bit system folder.
        let bridge32 = bridge.appendingPathComponent("wine/i386-windows/lsteamclient.dll")
        let system32Bit = prefix.directory.appendingPathComponent("drive_c/windows/syswow64", isDirectory: true)
        if fm.fileExists(atPath: bridge32.path), fm.fileExists(atPath: system32Bit.path) {
            let target = system32Bit.appendingPathComponent("lsteamclient.dll")
            if !fm.contentsEqual(atPath: bridge32.path, andPath: target.path) {
                try? fm.removeItem(at: target)
                try fm.copyItem(at: bridge32, to: target)
            }
        }
    }

    /// How the game is started: through the helper, with the prefix's settings, Steam's own
    /// variables and the bridge switched on.
    public func steamLaunchPlan(for run: SteamRun, program: Program, in prefix: Prefix) throws -> LaunchPlan {
        let planner = try planner(for: prefix)
        guard let bridge = planner.runtime.steamBridge else { throw FineWineError(tr("steam.err_no_runtime")) }
        let base = try planner.plan(for: program)
        var arguments = base.arguments
        // A game FineWine would start through its stand-in for Steam has the real one here.
        if arguments.first == SteamStandIn.windowsPath { arguments.removeFirst() }
        arguments.insert(SteamRun.helperWindowsPath, at: 0)
        arguments += run.arguments

        var env = base.environment
        for (name, value) in run.steamEnvironment { env[name] = value }
        let bridgePath = bridge.appendingPathComponent("wine").path
        env["WINEDLLPATH"] = [env["WINEDLLPATH"], bridgePath].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: ":")
        env[SteamRun.bridgeVariable] = "1"
        // What Steam starts is a game, whichever of its files draws: see LaunchPlanner.dpiAwareEnvironment.
        if env[LaunchPlanner.dpiAwareVariable] == nil { env[LaunchPlanner.dpiAwareVariable] = "1" }
        // The bridge loads Steam's overlay library into the game (Steam names it in
        // STEAM_DYLD_INSERT_LIBRARIES) together with this helper for it, when the runtime has one.
        let shim = bridge.appendingPathComponent("overlay-shim.dylib")
        if FileManager.default.fileExists(atPath: shim.path) { env[SteamRun.overlayShimVariable] = shim.path }
        return LaunchPlan(executable: base.executable, arguments: arguments, environment: env,
                          workingDirectory: run.executable.deletingLastPathComponent())
    }

    /// Runs a game for Steam and waits for it. Returns the game's exit status.
    public func runForSteam(_ run: SteamRun, client: SteamClient = .standard(),
                            log: (@Sendable (String) -> Void)? = nil) throws -> Int32 {
        log?("app \(run.appID): \(run.executable.path)")
        let (prefix, program) = try prepareSteamPrefix(for: run, client: client) { log?($0) }
        let runtime = try self.runtime(for: prefix)
        guard runtime.steamBridge != nil else { throw FineWineError(tr("steam.err_no_runtime")) }
        log?("prefix “\(prefix.name)”, runtime \(runtime.name)")

        let valve = ValveClientFiles(directory: paths.valveClientFiles)
        try valve.ensure(adoptingFrom: client.valveFileSources) { log?("fetching \($0) from Valve") }
        try stageSteamBridge(from: runtime, valve: valve, in: prefix)

        let planner = try planner(for: prefix)
        try? FileManager.default.createDirectory(at: planner.gameMarker(for: program).deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        keepDesktopInPrefix(prefix)
        refreshEmulator(in: prefix, from: runtime)

        let plan = try steamLaunchPlan(for: run, program: program, in: prefix)
        let done = DispatchSemaphore(value: 0)
        let status = LockedBox<Int32>(0)
        _ = try runner.start(plan, logFile: logFile(for: prefix, name: program.name)) { code in
            status.set(code)
            done.signal()
        }
        done.wait()
        log?("the program ended with \(status.get())")
        // Steam counts the game as running until this returns: wait for everything it started.
        if run.verb == .waitForExitAndRun, let server = runtime.wineserverBinary {
            _ = try? runner.run(LaunchPlan(executable: server, arguments: ["-w"], environment: plan.environment,
                                           workingDirectory: prefix.directory))
        }
        return status.get()
    }
}
