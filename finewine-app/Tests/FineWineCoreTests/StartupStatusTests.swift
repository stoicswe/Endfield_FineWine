import XCTest
@testable import FineWineCore

final class StartupStatusTests: XCTestCase {
    private func sandbox() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("fw-status-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    func testPrefixNeedsWineUpdateWhenTheRuntimeIsNotTheOneItWasSetUpWith() throws {
        let root = try sandbox()
        let prefix = root.appendingPathComponent("prefix"), runtime = root.appendingPathComponent("runtime")
        let inf = runtime.appendingPathComponent("share/wine/wine.inf")
        try FileManager.default.createDirectory(at: prefix, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: inf.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("inf".utf8).write(to: inf)
        let modified = Date(timeIntervalSince1970: 1_800_000_000)
        try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: inf.path)
        let stamp = prefix.appendingPathComponent(".update-timestamp")

        // a prefix Wine has not set up yet is not "being updated"
        XCTAssertFalse(StartupStatus.prefixNeedsWineUpdate(prefix: prefix, runtimeRoot: runtime))
        try Data("1800000000\n".utf8).write(to: stamp)
        XCTAssertFalse(StartupStatus.prefixNeedsWineUpdate(prefix: prefix, runtimeRoot: runtime))
        try Data("1700000000\n".utf8).write(to: stamp)
        XCTAssertTrue(StartupStatus.prefixNeedsWineUpdate(prefix: prefix, runtimeRoot: runtime))
        try Data("disable\n".utf8).write(to: stamp)
        XCTAssertFalse(StartupStatus.prefixNeedsWineUpdate(prefix: prefix, runtimeRoot: runtime))
    }

    func testLaunchMessageChangesAsTimePasses() {
        let early = StartupStatus.launchMessage(elapsed: 1, updatingPrefix: false)
        let later = StartupStatus.launchMessage(elapsed: 10, updatingPrefix: false)
        let long = StartupStatus.launchMessage(elapsed: 120, updatingPrefix: false)
        XCTAssertEqual(Set([early, later, long]).count, 3)
        XCTAssertTrue(StartupStatus.launchMessage(elapsed: 1, updatingPrefix: true).contains("Updating the prefix"))
    }

    func testElapsedTextStartsAfterAFewSeconds() {
        XCTAssertEqual(StartupStatus.elapsedText(2), "")
        XCTAssertEqual(StartupStatus.elapsedText(12.7), "12 s")
        XCTAssertEqual(StartupStatus.elapsedText(65), "1 min 5 s")
    }
}
