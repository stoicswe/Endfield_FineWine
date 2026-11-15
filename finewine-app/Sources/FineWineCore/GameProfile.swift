import Foundation

/// A named set of defaults for one game (or for games in general): the settings a new prefix
/// starts with and the arguments its main executable needs.
public struct GameProfile: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var name: String
    public var summary: String
    public var settings: PrefixSettings
    /// Executable file names this profile's launch arguments apply to (`Endfield.exe`),
    /// compared without regard to case.
    public var executables: [String]
    /// Arguments added when one of `executables` is launched.
    public var launchArguments: [String]
    /// Things the user should know, shown when the profile is chosen.
    public var notes: [String]

    public init(id: String, name: String, summary: String, settings: PrefixSettings = PrefixSettings(),
                executables: [String] = [], launchArguments: [String] = [], notes: [String] = []) {
        self.id = id
        self.name = name
        self.summary = summary
        self.settings = settings
        self.executables = executables
        self.launchArguments = launchArguments
        self.notes = notes
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? id
        summary = try c.decodeIfPresent(String.self, forKey: .summary) ?? ""
        settings = try c.decodeIfPresent(PrefixSettings.self, forKey: .settings) ?? PrefixSettings()
        executables = try c.decodeIfPresent([String].self, forKey: .executables) ?? []
        launchArguments = try c.decodeIfPresent([String].self, forKey: .launchArguments) ?? []
        notes = try c.decodeIfPresent([String].self, forKey: .notes) ?? []
    }

    /// Whether the profile's launch arguments apply to the executable at `windowsPath`.
    public func matches(windowsPath: String) -> Bool {
        let file = WindowsPath.lastComponent(windowsPath).lowercased()
        return executables.contains { $0.lowercased() == file }
    }

    // MARK: Built-in profiles

    public static let generic = GameProfile(
        id: "generic",
        name: "Standard",
        summary: "Windows 11 with DXMT. A sensible start for most programs.")

    public static let endfield: GameProfile = {
        var settings = PrefixSettings()
        settings.windowsVersion = .win11
        settings.windowsBuild = "26100"
        settings.graphicsBackend = .dxmt
        settings.hideHypervisor = true
        return GameProfile(
            id: "arknights-endfield",
            name: "Arknights: Endfield",
            summary: "Windows 11 24H2 (build 26100), DXMT, and the hypervisor flag hidden from the game.",
            settings: settings,
            executables: ["Endfield.exe"],
            launchArguments: ["-force-d3d11"],
            notes: ["Needs a FineWine runtime that includes the Endfield fixes from this project's patches."])
    }()

    public static let builtIn: [GameProfile] = [generic, endfield]
}

/// Built-in profiles plus any JSON profiles the user dropped in the Profiles folder.
public struct ProfileStore {
    public let paths: FineWinePaths
    public init(paths: FineWinePaths) { self.paths = paths }

    /// Built-ins first; a user profile with a built-in's id replaces it.
    public func list() -> [GameProfile] {
        var profiles = GameProfile.builtIn
        let files = ((try? FileManager.default.contentsOfDirectory(at: paths.profiles, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension.lowercased() == "json" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        for file in files {
            guard let data = try? Data(contentsOf: file),
                  let profile = try? JSONDecoder().decode(GameProfile.self, from: data) else { continue }
            if let index = profiles.firstIndex(where: { $0.id == profile.id }) {
                profiles[index] = profile
            } else {
                profiles.append(profile)
            }
        }
        return profiles
    }

    public func profile(id: String?) -> GameProfile? {
        guard let id else { return nil }
        return list().first { $0.id == id }
    }
}
