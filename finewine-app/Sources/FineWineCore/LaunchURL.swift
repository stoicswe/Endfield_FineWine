import Foundation

/// The `finewine://` links shortcut apps use to ask the running FineWine to do something.
public enum LaunchURL: Equatable, Sendable {
    /// Start a program in a prefix.
    case launch(prefix: UUID, program: UUID)
    /// Show a prefix in the FineWine window, optionally on one of its sections
    /// (`programs`, `configuration`, `tools`, `details`).
    case show(prefix: UUID, section: String? = nil)

    public static let scheme = "finewine"

    public init?(url: URL) {
        guard url.scheme?.lowercased() == Self.scheme,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        var query: [String: String] = [:]
        for item in components.queryItems ?? [] where query[item.name] == nil {
            query[item.name] = item.value
        }
        guard let prefix = query["prefix"].flatMap(UUID.init(uuidString:)) else { return nil }
        switch components.host?.lowercased() {
        case "launch":
            guard let program = query["program"].flatMap(UUID.init(uuidString:)) else { return nil }
            self = .launch(prefix: prefix, program: program)
        case "show":
            // Only plain lowercase words get through; anything else is dropped rather than trusted.
            let section = query["section"].flatMap { $0.allSatisfy { $0.isASCII && $0.isLowercase } && !$0.isEmpty ? $0 : nil }
            self = .show(prefix: prefix, section: section)
        default:
            return nil
        }
    }

    public var url: URL {
        var components = URLComponents()
        components.scheme = Self.scheme
        switch self {
        case .launch(let prefix, let program):
            components.host = "launch"
            components.queryItems = [URLQueryItem(name: "prefix", value: prefix.uuidString),
                                     URLQueryItem(name: "program", value: program.uuidString)]
        case .show(let prefix, let section):
            components.host = "show"
            components.queryItems = [URLQueryItem(name: "prefix", value: prefix.uuidString)]
                + (section.map { [URLQueryItem(name: "section", value: $0)] } ?? [])
        }
        return components.url!
    }
}
