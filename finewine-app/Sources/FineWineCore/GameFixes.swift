import Foundation

/// What a game is known to need to run, taken from Proton's own table of per-game settings
/// (the `proton` launch script) and expressed with the same switches, which the runtime reads
/// under Proton's names (runtime patch 0058). A game is recognised by its Steam app id.
///
/// Only what makes sense on a Mac is here. Proton's table also has entries for Linux's window
/// system, its synchronisation primitives, NVIDIA's libraries and its media converter.
public struct GameFixes: Equatable, Sendable {
    /// Environment variables for the game, by Proton's names.
    public var environment: [String: String] = [:]
    /// DLL load orders in `WINEDLLOVERRIDES` form.
    public var dllOverrides: [String: String] = [:]

    public var isEmpty: Bool { environment.isEmpty && dllOverrides.isEmpty }

    /// The fixes for a Steam app id, or none.
    public static func fixes(forSteamAppID appID: String) -> GameFixes {
        var fixes = GameFixes()
        if heapDelayFree.contains(appID) { fixes.environment["WINE_HEAP_DELAY_FREE"] = "1" }
        if heapZeroMemory.contains(appID) { fixes.environment["WINE_HEAP_ZERO_MEMORY"] = "1" }
        if heapTopDown.contains(appID) { fixes.environment["WINE_HEAP_TOP_DOWN"] = "1" }
        if let limit = processorLimit[appID] { fixes.environment["WINE_CPU_TOPOLOGY"] = String(limit) }
        if noSHAInOpenSSL.contains(appID) { fixes.environment["OPENSSL_ia32cap"] = "~0x20000000" }
        if let overrides = dllOverridesByApp[appID] { fixes.dllOverrides = overrides }
        return fixes
    }

    // Programs that read memory they have just freed.
    static let heapDelayFree: Set<String> = [
        "202990",   // Call of Duty: Black Ops II - Multiplayer
        "212910",   // Call of Duty: Black Ops II - Zombies
        "499100",   // Dark Parables: The Exiled Prince Collector's Edition
        "1404090",  // Trivia Tricks
        "2052410",  // WITCH ON THE HOLY NIGHT
        "789910",   // Planet of the Apes: Last Frontier
        "1183470",  // Imperiums: Greek Wars
        "876340",   // VR Slots 3D
    ]

    // Programs that read memory they never wrote.
    static let heapZeroMemory: Set<String> = [
        "21980",    // Call of Juarez: Bound in Blood
        "553850",   // Helldivers 2
        "2055290",  // Sonic Colors: Ultimate
    ]

    static let heapTopDown: Set<String> = [
        "71230",    // Crazy Taxi
        "3328910",  // MySims Kingdom
    ]

    /// The most processors the game copes with. Proton's entry for DIRT 5 ("performance cores
    /// only") is left out: the runtime limits the count and cannot choose which cores.
    static let processorLimit: [String: Int] = [
        "19900": 16,    // Far Cry 2
        "298110": 16,   // Far Cry 4
        "20920": 16,    // The Witcher 2: Assassins of Kings Enhanced Edition
        "35130": 16,    // Lara Croft and the Guardian of Light
        "55150": 16,    // Warhammer 40,000: Space Marine
        "204450": 16,   // Call of Juarez: Gunslinger
        "15620": 8,     // Warhammer 40,000: Dawn of War II
        "20570": 8,     // Warhammer 40,000: Dawn of War II - Chaos Rising
        "56400": 8,     // Warhammer 40,000: Dawn of War II - Retribution
        "618970": 4,    // Outcast - Second Contact
        "10150": 8,     // Prototype
        "2229830": 1,   // Command & Conquer and The Covert Operations
        "259170": 8,    // Alone in the Dark (2008)
        "11440": 4,     // DiRT
        "316260": 16,   // Disney Universe
        "286810": 30,   // Hard Truck Apocalypse: Rise of Clans / Ex Machina: Meridian 113
        "70000": 28,    // Dino D-Day
        "115320": 8,    // Prototype 2
        "65540": 16,    // Gothic 1 Classic
    ]

    // Games whose bundled OpenSSL crashes when it uses the processor's SHA instructions.
    static let noSHAInOpenSSL: Set<String> = [
        "661920", "558260", "386360", "487720", "879420", "649950", "1150080", "463150", "420290",
        "1092660", "1052070", "399810", "967390", "968870", "544920", "1055610", "682990", "551770",
        "392110", "447020", "834280", "890880", "433530", "521890", "783170", "1195460", "1029890",
        "535850", "711750", "882020", "824280", "775900", "415200", "748360", "1058450", "556180",
        "561600", "798290", "366870", "485030", "469610", "759740", "1342260", "425670", "1096570",
        "492230", "996580", "437630", "442780", "433100", "406970", "451520", "1237970", "1051200",
        "285190", "1133320",
    ]

    // Games that bring their own copy of a system library and need it used first.
    static let dllOverridesByApp: [String: [String: String]] = [
        "500810": ["ddraw": "n,b"],     // Arcanum
        "4249100": ["ddraw": "n,b"],    // Resident Evil (1996)
        "4249110": ["ddraw": "n,b"],    // Resident Evil 2 (1998)
        "4249130": ["ddraw": "n,b"],    // Dino Crisis
        "4249150": ["ddraw": "n,b"],    // Breath of Fire IV
        "3780660": ["dinput": "n,b"],
        "2471120": ["winmm": "n,b"],
        "1928420": ["gameinput": "d"],
    ]
}

/// Finds the Steam app id of a game that was not started by Steam: from a `steam_appid.txt`
/// beside the program or up to two folders above it, or from the Steam library the game is
/// installed in (`steamapps/appmanifest_<id>.acf` naming the game's folder).
public enum SteamAppIDFinder {
    public static func appID(forProgramAt url: URL, fileManager: FileManager = .default) -> String? {
        var folder = url.deletingLastPathComponent()
        var folders: [URL] = []
        for _ in 0..<3 {
            folders.append(folder)
            let parent = folder.deletingLastPathComponent()
            if parent.path == folder.path { break }
            folder = parent
        }
        for candidate in folders {
            if let text = try? String(contentsOf: candidate.appendingPathComponent("steam_appid.txt"), encoding: .utf8),
               let id = digits(text) { return id }
        }
        // <library>/steamapps/common/<game folder>/...
        let parts = url.standardizedFileURL.pathComponents
        guard let common = parts.lastIndex(where: { $0.lowercased() == "common" }), common >= 1,
              parts[common - 1].lowercased() == "steamapps", common + 1 < parts.count else { return nil }
        let gameFolder = parts[common + 1]
        let steamapps = URL(fileURLWithPath: NSString.path(withComponents: Array(parts[..<common])), isDirectory: true)
        guard let entries = try? fileManager.contentsOfDirectory(atPath: steamapps.path) else { return nil }
        for entry in entries where entry.hasPrefix("appmanifest_") && entry.hasSuffix(".acf") {
            guard let text = try? String(contentsOf: steamapps.appendingPathComponent(entry), encoding: .utf8),
                  installDir(inManifest: text)?.caseInsensitiveCompare(gameFolder) == .orderedSame else { continue }
            return digits(String(entry.dropFirst("appmanifest_".count).dropLast(".acf".count)))
        }
        return nil
    }

    static func digits(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty && trimmed.count <= 12 && trimmed.allSatisfy(\.isNumber) ? trimmed : nil
    }

    /// The value of `"installdir"` in an app manifest.
    static func installDir(inManifest text: String) -> String? {
        for line in text.split(whereSeparator: \.isNewline) {
            let fields = line.split(separator: "\"", omittingEmptySubsequences: false)
            // <tabs>"installdir"<tabs>"<value>"
            if fields.count >= 5, fields[1].lowercased() == "installdir" { return String(fields[3]) }
        }
        return nil
    }
}
