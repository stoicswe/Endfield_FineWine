import Foundation
import CryptoKit

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
        // Patched MoltenVK (Vulkan/DXVK/vkd3d paths; replaces CrossOver's bundled copy).
        // Built by scripts/build-moltenvk.sh and baked into the payload by build-app.sh.
        PayloadModule(payloadSubpath: "lib64/libMoltenVK.dylib",
                      crossoverSubpath: "lib64/libMoltenVK.dylib"),
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

/// A GPTK install the user supplied — the `…/redist/lib/external` folder inside Apple's
/// mounted "Evaluation environment for Windows games …" DMG (or a folder picked by hand).
///
/// Apple's Game Porting Toolkit is evaluation-only software and is **never bundled or
/// redistributed** by this app; the app only reads the copy the user mounted themselves.
struct GPTKSource: Identifiable, Hashable, Sendable {
    /// The `…/redist/lib/external` directory.
    let url: URL
    /// CFBundleShortVersionString of the bundled D3DMetal.framework (e.g. "4.0b2"), if readable.
    let version: String?
    /// The mounted volume's name (e.g. "Evaluation environment for Windows games 4.0b2").
    let volumeName: String

    var id: String { url.path }

    var displayName: String {
        if let version, !version.isEmpty { return "\(volumeName) — D3DMetal \(version)" }
        return volumeName
    }

    /// D3DMetal 4.x is the GPTK4 release that adds the Metal 4 / MetalFX features.
    var isVersion4: Bool { version?.hasPrefix("4") == true }

    init?(url: URL) {
        let fm = FileManager.default
        let lib = url.appendingPathComponent("libd3dshared.dylib")
        let plist = url.appendingPathComponent("D3DMetal.framework/Resources/Info.plist")
        guard fm.fileExists(atPath: lib.path),
              fm.fileExists(atPath: url.appendingPathComponent("D3DMetal.framework").path) else { return nil }
        self.url = url
        self.version = Self.frameworkVersion(plist)
        let parts = url.standardizedFileURL.pathComponents   // ["/", "Volumes", "<label>", "redist", "lib", "external"]
        if parts.count >= 6, parts[1] == "Volumes" {
            volumeName = parts[2]
        } else {
            volumeName = url.deletingLastPathComponent().lastPathComponent
        }
    }

    private static func frameworkVersion(_ plist: URL) -> String? {
        guard let data = try? Data(contentsOf: plist),
              let parsed = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        else { return nil }
        return parsed["CFBundleShortVersionString"] as? String
    }

    /// Every GPTK redist currently mounted under /Volumes (`<volume>/redist/lib/external`).
    static func detectMounted() -> [GPTKSource] {
        let fm = FileManager.default
        guard let volumes = try? fm.contentsOfDirectory(at: URL(fileURLWithPath: "/Volumes"),
                                                        includingPropertiesForKeys: nil) else { return [] }
        return volumes
            .compactMap { GPTKSource(url: $0.appendingPathComponent("redist/lib/external", isDirectory: true)) }
            .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
    }
}

/// What we know about a selected CrossOver.app.
struct CrossOverInfo {
    static let expectedVersion = "26.3"

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

/// Performs the patch. Mirrors scripts/swap-into-crossover.sh steps 1, 2, 3 and 5:
/// the patched Wine-module swap plus the bundled patched MoltenVK, and (optionally) Apple's
/// GPTK4 / D3DMetal, installed from a copy the user supplied — it is never bundled here.
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

    private static func stepLabels(includingGPTK: Bool) -> [String] {
        var labels = [
            "Copying CrossOver",
            "Installing the patched modules",
        ]
        if includingGPTK { labels.append("Installing GPTK4 / D3DMetal") }
        labels += [
            "Re-sealing the bundle",
            "Verifying",
            "Moving the patched app into place",
        ]
        return labels
    }

    func reset() {
        steps = []
        patchedApp = nil
        errorMessage = nil
    }

    func patch(source: URL, destination: URL, gptk: GPTKSource? = nil) {
        guard !isRunning else { return }
        guard let payloadDir = Payload.directory, Payload.isComplete else {
            errorMessage = "This build of the patcher does not include the module payload (Wine + MoltenVK). Rebuild it with patcher-app/scripts/build-app.sh after scripts/build-wine.sh all and scripts/build-moltenvk.sh all."
            return
        }
        reset()
        isRunning = true
        steps = Self.stepLabels(includingGPTK: gptk != nil).enumerated().map { Step(id: $0.offset, label: $0.element) }

        Task.detached(priority: .userInitiated) {
            var current = 0
            func begin(_ index: Int) async {
                current = index
                await MainActor.run { self.steps[index].status = .running }
            }
            func finish(_ index: Int) async {
                await MainActor.run { self.steps[index].status = .done }
            }
            var staged: URL?
            defer {
                if let staged { try? FileManager.default.removeItem(at: staged.deletingLastPathComponent()) }
            }
            do {
                var index = 0

                await begin(index)
                let app = try Self.copyBundle(from: source, to: destination)
                staged = app
                await finish(index); index += 1

                await begin(index)
                try Self.installModules(into: app, from: payloadDir)
                await finish(index); index += 1

                if let gptk {
                    await begin(index)
                    try Self.installGPTK(into: app, from: gptk.url)
                    await finish(index); index += 1
                }

                await begin(index)
                try Self.resealBundle(app)
                await finish(index); index += 1

                await begin(index)
                try Self.verify(app, payloadDir: payloadDir, gptk: gptk)
                await finish(index); index += 1

                await begin(index)
                try Self.moveIntoPlace(app, destination: destination)
                await finish(index); index += 1

                await MainActor.run {
                    self.patchedApp = destination
                    self.isRunning = false
                }
            } catch {
                let failed = current
                await MainActor.run {
                    if failed < self.steps.count { self.steps[failed].status = .failed }
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

    /// Copies CrossOver into a fresh staging folder on the destination's volume and returns the
    /// staged app. It is patched and sealed there and only moved to `destination` once it
    /// verifies, so a half-patched bundle never sits in /Applications.
    private nonisolated static func copyBundle(from source: URL, to destination: URL) throws -> URL {
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
        let staging = try fm.url(for: .itemReplacementDirectory, in: .userDomainMask,
                                 appropriateFor: dst.deletingLastPathComponent(), create: true)
        let staged = staging.appendingPathComponent(dst.lastPathComponent, isDirectory: true)
        // ditto preserves symlinks and permissions, like scripts/swap-into-crossover.sh. Extended
        // attributes are left behind: Finder/iCloud/quarantine xattrs on the source would make
        // codesign refuse to re-seal the copy. The bundle is ~a few GB; this is the slow step.
        do {
            try run("/usr/bin/ditto", ["--noextattr", "--noqtn", src.path, staged.path])
        } catch {
            try? fm.removeItem(at: staging)
            throw error
        }
        return staged
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
            // Move the stock module aside under the same backup name the shell script uses, so
            // the payload lands as a fresh file rather than overwriting a signed one in place.
            let backup = dst.appendingPathExtension("cxorig")
            if fm.fileExists(atPath: backup.path) {
                try fm.removeItem(at: dst)
            } else {
                try fm.moveItem(at: dst, to: backup)
            }
            try fm.copyItem(at: src, to: dst)
            // Only the Mach-O modules (ntdll.so, libMoltenVK.dylib) need a signature of their
            // own to load on Apple Silicon. The PE modules are covered by the bundle seal, as in
            // stock CrossOver.
            if dst.pathExtension == "so" || dst.pathExtension == "dylib" {
                try run("/usr/bin/codesign", ["--force", "--sign", "-", dst.path])
            }
        }
    }

    /// Installs Apple's GPTK4 / D3DMetal (the user's own mounted DMG) over CrossOver's bundled
    /// D3DMetal. Only `lib64/apple_gptk/external/` is replaced: every D3DMetal glue module in
    /// `lib64/apple_gptk/wine/` symlinks into it, so the whole D3D11/D3D12/DXGI/DLSS (NVNGX)
    /// stack upgrades at once — and no `lib/wine/.../{d3d11,d3d12,dxgi}.dll` is touched (dropping
    /// Apple's DLLs there breaks `unityplayer.dll`, Windows error 1114). Mirrors
    /// scripts/swap-into-crossover.sh step 3.
    private nonisolated static func installGPTK(into app: URL, from gptkExternal: URL) throws {
        let fm = FileManager.default
        let cxr = cxRoot(app)
        let dest = cxr.appendingPathComponent("lib64/apple_gptk/external", isDirectory: true)
        guard fm.fileExists(atPath: dest.path) else {
            throw PatchError("lib64/apple_gptk/external not found in the copied app — is this really CrossOver \(CrossOverInfo.expectedVersion)?")
        }
        let lib = gptkExternal.appendingPathComponent("libd3dshared.dylib")
        let framework = gptkExternal.appendingPathComponent("D3DMetal.framework", isDirectory: true)
        guard fm.fileExists(atPath: lib.path), fm.fileExists(atPath: framework.path) else {
            throw PatchError("That folder is not a GPTK redist — expected D3DMetal.framework and libd3dshared.dylib inside it (…/redist/lib/external).")
        }
        // Re-running the patcher with the same GPTK already installed is a no-op.
        if externalMatches(source: gptkExternal, destination: dest) { return }

        let backup = cxr.appendingPathComponent("lib64/apple_gptk/external.cxorig", isDirectory: true)
        if fm.fileExists(atPath: backup.path) { try? fm.removeItem(at: backup) }
        try fm.moveItem(at: dest, to: backup)
        do {
            // ditto (not copyItem) preserves the framework's symlinks and permissions; the two
            // flags drop the DMG's quarantine/FinderInfo xattrs, which would break the seal.
            try run("/usr/bin/ditto", ["--noextattr", "--noqtn", gptkExternal.path + "/", dest.path])
        } catch {
            // A failed copy must not leave a half-installed GPTK: restore CrossOver's original.
            try? fm.removeItem(at: dest)
            try? fm.moveItem(at: backup, to: dest)
            throw error
        }
        // Apple's signatures normally survive ditto; only re-sign the halves that don't verify.
        let dstLib = dest.appendingPathComponent("libd3dshared.dylib")
        if !codesignVerifies(dstLib.path, deep: false) {
            try run("/usr/bin/codesign", ["--force", "--sign", "-", dstLib.path])
        }
        let dstFramework = dest.appendingPathComponent("D3DMetal.framework", isDirectory: true)
        if !codesignVerifies(dstFramework.path, deep: true) {
            try run("/usr/bin/codesign", ["--force", "--deep", "--sign", "-", dstFramework.path])
        }
    }

    /// True when the installed D3DMetal.framework binary and libd3dshared.dylib already match
    /// the source, so a re-patch doesn't needlessly replace (and re-sign) them.
    private nonisolated static func externalMatches(source: URL, destination: URL) -> Bool {
        let lib = "libd3dshared.dylib"
        let fw = "D3DMetal.framework/Versions/A/D3DMetal"
        guard let srcLib = hash(source.appendingPathComponent(lib)),
              let dstLib = hash(destination.appendingPathComponent(lib)),
              srcLib == dstLib,
              let srcFw = hash(source.appendingPathComponent(fw)),
              let dstFw = hash(destination.appendingPathComponent(fw)),
              srcFw == dstFw
        else { return false }
        return true
    }

    private nonisolated static func hash(_ url: URL) -> Data? {
        guard let data = try? Data(contentsOf: url, options: .alwaysMapped) else { return nil }
        return Data(SHA256.hash(data: data))
    }

    private nonisolated static func codesignVerifies(_ path: String, deep: Bool) -> Bool {
        var args = ["--verify"]
        if deep { args += ["--deep", "--strict"] }
        args.append(path)
        return (try? run("/usr/bin/codesign", args)) != nil
    }

    /// Re-seals the bundle with an ad-hoc signature. Deleting the seal is not enough: a copy
    /// made by a downloaded app (like this one) carries com.apple.provenance, so macOS checks
    /// the bundle's signature at first launch and kills every binary in a bundle whose seal is
    /// missing ("…is damaged and can't be opened"). Only the outer bundle is re-signed: the
    /// nested CodeWeavers binaries keep their signatures (wineloader/wineserver already carry
    /// disable-library-validation, so they load the ad-hoc ntdll.so), and the main executable
    /// keeps its entitlements but not the hardened runtime, whose library validation would
    /// reject the CodeWeavers-signed frameworks under an ad-hoc signature.
    private nonisolated static func resealBundle(_ app: URL) throws {
        _ = try? run("/usr/bin/xattr", ["-drs", "com.apple.quarantine", app.path])
        // codesign refuses to seal "detritus", and even ditto leaves FinderInfo on the bundle folder.
        _ = try? run("/usr/bin/xattr", ["-rd", "com.apple.FinderInfo", app.path])
        _ = try? run("/usr/bin/xattr", ["-rd", "com.apple.ResourceFork", app.path])
        try run("/usr/bin/codesign", ["--force", "--sign", "-", "--preserve-metadata=entitlements",
                                      "--timestamp=none", app.path])
    }

    /// Replaces `destination` with the verified staged app.
    private nonisolated static func moveIntoPlace(_ staged: URL, destination: URL) throws {
        let fm = FileManager.default
        if fm.fileExists(atPath: destination.path) {
            do {
                try fm.removeItem(at: destination)
            } catch {
                // App Management can refuse to delete an app that has been launched, but
                // moving it to the Trash is still allowed.
                do {
                    try fm.trashItem(at: destination, resultingItemURL: nil)
                } catch {
                    throw PatchError("Couldn't replace the existing \(destination.lastPathComponent) — move it to the Trash and patch again.")
                }
            }
        }
        try fm.moveItem(at: staged, to: destination)
    }

    private nonisolated static func verify(_ app: URL, payloadDir: URL, gptk: GPTKSource?) throws {
        let cxr = cxRoot(app)
        for module in Payload.modules {
            let src = payloadDir.appendingPathComponent(module.payloadSubpath)
            let dst = cxr.appendingPathComponent(module.crossoverSubpath)
            guard let a = fileSize(src), let b = fileSize(dst), a == b else {
                throw PatchError("\(module.crossoverSubpath) does not match the bundled payload after the swap.")
            }
        }
        // If the user supplied GPTK, confirm the D3DMetal external half really came across (the
        // installed libd3dshared.dylib must be byte-identical to the source they selected).
        if let gptk {
            let external = cxr.appendingPathComponent("lib64/apple_gptk/external", isDirectory: true)
            let installed = external.appendingPathComponent("libd3dshared.dylib")
            guard FileManager.default.fileExists(atPath: installed.path),
                  FileManager.default.fileExists(atPath: external.appendingPathComponent("D3DMetal.framework/Versions/A/D3DMetal").path) else {
                throw PatchError("GPTK4 was not installed correctly — D3DMetal.framework or libd3dshared.dylib is missing from the patched app.")
            }
            guard let src = hash(gptk.url.appendingPathComponent("libd3dshared.dylib")),
                  let dst = hash(installed), src == dst else {
                throw PatchError("The installed GPTK4 libd3dshared.dylib does not match the source you selected.")
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
        // The whole bundle must verify, or macOS reports it as damaged and kills its binaries.
        do {
            try run("/usr/bin/codesign", ["--verify", "--deep", "--strict", app.path])
        } catch {
            throw PatchError("The patched app's signature does not verify, so macOS would refuse to run it. \(error.localizedDescription)")
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
