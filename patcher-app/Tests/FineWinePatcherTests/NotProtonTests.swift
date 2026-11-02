import XCTest
@testable import FineWinePatcher

final class NotProtonTests: XCTestCase {
    var tempDir: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("NotProtonTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
        try super.tearDownWithError()
    }

    func testDetectStatusWhenNotInstalled() {
        let steamRoot = tempDir.appendingPathComponent("Steam", isDirectory: true)
        let npSupport = tempDir.appendingPathComponent("notproton", isDirectory: true)

        let status = NotProton.detectStatus(
            steamRoot: steamRoot,
            notProtonRoot: npSupport,
            buildName: "test-build",
            toolName: "test-tool"
        )

        XCTAssertFalse(status.steamInstalled)
        XCTAssertFalse(status.notProtonInstalled)
        XCTAssertFalse(status.runnerExists)
        XCTAssertFalse(status.toolExists)
        XCTAssertFalse(status.isRegistered)
    }

    func testRegisterAndUnregisterInSandbox() throws {
        let fm = FileManager.default
        let steamRoot = tempDir.appendingPathComponent("Steam", isDirectory: true)
        let npSupport = tempDir.appendingPathComponent("notproton", isDirectory: true)

        // Create a mock patched CrossOver app bundle
        let mockApp = tempDir.appendingPathComponent("MockCrossOver.app", isDirectory: true)
        let cxr = mockApp.appendingPathComponent("Contents/SharedSupport/CrossOver", isDirectory: true)
        let binDir = cxr.appendingPathComponent("bin", isDirectory: true)
        let wineUnixDir = cxr.appendingPathComponent("lib/wine/x86_64-unix", isDirectory: true)
        try fm.createDirectory(at: binDir, withIntermediateDirectories: true)
        try fm.createDirectory(at: wineUnixDir, withIntermediateDirectories: true)

        let wineBin = binDir.appendingPathComponent("wine")
        try "#!/bin/sh\nexit 0\n".write(to: wineBin, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: wineBin.path)

        let ntdll = wineUnixDir.appendingPathComponent("ntdll.so")
        try "fake-ntdll".write(to: ntdll, atomically: true, encoding: .utf8)

        XCTAssertTrue(NotProton.isPatchedCrossOver(mockApp))

        // Register
        try NotProton.register(
            patchedApp: mockApp,
            steamRoot: steamRoot,
            notProtonRoot: npSupport,
            buildName: "finewine-test",
            displayName: "Test Display Name",
            toolName: "notproton-finewine-test",
            flavor: "rosetta"
        )

        let statusAfterRegister = NotProton.detectStatus(
            steamRoot: steamRoot,
            notProtonRoot: npSupport,
            buildName: "finewine-test",
            toolName: "notproton-finewine-test",
            customPatchedApp: mockApp
        )

        XCTAssertTrue(statusAfterRegister.runnerExists)
        XCTAssertTrue(statusAfterRegister.toolExists)
        XCTAssertTrue(statusAfterRegister.isRegistered)

        // Verify compatibilitytool.vdf content
        let vdfURL = statusAfterRegister.toolDirectory.appendingPathComponent("compatibilitytool.vdf")
        let vdfContent = try String(contentsOf: vdfURL, encoding: .utf8)
        XCTAssertTrue(vdfContent.contains("notproton-finewine-test"))
        XCTAssertTrue(vdfContent.contains("Test Display Name"))
        XCTAssertTrue(vdfContent.contains("\"to_oslist\" \"macos\""))

        // Verify toolmanifest.vdf content
        let manifestURL = statusAfterRegister.toolDirectory.appendingPathComponent("toolmanifest.vdf")
        let manifestContent = try String(contentsOf: manifestURL, encoding: .utf8)
        XCTAssertTrue(manifestContent.contains("\"commandline\" \"/run %verb%\""))

        // Verify defaults override
        let defaultsURL = npSupport.appendingPathComponent("defaults-override-finewine-test-rosetta")
        let defaultsContent = try String(contentsOf: defaultsURL, encoding: .utf8)
        XCTAssertTrue(defaultsContent.contains("CX_GRAPHICS_BACKEND=d3dmetal"))
        XCTAssertTrue(defaultsContent.contains("WINEMSYNC=1"))

        // Unregister
        try NotProton.unregister(
            steamRoot: steamRoot,
            notProtonRoot: npSupport,
            buildName: "finewine-test",
            toolName: "notproton-finewine-test"
        )

        let statusAfterUnregister = NotProton.detectStatus(
            steamRoot: steamRoot,
            notProtonRoot: npSupport,
            buildName: "finewine-test",
            toolName: "notproton-finewine-test",
            customPatchedApp: mockApp
        )

        XCTAssertFalse(statusAfterUnregister.isRegistered)
        XCTAssertFalse(statusAfterUnregister.toolExists)
        XCTAssertFalse(statusAfterUnregister.runnerExists)
    }
}
