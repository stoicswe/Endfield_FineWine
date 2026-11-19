import Foundation

/// What is running in a prefix, by name, for asking before everything is closed.
public enum RunningPrograms {
    /// The programs among a prefix's processes, named as FineWine lists them where it does and
    /// by file name otherwise. `commands` are the processes' command lines as `ps` shows them:
    /// Wine replaces a program's arguments with its Windows command line. Left out are Wine's
    /// and Windows' own processes, helper processes of browsers-in-a-program (Chromium starts
    /// several per window), crash reporters, and FineWine's Steam stand-in.
    public static func names(commands: [String], programs: [Program]) -> [String] {
        var names: [String] = []
        for command in commands {
            guard let path = windowsProgramPath(in: command) else { continue }
            let lower = path.lowercased()
            if lower.contains("\\windows\\") { continue }
            if command.contains(" --type=") { continue }
            let file = path.split(separator: "\\").last.map(String.init) ?? path
            let stem = String(file.dropLast(4))
            if lower.hasSuffix("\\steam\\steam.exe") || stem.lowercased().contains("crashhandler") { continue }
            // A listed program is recognised by its file. A game that only a launcher can start
            // is listed with the launcher's file, so it is also recognised by its folder: the
            // innermost folder on the path that is named like a listed program
            // (…\games\Arknights Endfield\Endfield.exe is "Arknights Endfield").
            let listed = programs.first { normalized($0.windowsPath) == lower }?.name
                ?? path.split(separator: "\\").dropLast().reversed().lazy
                    .compactMap { folder in programs.first { folded($0.name) == folded(String(folder)) }?.name }.first
            let name = listed ?? stem
            if !names.contains(name) { names.append(name) }
        }
        return names
    }

    /// The path of the program a command line starts with, with backslashes: a Windows path
    /// (`C:\…\Game.exe`), or a Mac one for a program started from a file outside the prefix
    /// (`/Users/…/setup.exe`), which is how Wine shows those. Nil when the command is not a
    /// Windows program.
    static func windowsProgramPath(in command: String) -> String? {
        let trimmed = command.trimmingCharacters(in: .whitespaces)
        let characters = Array(trimmed.prefix(3))
        let isDrivePath = characters.count == 3 && characters[0].isLetter && characters[1] == ":"
            && (characters[2] == "\\" || characters[2] == "/")
        guard isDrivePath || trimmed.hasPrefix("/"),
              let end = trimmed.range(of: ".exe", options: .caseInsensitive) else { return nil }
        return trimmed[..<end.upperBound].replacingOccurrences(of: "/", with: "\\")
    }

    /// A name as it is compared with a folder's: letters and digits only, in lower case.
    private static func folded(_ name: String) -> String {
        String(name.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) })
    }

    private static func normalized(_ path: String) -> String {
        path.replacingOccurrences(of: "/", with: "\\").lowercased()
    }

    /// What `ps` shows as the command line of each process.
    public static func systemCommands(of pids: [Int32]) -> [String] {
        guard !pids.isEmpty else { return [] }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-ww", "-o", "command=", "-p", pids.map(String.init).joined(separator: ",")]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return [] }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self).split(whereSeparator: \.isNewline).map(String.init)
    }
}
