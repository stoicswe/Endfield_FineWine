import SwiftUI
import AppKit
import FineWineCore

@main
struct FineWineApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model = AppModel.shared
    @StateObject private var l10n = LanguageManager.shared

    var body: some Scene {
        // FineWine lives in the menu bar; the window below is opened from it when needed.
        MenuBarExtra {
            MenuBarView()
                .environmentObject(model)
                .environmentObject(l10n)
                .environment(\.layoutDirection, l10n.layoutDirection)
                .environment(\.locale, Locale(identifier: l10n.activeLanguageCode))
        } label: {
            MenuBarLabel()
                .environmentObject(model)
                .environmentObject(l10n)
                .environment(\.layoutDirection, l10n.layoutDirection)
                .environment(\.locale, Locale(identifier: l10n.activeLanguageCode))
        }
        .menuBarExtraStyle(.window)

        Window("FineWine", id: "main") {
            MainWindow()
                .environmentObject(model)
                .environmentObject(l10n)
                .environment(\.layoutDirection, l10n.layoutDirection)
                .environment(\.locale, Locale(identifier: l10n.activeLanguageCode))
        }
        .defaultSize(width: 980, height: 680)
        .windowToolbarStyle(.unified)
        // SwiftUI shows a window scene whenever the app is handed a file or a link. Opening a
        // Windows program, or a shortcut app's finewine:// link, must not bring the manager up:
        // the delegate handles those, and the manager is opened only when there is a reason.
        .handlesExternalEvents(matching: [])
        .commands {
            FineWineCommands()
        }

        // An update of FineWine itself: what is new, and the download and installation.
        Window(l10n.tr("update.window_title"), id: "update") {
            UpdateWindow()
                .environmentObject(model)
                .environmentObject(l10n)
                .environment(\.layoutDirection, l10n.layoutDirection)
                .environment(\.locale, Locale(identifier: l10n.activeLanguageCode))
        }
        .defaultSize(width: 640, height: 560)
        .windowResizability(.contentMinSize)
        .handlesExternalEvents(matching: [])

        Settings {
            SettingsView()
                .environmentObject(model)
                .environmentObject(l10n)
                .environment(\.layoutDirection, l10n.layoutDirection)
                .environment(\.locale, Locale(identifier: l10n.activeLanguageCode))
        }
    }
}

/// Commands for macOS menu bar (Language switching).
struct FineWineCommands: Commands {
    @ObservedObject private var l10n = LanguageManager.shared

    var body: some Commands {
        CommandGroup(after: .appInfo) {
            Button(l10n.tr("update.check_menu")) {
                Task { await UpdateModel.shared.check(manual: true) }
            }
        }
        CommandMenu(l10n.tr("menu.language")) {
            ForEach(AppLanguage.allCases) { lang in
                Button {
                    l10n.selectedLanguage = lang
                } label: {
                    HStack {
                        Text(lang.displayName)
                        if l10n.selectedLanguage == lang {
                            Spacer()
                            Image(systemName: "checkmark")
                        }
                    }
                }
            }
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
                UpdateModel.shared.openUpdateWindow = {
                    openWindow(id: "update")
                    NSApp.activate()
                }
                UpdateModel.shared.start()
                // First run: nothing to launch yet, so start in the manager. Not when FineWine was
                // started to open a file, though: that file is about to get a prefix by itself,
                // and the manager would only be in the way. The check waits a moment because the
                // file arrives just after launch.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                    if model.prefixes.isEmpty, !model.wasAskedToOpenSomething { model.openMainWindow() }
                }
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
    func applicationWillFinishLaunching(_ notification: Notification) {
        // Started by opening a file or a finewine:// link, as opposed to being started itself.
        if let event = NSAppleEventManager.shared().currentAppleEvent,
           event.eventID == AEEventID(kAEOpenDocuments) || event.eventID == AEEventID(kAEGetURL) {
            MainActor.assumeIsolated { AppModel.shared.wasAskedToOpenSomething = true }
        }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        MainActor.assumeIsolated { AppModel.shared.wasAskedToOpenSomething = true }
        Task { @MainActor in
            for url in urls {
                // Files come from Finder ("Open With", or a double-click once FineWine is the
                // default app for them); finewine:// links come from shortcut apps.
                if url.isFileURL { AppModel.shared.open(executable: url) } else { AppModel.shared.handle(url) }
            }
        }
    }

    // Quitting, however it was asked for (the power button, Command-Q, logging out): if
    // programs are running the user is asked first, and they are closed before FineWine goes.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // The updater has asked already and closed the programs.
        if MainActor.assumeIsolated({ AppModel.shared.quittingForUpdate }) { return .terminateNow }
        Task { @MainActor in
            let quit = await AppModel.shared.confirmQuit()
            sender.reply(toApplicationShouldTerminate: quit)
        }
        return .terminateLater
    }

    // Closing the manager window leaves FineWine running in the menu bar.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}
