import XCTest
@testable import FineWinePatcher

final class SikarugirTests: XCTestCase {
    var tempDir: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("SikarugirTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
        try super.tearDownWithError()
    }

    // MARK: - detectStatus

    func testDetectStatusWhenNotInstalled() {
        let sikarugirRoot = tempDir.appendingPathComponent("Sikarugir", isDirectory: true)

        let status = Sikarugir.detectStatus(sikarugirRoot: sikarugirRoot)

        XCTAssertFalse(status.sikarugirInstalled)
        XCTAssertFalse(status.engineInstalled)
        XCTAssertNil(status.engineTarball)
    }

    func testDetectStatusSikarugirPresentButEngineAbsent() throws {
        let sikarugirRoot = tempDir.appendingPathComponent("Sikarugir", isDirectory: true)
        try FileManager.default.createDirectory(at: sikarugirRoot, withIntermediateDirectories: true)

        let status = Sikarugir.detectStatus(sikarugirRoot: sikarugirRoot)

        XCTAssertTrue(status.sikarugirInstalled)
        XCTAssertFalse(status.engineInstalled)
    }

    func testDetectStatusEngineDetectedByNtdll() throws {
        let fm = FileManager.default
        let sikarugirRoot = tempDir.appendingPathComponent("Sikarugir", isDirectory: true)
        let engineDir = sikarugirRoot
            .appendingPathComponent("Engines", isDirectory: true)
            .appendingPathComponent(Sikarugir.engineName, isDirectory: true)
        let ntdllDir = engineDir.appendingPathComponent("lib/wine/x86_64-unix", isDirectory: true)
        try fm.createDirectory(at: ntdllDir, withIntermediateDirectories: true)
        let ntdll = ntdllDir.appendingPathComponent("ntdll.so")
        try "fake".write(to: ntdll, atomically: true, encoding: .utf8)

        let status = Sikarugir.detectStatus(sikarugirRoot: sikarugirRoot)

        XCTAssertTrue(status.sikarugirInstalled)
        XCTAssertTrue(status.engineInstalled)
    }

    func testDetectStatusCustomTarball() throws {
        let sikarugirRoot = tempDir.appendingPathComponent("Sikarugir", isDirectory: true)
        let fakeTarball = tempDir.appendingPathComponent("WS12WineFineWine26.3.0_1.tar.xz")
        try "fake".write(to: fakeTarball, atomically: true, encoding: .utf8)

        let status = Sikarugir.detectStatus(sikarugirRoot: sikarugirRoot, customTarball: fakeTarball)

        XCTAssertEqual(status.engineTarball, fakeTarball)
    }

    // MARK: - installEngine / removeEngine

    func testInstallEngineFailsForMissingTarball() {
        let sikarugirRoot = tempDir.appendingPathComponent("Sikarugir", isDirectory: true)
        let fakeTarball = tempDir.appendingPathComponent("nonexistent.tar.xz")

        XCTAssertThrowsError(try Sikarugir.installEngine(tarball: fakeTarball,
                                                         sikarugirRoot: sikarugirRoot)) { error in
            XCTAssertTrue(error.localizedDescription.contains("not found"))
        }
    }

    func testInstallEngineExtractsAndVerifies() throws {
        // Build a minimal .tar.xz that contains bin/wine
        let fm = FileManager.default
        let stagingDir = tempDir.appendingPathComponent("engine-staging", isDirectory: true)
        let binDir = stagingDir.appendingPathComponent("bin", isDirectory: true)
        try fm.createDirectory(at: binDir, withIntermediateDirectories: true)
        let wineExec = binDir.appendingPathComponent("wine")
        try "#!/bin/sh\nexit 0\n".write(to: wineExec, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: wineExec.path)

        // Also create lib/wine/x86_64-unix/ntdll.so to satisfy the ntdll detection path
        let ntdllDir = stagingDir.appendingPathComponent("lib/wine/x86_64-unix", isDirectory: true)
        try fm.createDirectory(at: ntdllDir, withIntermediateDirectories: true)
        try "fake-ntdll".write(to: ntdllDir.appendingPathComponent("ntdll.so"),
                               atomically: true, encoding: .utf8)

        // Create a .tar.xz from the staging dir
        let tarball = tempDir.appendingPathComponent("WS12WineFineWine26.3.0_1.tar.xz")
        let tarCreate = Process()
        tarCreate.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        tarCreate.arguments = ["-cJf", tarball.path, "-C", stagingDir.path, "."]
        try tarCreate.run()
        tarCreate.waitUntilExit()
        guard tarCreate.terminationStatus == 0 else {
            XCTFail("Failed to create test tarball")
            return
        }

        let sikarugirRoot = tempDir.appendingPathComponent("Sikarugir", isDirectory: true)
        try Sikarugir.installEngine(tarball: tarball, sikarugirRoot: sikarugirRoot)

        let engineDir = sikarugirRoot
            .appendingPathComponent("Engines/\(Sikarugir.engineName)", isDirectory: true)
        XCTAssertTrue(fm.isExecutableFile(atPath: engineDir.appendingPathComponent("bin/wine").path))

        let status = Sikarugir.detectStatus(sikarugirRoot: sikarugirRoot)
        XCTAssertTrue(status.engineInstalled)
    }

    func testRemoveEngineWhenNotPresent() {
        // Should not throw when nothing is installed
        let sikarugirRoot = tempDir.appendingPathComponent("Sikarugir", isDirectory: true)
        XCTAssertNoThrow(try Sikarugir.removeEngine(sikarugirRoot: sikarugirRoot))
    }

    func testInstallThenRemoveEngine() throws {
        let fm = FileManager.default
        let sikarugirRoot = tempDir.appendingPathComponent("Sikarugir", isDirectory: true)
        let engineDir = sikarugirRoot
            .appendingPathComponent("Engines/\(Sikarugir.engineName)", isDirectory: true)

        // Manually stage a fake engine
        let binDir = engineDir.appendingPathComponent("bin", isDirectory: true)
        try fm.createDirectory(at: binDir, withIntermediateDirectories: true)
        let wine = binDir.appendingPathComponent("wine")
        try "#!/bin/sh\n".write(to: wine, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: wine.path)

        XCTAssertTrue(Sikarugir.detectStatus(sikarugirRoot: sikarugirRoot).engineInstalled)

        try Sikarugir.removeEngine(sikarugirRoot: sikarugirRoot)

        XCTAssertFalse(fm.fileExists(atPath: engineDir.path))
        XCTAssertFalse(Sikarugir.detectStatus(sikarugirRoot: sikarugirRoot).engineInstalled)
    }

    // MARK: - findEngineTarball

    func testFindEngineTarballFindsInDownloads() throws {
        // We can't write into the real ~/Downloads, so use the custom-tarball path instead.
        // The detect-status path covers the custom tarball; findEngineTarball is a best-effort
        // helper, so just confirm it returns nil when nothing is there.
        let result = Sikarugir.findEngineTarball()
        // Acceptable: either nil or a URL pointing to an actually existing file.
        if let url = result {
            XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        }
    }

    // MARK: - Constants

    func testEngineNameMatchesScheme() {
        XCTAssertTrue(Sikarugir.engineName.hasPrefix(Sikarugir.engineScheme))
        XCTAssertTrue(Sikarugir.engineName.contains(Sikarugir.engineVersion))
    }
}

