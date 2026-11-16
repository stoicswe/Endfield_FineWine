import SwiftUI
import AppKit
import Darwin
import FineWineCore

/// A small status window in the middle of the display, shown while FineWine is doing
/// something that takes a while and has no window of its own yet: setting a prefix up,
/// changing one, starting a program. It says what is going on and how long it has been, so a
/// slow start does not look like a stall. It takes no focus and goes away by itself; a click
/// dismisses it early.
@MainActor
final class StatusSplash: ObservableObject {
    static let shared = StatusSplash()

    struct Item: Identifiable {
        let id = UUID()
        var title: String
        var message: String
        var icon: NSImage?
        var started = Date()
        /// For a starting program: the Wine windows that were already on screen, and whether
        /// the prefix is being brought up to date first.
        var launch: (baseline: Set<CGWindowID>, updatingPrefix: Bool)?
    }

    private static let enabledKey = "ShowStatusWindow"

    /// The user's choice, in the app's settings. On unless turned off.
    var isEnabled: Bool {
        get { UserDefaults.standard.object(forKey: Self.enabledKey) as? Bool ?? true }
        set {
            objectWillChange.send()
            UserDefaults.standard.set(newValue, forKey: Self.enabledKey)
            if !newValue { items.removeAll(); refresh() }
        }
    }

    /// What is going on, oldest first. The newest is what the window shows.
    @Published private(set) var items: [Item] = []
    @Published private(set) var now = Date()

    var current: Item? { items.last }

    private var panel: NSPanel?
    private var timer: Timer?

    /// A program that has not shown a window after this long is no longer waited for.
    private static let launchTimeout: TimeInterval = 180
    /// A status that came and went at once would only flicker.
    private static let minimumVisible: TimeInterval = 0.8

    // MARK: Showing and hiding

    /// Shows a status until `hide` is called with the token returned.
    @discardableResult
    func show(title: String, message: String, icon: NSImage? = nil) -> UUID? {
        guard isEnabled else { return nil }
        let item = Item(title: title, message: message, icon: icon)
        items.append(item)
        refresh()
        return item.id
    }

    /// Shows a status for a program that is starting. It goes away when a new Wine window
    /// comes on screen, when `hide` is called (the program ended), or after a few minutes.
    @discardableResult
    func showLaunch(title: String, icon: NSImage? = nil, updatingPrefix: Bool) -> UUID? {
        guard isEnabled else { return nil }
        var item = Item(title: title,
                        message: StartupStatus.launchMessage(elapsed: 0, updatingPrefix: updatingPrefix), icon: icon)
        item.launch = (Self.wineWindows(), updatingPrefix)
        items.append(item)
        refresh()
        return item.id
    }

    func update(_ token: UUID?, message: String) {
        guard let token, let index = items.firstIndex(where: { $0.id == token }) else { return }
        items[index].message = message
    }

    func retitle(_ token: UUID?, _ title: String) {
        guard let token, let index = items.firstIndex(where: { $0.id == token }) else { return }
        items[index].title = title
    }

    func hide(_ token: UUID?) {
        guard let token, let item = items.first(where: { $0.id == token }) else { return }
        let shownFor = Date().timeIntervalSince(item.started)
        if shownFor < Self.minimumVisible {
            DispatchQueue.main.asyncAfter(deadline: .now() + (Self.minimumVisible - shownFor)) { [weak self] in
                self?.remove(token)
            }
        } else {
            remove(token)
        }
    }

    /// A click on the window: everything shown is dismissed. The work carries on.
    func dismissAll() {
        items.removeAll()
        refresh()
    }

    private func remove(_ token: UUID) {
        items.removeAll { $0.id == token }
        refresh()
    }

    // MARK: The window

    private func refresh() {
        if items.isEmpty {
            timer?.invalidate()
            timer = nil
            panel?.orderOut(nil)
            return
        }
        if timer == nil {
            let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.tick() }
            }
            RunLoop.main.add(timer, forMode: .common)
            self.timer = timer
        }
        let panel = self.panel ?? makePanel()
        self.panel = panel
        if !panel.isVisible {
            place(panel)
            panel.orderFrontRegardless()
        }
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 380, height: 112),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.isMovableByWindowBackground = true
        // Over whatever is in front, full-screen apps included, and in every Space.
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        let host = NSHostingView(rootView: StatusSplashView().environmentObject(self))
        host.frame = panel.contentLayoutRect
        host.autoresizingMask = [.width, .height]
        panel.contentView = host
        return panel
    }

    /// The middle of the display the pointer is on, a little above centre, where a dialog sits.
    private func place(_ panel: NSPanel) {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
        guard let frame = screen?.visibleFrame else { return panel.center() }
        let size = panel.frame.size
        panel.setFrameOrigin(NSPoint(x: frame.midX - size.width / 2,
                                     y: frame.midY - size.height / 2 + frame.height * 0.08))
    }

    private func tick() {
        now = Date()
        let onScreen = items.contains { $0.launch != nil } ? Self.wineWindows() : []
        for item in items {
            guard let launch = item.launch else { continue }
            let elapsed = now.timeIntervalSince(item.started)
            if !onScreen.subtracting(launch.baseline).isEmpty || elapsed > Self.launchTimeout {
                hide(item.id)
            } else {
                update(item.id, message: StartupStatus.launchMessage(elapsed: elapsed, updatingPrefix: launch.updatingPrefix))
            }
        }
    }

    // MARK: Wine's windows

    /// The windows on screen that belong to Wine programs: ordinary windows of a real size
    /// whose process is a Wine loader. Every runtime keeps its loader in `lib/wine/<arch>-unix`.
    static func wineWindows() -> Set<CGWindowID> {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]] else { return [] }
        var isWine: [pid_t: Bool] = [:]
        var result = Set<CGWindowID>()
        for window in list {
            guard (window[kCGWindowLayer as String] as? Int) == 0,
                  let id = window[kCGWindowNumber as String] as? CGWindowID,
                  let pid = window[kCGWindowOwnerPID as String] as? pid_t,
                  let bounds = window[kCGWindowBounds as String] as? [String: Any],
                  let width = bounds["Width"] as? Double, let height = bounds["Height"] as? Double,
                  width >= 120, height >= 80 else { continue }
            if isWine[pid] == nil { isWine[pid] = Self.isWineProcess(pid) }
            if isWine[pid] == true { result.insert(id) }
        }
        return result
    }

    private static func isWineProcess(_ pid: pid_t) -> Bool {
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return false }
        let path = String(cString: buffer)
        return path.contains("/lib/wine/") && path.contains("-unix/")
    }
}

/// The status window's contents: an icon, what is happening, and a bar that keeps moving.
struct StatusSplashView: View {
    @EnvironmentObject private var splash: StatusSplash

    var body: some View {
        Group {
            if let item = splash.current {
                HStack(alignment: .center, spacing: 14) {
                    Image(nsImage: item.icon ?? NSApp.applicationIconImage)
                        .resizable().interpolation(.high)
                        .frame(width: 52, height: 52)
                    VStack(alignment: .leading, spacing: 5) {
                        HStack(alignment: .firstTextBaseline) {
                            Text(item.title).font(.headline).lineLimit(1).truncationMode(.middle)
                            Spacer(minLength: 8)
                            Text(StartupStatus.elapsedText(splash.now.timeIntervalSince(item.started)))
                                .font(.caption).monospacedDigit().foregroundStyle(.secondary)
                        }
                        Text(item.message)
                            .font(.subheadline).foregroundStyle(.secondary)
                            .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                        ProgressView().progressViewStyle(.linear).controlSize(.small)
                    }
                }
                .padding(.horizontal, 18).padding(.vertical, 16)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Color.clear
            }
        }
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(.white.opacity(0.12)))
        .contentShape(Rectangle())
        .onTapGesture { splash.dismissAll() }
        .help("Click to hide. What is being done carries on.")
        .accessibilityElement(children: .combine)
    }
}
