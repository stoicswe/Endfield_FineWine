import Foundation
import FineWineCore

/// What `FineWine --steam-run` does: one game, started for the Mac Steam client. Everything it
/// does is written to `Logs/steam-tool.log` in FineWine's folder, since nothing is on screen.
enum SteamRunCommand {
    static func run(_ arguments: [String]) -> Int32 {
        let service = PrefixService(paths: .standard())
        let logFile = service.paths.logs.appendingPathComponent("steam-tool.log")
        try? FileManager.default.createDirectory(at: service.paths.logs, withIntermediateDirectories: true)
        let log: @Sendable (String) -> Void = { line in
            let stamp = ISO8601DateFormatter().string(from: Date())
            guard let data = "\(stamp) \(line)\n".data(using: .utf8) else { return }
            if let handle = try? FileHandle(forWritingTo: logFile) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
            } else {
                try? data.write(to: logFile)
            }
        }
        do {
            guard let request = try SteamRun.parse(arguments: arguments, environment: ProcessInfo.processInfo.environment) else {
                log("nothing to start for: \(arguments.joined(separator: " "))")
                return 0
            }
            return try service.runForSteam(request, log: log)
        } catch {
            log("failed: \(error.localizedDescription)")
            tell(error.localizedDescription)
            return 1
        }
    }

    /// Steam shows nothing when a tool fails, so the reason is put on screen.
    private static func tell(_ message: String) {
        let script = Process()
        script.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        let quoted = { (text: String) in "\"" + text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\"" }
        script.arguments = ["-e", "display alert \(quoted(tr("steam.alert_title"))) message \(quoted(message))"]
        script.standardOutput = FileHandle.nullDevice
        script.standardError = FileHandle.nullDevice
        try? script.run()
    }
}
