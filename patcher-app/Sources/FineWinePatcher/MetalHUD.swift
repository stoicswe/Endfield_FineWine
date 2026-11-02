import Foundation

// MARK: - Metal HUD (optional Tools phase)
//
// Apple's Metal Performance HUD (`MTL_HUD_ENABLED=1`) is a Unix-side environment variable.
// CrossOver 26 injects `[EnvironmentVariables]` from `cxbottle.conf` into every Wine process
// in that bottle — so one bottle key covers `Endfield.exe`, the Gryphline `Games.exe` /
// `Launcher.exe` UI, XXMI, and anything else in the bottle that talks to Metal (D3DMetal,
// DXMT, or MoltenVK). Mac launcher stubs that point at those EXEs get the same key in
// `LSEnvironment` so Dock / `open Foo.app` launches inherit it too.

enum MetalHUD {
    static let envKey = "MTL_HUD_ENABLED"
    static let enabledValue = "1"
    static let fpsKey = "D3DM_MAX_FPS"
    static let stateFileName = "cxbottle.conf.finewine-metal-hud"

    /// Windows image names whose Metal clients should inherit the HUD.
    /// `launcher.exe` is only treated as related when it lives under a GRYPHLINK tree.
    static let relatedFileNames: Set<String> = [
        "endfield.exe",
        "games.exe",
        "em-win64-shipping.exe",
        "xxmi launcher.exe",
        "xxmi-launcher.exe",
    ]

    enum RelatedKind: String, Equatable {
        case game
        case launcherUI
        case gryphlink
        case mods
    }

    struct RelatedApp: Equatable, Identifiable {
        let windowsPath: String
        let fileName: String
        let kind: RelatedKind
        var id: String { windowsPath }

        var displayKind: String {
            switch kind {
            case .game: return "game"
            case .launcherUI: return "Gryphline UI"
            case .gryphlink: return "Gryphline bootstrap"
            case .mods: return "mod launcher"
            }
        }
    }

    struct MacLauncher: Equatable, Identifiable {
        let url: URL
        let reason: String
        var id: String { url.path }
        var name: String { url.deletingPathExtension().lastPathComponent }
    }

    struct Plan: Equatable {
        let bottle: URL
        let conf: URL
        let currentlyEnabled: Bool
        let currentValue: String?
        let maxFPS: String?
        let related: [RelatedApp]
        let macLaunchers: [MacLauncher]
    }

    struct State: Equatable {
        let appliedAt: String
        let previous: String?
        let related: [String]
        let macLaunchers: [String]
        let macPrevious: [String: String?]
    }

    // MARK: - Discovery

    static func plan(for bottle: URL,
                     extraLauncherRoots: [URL] = [],
                     includeDefaultLauncherRoots: Bool = true) -> Plan? {
        let conf = bottle.appendingPathComponent("cxbottle.conf")
        guard let text = try? String(contentsOf: conf, encoding: .utf8) else { return nil }
        let value = BottleConf.environmentValue(in: text, key: envKey)
        let fps = BottleConf.environmentValue(in: text, key: fpsKey)
        return Plan(
            bottle: bottle,
            conf: conf,
            currentlyEnabled: value == enabledValue,
            currentValue: value,
            maxFPS: fps,
            related: findRelatedApps(bottle: bottle),
            macLaunchers: findMacLaunchers(bottle: bottle,
                                           extraRoots: extraLauncherRoots,
                                           includeDefaultLauncherRoots: includeDefaultLauncherRoots)
        )
    }

    static func readState(bottle: URL) -> State? {
        parseState(try? String(contentsOf: stateFile(for: bottle), encoding: .utf8))
    }

    static func findRelatedApps(bottle: URL) -> [RelatedApp] {
        let driveC = bottle.appendingPathComponent("drive_c", isDirectory: true)
        let fm = FileManager.default
        guard fm.fileExists(atPath: driveC.path) else { return [] }

        var found: [RelatedApp] = []
        var seen = Set<String>()

        let searchRoots = [
            driveC.appendingPathComponent("Program Files/GRYPHLINK", isDirectory: true),
            driveC.appendingPathComponent("Program Files (x86)/GRYPHLINK", isDirectory: true),
            driveC.appendingPathComponent("users", isDirectory: true),
        ]

        for root in searchRoots {
            guard fm.fileExists(atPath: root.path) else { continue }
            let enumerator = fm.enumerator(
                at: root,
                includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey],
                options: [.skipsHiddenFiles]
            )
            var depthBudget = 8_000
            while let url = enumerator?.nextObject() as? URL {
                depthBudget -= 1
                if depthBudget <= 0 { break }
                let name = url.lastPathComponent
                if (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
                    if shouldSkipDirectory(name) { enumerator?.skipDescendants() }
                    continue
                }
                guard let app = relatedApp(at: url, driveC: driveC) else { continue }
                if seen.insert(app.windowsPath.lowercased()).inserted {
                    found.append(app)
                }
            }
        }

        return found.sorted { $0.windowsPath.localizedCaseInsensitiveCompare($1.windowsPath) == .orderedAscending }
    }

    static func relatedApp(at url: URL, driveC: URL) -> RelatedApp? {
        let fileName = url.lastPathComponent
        let lower = fileName.lowercased()
        let pathLower = url.path.lowercased()
        let underGryphlink = pathLower.contains("/gryphlink/")
        let isLauncher = lower == "launcher.exe" && underGryphlink
        guard relatedFileNames.contains(lower) || isLauncher else { return nil }
        let canonicalURL = url.standardizedFileURL.resolvingSymlinksInPath()
        let canonicalDriveC = driveC.standardizedFileURL.resolvingSymlinksInPath()
        guard canonicalURL.path.hasPrefix(canonicalDriveC.path) else { return nil }
        let relative = String(canonicalURL.path.dropFirst(canonicalDriveC.path.count))
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let windowsPath = "C:\\" + relative.replacingOccurrences(of: "/", with: "\\")
        let kind: RelatedKind
        switch lower {
        case "endfield.exe", "em-win64-shipping.exe": kind = .game
        case "games.exe": kind = .launcherUI
        case "xxmi launcher.exe", "xxmi-launcher.exe": kind = .mods
        default: kind = .gryphlink
        }
        return RelatedApp(windowsPath: windowsPath, fileName: fileName, kind: kind)
    }

    static func findMacLaunchers(bottle: URL,
                                 extraRoots: [URL] = [],
                                 includeDefaultLauncherRoots: Bool = true) -> [MacLauncher] {
        let fm = FileManager.default
        var roots = includeDefaultLauncherRoots ? defaultMacLauncherRoots() : []
        roots.append(contentsOf: extraRoots)
        var seen = Set<String>()
        var result: [MacLauncher] = []
        let bottleName = bottle.lastPathComponent.lowercased()

        for root in roots {
            guard fm.fileExists(atPath: root.path) else { continue }
            let enumerator = fm.enumerator(
                at: root,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            )
            var budget = 2_000
            while let url = enumerator?.nextObject() as? URL {
                budget -= 1
                if budget <= 0 { break }
                guard url.pathExtension.lowercased() == "app" else { continue }
                enumerator?.skipDescendants()
                let canonical = url.standardizedFileURL.path
                guard seen.insert(canonical).inserted else { continue }
                if let reason = macLauncherReason(url, bottleName: bottleName) {
                    result.append(MacLauncher(url: url, reason: reason))
                }
            }
        }
        return result.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    static func defaultMacLauncherRoots() -> [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return [
            home.appendingPathComponent("Applications/CrossOver", isDirectory: true),
            home.appendingPathComponent("Applications", isDirectory: true),
        ]
    }

    static func macLauncherReason(_ app: URL, bottleName: String) -> String? {
        let plist = app.appendingPathComponent("Contents/Info.plist")
        if let blob = (try? String(contentsOf: plist, encoding: .utf8))
                ?? String(data: (try? Data(contentsOf: plist)) ?? Data(), encoding: .isoLatin1) {
            let haystack = blob.lowercased()
            if haystack.contains("endfield.exe") { return "targets Endfield.exe" }
            if haystack.contains("games.exe") { return "targets Games.exe" }
            if haystack.contains("em-win64-shipping.exe") { return "targets EM-Win64-Shipping.exe" }
            if haystack.contains("gryphlink") { return "targets GRYPHLINK" }
            if !bottleName.isEmpty, haystack.contains(bottleName) { return "bottle \(bottleName)" }
        }
        let name = app.deletingPathExtension().lastPathComponent.lowercased()
        let needles = ["endfield", "gryphlink", "gryphline", "arknights", "games.exe", "xxmi"]
        if needles.contains(where: { name.contains($0) }) {
            return "name matches \(app.deletingPathExtension().lastPathComponent)"
        }
        return nil
    }

    // MARK: - Apply / revert

    @discardableResult
    static func apply(plan: Plan) throws -> State {
        let fm = FileManager.default
        guard fm.fileExists(atPath: plan.conf.path) else {
            throw PatchError("Bottle config not found at \(plan.conf.path)")
        }
        let original = try String(contentsOf: plan.conf, encoding: .utf8)
        let previous = BottleConf.environmentValue(in: original, key: envKey)
        let updated = BottleConf.setEnvironmentValue(original, key: envKey, value: enabledValue)
        if updated != original {
            try backupConfIfNeeded(plan.conf)
            try updated.write(to: plan.conf, atomically: true, encoding: .utf8)
        }

        var macPrevious: [String: String?] = [:]
        for launcher in plan.macLaunchers {
            let before = (try? readLSEnvironment(launcher.url))?[envKey]
            macPrevious[launcher.url.path] = before
            try setLSEnvironment(launcher.url, key: envKey, value: enabledValue)
        }

        let state = State(
            appliedAt: ISO8601DateFormatter().string(from: Date()),
            previous: previous,
            related: plan.related.map(\.windowsPath),
            macLaunchers: plan.macLaunchers.map(\.url.path),
            macPrevious: macPrevious
        )
        try writeState(state, bottle: plan.bottle)
        return state
    }

    static func revert(bottle: URL) throws {
        let conf = bottle.appendingPathComponent("cxbottle.conf")
        guard let original = try? String(contentsOf: conf, encoding: .utf8) else {
            throw PatchError("Bottle config not found at \(conf.path)")
        }
        let state = readState(bottle: bottle)
        let updated = BottleConf.setEnvironmentValue(original, key: envKey, value: state?.previous)
        if updated != original {
            try updated.write(to: conf, atomically: true, encoding: .utf8)
        }

        let launchers = state?.macLaunchers ?? findMacLaunchers(bottle: bottle).map(\.url.path)
        for path in launchers {
            let url = URL(fileURLWithPath: path)
            let previous = state?.macPrevious[path] ?? nil
            try? setLSEnvironment(url, key: envKey, value: previous)
        }
        try? FileManager.default.removeItem(at: stateFile(for: bottle))
    }

    static func isEnabled(in confText: String) -> Bool {
        BottleConf.environmentValue(in: confText, key: envKey) == enabledValue
    }

    static func setFPSCap(bottle: URL, fps: String?) throws {
        let conf = bottle.appendingPathComponent("cxbottle.conf")
        guard let original = try? String(contentsOf: conf, encoding: .utf8) else {
            throw PatchError("Bottle config not found at \(conf.path)")
        }
        let updated = BottleConf.setEnvironmentValue(original, key: fpsKey, value: fps)
        if updated != original {
            try backupConfIfNeeded(conf)
            try updated.write(to: conf, atomically: true, encoding: .utf8)
        }
    }

    /// Stops any running wineserver processes for the given bottle prefix.
    static func stopBottle(bottle: URL, app: URL? = nil) throws {
        let candidates = [
            app?.appendingPathComponent("Contents/SharedSupport/CrossOver"),
            URL(fileURLWithPath: "/Applications/CrossOver_Endfield_Patch.app/Contents/SharedSupport/CrossOver"),
            URL(fileURLWithPath: "/Applications/CrossOver.app/Contents/SharedSupport/CrossOver"),
        ].compactMap { $0 }

        // CrossOver 26 ships `wineserver`; CrossOver 27 ships `wineserver-arm64` / `wineserver-x86`.
        // An arm64 bottle runs on the arm64 server, which is why it comes first.
        let names = ["wineserver", "wineserver-arm64", "wineserver-x86"]
        let servers = candidates.lazy.flatMap { cxr in names.lazy.map { cxr.appendingPathComponent("bin/\($0)") } }
        guard let wineserver = servers.first(where: { FileManager.default.fileExists(atPath: $0.path) }) else {
            throw PatchError("Could not locate wineserver in CrossOver bundle")
        }
        let cxr = wineserver.deletingLastPathComponent().deletingLastPathComponent()

        let proc = Process()
        proc.executableURL = wineserver
        proc.arguments = ["-k"]
        var env = ProcessInfo.processInfo.environment
        env["WINEPREFIX"] = bottle.path
        env["CX_ROOT"] = cxr.path
        proc.environment = env
        proc.standardOutput = Pipe()
        proc.standardError = Pipe()
        try proc.run()
        proc.waitUntilExit()
    }

    // MARK: - LSEnvironment

    static func readLSEnvironment(_ app: URL) throws -> [String: String] {
        let plistURL = app.appendingPathComponent("Contents/Info.plist")
        guard let data = try? Data(contentsOf: plistURL),
              let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
              let dict = plist as? [String: Any] else {
            throw PatchError("Could not read Info.plist for \(app.lastPathComponent)")
        }
        if let env = dict["LSEnvironment"] as? [String: String] { return env }
        if let env = dict["LSEnvironment"] as? [String: Any] {
            return env.compactMapValues { $0 as? String }
        }
        return [:]
    }

    static func setLSEnvironment(_ app: URL, key: String, value: String?) throws {
        let fm = FileManager.default
        let plistURL = app.appendingPathComponent("Contents/Info.plist")
        guard fm.fileExists(atPath: plistURL.path) else { return }
        guard let data = try? Data(contentsOf: plistURL),
              var plist = (try? PropertyListSerialization.propertyList(from: data, options: .mutableContainersAndLeaves, format: nil)) as? [String: Any] else {
            throw PatchError("Could not parse Info.plist for \(app.lastPathComponent)")
        }
        var env = plist["LSEnvironment"] as? [String: Any] ?? [:]
        if let value {
            env[key] = value
        } else {
            env.removeValue(forKey: key)
        }
        if env.isEmpty {
            plist.removeValue(forKey: "LSEnvironment")
        } else {
            plist["LSEnvironment"] = env
        }
        let newData = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try newData.write(to: plistURL, options: .atomic)
        try resignAdHocIfNeeded(app)
    }

    /// Only re-sign unsigned / ad-hoc launcher stubs. A Developer ID or Apple-signed helper
    /// is left alone — rewriting its seal would make Gatekeeper kill it.
    static func resignAdHocIfNeeded(_ app: URL) throws {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        proc.arguments = ["-dv", app.path]
        let err = Pipe()
        proc.standardError = err
        proc.standardOutput = Pipe()
        try proc.run()
        proc.waitUntilExit()
        let text = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let signed = proc.terminationStatus == 0 && text.contains("Authority=")
        let adhoc = text.contains("adhoc") || text.contains("Signature=adhoc") || !signed
        guard adhoc else { return }
        let sign = Process()
        sign.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        sign.arguments = ["--force", "--sign", "-", "--timestamp=none", app.path]
        sign.standardOutput = Pipe()
        sign.standardError = Pipe()
        try sign.run()
        sign.waitUntilExit()
    }

    // MARK: - State file

    static func stateFile(for bottle: URL) -> URL {
        bottle.appendingPathComponent(stateFileName)
    }

    static func writeState(_ state: State, bottle: URL) throws {
        var lines = [
            "applied_at = \(state.appliedAt)",
            "previous = \(state.previous ?? "")",
            "related = \(state.related.joined(separator: " | "))",
        ]
        for (i, path) in state.macLaunchers.enumerated() {
            lines.append("mac_launcher_\(i) = \(path)")
            if let prev = state.macPrevious[path] {
                lines.append("mac_launcher_\(i)_previous = \(prev ?? "")")
            }
        }
        try lines.joined(separator: "\n").write(to: stateFile(for: bottle), atomically: true, encoding: .utf8)
    }

    static func parseState(_ text: String?) -> State? {
        guard let text else { return nil }
        var values: [String: String] = [:]
        for line in text.split(separator: "\n") {
            let parts = line.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2 else { continue }
            values[parts[0].trimmingCharacters(in: .whitespaces)] = parts[1].trimmingCharacters(in: .whitespaces)
        }
        guard values["applied_at"] != nil else { return nil }
        let previous = values["previous"].flatMap { $0.isEmpty ? nil : $0 }
        let related = (values["related"] ?? "")
            .split(separator: "|")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        var macLaunchers: [String] = []
        var macPrevious: [String: String?] = [:]
        var i = 0
        while let path = values["mac_launcher_\(i)"] {
            macLaunchers.append(path)
            if let prev = values["mac_launcher_\(i)_previous"] {
                macPrevious[path] = prev.isEmpty ? nil : prev
            }
            i += 1
        }
        return State(appliedAt: values["applied_at"] ?? "",
                     previous: previous,
                     related: related,
                     macLaunchers: macLaunchers,
                     macPrevious: macPrevious)
    }

    // MARK: - Private

    private static func shouldSkipDirectory(_ name: String) -> Bool {
        let skip: Set<String> = [
            "Endfield_Data", "U8Data", "sdkdata", "WebviewConfig",
            "node_modules", ".git", "drive_c",
        ]
        return skip.contains(name)
    }

    private static func backupConfIfNeeded(_ conf: URL) throws {
        let backup = conf.appendingPathExtension("finewine-metal-hud.bak")
        if !FileManager.default.fileExists(atPath: backup.path) {
            try FileManager.default.copyItem(at: conf, to: backup)
        }
    }
}

// MARK: - cxbottle.conf EnvironmentVariables editor

enum BottleConf {
    /// Reads `"KEY" = "value"` from `[EnvironmentVariables]`. Commented `;;"KEY"` lines are ignored.
    static func environmentValue(in text: String, key: String) -> String? {
        var inEnv = false
        let token = "\"\(key)\""
        for raw in text.components(separatedBy: "\n") {
            let line = raw.hasSuffix("\r") ? String(raw.dropLast()) : raw
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed == "[EnvironmentVariables]" {
                inEnv = true
                continue
            }
            if trimmed.hasPrefix("[") && trimmed.hasSuffix("]") {
                inEnv = false
                continue
            }
            guard inEnv else { continue }
            if trimmed.hasPrefix(";;") || trimmed.hasPrefix("#") || trimmed.hasPrefix(";") { continue }
            guard trimmed.hasPrefix(token) else { continue }
            let parts = trimmed.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2 else { continue }
            return parts[1].trimmingCharacters(in: .whitespaces)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
        }
        return nil
    }

    /// Sets or removes a quoted `[EnvironmentVariables]` key. `value == nil` deletes the line.
    /// Preserves comments, unknown keys, and CRLF. Creates the section when needed.
    static func setEnvironmentValue(_ text: String, key: String, value: String?) -> String {
        let lines = text.components(separatedBy: "\n")
        let token = "\"\(key)\""
        var out: [String] = []
        var inEnv = false
        var foundSection = false
        var wrote = false

        func core(_ line: String) -> String { line.hasSuffix("\r") ? String(line.dropLast()) : line }
        func eol(_ line: String) -> String { line.hasSuffix("\r") ? "\r" : "" }
        func assignment(_ sample: String) -> String {
            guard let value else { return "" }
            return "\"\(key)\" = \"\(value)\"\(eol(sample))"
        }
        func isOurKey(_ line: String) -> Bool {
            let trimmed = core(line).trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix(";;") || trimmed.hasPrefix("#") || trimmed.hasPrefix(";") { return false }
            return trimmed.hasPrefix(token)
        }

        for line in lines {
            let trimmed = core(line).trimmingCharacters(in: .whitespaces)
            if trimmed == "[EnvironmentVariables]" {
                inEnv = true
                foundSection = true
                out.append(line)
                continue
            }
            if trimmed.hasPrefix("[") && trimmed.hasSuffix("]") {
                if inEnv, !wrote, value != nil {
                    out.append(assignment(line))
                    wrote = true
                }
                inEnv = false
                out.append(line)
                continue
            }
            if inEnv, isOurKey(line) {
                if let value, !wrote {
                    out.append("\"\(key)\" = \"\(value)\"\(eol(line))")
                    wrote = true
                }
                continue
            }
            out.append(line)
        }

        if inEnv, !wrote, value != nil {
            // Keep a trailing blank line at EOF if the original had one.
            if let last = out.last, core(last).trimmingCharacters(in: .whitespaces).isEmpty {
                out.insert(assignment(last), at: out.count - 1)
            } else {
                out.append(assignment(out.last ?? ""))
            }
            wrote = true
        }

        if !foundSection, let value {
            if let last = out.last, !core(last).trimmingCharacters(in: .whitespaces).isEmpty {
                out.append("")
            }
            out.append("[EnvironmentVariables]")
            out.append("\"\(key)\" = \"\(value)\"")
        }
        return out.joined(separator: "\n")
    }
}
