import Foundation
import FineWineCore

/// The CrossOver-only tools exposed by FineWine. They intentionally work on a bottle in place:
/// a FineWine prefix is not a CrossOver bottle, and treating the two as interchangeable would
/// silently edit the wrong configuration.
struct CrossOverToolBottle: Identifiable, Hashable {
    let url: URL
    let backend: CrossOverBackend?

    var id: String { url.standardizedFileURL.path }
    var name: String { url.lastPathComponent }

    static func detected() -> [CrossOverToolBottle] {
        CrossOverBottle.list().filter(\.isCrossOver).map { bottle in
            CrossOverToolBottle(url: bottle.directory, backend: CrossOverBackend.from(bottle.directory))
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    static func fromSelection(_ selection: URL) -> [CrossOverToolBottle] {
        let fm = FileManager.default
        if let bottle = CrossOverBottle.read(selection), bottle.isCrossOver {
            return [CrossOverToolBottle(url: bottle.directory, backend: CrossOverBackend.from(bottle.directory))]
        }
        guard let children = try? fm.contentsOfDirectory(at: selection, includingPropertiesForKeys: [.isDirectoryKey]) else { return [] }
        return children.compactMap { child in
            guard let bottle = CrossOverBottle.read(child), bottle.isCrossOver else { return nil }
            return CrossOverToolBottle(url: bottle.directory, backend: CrossOverBackend.from(bottle.directory))
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}

enum CrossOverBackend: String, CaseIterable, Identifiable {
    case d3dmetal, dxmt, dxvk, wined3d, auto

    var id: String { rawValue }
    var title: String {
        switch self {
        case .d3dmetal: return "D3DMetal"
        case .dxmt: return "DXMT"
        case .dxvk: return "DXVK"
        case .wined3d: return "WineD3D"
        case .auto: return "Automatic"
        }
    }
    var bottleValue: String? { self == .auto ? nil : rawValue }
    var upscalerKey: String? {
        switch self {
        case .d3dmetal: return "D3DM_ENABLE_METALFX"
        case .dxmt: return "DXMT_ENABLE_NVEXT"
        default: return nil
        }
    }
    var backendDLLPath: String? {
        switch self {
        case .d3dmetal: return "lib64/apple_gptk/wine/x86_64-windows/d3d11.dll"
        case .dxmt: return "lib/dxmt/x86_64-windows/d3d11.dll"
        case .dxvk: return "lib/dxvk/x86_64-windows/d3d11.dll"
        case .wined3d, .auto: return nil
        }
    }

    static func from(_ bottle: URL) -> CrossOverBackend? {
        let conf = bottle.appendingPathComponent("cxbottle.conf")
        guard let text = try? String(contentsOf: conf, encoding: .utf8) else { return nil }
        for key in ["CX_ACTIVE_GRAPHICS_BACKEND", "CX_GRAPHICS_BACKEND"] {
            if let value = CrossOverBottleConf.value(in: text, key: key), let backend = CrossOverBackend(rawValue: value) {
                return backend == .wined3d || backend == .auto ? nil : backend
            }
        }
        return nil
    }
}

struct CrossOverBottleSettings {
    var backend: CrossOverBackend = .auto
    var msync = true
    var upscaling = false
    var metalHUD = false
    var fpsCap: String? = nil

    static func read(_ bottle: URL) throws -> Self {
        let text = try String(contentsOf: bottle.appendingPathComponent("cxbottle.conf"), encoding: .utf8)
        let selected = CrossOverBackend.from(bottle) ?? .auto
        return Self(backend: selected,
                    msync: CrossOverBottleConf.value(in: text, key: "WINEMSYNC") != "0",
                    upscaling: selected.upscalerKey.flatMap { CrossOverBottleConf.value(in: text, key: $0) } == "1",
                    metalHUD: CrossOverBottleConf.value(in: text, key: "MTL_HUD_ENABLED") == "1",
                    fpsCap: CrossOverBottleConf.value(in: text, key: "D3DM_MAX_FPS"))
    }

    func write(to bottle: URL) throws {
        let conf = bottle.appendingPathComponent("cxbottle.conf")
        var text = try String(contentsOf: conf, encoding: .utf8)
        try CrossOverTools.backup(conf, named: "cxbottle.conf.finewine-tools.bak")
        text = CrossOverBottleConf.setting(text, key: "CX_GRAPHICS_BACKEND", value: backend.bottleValue)
        text = CrossOverBottleConf.setting(text, key: "WINEMSYNC", value: msync ? "1" : "0")
        for choice in CrossOverBackend.allCases {
            guard let key = choice.upscalerKey else { continue }
            text = CrossOverBottleConf.setting(text, key: key, value: choice == backend && upscaling ? "1" : nil)
        }
        text = CrossOverBottleConf.setting(text, key: "MTL_HUD_ENABLED", value: metalHUD ? "1" : nil)
        text = CrossOverBottleConf.setting(text, key: "D3DM_MAX_FPS", value: fpsCap)
        try text.write(to: conf, atomically: true, encoding: .utf8)
    }
}

enum CrossOverTools {
    static let efmiMarker = "; FineWine EFMI chain — remove with FineWine"

    static func backup(_ file: URL, named name: String) throws {
        let backup = file.deletingLastPathComponent().appendingPathComponent(name)
        if !FileManager.default.fileExists(atPath: backup.path) {
            try FileManager.default.copyItem(at: file, to: backup)
        }
    }

    /// Finds the usual portable and per-user EFMI locations without recursively walking a bottle.
    static func locateEFMI(in bottle: URL) -> URL? {
        let fm = FileManager.default
        let driveC = bottle.appendingPathComponent("drive_c", isDirectory: true)
        var candidates = [
            driveC.appendingPathComponent("XXMI/EFMI"),
            driveC.appendingPathComponent("EFMI")
        ]
        if let users = try? fm.contentsOfDirectory(at: driveC.appendingPathComponent("users"), includingPropertiesForKeys: nil) {
            for user in users {
                candidates += [
                    user.appendingPathComponent("AppData/Roaming/XXMI Launcher/EFMI"),
                    user.appendingPathComponent("Desktop/XXMI-Launcher-Portable/EFMI"),
                    user.appendingPathComponent("Downloads/XXMI-Launcher-Portable/EFMI")
                ]
            }
        }
        return candidates.first { fm.fileExists(atPath: $0.appendingPathComponent("d3dx.ini").path) }
    }

    static func applyEFMI(bottle: URL, importer: URL, patchedApp: URL) throws {
        guard let backend = CrossOverBackend.from(bottle), let backendPath = backend.backendDLLPath else {
            throw CrossOverToolError("Choose a bottle using D3DMetal, DXMT, or DXVK before applying the EFMI chain.")
        }
        let source = patchedApp.appendingPathComponent("Contents/SharedSupport/CrossOver/\(backendPath)")
        guard FileManager.default.fileExists(atPath: source.path) else {
            throw CrossOverToolError("The selected app does not contain the \(backend.title) D3D11 backend.")
        }
        let ini = importer.appendingPathComponent("d3dx.ini")
        var text = try String(contentsOf: ini, encoding: .utf8)
        try backup(ini, named: "d3dx.ini.finewine-chain.bak")
        let target: String
        let zDevice = bottle.appendingPathComponent("dosdevices/z:")
        if (try? FileManager.default.destinationOfSymbolicLink(atPath: zDevice.path)) == "/" {
            target = "Z:" + source.path.replacingOccurrences(of: "/", with: "\\")
        } else {
            let staged = importer.appendingPathComponent("d3d11_finewine_backend.dll")
            try? FileManager.default.removeItem(at: staged)
            try FileManager.default.copyItem(at: source, to: staged)
            target = staged.lastPathComponent
        }
        text = removeEFMIChain(from: text)
        if let range = text.range(of: "[System]", options: [.caseInsensitive]) {
            let insertion = text[range.upperBound...].firstIndex(of: "\n") ?? range.upperBound
            text.insert(contentsOf: "\n\(efmiMarker)\nproxy_d3d11 = \(target)\n", at: insertion)
        } else {
            text += (text.hasSuffix("\n") ? "" : "\n") + "\n[System]\n\(efmiMarker)\nproxy_d3d11 = \(target)\n"
        }
        try text.write(to: ini, atomically: true, encoding: .utf8)
    }

    static func revertEFMI(importer: URL) throws {
        let ini = importer.appendingPathComponent("d3dx.ini")
        let text = try String(contentsOf: ini, encoding: .utf8)
        try removeEFMIChain(from: text).write(to: ini, atomically: true, encoding: .utf8)
        try? FileManager.default.removeItem(at: importer.appendingPathComponent("d3d11_finewine_backend.dll"))
    }

    static func efmiApplied(importer: URL) -> Bool {
        ((try? String(contentsOf: importer.appendingPathComponent("d3dx.ini"), encoding: .utf8)) ?? "").contains(efmiMarker)
    }

    private static func removeEFMIChain(from text: String) -> String {
        var lines = text.components(separatedBy: "\n")
        var index = 0
        while index < lines.count {
            if lines[index].trimmingCharacters(in: .whitespaces) == efmiMarker {
                lines.remove(at: index)
                if index < lines.count, lines[index].trimmingCharacters(in: .whitespaces).lowercased().hasPrefix("proxy_d3d11") {
                    lines.remove(at: index)
                }
            } else { index += 1 }
        }
        return lines.joined(separator: "\n")
    }

    static func patchedAppIsUsable(_ app: URL) -> Bool {
        FileManager.default.isExecutableFile(atPath: app.appendingPathComponent("Contents/SharedSupport/CrossOver/bin/wine").path)
    }

    static func notProtonStatus() -> NotProtonStatus {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let steam = home.appendingPathComponent("Library/Application Support/Steam")
        let root = home.appendingPathComponent("Library/Application Support/notproton")
        let runner = root.appendingPathComponent("runners/crossover-finewine-26.3/CrossOver/bin/wine")
        let tool = steam.appendingPathComponent("compatibilitytools.d/notproton-finewine-rosetta")
        return NotProtonStatus(steamInstalled: FileManager.default.fileExists(atPath: steam.path),
                               notProtonInstalled: FileManager.default.fileExists(atPath: root.path),
                               isRegistered: FileManager.default.isExecutableFile(atPath: runner.path) && FileManager.default.fileExists(atPath: tool.appendingPathComponent("compatibilitytool.vdf").path))
    }

    static func registerNotProton(patchedApp: URL) throws {
        guard patchedAppIsUsable(patchedApp) else { throw CrossOverToolError("Choose a valid patched CrossOver app.") }
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser
        let steam = home.appendingPathComponent("Library/Application Support/Steam")
        guard fm.fileExists(atPath: steam.path) else { throw CrossOverToolError("Steam is not installed for this user.") }
        let notProton = home.appendingPathComponent("Library/Application Support/notproton")
        let runner = notProton.appendingPathComponent("runners/crossover-finewine-26.3")
        let runnerTarget = runner.appendingPathComponent("CrossOver")
        let source = patchedApp.appendingPathComponent("Contents/SharedSupport/CrossOver")
        if fm.fileExists(atPath: runner.path) { try fm.removeItem(at: runner) }
        try fm.createDirectory(at: runner, withIntermediateDirectories: true)
        let ditto = Process()
        ditto.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        ditto.arguments = ["--noextattr", "--noqtn", source.path, runnerTarget.path]
        try ditto.run(); ditto.waitUntilExit()
        guard ditto.terminationStatus == 0 else { throw CrossOverToolError("Could not copy the CrossOver runner (status \(ditto.terminationStatus)).") }
        let tool = steam.appendingPathComponent("compatibilitytools.d/notproton-finewine-rosetta")
        if fm.fileExists(atPath: tool.path) { try fm.removeItem(at: tool) }
        try fm.createDirectory(at: tool, withIntermediateDirectories: true)
        let display = "CrossOver 26.3 - Endfield FineWine - Rosetta"
        let vdf = "\"compatibilitytools\"\n{\n  \"compat_tools\"\n  {\n    \"notproton-finewine-rosetta\"\n    {\n      \"install_path\" \".\"\n      \"display_name\" \"\(display)\"\n      \"from_oslist\" \"windows\"\n      \"to_oslist\" \"macos\"\n    }\n  }\n}\n"
        try vdf.write(to: tool.appendingPathComponent("compatibilitytool.vdf"), atomically: true, encoding: .utf8)
        try "finewine-26.3\n".write(to: tool.appendingPathComponent("build"), atomically: true, encoding: .utf8)
        try "rosetta\n".write(to: tool.appendingPathComponent("flavor"), atomically: true, encoding: .utf8)
        // This follows NotProton's compatibility-tool calling convention instead of invoking
        // CrossOver's wrapper with Steam's verb as if it were an executable.
        let run = "#!/bin/sh\nset -e\nverb=\"$1\"\nshift || true\nif [ \"$verb\" = getcompatpath ]; then\n  printf '%s\\n' \"$STEAM_COMPAT_DATA_PATH\"\n  exit 0\nfi\nroot=\"$HOME/Library/Application Support/notproton/runners/crossover-finewine-26.3/CrossOver\"\nexport CX_ROOT=\"$root\"\nwine_unix=\"$root/lib/wine/x86_64-unix\"\nexport WINELOADER=\"$wine_unix/wine\"\nexport WINESERVER=\"$root/bin/wineserver\"\n[ -x \"$WINESERVER\" ] || export WINESERVER=\"$root/bin/wineserver-x86\"\nexport WINEDLLPATH=\"$root/lib/wine/x86_64-windows:$wine_unix\"\nexport PATH=\"$root/bin:$PATH\"\nexport ROSETTA_ADVERTISE_AVX=1\nif [ -n \"$STEAM_COMPAT_DATA_PATH\" ]; then\n  export WINEPREFIX=\"$STEAM_COMPAT_DATA_PATH/pfx\"\n  mkdir -p \"$WINEPREFIX\"\nfi\ncase \"$verb\" in\n  run|waitforexitandrun) \"$WINESERVER\" -k >/dev/null 2>&1 || true; \"$WINELOADER\" \"$@\" ;;\n  *) \"$WINELOADER\" \"$@\" ;;\nesac\n"
        let runURL = tool.appendingPathComponent("run")
        try run.write(to: runURL, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: runURL.path)
    }

    static func unregisterNotProton() throws {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let fm = FileManager.default
        for url in [
            home.appendingPathComponent("Library/Application Support/notproton/runners/crossover-finewine-26.3"),
            home.appendingPathComponent("Library/Application Support/Steam/compatibilitytools.d/notproton-finewine-rosetta")
        ] where fm.fileExists(atPath: url.path) {
            try fm.removeItem(at: url)
        }
    }
}

struct NotProtonStatus {
    let steamInstalled: Bool
    let notProtonInstalled: Bool
    let isRegistered: Bool
}

struct CrossOverToolError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

/// A small, CRLF-safe editor for `[EnvironmentVariables]` in CrossOver's config format.
enum CrossOverBottleConf {
    static func value(in text: String, key: String) -> String? {
        var environment = false
        for raw in text.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if line == "[EnvironmentVariables]" { environment = true; continue }
            if line.hasPrefix("[") && line.hasSuffix("]") { environment = false }
            guard environment, !line.hasPrefix(";"), !line.hasPrefix("#"), line.hasPrefix("\"\(key)\"") else { continue }
            return line.split(separator: "=", maxSplits: 1).last?.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
        }
        return nil
    }

    static func setting(_ text: String, key: String, value: String?) -> String {
        var lines = text.components(separatedBy: "\n")
        var environment = false, found = false, written = false
        let assignment: (String) -> String = { value in "\"\(key)\" = \"\(value)\"" }
        for index in lines.indices {
            let trimmed = lines[index].trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed == "[EnvironmentVariables]" { environment = true; found = true; continue }
            if trimmed.hasPrefix("[") && trimmed.hasSuffix("]") { environment = false; continue }
            guard environment, !trimmed.hasPrefix(";"), !trimmed.hasPrefix("#"), trimmed.hasPrefix("\"\(key)\"") else { continue }
            if let value, !written { lines[index] = assignment(value); written = true } else { lines[index] = "" }
        }
        if let value, !written {
            if found, let section = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespacesAndNewlines) == "[EnvironmentVariables]" }) {
                lines.insert(assignment(value), at: section + 1)
            } else {
                if lines.last?.isEmpty == false { lines.append("") }
                lines += ["[EnvironmentVariables]", assignment(value)]
            }
        }
        return lines.joined(separator: "\n")
    }
}
