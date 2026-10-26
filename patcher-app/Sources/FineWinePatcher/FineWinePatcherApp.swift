import SwiftUI

@main
struct FineWinePatcherApp: App {
    // One engine shared by both windows, so the Mod Framework window sees the patched app
    // as soon as the main window's patch completes (and vice versa's running states).
    @StateObject private var engine = PatcherEngine()
    // Automated Setup (bottle creation + installer) lives at app scope so closing the wizard
    // never kills a bottle that is being created or an installer that is still running.
    @StateObject private var setup = SetupEngine()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(engine)
                .environmentObject(setup)
        }
        .windowResizability(.contentSize)
        .commands { PatcherCommands() }

        // The mod framework management lives in its own window, opened from the Tools
        // submenu — never on the main page.
        Window("Mod Framework (EFMI)", id: "mod-framework") {
            ModChainView()
                .environmentObject(engine)
        }
        .windowResizability(.contentSize)

        Window("Steam / NotProton", id: "notproton") {
            NotProtonView()
        }
        .windowResizability(.contentSize)
        
        Window("Metal HUD", id: "metal-hud") {
            MetalHUDView()
                .environmentObject(engine)
        }
        .windowResizability(.contentSize)
    }
}

/// The app's menu bar. Tools menu items open mod-chain and Steam Play / NotProton windows.
/// The app's menu bar. Tools items open the mod-chain and Metal HUD windows.
struct PatcherCommands: Commands {
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(replacing: .newItem) {}
        CommandMenu("Tools") {
            Button("Mod Framework (EFMI)…") {
                openWindow(id: "mod-framework")
            }
            Button("Steam / NotProton…") {
                openWindow(id: "notproton")
            }
            Button("Metal HUD…") {
                openWindow(id: "metal-hud")
            }
        }
    }
}
