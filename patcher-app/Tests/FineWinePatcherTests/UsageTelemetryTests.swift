import XCTest
@testable import FineWinePatcher

final class UsageTelemetryTests: XCTestCase {

    func testOnlyAllowlistedMetadataCanBeSent() {
        let safe = UsageTelemetry.safeMetadata([
            "gptk": "true",
            "duration_seconds": "42",
            "failed_step": "3",
            "cross_over_build": "39832",
            "path": "/Users/example/Bottles/private",
            "bottle": "Arknights Endfield",
            "token": "secret",
        ])
        XCTAssertEqual(safe, [
            "gptk": "true",
            "duration_seconds": "42",
            "failed_step": "3",
            "cross_over_build": "39832",
        ])
    }

    func testFailedPatchPromptContainsOnlyTheApprovedSchema() throws {
        let prompt = UsageTelemetry.makePatchPrompt(
            succeeded: false, gptk: true, failedStep: 3, durationSeconds: 42,
            crossOverBuild: "39832"
        )
        XCTAssertEqual(prompt.event, "patch_failed")
        XCTAssertFalse(prompt.isSuccess)

        let object = try jsonObject(prompt)
        XCTAssertEqual(
            Set(object.keys),
            ["app", "event", "count", "appVersion", "osMajor", "metadata"]
        )
        XCTAssertEqual(object["event"] as? String, "patch_failed")
        let metadata = try XCTUnwrap(object["metadata"] as? [String: String])
        XCTAssertEqual(metadata, [
            "gptk": "true",
            "duration_seconds": "42",
            "failed_step": "3",
            "cross_over_build": "39832",
        ])
    }

    func testSuccessfulPatchPromptHasNoFailedStep() throws {
        let prompt = UsageTelemetry.makePatchPrompt(
            succeeded: true, gptk: false, failedStep: nil, durationSeconds: 12,
            crossOverBuild: "39832"
        )
        XCTAssertEqual(prompt.event, "patch_succeeded")
        XCTAssertTrue(prompt.isSuccess)

        let metadata = try XCTUnwrap(try jsonObject(prompt)["metadata"] as? [String: String])
        XCTAssertEqual(metadata, [
            "gptk": "false", "duration_seconds": "12", "cross_over_build": "39832",
        ])
        XCTAssertNil(metadata["failed_step"])
    }

    /// An app whose Info.plist has no CFBundleVersion must not send an empty/absent-looking field.
    func testUnknownCrossOverBuildIsOmitted() throws {
        let prompt = UsageTelemetry.makePatchPrompt(
            succeeded: true, gptk: false, failedStep: nil, durationSeconds: 3,
            crossOverBuild: nil
        )
        let metadata = try XCTUnwrap(try jsonObject(prompt)["metadata"] as? [String: String])
        XCTAssertEqual(metadata, ["gptk": "false", "duration_seconds": "3"])
        XCTAssertNil(metadata["cross_over_build"])
    }

    // MARK: - Automated Setup reports

    func testSetupPromptIncludesRedactedLogsAndSetupMetadata() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("fw-setup-telemetry-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let log = dir.appendingPathComponent("installer-Private Bottle.log")
        let contents = """
        $ bin/wine --bottle "Private Bottle" --wait-children -- .../Users/alice/Downloads/GRYPHLINK.exe
        wine: alice@example.com token=super-secret
        uuid 50D9CB9A-F061-4E63-8004-95D6704F4A36
        winewrapper.exe:error: cannot execute
        """
        try contents.write(to: log, atomically: true, encoding: .utf8)

        var settings = BottleSettings()
        settings.name = "Private Bottle"
        settings.backend = .dxmt
        settings.msync = false
        settings.upscaling = true

        let prompt = UsageTelemetry.makeSetupPrompt(
            succeeded: false, failedStep: 1, durationSeconds: 19,
            settings: settings, msyncFallback: false, installerStarted: true, installerExit: 11,
            bottleName: settings.trimmedName,
            logs: [("installer-Private Bottle.log", log)]
        )

        XCTAssertEqual(prompt.event, "setup_failed")
        XCTAssertTrue(prompt.isSetup)
        XCTAssertFalse(prompt.isSuccess)

        let object = try jsonObject(prompt)
        XCTAssertTrue(Set(object.keys).isSuperset(of: ["logs", "metadata"]))
        let logs = try XCTUnwrap(object["logs"] as? [String])
        XCTAssertEqual(logs.count, 1)
        let joined = logs.joined()
        XCTAssertFalse(joined.contains("Private Bottle"))
        XCTAssertFalse(joined.localizedCaseInsensitiveContains("alice@example.com"))
        XCTAssertFalse(joined.contains("super-secret"))
        XCTAssertFalse(joined.contains("50D9CB9A-F061"))
        XCTAssertTrue(joined.contains("<bottle>"))
        XCTAssertTrue(joined.contains("cannot execute"), "the useful error line must survive")

        let metadata = try XCTUnwrap(object["metadata"] as? [String: String])
        XCTAssertEqual(metadata, [
            "duration_seconds": "19",
            "setup_backend": "dxmt",
            "setup_msync": "false",
            "setup_upscaling": "true",
            "installer_status": "exited:11",
            "failed_step": "1",
        ])
    }

    func testPatchPromptsCarryNoLogs() throws {
        let prompt = UsageTelemetry.makePatchPrompt(
            succeeded: true, gptk: false, failedStep: nil, durationSeconds: 5
        )
        XCTAssertFalse(prompt.isSetup)
        XCTAssertTrue(prompt.logs.isEmpty)
        XCTAssertNil(try jsonObject(prompt)["logs"])
    }

    private func jsonObject(_ prompt: UsageTelemetry.Prompt) throws -> [String: Any] {
        let data = try XCTUnwrap(prompt.json.data(using: .utf8))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
}
