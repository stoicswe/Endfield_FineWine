import Foundation
import AppKit

// MARK: - App Alias
//
// Creates a macOS .app bundle that opens the Gryphline launcher through the
// FineWine-patched CrossOver. Uses CrossOver's own "Menu Helper" binary so that
// CrossOver handles all the Wine environment setup — same mechanism as CrossOver's
// own generated app shortcuts. One Dock icon, no shell scripts.
//
// The bundle is structured like CrossOver's generated shortcuts:
//   - Executable: Menu Helper binary copied from an existing CrossOver shortcut
//   - Info.plist:  CrossOverHelperCommand pointing to the bottle's .lnk file
//   - CXHelperAppBottleTag: bottle UUID tag from cxbottle.conf

enum AppAlias {

    static let defaultAppName = "Arknights Endfield"
    static let gryphLinkAppName = "GRYPHLINK"
    static let bundleIdentifier = "com.finewine.endfield-alias"
    static let gryphLinkBundleIdentifier = "com.finewine.gryphlink-alias"
    static let patchedBundleID = "com.codeweavers.CrossOvEF"

    struct Config {
        var appName: String = defaultAppName
        var bundleID: String? = nil            // overrides default bundleIdentifier if set
        var bottleName: String = "Endfield12Sep"
        var bottlePath: String? = nil          // absolute path to bottle dir (external SSD)
        var lnkName: String = "Arknights+Endfield.lnk"   // filename inside cxmenu Desktop dir
        var environment: [String: String] = [:]           // LSEnvironment extras (HUD, FPS, etc.)
        var patchedAppBundleID: String = patchedBundleID  // the patched CrossOver this alias opens
    }

    // MARK: - Presets

    /// Config for the Arknights Endfield game shortcut.
    static func endfieldConfig(bottleName: String = "Endfield12Sep", bottlePath: String? = nil,
                               environment: [String: String] = [:]) -> Config {
        Config(appName: defaultAppName, bottleName: bottleName,
               bottlePath: bottlePath, lnkName: "Arknights+Endfield.lnk", environment: environment)
    }

    /// Config for the GRYPHLINK platform launcher shortcut.
    static func gryphLinkConfig(bottleName: String = "Endfield12Sep", bottlePath: String? = nil) -> Config {
        Config(appName: gryphLinkAppName, bundleID: gryphLinkBundleIdentifier,
               bottleName: bottleName, bottlePath: bottlePath, lnkName: "GRYPHLINK.lnk")
    }

    // MARK: - Bottle discovery helpers

    /// Reads the BottleID UUID from cxbottle.conf in the given bottle directory.
    static func bottleTag(in bottleURL: URL) -> String? {
        let conf = bottleURL.appendingPathComponent("cxbottle.conf")
        guard let text = try? String(contentsOf: conf, encoding: .utf8) else { return nil }
        // Line looks like: "BottleID" = "AEB85709-01EC-47AC-8C5C-17BCDADD0434"
        for line in text.components(separatedBy: .newlines) {
            if line.contains("BottleID") {
                let parts = line.components(separatedBy: "\"")
                if parts.count >= 4 { return parts[3] }
            }
        }
        return nil
    }

    /// Finds the .lnk file for the given lnk name in the bottle's cxmenu Desktop directory.
    static func lnkURL(in bottleURL: URL, lnkName: String) -> URL? {
        let fm = FileManager.default
        let cxmenu = bottleURL.appendingPathComponent("desktopdata/cxmenu", isDirectory: true)
        guard let entries = try? fm.contentsOfDirectory(at: cxmenu, includingPropertiesForKeys: nil) else { return nil }
        // Desktop directories are named like: Desktop.C^5E3A_users_Public_Desktop
        for dir in entries where dir.lastPathComponent.hasPrefix("Desktop.") {
            let lnk = dir.appendingPathComponent(lnkName)
            if fm.fileExists(atPath: lnk.path) { return lnk }
        }
        return nil
    }

    /// The patched CrossOver a bottle belongs to. An `arm64` bottle only runs on the ARM copy.
    static func patchedBundleID(forBottle bottleURL: URL) -> String {
        let conf = bottleURL.appendingPathComponent("cxbottle.conf")
        let text = (try? String(contentsOf: conf, encoding: .utf8)) ?? ""
        let isArm = text.components(separatedBy: .newlines).contains {
            $0.contains("\"WineArch\"") && $0.contains("\"arm64\"")
        }
        return isArm ? CrossOverVariant.arm.patchedBundleIdentifier : CrossOverVariant.x64.patchedBundleIdentifier
    }

    /// Finds a Menu Helper binary in `app`, skipping one built for another patched CrossOver:
    /// a helper opens the app whose ID it hardcodes, so that alias would open the wrong copy.
    private static func menuHelper(in app: URL, patchedBundleID: String) -> URL? {
        let otherIDs = CrossOverVariant.allCases.map(\.patchedBundleIdentifier).filter { $0 != patchedBundleID }
        for name in ["Menu Helper", "Menu Helper arm64"] {
            let binary = app.appendingPathComponent("Contents/MacOS/\(name)")
            guard let data = try? Data(contentsOf: binary, options: .alwaysMapped) else { continue }
            if !otherIDs.contains(where: { data.range(of: Data(($0 + "\0").utf8)) != nil }) { return binary }
        }
        return nil
    }

    /// Finds the Menu Helper binary from an existing CrossOver-generated shortcut app.
    static func menuHelperBinary(patchedBundleID: String = AppAlias.patchedBundleID) -> URL? {
        let fm = FileManager.default
        let searchDirs = [
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications/CrossOver"),
        ]
        for dir in searchDirs {
            guard let apps = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { continue }
            for app in apps where app.pathExtension == "app" {
                if let binary = menuHelper(in: app, patchedBundleID: patchedBundleID) { return binary }
            }
            // Also look one level deeper (e.g. ~/Applications/CrossOver/GRYPHLINK/*.app)
            for subdir in (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [] {
                guard (try? subdir.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true else { continue }
                guard let apps2 = try? fm.contentsOfDirectory(at: subdir, includingPropertiesForKeys: nil) else { continue }
                for app in apps2 where app.pathExtension == "app" {
                    if let binary = menuHelper(in: app, patchedBundleID: patchedBundleID) { return binary }
                }
            }
        }
        return nil
    }

    /// Resolves default icon for the given app name from bundle resources or known asset locations.
    static func resolveDefaultIcon(for appName: String = defaultAppName) -> URL? {
        let fm = FileManager.default

        // Icon name to try based on app
        let names: [String]
        switch appName {
        case gryphLinkAppName:
            names = ["GRYPHLINK", "shortcut"]
        default:
            names = ["shortcut", "Endfield", "EndfieldShortcut"]
        }

        // 1. Bundle resources
        for name in names {
            if let url = Bundle.main.url(forResource: name, withExtension: "icns") { return url }
        }
        if let resURL = Bundle.main.resourceURL {
            for name in names {
                let f = resURL.appendingPathComponent("\(name).icns")
                if fm.fileExists(atPath: f.path) { return f }
            }
        }

        // 2. Project source resources (development fallback)
        let base = "/Users/RyanAngelina/Documents/Developer/Endfield_FineWine/patcher-app/Sources/FineWinePatcher/Resources"
        let candidatePaths = names.map { "\(base)/\($0).icns" } + [
            "/Users/RyanAngelina/.gemini/antigravity/brain/0729d02c-b211-4f27-8612-f142ed6b6915/.user_uploaded/media_1793355124173_95fc30ac.icns",
        ]
        for path in candidatePaths where fm.fileExists(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        return nil
    }

    /// Resolves the CrossOver-extracted PNG icon for the given app from the bottle's windata dir.
    /// Returns nil if the bottle path is not set or icon not found.
    static func resolveBottleIcon(for appName: String, bottleURL: URL) -> URL? {
        let fm = FileManager.default
        let iconDir = bottleURL.appendingPathComponent("windata/cxmenu/icons/hicolor/256x256/apps")
        guard fm.fileExists(atPath: iconDir.path) else { return nil }
        // Map app name to known icon filenames
        let candidates: [String]
        switch appName {
        case gryphLinkAppName:
            candidates = ["435C_Launcher.0.png"]
        default:
            candidates = ["E382_endfield.0.png"]
        }
        for name in candidates {
            let url = iconDir.appendingPathComponent(name)
            if fm.fileExists(atPath: url.path) { return url }
        }
        return nil
    }

    /// Determines the best Applications directory to install to:
    /// prefers `/Applications` if writable or if an app already exists there, otherwise `~/Applications`.
    static func targetApplicationsDirectory(for appName: String) -> URL {
        let fm = FileManager.default
        let systemApps = URL(fileURLWithPath: "/Applications", isDirectory: true)
        let systemAppPath = systemApps.appendingPathComponent("\(appName).app")

        if fm.fileExists(atPath: systemAppPath.path) && fm.isWritableFile(atPath: systemAppPath.path) {
            return systemApps
        }
        if fm.isWritableFile(atPath: systemApps.path) {
            return systemApps
        }
        return fm.homeDirectoryForCurrentUser.appendingPathComponent("Applications", isDirectory: true)
    }

    /// Converts a PNG to a multi-size .icns file using sips + iconutil.
    /// Returns true on success.
    @discardableResult
    static func buildIconSet(from pngURL: URL, outputIcns: URL) -> Bool {
        let fm = FileManager.default
        let iconsetURL = outputIcns.deletingPathExtension().appendingPathExtension("iconset")
        try? fm.createDirectory(at: iconsetURL, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: iconsetURL) }

        for size in [16, 32, 64, 128, 256] {
            for scale in [1, 2] {
                let px = size * scale
                let name = scale == 1 ? "icon_\(size)x\(size).png" : "icon_\(size)x\(size)@2x.png"
                let out = iconsetURL.appendingPathComponent(name)
                let sips = Process()
                sips.executableURL = URL(fileURLWithPath: "/usr/bin/sips")
                sips.arguments = ["-z", "\(px)", "\(px)", pngURL.path, "--out", out.path]
                sips.standardOutput = Pipe(); sips.standardError = Pipe()
                try? sips.run(); sips.waitUntilExit()
            }
        }

        let iconutil = Process()
        iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
        iconutil.arguments = ["-c", "icns", iconsetURL.path, "-o", outputIcns.path]
        iconutil.standardOutput = Pipe(); iconutil.standardError = Pipe()
        try? iconutil.run(); iconutil.waitUntilExit()
        return fm.fileExists(atPath: outputIcns.path)
    }

    // MARK: - Create

    /// Creates or overwrites the alias bundle. Uses CrossOver's Menu Helper binary so
    /// CrossOver handles all Wine environment setup natively.
    /// Returns the URL of the created bundle.
    @discardableResult
    static func create(config: Config, iconSource: URL? = nil) throws -> URL {
        let fm = FileManager.default
        let appsDir = targetApplicationsDirectory(for: config.appName)
        try fm.createDirectory(at: appsDir, withIntermediateDirectories: true)

        let appDir = appsDir.appendingPathComponent("\(config.appName).app", isDirectory: true)

        // Remove previous version
        if fm.fileExists(atPath: appDir.path) {
            try fm.removeItem(at: appDir)
        }

        let contents = appDir.appendingPathComponent("Contents", isDirectory: true)
        let macOS = contents.appendingPathComponent("MacOS", isDirectory: true)
        let resources = contents.appendingPathComponent("Resources", isDirectory: true)
        try fm.createDirectory(at: macOS, withIntermediateDirectories: true)
        try fm.createDirectory(at: resources, withIntermediateDirectories: true)

        // Resolve bottle URL
        let bottleURL: URL? = {
            if let bp = config.bottlePath, !bp.isEmpty {
                let u = URL(fileURLWithPath: bp)
                if fm.fileExists(atPath: u.path) { return u }
            }
            let standard = fm.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support/CrossOver/Bottles/\(config.bottleName)")
            return fm.fileExists(atPath: standard.path) ? standard : nil
        }()

        var config = config
        if let bottleURL { config.patchedAppBundleID = patchedBundleID(forBottle: bottleURL) }

        // 1. Menu Helper binary
        let helperBinary = menuHelperBinary(patchedBundleID: config.patchedAppBundleID)
        if let helperBinary {
            let dest = macOS.appendingPathComponent(config.appName)
            try fm.copyItem(at: helperBinary, to: dest)
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dest.path)
        }

        // 2. Resources from existing CrossOver shortcut (nibs, localizations)
        if let helperBinary {
            let srcResources = helperBinary
                .deletingLastPathComponent()           // MacOS/
                .deletingLastPathComponent()           // Contents/
                .appendingPathComponent("Resources", isDirectory: true)
            if fm.fileExists(atPath: srcResources.path) {
                let entries = (try? fm.contentsOfDirectory(at: srcResources, includingPropertiesForKeys: nil)) ?? []
                for entry in entries {
                    try? fm.copyItem(at: entry, to: resources.appendingPathComponent(entry.lastPathComponent))
                }
            }
        }

        // 3. Icon — CrossOver convention uses "CrossOverHelper.icns" as the icon filename
        // Prefer: provided source > bottle PNG (converted) > bundled icns
        var chosenIcon = iconSource
        if chosenIcon == nil, let bURL = bottleURL {
            chosenIcon = resolveBottleIcon(for: config.appName, bottleURL: bURL)
                .flatMap { pngURL -> URL? in
                    // Convert PNG to icns in a temp location
                    let tmp = FileManager.default.temporaryDirectory
                        .appendingPathComponent("finewine-icon-\(UUID().uuidString).icns")
                    return buildIconSet(from: pngURL, outputIcns: tmp) ? tmp : nil
                }
        }
        if chosenIcon == nil {
            chosenIcon = resolveDefaultIcon(for: config.appName)
        }
        if let chosenIcon, fm.fileExists(atPath: chosenIcon.path) {
            // Write as CrossOverHelper.icns (what CFBundleIconFile references)
            let dest = resources.appendingPathComponent("CrossOverHelper.icns")
            try? fm.removeItem(at: dest)
            try? fm.copyItem(at: chosenIcon, to: dest)
        }

        // 4. PkgInfo
        try Data("APPL????".utf8).write(to: contents.appendingPathComponent("PkgInfo"))

        // 5. Info.plist
        try writeInfoPlist(to: contents, config: config, bottleURL: bottleURL)

        // 6. Strip quarantine
        let xattr = Process()
        xattr.executableURL = URL(fileURLWithPath: "/usr/bin/xattr")
        xattr.arguments = ["-rd", "com.apple.quarantine", appDir.path]
        xattr.standardOutput = Pipe(); xattr.standardError = Pipe()
        try? xattr.run(); xattr.waitUntilExit()

        // 7. Ad-hoc sign
        let cs = Process()
        cs.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        cs.arguments = ["--force", "--sign", "-", "--timestamp=none", appDir.path]
        cs.standardOutput = Pipe(); cs.standardError = Pipe()
        try? cs.run(); cs.waitUntilExit()

        // 8. Refresh LaunchServices
        let lsr = Process()
        lsr.executableURL = URL(fileURLWithPath: "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister")
        lsr.arguments = ["-f", appDir.path]
        lsr.standardOutput = Pipe(); lsr.standardError = Pipe()
        try? lsr.run(); lsr.waitUntilExit()

        // Clean up any outdated copy in ~/Applications if we installed to /Applications
        let userApp = fm.homeDirectoryForCurrentUser.appendingPathComponent("Applications/\(config.appName).app")
        if appDir.path != userApp.path && fm.fileExists(atPath: userApp.path) {
            try? fm.removeItem(at: userApp)
        }

        return appDir
    }

    /// Checks whether an alias already exists in /Applications or ~/Applications.
    static func existingAlias(named name: String = defaultAppName) -> URL? {
        let fm = FileManager.default
        let candidates = [
            URL(fileURLWithPath: "/Applications/\(name).app"),
            fm.homeDirectoryForCurrentUser.appendingPathComponent("Applications/\(name).app"),
        ]
        return candidates.first { fm.fileExists(atPath: $0.path) }
    }

    /// Removes an existing alias from both /Applications and ~/Applications.
    static func remove(named name: String = defaultAppName) throws {
        let fm = FileManager.default
        let candidates = [
            URL(fileURLWithPath: "/Applications/\(name).app"),
            fm.homeDirectoryForCurrentUser.appendingPathComponent("Applications/\(name).app"),
        ]
        for path in candidates where fm.fileExists(atPath: path.path) {
            try fm.removeItem(at: path)
        }
    }

    // MARK: - Plist

    private static func writeInfoPlist(to contents: URL, config: Config, bottleURL: URL?) throws {
        // Resolve lnk path and bottle tag
        let lnkURL: URL? = bottleURL.flatMap { Self.lnkURL(in: $0, lnkName: config.lnkName) }
        let bottleTag: String? = bottleURL.flatMap { Self.bottleTag(in: $0) }
        let bottlePath = bottleURL?.path ?? ""

        let lnkPath = lnkURL?.path ?? "\(bottlePath)/desktopdata/cxmenu/Desktop.C^5E3A_users_Public_Desktop/\(config.lnkName)"
        let tag = bottleTag.map { "CrossOver-\($0)/" } ?? ""

        // CrossOverHelperMenuPath uses a relative-style encoding that CrossOver compares against
        // MostRecentCXFBMenuPlist RawPath entries. Format: Desktop.C^3A_users_Public_Desktop/<name>.lnk
        // The lnk filename in RawPath uses spaces (not +) — match that exactly.
        let lnkBaseName = config.lnkName.replacingOccurrences(of: "+", with: " ")
        let menuPath = "Desktop.C^3A_users_Public_Desktop/\(lnkBaseName)"

        var plist: [String: Any] = [
            "CFBundleDevelopmentRegion": "English",
            "CFBundleDocumentTypes": [[
                "CFBundleTypeRole": "Viewer",
                "LSItemContentTypes": ["com.codeweavers.CrossOverHelper.MenuDummyType"],
            ]],
            "CFBundleExecutable": config.appName,
            // CrossOver convention: icon file is named "CrossOverHelper"
            "CFBundleIconFile": "CrossOverHelper",
            "CFBundleIdentifier": config.bundleID ?? bundleIdentifier,
            "CFBundleInfoDictionaryVersion": "6.0",
            "CFBundleName": config.appName,
            "CFBundleDisplayName": config.appName,
            "CFBundlePackageType": "APPL",
            "CFBundleVersion": "1.0",
            "CFBundleShortVersionString": "1.0",
            "CXHelperAppBottleName": config.bottleName,
            "CXHelperAppBottleTag": tag,
            "CXHelperAppVersion": 43,
            "CXOriginalMenuName": config.appName,
            "CrossOverHelperCommand": "\"\(lnkPath)\"",
            "CrossOverHelperMenuPath": menuPath,
            "LSBackgroundOnly": false,
            "LSMinimumSystemVersion": "10.15",
            "NSHighResolutionCapable": true,
            "NSCameraUsageDescription": "A Windows application is trying to access the camera.",
            "NSMainNibFile": "MainMenu",
            "NSMicrophoneUsageDescription": "A Windows application is trying to access the microphone.",
            "NSPrincipalClass": "CXFBHelperApp",
            "NSRequiresAquaSystemAppearance": "NO",
            "NSUpdateSecurityPolicy": [
                "AllowProcesses": ["9C6B7X7Z8E": [config.patchedAppBundleID]],
            ],
            "UTImportedTypeDeclarations": [[
                "UTTypeIdentifier": "com.codeweavers.CrossOverHelper.MenuDummyType",
            ]],
        ]

        // LSEnvironment — env vars from Bottle Settings for Dock launches
        if !config.environment.isEmpty {
            plist["LSEnvironment"] = config.environment
        }

        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try data.write(to: contents.appendingPathComponent("Info.plist"), options: .atomic)
    }
}
