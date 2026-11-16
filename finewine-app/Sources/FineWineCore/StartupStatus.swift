import Foundation

/// What the status window says while something slow is going on, worked out here so that it
/// can be tested without a window.
public enum StartupStatus {
    /// True when Wine will bring the prefix up to date the next time a program starts in it,
    /// which it does by itself and which takes a while: the runtime is newer (or other) than
    /// the one the prefix was last set up with. Wine records the modification time of the
    /// runtime's `wine.inf` in the prefix's `.update-timestamp` and compares the two.
    public static func prefixNeedsWineUpdate(prefix: URL, runtimeRoot: URL) -> Bool {
        let stamp = prefix.appendingPathComponent(".update-timestamp")
        guard let recorded = try? String(contentsOf: stamp, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines) else { return false }   // not set up yet
        if recorded == "disable" { return false }
        let inf = runtimeRoot.appendingPathComponent("share/wine/wine.inf")
        guard let modified = (try? FileManager.default.attributesOfItem(atPath: inf.path))?[.modificationDate] as? Date
        else { return false }
        return recorded != String(Int(modified.timeIntervalSince1970))
    }

    /// The line under the title while a program starts. It changes as time passes, so that a
    /// long start reads as work going on and not as a stall.
    public static func launchMessage(elapsed: TimeInterval, updatingPrefix: Bool) -> String {
        if updatingPrefix {
            return elapsed < 45
                ? "Updating the prefix for this version of the runtime…"
                : "Still updating the prefix. This happens once after the runtime changes."
        }
        switch elapsed {
        case ..<4: return "Starting Wine…"
        case ..<15: return "Loading the program…"
        case ..<40: return "Still loading. Large programs take a while to show their window."
        default: return "Still working. You can keep using your Mac; the window will appear by itself."
        }
    }

    /// Elapsed time as the status window shows it: nothing for the first seconds, then
    /// "12 s", then "1 min 5 s".
    public static func elapsedText(_ elapsed: TimeInterval) -> String {
        let seconds = Int(elapsed)
        if seconds < 5 { return "" }
        if seconds < 60 { return "\(seconds) s" }
        return "\(seconds / 60) min \(seconds % 60) s"
    }
}
