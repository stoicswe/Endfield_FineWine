import Foundation

/// Some games only start when they find the Steam client running; that is how they are run on
/// Linux. The runtime ships a small stand-in for it (`runtime-extras/steam-helper`), and the
/// programs known to need it are started through that.
public enum SteamStandIn {
    /// Where the stand-in is in a runtime, and where it is put in a prefix: where Steam is.
    public static let runtimePath = "share/finewine/steam/steam.exe"
    public static let windowsPath = #"C:\Program Files (x86)\Steam\steam.exe"#

    /// The id given to a program as `SteamGameId` and `SteamAppId`, or nil for a program that
    /// is run as it is. The list is HoYoverse's games and their launcher, the same programs
    /// DWProton starts this way on Linux.
    public static func appID(forWindowsPath path: String) -> String? {
        let parts = path.split(whereSeparator: { $0 == "\\" || $0 == "/" }).map { $0.lowercased() }
        guard let name = parts.last else { return nil }
        switch name {
        case "genshinimpact.exe": return "genshin"
        case "zenlesszonezero.exe", "bh3.exe": return "zenlesszonezero"
        case "launcher.exe":
            // HoYoPlay itself, which starts the games; not a game's own launcher.exe under it.
            return parts.contains("hoyoplay") && !parts.contains("games") ? "zenlesszonezero" : nil
        default: return nil
        }
    }
}
