import Foundation

/// Information about an Endfield_FineWine repository checkout.
public struct RuntimeRepoInfo: Equatable, Sendable {
    public var root: URL
    public var buildScript: URL
    public var hasBuiltWine: Bool
    public var hasPackagedRuntime: Bool
    public var packagedManifest: RuntimeManifest?

    public init(root: URL, buildScript: URL, hasBuiltWine: Bool, hasPackagedRuntime: Bool, packagedManifest: RuntimeManifest? = nil) {
        self.root = root
        self.buildScript = buildScript
        self.hasBuiltWine = hasBuiltWine
        self.hasPackagedRuntime = hasPackagedRuntime
        self.packagedManifest = packagedManifest
    }
}

/// How the runtime should be regenerated.
public enum RuntimeRegenerationMode: String, CaseIterable, Identifiable, Sendable {
    /// Fast: packages the compiled Wine build from build/finewine-runtime-build into the runtime (~15s).
    case quickPackage = "quick_package"
    /// Directly installs from build/finewine-runtime without running build scripts (instant).
    case copyExisting = "copy_existing"
    /// Recompiles changed Wine files and packages the runtime.
    case rebuildAndPackage = "rebuild_package"
    /// Full clean build from scratch (Wine, patches, dependencies, helpers).
    case fullBuild = "full_build"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .quickPackage: return "Regenerate & Package Runtime (Fast)"
        case .copyExisting: return "Install Pre-built Runtime"
        case .rebuildAndPackage: return "Recompile & Package Runtime"
        case .fullBuild: return "Full Build from Source"
        }
    }

    public var description: String {
        switch self {
        case .quickPackage:
            return "Packages compiled Wine binaries, MoltenVK, and helpers into the runtime without full recompilation (~15 seconds)."
        case .copyExisting:
            return "Copies the existing built runtime directly from the repository build folder without running build scripts."
        case .rebuildAndPackage:
            return "Runs make in the build directory to compile modified source files, then packages the runtime."
        case .fullBuild:
            return "Downloads dependencies, checks out Wine, applies patches, configures, and builds everything from scratch."
        }
    }
}

/// Discovers the Endfield_FineWine repository, runs runtime build/package scripts, streams output,
/// and installs the runtime to the chosen destination (Mac or external disk).
public actor RuntimeRegenerator {
    private var currentProcess: Process?
    private var isCancelled = false

    public init() {}

    /// Environment variable to explicitly specify the repository path.
    public static let repoOverrideVariable = "FINEWINE_REPO"

    /// Attempts to locate the Endfield_FineWine repository by checking environment,
    /// bundle path ancestors, current working directory ancestors, and standard developer paths.
    public static func locateRepository(startingAt: URL? = nil,
                                        environment: [String: String] = ProcessInfo.processInfo.environment) -> URL? {
        let fm = FileManager.default

        // 1. Environment variable override
        if let envPath = environment[repoOverrideVariable], !envPath.isEmpty {
            let url = URL(fileURLWithPath: (envPath as NSString).expandingTildeInPath, isDirectory: true)
            if isRepository(at: url) { return url }
        }

        // 2. Starting URL or bundle URL ancestors
        var probeURLs: [URL] = []
        if let startingAt { probeURLs.append(startingAt) }
        probeURLs.append(Bundle.main.bundleURL)
        probeURLs.append(URL(fileURLWithPath: fm.currentDirectoryPath, isDirectory: true))

        for start in probeURLs {
            var curr = start.standardizedFileURL
            for _ in 0..<7 {
                if isRepository(at: curr) { return curr }
                let parent = curr.deletingLastPathComponent()
                if parent.path == curr.path { break }
                curr = parent
            }
        }

        // 3. Common developer locations
        let home = fm.homeDirectoryForCurrentUser
        let candidates = [
            home.appendingPathComponent("Documents/Developer/Endfield_FineWine", isDirectory: true),
            home.appendingPathComponent("Developer/Endfield_FineWine", isDirectory: true),
            home.appendingPathComponent("src/Endfield_FineWine", isDirectory: true),
            home.appendingPathComponent("Projects/Endfield_FineWine", isDirectory: true)
        ]
        for candidate in candidates where isRepository(at: candidate) {
            return candidate
        }

        return nil
    }

    /// Checks if a folder looks like the Endfield_FineWine repository.
    public static func isRepository(at url: URL) -> Bool {
        let fm = FileManager.default
        let script = url.appendingPathComponent("scripts/build-finewine-runtime.sh")
        return fm.isExecutableFile(atPath: script.path) || fm.fileExists(atPath: script.path)
    }

    /// Inspects a repository to see what build files and runtimes are present.
    public static func inspectRepository(at root: URL) -> RuntimeRepoInfo? {
        let fm = FileManager.default
        let script = root.appendingPathComponent("scripts/build-finewine-runtime.sh")
        guard fm.fileExists(atPath: script.path) else { return nil }

        let builtWine = root.appendingPathComponent("build/finewine-runtime-build/loader/wine")
        let hasBuiltWine = fm.isExecutableFile(atPath: builtWine.path)

        let packagedDir = root.appendingPathComponent("build/finewine-runtime")
        let manifest = RuntimeStore.readManifest(in: packagedDir)
        let hasPackagedRuntime = manifest != nil && fm.isExecutableFile(atPath: packagedDir.appendingPathComponent("bin/wine").path)

        return RuntimeRepoInfo(root: root, buildScript: script,
                               hasBuiltWine: hasBuiltWine,
                               hasPackagedRuntime: hasPackagedRuntime,
                               packagedManifest: manifest)
    }

    /// Cancels any currently executing build process.
    public func cancel() {
        isCancelled = true
        currentProcess?.terminate()
        currentProcess = nil
    }

    /// Regenerates or copies the Wine runtime and places it at `destinationPlace`.
    @discardableResult
    public func regenerate(mode: RuntimeRegenerationMode,
                           repo: URL,
                           destinationPlace: RuntimePlace,
                           runtimeStore: RuntimeStore,
                           volumes: VolumeProviding = SystemVolumes(),
                           logHandler: @Sendable @escaping (String) -> Void) async throws -> WineRuntime {
        isCancelled = false
        guard Self.isRepository(at: repo) else {
            throw FineWineError("“\(repo.path)” is not a valid Endfield_FineWine repository.")
        }

        let repo = repo.standardizedFileURL
        let script = repo.appendingPathComponent("scripts/build-finewine-runtime.sh")
        let packagedRuntimeDir = repo.appendingPathComponent("build/finewine-runtime", isDirectory: true)

        switch mode {
        case .copyExisting:
            logHandler("==> Using existing runtime build at \(packagedRuntimeDir.path)...")
            guard let manifest = RuntimeStore.readManifest(in: packagedRuntimeDir) else {
                throw FineWineError("No packaged runtime found at \(packagedRuntimeDir.path). Please run Regenerate & Package first.")
            }
            logHandler("Found \(manifest.name) (\(manifest.id)).")

        case .quickPackage:
            logHandler("==> Packaging runtime from existing build...")
            try await runScript(script: script, argument: "package", in: repo, logHandler: logHandler)

        case .rebuildAndPackage:
            logHandler("==> Recompiling Wine...")
            try await runScript(script: script, argument: "build", in: repo, logHandler: logHandler)
            logHandler("==> Packaging runtime...")
            try await runScript(script: script, argument: "package", in: repo, logHandler: logHandler)

        case .fullBuild:
            logHandler("==> Running full runtime build...")
            try await runScript(script: script, argument: "all", in: repo, logHandler: logHandler)
        }

        guard !isCancelled else { throw FineWineError(FolderCopy.cancelledMessage) }

        // Verify the generated runtime
        guard let manifest = RuntimeStore.readManifest(in: packagedRuntimeDir) else {
            throw FineWineError("The build completed, but no runtime.json was produced at \(packagedRuntimeDir.path).")
        }

        guard let targetDir = runtimeStore.targetDirectory(for: destinationPlace, runtimeID: manifest.id, volumes: volumes) else {
            throw FineWineError("The destination location is not available or the disk is disconnected.")
        }

        logHandler("==> Installing \(manifest.name) to \(targetDir.path)...")

        let installed = try runtimeStore.install(from: packagedRuntimeDir, to: targetDir)

        logHandler("✅ Successfully installed \(installed.name) to \(targetDir.path)!")
        return installed
    }

    private func runScript(script: URL, argument: String, in workingDirectory: URL,
                           logHandler: @Sendable @escaping (String) -> Void) async throws {
        let process = Process()
        // Use system bash (/bin/bash) to avoid any broken Homebrew dylib linkages
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [script.path, argument]
        process.currentDirectoryURL = workingDirectory

        // Ensure PATH has Homebrew and system bins
        var env = ProcessInfo.processInfo.environment
        let brewPaths = "/opt/homebrew/bin:/opt/homebrew/sbin:/usr/local/bin"
        let standardPaths = "/usr/bin:/bin:/usr/sbin:/sbin"
        let currentPath = env["PATH"] ?? ""
        env["PATH"] = "\(brewPaths):\(standardPaths):\(currentPath)"
        process.environment = env

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        process.qualityOfService = .userInitiated

        self.currentProcess = process

        // Read output line by line
        let fileHandle = pipe.fileHandleForReading
        let reader = Task.detached(priority: .userInitiated) {
            var buffer = Data()
            while true {
                let chunk = fileHandle.availableData
                guard !chunk.isEmpty else { break }
                buffer.append(chunk)
                while let newlineIndex = buffer.firstIndex(of: 0x0A) { // '\n'
                    let lineData = buffer.subdata(in: 0..<newlineIndex)
                    buffer.removeSubrange(0...newlineIndex)
                    let line = String(decoding: lineData, as: UTF8.self).trimmingCharacters(in: .newlines)
                    if !line.isEmpty {
                        logHandler(line)
                    }
                }
            }
            if !buffer.isEmpty {
                let remaining = String(decoding: buffer, as: UTF8.self).trimmingCharacters(in: .newlines)
                if !remaining.isEmpty { logHandler(remaining) }
            }
        }

        try process.run()

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            process.terminationHandler = { _ in continuation.resume() }
        }

        _ = await reader.result
        self.currentProcess = nil

        guard !isCancelled else {
            throw FineWineError(FolderCopy.cancelledMessage)
        }

        if process.terminationStatus != 0 {
            throw FineWineError("Command ‘scripts/build-finewine-runtime.sh \(argument)’ failed with exit code \(process.terminationStatus).")
        }
    }
}
