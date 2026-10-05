import Foundation
import CryptoKit

// MARK: - Mod (EFMI) chain support
//
// Points EFMI's d3dx.ini `[System] proxy_d3d11` at the *backend* d3d11.dll inside the patched
// app, so 3DMigoto hands off to CrossOver's D3D11→Metal backend instead of Wine's wined3d.
// Without it, 3DMigoto's default "original" resolution (C:\Windows\system32\d3d11.dll) ends at
// wined3d on every backend — see docs/mod-injection/07-load-ordering-and-chaining.md for the
// mechanism and docs/mod-injection/08-patcher-integration-plan.md for this phase's plan.
//
// The edit mirrors scripts/swap-into-crossover.sh's mod-chain step (that script is the reference
// implementation; both are verified byte-exact on revert, idempotent on re-run, and CRLF-safe).

/// The bottle graphics backends that have their own `d3d11.dll` to chain to.
enum ChainBackend: String, CaseIterable {
    case d3dmetal, dxmt, dxvk

    /// Where this backend's d3d11.dll lives inside Contents/SharedSupport/CrossOver/.
    /// Never Wine's wined3d copy — that is exactly what the chain has to get *past*.
    var crossoverSubpath: String {
        switch self {
        case .d3dmetal: return "lib64/apple_gptk/wine/x86_64-windows/d3d11.dll"
        case .dxmt:     return "lib/dxmt/x86_64-windows/d3d11.dll"
        case .dxvk:     return "lib/dxvk/x86_64-windows/d3d11.dll"
        }
    }

    var displayName: String {
        switch self {
        case .d3dmetal: return "D3DMetal"
        case .dxmt:     return "DXMT"
        case .dxvk:     return "DXVK"
        }
    }

    /// CrossOver writes the chosen backend into cxbottle.conf as
    ///   "CX_ACTIVE_GRAPHICS_BACKEND" = "dxmt"      (the one actually in use)
    ///   "CX_GRAPHICS_BACKEND"       = "dxmt"      (the user's choice)
    static func fromBottleConf(_ text: String?) -> ChainBackend? {
        guard let text else { return nil }
        for key in ["CX_ACTIVE_GRAPHICS_BACKEND", "CX_GRAPHICS_BACKEND"] {
            for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
                let line = raw.trimmingCharacters(in: .whitespaces)
                guard line.contains(key) else { continue }
                // form:  "KEY" = "value"
                let parts = line.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                guard parts.count == 2 else { continue }
                let lhs = parts[0].trimmingCharacters(in: .whitespaces)
                guard lhs == "\"\(key)\"" else { continue }
                let value = parts[1].trimmingCharacters(in: .whitespaces)
                    .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
                if let backend = ChainBackend(rawValue: value) { return backend }
            }
        }
        return nil
    }
}

/// One CrossOver bottle (a directory under ~/Library/Application Support/CrossOver/Bottles).
struct BottleInfo: Identifiable, Hashable {
    let url: URL
    /// nil = no backend configured (wined3d). In that case system32\d3d11.dll *is* the backend,
    /// so 3DMigoto's default chain is already correct and no `proxy_d3d11` is needed.
    let backend: ChainBackend?

    var id: String { url.lastPathComponent }
    var name: String { url.lastPathComponent }

    static func detectAll() -> [BottleInfo] {
        let root = bottlesRoot()
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey]) else {
            return []
        }
        return entries
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true }
            .compactMap { url -> BottleInfo? in
                let conf = url.appendingPathComponent("cxbottle.conf")
                guard let text = try? String(contentsOf: conf, encoding: .utf8) else { return nil }
                return BottleInfo(url: url, backend: ChainBackend.fromBottleConf(text))
            }
            .sorted { $0.name < $1.name }
    }

    static func bottlesRoot() -> URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home.appendingPathComponent("Library/Application Support/CrossOver/Bottles", isDirectory: true)
    }
}

/// Everything the mod-chain phase needs, resolved up-front so the UI can show it before applying.
struct ChainPlan {
    enum Mode: String {
        /// Point proxy_d3d11 at the backend dll through the bottle's Z: drive (no files staged).
        case path
        /// Copy the backend dll next to EFMI's d3d11.dll and reference it relatively. Used when
        /// the bottle has no Z: → / mapping, and available on demand for path robustness.
        case copy
    }

    let patchedApp: URL
    let bottle: URL
    let backend: ChainBackend
    let importerDir: URL
    let d3dxIni: URL
    let mode: Mode
    /// The backend d3d11.dll inside the patched app (the chain source).
    let sourceFile: URL
    /// The value written to proxy_d3d11 — what 3DMigoto will LoadLibrary.
    let target: String
    /// Non-nil in .copy mode: the staged copy next to EFMI's d3d11.dll.
    let stagedFile: URL?
    let sourceSHA256: String

    var shortHash: String { String(sourceSHA256.prefix(12)) }
    var stateFile: URL { importerDir.appendingPathComponent(ModChain.stateFileName) }
}

/// What a previously applied chain recorded (read back for the UI's status line and for revert).
struct ChainState {
    let appPath: String
    let backend: String
    let mode: String
    let target: String
    let appliedAt: String
    /// Only present when the apply replaced a chain the user had set themselves; revert puts it back.
    let replacedLine: String?
}

enum ModChain {
    static let stagedDLLName = "d3d11_cx.dll"
    static let markerPrefix = "; FineWine chain:"
    static let stateFileName = "d3dx.ini.finewine-chain"
    /// Same convention as the Wine-module swap backups.
    static let backupExtension = "cxorig"

    // MARK: discovery

    static func defaultPatchedApp() -> URL? {
        let candidate = URL(fileURLWithPath: "/Applications/CrossOver_Endfield_Patch.app")
        return isPatchedCrossOver(candidate) ? candidate : nil
    }

    static func isPatchedCrossOver(_ app: URL) -> Bool {
        FileManager.default.fileExists(atPath: crossOverRoot(app).path)
    }

    static func crossOverRoot(_ app: URL) -> URL {
        app.appendingPathComponent("Contents/SharedSupport/CrossOver", isDirectory: true)
    }

    /// Find the EFMI folder: XXMI Launcher's config first, then its default install location,
    /// then the user's explicit override. The folder is only valid if it contains d3dx.ini.
    static func locateImporter(bottle: URL, override: URL?) -> URL? {
        var candidates: [URL] = []
        if let override { candidates.append(override) }
        let users = bottle.appendingPathComponent("drive_c/users")
        if let entries = try? FileManager.default.contentsOfDirectory(at: users, includingPropertiesForKeys: nil) {
            for user in entries {
                let root = user.appendingPathComponent("AppData/Roaming/XXMI Launcher")
                let cfg = root.appendingPathComponent("XXMI Launcher Config.json")
                if let data = try? Data(contentsOf: cfg),
                   let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                   let importers = obj["Importers"] as? [String: Any],
                   let efmi = importers["EFMI"] as? [String: Any],
                   let importer = efmi["Importer"] as? [String: Any],
                   let win = importer["importer_path"] as? String,
                   !win.isEmpty,
                   let mac = macPath(forWindowsPath: win, bottle: bottle) {
                    candidates.append(mac)
                }
                candidates.append(root.appendingPathComponent("EFMI"))
            }
        }
        return candidates.first {
            FileManager.default.fileExists(atPath: $0.appendingPathComponent("d3dx.ini").path)
        }
    }

    /// Resolve a bottle `dosdevices` link (e.g. `z:` → `/`) to its mac-side target.
    static func dosDeviceTarget(bottle: URL, drive: String) -> String? {
        let link = bottle.appendingPathComponent("dosdevices/\(drive)").path
        return (try? FileManager.default.destinationOfSymbolicLink(atPath: link))
    }

    /// "C:\Users\me\AppData\...\EFMI" → the mac path inside the bottle, via dosdevices + realpath.
    static func macPath(forWindowsPath win: String, bottle: URL) -> URL? {
        var p = win.trimmingCharacters(in: .whitespacesAndNewlines)
        guard p.count >= 2, p.dropFirst(1).first == ":" else { return nil }
        let drive = String(p[p.startIndex]).lowercased()
        let rest = p.dropFirst(2).replacingOccurrences(of: "\\", with: "/")
        guard let target = dosDeviceTarget(bottle: bottle, drive: drive) else { return nil }
        var out = URL(fileURLWithPath: target, isDirectory: true)
        for component in rest.split(separator: "/") {
            if component == ".." {
                out = out.deletingLastPathComponent()
            } else if component != "." {
                out.appendPathComponent(String(component))
            }
        }
        return out
    }

    /// mac path → in-bottle windows path (drive Z:).
    static func windowsPath(for url: URL) -> String {
        "Z:" + url.path.replacingOccurrences(of: "/", with: "\\")
    }

    // MARK: planning

    static func plan(patchedApp: URL, bottle: URL, backend: ChainBackend,
                     importerDir: URL, forcedMode: ChainPlan.Mode? = nil) throws -> ChainPlan {
        let source = crossOverRoot(patchedApp).appendingPathComponent(backend.crossoverSubpath)
        guard FileManager.default.fileExists(atPath: source.path) else {
            throw PatchError("The backend d3d11.dll is missing from the patched app: \(backend.crossoverSubpath)")
        }
        let d3dx = importerDir.appendingPathComponent("d3dx.ini")
        guard FileManager.default.fileExists(atPath: d3dx.path) else {
            throw PatchError("No d3dx.ini in \(importerDir.path) — is EFMI installed there?")
        }
        var mode = forcedMode ?? .path
        if mode == .path && dosDeviceTarget(bottle: bottle, drive: "z") != "/" {
            // The app bundle is not reachable through the bottle's Z: drive — stage a copy instead.
            mode = .copy
        }
        let staged = importerDir.appendingPathComponent(stagedDLLName)
        return ChainPlan(
            patchedApp: patchedApp, bottle: bottle, backend: backend,
            importerDir: importerDir, d3dxIni: d3dx, mode: mode,
            sourceFile: source,
            target: mode == .path ? windowsPath(for: source) : stagedDLLName,
            stagedFile: mode == .copy ? staged : nil,
            sourceSHA256: (try? sha256Hex(source)) ?? "")
    }

    // MARK: the four steps (mirror the shell script's step list)

    static func backup(_ plan: ChainPlan) throws {
        let backup = plan.d3dxIni.appendingPathExtension(backupExtension)
        let fm = FileManager.default
        if !fm.fileExists(atPath: backup.path) {
            try fm.copyItem(at: plan.d3dxIni, to: backup)
        }
    }

    static func stage(_ plan: ChainPlan) throws {
        guard let staged = plan.stagedFile else { return }   // .path mode stages nothing
        let fm = FileManager.default
        // Re-copy when the source changed (CrossOver updated, backend switched).
        let current = try? sha256Hex(staged)
        if current != plan.sourceSHA256 {
            try? fm.removeItem(at: staged)
            try fm.copyItem(at: plan.sourceFile, to: staged)
        }
    }

    /// Returns the text of any pre-existing *active* `proxy_d3d11` line this apply replaced
    /// (nil when there wasn't one) — the caller records it in the state file for an exact revert.
    @discardableResult
    static func writeChain(_ plan: ChainPlan) throws -> String? {
        try applyChainToIni(plan.d3dxIni, target: plan.target, backend: plan.backend.rawValue,
                            shortHash: plan.shortHash)
    }

    static func verify(_ plan: ChainPlan) throws {
        let text = try String(contentsOf: plan.d3dxIni, encoding: .utf8)
        guard sectionContains(key: "proxy_d3d11", value: plan.target, in: text) else {
            throw PatchError("d3dx.ini does not contain the chain after editing.")
        }
        guard text.contains(markerPrefix) else {
            throw PatchError("d3dx.ini is missing the FineWine marker after editing.")
        }
        if let staged = plan.stagedFile {
            let sha = try sha256Hex(staged)
            guard sha == plan.sourceSHA256 else {
                throw PatchError("The staged \(stagedDLLName) does not match the backend DLL in the patched app.")
            }
        }
    }

    static func writeState(_ plan: ChainPlan, replaced: String?) throws {
        let formatter = ISO8601DateFormatter()
        var state = """
        app_path = \(plan.patchedApp.path)
        backend = \(plan.backend.rawValue)
        mode = \(plan.mode.rawValue)
        target = \(plan.target)
        target_sha256 = \(plan.sourceSHA256)
        applied_at = \(formatter.string(from: Date()))
        """
        // If the apply replaced a chain the user had set themselves, remember it for revert.
        if let replaced, !replaced.isEmpty {
            state += "\nreplaced_line = \(replaced)"
        }
        try state.write(to: plan.stateFile, atomically: true, encoding: .utf8)
    }

    static func readState(importerDir: URL) -> ChainState? {
        let url = importerDir.appendingPathComponent(stateFileName)
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        var values: [String: String] = [:]
        for line in text.split(separator: "\n") {
            let parts = line.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2 else { continue }
            values[parts[0].trimmingCharacters(in: .whitespaces)] = parts[1].trimmingCharacters(in: .whitespaces)
        }
        guard values["backend"] != nil else { return nil }
        return ChainState(appPath: values["app_path"] ?? "",
                          backend: values["backend"] ?? "",
                          mode: values["mode"] ?? "",
                          target: values["target"] ?? "",
                          appliedAt: values["applied_at"] ?? "",
                          replacedLine: values["replaced_line"])
    }

    // MARK: revert

    /// Surgical revert: remove the marker + the proxy line we added, restoring any line we
    /// replaced. Falls back to the pre-chain backup when XXMI has since rewritten d3dx.ini
    /// (marker gone) — the backup is always the byte-exact escape hatch.
    static func revert(importerDir: URL) throws {
        let fm = FileManager.default
        let d3dx = importerDir.appendingPathComponent("d3dx.ini")
        let backup = d3dx.appendingPathExtension(backupExtension)
        let staged = importerDir.appendingPathComponent(stagedDLLName)

        if var text = try? String(contentsOf: d3dx, encoding: .utf8),
           text.contains(markerPrefix) {
            text = removeChainLines(from: text, reinsert: readState(importerDir: importerDir)?.replacedLine)
            try text.write(to: d3dx, atomically: true, encoding: .utf8)
        } else if fm.fileExists(atPath: backup.path) {
            try? fm.removeItem(at: d3dx)
            try fm.copyItem(at: backup, to: d3dx)
        } else {
            throw PatchError("Nothing to revert: no chain marker in d3dx.ini and no pre-chain backup.")
        }
        try? fm.removeItem(at: staged)
        try? fm.removeItem(at: importerDir.appendingPathComponent(stateFileName))
    }

    // MARK: ini editing (same rules as the shell implementation)

    /// The line-ending trick that keeps CRLF files intact: split on "\n" (each element keeps its
    /// trailing "\r" if the file is CRLF), edit, rejoin with "\n".
    private static func splitLines(_ text: String) -> [String] {
        text.components(separatedBy: "\n")
    }

    private static func core(_ line: String) -> String {
        line.hasSuffix("\r") ? String(line.dropLast()) : line
    }

    private static func eol(_ line: String) -> String {
        line.hasSuffix("\r") ? "\r" : ""
    }

    /// `;proxy_d3d11=d3d11_helix.dll` / `proxy_d3d11 = X` → the key name without comment marks.
    private static func proxyKind(_ coreLine: String) -> String? {
        var t = coreLine.trimmingCharacters(in: .whitespaces)
        let commented = t.hasPrefix(";")
        while t.hasPrefix(";") {
            t = String(t.dropFirst()).trimmingCharacters(in: .whitespaces)
        }
        guard t.lowercased().hasPrefix("proxy_d3d11") else { return nil }
        let rest = t.dropFirst("proxy_d3d11".count)
        guard let first = rest.first, first == "=" || first == " " || first == "\t" else { return nil }
        return commented ? "commented" : "active"
    }

    private static func value(of coreLine: String) -> String {
        guard let eq = coreLine.firstIndex(of: "=") else { return "" }
        return String(coreLine[coreLine.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
    }

    private static func isSectionLine(_ coreLine: String) -> Bool {
        let t = coreLine.trimmingCharacters(in: .whitespaces)
        return t.hasPrefix("[") && t.hasSuffix("]")
    }

    /// Apply the chain. Invariant (same as the shell): after this there is EXACTLY ONE active
    /// `proxy_d3d11` in [System] — ours — which makes re-runs true no-ops:
    /// - commented example lines are kept, ours goes right after the first one;
    /// - any active proxy_d3d11 line is dropped; a *different* one is returned so the caller can
    ///   record it for an exact revert;
    /// - with neither, ours is inserted right after the [System] header.
    @discardableResult
    static func applyChainToIni(_ ini: URL, target: String, backend: String, shortHash: String) throws -> String? {
        guard var text = try? String(contentsOf: ini, encoding: .utf8) else {
            throw PatchError("Could not read \(ini.path)")
        }
        let marker = "\(markerPrefix) backend=\(backend) target_sha256=\(shortHash)"
        var lines = splitLines(text).filter { !core($0).trimmingCharacters(in: .whitespaces).hasPrefix(markerPrefix) }

        var out: [String] = []
        var inSystem = false
        var replaced: String?
        var replacedAt: Int?
        var firstExample: Int?

        for line in lines {
            let c = core(line)
            let t = c.trimmingCharacters(in: .whitespaces)
            if t.lowercased().hasPrefix("[system]") {
                inSystem = true
            } else if isSectionLine(c) {
                inSystem = false
            }
            if inSystem, let kind = proxyKind(c) {
                if kind == "commented" && firstExample == nil {
                    firstExample = out.count                 // insert right after the documented example
                }
                if kind == "active" {
                    if replacedAt == nil && value(of: c).lowercased() != target.lowercased() {
                        replaced = t                          // a genuinely different (user-set) chain
                        replacedAt = out.count
                    }
                    continue                                  // drop it — exactly one active key
                }
            }
            out.append(line)
        }

        let at: Int
        if let idx = firstExample {
            at = idx + 1
        } else if let idx = replacedAt {
            at = idx                                          // put ours back where the old line was
        } else {
            guard let hdr = out.firstIndex(where: { core($0).trimmingCharacters(in: .whitespaces).lowercased().hasPrefix("[system]") }) else {
                throw PatchError("d3dx.ini has no [System] section — cannot add the chain.")
            }
            at = hdr + 1
        }
        let e = at > 0 ? eol(out[at - 1]) : ""
        out.insert(contentsOf: ["proxy_d3d11 = \(target)\(e)", "\(marker)\(e)"], at: at)

        try out.joined(separator: "\n").write(to: ini, atomically: true, encoding: .utf8)
        return replaced
    }

    private static func removeChainLines(from text: String, reinsert: String?) -> String {
        var lines = splitLines(text)
        var out: [String] = []
        var insertAt: Int?
        var insertEol = ""
        var i = 0
        while i < lines.count {
            let c = core(lines[i])
            if c.trimmingCharacters(in: .whitespaces).hasPrefix(markerPrefix) {
                i += 1
                continue
            }
            if proxyKind(c) == "active", i + 1 < lines.count,
               core(lines[i + 1]).trimmingCharacters(in: .whitespaces).hasPrefix(markerPrefix) {
                if insertAt == nil {
                    insertAt = out.count
                    insertEol = eol(c)
                }
                i += 2
                continue
            }
            out.append(lines[i])
            i += 1
        }
        if let reinsert, !reinsert.isEmpty, let at = insertAt {
            out.insert("\(reinsert)\(insertEol)", at: at)
        }
        return out.joined(separator: "\n")
    }

    /// True when [System] contains an active `proxy_d3d11 = value` line.
    private static func sectionContains(key: String, value wanted: String, in text: String) -> Bool {
        var inSystem = false
        for line in splitLines(text) {
            let c = core(line)
            let t = c.trimmingCharacters(in: .whitespaces)
            if t.lowercased().hasPrefix("[system]") {
                inSystem = true
            } else if isSectionLine(c) {
                inSystem = false
            }
            guard inSystem, proxyKind(c) == "active" else { continue }
            let name = String(t.split(separator: "=", maxSplits: 1).first ?? "")
                .trimmingCharacters(in: .whitespaces)
            if name.lowercased() == key && value(of: t).lowercased() == wanted.lowercased() {
                return true
            }
        }
        return false
    }

    // MARK: misc

    static func sha256Hex(_ url: URL) throws -> String {
        let data = try Data(contentsOf: url, options: .alwaysMapped)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
