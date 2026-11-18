import AppKit
import Foundation
import FineWineCore

/// A place a prefix or snapshot can go: this Mac, a drive FineWine knows that is plugged in,
/// or a plugged-in drive it hasn't used yet (made ready when chosen).
struct PlaceChoice: Identifiable, Hashable {
    /// "" for this Mac, else the volume UUID: the same tags the drive pickers use.
    let id: String
    let name: String
    let symbol: String
    let freeBytes: Int64?
}

extension AppModel {
    // MARK: Places

    /// This Mac, then every plugged-in drive that can hold prefixes, by name.
    func placeChoices() -> [PlaceChoice] {
        let mac = service.prefixes.drives.volumes.volume(containing: service.paths.root)
        var out = [PlaceChoice(id: "", name: tr("drive.this_mac"), symbol: "desktopcomputer", freeBytes: mac?.availableBytes)]
        for entry in candidateVolumes() where entry.problem == nil {
            guard let uuid = entry.volume.uuid else { continue }
            out.append(PlaceChoice(id: uuid, name: entry.volume.name, symbol: "externaldrive",
                                   freeBytes: entry.volume.availableBytes))
        }
        return out
    }

    func choiceID(_ place: PrefixPlace) -> String {
        if case .drive(let uuid) = place { return uuid }
        return ""
    }

    /// The place a choice stands for. A drive not used yet is made ready first
    /// (`FineWine/Prefixes` on it) and remembered. Nil if that fails (the user is told).
    func resolve(_ choiceID: String) -> PrefixPlace? {
        if choiceID.isEmpty { return .thisMac }
        if drives.contains(where: { $0.uuid == choiceID }) { return .drive(choiceID) }
        guard let volume = candidateVolumes().first(where: { $0.volume.uuid == choiceID })?.volume else { return nil }
        return useDrive(volume)
    }

    // MARK: Copies

    /// Runs a long copy off the main thread: the prefix is marked busy with a percentage, the
    /// status window follows it, and the copy can be cancelled (`cancelCopy`). A cancel is not
    /// an error; anything else is shown.
    func copyWork<T: Sendable>(on key: UUID, title: String, _ status: String, failure: String,
                               _ body: @escaping @Sendable (PrefixService, CopyProgress, @escaping @Sendable (String) -> Void) throws -> T) async -> T? {
        let progress = CopyProgress()
        copies[key] = progress
        busy[key] = status
        let token = StatusSplash.shared.show(title: title, message: status)
        let stage = StageBox(status)
        let ticker = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(400))
                guard let self, self.copies[key] != nil else { return }
                let text = Self.progressText(stage.value, progress)
                self.busy[key] = text
                StatusSplash.shared.update(token, message: text)
            }
        }
        defer {
            ticker.cancel()
            copies[key] = nil
            busy[key] = nil
            StatusSplash.shared.hide(token)
        }
        let service = UncheckedBox(service)
        do {
            return try await Task.detached(priority: .userInitiated) {
                try body(service.value, progress) { stage.value = $0 }
            }.value
        } catch let error as FineWineError where error.message == FolderCopy.cancelledMessage {
            return nil
        } catch {
            show(error, title: failure)
            return nil
        }
    }

    static func progressText(_ status: String, _ progress: CopyProgress) -> String {
        let total = progress.totalBytes
        guard total > 0 else { return status }
        let format = { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) }
        return tr("copy.progress", status, Int((progress.fraction * 100).rounded(.down)),
                  format(progress.copiedBytes), format(total))
    }

    /// Stops a copy under way. What was copied so far is removed; the original is untouched.
    func cancelCopy(_ key: UUID) { copies[key]?.cancel() }

    // MARK: Moving

    /// Moves a prefix to this Mac or a drive (see `PlaceChoice`).
    func move(_ prefix: Prefix, toChoice choiceID: String) async {
        guard let place = resolve(choiceID) else { return }
        let destination = placeName(place)
        guard await copyWork(on: prefix.id, title: prefix.name, tr("move.status", destination),
                             failure: tr("move.err_title", prefix.name), { service, progress, _ in
            try service.movePrefix(prefix, to: place, progress: progress)
        }) != nil else { return reload() }
        reload()
        selection = prefix.id
    }

    // MARK: Snapshots

    func snapshots(of prefix: Prefix) -> [PrefixSnapshot] { snapshots.filter { $0.prefixID == prefix.id } }

    /// Snapshots whose prefix is gone (deleted, not just on a drive that is unplugged).
    var orphanedSnapshots: [PrefixSnapshot] {
        let known = Set(prefixes.map(\.id)).union(drives.flatMap(\.prefixes).map(\.id))
        return snapshots.filter { !known.contains($0.prefixID) }
    }

    @discardableResult
    func takeSnapshot(of prefix: Prefix, note: String = "", onChoice choiceID: String? = nil) async -> PrefixSnapshot? {
        var place: PrefixPlace?
        if let choiceID {
            guard let resolved = resolve(choiceID) else { return nil }
            place = resolved
        }
        let destination = place
        let taken = await copyWork(on: prefix.id, title: prefix.name, tr("snapshot.status_taking"),
                                   failure: tr("snapshot.err_take_title"), { service, progress, _ in
            try service.takeSnapshot(of: prefix, note: note, on: destination, progress: progress)
        })
        reload()
        if let taken, let token = StatusSplash.shared.show(title: tr("snapshot.taken_title", prefix.name),
                                                           message: tr("snapshot.taken_msg", placeName(taken.place))) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { StatusSplash.shared.hide(token) }
        }
        return taken
    }

    /// Asks, then puts the prefix back the way the snapshot has it.
    func restore(_ snapshot: PrefixSnapshot, over prefix: Prefix) async {
        guard let keepCurrent = Panels.confirmRestore(prefix: prefix.name, snapshot: snapshot) else { return }
        let restored = await copyWork(on: prefix.id, title: prefix.name, tr("snapshot.stage_restoring"),
                                      failure: tr("snapshot.err_restore_title"), { service, progress, stage in
            try service.restoreSnapshot(snapshot, over: prefix, keepingCurrent: keepCurrent, progress: progress, stage: stage)
        })
        running[prefix.id] = nil
        reload()
        if restored != nil { selection = prefix.id }
    }

    /// Makes a new prefix from a snapshot, named after the snapshot's prefix.
    func restoreAsNew(_ snapshot: PrefixSnapshot) async {
        let taken = Set(prefixes.map { $0.name.lowercased() } + drives.flatMap(\.prefixes).map { $0.name.lowercased() })
        var name = tr("snapshot.restored_name", snapshot.prefixName)
        var counter = 2
        while taken.contains(name.lowercased()) {
            name = tr("snapshot.restored_name", snapshot.prefixName) + " \(counter)"
            counter += 1
        }
        let chosen = name
        let made = await copyWork(on: snapshot.id, title: chosen, tr("snapshot.status_restoring_new"),
                                  failure: tr("snapshot.err_restore_title"), { service, progress, _ in
            try service.prefixes.restoreAsNew(snapshot, name: chosen, progress: progress)
        })
        reload()
        if let made { selection = made.id }
    }

    func deleteSnapshot(_ snapshot: PrefixSnapshot) {
        let described = snapshot.createdAt.formatted(date: .abbreviated, time: .shortened)
        guard Panels.confirm(title: tr("snapshot.delete_confirm_title", described),
                             message: tr("snapshot.delete_confirm_msg"),
                             action: tr("app.delete")) else { return }
        do { try service.prefixes.deleteSnapshot(snapshot) } catch { show(error, title: tr("snapshot.err_delete_title")) }
        reload()
    }
}

/// The step a copy is at, set from the worker thread and read for the status line.
final class StageBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: String
    init(_ value: String) { stored = value }
    var value: String {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}

extension Panels {
    /// Asks before a restore. Nil when cancelled; otherwise whether to snapshot the prefix as
    /// it is now first (on unless unticked).
    @MainActor static func confirmRestore(prefix: String, snapshot: PrefixSnapshot) -> Bool? {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = tr("snapshot.restore_confirm_title", prefix,
                               snapshot.createdAt.formatted(date: .abbreviated, time: .shortened))
        alert.informativeText = tr("snapshot.restore_confirm_msg")
        alert.showsSuppressionButton = true
        alert.suppressionButton?.title = tr("snapshot.keep_current")
        alert.suppressionButton?.state = .on
        alert.addButton(withTitle: tr("snapshot.restore")).hasDestructiveAction = true
        alert.addButton(withTitle: tr("app.cancel"))
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        return alert.suppressionButton?.state == .on
    }
}
