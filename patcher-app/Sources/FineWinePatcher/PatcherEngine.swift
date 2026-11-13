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
    /// true when CrossOver ships no stock copy of this module (e.g. lsass.exe) and we add it.
    let isNew: Bool

    init(payloadSubpath: String, crossoverSubpath: String, isNew: Bool = false) {
        self.payloadSubpath = payloadSubpath
        self.crossoverSubpath = crossoverSubpath
        self.isNew = isNew
    }
}

/// Which CrossOver build the patcher targets. The two products differ in Wine version, bundle
/// layout and host architecture, so almost every path the patcher touches derives from this.
///
/// The patcher detects the variant from the selected app's layout (`CrossOverInfo`) and only
/// installs the payload that matches — the x64 path is never affected by the ARM payload and
/// vice-versa.
enum CrossOverVariant: String, CaseIterable, Sendable {
    /// CrossOver 26.x — Wine 11.0, `lib64/…`, x86_64 Wine under Rosetta 2.
    case x64
    /// CrossOver ARM / 27 preview — Wine 11.17, `lib/<host>/…`, native aarch64 Wine (no Rosetta).
    /// Experimental: the load-bearing `#ifdef __x86_64__` dispatcher spoof is absent on the
    /// aarch64 unix side, so getting past ACE on this variant is the open question.
    case arm

    var displayName: String {
        switch self {
        case .x64: return "x64"
        case .arm: return "ARM"
        }
    }

    var isExperimental: Bool { self == .arm }

    /// Version the variant's bundled modules are built against. For x64 this is exact (the Wine
    /// ABI must match). ARM releases are date-versioned previews, so the variant is detected from
    /// the app layout instead and this is used for display/download hints only.
    var expectedVersion: String {
        switch self {
        case .x64: return "26.3"
        case .arm: return "27 preview"
        }
    }

    /// Host (unix) architecture Wine runs as for this variant. The ARM variant intentionally
    /// targets `aarch64` with no Rosetta.
    var hostArch: String {
        switch self {
        case .x64: return "x86_64"
        case .arm: return "aarch64"
        }
    }

    /// Directory (relative to `Contents/SharedSupport/CrossOver/`) holding the host libraries
    /// (gnutls, MoltenVK). 26.x uses `lib64`; CrossOver 27 uses `lib/<host>`.
    var hostLibSubpath: String { self == .x64 ? "lib64" : "lib/\(hostArch)" }

    /// The rpath the payload ntdll.so must carry so CrossOver's cxcompatdb.so (and through it
    /// D3DMetal) keeps working. Added at app-build time; differs per variant because the host lib
    /// dir moved.
    var requiredNtdllRpath: String { "@loader_path/../../../\(hostLibSubpath)" }

    /// CrossOver's D3DMetal tree. 26.x: `lib64/apple_gptk`; CrossOver 27: `lib/apple_gptk`.
    var gptkPrefixSubpath: String { self == .x64 ? "lib64/apple_gptk" : "lib/apple_gptk" }

    /// Whether this variant's Wine runs as x86_64 and therefore needs Rosetta 2. The ARM variant
    /// runs native aarch64 Wine; x86_64 Windows code is emulated by FEX inside those processes.
    var requiresRosetta: Bool { self == .x64 }

    /// The `cxbottle --winearch` value this variant's bottles need. CrossOver ARM also ships an
    /// x86_64 Wine tree and runs a default `win64` bottle on it under Rosetta, so only an `arm64`
    /// bottle reaches the aarch64 host (and this variant's payload).
    var bottleWineArch: String? { self == .arm ? "arm64" : nil }

    /// D3DMetal is x86_64-only, even inside CrossOver ARM, so an aarch64 Wine process can't load it.
    var supportsD3DMetal: Bool { self == .x64 }

    /// Default name of the patched copy. They differ so patching one variant never replaces the
    /// other's copy.
    var patchedAppName: String {
        switch self {
        case .x64: return "CrossOver_Endfield_Patch"
        case .arm: return "CrossOver_Endfield_Patch_ARM"
        }
    }

    /// Bundle identifier of this variant's patched copy. Shortcuts find their app by this ID, so
    /// each variant needs its own or shortcuts could open the wrong copy. The helpers hardcode the
    /// ID in a fixed-size slot, so it must stay the same length as CrossOver's own.
    var patchedBundleIdentifier: String {
        switch self {
        case .x64: return PatcherEngine.patchedBundleIdentifier
        case .arm: return "com.codeweavers.CrsEF.ARM"
        }
    }

    /// Modules this variant swaps, in install order. `crossoverSubpath` is relative to
    /// `Contents/SharedSupport/CrossOver/`; `payloadSubpath` is relative to the variant's payload
    /// directory (see `Payload.directory(for:)`).
    var modules: [PayloadModule] {
        switch self {
        case .x64:
            return [
                // Rosetta NOP + privileged-instruction fixes, NtDelayExecution QPC timing
                PayloadModule(payloadSubpath: "x86_64-unix/ntdll.so",
                              crossoverSubpath: "lib/wine/x86_64-unix/ntdll.so"),
                // Composites the alpha of windows that asked DWM to blur behind them, so no black
                // margin surrounds the GRYPHLINK launcher. The game never asks, so it stays opaque.
                PayloadModule(payloadSubpath: "x86_64-unix/winemac.so",
                              crossoverSubpath: "lib/wine/x86_64-unix/winemac.so"),
                // Marks the windows that ask DWM to blur behind them, for winemac.so above.
                PayloadModule(payloadSubpath: "x86_64-windows/dwmapi.dll",
                              crossoverSubpath: "lib/wine/x86_64-windows/dwmapi.dll"),
                // KiUser*Dispatcher int3 spoof
                PayloadModule(payloadSubpath: "x86_64-windows/kernel32.dll",
                              crossoverSubpath: "lib/wine/x86_64-windows/kernel32.dll"),
                // ntoskrnl.exe em-backports, ACE-CORE fixes and the aarch64 shared page emulation
                PayloadModule(payloadSubpath: "x86_64-windows/ntoskrnl.exe",
                              crossoverSubpath: "lib/wine/x86_64-windows/ntoskrnl.exe"),
                // ACE-CORE scans the process list for lsass.exe; stock CrossOver 26.3 ships none, so add it.
                PayloadModule(payloadSubpath: "x86_64-windows/lsass.exe",
                              crossoverSubpath: "lib/wine/x86_64-windows/lsass.exe", isNew: true),
                // Patched wineboot.exe starts the lsass.exe stub at boot.
                PayloadModule(payloadSubpath: "x86_64-windows/wineboot.exe",
                              crossoverSubpath: "lib/wine/x86_64-windows/wineboot.exe"),
                // rundll32.exe is EXEC'd by cxbottle for the 'win11Install crossover.inf' step that
                // creates every bottle. Our rebuild drops the visible helper window that hangs/fails
                // prefix creation on macOS 26 (WineHQ bug 59595) — upstream Wine has not merged a fix,
                // so we ship the patched builtin. Like wineserver it is an exec'd Mach-O and needs its
                // own signature (see requiresOwnSignature).
                PayloadModule(payloadSubpath: "x86_64-windows/rundll32.exe",
                              crossoverSubpath: "lib/wine/x86_64-windows/rundll32.exe"),
                // wineserver: its server-side protocol version must match the swapped ntdll.so's client
                // version. Stock CrossOver ships an older wineserver, so leaving it in place makes every
                // wine process die with "wine client error:0: version mismatch …" before any window shows.
                // CrossOver installs the same binary at two paths; both must be replaced. This is also the
                // module that carries the ACE-CORE token-object fix (see docs/14-ace-core-regression.md).
                PayloadModule(payloadSubpath: "server/wineserver",
                              crossoverSubpath: "bin/wineserver"),
                PayloadModule(payloadSubpath: "server/wineserver",
                              crossoverSubpath: "CrossOver-Hosted Application/wineserver"),
                // Patched MoltenVK (Vulkan/DXVK/vkd3d paths; replaces CrossOver's bundled copy).
                // Built by scripts/build-moltenvk.sh and baked into the payload by build-app.sh.
                PayloadModule(payloadSubpath: "lib64/libMoltenVK.dylib",
                              crossoverSubpath: "lib64/libMoltenVK.dylib"),
            ]
        case .arm:
            // An arm64 bottle only loads `aarch64-windows`, so these are ARM64 PE modules. Only
            // modules that stay compatible with stock CrossOver ARM are swapped: its ntdll.so and
            // wineserver can't be replaced, and the PE modules must come from the Wine release
            // CrossOver ARM is based on (11.21 for preview 20261111), whose wineserver request
            // numbers they use. Built by scripts/build-wine-arm.sh from patches/ARM.
            return [
                // ntoskrnl.exe em-backports, ACE-CORE fixes and the aarch64 shared page emulation
                PayloadModule(payloadSubpath: "aarch64-windows/ntoskrnl.exe",
                              crossoverSubpath: "lib/wine/aarch64-windows/ntoskrnl.exe"),
                // Drops the visible helper window that hangs prefix creation on macOS 26.
                PayloadModule(payloadSubpath: "aarch64-windows/rundll32.exe",
                              crossoverSubpath: "lib/wine/aarch64-windows/rundll32.exe"),
                // Loader stub for ACE-CORE's ARM64 drivers, which import it. Wine doesn't ship it.
                PayloadModule(payloadSubpath: "aarch64-windows/wdfldr.sys",
                              crossoverSubpath: "lib/wine/aarch64-windows/wdfldr.sys", isNew: true),
                // The launcher-alpha fix, loaded into CrossOver ARM's own winemac.so (see ArmLauncherAlpha).
                PayloadModule(payloadSubpath: "aarch64-unix/fwalpha.dylib",
                              crossoverSubpath: "lib/wine/aarch64-unix/fwalpha.dylib", isNew: true),
                // The same patched MoltenVK as x64, built for arm64. CrossOver ARM's stock 1.2.10 has
                // the swapchain-recreate black window. Built by MVK_ARCH=aarch64 build-moltenvk.sh.
                PayloadModule(payloadSubpath: "lib/aarch64/libMoltenVK.dylib",
                              crossoverSubpath: "lib/aarch64/libMoltenVK.dylib"),
            ]
        }
    }
}

enum Payload {
    /// Directory containing the bundled pre-built modules for a variant.
    ///
    /// x64 keeps the legacy root layout (`Resources/payload/…`) so existing builds are untouched;
    /// ARM lives in a subdirectory (`Resources/payload/arm/…`). `FINEWINE_PAYLOAD_DIR` overrides
    /// the x64 root for development (`swift run`).
    static func directory(for variant: CrossOverVariant) -> URL? {
        switch variant {
        case .x64:
            if let override = ProcessInfo.processInfo.environment["FINEWINE_PAYLOAD_DIR"] {
                let url = URL(fileURLWithPath: override, isDirectory: true)
                if FileManager.default.fileExists(atPath: url.path) { return url }
            }
            guard let resources = Bundle.main.resourceURL else { return nil }
            let url = resources.appendingPathComponent("payload", isDirectory: true)
            return FileManager.default.fileExists(atPath: url.path) ? url : nil
        case .arm:
            guard let resources = Bundle.main.resourceURL else { return nil }
            let url = resources.appendingPathComponent("payload", isDirectory: true)
                .appendingPathComponent(variant.rawValue, isDirectory: true)
            return FileManager.default.fileExists(atPath: url.path) ? url : nil
        }
    }

    static func isComplete(for variant: CrossOverVariant) -> Bool {
        guard let dir = directory(for: variant) else { return false }
        return variant.modules.allSatisfy {
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

    /// The `wine` folder next to `external` that holds the D3DMetal glue built for this version
    /// (`x86_64-windows/*.dll` plus the `x86_64-unix` links into `libd3dshared.dylib`) — the
    /// DMG's `redist/lib/wine` or a CrossOver app's `apple_gptk/wine`. Nil when there is none.
    let glue: URL?

    var id: String { url.path }

    var displayName: String {
        if let version, !version.isEmpty { return "\(volumeName) — D3DMetal \(version)" }
        return volumeName
    }

    /// D3DMetal 4.x is the GPTK4 release that adds the Metal 4 / MetalFX features.
    var isVersion4: Bool { version?.hasPrefix("4") == true }

    /// D3DMetal versions that still run behind CrossOver 26.3's own D3DMetal 3.0 glue. From 4.0b3
    /// on, the glue calls into the framework through a jump table, so the 3.0 glue passes it
    /// garbage: d3d11.dll faults in its DllMain and the process hangs on the loader lock (the CN
    /// Gryphline launcher with 4.0b3 over the 3.0 glue).
    static let versionsCompatibleWithStockGlue = ["3", "4.0b1", "4.0b2"]

    /// True when this D3DMetal can't be paired with CrossOver 26.3's stock glue and needs its own.
    var needsMatchingGlue: Bool { Self.needsMatchingGlue(version: version) }

    static func needsMatchingGlue(version: String?) -> Bool {
        guard let version, !version.isEmpty else { return true }
        return !versionsCompatibleWithStockGlue.contains { prefix in
            prefix.contains(".") ? version == prefix : version.hasPrefix(prefix + ".") || version == prefix
        }
    }

    /// Why this source can't be installed, or nil when it can.
    var installProblem: String? {
        guard needsMatchingGlue, glue == nil else { return nil }
        return "D3DMetal \(version ?? "(unknown version)") needs the D3DMetal DLLs built with it, and none were found next to \(url.lastPathComponent) (expected …/redist/lib/wine/x86_64-windows). With CrossOver's D3DMetal 3.0 DLLs it crashes every DirectX 11 program, including the Gryphline launcher. Choose the whole mounted DMG, or keep CrossOver's bundled D3DMetal."
    }

    init?(url: URL) {
        let fm = FileManager.default
        let lib = url.appendingPathComponent("libd3dshared.dylib")
        let plist = url.appendingPathComponent("D3DMetal.framework/Resources/Info.plist")
        guard fm.fileExists(atPath: lib.path),
              fm.fileExists(atPath: url.appendingPathComponent("D3DMetal.framework").path) else { return nil }
        self.url = url
        self.version = Self.frameworkVersion(plist)
        self.glue = Self.glueFolder(besides: url)
        let parts = url.standardizedFileURL.pathComponents
        if parts.count >= 3, parts[1] == "Volumes" {
            volumeName = parts[2]
        } else if let app = parts.first(where: { $0.hasSuffix(".app") }) {
            volumeName = (app as NSString).deletingPathExtension
        } else {
            var cur = url
            while ["external", "lib", "redist"].contains(cur.lastPathComponent.lowercased()), cur.pathComponents.count > 1 {
                cur = cur.deletingLastPathComponent()
            }
            volumeName = cur.lastPathComponent
        }
    }

    /// The `wine` sibling of an `external` folder, when it has the D3D11 and DXGI glue DLLs.
    static func glueFolder(besides external: URL) -> URL? {
        let wine = external.deletingLastPathComponent().appendingPathComponent("wine", isDirectory: true)
        let windows = wine.appendingPathComponent("x86_64-windows", isDirectory: true)
        let fm = FileManager.default
        guard ["d3d11.dll", "dxgi.dll"].allSatisfy({ fm.fileExists(atPath: windows.appendingPathComponent($0).path) })
        else { return nil }
        return wine
    }

    private static func frameworkVersion(_ plist: URL) -> String? {
        guard let data = try? Data(contentsOf: plist),
              let parsed = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        else { return nil }
        return parsed["CFBundleShortVersionString"] as? String
    }

    /// Attaches a DMG using hdiutil and returns the mounted volume URL if successful.
    @discardableResult
    static func attachDMG(_ dmgURL: URL) -> URL? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        p.arguments = ["attach", "-nobrowse", "-readonly", "-plist", dmgURL.path]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = Pipe()
        do {
            try p.run()
            p.waitUntilExit()
            guard p.terminationStatus == 0 else { return nil }
            let data = out.fileHandleForReading.readDataToEndOfFile()
            guard let plist = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
                  let entities = plist["system-entities"] as? [[String: Any]] else { return nil }
            for entity in entities {
                if let mountPoint = entity["mount-point"] as? String {
                    return URL(fileURLWithPath: mountPoint)
                }
            }
        } catch {
            return nil
        }
        return nil
    }

    /// Checks if a volume with the given name (or prefix) is already mounted under /Volumes.
    static func findMountedVolume(named name: String) -> URL? {
        let fm = FileManager.default
        guard let volumes = try? fm.contentsOfDirectory(at: URL(fileURLWithPath: "/Volumes"),
                                                        includingPropertiesForKeys: nil) else { return nil }
        let target = name.lowercased()
        return volumes.first {
            let n = $0.lastPathComponent.lowercased()
            return n == target || n.hasPrefix(target) || target.hasPrefix(n)
        }
    }

    /// Resolves a GPTKSource from a candidate URL (direct folder, volume, or .dmg file).
    static func resolve(from candidate: URL) -> GPTKSource? {
        let fm = FileManager.default
        let standard = candidate.standardizedFileURL

        // 1. If it's a DMG file directly
        if standard.pathExtension.lowercased() == "dmg" {
            let dmgBase = standard.deletingPathExtension().lastPathComponent
            if let existing = findMountedVolume(named: dmgBase), let src = resolve(from: existing) {
                return src
            }
            if let mounted = attachDMG(standard) {
                return resolve(from: mounted)
            }
            return nil
        }

        // 2. Direct match or standard subpaths
        let directSubpaths = [
            standard,
            standard.appendingPathComponent("redist/lib/external", isDirectory: true),
            standard.appendingPathComponent("lib/external", isDirectory: true),
            standard.appendingPathComponent("external", isDirectory: true),
            // A CrossOver app (e.g. CrossOver 27) — its D3DMetal comes with matching glue.
            standard.appendingPathComponent("Contents/SharedSupport/CrossOver/lib/apple_gptk/external", isDirectory: true),
            standard.appendingPathComponent("Contents/SharedSupport/CrossOver/lib64/apple_gptk/external", isDirectory: true),
        ]
        for path in directSubpaths {
            if let src = GPTKSource(url: path) {
                return src
            }
        }

        // 3. If candidate is a directory (such as /Volumes/Game Porting Toolkit), check for nested DMGs
        var isDir: ObjCBool = false
        if fm.fileExists(atPath: standard.path, isDirectory: &isDir), isDir.boolValue {
            if let contents = try? fm.contentsOfDirectory(at: standard, includingPropertiesForKeys: nil) {
                let dmgs = contents.filter { $0.pathExtension.lowercased() == "dmg" }
                    .sorted { a, b in
                        let aEval = a.lastPathComponent.lowercased().contains("evaluation")
                        let bEval = b.lastPathComponent.lowercased().contains("evaluation")
                        if aEval != bEval { return aEval }
                        return a.lastPathComponent < b.lastPathComponent
                    }
                for dmg in dmgs {
                    let dmgBase = dmg.deletingPathExtension().lastPathComponent
                    if let existing = findMountedVolume(named: dmgBase), let src = resolve(from: existing) {
                        return src
                    }
                    if let mounted = attachDMG(dmg) {
                        if let src = resolve(from: mounted) {
                            return src
                        }
                    }
                }
            }
        }

        return nil
    }

    /// Every GPTK redist currently mounted under /Volumes (`<volume>/redist/lib/external`),
    /// plus mounted volumes containing an inner evaluation environment DMG.
    static func detectMounted() -> [GPTKSource] {
        let fm = FileManager.default
        guard let volumes = try? fm.contentsOfDirectory(at: URL(fileURLWithPath: "/Volumes"),
                                                        includingPropertiesForKeys: nil) else { return [] }

        var results: [GPTKSource] = []
        var seen = Set<String>()

        // Pass 1: Direct check on all mounted volumes
        for vol in volumes {
            if let src = GPTKSource(url: vol.appendingPathComponent("redist/lib/external", isDirectory: true)) {
                if seen.insert(src.id).inserted { results.append(src) }
            }
        }

        // Pass 2: Check mounted volumes that contain an inner evaluation environment DMG
        // (such as "/Volumes/Game Porting Toolkit" which contains "Evaluation environment...dmg")
        for vol in volumes {
            if let src = resolve(from: vol) {
                if seen.insert(src.id).inserted { results.append(src) }
            }
        }

        // Pass 3: Convenience: check ~/Downloads for Evaluation / Game Porting Toolkit DMGs if nothing in /Volumes
        if results.isEmpty {
            let downloads = fm.homeDirectoryForCurrentUser.appendingPathComponent("Downloads")
            if let files = try? fm.contentsOfDirectory(at: downloads, includingPropertiesForKeys: nil) {
                let candidates = files.filter { url in
                    let name = url.lastPathComponent.lowercased()
                    return url.pathExtension.lowercased() == "dmg" &&
                           (name.contains("game_porting_toolkit") || name.contains("evaluation"))
                }
                for dmg in candidates {
                    if let src = resolve(from: dmg) {
                        if seen.insert(src.id).inserted { results.append(src) }
                    }
                }
            }
        }

        return results.sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
    }
}

/// What we know about a selected CrossOver.app — including which variant (x64 vs ARM/aarch64)
/// it is, detected from the bundle layout.
struct CrossOverInfo {
    let url: URL
    let version: String?
    /// CFBundleVersion — CrossOver's exact build. Point builds of "26.3" ship different Wine
    /// modules (which is why wineserver has to be swapped too), so this is the field to quote when
    /// a report only works on one build. Reported (anonymously) with patch statistics.
    let build: String?
    let bundleIdentifier: String?
    /// `nil` when this looks like neither known CrossOver layout.
    let variant: CrossOverVariant?
    let hasWineModules: Bool

    /// For x64 the Wine ABI must match, so a non-26.3 version is a warning. ARM releases are
    /// date-versioned previews detected structurally, so any detected ARM app counts as expected.
    var isExpectedVersion: Bool {
        switch variant {
        case .x64: return version?.hasPrefix(CrossOverVariant.x64.expectedVersion) == true
        case .arm: return true
        case nil:  return false
        }
    }

    var displayName: String { url.deletingPathExtension().lastPathComponent }
    /// "26.3.0 (39832)" — version and build for the UI and reports.
    var displayVersion: String {
        let version = version ?? "unknown"
        guard let build, !build.isEmpty, build != version else { return version }
        return "\(version) (build \(build))"
    }

    init(url: URL) {
        self.url = url
        var plist: [String: Any] = [:]
        if let data = try? Data(contentsOf: url.appendingPathComponent("Contents/Info.plist")),
           let parsed = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] {
            plist = parsed
        }
        version = plist["CFBundleShortVersionString"] as? String
        build = plist["CFBundleVersion"] as? String
        bundleIdentifier = plist["CFBundleIdentifier"] as? String

        let fm = FileManager.default
        let cxr = url.appendingPathComponent("Contents/SharedSupport/CrossOver")
        // Detect the variant structurally: the ARM app is the one carrying an aarch64 Wine tree.
        let armTree = cxr.appendingPathComponent("lib/wine/aarch64-unix/ntdll.so")
        let x64Tree = cxr.appendingPathComponent("lib/wine/x86_64-unix/ntdll.so")
        let x64Libs = cxr.appendingPathComponent("lib64/libMoltenVK.dylib")
        if fm.fileExists(atPath: armTree.path) {
            variant = .arm
        } else if fm.fileExists(atPath: x64Tree.path), fm.fileExists(atPath: x64Libs.path) {
            variant = .x64
        } else {
            variant = nil
        }

        // `isNew` modules (e.g. lsass.exe) are added by us and are absent from stock CrossOver,
        // so only the modules CrossOver already ships decide whether this looks patchable.
        hasWineModules = variant.map { v in
            v.modules.filter { !$0.isNew }.allSatisfy {
                fm.fileExists(atPath: cxr.appendingPathComponent($0.crossoverSubpath).path)
            }
        } ?? false
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
    /// Set after a patch run finishes. The UI presents it with an explicit send/skip choice.
    @Published var telemetryPrompt: UsageTelemetry.Prompt?

    // MARK: Mod (EFMI) chain phase (bottle-side; independent of the app patch above)

    @Published private(set) var modSteps: [Step] = []
    @Published private(set) var modIsRunning = false
    @Published var modError: String?
    @Published private(set) var modAppliedPlan: ChainPlan?

    // MARK: Metal HUD (optional Tools phase; bottle-side)

    @Published private(set) var hudSteps: [Step] = []
    @Published private(set) var hudIsRunning = false
    @Published var hudError: String?

    private static let hudStepLabels = [
        "Writing MTL_HUD_ENABLED into the bottle",
        "Updating related macOS launchers",
    ]

    private static let hudRevertLabels = [
        "Removing MTL_HUD_ENABLED from the bottle",
        "Restoring macOS launchers",
    ]

    private static let modStepLabels = [
        "Backing up d3dx.ini",
        "Staging the backend d3d11.dll",
        "Writing the chain into d3dx.ini",
        "Verifying",
    ]

    private static let modRevertLabels = [
        "Undoing the d3dx.ini edit",
        "Removing staged files",
    ]

    func modReset() {
        modSteps = []
        modError = nil
        modAppliedPlan = nil
    }

    func applyModChain(plan: ChainPlan) {
        guard !isRunning, !modIsRunning else { return }
        modReset()
        modIsRunning = true
        modSteps = Self.modStepLabels.enumerated().map { Step(id: $0.offset, label: $0.element) }

        Task.detached(priority: .userInitiated) {
            var current = 0
            func begin(_ index: Int) async {
                current = index
                await MainActor.run { self.modSteps[index].status = .running }
            }
            func finish(_ index: Int) async {
                await MainActor.run { self.modSteps[index].status = .done }
            }
            do {
                await begin(0)
                try ModChain.backup(plan)
                await finish(0)

                await begin(1)
                try ModChain.stage(plan)
                await finish(1)

                await begin(2)
                let replaced = try ModChain.writeChain(plan)
                await finish(2)

                await begin(3)
                try ModChain.verify(plan)
                try ModChain.writeState(plan, replaced: replaced)
                await finish(3)

                await MainActor.run {
                    self.modAppliedPlan = plan
                    self.modIsRunning = false
                }
            } catch {
                let failed = current
                await MainActor.run {
                    self.modSteps[failed].status = .failed
                    self.modError = error.localizedDescription
                    self.modIsRunning = false
                }
            }
        }
    }

    func revertModChain(importerDir: URL) {
        guard !isRunning, !modIsRunning else { return }
        modReset()
        modIsRunning = true
        modSteps = Self.modRevertLabels.enumerated().map { Step(id: $0.offset, label: $0.element) }

        Task.detached(priority: .userInitiated) {
            do {
                try ModChain.revert(importerDir: importerDir)
                await MainActor.run {
                    self.modSteps[0].status = .done
                    self.modSteps[1].status = .done
                    self.modIsRunning = false
                }
            } catch {
                await MainActor.run {
                    self.modSteps[0].status = .failed
                    self.modError = error.localizedDescription
                    self.modIsRunning = false
                }
            }
        }
    }

    // MARK: - Steam / NotProton (optional Tools phase)

    @Published private(set) var notProtonSteps: [Step] = []
    @Published private(set) var notProtonIsRunning = false
    @Published var notProtonError: String?

    private static let notProtonRegisterLabels = [
        "Preparing directories",
        "Staging runner into NotProton",
        "Configuring Steam compatibility tool manifests",
        "Applying Endfield graphics defaults",
    ]

    private static let notProtonUnregisterLabels = [
        "Removing Steam compatibility tool entry",
        "Removing NotProton runner",
    ]

    func registerNotProton(app: URL) {
        guard !isRunning, !notProtonIsRunning else { return }
        notProtonSteps = []
        notProtonError = nil
        notProtonIsRunning = true
        notProtonSteps = Self.notProtonRegisterLabels.enumerated().map { Step(id: $0.offset, label: $0.element) }

        Task.detached(priority: .userInitiated) {
            func begin(_ index: Int) async {
                await MainActor.run { self.notProtonSteps[index].status = .running }
            }
            func finish(_ index: Int) async {
                await MainActor.run { self.notProtonSteps[index].status = .done }
            }
            do {
                await begin(0)
                try await Task.sleep(nanoseconds: 50_000_000)
                await finish(0)

                await begin(1)
                try NotProton.register(patchedApp: app)
                await finish(1)

                await begin(2)
                await finish(2)

                await begin(3)
                await finish(3)

                await MainActor.run {
                    self.notProtonIsRunning = false
                }
            } catch {
                await MainActor.run {
                    self.notProtonSteps[1].status = .failed
                    self.notProtonError = error.localizedDescription
                    self.notProtonIsRunning = false
                }
            }
        }
    }

    func unregisterNotProton() {
        guard !isRunning, !notProtonIsRunning else { return }
        notProtonSteps = []
        notProtonError = nil
        notProtonIsRunning = true
        notProtonSteps = Self.notProtonUnregisterLabels.enumerated().map { Step(id: $0.offset, label: $0.element) }

        Task.detached(priority: .userInitiated) {
            do {
                await MainActor.run { self.notProtonSteps[0].status = .running }
                try NotProton.unregister()
                await MainActor.run {
                    self.notProtonSteps[0].status = .done
                    self.notProtonSteps[1].status = .done
                    self.notProtonIsRunning = false
                }
            } catch {
                await MainActor.run {
                    self.notProtonSteps[0].status = .failed
                    self.notProtonError = error.localizedDescription
                    self.notProtonIsRunning = false
                }
            }
        }
    }

    func applyMetalHUD(plan: MetalHUD.Plan) {
        guard !isRunning, !hudIsRunning else { return }
        hudError = nil
        hudIsRunning = true
        hudSteps = Self.hudStepLabels.enumerated().map { Step(id: $0.offset, label: $0.element) }

        Task.detached(priority: .userInitiated) {
            do {
                await MainActor.run { self.hudSteps[0].status = .running }
                _ = try MetalHUD.apply(plan: plan)
                await MainActor.run {
                    self.hudSteps[0].status = .done
                    self.hudSteps[1].status = .done
                    self.hudIsRunning = false
                }
            } catch {
                await MainActor.run {
                    self.hudSteps[0].status = .failed
                    self.hudError = error.localizedDescription
                    self.hudIsRunning = false
                }
            }
        }
    }

    func revertMetalHUD(bottle: URL) {
        guard !isRunning, !hudIsRunning else { return }
        hudError = nil
        hudIsRunning = true
        hudSteps = Self.hudRevertLabels.enumerated().map { Step(id: $0.offset, label: $0.element) }

        Task.detached(priority: .userInitiated) {
            do {
                await MainActor.run { self.hudSteps[0].status = .running }
                try MetalHUD.revert(bottle: bottle)
                await MainActor.run {
                    self.hudSteps[0].status = .done
                    self.hudSteps[1].status = .done
                    self.hudIsRunning = false
                }
            } catch {
                await MainActor.run {
                    self.hudSteps[0].status = .failed
                    self.hudError = error.localizedDescription
                    self.hudIsRunning = false
                }
            }
        }
    }

    func setMetalHUDFPS(bottle: URL, fps: String?) {
        do {
            try MetalHUD.setFPSCap(bottle: bottle, fps: fps)
        } catch {
            self.hudError = error.localizedDescription
        }
    }

    func stopBottle(bottle: URL) {
        do {
            try MetalHUD.stopBottle(bottle: bottle, app: patchedApp)
        } catch {
            self.hudError = error.localizedDescription
        }
    }

    // MARK: - Sikarugir Engine (optional Tools phase)

    @Published private(set) var sikarugirSteps: [Step] = []
    @Published private(set) var sikarugirIsRunning = false
    @Published var sikarugirError: String?

    private static let sikarugirInstallLabels = [
        "Preparing Sikarugir engines directory",
        "Extracting engine tarball",
        "Verifying engine",
    ]

    private static let sikarugirRemoveLabels = [
        "Removing FineWine engine from Sikarugir",
    ]

    func installSikarugirEngine(tarball: URL) {
        guard !isRunning, !sikarugirIsRunning else { return }
        sikarugirSteps = []
        sikarugirError = nil
        sikarugirIsRunning = true
        sikarugirSteps = Self.sikarugirInstallLabels.enumerated().map { Step(id: $0.offset, label: $0.element) }

        Task.detached(priority: .userInitiated) {
            func begin(_ index: Int) async {
                await MainActor.run { self.sikarugirSteps[index].status = .running }
            }
            func finish(_ index: Int) async {
                await MainActor.run { self.sikarugirSteps[index].status = .done }
            }
            do {
                await begin(0)
                try await Task.sleep(nanoseconds: 50_000_000)
                await finish(0)

                await begin(1)
                try Sikarugir.installEngine(tarball: tarball)
                await finish(1)

                await begin(2)
                await finish(2)

                await MainActor.run {
                    self.sikarugirIsRunning = false
                }
            } catch {
                let msg = error.localizedDescription
                await MainActor.run {
                    if self.sikarugirSteps.indices.contains(1) {
                        self.sikarugirSteps[1].status = .failed
                    }
                    self.sikarugirError = msg
                    self.sikarugirIsRunning = false
                }
            }
        }
    }

    func removeSikarugirEngine() {
        guard !isRunning, !sikarugirIsRunning else { return }
        sikarugirSteps = []
        sikarugirError = nil
        sikarugirIsRunning = true
        sikarugirSteps = Self.sikarugirRemoveLabels.enumerated().map { Step(id: $0.offset, label: $0.element) }

        Task.detached(priority: .userInitiated) {
            do {
                await MainActor.run { self.sikarugirSteps[0].status = .running }
                try Sikarugir.removeEngine()
                await MainActor.run {
                    self.sikarugirSteps[0].status = .done
                    self.sikarugirIsRunning = false
                }
            } catch {
                let msg = error.localizedDescription
                await MainActor.run {
                    self.sikarugirSteps[0].status = .failed
                    self.sikarugirError = msg
                    self.sikarugirIsRunning = false
                }
            }
        }
    }

    // MARK: - GPTK Upgrade In Place

    @Published private(set) var gptkUpgradeSteps: [Step] = []
    @Published private(set) var gptkUpgradeIsRunning = false
    @Published var gptkUpgradeError: String?

    private static let gptkUpgradeLabels = [
        "Installing GPTK / D3DMetal",
        "Re-sealing the bundle",
        "Verifying",
    ]

    @Published private(set) var d3dMetalRepairIsRunning = false
    @Published var d3dMetalRepairResult: String?
    @Published var d3dMetalRepairError: String?

    /// Repairs a patched copy whose D3DMetal framework and DLLs don't match (see D3DMetalRepair),
    /// then re-seals it.
    func repairD3DMetal(in patchedApp: URL) {
        guard !isRunning, !gptkUpgradeIsRunning, !d3dMetalRepairIsRunning else { return }
        d3dMetalRepairIsRunning = true
        d3dMetalRepairResult = nil
        d3dMetalRepairError = nil
        Task.detached(priority: .userInitiated) {
            do {
                let result = try Self.repairD3DMetalNow(in: patchedApp)
                await MainActor.run {
                    self.d3dMetalRepairResult = result
                    self.d3dMetalRepairIsRunning = false
                }
            } catch {
                await MainActor.run {
                    self.d3dMetalRepairError = error.localizedDescription
                    self.d3dMetalRepairIsRunning = false
                }
            }
        }
    }

    /// The synchronous repair, shared with Automated Setup: repair, re-seal, re-check.
    nonisolated static func repairD3DMetalNow(in patchedApp: URL) throws -> String {
        let result = try D3DMetalRepair.repair(in: patchedApp, sources: D3DMetalRepair.candidateSources())
        try resealBundle(patchedApp)
        if let left = D3DMetalRepair.mismatch(in: patchedApp) { throw PatchError(left.summary) }
        return result
    }

    /// Replaces the D3DMetal in an already-patched CrossOver with a different GPTK version,
    /// without re-running the full copy+patch pipeline.
    func upgradeGPTK(in patchedApp: URL, from gptk: GPTKSource) {
        guard !isRunning, !gptkUpgradeIsRunning else { return }
        guard let variant = CrossOverInfo(url: patchedApp).variant else {
            gptkUpgradeError = "\(patchedApp.lastPathComponent) is not a recognized CrossOver layout."
            return
        }
        guard variant.supportsD3DMetal else {
            gptkUpgradeError = "D3DMetal is x86_64-only, so it can't run on the \(variant.displayName) variant."
            return
        }
        if let problem = gptk.installProblem {
            gptkUpgradeError = problem
            return
        }
        gptkUpgradeError = nil
        gptkUpgradeIsRunning = true
        gptkUpgradeSteps = Self.gptkUpgradeLabels.enumerated().map { Step(id: $0.offset, label: $0.element) }

        Task.detached(priority: .userInitiated) {
            var current = 0
            func begin(_ index: Int) async {
                current = index
                await MainActor.run { self.gptkUpgradeSteps[index].status = .running }
            }
            func finish(_ index: Int) async {
                await MainActor.run { self.gptkUpgradeSteps[index].status = .done }
            }
            do {
                await begin(0)
                try Self.installGPTK(into: patchedApp, from: gptk, variant: variant)
                await finish(0)

                await begin(1)
                try Self.resealBundle(patchedApp)
                await finish(1)

                await begin(2)
                // Verify only the GPTK half — the Wine modules haven't changed.
                guard let payloadDir = Payload.directory(for: variant) else {
                    throw PatchError("Payload directory not available for verification.")
                }
                try Self.verify(patchedApp, payloadDir: payloadDir, gptk: gptk, variant: variant)
                await finish(2)

                await MainActor.run {
                    self.patchedApp = patchedApp
                    self.gptkUpgradeIsRunning = false
                }
            } catch {
                let failed = current
                await MainActor.run {
                    self.gptkUpgradeSteps[failed].status = .failed
                    self.gptkUpgradeError = error.localizedDescription
                    self.gptkUpgradeIsRunning = false
                }
            }
        }
    }

    nonisolated static let originalBundleIdentifier = "com.codeweavers.CrossOver"
    nonisolated static var patchedBundleIdentifier: String {
        if let env = ProcessInfo.processInfo.environment["BUNDLE_ID"], env.count == originalBundleIdentifier.count {
            return env
        }
        return "com.codeweavers.CrossOvEF"
    }

    private static func stepLabels(includingRosetta: Bool, includingGPTK: Bool) -> [String] {
        var labels = includingRosetta ? ["Checking / installing Rosetta 2"] : []
        labels += [
            "Copying CrossOver",
            "Installing the patched modules",
        ]
        if includingGPTK { labels.append("Installing GPTK4 / D3DMetal") }
        labels += [
            "Patching bundle ID and launcher seeds",
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
        telemetryPrompt = nil
    }

    /// - Parameter reportTelemetry: `false` for a patch run that is part of a larger Automated
    ///   Setup run — that run asks once at the end instead of prompting twice.
    func patch(source: URL, variant: CrossOverVariant, destination: URL, gptk: GPTKSource? = nil, reportTelemetry: Bool = true) {
        guard !isRunning else { return }
        guard let payloadDir = Payload.directory(for: variant), Payload.isComplete(for: variant) else {
            errorMessage = variant.isExperimental
                ? "This build of the patcher has no \(variant.displayName) module payload yet. Build it with scripts/build-wine-arm.sh (and stage it with build-app.sh). The \(CrossOverVariant.x64.displayName) payload is unaffected."
                : "This build of the patcher does not include the module payload (Wine + MoltenVK). Rebuild it with patcher-app/scripts/build-app.sh after scripts/build-wine.sh all and scripts/build-moltenvk.sh all."
            return
        }
        let gptk = variant.supportsD3DMetal ? gptk : nil
        if let problem = gptk?.installProblem {
            errorMessage = problem
            return
        }
        reset()
        isRunning = true
        steps = Self.stepLabels(includingRosetta: variant.requiresRosetta, includingGPTK: gptk != nil)
            .enumerated().map { Step(id: $0.offset, label: $0.element) }
        let patchStartedAt = Date()
        // Recorded with the (optional) statistics: CrossOver point builds of the same version can
        // ship different Wine modules, and this is what identifies the source app in a report.
        let crossOverBuild = CrossOverInfo(url: source).build

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

                if variant.requiresRosetta {
                    await begin(index)
                    try RosettaSupport.ensureInstalled()
                    await finish(index); index += 1
                }

                await begin(index)
                let app = try Self.copyBundle(from: source, to: destination)
                staged = app
                await finish(index); index += 1

                await begin(index)
                try Self.installModules(into: app, from: payloadDir, variant: variant)
                if variant == .arm {
                    try ArmNtdllFix.apply(toCrossOverRoot: Self.cxRoot(app))
                    try ArmLauncherAlpha.apply(toCrossOverRoot: Self.cxRoot(app)) {
                        _ = try Self.run("/usr/bin/codesign", ["--force", "--sign", "-", $0.path])
                    }
                    // A compatibility setting; an unknown emulator build is left as it is.
                    _ = try? ArmEmulatorIdentity.apply(toCrossOverRoot: Self.cxRoot(app))
                }
                await finish(index); index += 1

                if let gptk {
                    await begin(index)
                    try Self.installGPTK(into: app, from: gptk, variant: variant)
                    await finish(index); index += 1
                }

                await begin(index)
                try Self.patchBundleIdentifier(in: app, variant: variant)
                await finish(index); index += 1

                await begin(index)
                try Self.resealBundle(app)
                await finish(index); index += 1

                await begin(index)
                try Self.verify(app, payloadDir: payloadDir, gptk: gptk, variant: variant)
                await finish(index); index += 1

                await begin(index)
                try Self.moveIntoPlace(app, destination: destination)
                await finish(index); index += 1

                let elapsed = Int(Date().timeIntervalSince(patchStartedAt))
                var prompt: UsageTelemetry.Prompt? = UsageTelemetry.makePatchPrompt(
                    succeeded: true, gptk: gptk != nil, failedStep: nil, durationSeconds: elapsed,
                    crossOverBuild: crossOverBuild)
                if !reportTelemetry { prompt = nil }
                let promptToSend = prompt
                await MainActor.run {
                    self.patchedApp = destination
                    self.isRunning = false
                    self.telemetryPrompt = promptToSend
                }
            } catch {
                let failed = current
                let elapsed = Int(Date().timeIntervalSince(patchStartedAt))
                var prompt: UsageTelemetry.Prompt? = UsageTelemetry.makePatchPrompt(
                    succeeded: false, gptk: gptk != nil, failedStep: failed, durationSeconds: elapsed,
                    crossOverBuild: crossOverBuild)
                if !reportTelemetry { prompt = nil }
                let promptToSend = prompt
                await MainActor.run {
                    if failed < self.steps.count { self.steps[failed].status = .failed }
                    self.errorMessage = error.localizedDescription
                    self.isRunning = false
                    self.telemetryPrompt = promptToSend
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

    private nonisolated static func installModules(into app: URL, from payloadDir: URL, variant: CrossOverVariant) throws {
        let fm = FileManager.default
        let cxr = cxRoot(app)
        for module in variant.modules {
            let src = payloadDir.appendingPathComponent(module.payloadSubpath)
            let dst = cxr.appendingPathComponent(module.crossoverSubpath)
            guard fm.fileExists(atPath: src.path) else {
                throw PatchError("The bundled \(variant.displayName) payload is missing \(module.payloadSubpath).")
            }
            if fm.fileExists(atPath: dst.path) {
                // Move the stock module aside under the same backup name the shell script uses, so
                // the payload lands as a fresh file rather than overwriting a signed one in place.
                let backup = dst.appendingPathExtension("cxorig")
                if fm.fileExists(atPath: backup.path) {
                    try fm.removeItem(at: dst)
                } else {
                    try fm.moveItem(at: dst, to: backup)
                }
            } else if !module.isNew {
                throw PatchError("\(module.crossoverSubpath) not found in the copied app — is this really CrossOver \(variant.expectedVersion) (\(variant.displayName))?")
            }
            try fm.copyItem(at: src, to: dst)
            // Only the Mach-O modules (ntdll.so, libMoltenVK.dylib, wineserver) need a signature
            // of their own to load on Apple Silicon. The PE modules are covered by the bundle
            // seal, as in stock CrossOver.
            if requiresOwnSignature(dst) {
                try run("/usr/bin/codesign", ["--force", "--sign", "-", dst.path])
            }
        }
    }

    /// Installs Apple's GPTK4 / D3DMetal (the user's own mounted DMG) over CrossOver's bundled
    /// D3DMetal. `lib64/apple_gptk/external/` is replaced, and so is `lib64/apple_gptk/wine/` when
    /// the source carries the glue built with that D3DMetal: the glue's `x86_64-unix` modules
    /// symlink into `external`, so the whole D3D11/D3D12/DXGI/DLSS (NVNGX) stack upgrades at once.
    /// D3DMetal 4.0b3+ requires that glue (see `GPTKSource.needsMatchingGlue`). No
    /// `lib/wine/.../{d3d11,d3d12,dxgi}.dll` is touched (dropping Apple's DLLs there breaks
    /// `unityplayer.dll`, Windows error 1114). Mirrors scripts/swap-into-crossover.sh step 3.
    private nonisolated static func installGPTK(into app: URL, from gptk: GPTKSource, variant: CrossOverVariant) throws {
        if let problem = gptk.installProblem { throw PatchError(problem) }
        let gptkExternal = gptk.url
        let fm = FileManager.default
        let cxr = cxRoot(app)
        let gptkPrefix = cxr.appendingPathComponent(variant.gptkPrefixSubpath, isDirectory: true)
        let dest = gptkPrefix.appendingPathComponent("external", isDirectory: true)
        guard fm.fileExists(atPath: dest.path) else {
            throw PatchError("\(variant.gptkPrefixSubpath)/external not found in the copied app — is this really CrossOver \(variant.expectedVersion)?")
        }
        let lib = gptkExternal.appendingPathComponent("libd3dshared.dylib")
        let framework = gptkExternal.appendingPathComponent("D3DMetal.framework", isDirectory: true)
        guard fm.fileExists(atPath: lib.path), fm.fileExists(atPath: framework.path) else {
            throw PatchError("That folder is not a GPTK redist — expected D3DMetal.framework and libd3dshared.dylib inside it (…/redist/lib/external).")
        }
        if let glue = gptk.glue { try installGlue(glue, into: gptkPrefix) }
        // Re-running the patcher with the same GPTK already installed is a no-op.
        if externalMatches(source: gptkExternal, destination: dest) { return }

        let backup = gptkPrefix.appendingPathComponent("external.cxorig", isDirectory: true)
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

    /// Replaces `apple_gptk/wine` with the glue that was built with the D3DMetal being installed,
    /// keeping CrossOver's own as `wine.cxorig`. Every `x86_64-unix` module must be a link into
    /// `external` (CrossOver's layout); a glue folder without that half gets the links made from
    /// its DLL names.
    nonisolated static func installGlue(_ glue: URL, into gptkPrefix: URL) throws {
        let fm = FileManager.default
        let dest = gptkPrefix.appendingPathComponent("wine", isDirectory: true)
        let srcWindows = glue.appendingPathComponent("x86_64-windows", isDirectory: true)
        if let a = try? fm.contentsOfDirectory(atPath: srcWindows.path).sorted(),
           let b = try? fm.contentsOfDirectory(atPath: dest.appendingPathComponent("x86_64-windows").path).sorted(),
           a == b, a.allSatisfy({
               hash(srcWindows.appendingPathComponent($0)) == hash(dest.appendingPathComponent("x86_64-windows/\($0)"))
           }) { return }

        let backup = gptkPrefix.appendingPathComponent("wine.cxorig", isDirectory: true)
        if fm.fileExists(atPath: backup.path) { try? fm.removeItem(at: backup) }
        if fm.fileExists(atPath: dest.path) { try fm.moveItem(at: dest, to: backup) }
        do {
            let windows = dest.appendingPathComponent("x86_64-windows", isDirectory: true)
            let unix = dest.appendingPathComponent("x86_64-unix", isDirectory: true)
            try fm.createDirectory(at: unix, withIntermediateDirectories: true)
            try run("/usr/bin/ditto", ["--noextattr", "--noqtn", srcWindows.path + "/", windows.path])
            let target = "../../external/libd3dshared.dylib"
            let srcUnix = glue.appendingPathComponent("x86_64-unix", isDirectory: true)
            var names = (try? fm.contentsOfDirectory(atPath: srcUnix.path)) ?? []
            if names.isEmpty {
                names = try fm.contentsOfDirectory(atPath: windows.path)
                    .filter { $0.lowercased().hasSuffix(".dll") }
                    .map { ($0 as NSString).deletingPathExtension + ".so" }
            }
            for name in names where name.hasSuffix(".so") {
                try fm.createSymbolicLink(atPath: unix.appendingPathComponent(name).path, withDestinationPath: target)
            }
        } catch {
            try? fm.removeItem(at: dest)
            if fm.fileExists(atPath: backup.path) { try? fm.moveItem(at: backup, to: dest) }
            throw error
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

    /// Mach-O payload modules that need a signature of their own to load on Apple Silicon.
    /// `wineserver` has no extension but is a signed Mach-O executable like the `.so`/`.dylib`
    /// libraries, so it must be treated the same when signing and when stripping for comparison.
    /// `rundll32.exe` is likewise an exec'd Mach-O (the PE header rides inside); unlike the other
    /// PE builtins it is never only mapped, so an unsigned copy gets killed before main().
    private nonisolated static func requiresOwnSignature(_ url: URL) -> Bool {
        let ext = url.pathExtension
        return ext == "so" || ext == "dylib"
            || url.lastPathComponent == "wineserver" || url.lastPathComponent == "rundll32.exe"
    }

    /// Content hash of a module with any embedded code signature removed. The Mach-O modules
    /// (ntdll.so, libMoltenVK.dylib, wineserver) are ad-hoc re-signed after the swap; because
    /// codesign's ad-hoc signature bytes differ across macOS/codesign versions, comparing the
    /// signed file directly would report a false mismatch. Stripping the signature makes the
    /// comparison depend only on the actual code. PE modules carry no embedded signature and are
    /// hashed as-is.
    nonisolated static func contentHash(_ url: URL) -> Data? {
        guard let raw = try? Data(contentsOf: url, options: .alwaysMapped) else { return nil }
        guard requiresOwnSignature(url) else {
            return Data(SHA256.hash(data: raw))
        }
        let fm = FileManager.default
        // codesign --remove-signature needs a writable file, so strip it from a temp copy.
        // The file name itself is irrelevant here (we never sign), so a unique name is fine.
        let tmp = fm.temporaryDirectory
            .appendingPathComponent("fw-content-\(UUID().uuidString)-\(url.lastPathComponent)")
        defer { try? fm.removeItem(at: tmp) }
        do {
            try fm.copyItem(at: url, to: tmp)
            // Removing a signature does not fully undo signing: codesign records the signature's
            // allocation in the Mach-O's __LINKEDIT vmsize, and stripping from a CI/Developer-ID
            // signed payload can leave different header bytes than stripping a locally ad-hoc
            // signed copy. Re-sign both sides with the local ad-hoc identity first, so the
            // signature layout (and therefore the stripped bytes) is canonical.
            guard (try? run("/usr/bin/codesign", ["--force", "--sign", "-", "--identifier",
                                                   "io.github.stoicswe.FineWinePatcher.content-hash",
                                                   tmp.path])) != nil else {
                return nil
            }
            guard (try? run("/usr/bin/codesign", ["--remove-signature", tmp.path])) != nil else {
                return nil
            }
            let stripped = try Data(contentsOf: tmp, options: .alwaysMapped)
            return Data(SHA256.hash(data: stripped))
        } catch {
            return nil
        }
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
    nonisolated static func resealBundle(_ app: URL) throws {
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

    private nonisolated static func verify(_ app: URL, payloadDir: URL, gptk: GPTKSource?, variant: CrossOverVariant) throws {
        let cxr = cxRoot(app)
        for module in variant.modules {
            let src = payloadDir.appendingPathComponent(module.payloadSubpath)
            let dst = cxr.appendingPathComponent(module.crossoverSubpath)
            // Compare module *content*, not raw bytes. The Mach-O modules are re-signed
            // (ad-hoc) after the swap, and ad-hoc signatures are not byte-identical across
            // codesign versions (the CI build runner's macOS vs. the user's), so a raw
            // size/hash comparison fails even when the swap is perfectly fine.
            // contentHash() strips the embedded signature first, so it is stable across
            // codesign versions.
            guard let a = contentHash(src), let b = contentHash(dst), a == b else {
                throw PatchError("\(module.crossoverSubpath) does not match the bundled payload after the swap.")
            }
        }
        if variant == .arm && !ArmLauncherAlpha.isApplied(inCrossOverRoot: cxr) {
            throw PatchError("The launcher black-margin fix is missing from winemac.so after patching.")
        }
        if variant == .arm && !ArmNtdllFix.isApplied(inCrossOverRoot: cxr) {
            throw PatchError("The ntdll.dll fix is missing after patching.")
        }
        // If the user supplied GPTK, confirm the D3DMetal external half really came across (the
        // installed libd3dshared.dylib must be byte-identical to the source they selected).
        if let gptk {
            let external = cxr.appendingPathComponent("\(variant.gptkPrefixSubpath)/external", isDirectory: true)
            let installed = external.appendingPathComponent("libd3dshared.dylib")
            guard FileManager.default.fileExists(atPath: installed.path),
                  FileManager.default.fileExists(atPath: external.appendingPathComponent("D3DMetal.framework/Versions/A/D3DMetal").path) else {
                throw PatchError("GPTK4 was not installed correctly — D3DMetal.framework or libd3dshared.dylib is missing from the patched app.")
            }
            guard let src = hash(gptk.url.appendingPathComponent("libd3dshared.dylib")),
                  let dst = hash(installed), src == dst else {
                throw PatchError("The installed GPTK4 libd3dshared.dylib does not match the source you selected.")
            }
            if let glue = gptk.glue {
                let installedDll = cxr.appendingPathComponent("\(variant.gptkPrefixSubpath)/wine/x86_64-windows/d3d11.dll")
                guard let src = hash(glue.appendingPathComponent("x86_64-windows/d3d11.dll")),
                      let dst = hash(installedDll), src == dst else {
                    throw PatchError("The D3DMetal DLLs that came with GPTK4 were not installed — its d3d11.dll is missing from the patched app.")
                }
            }
        }
        // ntdll.so is the module the kernel actually checks; make sure its ad-hoc
        // signature is valid and that it carries the host-lib rpath (baked in at
        // app-build time) — without that rpath cxcompatdb.so can't load and
        // D3DMetal never engages.
        let ntdll = cxr.appendingPathComponent("lib/wine/\(variant.hostArch)-unix/ntdll.so")
        try run("/usr/bin/codesign", ["--verify", ntdll.path])
        let data = try Data(contentsOf: ntdll, options: .alwaysMapped)
        guard let needle = variant.requiredNtdllRpath.data(using: .utf8),
              data.range(of: needle) != nil else {
            throw PatchError("ntdll.so is missing the \(variant.hostLibSubpath) rpath — D3DMetal would not work. Rebuild the patcher with scripts/build-app.sh (it adds the rpath to the payload).")
        }
        // Verify bundle identifier
        let infoPlist = app.appendingPathComponent("Contents/Info.plist")
        guard let plistData = try? Data(contentsOf: infoPlist),
              let plist = (try? PropertyListSerialization.propertyList(from: plistData, format: nil)) as? [String: Any],
              let bid = plist["CFBundleIdentifier"] as? String,
              bid == variant.patchedBundleIdentifier else {
            throw PatchError("The patched app's CFBundleIdentifier was not set to \(variant.patchedBundleIdentifier).")
        }

        // The whole bundle must verify, or macOS reports it as damaged and kills its binaries.
        do {
            try run("/usr/bin/codesign", ["--verify", "--deep", "--strict", app.path])
        } catch {
            throw PatchError("The patched app's signature does not verify, so macOS would refuse to run it. \(error.localizedDescription)")
        }
    }

    /// Replaces the Menu Helper binaries in the seed launchers. CrossOver refreshes every bottle's
    /// launchers from whichever copy ran last, so a helper with a hardcoded bundle ID sends other
    /// bottles to that copy; the launcher's own command always names the right one. It also spares
    /// ARM the x86_64 helper's Rosetta dependency. `Menu Helper arm64` can't be patched at all: it
    /// is laid out like Wine's loader, so macOS kills it at exec under any other signature.
    /// Keep in sync with scripts/lib/menu-helper.sh.
    nonisolated static let menuHelperScript = """
    #!/bin/sh
    # Stands in for CrossOver's Menu Helper. The launcher's command names the right CrossOver copy.
    contents=$(cd "$(dirname "$0")/.." && pwd)
    command=$(/usr/bin/plutil -extract CrossOverHelperCommand raw "$contents/Info.plist") || exit 1
    eval "exec $command"

    """

    /// Patches the app's CFBundleIdentifier in Info.plist to the variant's patched ID and
    /// patches the seed launcher templates (`Contents/Resources/Menu Helper.cpbz2`, `Bottle
    /// Helper.cpbz2` and, on CrossOver ARM, `Menu Helper arm64.cpbz2`) so that launcher app
    /// bundles created by this patched CrossOver reference its bundle ID and always launch
    /// with the patched version. The Menu Helpers are replaced instead: see `menuHelperScript`.
    nonisolated static func patchBundleIdentifier(in app: URL, variant: CrossOverVariant) throws {
        let patchedBundleIdentifier = variant.patchedBundleIdentifier
        let fm = FileManager.default
        let infoPlist = app.appendingPathComponent("Contents/Info.plist")
        guard fm.fileExists(atPath: infoPlist.path) else {
            throw PatchError("Info.plist not found in staged app.")
        }
        guard let data = try? Data(contentsOf: infoPlist),
              var plist = (try? PropertyListSerialization.propertyList(from: data, options: .mutableContainersAndLeaves, format: nil)) as? [String: Any] else {
            throw PatchError("Failed to parse Info.plist in staged app.")
        }
        plist["CFBundleIdentifier"] = patchedBundleIdentifier
        let newData = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try newData.write(to: infoPlist, options: .atomic)

        let resDir = app.appendingPathComponent("Contents/Resources", isDirectory: true)
        let helpers = ["Menu Helper", "Menu Helper arm64", "Bottle Helper"]
        for helper in helpers {
            let cpbz2 = resDir.appendingPathComponent("\(helper).cpbz2")
            guard fm.fileExists(atPath: cpbz2.path) else { continue }
            let tmpDir = try fm.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: resDir, create: true)
            defer { try? fm.removeItem(at: tmpDir) }

            // Extract cpbz2
            try run("/bin/sh", ["-c", "cd '\(tmpDir.path)' && bzip2 -dc '\(cpbz2.path)' | cpio -idm 2>/dev/null"])

            // Patch Info.plist if present in helper
            let helperPlist = tmpDir.appendingPathComponent("Contents/Info.plist")
            if fm.fileExists(atPath: helperPlist.path),
               let hData = try? Data(contentsOf: helperPlist),
               var hPlist = (try? PropertyListSerialization.propertyList(from: hData, options: .mutableContainersAndLeaves, format: nil)) as? [String: Any] {
                if var secPolicy = hPlist["NSUpdateSecurityPolicy"] as? [String: Any],
                   var allowProc = secPolicy["AllowProcesses"] as? [String: [String]] {
                    for (k, arr) in allowProc {
                        allowProc[k] = arr.map { $0 == originalBundleIdentifier ? patchedBundleIdentifier : $0 }
                    }
                    secPolicy["AllowProcesses"] = allowProc
                    hPlist["NSUpdateSecurityPolicy"] = secPolicy
                    if let newHData = try? PropertyListSerialization.data(fromPropertyList: hPlist, format: .xml, options: 0) {
                        try? newHData.write(to: helperPlist, options: .atomic)
                    }
                }
            }

            // Patch Mach-O binary
            let bin = tmpDir.appendingPathComponent("Contents/MacOS/\(helper)")
            if helper.hasPrefix("Menu Helper"), fm.fileExists(atPath: bin.path) {
                try Data(menuHelperScript.utf8).write(to: bin, options: .atomic)
                try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: bin.path)
                for sealPath in ["Contents/_CodeSignature", "Contents/CodeResources"] {
                    let bundleSeal = tmpDir.appendingPathComponent(sealPath)
                    if fm.fileExists(atPath: bundleSeal.path) { try fm.removeItem(at: bundleSeal) }
                }
            } else if fm.fileExists(atPath: bin.path) {
                var binData = try Data(contentsOf: bin)
                guard let target = (originalBundleIdentifier + "\0").data(using: .utf8),
                      let replacement = (patchedBundleIdentifier + "\0").data(using: .utf8),
                      target.count == replacement.count else {
                    throw PatchError("Invalid bundle ID replacement length for \(helper).")
                }
                var replaced = false
                while let range = binData.range(of: target) {
                    binData.replaceSubrange(range, with: replacement)
                    replaced = true
                }
                if replaced {
                    try binData.write(to: bin, options: .atomic)
                    // Sign outside Contents so codesign treats this as a Mach-O, not an app
                    // bundle. CrossOver changes the helper's plist/resources when it creates
                    // a launcher, so the seed must not seal either of them.
                    let looseBin = tmpDir.appendingPathComponent(".\(helper).signing")
                    try fm.moveItem(at: bin, to: looseBin)
                    try run("/usr/bin/codesign", ["--force", "--sign", "-", "--options", "runtime",
                                                  "--timestamp=none", "--identifier", "com.codeweavers.CrossOver.\(helper)",
                                                  looseBin.path])
                    try fm.moveItem(at: looseBin, to: bin)
                    for sealPath in ["Contents/_CodeSignature", "Contents/CodeResources"] {
                        let bundleSeal = tmpDir.appendingPathComponent(sealPath)
                        if fm.fileExists(atPath: bundleSeal.path) { try fm.removeItem(at: bundleSeal) }
                    }
                }
            }

            // Repack cpbz2
            let tmpCpbz2 = tmpDir.appendingPathComponent("\(helper).cpbz2.tmp")
            try run("/bin/sh", ["-c", "cd '\(tmpDir.path)' && find . | cpio -o -H odc 2>/dev/null | bzip2 -c > '\(tmpCpbz2.path)'"])
            guard fm.fileExists(atPath: tmpCpbz2.path) else {
                throw PatchError("Failed to repack \(helper).cpbz2.")
            }
            try fm.removeItem(at: cpbz2)
            try fm.moveItem(at: tmpCpbz2, to: cpbz2)
        }
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
