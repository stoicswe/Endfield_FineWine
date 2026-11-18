import Foundation

/// Moving prefixes between this Mac and drives, and snapshots: the parts that need Wine
/// stopped and shortcuts kept right.
extension PrefixService {
    /// A prefix's files can only be copied whole while nothing in it runs: Wine keeps the
    /// registry in memory and writes it out when the prefix shuts down. Programs that are
    /// still open stop the work; Wine's own background processes, which linger a few seconds
    /// after the last program closes, are ended.
    func prepareForCopy(_ prefix: Prefix) throws {
        let names = runningProgramNames(in: prefix)
        guard names.isEmpty else {
            throw FineWineError(tr("move.err_running", prefix.name, names.joined(separator: ", ")))
        }
        if let plan = try? planner(for: prefix).killPlan() { _ = try? runner.run(plan) }
        var waited = 0
        while !findProcesses(prefix.directory).isEmpty, waited < 30 {
            Thread.sleep(forTimeInterval: 0.1)
            waited += 1
        }
        guard findProcesses(prefix.directory).isEmpty else {
            throw FineWineError(tr("move.err_running", prefix.name, "Wine"))
        }
    }

    public func movePrefix(_ prefix: Prefix, to place: PrefixPlace, progress: CopyProgress = CopyProgress()) throws -> Prefix {
        try prepareForCopy(prefix)
        return try prefixes.move(prefix, to: place, progress: progress)
    }

    public func takeSnapshot(of prefix: Prefix, note: String = "", on place: PrefixPlace? = nil,
                             progress: CopyProgress = CopyProgress()) throws -> PrefixSnapshot {
        try prepareForCopy(prefix)
        return try prefixes.takeSnapshot(of: prefix, note: note, on: place, progress: progress)
    }

    /// Puts the prefix back the way the snapshot has it. With `keepingCurrent`, the prefix as
    /// it is now is saved as a snapshot first (next to the one restored), so the restore can be
    /// undone. Shortcut apps follow the programs: a program that comes back keeps its shortcut,
    /// and the shortcut of one that is gone is removed.
    public func restoreSnapshot(_ snapshot: PrefixSnapshot, over prefix: Prefix, keepingCurrent: Bool,
                                progress: CopyProgress = CopyProgress(),
                                stage: (@Sendable (String) -> Void)? = nil) throws -> (prefix: Prefix, kept: PrefixSnapshot?) {
        try prepareForCopy(prefix)
        var kept: PrefixSnapshot?
        if keepingCurrent {
            stage?(tr("snapshot.stage_keeping"))
            let place = prefixes.snapshotsFolder(for: snapshot.place) == nil ? prefix.place : snapshot.place
            kept = try prefixes.takeSnapshot(of: prefix, note: tr("snapshot.note_before_restore"), on: place,
                                             progress: CopyProgress())
        }
        stage?(tr("snapshot.stage_restoring"))
        var restored = try prefixes.restore(snapshot, over: prefix, progress: progress)
        let programIDs = Set(restored.metadata.programs.map(\.id))
        var shortcutOf: [UUID: String] = [:]
        for shortcut in shortcuts.list() where shortcut.prefixID == prefix.id {
            if programIDs.contains(shortcut.programID) {
                shortcutOf[shortcut.programID] = shortcut.url.path
            } else {
                try? shortcuts.remove(programID: shortcut.programID)
            }
        }
        for index in restored.metadata.programs.indices {
            restored.metadata.programs[index].shortcutPath = shortcutOf[restored.metadata.programs[index].id]
        }
        try prefixes.save(restored)
        return (restored, kept)
    }
}
