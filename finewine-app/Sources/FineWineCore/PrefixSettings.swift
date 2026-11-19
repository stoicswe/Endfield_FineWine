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
        case .dxmt: return tr("backend.dxmt")
        case .dxvk: return tr("backend.dxvk")
        case .wined3d: return tr("backend.wined3d")
        }
    }

    /// What the choice covers, for showing under the picker. Direct3D 12 and Vulkan are not
    /// part of it: a FineWine runtime always provides both through MoltenVK.
    public static var scopeNote: String { tr("backend.scope_note") }
}

/// The language Windows programs that are not Unicode are run in: Windows' "Language for
/// non-Unicode programs". It picks the ANSI code page their text goes through (932 Shift-JIS,
/// 936 GBK, 949 for Korean, 950 Big5) and the region formats; Wine's own interface keeps the
/// Mac's language. Unicode programs, most games among them, show every language either way:
/// the runtime has fonts for Chinese, Japanese and Korean whatever this says.
public enum NonUnicodeLanguage: String, Codable, CaseIterable, Sendable {
    /// What the Mac's language and region give (Wine's own choice).
    case automatic
    case english
    case japanese
    case chineseSimplified
    case chineseTraditional
    case korean

    public var displayName: String {
        switch self {
        case .automatic: return tr("nonunicode.automatic")
        case .english: return tr("nonunicode.english")
        // Each language in its own name, as Windows and macOS list them.
        case .japanese: return "日本語"
        case .chineseSimplified: return "简体中文"
        case .chineseTraditional: return "繁體中文"
        case .korean: return "한국어"
        }
    }

    /// The Mac locale Wine takes the code page from (`LC_CTYPE`); nil leaves Wine's own choice.
    public var unixLocale: String? {
        switch self {
        case .automatic: return nil
        case .english: return "en_US.UTF-8"
        case .japanese: return "ja_JP.UTF-8"
        case .chineseSimplified: return "zh_CN.UTF-8"
        case .chineseTraditional: return "zh_TW.UTF-8"
        case .korean: return "ko_KR.UTF-8"
        }
    }

    /// The ANSI code page programs get with this choice; nil for automatic.
    public var codePage: Int? {
        switch self {
        case .automatic: return nil
        case .english: return 1252
        case .japanese: return 932
        case .chineseSimplified: return 936
        case .chineseTraditional: return 950
        case .korean: return 949
        }
    }
}

/// How Windows synchronisation objects (events, mutexes, semaphores) are implemented.
/// How a program's full-screen window is presented on the Mac.
public enum FullScreenMode: String, Codable, CaseIterable, Sendable {
    /// A full-screen Space of its own, as a Mac game has: the menu bar appears at the top
    /// edge, swiping goes back to the desktop, notifications show over the game.
    case space
    /// An ordinary window that covers the screen; the menu bar and Dock hide until the pointer
    /// reaches the edge. The game stays on the desktop it was started on.
    case borderless
    /// Wine's own way: the window is raised above the menu bar and the Dock, which never appear.
    case exclusive

    public var displayName: String {
        switch self {
        case .space: return tr("fullscreen.space")
        case .borderless: return tr("fullscreen.borderless")
        case .exclusive: return tr("fullscreen.exclusive")
        }
    }
}

public enum SyncMode: String, Codable, CaseIterable, Sendable {
    /// Every wait goes through the Wine server.
    case standard
    /// MSync: waits are handled in the program's own process with Mach semaphores, which is
    /// much faster for games. It is the macOS counterpart of ESync and FSync on Linux, neither
    /// of which exists for macOS in this generation of Wine.
    case msync

    public var displayName: String {
        switch self {
        case .standard: return tr("sync.standard")
        case .msync: return tr("sync.msync")
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
        case .nativeThenBuiltin: return tr("dll_order.native_builtin")
        case .builtinThenNative: return tr("dll_order.builtin_native")
        case .native: return tr("dll_order.native")
        case .builtin: return tr("dll_order.builtin")
        case .disabled: return tr("dll_order.disabled")
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
    /// MSync by default: Windows events, mutexes and semaphores are Mach semaphores inside the
    /// program instead of requests to Wine's server, which measured 4 to 23 times faster
    /// (docs/project-information/22-performance.md).
    public var syncMode: SyncMode = .msync
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
    /// Hide the "running under a hypervisor" CPU flag from x64 programs (a FEX setting). FEX
    /// sets the flag to announce itself as an emulator; the Mac is not a virtual machine, and
    /// games that refuse to run in one ("cannot run under a Virtual Machine") refuse here too.
    /// On by default, by the user's decision (2026-11-15).
    public var hideHypervisor: Bool = true
    /// Back a program's memory with a shared file of zeroes instead of anonymous memory
    /// (runtime patch 0036, `FINEWINE_ZERO_PAGES`). macOS charges a program for every page it
    /// reads, even one it never wrote; a game that reads through its own memory (anti-cheat
    /// does) then pays for everything it has set aside and not used. With this on such reads
    /// cost nothing; the first write to a page is about a microsecond slower. On by default
    /// since v2.1; can be turned off if a program misbehaves.
    public var zeroPages: Bool = true
    /// Have the x64 emulator keep its per-thread record of translated code in a compact form
    /// (fex patch 0008, `FEX_COMPACTBLOCKRECORDS`). The usual record costs about 60 bytes for
    /// each piece of translated code each thread has run, gigabytes in a large game with many
    /// threads. On by default since v2.1; can be turned off if a game stutters more or misbehaves.
    public var compactBlockRecords: Bool = true
    /// Let games that offer NVIDIA DLSS use Apple's MetalFX instead: super resolution as
    /// MetalFX upscaling, frame generation as MetalFX frame interpolation. Direct3D 10 and 11
    /// games get it from DXMT; Direct3D 12 and Vulkan games from the runtime's MoltenVK. FSR
    /// needs nothing: it is the game's own shader code and runs as it is.
    public var dlssThroughMetalFX: Bool = true
    /// Report the GPU to Windows programs as an NVIDIA GeForce RTX 5080: its name and its PCI
    /// ids. The memory stays what it is. Games only offer DLSS on an NVIDIA adapter, so they
    /// need this to show the option; it is off by default because it is not the truth.
    public var reportNvidiaGPU: Bool = false

    /// How full-screen windows are presented. A Space of their own by default, so that a game
    /// behaves like a Mac game.
    public var fullScreenMode: FullScreenMode = .space
    /// Run programs that use Direct3D, Vulkan or OpenGL with the loader macOS treats as a game,
    /// so that Game Mode turns on when one is full screen.
    public var gameMode: Bool = true
    /// Start HoYoverse's games and launcher through the runtime's stand-in for the Steam
    /// client, as they are started on Linux. See `SteamStandIn`.
    public var steamForHoYoverse: Bool = true
    /// Give windows that have no Mac title bar (launchers, games in a window) a Mac window's
    /// round corners.
    public var roundedWindows: Bool = true
    /// Upscale a Direct3D 10 or 11 picture that is smaller than its window to the window's
    /// display pixels with MetalFX, instead of leaving the stretch to the window server.
    public var metalFXUpscaling: Bool = true
    /// Draw programs' icons in the Dock (and their shortcut apps' icons) as Mac app icons: a
    /// rounded square on Apple's icon grid. See `MacIconStyle`. On by default.
    public var macStyleIcons: Bool = true
    /// Windows' "Language for non-Unicode programs". See `NonUnicodeLanguage`.
    public var nonUnicodeLanguage: NonUnicodeLanguage = .automatic

    /// The PCI ids reported when `reportNvidiaGPU` is on: NVIDIA, and its GeForce RTX 5080.
    public static let reportedGPUVendorID: UInt16 = 0x10DE
    public static let reportedGPUDeviceID: UInt16 = 0x2C02
    public static let reportedGPUName = "NVIDIA GeForce RTX 5080"
    /// Apple's PCI vendor id, which is what the GPU really is.
    public static let appleGPUVendorID: UInt16 = 0x106B
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
        zeroPages = try c.decodeIfPresent(Bool.self, forKey: .zeroPages) ?? d.zeroPages
        compactBlockRecords = try c.decodeIfPresent(Bool.self, forKey: .compactBlockRecords) ?? d.compactBlockRecords
        debugChannels = try c.decodeIfPresent(String.self, forKey: .debugChannels) ?? d.debugChannels
        macAppearance = try c.decodeIfPresent(Bool.self, forKey: .macAppearance) ?? d.macAppearance
        dlssThroughMetalFX = try c.decodeIfPresent(Bool.self, forKey: .dlssThroughMetalFX) ?? d.dlssThroughMetalFX
        reportNvidiaGPU = try c.decodeIfPresent(Bool.self, forKey: .reportNvidiaGPU) ?? d.reportNvidiaGPU
        gameMode = try c.decodeIfPresent(Bool.self, forKey: .gameMode) ?? d.gameMode
        steamForHoYoverse = try c.decodeIfPresent(Bool.self, forKey: .steamForHoYoverse) ?? d.steamForHoYoverse
        roundedWindows = try c.decodeIfPresent(Bool.self, forKey: .roundedWindows) ?? d.roundedWindows
        metalFXUpscaling = try c.decodeIfPresent(Bool.self, forKey: .metalFXUpscaling) ?? d.metalFXUpscaling
        fullScreenMode = try c.decodeIfPresent(FullScreenMode.self, forKey: .fullScreenMode) ?? d.fullScreenMode
        macStyleIcons = try c.decodeIfPresent(Bool.self, forKey: .macStyleIcons) ?? d.macStyleIcons
        // An unknown value (from a newer FineWine) falls back to automatic.
        nonUnicodeLanguage = (try? c.decodeIfPresent(NonUnicodeLanguage.self, forKey: .nonUnicodeLanguage)) ?? d.nonUnicodeLanguage
    }

    // MARK: Validation

    /// Problems that would make the settings fail to apply, in the user's terms.
    public func validationProblems() -> [String] {
        var problems: [String] = []
        if !windowsBuild.isEmpty, UInt32(windowsBuild) == nil {
            problems.append(tr("validation.win_build_number"))
        }
        if !automaticDPI, !(72...480).contains(dpi) {
            problems.append(tr("validation.dpi_range"))
        }
        if let desktop = virtualDesktop, desktop.width < 640 || desktop.height < 480 {
            problems.append(tr("validation.desktop_min"))
        }
        for variable in environment where !EnvironmentVariable.isValidName(variable.name) {
            problems.append(tr("validation.env_invalid", variable.name))
        }
        let names = dllOverrides.map { DLLOverride.normalizedName($0.name) }
        if names.contains(where: \.isEmpty) {
            problems.append(tr("validation.dll_empty"))
        }
        if Set(names).count != names.count {
            problems.append(tr("validation.dll_duplicate"))
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

        // The localized names of Windows' Chinese, Japanese and Korean fonts (宋体, ＭＳ ゴシック,
        // 맑은 고딕, ...); the runtime's wine.inf maps the English ones. See CJKFonts.
        edits += CJKFonts.registryEdits(localizedOnly: true)

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
        // Metal only has its performance overlay in a process started with this set, so it is
        // always set: the overlay can then be shown and hidden while a game runs (View > Metal
        // HUD, or Option-F12). The setting decides whether it starts out shown.
        out.append(("MTL_HUD_ENABLED", "1"))
        out.append(("FINEWINE_METAL_HUD", metalHUD ? "1" : "0"))
        out.append(("FINEWINE_FULLSCREEN", fullScreenMode.rawValue))
        if !roundedWindows { out.append(("FINEWINE_ROUNDED_WINDOWS", "0")) }
        if !metalFXUpscaling { out.append(("FINEWINE_METALFX_AUTO", "0")) }
        if !macStyleIcons { out.append(("FINEWINE_MAC_ICONS", "0")) }
        if hideHypervisor { out.append(("FEX_HIDEHYPERVISORBIT", "1")) }
        if zeroPages { out.append(("FINEWINE_ZERO_PAGES", "1")) }
        if compactBlockRecords { out.append(("FEX_COMPACTBLOCKRECORDS", "1")) }
        // Wine takes the ANSI code page from LC_CTYPE, and the interface language from
        // LC_MESSAGES or LANG (or, with neither, the Mac's language), which stay as they are.
        // LC_ALL would override LC_CTYPE, so the environment drops it (LaunchPlanner).
        if let locale = nonUnicodeLanguage.unixLocale { out.append(("LC_CTYPE", locale)) }
        if dlssThroughMetalFX {
            // Lets nvngx.dll load for Direct3D 12 and Vulkan programs, whose DLSS calls it
            // turns into MetalFX work in MoltenVK.
            out.append(("FINEWINE_DLSS", "1"))
            // DXMT turns its NVIDIA stand-ins on with this variable: it then registers its
            // nvngx.dll where the DLSS SDK inside a game looks for NVIDIA's, and Direct3D 11
            // DLSS runs as MetalFX. Without it DXMT removes that registration.
            if graphicsBackend == .dxmt { out.append(("DXMT_ENABLE_NVEXT", "1")) }
        }
        // The ids the GPU is reported under, to each layer a program can ask: Vulkan
        // (MoltenVK), Wine's Direct3D (which Direct3D 12 also reports through), and DXMT.
        let vendor = String(Self.reportedGPUVendorID, radix: 16), device = String(Self.reportedGPUDeviceID, radix: 16)
        if reportNvidiaGPU {
            out.append(("FINEWINE_GPU_VENDOR_ID", vendor))
            out.append(("FINEWINE_GPU_DEVICE_ID", device))
            out.append(("FINEWINE_GPU_NAME", Self.reportedGPUName))
            out.append(("WINE_D3D_CONFIG", "VideoPciVendorID=0x\(vendor),VideoPciDeviceID=0x\(device)"))
            if graphicsBackend == .dxmt {
                out.append(("DXMT_CONFIG", "dxgi.customVendorId=\(vendor);dxgi.customDeviceId=\(device);dxgi.customDeviceDesc=\"\(Self.reportedGPUName)\""))
            }
        } else if dlssThroughMetalFX, graphicsBackend == .dxmt {
            // With its NVIDIA stand-ins on, DXMT reports NVIDIA's vendor id by itself. Whether
            // the GPU is reported as NVIDIA is this prefix's other setting, so say Apple's.
            out.append(("DXMT_CONFIG", "dxgi.customVendorId=\(String(Self.appleGPUVendorID, radix: 16))"))
        }
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
