import Foundation

struct PatchError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

/// One patched Wine module: where it lives in the app's bundled payload and
/// where it goes inside a CrossOver.app copy.
struct PayloadModule {
    let payloadSubpath: String    // relative to Resources/payload/
    let crossoverSubpath: String  // relative to Contents/SharedSupport/CrossOver/
}

enum Payload {
    static let modules: [PayloadModule] = [
        // Rosetta NOP + privileged-instruction fixes, NtDelayExecution QPC timing
        PayloadModule(payloadSubpath: "x86_64-unix/ntdll.so",
                      crossoverSubpath: "lib/wine/x86_64-unix/ntdll.so"),
        // KiUser*Dispatcher int3 spoof
        PayloadModule(payloadSubpath: "x86_64-windows/kernel32.dll",
                      crossoverSubpath: "lib/wine/x86_64-windows/kernel32.dll"),
        // ntoskrnl.exe em-backports
        PayloadModule(payloadSubpath: "x86_64-windows/ntoskrnl.exe",
                      crossoverSubpath: "lib/wine/x86_64-windows/ntoskrnl.exe"),
    ]

    /// The rpath the payload ntdll.so must carry so CrossOver's cxcompatdb.so
    /// (and through it D3DMetal) keeps working. Added at app-build time by
    /// scripts/build-app.sh so end users never need Xcode tools.
    static let requiredNtdllRpath = "@loader_path/../../../lib64"

    /// Directory containing the bundled pre-built modules.
    /// FINEWINE_PAYLOAD_DIR overrides it for development (`swift run`).
    static var directory: URL? {
        if let override = ProcessInfo.processInfo.environment["FINEWINE_PAYLOAD_DIR"] {
            let url = URL(fileURLWithPath: override, isDirectory: true)
            if FileManager.default.fileExists(atPath: url.path) { return url }
        }
        guard let resources = Bundle.main.resourceURL else { return nil }
        let url = resources.appendingPathComponent("payload", isDirectory: true)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    static var isComplete: Bool {
        guard let dir = directory else { return false }
        return modules.allSatisfy {
            FileManager.default.fileExists(atPath: dir.appendingPathComponent($0.payloadSubpath).path)
        }
    }
}

/// What we know about a selected CrossOver.app.
struct CrossOverInfo {
    static let expectedVersion = "26.2"

    let url: URL
    let version: String?
    let bundleIdentifier: String?
    let hasWineModules: Bool

    var isExpectedVersion: Bool { version?.hasPrefix(Self.expectedVersion) == true }
    var displayName: String { url.deletingPathExtension().lastPathComponent }

    init(url: URL) {
        self.url = url
        var plist: [String: Any] = [:]
        if let data = try? Data(contentsOf: url.appendingPathComponent("Contents/Info.plist")),
           let parsed = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] {
            plist = parsed
        }
        version = plist["CFBundleShortVersionString"] as? String
        bundleIdentifier = plist["CFBundleIdentifier"] as? String
        let cxr = url.appendingPathComponent("Contents/SharedSupport/CrossOver")
        hasWineModules = Payload.modules.allSatisfy {
            FileManager.default.fileExists(atPath: cxr.appendingPathComponent($0.crossoverSubpath).path)
        }
    }
}

/// Performs the patch. Mirrors scripts/swap-into-crossover.sh steps 1, 2 and 5
/// (the Wine-module swap). GPTK4/MoltenVK graphics upgrades are intentionally
/// out of scope — Apple's GPTK may not be redistributed.
@MainActor
final class PatcherEngine: ObservableObject {
    struct Step: Identifiable {
        enum Status { case pending, running, done, failed }
        let id: Int
        let label: String
        var status: Status = .pending
    }

    @Published private(set) var steps: [Step] = []
    @Published private(set) var isRunning = false
    @Published private(set) var patchedApp: URL?
    @Published var errorMessage: String?

    private static let stepLabels = [
        "Copying CrossOver",
        "Installing the patched Wine modules",
        "Removing the bundle seal & quarantine",
        "Verifying",
    ]

    func reset() {
        steps = []
        patchedApp = nil
        errorMessage = nil
    }

    func patch(source: URL, destination: URL) {
        guard !isRunning else { return }
        guard let payloadDir = Payload.directory, Payload.isComplete else {
            errorMessage = "This build of the patcher does not include the Wine module payload. Rebuild it with patcher-app/scripts/build-app.sh after scripts/build-wine.sh all."
            return
        }
        reset()
        isRunning = true
        steps = Self.stepLabels.enumerated().map { Step(id: $0.offset, label: $0.element) }

        Task.detached(priority: .userInitiated) {
            var current = 0
            func begin(_ index: Int) async {
                current = index
                await MainActor.run { self.steps[index].status = .running }
            }
            func finish(_ index: Int) async {
                await MainActor.run { self.steps[index].status = .done }
            }
            do {
                await begin(0)
                try Self.copyBundle(from: source, to: destination)
                await finish(0)

                await begin(1)
                try Self.installModules(into: destination, from: payloadDir)
                await finish(1)

                await begin(2)
                Self.stripSealAndQuarantine(destination)
                await finish(2)

                await begin(3)
                try Self.verify(destination, payloadDir: payloadDir)
                await finish(3)

                await MainActor.run {
                    self.patchedApp = destination
                    self.isRunning = false
                }
            } catch {
                let failed = current
                await MainActor.run {
                    self.steps[failed].status = .failed
                    self.errorMessage = error.localizedDescription
                    self.isRunning = false
                }
            }
        }
    }

    // MARK: - Workers (run off the main actor)

    private nonisolated static func cxRoot(_ app: URL) -> URL {
        app.appendingPathComponent("Contents/SharedSupport/CrossOver", isDirectory: true)
    }

    private nonisolated static func copyBundle(from source: URL, to destination: URL) throws {
        let fm = FileManager.default
        let src = source.standardizedFileURL
        let dst = destination.standardizedFileURL
        guard dst.pathExtension == "app" else {
            throw PatchError("The destination must be an .app path.")
        }
        guard src.path != dst.path else {
            throw PatchError("The destination must be different from the original CrossOver.app.")
        }
        guard !dst.path.hasPrefix(src.path + "/"), !src.path.hasPrefix(dst.path + "/") else {
            throw PatchError("The destination cannot be inside the original CrossOver.app (or vice versa).")
        }
        if fm.fileExists(atPath: dst.path) {
            try fm.removeItem(at: dst)
        }
        // /bin/cp -a preserves symlinks, permissions and metadata — same as
        // scripts/swap-into-crossover.sh. The bundle is ~a few GB; this is the slow step.
        try run("/bin/cp", ["-a", src.path, dst.path])
    }

    private nonisolated static func installModules(into app: URL, from payloadDir: URL) throws {
        let fm = FileManager.default
        let cxr = cxRoot(app)
        for module in Payload.modules {
            let src = payloadDir.appendingPathComponent(module.payloadSubpath)
            let dst = cxr.appendingPathComponent(module.crossoverSubpath)
            guard fm.fileExists(atPath: src.path) else {
                throw PatchError("The bundled payload is missing \(module.payloadSubpath).")
            }
            guard fm.fileExists(atPath: dst.path) else {
                throw PatchError("\(module.crossoverSubpath) not found in the copied app — is this really CrossOver \(CrossOverInfo.expectedVersion)?")
            }
            // Keep a backup of the stock module under the same name the shell script uses.
            let backup = dst.appendingPathExtension("cxorig")
            if !fm.fileExists(atPath: backup.path) {
                try fm.copyItem(at: dst, to: backup)
            }
            try fm.removeItem(at: dst)
            try fm.copyItem(at: src, to: dst)
            // Ad-hoc signature so the modified file loads on Apple Silicon. For the
            // PE modules codesign stores it in xattrs; harmless and matches the script.
            try run("/usr/bin/codesign", ["--force", "--sign", "-", dst.path])
        }
    }

    private nonisolated static func stripSealAndQuarantine(_ app: URL) {
        let fm = FileManager.default
        for sub in ["Contents/_CodeSignature", "Contents/CodeResources"] {
            try? fm.removeItem(at: app.appendingPathComponent(sub))
        }
        _ = try? run("/usr/bin/xattr", ["-drs", "com.apple.quarantine", app.path])
    }

    private nonisolated static func verify(_ app: URL, payloadDir: URL) throws {
        let cxr = cxRoot(app)
        for module in Payload.modules {
            let src = payloadDir.appendingPathComponent(module.payloadSubpath)
            let dst = cxr.appendingPathComponent(module.crossoverSubpath)
            guard let a = fileSize(src), let b = fileSize(dst), a == b else {
                throw PatchError("\(module.crossoverSubpath) does not match the bundled payload after the swap.")
            }
        }
        // ntdll.so is the module the kernel actually checks; make sure its ad-hoc
        // signature is valid and that it carries the lib64 rpath (baked in at
        // app-build time) — without that rpath cxcompatdb.so can't load and
        // D3DMetal never engages.
        let ntdll = cxr.appendingPathComponent("lib/wine/x86_64-unix/ntdll.so")
        try run("/usr/bin/codesign", ["--verify", ntdll.path])
        let data = try Data(contentsOf: ntdll, options: .alwaysMapped)
        guard let needle = Payload.requiredNtdllRpath.data(using: .utf8),
              data.range(of: needle) != nil else {
            throw PatchError("ntdll.so is missing the lib64 rpath — D3DMetal would not work. Rebuild the patcher with scripts/build-app.sh (it adds the rpath to the payload).")
        }
    }

    private nonisolated static func fileSize(_ url: URL) -> UInt64? {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? UInt64) ?? nil
    }

    @discardableResult
    private nonisolated static func run(_ tool: String, _ args: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = args
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        do {
            try process.run()
        } catch {
            throw PatchError("Could not run \((tool as NSString).lastPathComponent): \(error.localizedDescription)")
        }
        // Read to EOF before waiting so a full pipe can never stall the child.
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let text = String(data: data, encoding: .utf8) ?? ""
        guard process.terminationStatus == 0 else {
            let name = (tool as NSString).lastPathComponent
            let detail = text.trimmingCharacters(in: .whitespacesAndNewlines)
            throw PatchError("\(name) failed (exit \(process.terminationStatus))\(detail.isEmpty ? "" : ": \(detail)")")
        }
        return text
    }
}
