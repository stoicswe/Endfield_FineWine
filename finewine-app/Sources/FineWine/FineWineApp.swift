import SwiftUI
import AppKit
import FineWineCore

@main
struct FineWineApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model = AppModel.shared

    var body: some Scene {
        // FineWine lives in the menu bar; the window below is opened from it when needed.
        MenuBarExtra {
            MenuBarView().environmentObject(model)
        } label: {
            MenuBarLabel().environmentObject(model)
        }
        .menuBarExtraStyle(.window)

        Window("FineWine", id: "main") {
            MainWindow().environmentObject(model)
        }
        .defaultSize(width: 980, height: 680)
        .windowToolbarStyle(.unified)

        Settings {
            SettingsView().environmentObject(model)
        }
    }
}

/// The menu bar icon. It is the one view that exists for the app's whole life, so it also gives
/// the model a way to open the main window.
struct MenuBarLabel: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        icon
            .accessibilityLabel("FineWine")
            .onAppear {
                model.openMainWindow = {
                    openWindow(id: "main")
                    NSApp.activate()
                }
                // First run: nothing to launch yet, so start in the manager.
                if model.prefixes.isEmpty { model.openMainWindow() }
            }
    }
}

extension MenuBarLabel {
    /// The wine glass from the app's resources, drawn as a template so the menu bar colours it
    /// for light, dark and tinted bars. Falls back to a system symbol when the app is run
    /// outside its bundle (`swift run`).
    static let glass: NSImage? = {
        guard let url = Bundle.main.url(forResource: "MenuBarIcon", withExtension: "svg"),
              let image = NSImage(contentsOf: url), image.size.height > 0 else { return nil }
        let height: CGFloat = 18
        image.size = NSSize(width: (image.size.width / image.size.height * height).rounded(), height: height)
        image.isTemplate = true
        return image
    }()

    @ViewBuilder var icon: some View {
        if let glass = Self.glass {
            Image(nsImage: glass)
        } else {
            Image(systemName: "wineglass")
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func application(_ application: NSApplication, open urls: [URL]) {
        Task { @MainActor in
            for url in urls {
                // Files come from Finder ("Open With", or a double-click once FineWine is the
                // default app for them); finewine:// links come from shortcut apps.
                if url.isFileURL { AppModel.shared.open(executable: url) } else { AppModel.shared.handle(url) }
            }
        }
    }

    // Closing the manager window leaves FineWine running in the menu bar.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}
