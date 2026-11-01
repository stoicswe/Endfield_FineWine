import Foundation

// MARK: - Bottle Settings Read/Write
//
// Reads and writes per-bottle `[EnvironmentVariables]` in `cxbottle.conf`, using the
// `BottleConf` editor already defined in MetalHUD.swift. This is the inverse of what
// `SetupEngine` writes at bottle creation time — the user can tweak their bottle after
// the fact without touching a terminal.

extension BottleSettings {

    /// The environment keys the settings page manages.
    private static let managedKeys = [
        "CX_GRAPHICS_BACKEND",
        "WINEMSYNC",
        "D3DM_ENABLE_METALFX",
        "DXMT_ENABLE_NVEXT",
        "MTL_HUD_ENABLED",
        "D3DM_MAX_FPS",
    ]

    // MARK: - Read

    /// Reads the current bottle settings from `cxbottle.conf`.
    static func read(from bottleDir: URL) -> BottleSettings? {
        let conf = bottleDir.appendingPathComponent("cxbottle.conf")
        guard let text = try? String(contentsOf: conf, encoding: .utf8) else { return nil }
        return read(from: text)
    }

    /// Reads settings from the text of a `cxbottle.conf`.
    static func read(from confText: String) -> BottleSettings {
        var settings = BottleSettings()
        settings.name = ""   // caller should set this from the bottle directory name

        // Graphics backend
        if let raw = BottleConf.environmentValue(in: confText, key: "CX_GRAPHICS_BACKEND"),
           let backend = BottleBackend(rawValue: raw) {
            settings.backend = backend
        } else {
            settings.backend = .auto
        }

        // MSync
        let msyncRaw = BottleConf.environmentValue(in: confText, key: "WINEMSYNC")
        settings.msync = msyncRaw != "0"   // default to true unless explicitly disabled

        // Upscaling — check the backend-specific key
        if let key = settings.backend.upscalerKey {
            let val = BottleConf.environmentValue(in: confText, key: key)
            settings.upscaling = val == "1"
        } else {
            settings.upscaling = false
        }

        // Metal HUD
        settings.metalHUD = BottleConf.environmentValue(in: confText, key: "MTL_HUD_ENABLED") == "1"

        return settings
    }

    // MARK: - Write

    /// The FPS cap value, read separately since it's not part of the base `BottleSettings`.
    static func readFPSCap(from bottleDir: URL) -> String? {
        let conf = bottleDir.appendingPathComponent("cxbottle.conf")
        guard let text = try? String(contentsOf: conf, encoding: .utf8) else { return nil }
        return BottleConf.environmentValue(in: text, key: "D3DM_MAX_FPS")
    }

    /// Writes the current settings into the bottle's `cxbottle.conf`.
    ///
    /// Only the managed keys are touched — custom variables the user added by hand are
    /// preserved. The `BottleConf.setEnvironmentValue` editor already handles section
    /// creation, CRLF, and comment lines.
    func write(to bottleDir: URL, fpsCap: String? = nil) throws {
        let conf = bottleDir.appendingPathComponent("cxbottle.conf")
        guard FileManager.default.fileExists(atPath: conf.path) else {
            throw PatchError("Bottle config not found at \(conf.path)")
        }
        var text = try String(contentsOf: conf, encoding: .utf8)

        // Back up before first write (one backup, same pattern as MetalHUD)
        let backup = conf.appendingPathExtension("finewine-settings.bak")
        if !FileManager.default.fileExists(atPath: backup.path) {
            try FileManager.default.copyItem(at: conf, to: backup)
        }

        // Guard against unsupported Metal 4 properties on older macOS
        if ProcessInfo.processInfo.operatingSystemVersion.majorVersion < BottleSettings.metal4OSMajor {
            for key in BottleSettings.metal4PropertyKeys {
                text = BottleConf.setEnvironmentValue(text, key: key, value: nil)
            }
        }

        // 1. Graphics backend
        text = BottleConf.setEnvironmentValue(text, key: "CX_GRAPHICS_BACKEND", value: backend.bottleValue)

        // 2. MSync
        text = BottleConf.setEnvironmentValue(text, key: "WINEMSYNC", value: msync ? "1" : "0")

        // 3. Upscaler — set the right key, clear the wrong one
        for b in BottleBackend.allCases {
            guard let key = b.upscalerKey else { continue }
            if b == backend && upscaling {
                text = BottleConf.setEnvironmentValue(text, key: key, value: "1")
            } else {
                text = BottleConf.setEnvironmentValue(text, key: key, value: nil)
            }
        }

        // 4. Metal HUD
        text = BottleConf.setEnvironmentValue(text, key: "MTL_HUD_ENABLED", value: metalHUD ? "1" : nil)

        // 5. FPS cap
        text = BottleConf.setEnvironmentValue(text, key: "D3DM_MAX_FPS", value: fpsCap)

        try text.write(to: conf, atomically: true, encoding: .utf8)
    }
}

