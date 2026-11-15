import Foundation

/// Where FineWine keeps its data. Everything hangs off one root so tests can point it at a
/// temporary directory.
public struct FineWinePaths: Equatable, Sendable {
    public let root: URL
    /// Where generated shortcut apps go.
    public let shortcuts: URL

    public init(root: URL, shortcuts: URL) {
        self.root = root
        self.shortcuts = shortcuts
    }

    /// Environment variable that moves all of FineWine's data under one folder, for development
    /// and testing without touching the real prefixes.
    public static let homeOverrideVariable = "FINEWINE_HOME"

    /// `~/Library/Application Support/FineWine` and `~/Applications/FineWine`, unless
    /// `FINEWINE_HOME` names another place.
    public static func standard(environment: [String: String] = ProcessInfo.processInfo.environment,
                                home: URL = FileManager.default.homeDirectoryForCurrentUser) -> FineWinePaths {
        if let override = environment[homeOverrideVariable], override.hasPrefix("/") {
            let base = URL(fileURLWithPath: override, isDirectory: true)
            return FineWinePaths(root: base.appendingPathComponent("Support", isDirectory: true),
                                 shortcuts: base.appendingPathComponent("Shortcuts", isDirectory: true))
        }
        return FineWinePaths(
            root: home.appendingPathComponent("Library/Application Support/FineWine", isDirectory: true),
            shortcuts: home.appendingPathComponent("Applications/FineWine", isDirectory: true))
    }

    public var prefixes: URL { root.appendingPathComponent("Prefixes", isDirectory: true) }
    public var runtimes: URL { root.appendingPathComponent("Runtimes", isDirectory: true) }
    public var profiles: URL { root.appendingPathComponent("Profiles", isDirectory: true) }
    public var logs: URL { root.appendingPathComponent("Logs", isDirectory: true) }
    /// The list of runtimes that live outside `runtimes` (added by the user from a folder).
    public var externalRuntimes: URL { root.appendingPathComponent("external-runtimes.json") }

    public func ensureDirectories() throws {
        for dir in [root, prefixes, runtimes, profiles, logs] {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
    }
}

public struct FineWineError: LocalizedError, Equatable {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}
