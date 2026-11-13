import SwiftUI

@main
struct FineWinePatcherApp: App {
    // One engine shared by both windows, so the Mod Framework window sees the patched app
    // as soon as the main window's patch completes (and vice versa's running states).
    @StateObject private var engine = PatcherEngine()
    // Automated Setup (bottle creation + installer) lives at app scope so closing the wizard
    // never kills a bottle that is being created or an installer that is still running.
    @StateObject private var setup = SetupEngine()
    @StateObject private var l10n = LanguageManager.shared

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(engine)
                .environmentObject(setup)
                .environmentObject(l10n)
        }
        .windowResizability(.contentSize)
        .windowStyle(.hiddenTitleBar)
        .commands { PatcherCommands() }

        // The mod framework management lives in its own window, opened from the Tools
        // submenu — never on the main page.
        Window("Mod Framework (EFMI)", id: "mod-framework") {
            ModChainView()
                .environmentObject(engine)
                .environmentObject(l10n)
        }
        .windowResizability(.contentSize)
        .windowStyle(.hiddenTitleBar)

        Window("Steam / NotProton", id: "notproton") {
            NotProtonView()
                .environmentObject(engine)
                .environmentObject(l10n)
        }
        .windowResizability(.contentSize)
        .windowStyle(.hiddenTitleBar)

        Window("Sikarugir Engine", id: "sikarugir") {
            SikarugirView()
                .environmentObject(engine)
                .environmentObject(l10n)
        }
        .windowResizability(.contentSize)
        .windowStyle(.hiddenTitleBar)

        Window("Metal HUD", id: "metal-hud") {
            MetalHUDView()
                .environmentObject(engine)
                .environmentObject(l10n)
        }
        .windowResizability(.contentSize)
        .windowStyle(.hiddenTitleBar)

        Window("Bottle Settings", id: "bottle-settings") {
            BottleSettingsView()
                .environmentObject(engine)
                .environmentObject(l10n)
        }
        .windowResizability(.contentSize)
        .windowStyle(.hiddenTitleBar)
    }
}

/// The app's menu bar. Tools menu items open mod-chain and Steam Play / NotProton windows.
struct PatcherCommands: Commands {
    @Environment(\.openWindow) private var openWindow
    @ObservedObject private var l10n = LanguageManager.shared

    var body: some Commands {
        CommandGroup(replacing: .newItem) {}
        CommandMenu(l10n.tr("menu.tools")) {
            Button(l10n.tr("menu.bottle_settings")) {
                openWindow(id: "bottle-settings")
            }
            Button(l10n.tr("menu.mod_framework")) {
                openWindow(id: "mod-framework")
            }
            Button(l10n.tr("menu.steam_notproton")) {
                openWindow(id: "notproton")
            }
            Button(l10n.tr("menu.sikarugir")) {
                openWindow(id: "sikarugir")
            }
            Button(l10n.tr("menu.metal_hud")) {
                openWindow(id: "metal-hud")
            }
        }
        CommandMenu(l10n.tr("menu.language")) {
            ForEach(AppLanguage.allCases) { lang in
                Button(action: {
                    l10n.selectedLanguage = lang
                }) {
                    HStack {
                        Text(lang.displayName)
                        if l10n.selectedLanguage == lang {
                            Spacer()
                            Text("✓")
                        }
                    }
                }
            }
        }
    }
}
