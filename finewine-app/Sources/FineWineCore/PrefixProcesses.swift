import Foundation

/// Finds the Mac processes that belong to a prefix, for stopping one that no longer answers.
///
/// Wine's server normally ends a prefix's processes itself. If the server is the one that is
/// stuck, or is gone, FineWine looks for what is left in two ways:
/// - every process of a prefix run by FineWine's runtime keeps the file `.finewine-alive` in
///   the prefix open, and `lsof` lists who has a file open. This is the one that finds
///   programs: Wine replaces a program's arguments with its Windows command line, so `ps`
///   cannot say which prefix a program belongs to.
/// - Wine's server does still show its `WINEPREFIX` to `ps`.
public enum PrefixProcesses {
    /// The process ids in `ps -axww -E -o pid=,command=` output whose environment says they
    /// belong to the prefix at `prefixPath`. A prefix whose path merely starts the same way
    /// (`…/Games` and `…/Games 2`) is not matched.
    public static func pids(inPSOutput output: String, prefixPath: String) -> [Int32] {
        let needle = "WINEPREFIX=" + prefixPath
        var pids: [Int32] = []
        for line in output.split(separator: "\n") {
            let trimmed = line.drop { $0 == " " }
            guard let space = trimmed.firstIndex(of: " "), let pid = Int32(trimmed[..<space]) else { continue }
            var search = trimmed[space...]
            while let range = search.range(of: needle) {
                // What follows must be the end of the value: the end of the line, or the next
                // variable ("NAME="). The path itself may contain spaces.
                let rest = search[range.upperBound...]
                if rest.isEmpty || rest.range(of: #"^ [A-Za-z_][A-Za-z0-9_]*="#, options: .regularExpression) != nil {
                    pids.append(pid)
                    break
                }
                search = rest
            }
        }
        return pids
    }

    /// The name of the file every process of a prefix keeps open (runtime patch 0013).
    public static let aliveMarkerName = ".finewine-alive"

    /// The process ids in `lsof -t <file>` output: one per line.
    public static func pids(inLsofOutput output: String) -> [Int32] {
        output.split(whereSeparator: \.isNewline).compactMap { Int32($0.trimmingCharacters(in: .whitespaces)) }
    }

    private static func output(of tool: String, _ arguments: [String]) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return "" }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }

    /// What `ps` says about every process of this user, environment included.
    public static func systemPSOutput() -> String {
        output(of: "/bin/ps", ["-axww", "-E", "-o", "pid=,command="])
    }

    /// Every process that belongs to the prefix right now, found both ways.
    public static func systemPIDs(prefixDirectory: URL) -> [Int32] {
        var pids: [Int32] = []
        let marker = prefixDirectory.appendingPathComponent(aliveMarkerName).path
        if FileManager.default.fileExists(atPath: marker) {
            pids = self.pids(inLsofOutput: output(of: "/usr/sbin/lsof", ["-t", marker]))
        }
        for pid in self.pids(inPSOutput: systemPSOutput(), prefixPath: prefixDirectory.path) where !pids.contains(pid) {
            pids.append(pid)
        }
        // Never this process: FineWine's own tools are run with the prefix in their environment.
        return pids.filter { $0 != ProcessInfo.processInfo.processIdentifier }
    }
}
