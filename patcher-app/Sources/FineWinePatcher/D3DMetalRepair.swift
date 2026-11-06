import Foundation
import CryptoKit

/// Finds and repairs a patched CrossOver whose two D3DMetal halves don't belong together: the
/// framework in `apple_gptk/external` and the glue DLLs in `apple_gptk/wine` that call into it.
///
/// From D3DMetal 4.0b3 on, the glue reaches the framework through a jump table (its DLLs embed
/// `jump_table.h`); CrossOver 26.3's D3DMetal 3.0 glue doesn't, and passes such a framework
/// garbage — every DirectX 11 program faults in d3d11.dll's DllMain and then hangs on the loader
/// lock. Copies patched with a 4.0b3 GPTK before the patcher installed the matching glue are in
/// exactly that state.
enum D3DMetalRepair {

    struct Mismatch: Equatable {
        let frameworkVersion: String?
        let glueUsesJumpTable: Bool

        var summary: String {
            let framework = "D3DMetal \(frameworkVersion ?? "(unknown version)")"
            return glueUsesJumpTable
                ? "\(framework) is paired with newer D3DMetal DLLs it can't use — DirectX 11 programs crash on start."
                : "\(framework) is paired with CrossOver's D3DMetal 3.0 DLLs — every DirectX 11 program, including the Gryphline launcher, crashes on start."
        }
    }

    /// `apple_gptk` inside the app, for the D3DMetal-capable (x64) variant only.
    static func gptkPrefix(of app: URL) -> URL? {
        guard let variant = CrossOverInfo(url: app).variant, variant.supportsD3DMetal else { return nil }
        return app.appendingPathComponent("Contents/SharedSupport/CrossOver/\(variant.gptkPrefixSubpath)", isDirectory: true)
    }

    static func frameworkVersion(external: URL) -> String? {
        let plist = external.appendingPathComponent("D3DMetal.framework/Resources/Info.plist")
        guard let data = try? Data(contentsOf: plist),
              let parsed = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        else { return nil }
        return parsed["CFBundleShortVersionString"] as? String
    }

    /// Whether the glue's d3d11.dll is the jump-table kind; nil when there is no glue.
    static func glueUsesJumpTable(wine: URL) -> Bool? {
        let dll = wine.appendingPathComponent("x86_64-windows/d3d11.dll")
        guard let data = try? Data(contentsOf: dll, options: .alwaysMapped) else { return nil }
        return data.range(of: Data("jump_table.h".utf8)) != nil
    }

    /// Whether a framework of `version` runs behind glue of the given kind.
    static func isConsistent(frameworkVersion version: String?, glueUsesJumpTable jumpTable: Bool) -> Bool {
        if GPTKSource.needsMatchingGlue(version: version) { return jumpTable }
        // CrossOver's own D3DMetal 3.0 has only ever shipped with its 3.0 glue.
        if version?.hasPrefix("3") == true { return !jumpTable }
        return true   // 4.0b1 / 4.0b2 run behind either kind
    }

    static func mismatch(in app: URL) -> Mismatch? {
        guard let prefix = gptkPrefix(of: app) else { return nil }
        let external = prefix.appendingPathComponent("external", isDirectory: true)
        guard FileManager.default.fileExists(atPath: external.appendingPathComponent("D3DMetal.framework").path),
              let jumpTable = glueUsesJumpTable(wine: prefix.appendingPathComponent("wine", isDirectory: true))
        else { return nil }
        let version = frameworkVersion(external: external)
        return isConsistent(frameworkVersion: version, glueUsesJumpTable: jumpTable)
            ? nil : Mismatch(frameworkVersion: version, glueUsesJumpTable: jumpTable)
    }

    /// GPTK sources that carry glue: mounted DMGs, plus CrossOver apps in the Applications folders
    /// (CrossOver 27 ships D3DMetal 4.0b3 with its glue).
    static func candidateSources() -> [GPTKSource] {
        var sources = GPTKSource.detectMounted()
        let fm = FileManager.default
        let folders = ["/Applications", NSHomeDirectory() + "/Applications"]
        for folder in folders {
            for name in (try? fm.contentsOfDirectory(atPath: folder)) ?? []
            where name.hasSuffix(".app") && name.lowercased().contains("crossover") {
                if let source = GPTKSource.resolve(from: URL(fileURLWithPath: folder).appendingPathComponent(name)) {
                    sources.append(source)
                }
            }
        }
        return sources.filter { $0.glue != nil }
    }

    /// Makes the app's D3DMetal halves match again and returns what was done. Prefers keeping the
    /// installed framework (installing the glue built with that exact framework, from `sources`);
    /// otherwise restores the matching CrossOver original the patcher kept as `.cxorig`. The
    /// caller re-seals the bundle afterwards.
    static func repair(in app: URL, sources: [GPTKSource]) throws -> String {
        guard let mismatch = mismatch(in: app), let prefix = gptkPrefix(of: app) else {
            return "D3DMetal in \(app.lastPathComponent) is already consistent."
        }
        let fm = FileManager.default
        let external = prefix.appendingPathComponent("external", isDirectory: true)
        let wine = prefix.appendingPathComponent("wine", isDirectory: true)
        let installedFramework = hash(external.appendingPathComponent("D3DMetal.framework/Versions/A/D3DMetal"))

        // 1. Keep the installed D3DMetal: glue built with that very framework.
        if let source = sources.first(where: { source in
            source.glue != nil && installedFramework != nil
                && hash(source.url.appendingPathComponent("D3DMetal.framework/Versions/A/D3DMetal")) == installedFramework
        }), let glue = source.glue {
            try PatcherEngine.installGlue(glue, into: prefix)
            return "Installed the D3DMetal \(mismatch.frameworkVersion ?? "") DLLs from \(source.volumeName)."
        }

        // 2. Put CrossOver's own framework back when it matches the glue that is installed.
        let externalBackup = prefix.appendingPathComponent("external.cxorig", isDirectory: true)
        if fm.fileExists(atPath: externalBackup.appendingPathComponent("D3DMetal.framework").path) {
            let backupVersion = frameworkVersion(external: externalBackup)
            if isConsistent(frameworkVersion: backupVersion, glueUsesJumpTable: mismatch.glueUsesJumpTable) {
                try swap(externalBackup, into: external)
                return "Restored CrossOver's bundled D3DMetal \(backupVersion ?? ""); the D3DMetal \(mismatch.frameworkVersion ?? "") framework is kept as external.cxorig."
            }
        }

        // 3. Put CrossOver's own glue back when it matches the installed framework.
        let wineBackup = prefix.appendingPathComponent("wine.cxorig", isDirectory: true)
        if let backupJumpTable = glueUsesJumpTable(wine: wineBackup),
           isConsistent(frameworkVersion: mismatch.frameworkVersion, glueUsesJumpTable: backupJumpTable) {
            try swap(wineBackup, into: wine)
            return "Restored CrossOver's D3DMetal DLLs to match D3DMetal \(mismatch.frameworkVersion ?? "")."
        }

        throw PatchError("\(mismatch.summary) No matching D3DMetal DLLs were found and CrossOver's original D3DMetal isn't kept in the app. Mount the GPTK DMG it came from and repair again, or re-create the patched copy.")
    }

    /// Exchanges `backup` and `live`, so the replaced half stays available as the backup.
    private static func swap(_ backup: URL, into live: URL) throws {
        let fm = FileManager.default
        let parked = live.deletingLastPathComponent().appendingPathComponent(live.lastPathComponent + ".swap", isDirectory: true)
        try? fm.removeItem(at: parked)
        try fm.moveItem(at: live, to: parked)
        do {
            try fm.moveItem(at: backup, to: live)
        } catch {
            try? fm.moveItem(at: parked, to: live)
            throw error
        }
        try fm.moveItem(at: parked, to: backup)
    }

    private static func hash(_ url: URL) -> Data? {
        guard let data = try? Data(contentsOf: url, options: .alwaysMapped) else { return nil }
        return Data(SHA256.hash(data: data))
    }
}
