import XCTest
@testable import FineWinePatcher

/// Guards the CPU-name edit to CrossOver ARM's x64 emulator.
final class ArmEmulatorIdentityTests: XCTestCase {

    private let build = ArmEmulatorIdentity.builds[0]

    /// A file with the stock name literal in place and zeroes elsewhere.
    private func fixture() -> Data {
        var data = Data(count: build.nameOffset + 64)
        data.replaceSubrange(build.nameOffset..<build.nameOffset + 15, with: Array(ArmEmulatorIdentity.stockName.utf8))
        data[build.nameOffset + 16] = 0x51   // the byte after the literal must survive
        return data
    }

    func testOnlyTheNameLiteralChanges() throws {
        let original = fixture()
        let patched = try ArmEmulatorIdentity.patched(original, build: build, cpuName: "Apple M3")
        XCTAssertEqual(Array(patched[build.nameOffset..<build.nameOffset + 16]),
                       Array("Apple M3".utf8) + [UInt8](repeating: 0, count: 8))
        XCTAssertEqual(patched.count, original.count)
        let changed = (0..<original.count).filter { original[$0] != patched[$0] }
        XCTAssertFalse(changed.isEmpty)
        XCTAssertTrue(changed.allSatisfy { (build.nameOffset..<build.nameOffset + 16).contains($0) })
    }

    func testNameIsCutToTheLiteral() {
        XCTAssertEqual(ArmEmulatorIdentity.fieldName("Apple M4 Max Extra Long Name").map { String(decoding: $0, as: UTF8.self) },
                       "Apple M4 Max Ex")
        XCTAssertNil(ArmEmulatorIdentity.fieldName("  "))
    }

    func testRefusesUnexpectedData() {
        var data = fixture()
        data[build.nameOffset] ^= 0xff
        XCTAssertThrowsError(try ArmEmulatorIdentity.patched(data, build: build, cpuName: "Apple M3"))
    }

    func testLeavesAnUnknownFileAlone() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("fw-xtajit-\(UUID().uuidString).dll")
        defer { try? FileManager.default.removeItem(at: url) }
        let original = fixture()   // right literal, but not a known build's hash
        try original.write(to: url)
        XCTAssertFalse(try ArmEmulatorIdentity.apply(toFile: url, cpuName: "Apple M3"))
        XCTAssertEqual(try Data(contentsOf: url), original)
    }

    func testArmBottlesHideTheHypervisorBit() {
        XCTAssertEqual(ArmEmulatorIdentity.environment.map { "\($0.key)=\($0.value)" }, ["FEX_HIDEHYPERVISORBIT=1"])
    }

    /// Runs against the real file of a known stock CrossOver ARM build, if one is installed: only
    /// the 16-byte literal may differ afterwards, and a second run changes nothing.
    func testPatchesTheInstalledStockEmulator() throws {
        let apps = ["CrossOver Preview ARM.app", "CrossOver ARM Preview.app", "CrossOver Preview.app"]
        for app in apps {
            let source = URL(fileURLWithPath: "/Applications/\(app)/Contents/SharedSupport/CrossOver")
                .appendingPathComponent(ArmEmulatorIdentity.appSubpath)
            guard let stock = try? Data(contentsOf: source),
                  ArmEmulatorIdentity.builds.contains(where: { $0.stockSHA256 == ArmEmulatorIdentity.sha256Hex(stock) })
            else { continue }
            let copy = FileManager.default.temporaryDirectory.appendingPathComponent("fw-xtajit-\(UUID().uuidString).dll")
            defer { try? FileManager.default.removeItem(at: copy) }
            try stock.write(to: copy)
            XCTAssertTrue(try ArmEmulatorIdentity.apply(toFile: copy, cpuName: "Apple M3"))
            let patched = try Data(contentsOf: copy)
            XCTAssertNotNil(ArmEmulatorIdentity.editedBuild(of: patched))
            let changed = (0..<stock.count).filter { stock[$0] != patched[$0] }
            XCTAssertTrue(changed.allSatisfy { (build.nameOffset..<build.nameOffset + 16).contains($0) })
            XCTAssertEqual(Array(patched[build.nameOffset..<build.nameOffset + 9]), Array("Apple M3".utf8) + [0])
            XCTAssertTrue(try ArmEmulatorIdentity.apply(toFile: copy, cpuName: "Other"), "a second run is a no-op")
            XCTAssertEqual(try Data(contentsOf: copy), patched)
            return
        }
        throw XCTSkip("No known stock CrossOver ARM build is installed.")
    }
}
