import XCTest
@testable import FineWineCore

/// Runs FineWine's prefix operations against a real Wine runtime. Skipped unless
/// `FINEWINE_TEST_RUNTIME` names a runtime folder, so the ordinary test run needs no Wine:
///
///     FINEWINE_TEST_RUNTIME=$PWD/../build/finewine-runtime swift test --filter RuntimeIntegrationTests
///
/// Set `FINEWINE_TEST_HOME` to keep the prefixes it makes (for looking at them afterwards).
final class RuntimeIntegrationTests: XCTestCase {
    private var keptRoot: URL?
    private var sandbox: Sandbox?

    private func makeService() throws -> (PrefixService, WineRuntime) {
        let env = ProcessInfo.processInfo.environment
        guard let runtimePath = env["FINEWINE_TEST_RUNTIME"], !runtimePath.isEmpty else {
            throw XCTSkip("set FINEWINE_TEST_RUNTIME to a Wine runtime folder to run this")
        }
        let paths: FineWinePaths
        if let home = env["FINEWINE_TEST_HOME"], home.hasPrefix("/") {
            let root = URL(fileURLWithPath: home, isDirectory: true)
            try? FileManager.default.removeItem(at: root)
            paths = FineWinePaths(root: root.appendingPathComponent("Support"), shortcuts: root.appendingPathComponent("Shortcuts"))
        } else {
            let sandbox = Sandbox()
            self.sandbox = sandbox
            paths = sandbox.paths
        }
        let service = PrefixService(paths: paths)
        let runtime = try service.runtimes.addExternal(URL(fileURLWithPath: runtimePath, isDirectory: true))
        return (service, runtime)
    }

    override func tearDown() {
        sandbox = nil
        super.tearDown()
    }

    func testCreateConfigureAndRestyleAPrefix() throws {
        let (service, runtime) = try makeService()
        let dark = MacAppearance(isDark: true, accentRed: 255, accentGreen: 45, accentBlue: 85)
        let light = MacAppearance(isDark: false, accentRed: 0, accentGreen: 122, accentBlue: 255)

        // Create: Wine sets the prefix up and the settings land in its registry.
        var prefix = try service.createPrefix(name: "Integration", runtime: runtime, profile: .endfield, appearance: dark)
        defer { try? service.stopAll(in: prefix) }
        XCTAssertTrue(prefix.isInitialized, "wineboot should have written the registry files")
        XCTAssertEqual(prefix.metadata.appliedAppearance, dark)

        // Wine writes its registry files when the server shuts down.
        try service.stopAll(in: prefix)
        var snapshot = PrefixRegistrySnapshot.read(prefix: prefix.directory)
        XCTAssertEqual(snapshot.windowsVersion, "win11")
        XCTAssertEqual(snapshot.windowsBuild, "26100")
        XCTAssertEqual(snapshot.dpi, 192, "automatic scaling on a Retina display")
        XCTAssertEqual(snapshot.retinaMode, true, "high-resolution mode is the default")
        var user = try WineRegistryReader(contentsOf: prefix.directory.appendingPathComponent("user.reg"))
        XCTAssertEqual(user.string(key: #"Control Panel\Colors"#, name: "Hilight"), "255 45 85")
        XCTAssertEqual(user.string(key: #"Control Panel\Colors"#, name: "Window"), "30 30 30")
        XCTAssertEqual(user.string(key: #"Software\Microsoft\Windows\CurrentVersion\ThemeManager"#, name: "ThemeActive"), "0")

        // Change settings, switch to MSync, and restyle for light mode.
        prefix.metadata.settings.automaticDPI = false
        prefix.metadata.settings.dpi = 144
        prefix.metadata.settings.syncMode = .msync
        prefix.metadata.settings.dllOverrides = [DLLOverride(name: "dinput8", order: .nativeThenBuiltin)]
        XCTAssertTrue(service.needsAppearanceRefresh(prefix, current: light))
        prefix = try service.applySettings(to: prefix, appearance: light)
        XCTAssertEqual(try service.planner(for: prefix).environment()["WINEMSYNC"], "1")

        try service.stopAll(in: prefix)
        snapshot = PrefixRegistrySnapshot.read(prefix: prefix.directory)
        XCTAssertEqual(snapshot.dpi, 144)
        XCTAssertEqual(snapshot.dllOverrides["dinput8"], "native,builtin")
        user = try WineRegistryReader(contentsOf: prefix.directory.appendingPathComponent("user.reg"))
        XCTAssertEqual(user.string(key: #"Control Panel\Colors"#, name: "Hilight"), "0 122 255")
        XCTAssertEqual(user.string(key: #"Control Panel\Colors"#, name: "Window"), "255 255 255")
        XCTAssertEqual(user.string(key: #"Software\Microsoft\Windows\CurrentVersion\ThemeManager"#, name: "ThemeActive"), "1")

        // A prefix with nothing changed gets high-resolution mode and the display's DPI.
        let plain = try service.createPrefix(name: "Defaults", runtime: runtime, profile: nil, appearance: light)
        try service.stopAll(in: plain)
        let defaults = PrefixRegistrySnapshot.read(prefix: plain.directory)
        XCTAssertEqual(defaults.retinaMode, true)
        XCTAssertEqual(defaults.dpi, 192)

        // A Windows program runs to completion and its output comes back.
        var plan = try service.planner(for: prefix).plan(for: WineTool.cmd)
        plan.arguments = ["cmd", "/c", "echo", "finewine-ok"]
        let result = try service.runner.run(plan)
        XCTAssertEqual(result.status, 0, result.output)
        XCTAssertTrue(result.output.contains("finewine-ok"), result.output)
    }
}
