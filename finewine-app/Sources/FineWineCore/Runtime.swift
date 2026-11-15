import Foundation

/// How a runtime provides one graphics backend: a folder of DLLs to put on Wine's DLL search
/// path, and the load order for each of them.
public struct GraphicsBackendSpec: Codable, Equatable, Sendable {
    /// Folder holding the backend's Wine DLL tree, relative to the runtime root (`lib/dxmt`).
    public var dllPath: String
    /// DLL name → load order in `WINEDLLOVERRIDES` form (`n,b`).
    public var overrides: [String: String]

    public init(dllPath: String, overrides: [String: String]) {
        self.dllPath = dllPath
        self.overrides = overrides
    }
}

/// `runtime.json` at the root of a FineWine runtime.
public struct RuntimeManifest: Codable, Equatable, Sendable {
    public var id: String
    public var name: String
    /// FineWine's own version of this runtime build.
    public var version: String
    /// The Wine release it is based on.
    public var wineVersion: String
    /// The Mac-side architecture, e.g. `arm64`.
    public var architecture: String
    /// Graphics backends the runtime ships, keyed by `GraphicsBackend` raw value.
    public var graphics: [String: GraphicsBackendSpec]

    public init(id: String, name: String, version: String, wineVersion: String,
                architecture: String = "arm64", graphics: [String: GraphicsBackendSpec] = [:]) {
        self.id = id
        self.name = name
        self.version = version
        self.wineVersion = wineVersion
        self.architecture = architecture
        self.graphics = graphics
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? id
        version = try c.decodeIfPresent(String.self, forKey: .version) ?? ""
        wineVersion = try c.decodeIfPresent(String.self, forKey: .wineVersion) ?? ""
        architecture = try c.decodeIfPresent(String.self, forKey: .architecture) ?? "arm64"
        graphics = try c.decodeIfPresent([String: GraphicsBackendSpec].self, forKey: .graphics) ?? [:]
    }
}

/// A Wine build FineWine can run programs with.
public struct WineRuntime: Equatable, Identifiable, Sendable {
    public enum Kind: String, Sendable {
        /// Installed under FineWine's own Runtimes folder.
        case managed
        /// The runtime inside FineWine.app itself. It is always there and cannot be removed.
        case bundled
        /// A Wine folder elsewhere on disk that the user pointed FineWine at.
        case external
    }

    public var manifest: RuntimeManifest
    public var root: URL
    public var kind: Kind

    public var id: String { manifest.id }
    public var name: String { manifest.name }

    public init(manifest: RuntimeManifest, root: URL, kind: Kind) {
        self.manifest = manifest
        self.root = root
        self.kind = kind
    }

    public static let wineBinaryNames = ["wine", "wine64"]
    public static let serverBinaryNames = ["wineserver", "wineserver-arm64"]

    public var binDirectory: URL { root.appendingPathComponent("bin", isDirectory: true) }

    /// The `wine` loader, if the runtime has one.
    public var wineBinary: URL? {
        Self.wineBinaryNames.map { binDirectory.appendingPathComponent($0) }
            .first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    /// The copy of Wine's loader that macOS treats as a game: it is inside an app bundle whose
    /// Info.plist says so, beside the usual loader. The path is relative to the loader's folder.
    public static let gameLoaderName = "FineWine Game.app/Contents/MacOS/wine-game"

    /// Whether this runtime has that copy. Without it programs still run, just never in Game Mode.
    public var hasGameLoader: Bool {
        FileManager.default.isExecutableFile(
            atPath: root.appendingPathComponent("lib/wine/aarch64-unix/\(Self.gameLoaderName)").path)
    }

    /// The stand-in for the Steam client, if this runtime has it.
    public var steamStandIn: URL? {
        let url = root.appendingPathComponent(SteamStandIn.runtimePath)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    public var wineserverBinary: URL? {
        Self.serverBinaryNames.map { binDirectory.appendingPathComponent($0) }
            .first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    /// Reasons this runtime can't be used; empty when it looks complete.
    public func problems() -> [String] {
        var problems: [String] = []
        if wineBinary == nil { problems.append("bin/wine is missing or not executable.") }
        if wineserverBinary == nil { problems.append("bin/wineserver is missing or not executable.") }
        var isDir: ObjCBool = false
        let lib = root.appendingPathComponent("lib/wine").path
        if !FileManager.default.fileExists(atPath: lib, isDirectory: &isDir) || !isDir.boolValue {
            problems.append("lib/wine is missing.")
        }
        return problems
    }

    public var isUsable: Bool { problems().isEmpty }

    public func graphicsSpec(for backend: GraphicsBackend) -> GraphicsBackendSpec? {
        manifest.graphics[backend.rawValue]
    }
}

/// Finds, adds and removes runtimes.
public struct RuntimeStore {
    public static let manifestName = "runtime.json"

    /// The folder of the runtime built into the app, inside its Resources.
    public static let bundledFolderName = "Runtime"

    public let paths: FineWinePaths
    /// Where the built-in runtime is, if the app has one.
    public let bundledRoot: URL?
    private let fm = FileManager.default

    /// `bundledRoot` defaults to the running app's own; a development build run outside an app
    /// bundle, and the tests, have none.
    public init(paths: FineWinePaths,
                bundledRoot: URL? = Bundle.main.resourceURL?.appendingPathComponent(RuntimeStore.bundledFolderName, isDirectory: true)) {
        self.paths = paths
        self.bundledRoot = bundledRoot
    }

    /// The runtime built into the app.
    public var bundled: WineRuntime? {
        guard let root = bundledRoot, let manifest = Self.readManifest(in: root) else { return nil }
        return WineRuntime(manifest: manifest, root: root, kind: .bundled)
    }

    /// The built-in runtime first, then managed ones, then external ones, each sorted by name.
    /// The first usable one is what a new prefix gets. An installed runtime with the built-in
    /// one's id is left out: the one in the app is the one that is used.
    public func list() -> [WineRuntime] {
        let all = listInstalled()
        guard let bundled else { return all }
        return [bundled] + all.filter { $0.id != bundled.id }
    }

    private func listInstalled() -> [WineRuntime] {
        var managed: [WineRuntime] = []
        let dirs = (try? fm.contentsOfDirectory(at: paths.runtimes, includingPropertiesForKeys: nil)) ?? []
        for dir in dirs {
            guard let manifest = Self.readManifest(in: dir) else { continue }
            managed.append(WineRuntime(manifest: manifest, root: dir, kind: .managed))
        }
        let external = externalPaths().map { path -> WineRuntime in
            let root = URL(fileURLWithPath: path, isDirectory: true)
            let manifest = Self.readManifest(in: root) ?? Self.inferredManifest(for: root)
            return WineRuntime(manifest: manifest, root: root, kind: .external)
        }
        let byName: (WineRuntime, WineRuntime) -> Bool = {
            $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
        return managed.sorted(by: byName) + external.sorted(by: byName)
    }

    public func runtime(id: String) -> WineRuntime? { list().first { $0.id == id } }

    static func readManifest(in dir: URL) -> RuntimeManifest? {
        guard let data = try? Data(contentsOf: dir.appendingPathComponent(manifestName)) else { return nil }
        return try? JSONDecoder().decode(RuntimeManifest.self, from: data)
    }

    /// A manifest for a plain Wine folder that has no `runtime.json`.
    static func inferredManifest(for root: URL) -> RuntimeManifest {
        RuntimeManifest(id: "external:" + root.standardizedFileURL.path,
                        name: root.lastPathComponent, version: "", wineVersion: "")
    }

    // MARK: External runtimes

    public func externalPaths() -> [String] {
        guard let data = try? Data(contentsOf: paths.externalRuntimes),
              let list = try? JSONDecoder().decode([String].self, from: data) else { return [] }
        return list
    }

    /// Registers a Wine folder that stays where it is. Throws if it doesn't look like Wine.
    @discardableResult
    public func addExternal(_ root: URL) throws -> WineRuntime {
        let root = root.standardizedFileURL
        let manifest = Self.readManifest(in: root) ?? Self.inferredManifest(for: root)
        let runtime = WineRuntime(manifest: manifest, root: root, kind: .external)
        let problems = runtime.problems()
        guard problems.isEmpty else {
            throw FineWineError("“\(root.lastPathComponent)” is not a usable Wine runtime: " + problems.joined(separator: " "))
        }
        var list = externalPaths()
        if !list.contains(root.path) { list.append(root.path) }
        try writeExternal(list)
        return runtime
    }

    public func removeExternal(_ root: URL) throws {
        try writeExternal(externalPaths().filter { $0 != root.standardizedFileURL.path })
    }

    private func writeExternal(_ list: [String]) throws {
        try paths.ensureDirectories()
        try JSONEncoder().encode(list).write(to: paths.externalRuntimes, options: .atomic)
    }

    // MARK: Managed runtimes

    /// Installs a runtime from an unpacked folder that has a `runtime.json`, by copying it into
    /// the Runtimes folder. A runtime with the same id is replaced.
    @discardableResult
    public func installManaged(from source: URL) throws -> WineRuntime {
        guard let manifest = Self.readManifest(in: source) else {
            throw FineWineError("“\(source.lastPathComponent)” has no runtime.json, so it isn't a FineWine runtime.")
        }
        guard Self.isSafeIdentifier(manifest.id) else {
            throw FineWineError("The runtime's id “\(manifest.id)” can't be used as a folder name.")
        }
        try paths.ensureDirectories()
        let destination = paths.runtimes.appendingPathComponent(manifest.id, isDirectory: true)
        let staging = paths.runtimes.appendingPathComponent(".installing-\(UUID().uuidString)", isDirectory: true)
        try fm.copyItem(at: source, to: staging)
        if fm.fileExists(atPath: destination.path) { try fm.removeItem(at: destination) }
        try fm.moveItem(at: staging, to: destination)
        return WineRuntime(manifest: manifest, root: destination, kind: .managed)
    }

    public func removeManaged(id: String) throws {
        guard Self.isSafeIdentifier(id) else { throw FineWineError("“\(id)” is not a managed runtime.") }
        let dir = paths.runtimes.appendingPathComponent(id, isDirectory: true)
        guard fm.fileExists(atPath: dir.path) else { return }
        try fm.removeItem(at: dir)
    }

    /// Letters, digits, dot, dash and underscore only — safe as a single path component.
    static func isSafeIdentifier(_ id: String) -> Bool {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")
        return !id.isEmpty && id != "." && id != ".." && id.unicodeScalars.allSatisfy(allowed.contains)
    }
}
