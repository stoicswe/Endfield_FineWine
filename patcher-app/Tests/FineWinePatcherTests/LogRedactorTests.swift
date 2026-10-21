import XCTest
@testable import FineWinePatcher

final class LogRedactorTests: XCTestCase {

    private let redactor = LogRedactor(
        homeDirectory: "/Users/alice",
        userNames: ["alice", "Alice Smith"],
        hostName: "Alice-MacBook-Pro",
        bottleNames: ["Alice's Game"]
    )

    private let sample = """
    $ /Users/alice/Library/Application Support/CrossOver/Bottles/Alice's Game/cxbottle.conf
    root dir: C:\\users\\alice\\AppData\\Local
    drive_c/users/alice/AppData
    from 10.1.2.3 and fe80::1c2d:3e4f:5a6b:7c8d
    mail alice@example.com
    token=abc123secret
    Authorization: Bearer abc.def.ghi123456
    jwt eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.dozjgNryP4J3jVmNHl0w5N_XgL0n3I9PlFUP0THsR8U
    uuid 50D9CB9A-F061-4E63-8004-95D6704F4A36
    hash 0123456789abcdef0123456789abcdef
    mac aa:bb:cc:dd:ee:ff
    host Alice-MacBook-Pro.local
    Registered to: Alice Smith
    volume /Volumes/AliceSSD/game
    temp /private/var/folders/zz/T/xyz.log
    """

    func testIdentifiersAreRemoved() {
        let out = redactor.redact(sample)
        for secret in [
            "alice", "Alice Smith", "Alice-MacBook-Pro", "AliceSSD",
            "10.1.2.3", "fe80::1c2d", "alice@example.com", "abc123secret",
            "abc.def.ghi123456", "eyJhbGciOiJIUzI1NiJ9",
            "50D9CB9A-F061-4E63", "0123456789abcdef0123456789abcdef",
            "aa:bb:cc:dd:ee:ff",
        ] {
            XCTAssertFalse(out.localizedCaseInsensitiveContains(secret), "still contains \(secret):\n\(out)")
        }
    }

    func testPlaceholdersAreUsed() {
        let out = redactor.redact(sample)
        XCTAssertTrue(out.contains("~/Library/Application Support"))       // home folder
        XCTAssertTrue(out.contains("<bottle>"))                            // bottle name / path
        XCTAssertTrue(out.contains("C:\\users\\<user>"))                    // Windows profile
        XCTAssertTrue(out.contains("drive_c/users/<user>"))
        XCTAssertTrue(out.contains("<email>"))
        XCTAssertTrue(out.contains("token=<redacted>"))
        XCTAssertTrue(out.contains("Bearer <token>"))
        XCTAssertTrue(out.contains("<uuid>"))
        XCTAssertTrue(out.contains("<hash>"))
        XCTAssertTrue(out.contains("<mac>"))
        XCTAssertTrue(out.contains("<ip>"))
        XCTAssertTrue(out.contains("<host>"))
        XCTAssertTrue(out.contains("Registered to: <redacted>"))
        XCTAssertTrue(out.contains("/Volumes/<volume>"))
        XCTAssertTrue(out.contains("<tmp>"))
    }

    func testOtherUsersHomeFoldersAreGeneralised() {
        let out = redactor.redact("loading /Users/someoneelse/Games/Endfield.exe")
        XCTAssertFalse(out.contains("someoneelse"))
        XCTAssertTrue(out.contains("/Users/<user>"))
    }

    func testHarmlessLogLinesSurvive() {
        let line = "msync: bootstrapped mach port on wine-22664b0-msync."
        XCTAssertEqual(redactor.redact(line), line)
        let line2 = "[I] <MMKV.cpp:203::initializeMMKV> root dir: C:\\Program Files\\GRYPHLINK\\Cache\\Config"
        XCTAssertEqual(redactor.redact(line2), line2)
    }

    func testExcerptKeepsTheTailAndMarksTruncation() {
        let text = String(repeating: "a", count: 100) + "TAIL"
        let excerpt = LogRedactor.excerpt(text, maxCharacters: 10)
        XCTAssertTrue(excerpt.truncated)
        XCTAssertTrue(excerpt.text.hasSuffix("TAIL"))
        XCTAssertTrue(excerpt.text.contains("earlier output omitted"))
    }

    func testExcerptsRespectTheSharedBudget() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("fw-redactor-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let first = dir.appendingPathComponent("bottle-alices-game.log")
        let second = dir.appendingPathComponent("installer-alices-game.log")
        try (String(repeating: "x", count: 100) + " FIRST-END").write(to: first, atomically: true, encoding: .utf8)
        try (String(repeating: "y", count: 100) + " SECOND-END").write(to: second, atomically: true, encoding: .utf8)

        let excerpts = LogRedactor.excerpts(
            logs: [("bottle-Alice's Game.log", first), ("installer-Alice's Game.log", second)],
            redactor: redactor,
            maxPerLog: 60,
            maxTotalCharacters: 150
        )
        XCTAssertGreaterThanOrEqual(excerpts.count, 2)
        let joined = excerpts.joined(separator: "\n")
        XCTAssertFalse(joined.contains("Alice's Game"))
        XCTAssertTrue(joined.contains("<bottle>"))
        XCTAssertLessThanOrEqual(joined.count, 190)   // shared budget + the omission marker
        XCTAssertTrue(joined.contains("FIRST-END"))
    }
}
