import Foundation

/// One change to a prefix's registry.
public struct RegistryEdit: Equatable, Sendable {
    public enum Action: Equatable, Sendable {
        case setString(String)
        case setDWord(UInt32)
        case setBinary([UInt8])
        case deleteValue
        case deleteKey
    }

    /// Full key path with the long root name, e.g. `HKEY_CURRENT_USER\Software\Wine`.
    public let key: String
    /// The value name; `nil` is the key's default value. Ignored for `.deleteKey`.
    public let name: String?
    public let action: Action

    public init(key: String, name: String?, action: Action) {
        self.key = key
        self.name = name
        self.action = action
    }

    public static func string(_ key: String, _ name: String, _ value: String) -> RegistryEdit {
        RegistryEdit(key: key, name: name, action: .setString(value))
    }
    public static func dword(_ key: String, _ name: String, _ value: UInt32) -> RegistryEdit {
        RegistryEdit(key: key, name: name, action: .setDWord(value))
    }
    public static func binary(_ key: String, _ name: String, _ value: [UInt8]) -> RegistryEdit {
        RegistryEdit(key: key, name: name, action: .setBinary(value))
    }
    public static func delete(_ key: String, _ name: String) -> RegistryEdit {
        RegistryEdit(key: key, name: name, action: .deleteValue)
    }
}

/// Renders edits as a `.reg` file that `regedit /S` imports.
public enum RegistryFile {
    public static let header = "Windows Registry Editor Version 5.00"

    /// The file's text. Edits are grouped by key in first-seen order; a later edit to the same
    /// value wins, as it would if the lines were imported in sequence.
    public static func render(_ edits: [RegistryEdit]) -> String {
        var order: [String] = []
        var groups: [String: [RegistryEdit]] = [:]
        for edit in edits {
            if groups[edit.key] == nil { order.append(edit.key) }
            groups[edit.key, default: []].append(edit)
        }
        var out = header + "\r\n"
        for key in order {
            let group = groups[key] ?? []
            if group.contains(where: { $0.action == .deleteKey }) {
                out += "\r\n[-\(key)]\r\n"
                continue
            }
            out += "\r\n[\(key)]\r\n"
            for edit in group {
                let name = edit.name.map { "\"\(escape($0))\"" } ?? "@"
                switch edit.action {
                case .setString(let value): out += "\(name)=\"\(escape(value))\"\r\n"
                case .setDWord(let value): out += "\(name)=dword:\(String(format: "%08x", value))\r\n"
                case .setBinary(let bytes):
                    out += "\(name)=hex:" + bytes.map { String(format: "%02x", $0) }.joined(separator: ",") + "\r\n"
                case .deleteValue: out += "\(name)=-\r\n"
                case .deleteKey: break
                }
            }
        }
        return out
    }

    /// UTF-16LE with a byte-order mark, which is what regedit expects for a version 5 file and
    /// what keeps non-ASCII values intact.
    public static func data(_ edits: [RegistryEdit]) -> Data {
        var data = Data([0xFF, 0xFE])
        data.append(render(edits).data(using: .utf16LittleEndian) ?? Data())
        return data
    }

    static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }
}

/// Reads the registry files Wine keeps in a prefix (`user.reg`, `system.reg`). Only string and
/// dword values are decoded; that covers every setting FineWine shows.
public struct WineRegistryReader: Sendable {
    public enum Value: Equatable, Sendable {
        case string(String)
        case dword(UInt32)
        case other(String)
    }

    /// Lower-cased key path (single backslashes) → lower-cased value name → value. The default
    /// value is stored under `@`.
    private var keys: [String: [String: Value]] = [:]

    public init(text: String) {
        var current: String?
        for rawLine in text.split(omittingEmptySubsequences: true, whereSeparator: { $0 == "\n" || $0 == "\r\n" }) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") {
                guard let close = line.lastIndex(of: "]") else { current = nil; continue }
                let raw = String(line[line.index(after: line.startIndex)..<close])
                current = Self.unescape(raw).lowercased()
                if keys[current!] == nil { keys[current!] = [:] }
            } else if let key = current, line.hasPrefix("\"") || line.hasPrefix("@") {
                guard let (name, rest) = Self.splitNameValue(line) else { continue }
                keys[key, default: [:]][name.lowercased()] = Self.parseValue(rest)
            }
        }
    }

    public init(contentsOf url: URL) throws {
        let data = try Data(contentsOf: url)
        self.init(text: String(decoding: data, as: UTF8.self))
    }

    /// `key` is relative to the hive the file holds, e.g. `Software\Wine\DllOverrides`.
    public func value(key: String, name: String?) -> Value? {
        keys[key.lowercased()]?[(name ?? "@").lowercased()]
    }

    public func string(key: String, name: String?) -> String? {
        if case .string(let s) = value(key: key, name: name) { return s }
        return nil
    }

    public func dword(key: String, name: String?) -> UInt32? {
        if case .dword(let d) = value(key: key, name: name) { return d }
        return nil
    }

    /// Every value under `key`, with names as stored (lower-cased).
    public func values(key: String) -> [String: Value] {
        keys[key.lowercased()] ?? [:]
    }

    public func hasKey(_ key: String) -> Bool { keys[key.lowercased()] != nil }

    private static func splitNameValue(_ line: String) -> (String, String)? {
        if line.hasPrefix("@=") { return ("@", String(line.dropFirst(2))) }
        // Find the closing quote of the name, skipping escaped characters.
        var index = line.index(after: line.startIndex)
        var name = ""
        while index < line.endIndex {
            let ch = line[index]
            if ch == "\\" {
                let next = line.index(after: index)
                guard next < line.endIndex else { return nil }
                name.append(line[next])
                index = line.index(after: next)
                continue
            }
            if ch == "\"" { break }
            name.append(ch)
            index = line.index(after: index)
        }
        guard index < line.endIndex else { return nil }
        let afterQuote = line.index(after: index)
        guard afterQuote < line.endIndex, line[afterQuote] == "=" else { return nil }
        return (name, String(line[line.index(after: afterQuote)...]))
    }

    private static func parseValue(_ text: String) -> Value {
        if text.hasPrefix("\""), text.count >= 2, text.hasSuffix("\"") {
            return .string(unescape(String(text.dropFirst().dropLast())))
        }
        if text.lowercased().hasPrefix("dword:"), let number = UInt32(text.dropFirst(6), radix: 16) {
            return .dword(number)
        }
        return .other(text)
    }

    private static func unescape(_ text: String) -> String {
        var out = ""
        var iterator = text.makeIterator()
        while let ch = iterator.next() {
            if ch == "\\", let next = iterator.next() {
                out.append(next == "n" ? "\n" : next)
            } else {
                out.append(ch)
            }
        }
        return out
    }
}
