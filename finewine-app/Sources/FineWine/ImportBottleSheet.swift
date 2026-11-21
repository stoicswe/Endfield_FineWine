import SwiftUI
import FineWineCore

/// Picks a CrossOver bottle and makes a FineWine prefix from a copy of it.
struct ImportBottleSheet: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject private var l10n = LanguageManager.shared
    @Environment(\.dismiss) private var dismiss
    @State private var bottles: [CrossOverBottle] = []
    @State private var selected: String?
    @State private var name = ""
    @State private var placeChoice = ""
    @State private var places: [PlaceChoice] = []
    @State private var sizes: [String: Int64] = [:]
    /// The key the import runs under, while it runs (its progress is `model.busy[key]`).
    @State private var importing: UUID?

    private var bottle: CrossOverBottle? { bottles.first { $0.id == selected } }
    private var runtime: WineRuntime? { model.usableRuntimes.first }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(l10n.tr("bottle.sheet_title")).font(.title2.weight(.semibold))
            Text(l10n.tr("bottle.sheet_desc"))
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Card(title: l10n.tr("bottle.card_title"), symbol: "shippingbox") {
                if bottles.isEmpty {
                    Label(l10n.tr("bottle.none_found"), systemImage: "info.circle").foregroundStyle(.secondary)
                }
                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(bottles) { bottle in row(bottle) }
                    }
                }
                .frame(maxHeight: 180)
                Button(l10n.tr("bottle.choose_other")) { chooseOther() }
                    .fwButton().controlSize(.small)
            }

            Card(title: l10n.tr("sheet.name_title"), symbol: "textformat") {
                TextField(l10n.tr("sheet.name_placeholder"), text: $name)
                    .textFieldStyle(.roundedBorder)
                Divider()
                Row(label: l10n.tr("drive.label")) {
                    Picker(l10n.tr("drive.label"), selection: $placeChoice) {
                        ForEach(places) { Label($0.name, systemImage: $0.symbol).tag($0.id) }
                    }
                    .labelsHidden().fixedSize()
                }
            }

            HStack {
                if let importing {
                    ProgressView().controlSize(.small)
                    Text(model.busy[importing] ?? "").foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                Button(l10n.tr("app.cancel")) {
                    if let importing { model.cancelCopy(importing) } else { dismiss() }
                }
                .fwButton()
                .keyboardShortcut(.cancelAction)
                Button(l10n.tr("bottle.import")) { start() }
                    .fwProminentButton()
                    .keyboardShortcut(.defaultAction)
                    .disabled(bottle?.is64Bit != true || runtime == nil || importing != nil
                              || name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(22)
        .frame(width: 500)
        .background { Backdrop() }
        .interactiveDismissDisabled(importing != nil)
        .onAppear {
            places = model.placeChoices()
            placeChoice = model.choiceID(model.preferredPlace)
            if !places.contains(where: { $0.id == placeChoice }) { placeChoice = "" }
            bottles = CrossOverBottle.list()
            select(bottles.first { $0.is64Bit })
            measure(bottles)
        }
    }

    private func row(_ bottle: CrossOverBottle) -> some View {
        Button {
            select(bottle)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: selected == bottle.id ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(selected == bottle.id ? Look.accent : Color.secondary)
                VStack(alignment: .leading, spacing: 1) {
                    Text(bottle.name).lineLimit(1)
                    Text(bottle.is64Bit ? bottle.directory.deletingLastPathComponent().path : l10n.tr("bottle.note_32bit"))
                        .font(.caption).foregroundStyle(bottle.is64Bit ? Color.secondary : Color.orange)
                        .lineLimit(1).truncationMode(.middle)
                }
                Spacer()
                if let size = sizes[bottle.id] {
                    Text(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))
                        .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!bottle.is64Bit || importing != nil)
    }

    private func select(_ bottle: CrossOverBottle?) {
        guard let bottle else { return }
        // The name follows the bottle until the user has typed one of their own.
        if name.isEmpty || name == self.bottle?.name { name = bottle.name }
        selected = bottle.id
    }

    private func chooseOther() {
        guard let folder = Panels.chooseFolder(message: l10n.tr("bottle.choose_msg")) else { return }
        if let bottle = CrossOverBottle.read(folder) {
            if !bottles.contains(where: { $0.id == bottle.id }) { bottles.append(bottle) }
            select(bottle)
            measure([bottle])
        } else {
            // a folder of bottles works too
            let found = CrossOverBottle.list(in: [folder]).filter { new in !bottles.contains { $0.id == new.id } }
            guard !found.isEmpty else {
                model.alert = AppAlert(title: l10n.tr("bottle.err_title"), message: l10n.tr("bottle.not_a_bottle", folder.lastPathComponent))
                return
            }
            bottles += found
            select(found.first { $0.is64Bit })
            measure(found)
        }
    }

    private func measure(_ bottles: [CrossOverBottle]) {
        for bottle in bottles {
            Task.detached(priority: .utility) {
                let bytes = FolderCopy.measure(bottle.driveC).allocated
                await MainActor.run { sizes[bottle.id] = bytes }
            }
        }
    }

    private func start() {
        guard let bottle, let runtime, let place = model.resolve(placeChoice) else { return }
        let key = UUID()
        importing = key
        Task {
            let done = await model.importBottle(bottle, name: name, runtime: runtime, place: place, key: key)
            importing = nil
            if done { dismiss() }
        }
    }
}
