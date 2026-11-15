import Foundation

/// The Windows version a prefix reports. The raw value is the name Wine itself uses
/// (`winecfg /v <name>`, `HKCU\Software\Wine\Version`).
public enum WindowsVersion: String, Codable, CaseIterable, Sendable {
    case win11, win10, win81, win8, win7, vista, winxp64, winxp

    public var displayName: String {
        switch self {
        case .win11: return "Windows 11"
        case .win10: return "Windows 10"
        case .win81: return "Windows 8.1"
        case .win8: return "Windows 8"
        case .win7: return "Windows 7"
        case .vista: return "Windows Vista"
        case .winxp64: return "Windows XP (64-bit)"
        case .winxp: return "Windows XP"
        }
    }
}

public enum GraphicsBackend: String, Codable, CaseIterable, Sendable {
    /// Direct3D 10/11 on Metal.
    case dxmt
    /// Direct3D on Vulkan, through MoltenVK.
    case dxvk
    /// Wine's own Direct3D (OpenGL/Vulkan); needs nothing from the runtime.
    case wined3d

    public var displayName: String {
        switch self {
        case .dxmt: return "DXMT (Direct3D 10/11 on Metal)"
        case .dxvk: return "DXVK (Direct3D on Vulkan / MoltenVK)"
        case .wined3d: return "WineD3D (built in)"
        }
    }

    /// What the choice covers, for showing under the picker. Direct3D 12 and Vulkan are not
    /// part of it: a FineWine runtime always provides both through MoltenVK.
    public static let scopeNote = "This chooses how Direct3D 9, 10 and 11 are drawn. Direct3D 12 and Vulkan are always available, through MoltenVK."
}

/// How Windows synchronisation objects (events, mutexes, semaphores) are implemented.
public enum SyncMode: String, Codable, CaseIterable, Sendable {
    /// Every wait goes through the Wine server.
    case standard
    /// MSync: waits are handled in the program's own process with Mach semaphores, which is
    /// much faster for games. It is the macOS counterpart of ESync and FSync on Linux, neither
    /// of which exists for macOS in this generation of Wine.
    case msync

    public var displayName: String {
        switch self {
        case .standard: return "Wine server (slower, most compatible)"
        case .msync: return "MSync (faster)"
        }
    }

    /// Reads a stored value. Prefixes saved when ESync was still offered fall back to the
    /// Wine server, since no runtime provides ESync.
    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = SyncMode(rawValue: raw) ?? .standard
    }
}

/// How Wine should load one DLL. The raw value is what goes in the registry.
public enum DLLLoadOrder: String, Codable, CaseIterable, Sendable {
    case nativeThenBuiltin = "native,builtin"
    case builtinThenNative = "builtin,native"
    case native
    case builtin
    case disabled = ""

    public var displayName: String {
        switch self {
        case .nativeThenBuiltin: return "Native, then built in"
        case .builtinThenNative: return "Built in, then native"
        case .native: return "Native only"
        case .builtin: return "Built in only"
        case .disabled: return "Disabled"
        }
    }

    /// The short form `WINEDLLOVERRIDES` uses.
    public var environmentCode: String {
        switch self {
        case .nativeThenBuiltin: return "n,b"
        case .builtinThenNative: return "b,n"
        case .native: return "n"
        case .builtin: return "b"
        case .disabled: return ""
        }
    }
}

public struct DLLOverride: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    /// The DLL's name without `.dll`, as winecfg stores it (`d3d11`). Programs keep their
    /// extension (`winemenubuilder.exe`).
    public var name: String
    public var order: DLLLoadOrder

    public init(id: UUID = UUID(), name: String, order: DLLLoadOrder) {
        self.id = id
        self.name = name
        self.order = order
    }

    /// Lower-cased, trimmed, and without a `.dll` suffix.
    public static func normalizedName(_ raw: String) -> String {
        var name = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if name.hasSuffix(".dll") { name.removeLast(4) }
        return name
    }
}

public struct EnvironmentVariable: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var value: String

    public init(id: UUID = UUID(), name: String, value: String) {
        self.id = id
        self.name = name
        self.value = value
    }

    /// A name the shell would accept: letters, digits and underscores, not starting with a digit.
    public static func isValidName(_ name: String) -> Bool {
        guard let first = name.unicodeScalars.first else { return false }
        let letters = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz_")
        let rest = letters.union(CharacterSet(charactersIn: "0123456789"))
        return letters.contains(first) && name.unicodeScalars.allSatisfy(rest.contains)
    }
}

public struct VirtualDesktop: Codable, Equatable, Sendable {
    public var width: Int
    public var height: Int
    public init(width: Int, height: Int) {
        self.width = width
        self.height = height
    }
}

/// Everything a user can configure about a prefix. Settings are stored in the prefix's metadata
/// and turned into registry edits and environment variables when they are applied.
public struct PrefixSettings: Codable, Equatable, Sendable {
    public var windowsVersion: WindowsVersion = .win11
    /// Overrides the build number Windows reports (e.g. `26100`); empty leaves Wine's own.
    public var windowsBuild: String = ""
    public var graphicsBackend: GraphicsBackend = .dxmt
    public var syncMode: SyncMode = .standard
    public var dllOverrides: [DLLOverride] = []
    public var environment: [EnvironmentVariable] = []
    /// High-resolution mode: programs render at the display's real pixel resolution instead of
    /// being drawn at half size and scaled up. On by default.
    public var retinaMode: Bool = true
    /// Pick the DPI from the display, so that text and controls stay the size macOS shows them
    /// at while high-resolution mode gives them the display's full sharpness. On by default.
    public var automaticDPI: Bool = true
    /// Screen DPI used when `automaticDPI` is off; 96 is 100% scaling.
    public var dpi: Int = 96
    /// Run programs inside one desktop window of this size instead of separate Mac windows.
    public var virtualDesktop: VirtualDesktop?
    public var leftOptionIsAlt: Bool = true
    public var rightOptionIsAlt: Bool = true
    /// Show Metal's performance overlay.
    public var metalHUD: Bool = false
    /// Hide the "running under a hypervisor" CPU flag from x64 programs (a FEX setting).
    public var hideHypervisor: Bool = false
    /// Let games that offer NVIDIA DLSS upscale through Apple's MetalFX instead. Takes effect
    /// with DXMT, whose nvngx.dll does the translation. FSR needs nothing: it is the game's own
    /// shader code and runs as it is.
    public var dlssThroughMetalFX: Bool = true
    /// Give Windows controls macOS colours, fonts and the Mac's accent colour.
    public var macAppearance: Bool = true
    /// Wine debug channels (`WINEDEBUG`). `-all` is silent and fastest.
    public var debugChannels: String = "-all"

    public init() {}

    // Decoded field by field so a metadata file written by an older FineWine (missing newer
    // fields) still loads, with defaults for whatever it lacks.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = PrefixSettings()
        windowsVersion = try c.decodeIfPresent(WindowsVersion.self, forKey: .windowsVersion) ?? d.windowsVersion
        windowsBuild = try c.decodeIfPresent(String.self, forKey: .windowsBuild) ?? d.windowsBuild
        graphicsBackend = try c.decodeIfPresent(GraphicsBackend.self, forKey: .graphicsBackend) ?? d.graphicsBackend
        syncMode = try c.decodeIfPresent(SyncMode.self, forKey: .syncMode) ?? d.syncMode
        dllOverrides = try c.decodeIfPresent([DLLOverride].self, forKey: .dllOverrides) ?? d.dllOverrides
        environment = try c.decodeIfPresent([EnvironmentVariable].self, forKey: .environment) ?? d.environment
        retinaMode = try c.decodeIfPresent(Bool.self, forKey: .retinaMode) ?? d.retinaMode
        dpi = try c.decodeIfPresent(Int.self, forKey: .dpi) ?? d.dpi
        // A prefix saved before automatic scaling existed keeps the DPI its user chose.
        automaticDPI = try c.decodeIfPresent(Bool.self, forKey: .automaticDPI) ?? (c.contains(.dpi) ? false : d.automaticDPI)
        virtualDesktop = try c.decodeIfPresent(VirtualDesktop.self, forKey: .virtualDesktop)
        leftOptionIsAlt = try c.decodeIfPresent(Bool.self, forKey: .leftOptionIsAlt) ?? d.leftOptionIsAlt
        rightOptionIsAlt = try c.decodeIfPresent(Bool.self, forKey: .rightOptionIsAlt) ?? d.rightOptionIsAlt
        metalHUD = try c.decodeIfPresent(Bool.self, forKey: .metalHUD) ?? d.metalHUD
        hideHypervisor = try c.decodeIfPresent(Bool.self, forKey: .hideHypervisor) ?? d.hideHypervisor
        debugChannels = try c.decodeIfPresent(String.self, forKey: .debugChannels) ?? d.debugChannels
        macAppearance = try c.decodeIfPresent(Bool.self, forKey: .macAppearance) ?? d.macAppearance
        dlssThroughMetalFX = try c.decodeIfPresent(Bool.self, forKey: .dlssThroughMetalFX) ?? d.dlssThroughMetalFX
    }

    // MARK: Validation

    /// Problems that would make the settings fail to apply, in the user's terms.
    public func validationProblems() -> [String] {
        var problems: [String] = []
        if !windowsBuild.isEmpty, UInt32(windowsBuild) == nil {
            problems.append("The Windows build must be a number, such as 26100.")
        }
        if !automaticDPI, !(72...480).contains(dpi) {
            problems.append("The DPI must be between 72 and 480.")
        }
        if let desktop = virtualDesktop, desktop.width < 640 || desktop.height < 480 {
            problems.append("The virtual desktop must be at least 640 × 480.")
        }
        for variable in environment where !EnvironmentVariable.isValidName(variable.name) {
            problems.append("“\(variable.name)” is not a valid environment variable name.")
        }
        let names = dllOverrides.map { DLLOverride.normalizedName($0.name) }
        if names.contains(where: \.isEmpty) {
            problems.append("A DLL override has no name.")
        }
        if Set(names).count != names.count {
            problems.append("A DLL is listed more than once in the overrides.")
        }
        return problems
    }

    // MARK: Registry

    static let wineKey = #"HKEY_CURRENT_USER\Software\Wine"#
    static let overridesKey = #"HKEY_CURRENT_USER\Software\Wine\DllOverrides"#
    static let macDriverKey = #"HKEY_CURRENT_USER\Software\Wine\Mac Driver"#
    static let explorerKey = #"HKEY_CURRENT_USER\Software\Wine\Explorer"#
    static let desktopsKey = #"HKEY_CURRENT_USER\Software\Wine\Explorer\Desktops"#
    static let desktopKey = #"HKEY_CURRENT_USER\Control Panel\Desktop"#
    static let currentVersionKey = #"HKEY_LOCAL_MACHINE\Software\Microsoft\Windows NT\CurrentVersion"#

    /// The registry edits that bring a prefix in line with these settings. `previous` is what
    /// was applied last time; overrides it had that are gone now are deleted.
    /// The DPI Windows programs are told about. With automatic scaling it follows the display:
    /// in high-resolution mode a Retina display (scale 2) gives 192, so a program laid out for
    /// 96 DPI ends up the same physical size as on macOS, drawn with four times the pixels.
    /// Without high-resolution mode Wine already works in points, so the DPI stays at 96.
    public func effectiveDPI(displayScale: Double) -> Int {
        guard automaticDPI else { return dpi }
        guard retinaMode else { return 96 }
        let scale = min(max(displayScale, 1), 4)
        return Int((96 * scale).rounded())
    }

    /// `appearance` is the Mac's current look; with it and `macAppearance` on, the edits also
    /// style Windows controls to match. `displayScale` is the main display's backing scale
    /// factor (2 on a Retina display), used for automatic DPI.
    public func registryEdits(replacing previous: PrefixSettings? = nil,
                              appearance: MacAppearance? = nil,
                              displayScale: Double = 1) -> [RegistryEdit] {
        var edits: [RegistryEdit] = [.string(Self.wineKey, "Version", windowsVersion.rawValue)]

        if !windowsBuild.isEmpty {
            edits.append(.string(Self.currentVersionKey, "CurrentBuild", windowsBuild))
            edits.append(.string(Self.currentVersionKey, "CurrentBuildNumber", windowsBuild))
        }

        let current = Set(dllOverrides.map { DLLOverride.normalizedName($0.name) })
        for old in previous?.dllOverrides ?? [] {
            let name = DLLOverride.normalizedName(old.name)
            if !name.isEmpty, !current.contains(name) { edits.append(.delete(Self.overridesKey, name)) }
        }
        for override in dllOverrides {
            let name = DLLOverride.normalizedName(override.name)
            guard !name.isEmpty else { continue }
            edits.append(.string(Self.overridesKey, name, override.order.rawValue))
        }

        edits.append(.string(Self.macDriverKey, "RetinaMode", retinaMode ? "y" : "n"))
        edits.append(.string(Self.macDriverKey, "LeftOptionIsAlt", leftOptionIsAlt ? "y" : "n"))
        edits.append(.string(Self.macDriverKey, "RightOptionIsAlt", rightOptionIsAlt ? "y" : "n"))
        edits.append(.dword(Self.desktopKey, "LogPixels", UInt32(max(effectiveDPI(displayScale: displayScale), 0))))

        if let desktop = virtualDesktop {
            edits.append(.string(Self.explorerKey, "Desktop", "Default"))
            edits.append(.string(Self.desktopsKey, "Default", "\(desktop.width)x\(desktop.height)"))
        } else {
            edits.append(.delete(Self.explorerKey, "Desktop"))
        }

        if macAppearance, let appearance {
            edits += MacStyle.registryEdits(for: appearance)
        } else if !macAppearance, previous?.macAppearance == true {
            edits += MacStyle.removalEdits()
        }
        return edits
    }

    // MARK: Environment

    /// The environment variables these settings add to every Wine process in the prefix. The
    /// user's own variables come last so they can override anything above them.
    public func environmentVariables() -> [(name: String, value: String)] {
        var out: [(String, String)] = [("WINEDEBUG", debugChannels.isEmpty ? "-all" : debugChannels)]
        switch syncMode {
        case .standard: break
        case .msync: out.append(("WINEMSYNC", "1"))
        }
        if metalHUD { out.append(("MTL_HUD_ENABLED", "1")) }
        if hideHypervisor { out.append(("FEX_HIDEHYPERVISORBIT", "1")) }
        // DXMT turns its NVIDIA stand-ins on with this variable: it then registers its nvngx.dll
        // where the DLSS SDK inside a game looks for NVIDIA's, and DLSS upscaling runs as
        // MetalFX. Without it DXMT removes that registration and games see no DLSS.
        if dlssThroughMetalFX, graphicsBackend == .dxmt { out.append(("DXMT_ENABLE_NVEXT", "1")) }
        for variable in environment where EnvironmentVariable.isValidName(variable.name) {
            out.append((variable.name, variable.value))
        }
        return out
    }
}

/// What a prefix's registry files say right now, for showing next to the stored settings.
public struct PrefixRegistrySnapshot: Equatable, Sendable {
    public var windowsVersion: String?
    public var windowsBuild: String?
    public var dllOverrides: [String: String] = [:]
    public var retinaMode: Bool?
    public var dpi: Int?
    public var virtualDesktop: String?

    public init() {}

    /// Reads `user.reg` and `system.reg` from a prefix. Missing files give an empty snapshot.
    public static func read(prefix: URL) -> PrefixRegistrySnapshot {
        var snapshot = PrefixRegistrySnapshot()
        if let user = try? WineRegistryReader(contentsOf: prefix.appendingPathComponent("user.reg")) {
            snapshot.windowsVersion = user.string(key: #"Software\Wine"#, name: "Version")
            for (name, value) in user.values(key: #"Software\Wine\DllOverrides"#) {
                if case .string(let order) = value { snapshot.dllOverrides[name] = order }
            }
            snapshot.retinaMode = user.string(key: #"Software\Wine\Mac Driver"#, name: "RetinaMode").map {
                $0.lowercased().hasPrefix("y")
            }
            snapshot.dpi = user.dword(key: #"Control Panel\Desktop"#, name: "LogPixels").map(Int.init)
            if user.string(key: #"Software\Wine\Explorer"#, name: "Desktop") != nil {
                snapshot.virtualDesktop = user.string(key: #"Software\Wine\Explorer\Desktops"#, name: "Default")
            }
        }
        if let system = try? WineRegistryReader(contentsOf: prefix.appendingPathComponent("system.reg")) {
            snapshot.windowsBuild = system.string(key: #"Software\Microsoft\Windows NT\CurrentVersion"#,
                                                  name: "CurrentBuild")
        }
        return snapshot
    }
}
