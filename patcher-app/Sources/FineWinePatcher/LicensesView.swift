import SwiftUI
import AppKit

struct LicenseLink: Hashable {
    let label: String
    let url: String
}

struct LicenseComponent: Identifiable, Hashable {
    let id: String
    let name: String
    let license: String
    let summary: String
    let notice: String?
    let textFile: String
    let links: [LicenseLink]

    static let all: [LicenseComponent] = [
        LicenseComponent(
            id: "finewine-patcher",
            name: "FineWine Patcher",
            license: "MIT",
            summary: "This application — the interface and patching logic.",
            notice: "Copyright © 2026 Endfield_FineWine contributors.",
            textFile: "mit-finewine-patcher.txt",
            links: [
                LicenseLink(label: "Project repository", url: "https://github.com/stoicswe/Endfield_FineWine"),
            ]
        ),
        LicenseComponent(
            id: "crossover-wine-modules",
            name: "CrossOver Wine — patched modules",
            license: "LGPL-2.1-or-later",
            summary: "The pre-built Wine modules bundled inside this app and installed into your CrossOver copy: ntdll.so, kernel32.dll and ntoskrnl.exe. They are built from CodeWeavers' freely published CrossOver 26.2 Wine source with this project's patches applied.",
            notice: "Wine — Copyright © the Wine project authors. CrossOver Wine modifications — Copyright © CodeWeavers, Inc. Endfield patches — Copyright © Endfield_FineWine contributors and the dw-proton authors. The complete corresponding source is available at the links below.",
            textFile: "lgpl-2.1.txt",
            links: [
                LicenseLink(label: "Complete corresponding source (patches + build scripts)", url: "https://github.com/stoicswe/Endfield_FineWine"),
                LicenseLink(label: "CodeWeavers FOSS source for CrossOver", url: "https://www.codeweavers.com/crossover/source"),
                LicenseLink(label: "CrossOver source archive", url: "https://media.codeweavers.com/pub/crossover/source/"),
                LicenseLink(label: "Wine project", url: "https://www.winehq.org/"),
            ]
        ),
        LicenseComponent(
            id: "dwproton-patches",
            name: "dw-proton patches",
            license: "LGPL-2.1-or-later",
            summary: "The anti-cheat compatibility patches ported from the Linux dw-proton (Dawn Winery) project. They are part of the bundled Wine modules above.",
            notice: "Authors: Etaash Mathamsetty, Ziia Shi (mkrsym1), NelloKudo, and other dw-proton contributors.",
            textFile: "lgpl-2.1.txt",
            links: [
                LicenseLink(label: "dw-proton / Dawn Winery", url: "https://dawn.wine/"),
            ]
        ),
    ]
}

struct LicensesView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var selection: LicenseComponent.ID?

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                List(LicenseComponent.all, selection: $selection) { component in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(component.name)
                            .lineLimit(2)
                        Text(component.license)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 2)
                }
                .listStyle(.inset)
                .frame(width: 220)
                Divider()
                detail
            }
            Divider()
            HStack {
                Text("The bundled Wine modules are LGPL — you may rebuild or replace them; sources are linked above.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(12)
        }
        .frame(width: 700, height: 480)
        .onAppear {
            if selection == nil { selection = LicenseComponent.all.first?.id }
        }
    }

    @ViewBuilder
    private var detail: some View {
        if let component = LicenseComponent.all.first(where: { $0.id == selection }) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline) {
                    Text(component.name).font(.headline)
                    Spacer()
                    Text(component.license)
                        .font(.caption.weight(.medium))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.quaternary, in: Capsule())
                }
                Text(component.summary)
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                if let notice = component.notice {
                    Text(notice)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(component.links, id: \.self) { link in
                        if let url = URL(string: link.url) {
                            Link(link.label, destination: url)
                                .font(.caption)
                        }
                    }
                }
                Divider()
                ScrollView {
                    Text(licenseText(for: component))
                        .font(.system(size: 11, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(14)
        } else {
            Text("Select a component")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func licenseText(for component: LicenseComponent) -> String {
        guard let resources = Bundle.main.resourceURL else {
            return "License text not found in this build."
        }
        let url = resources
            .appendingPathComponent("licenses", isDirectory: true)
            .appendingPathComponent(component.textFile)
        return (try? String(contentsOf: url, encoding: .utf8))
            ?? "License text (\(component.textFile)) not found in this build — see the links above for the license."
    }
}
