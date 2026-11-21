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

/// A FineWine feature that needs support inside the runtime. A runtime that lists its
/// capabilities gets only those; the prefix settings for the rest are greyed out and nothing is
/// passed to the runtime for them. See docs/finewine-runtime-format.md.
public enum RuntimeCapability: String, CaseIterable, Codable, Sendable {
    /// MetalFX upscaling of a small picture, the render size, and the menu switch for it.
    case upscaling
    /// DLSS calls carried out by MetalFX.
    case dlss
    /// Reporting the GPU under other ids (`FINEWINE_GPU_*`).
    case gpuIdentity
    /// The choice of how a program goes full screen.
    case fullScreenModes
    case roundedWindows
    /// A second loader inside an app bundle that macOS takes for a game.
    case gameMode
    /// The stand-in for the Steam client.
    case steamStandIn
    /// Showing and hiding Metal's overlay while a program runs.
    case metalHUD
    /// MSync, the Mach-semaphore synchronisation.
    case msync
    /// FineWine's FEX and the settings it reads (`FEX_*`).
    case emulator
    case zeroPages
    /// Windows icons redrawn in the Mac's shape for the Dock.
    case macIcons
}

/// `runtime.json`: the description of a Wine build FineWine can run programs with. In a
/// FineWine runtime it is at the root of the build; for any other Wine build it can be alone in
/// a folder and say where the build is (`root`) and how it is started.
public struct RuntimeManifest: Codable, Equatable, Sendable {
    /// The newest `formatVersion` this app understands.
    public static let currentFormat = 2

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

    // What follows is format 2. Every field can be left out, and a description without them
    // means what it always did.

    /// The format the description is written in; a description for a newer app is refused.
    public var formatVersion: Int?
    /// Where the Wine build is, when it is not the folder of this file: an absolute path, or
    /// one starting with `~/`.
    public var root: String?
    /// The program that starts Wine, relative to the build (default `bin/wine`).
    public var loader: String?
    /// The Wine server, relative to the build (default `bin/wineserver`).
    public var server: String?
    /// Folders of Mac libraries, relative to the build (default `lib`).
    public var libraryPath: [String]?
    /// Variables every process gets. `${root}`, `${prefix}`, `${folder}` and `${home}` in a
    /// value are replaced. A prefix's own variables are set after these.
    public var environment: [String: String]?
    /// The FineWine features the runtime has (`RuntimeCapability`). Left out: all of them.
    public var capabilities: [String]?
    /// The arguments the loader sets a new prefix up with (default `wineboot --init`).
    public var prefixSetup: [String]?

    public init(id: String, name: String, version: String, wineVersion: String,
                architecture: String = "arm64", graphics: [String: GraphicsBackendSpec] = [:],
                formatVersion: Int? = nil, root: String? = nil, loader: String? = nil, server: String? = nil,
                libraryPath: [String]? = nil, environment: [String: String]? = nil,
                capabilities: [String]? = nil, prefixSetup: [String]? = nil) {
        self.id = id
        self.name = name
        self.version = version
        self.wineVersion = wineVersion
        self.architecture = architecture
        self.graphics = graphics
        self.formatVersion = formatVersion
        self.root = root
        self.loader = loader
        self.server = server
        self.libraryPath = libraryPath
        self.environment = environment
        self.capabilities = capabilities
        self.prefixSetup = prefixSetup
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? id
        version = try c.decodeIfPresent(String.self, forKey: .version) ?? ""
        wineVersion = try c.decodeIfPresent(String.self, forKey: .wineVersion) ?? ""
        architecture = try c.decodeIfPresent(String.self, forKey: .architecture) ?? "arm64"
        graphics = try c.decodeIfPresent([String: GraphicsBackendSpec].self, forKey: .graphics) ?? [:]
        formatVersion = try c.decodeIfPresent(Int.self, forKey: .formatVersion)
        root = try c.decodeIfPresent(String.self, forKey: .root)
        loader = try c.decodeIfPresent(String.self, forKey: .loader)
        server = try c.decodeIfPresent(String.self, forKey: .server)
        libraryPath = try c.decodeIfPresent([String].self, forKey: .libraryPath)
        environment = try c.decodeIfPresent([String: String].self, forKey: .environment)
        capabilities = try c.decodeIfPresent([String].self, forKey: .capabilities)
        prefixSetup = try c.decodeIfPresent([String].self, forKey: .prefixSetup)
    }

    /// Variables a description may not set: FineWine finds a prefix's processes by them.
    public static let reservedVariables = ["WINEPREFIX"]

    /// A path inside the build: relative, and not leading out of it.
    static func isInsidePath(_ path: String) -> Bool {
        !path.isEmpty && !path.hasPrefix("/") && !path.hasPrefix("~") && !path.split(separator: "/").contains("..")
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
    /// The folder the description is in (or, without one, the folder that was added). It is
    /// the Wine build too unless the description names another place.
    public var folder: URL
    public var kind: Kind

    public var id: String { manifest.id }
    public var name: String { manifest.name }

    /// `root` is the runtime's folder; the Wine build is there unless its description says
    /// otherwise.
    public init(manifest: RuntimeManifest, root: URL, kind: Kind) {
        self.manifest = manifest
        self.folder = root
        self.kind = kind
    }

    /// The Wine build: what the description names, or the runtime's own folder.
    public var root: URL {
        guard let named = manifest.root, !named.isEmpty else { return folder }
        return URL(fileURLWithPath: (named as NSString).expandingTildeInPath, isDirectory: true)
    }

    public static let wineBinaryNames = ["wine", "wine64"]
    public static let serverBinaryNames = ["wineserver", "wineserver-arm64"]

    /// The folder of the loader, where Wine's other tools are.
    public var binDirectory: URL {
        if let loader = manifest.loader, RuntimeManifest.isInsidePath(loader) {
            return root.appendingPathComponent(loader).deletingLastPathComponent()
        }
        return root.appendingPathComponent("bin", isDirectory: true)
    }

    private func executable(named: String?, defaults: [String]) -> URL? {
        if let named {
            guard RuntimeManifest.isInsidePath(named) else { return nil }
            let url = root.appendingPathComponent(named)
            return FileManager.default.isExecutableFile(atPath: url.path) ? url : nil
        }
        return defaults.map { root.appendingPathComponent("bin/\($0)") }
            .first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    /// The `wine` loader, if the runtime has one.
    public var wineBinary: URL? { executable(named: manifest.loader, defaults: Self.wineBinaryNames) }

    /// The folders of Mac libraries the runtime's programs look in.
    public var libraryDirectories: [URL] {
        (manifest.libraryPath ?? ["lib"]).filter(RuntimeManifest.isInsidePath)
            .map { root.appendingPathComponent($0, isDirectory: true) }
    }

    /// Whether the runtime has a FineWine feature. One that does not list its capabilities is
    /// taken to have them all, as every runtime before the list existed did; a plain Wine
    /// folder with no description has none.
    public func supports(_ capability: RuntimeCapability) -> Bool {
        manifest.capabilities.map { $0.contains(capability.rawValue) } ?? true
    }

    public var capabilities: Set<RuntimeCapability> { Set(RuntimeCapability.allCases.filter(supports)) }

    /// A value from the description with its placeholders filled in.
    public func expand(_ value: String, prefix: URL) -> String {
        value.replacingOccurrences(of: "${root}", with: root.path)
            .replacingOccurrences(of: "${folder}", with: folder.path)
            .replacingOccurrences(of: "${prefix}", with: prefix.path)
            .replacingOccurrences(of: "${home}", with: NSHomeDirectory())
    }

    /// The copy of Wine's loader that macOS treats as a game: it is inside an app bundle whose
    /// Info.plist says so, beside the usual loader. The path is relative to the loader's folder.
    public static let gameLoaderName = "FineWine Game.app/Contents/MacOS/wine-game"

    /// Whether this runtime has that copy. Without it programs still run, just never in Game Mode.
    /// Whether the runtime can run 32-bit Windows programs: it has the 32-bit Windows side and
    /// the emulator's 32-bit front end (runtime patch 0043, FEX patch 0011).
    public var runs32BitPrograms: Bool {
        let fm = FileManager.default
        return fm.fileExists(atPath: root.appendingPathComponent("lib/wine/i386-windows/ntdll.dll").path)
            && fm.fileExists(atPath: root.appendingPathComponent("lib/wine/aarch64-windows/xtajit.dll").path)
    }

    public var hasGameLoader: Bool {
        FileManager.default.isExecutableFile(
            atPath: root.appendingPathComponent("lib/wine/aarch64-unix/\(Self.gameLoaderName)").path)
    }

    /// The stand-in for the Steam client, if this runtime has it.
    public var steamStandIn: URL? {
        let url = root.appendingPathComponent(SteamStandIn.runtimePath)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    public var wineserverBinary: URL? { executable(named: manifest.server, defaults: Self.serverBinaryNames) }

    /// Whether this folder is CrossOver's (or a part of it) and not a Wine build of its own.
    /// CrossOver's `bin/wine` is a script that only works with CrossOver's bottles: started for
    /// a FineWine prefix it ignores the prefix and fails with "Unable to find the 'default'
    /// bottle". Its Wine also depends on the rest of CrossOver, so FineWine cannot use it.
    public var isCrossOver: Bool {
        let fm = FileManager.default
        if ["bin/cxbottle", "lib/perl/CXBottle.pm", "etc/CrossOver.conf"].contains(where: {
            fm.fileExists(atPath: root.appendingPathComponent($0).path)
        }) { return true }
        return root.resolvingSymlinksInPath().pathComponents.contains {
            $0.hasSuffix(".app") && $0.lowercased().hasPrefix("crossover")
        }
    }

    /// Reasons this runtime can't be used; empty when it looks complete.
    public func problems() -> [String] {
        if let format = manifest.formatVersion, format > RuntimeManifest.currentFormat {
            return [tr("runtime_problem.newer_format")]
        }
        if let named = manifest.root, !named.isEmpty {
            guard named.hasPrefix("/") || named.hasPrefix("~/") else { return [tr("runtime_problem.bad_path", named)] }
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: root.path, isDirectory: &isDir), isDir.boolValue else {
                return [tr("runtime_problem.root_missing", root.path)]
            }
        }
        // CrossOver's own way in (bin/wine) cannot be used; a description that names another
        // loader in it has said how it is to be started instead.
        if isCrossOver, manifest.loader == nil { return [tr("runtime_problem.crossover")] }
        var problems: [String] = []
        for path in [manifest.loader, manifest.server].compactMap({ $0 }) + (manifest.libraryPath ?? [])
        where !RuntimeManifest.isInsidePath(path) {
            problems.append(tr("runtime_problem.bad_path", path))
        }
        for name in (manifest.environment ?? [:]).keys.sorted()
        where RuntimeManifest.reservedVariables.contains(name) || !EnvironmentVariable.isValidName(name) {
            problems.append(tr("runtime_problem.bad_variable", name))
        }
        if wineBinary == nil {
            problems.append(manifest.loader.map { tr("runtime_problem.named_missing", $0) } ?? tr("runtime_problem.wine_missing"))
        }
        if wineserverBinary == nil {
            problems.append(manifest.server.map { tr("runtime_problem.named_missing", $0) } ?? tr("runtime_problem.wineserver_missing"))
        }
        var isDir: ObjCBool = false
        let lib = root.appendingPathComponent("lib/wine").path
        if !FileManager.default.fileExists(atPath: lib, isDirectory: &isDir) || !isDir.boolValue {
            problems.append(tr("runtime_problem.lib_missing"))
        }
        return problems
    }

    public var isUsable: Bool { problems().isEmpty }

    public func graphicsSpec(for backend: GraphicsBackend) -> GraphicsBackendSpec? {
        manifest.graphics[backend.rawValue]
    }

    /// The entry of `runtime.json`'s graphics list for DXVK's Direct3D 9 (scripts/build-dxvk.sh).
    public static let direct3D9OnVulkanKey = "dxvk-d3d9"
    /// Where the runtime keeps DXVK's Direct3D 9, if it has it: what the prefix setting
    /// "Direct3D 9 and older on Vulkan" needs.
    public var direct3D9OnVulkanSpec: GraphicsBackendSpec? { manifest.graphics[Self.direct3D9OnVulkanKey] }
}

/// Finds, adds and removes runtimes.
public struct RuntimeStore {
    public static let manifestName = "runtime.json"

    /// The folder of the runtime built into the app, inside its Resources.
    public static let bundledFolderName = "Runtime"

    public let paths: FineWinePaths
    /// Where the built-in runtime is, if the app has one.
    public let bundledRoot: URL?
    public let volumes: VolumeProviding
    private let fm = FileManager.default

    /// `bundledRoot` defaults to the running app's own; a development build run outside an app
    /// bundle, and the tests, have none.
    public init(paths: FineWinePaths,
                bundledRoot: URL? = Bundle.main.resourceURL?.appendingPathComponent(RuntimeStore.bundledFolderName, isDirectory: true),
                volumes: VolumeProviding = SystemVolumes()) {
        self.paths = paths
        self.bundledRoot = bundledRoot
        self.volumes = volumes
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
        var seenPaths = Set<String>()
        let dirs = (try? fm.contentsOfDirectory(at: paths.runtimes, includingPropertiesForKeys: nil)) ?? []
        for dir in dirs {
            guard let manifest = Self.readManifest(in: dir) else { continue }
            managed.append(WineRuntime(manifest: manifest, root: dir, kind: .managed))
            seenPaths.insert(dir.resolvingSymlinksInPath().path)
        }
        var externalMap: [String: WineRuntime] = [:]
        for path in externalPaths() {
            let root = URL(fileURLWithPath: path, isDirectory: true)
            let resPath = root.resolvingSymlinksInPath().path
            guard !seenPaths.contains(resPath) else { continue }
            let manifest = Self.readManifest(in: root) ?? Self.inferredManifest(for: root)
            externalMap[resPath] = WineRuntime(manifest: manifest, root: root, kind: .external)
            seenPaths.insert(resPath)
        }

        // Also discover runtimes on mounted volumes in <volume>/FineWine/Runtimes
        let mountedVolumes = volumes.mounted().filter { $0.root.standardizedFileURL.path != "/" }
        for vol in mountedVolumes {
            let driveRuntimesDir = Self.runtimesFolder(on: vol)
            let subdirs = (try? fm.contentsOfDirectory(at: driveRuntimesDir, includingPropertiesForKeys: nil)) ?? []
            for sub in subdirs {
                let resPath = sub.resolvingSymlinksInPath().path
                if !seenPaths.contains(resPath) {
                    if let manifest = Self.readManifest(in: sub) {
                        externalMap[resPath] = WineRuntime(manifest: manifest, root: sub, kind: .external)
                        seenPaths.insert(resPath)
                    }
                }
            }
        }

        let byName: (WineRuntime, WineRuntime) -> Bool = {
            $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
        return managed.sorted(by: byName) + Array(externalMap.values).sorted(by: byName)
    }

    public func runtime(id: String) -> WineRuntime? { list().first { $0.id == id } }

    static func readManifest(in dir: URL) -> RuntimeManifest? {
        guard let data = try? Data(contentsOf: dir.appendingPathComponent(manifestName)) else { return nil }
        return try? JSONDecoder().decode(RuntimeManifest.self, from: data)
    }

    /// A manifest for a plain Wine folder that has no `runtime.json`.
    static func inferredManifest(for root: URL) -> RuntimeManifest {
        RuntimeManifest(id: "external:" + root.standardizedFileURL.path,
                        name: root.lastPathComponent, version: "", wineVersion: "", capabilities: [])
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

    // MARK: Managed & Custom Placed runtimes

    /// Installs a runtime from an unpacked folder that has a `runtime.json`, by copying it into
    /// the Runtimes folder. A runtime with the same id is replaced.
    @discardableResult
    public func installManaged(from source: URL) throws -> WineRuntime {
        guard let manifest = Self.readManifest(in: source) else {
            throw FineWineError("“\(source.lastPathComponent)” has no runtime.json, so it isn't a FineWine runtime.")
        }
        try paths.ensureDirectories()
        let destination = paths.runtimes.appendingPathComponent(manifest.id, isDirectory: true)
        return try install(from: source, to: destination)
    }

    /// Installs a runtime into an arbitrary destination directory (e.g. on an external disk).
    /// If the destination is inside `paths.runtimes`, it is managed; otherwise it is registered
    /// as an external runtime so FineWine knows where it sits.
    @discardableResult
    public func install(from source: URL, to destination: URL) throws -> WineRuntime {
        guard let manifest = Self.readManifest(in: source) else {
            throw FineWineError("“\(source.lastPathComponent)” has no runtime.json, so it isn't a FineWine runtime.")
        }
        guard Self.isSafeIdentifier(manifest.id) else {
            throw FineWineError("The runtime's id “\(manifest.id)” can't be used as a folder name.")
        }

        let parent = destination.deletingLastPathComponent()
        try fm.createDirectory(at: parent, withIntermediateDirectories: true)
        try? paths.ensureDirectories()

        let destResolved = destination.resolvingSymlinksInPath().path
        let parentResolved = parent.resolvingSymlinksInPath().path
        let managedResolved = paths.runtimes.resolvingSymlinksInPath().path
        let isManaged = parentResolved == managedResolved
            || destination.standardizedFileURL.path.hasPrefix(paths.runtimes.standardizedFileURL.path)
        let kind: WineRuntime.Kind = isManaged ? .managed : .external

        let problems = WineRuntime(manifest: manifest, root: source, kind: kind).problems()
        guard problems.isEmpty else {
            throw FineWineError("“\(manifest.name)” is not a usable Wine runtime: " + problems.joined(separator: " "))
        }

        let staging = parent.appendingPathComponent(".installing-\(UUID().uuidString)", isDirectory: true)
        try FolderCopy.copy(source, to: staging)
        if fm.fileExists(atPath: destination.path) {
            try fm.removeItem(at: destination)
        }
        try fm.moveItem(at: staging, to: destination)

        let installed = WineRuntime(manifest: manifest, root: destination, kind: kind)
        if isManaged {
            // Ensure managed destination is not lingering in external-runtimes.json
            let list = externalPaths().filter { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path != destResolved }
            try? writeExternal(list)
        } else {
            var list = externalPaths()
            let destPath = destination.path
            if !list.contains(destPath) && !list.contains(destResolved) {
                list.append(destPath)
                try writeExternal(list)
            }
        }
        return installed
    }

    /// Installs a runtime from `source` to a `RuntimePlace` (this Mac, external drive, or custom folder).
    @discardableResult
    public func install(from source: URL, to place: RuntimePlace, volumes: VolumeProviding = SystemVolumes()) throws -> WineRuntime {
        guard let manifest = Self.readManifest(in: source) else {
            throw FineWineError("“\(source.lastPathComponent)” has no runtime.json, so it isn't a FineWine runtime.")
        }
        guard let target = targetDirectory(for: place, runtimeID: manifest.id, volumes: volumes) else {
            throw FineWineError("The destination volume or directory is not available.")
        }
        return try install(from: source, to: target)
    }

    /// Moves an existing runtime to another destination directory (e.g. moving between disks).
    @discardableResult
    public func move(runtime: WineRuntime, to destination: URL) throws -> WineRuntime {
        guard runtime.kind != .bundled else {
            throw FineWineError("The built-in runtime inside FineWine.app cannot be moved.")
        }
        let destination = destination.standardizedFileURL
        guard runtime.folder.standardizedFileURL.path != destination.path else {
            return runtime
        }

        let oldFolder = runtime.folder
        let oldKind = runtime.kind

        let installed = try install(from: oldFolder, to: destination)

        // Clean up old location
        switch oldKind {
        case .managed:
            try? removeManaged(id: runtime.id)
        case .external:
            try? removeExternal(oldFolder)
            try? fm.removeItem(at: oldFolder)
        case .bundled:
            break
        }

        return installed
    }

    /// Moves an existing runtime to a `RuntimePlace` (e.g. another disk or custom folder).
    @discardableResult
    public func move(runtime: WineRuntime, to place: RuntimePlace, volumes: VolumeProviding = SystemVolumes()) throws -> WineRuntime {
        guard let target = targetDirectory(for: place, runtimeID: runtime.id, volumes: volumes) else {
            throw FineWineError("The destination volume or directory is not available.")
        }
        return try move(runtime: runtime, to: target)
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
