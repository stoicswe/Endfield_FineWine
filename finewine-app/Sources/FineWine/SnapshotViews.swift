import SwiftUI
import AppKit
import FineWineCore

/// The places a prefix can be moved to, as menu items: this Mac and every plugged-in drive
/// that can hold prefixes, except where it is now.
struct MoveDestinations: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject private var l10n = LanguageManager.shared
    let prefix: Prefix

    var body: some View {
        let here = model.choiceID(prefix.place)
        let choices = model.placeChoices().filter { $0.id != here }
        if choices.isEmpty {
            Text(l10n.tr("move.no_drives"))
        }
        ForEach(choices) { choice in
            Button {
                Task { await model.move(prefix, toChoice: choice.id) }
            } label: {
                Label(choice.freeBytes.map {
                    l10n.tr("move.destination", choice.name, ByteCountFormatter.string(fromByteCount: $0, countStyle: .file))
                } ?? choice.name, systemImage: choice.symbol)
            }
        }
    }
}

/// "Move to" as a button with a menu, for the Details tab.
struct MoveMenu: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject private var l10n = LanguageManager.shared
    let prefix: Prefix

    var body: some View {
        Menu {
            MoveDestinations(prefix: prefix)
        } label: {
            Label(l10n.tr("move.menu"), systemImage: "arrow.right.doc.on.clipboard")
        }
        .menuStyle(.button)
        .fwButton()
        .fixedSize()
        .disabled(model.isRunning(prefix))
        .help(model.isRunning(prefix) ? l10n.tr("move.help_running") : l10n.tr("move.help"))
    }
}

/// A prefix's snapshots, in its Details tab: take one, put the prefix back to one, or make a
/// new prefix from one.
struct SnapshotsCard: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject private var l10n = LanguageManager.shared
    let prefix: Prefix
    @State private var taking = false

    var body: some View {
        let snapshots = model.snapshots(of: prefix)
        Card(title: l10n.tr("snapshot.card"), symbol: "clock.arrow.trianglehead.counterclockwise.rotate.90",
             footnote: l10n.tr("snapshot.card_footnote")) {
            Row(label: l10n.tr("snapshot.take_label"),
                detail: model.isRunning(prefix) ? l10n.tr("snapshot.take_running") : l10n.tr("snapshot.take_detail")) {
                Button(l10n.tr("snapshot.take")) { taking = true }
                    .fwButton()
                    .disabled(model.isRunning(prefix))
            }
            if snapshots.isEmpty {
                Divider()
                Text(l10n.tr("snapshot.none")).foregroundStyle(.secondary).font(.callout)
            }
            ForEach(snapshots) { snapshot in
                Divider()
                SnapshotRow(snapshot: snapshot, prefix: prefix)
            }
        }
        .sheet(isPresented: $taking) { TakeSnapshotSheet(prefix: prefix) }
    }
}

/// One snapshot: when, the note, where it is and how big.
struct SnapshotRow: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject private var l10n = LanguageManager.shared
    let snapshot: PrefixSnapshot
    /// The prefix it would be restored over; nil for a snapshot whose prefix is gone.
    let prefix: Prefix?

    private var detail: String {
        var parts: [String] = []
        if prefix == nil { parts.append(snapshot.prefixName) }
        if !snapshot.note.isEmpty { parts.append(snapshot.note) }
        parts.append(l10n.tr("drive.stored_on", model.placeName(snapshot.place)))
        parts.append(ByteCountFormatter.string(fromByteCount: snapshot.bytes, countStyle: .file))
        return parts.joined(separator: " · ")
    }

    var body: some View {
        Row(label: snapshot.createdAt.formatted(date: .abbreviated, time: .shortened), detail: detail) {
            HStack(spacing: 6) {
                if let prefix {
                    Button(l10n.tr("snapshot.restore")) { Task { await model.restore(snapshot, over: prefix) } }
                        .fwButton()
                        .disabled(model.isRunning(prefix))
                        .help(model.isRunning(prefix) ? l10n.tr("snapshot.take_running") : l10n.tr("snapshot.restore_help"))
                } else {
                    Button(l10n.tr("snapshot.restore_new")) { Task { await model.restoreAsNew(snapshot) } }
                        .fwButton()
                }
                Menu {
                    if prefix != nil {
                        Button(l10n.tr("snapshot.restore_new")) { Task { await model.restoreAsNew(snapshot) } }
                    }
                    Button(l10n.tr("app.show_in_finder")) { NSWorkspace.shared.activateFileViewerSelecting([snapshot.directory]) }
                    Divider()
                    Button(l10n.tr("app.delete"), role: .destructive) { model.deleteSnapshot(snapshot) }
                } label: {
                    Image(systemName: "ellipsis")
                }
                .menuStyle(.button)
                .menuIndicator(.hidden)
                .fwButton()
                .fixedSize()
            }
        }
        .disabled(model.copies[snapshot.id] != nil)
    }
}

/// Takes a snapshot: an optional note, and where to keep it.
struct TakeSnapshotSheet: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject private var l10n = LanguageManager.shared
    @Environment(\.dismiss) private var dismiss
    let prefix: Prefix
    @State private var note = ""
    @State private var choice = ""
    @State private var choices: [PlaceChoice] = []

    private var detail: String {
        if choice == model.choiceID(prefix.place) { return l10n.tr("snapshot.same_drive_detail") }
        return l10n.tr("snapshot.other_drive_detail")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(l10n.tr("snapshot.sheet_title", prefix.name)).font(.title2.weight(.semibold))
            Card(title: l10n.tr("snapshot.note_label"), symbol: "text.bubble") {
                TextField(l10n.tr("snapshot.note_placeholder"), text: $note).textFieldStyle(.roundedBorder)
            }
            Card(title: l10n.tr("snapshot.where_label"), symbol: "externaldrive") {
                Row(label: l10n.tr("drive.label"), detail: detail) {
                    Picker(l10n.tr("drive.label"), selection: $choice) {
                        ForEach(choices) { place in
                            Label(place.freeBytes.map {
                                l10n.tr("move.destination", place.name, ByteCountFormatter.string(fromByteCount: $0, countStyle: .file))
                            } ?? place.name, systemImage: place.symbol).tag(place.id)
                        }
                    }
                    .labelsHidden().fixedSize()
                }
            }
            HStack {
                Spacer()
                Button(l10n.tr("app.cancel")) { dismiss() }
                    .fwButton()
                    .keyboardShortcut(.cancelAction)
                Button(l10n.tr("snapshot.take")) {
                    let note = note, choice = choice
                    dismiss()
                    Task { await model.takeSnapshot(of: prefix, note: note, onChoice: choice) }
                }
                .fwProminentButton()
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(22)
        .frame(width: 460)
        .background { Backdrop() }
        .onAppear {
            choices = model.placeChoices()
            choice = model.choiceID(prefix.place)
        }
    }
}

/// Settings: where snapshots are kept, and the snapshots of prefixes that were deleted.
struct SnapshotsSettingsCard: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject private var l10n = LanguageManager.shared

    var body: some View {
        Card(title: l10n.tr("snapshot.card"), symbol: "clock.arrow.trianglehead.counterclockwise.rotate.90",
             footnote: l10n.tr("snapshot.settings_footnote")) {
            Row(label: l10n.tr("snapshot.on_this_mac"), detail: l10n.tr("snapshot.count", model.snapshots.count)) {
                Button(l10n.tr("app.show_in_finder")) {
                    if let folder = model.service.prefixes.snapshotsFolder(for: .thisMac) {
                        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                        NSWorkspace.shared.activateFileViewerSelecting([folder])
                    }
                }
                .fwButton()
            }
            let orphans = model.orphanedSnapshots
            if !orphans.isEmpty {
                Divider()
                Text(l10n.tr("snapshot.orphans_title")).font(.headline)
                ForEach(orphans) { snapshot in
                    Divider()
                    SnapshotRow(snapshot: snapshot, prefix: nil)
                }
            }
        }
    }
}
