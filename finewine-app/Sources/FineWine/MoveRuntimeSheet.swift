import SwiftUI
import AppKit
import FineWineCore

/// Sheet allowing the user to move an existing runtime to a different disk or custom folder.
struct MoveRuntimeSheet: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject private var l10n = LanguageManager.shared
    @Environment(\.dismiss) private var dismiss

    let runtime: WineRuntime

    @State private var placeChoiceID = ""
    @State private var customFolderURL: URL?
    @State private var isMoving = false
    @State private var errorMessage: String?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            VStack(alignment: .leading, spacing: 18) {
                if let error = errorMessage {
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
                        Text(error).font(.caption).foregroundStyle(.red)
                        Spacer()
                    }
                    .padding(10)
                    .background(Color.red.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
                }

                Card(title: l10n.tr("runtime_move.source_card"), symbol: "cpu") {
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(runtime.name).fontWeight(.medium)
                            Text(runtime.root.path).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                        }
                        Spacer()
                    }
                }

                Card(title: l10n.tr("runtime_move.target_card"), symbol: "externaldrive",
                     footnote: l10n.tr("runtime_move.target_footnote")) {
                    Row(label: l10n.tr("runtime_move.destination_label")) {
                        Picker(l10n.tr("runtime_move.destination_label"), selection: $placeChoiceID) {
                            Label(l10n.tr("drive.this_mac"), systemImage: "desktopcomputer").tag("")
                            ForEach(model.placeChoices().filter { !$0.id.isEmpty }) { choice in
                                Label(choiceText(choice), systemImage: choice.symbol).tag(choice.id)
                            }
                            Label(l10n.tr("runtime_regen.custom_folder"), systemImage: "folder").tag("custom")
                        }
                        .labelsHidden().fixedSize()
                    }

                    if placeChoiceID == "custom" {
                        Divider()
                        Row(label: l10n.tr("runtime_regen.custom_path_label"), detail: customFolderURL?.path ?? l10n.tr("app.none")) {
                            Button(l10n.tr("runtime_regen.choose_folder")) {
                                if let folder = Panels.chooseFolder(message: l10n.tr("runtime_regen.choose_custom_dest")) {
                                    customFolderURL = folder
                                }
                            }
                            .fwButton()
                        }
                    }
                }

                if isMoving {
                    HStack(spacing: 12) {
                        ProgressView().controlSize(.small)
                        Text(l10n.tr("runtime_move.moving_msg"))
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    .padding(.top, 4)
                }
            }
            .padding(20)

            Spacer()
            Divider()
            footer
        }
        .frame(width: 520, height: 420)
        .background { Backdrop() }
        .onAppear {
            setupInitialPlace()
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "shippingbox.and.arrow.backward.fill")
                .font(.system(size: 28))
                .foregroundStyle(Look.accent)
            VStack(alignment: .leading, spacing: 2) {
                Text(l10n.tr("runtime_move.title", runtime.name))
                    .font(.title3.weight(.semibold))
                Text(l10n.tr("runtime_move.subtitle"))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(16)
    }

    private var footer: some View {
        HStack {
            Button(l10n.tr("app.cancel")) { dismiss() }
                .fwButton()
                .disabled(isMoving)
            Spacer()
            Button(l10n.tr("runtime_move.action_button")) { startMoving() }
                .fwProminentButton().tint(Look.accent)
                .disabled(isMoving || (placeChoiceID == "custom" && customFolderURL == nil))
        }
        .padding(16)
    }

    private func choiceText(_ choice: PlaceChoice) -> String {
        guard let bytes = choice.freeBytes else { return choice.name }
        return "\(choice.name) (\(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)) free)"
    }

    private func setupInitialPlace() {
        if runtime.kind == .managed {
            placeChoiceID = ""
        } else if let vol = model.service.prefixes.drives.volumes.volume(containing: runtime.root), let uuid = vol.uuid {
            placeChoiceID = uuid
        } else {
            placeChoiceID = "custom"
            customFolderURL = runtime.root.deletingLastPathComponent()
        }
    }

    private func resolvePlace() -> RuntimePlace? {
        if placeChoiceID.isEmpty { return .thisMac }
        if placeChoiceID == "custom" {
            guard let url = customFolderURL else { return nil }
            return .customFolder(url)
        }
        return .drive(placeChoiceID)
    }

    private func startMoving() {
        guard let place = resolvePlace() else { return }
        isMoving = true
        errorMessage = nil

        Task {
            do {
                _ = try model.service.runtimes.move(
                    runtime: runtime,
                    to: place,
                    volumes: model.service.prefixes.drives.volumes
                )
                await MainActor.run {
                    model.reload()
                    isMoving = false
                    dismiss()
                }
            } catch {
                await MainActor.run {
                    isMoving = false
                    errorMessage = error.localizedDescription
                }
            }
        }
    }
}
