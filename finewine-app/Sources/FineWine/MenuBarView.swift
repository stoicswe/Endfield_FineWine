import SwiftUI
import AppKit
import FineWineCore

/// The panel under the menu bar icon: every prefix with its programs one click away.
struct MenuBarView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            if let name = model.settingUpPrefixName {
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text("Setting up the prefix “\(name)”…").font(.callout)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .glassCard(padding: 12)
            }
            if model.prefixes.isEmpty {
                Text(model.usableRuntimes.isEmpty
                     ? "Add a Wine runtime, then create a prefix to install Windows programs into."
                     : "Create a prefix to install Windows programs into.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .glassCard(padding: 12)
            } else {
                ScrollView {
                    GlassEffectContainer(spacing: 10) {
                        VStack(spacing: 10) {
                            ForEach(model.prefixes) { prefix in
                                MenuPrefixCard(prefix: prefix)
                            }
                        }
                    }
                    .padding(1)
                }
                .scrollIndicators(.never)
                .frame(maxHeight: 420)
            }
            footer
        }
        .padding(14)
        .frame(width: 340)
        .onAppear { model.reload() }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "wineglass.fill")
                .font(.title3)
                .foregroundStyle(Look.wine)
            Text("FineWine").font(.headline)
            Spacer()
            if model.runningCount > 0 {
                Pill(text: "\(model.runningCount) running", symbol: "play.fill", tint: .green)
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Button {
                model.openMainWindow()
            } label: {
                Label("Manage Prefixes", systemImage: "square.grid.2x2")
            }
            .buttonStyle(.glassProminent).tint(Look.wine)
            Spacer()
            Button {
                openSettings()
                NSApp.activate()
            } label: {
                Image(systemName: "gearshape")
            }
            .buttonStyle(.glass)
            .help("Settings")
            Button {
                NSApp.terminate(nil)
            } label: {
                Image(systemName: "power")
            }
            .buttonStyle(.glass)
            .help("Quit FineWine. Programs that are running keep running.")
        }
    }
}

private struct MenuPrefixCard: View {
    @EnvironmentObject private var model: AppModel
    let prefix: Prefix

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(prefix.name).font(.subheadline.weight(.semibold)).lineLimit(1)
                Spacer()
                if let status = model.busy[prefix.id] {
                    Text(status).font(.caption).foregroundStyle(.secondary)
                } else if model.isRunning(prefix) {
                    Menu("Shut Down") {
                        Button("Shut Down") { Task { await model.shutDown(prefix) } }
                        Button("Force Shut Down", role: .destructive) { Task { await model.forceShutDown(prefix) } }
                    }
                    .menuStyle(.button)
                    .buttonStyle(.glass)
                    .controlSize(.small)
                    .fixedSize()
                    .help("Shut Down asks every program to close. Force Shut Down also ends a program that has frozen.")
                }
                Button {
                    model.show(prefixID: prefix.id, section: "configuration")
                } label: {
                    Image(systemName: "slider.horizontal.3")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Configure this prefix")
            }
            if prefix.metadata.programs.isEmpty {
                Text("No programs yet").font(.caption).foregroundStyle(.secondary)
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
