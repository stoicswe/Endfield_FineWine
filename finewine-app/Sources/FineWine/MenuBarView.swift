import SwiftUI
import AppKit
import FineWineCore

/// The panel under the menu bar icon: every prefix with its programs one click away.
struct MenuBarView: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject private var l10n = LanguageManager.shared
    @Environment(\.openSettings) private var openSettings
    @Environment(\.openWindow) private var openWindow
    /// How tall the list of prefixes may get, as the user last set it.
    @AppStorage("MenuPanelListHeight") private var listLimit: Double = 520
    @State private var dragOffset: Double = 0
    @State private var contentHeight: Double = 200

    private static let heightRange: ClosedRange<Double> = 140...900

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            UpdateBanner()
            if let name = model.settingUpPrefixName {
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text(l10n.tr("menu.setting_up_prefix", name)).font(.callout)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .glassCard(padding: 12)
            }
            if model.listedPrefixes.isEmpty {
                Text(model.usableRuntimes.isEmpty
                     ? l10n.tr("menu.empty_no_runtimes")
                     : l10n.tr("menu.empty_has_runtimes"))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .glassCard(padding: 12)
            } else {
                // The list is as tall as its cards up to a height the user sets by dragging the
                // handle below it. (Left to itself a scroll view in this panel takes almost no
                // height at all, and the cards were cut off.)
                ScrollView {
                    FWGlassContainer(spacing: 10) {
                        VStack(spacing: 10) {
                            ForEach(model.listedPrefixes) { prefix in
                                MenuPrefixCard(prefix: prefix)
                            }
                            if model.showsDisconnectedPrefixes, !model.disconnectedPrefixes.isEmpty {
                                VStack(alignment: .leading, spacing: 6) {
                                    Text(l10n.tr("drive.not_connected_section")).font(.caption.weight(.semibold))
                                        .foregroundStyle(.secondary)
                                    ForEach(model.disconnectedPrefixes, id: \.prefix.id) { entry in
                                        HStack(spacing: 8) {
                                            Image(systemName: "externaldrive.badge.xmark").foregroundStyle(.tertiary)
                                            Text(entry.prefix.name).lineLimit(1).foregroundStyle(.secondary)
                                            Spacer()
                                            Text(l10n.tr("drive.connect_to_use", entry.drive.name))
                                                .font(.caption).foregroundStyle(.tertiary).lineLimit(1)
                                        }
                                        .help(l10n.tr("drive.not_connected_msg", entry.prefix.name, entry.drive.name))
                                    }
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .glassCard(padding: 12)
                            }
                        }
                    }
                    .padding(1)
                    .background(GeometryReader { proxy in
                        Color.clear.preference(key: ListHeightKey.self, value: proxy.size.height)
                    })
                }
                .scrollIndicators(.never)
                .onPreferenceChange(ListHeightKey.self) { contentHeight = $0 }
                .frame(height: max(60, min(contentHeight, listLimit + dragOffset)))
                resizeHandle
            }
            footer
        }
        .padding(14)
        .frame(width: 380)
        // the same glows as the windows, so the panel carries the accent too
        .background { Backdrop(opaque: false) }
        .onAppear { model.reload() }
    }

    /// A bar to drag: down for a taller list, up for a shorter one. Only shown when there is
    /// more list than fits, or the list has been made shorter than it could be.
    @ViewBuilder private var resizeHandle: some View {
        if contentHeight > 120 {
            Capsule()
                .fill(.secondary.opacity(0.45))
                .frame(width: 44, height: 5)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 3)
                .contentShape(Rectangle())
                .gesture(DragGesture()
                    .onChanged { value in
                        dragOffset = min(Self.heightRange.upperBound, max(Self.heightRange.lowerBound, listLimit + value.translation.height)) - listLimit
                    }
                    .onEnded { _ in
                        listLimit += dragOffset
                        dragOffset = 0
                    })
                .onHover { inside in if inside { NSCursor.resizeUpDown.push() } else { NSCursor.pop() } }
                .help(l10n.tr("menu.resize_help"))
                .accessibilityLabel(l10n.tr("menu.list_height"))
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "wineglass.fill")
                .font(.title3)
                .foregroundStyle(Look.accent)
            Text("FineWine").font(.headline)
            Spacer()
            if model.runningCount > 0 {
                Pill(text: l10n.tr("app.running_count", model.runningCount), symbol: "play.fill", tint: .green)
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Button {
                model.openMainWindow()
            } label: {
                Label(l10n.tr("menu.manage_prefixes"), systemImage: "square.grid.2x2")
            }
            .fwProminentButton()
            Spacer()
            Button(l10n.tr("menu.donate")) { NSWorkspace.shared.open(Links.wineDonate) }
                .fwButton()
                .help(l10n.tr("menu.donate_help"))
            Menu {
                Button("Bottle Settings…") { openWindow(id: "bottle-settings"); NSApp.activate() }
                Button("Mod Framework (EFMI)…") { openWindow(id: "efmi-tools"); NSApp.activate() }
                Button("Steam / NotProton…") { openWindow(id: "notproton-tools"); NSApp.activate() }
                Button("Metal HUD…") { openWindow(id: "metal-hud"); NSApp.activate() }
            } label: {
                Image(systemName: "wrench.and.screwdriver")
            }
            .menuStyle(.button)
            .fwButton()
            .help("CrossOver tools")
            Button {
                openSettings()
                NSApp.activate()
            } label: {
                Image(systemName: "gearshape")
            }
            .fwButton()
            .help(l10n.tr("menu.settings"))
            Button {
                NSApp.terminate(nil)
            } label: {
                Image(systemName: "power")
            }
            .fwButton()
            .help(l10n.tr("menu.quit_help"))
        }
    }
}

private struct MenuPrefixCard: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject private var l10n = LanguageManager.shared
    let prefix: Prefix

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                VStack(alignment: .leading, spacing: 1) {
                    Text(prefix.name).font(.subheadline.weight(.semibold)).lineLimit(1)
                    Label(model.placeName(prefix.place), systemImage: model.placeSymbol(prefix.place))
                        .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                if let status = model.busy[prefix.id] {
                    Text(status).font(.caption).foregroundStyle(.secondary)
                } else if model.isRunning(prefix) {
                    Menu(l10n.tr("menu.shut_down")) {
                        Button(l10n.tr("menu.shut_down")) { Task { await model.shutDown(prefix) } }
                        Button(l10n.tr("menu.force_shut_down"), role: .destructive) { Task { await model.forceShutDown(prefix) } }
                    }
                    .menuStyle(.button)
                    .fwButton()
                    .controlSize(.small)
                    .fixedSize()
                    .help(l10n.tr("menu.shut_down_help"))
                }
                if model.busy[prefix.id] == nil, model.isRunning(prefix),
                   model.runtime(for: prefix)?.supports(.upscaling) ?? true {
                    // MetalFX upscaling, switched while the prefix runs
                    Button {
                        model.toggleUpscaling(prefix)
                    } label: {
                        Image(systemName: model.isUpscalingOn(prefix) ? "sparkles.rectangle.stack.fill" : "sparkles.rectangle.stack")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(model.isUpscalingOn(prefix) ? Color.accentColor : Color.secondary)
                    .help(model.isUpscalingOn(prefix) ? l10n.tr("menu.upscaling_on_help") : l10n.tr("menu.upscaling_off_help"))
                }
                Button {
                    model.show(prefixID: prefix.id, section: "configuration")
                } label: {
                    Image(systemName: "slider.horizontal.3")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help(l10n.tr("menu.configure_prefix"))
            }
            if prefix.metadata.programs.isEmpty {
                Text(l10n.tr("menu.no_programs")).font(.caption).foregroundStyle(.secondary)
            } else {
                ForEach(prefix.metadata.programs) { program in
                    Button {
                        model.launch(program, in: prefix)
                    } label: {
                        HStack(spacing: 8) {
                            ProgramIcon(shortcutPath: program.shortcutPath, size: 22)
                            Text(program.name).lineLimit(1)
                            Spacer()
                            Image(systemName: "play.fill").font(.caption).foregroundStyle(.secondary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(model.busy[prefix.id] != nil)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard(padding: 12)
    }
}

private struct ListHeightKey: PreferenceKey {
    static let defaultValue: Double = 0
    static func reduce(value: inout Double, nextValue: () -> Double) { value = max(value, nextValue()) }
}


/// A line in the menu bar panel while an update is waiting to be installed.
private struct UpdateBanner: View {
    @ObservedObject private var updates = UpdateModel.shared
    @ObservedObject private var l10n = LanguageManager.shared

    var body: some View {
        if updates.phase == .available, let offer = updates.offer {
            Button {
                updates.openUpdateWindow()
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "arrow.down.circle.fill").foregroundStyle(Look.accent)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(l10n.tr("update.banner_title")).font(.callout.weight(.semibold))
                        Text(offer.release.name).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer()
                    Image(systemName: "chevron.forward").font(.caption).foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .glassCard(padding: 12)
        }
    }
}
