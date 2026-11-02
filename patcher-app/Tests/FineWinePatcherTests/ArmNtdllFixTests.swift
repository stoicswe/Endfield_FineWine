import XCTest
@testable import FineWinePatcher

/// Guards the byte patch behind the ARM logo-freeze fix. It edits a binary we can't rebuild, so a
/// wrong offset or encoding would corrupt the exception dispatcher rather than fail to compile.
final class ArmNtdllFixTests: XCTestCase {

    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("fw-ntdll-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    /// A file holding the expected instruction at every site and zeroes elsewhere.
    private func fixture() -> Data {
        var data = Data(count: ArmNtdllFix.sites.map(\.offset).max()! + 4)
        for site in ArmNtdllFix.sites {
            for index in 0..<4 { data[site.offset + index] = UInt8((site.instruction >> (8 * UInt32(index))) & 0xff) }
        }
        return data
    }

    private func word(_ data: Data, _ offset: Int) -> UInt32 {
        (0..<4).reversed().reduce(UInt32(0)) { $0 << 8 | UInt32(data[offset + $1]) }
    }

    func testClampEncodesUbfxWithTheSameRegisters() throws {
        let fixed = try ArmNtdllFix.clampLookups(in: fixture())
        // `lsr x17, x11, #18` -> `ubfx x17, x11, #18, #29`, checked against llvm-objdump.
        XCTAssertEqual(word(fixed, 0xc7910), 0xd352b971)
        for site in ArmNtdllFix.sites {
            let clamped = word(fixed, site.offset)
            XCTAssertEqual(clamped & 0x3ff, site.instruction & 0x3ff, "registers must not change")
            XCTAssertEqual((clamped >> 10) & 0x3f, 46)
        }
    }

    func testChangesOnlyTheSites() throws {
        let original = fixture()
        let fixed = try ArmNtdllFix.clampLookups(in: original)
        let changed = (0..<original.count).filter { original[$0] != fixed[$0] }
        XCTAssertEqual(changed.count, ArmNtdllFix.sites.count)
        for offset in changed {
            XCTAssertTrue(ArmNtdllFix.sites.contains { offset >= $0.offset && offset < $0.offset + 4 })
        }
    }

    func testRefusesUnexpectedCode() {
        var data = fixture()
        data[ArmNtdllFix.sites[3].offset] ^= 0xff
        XCTAssertThrowsError(try ArmNtdllFix.clampLookups(in: data))
    }

    func testRefusesAnUnknownBuild() throws {
        let cxr = tempDir.appendingPathComponent("cx", isDirectory: true)
        let url = cxr.appendingPathComponent(ArmNtdllFix.subpath)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let original = fixture()
        try original.write(to: url)
        XCTAssertThrowsError(try ArmNtdllFix.apply(toCrossOverRoot: cxr))
        XCTAssertEqual(try Data(contentsOf: url), original)
        XCTAssertFalse(ArmNtdllFix.isApplied(inCrossOverRoot: cxr))
    }

    /// Runs against the real file when CrossOver ARM is installed: the whole patch must produce the
    /// exact file that was tested in-game.
    func testProducesTheTestedFileFromStock() throws {
        let root = URL(fileURLWithPath: "/Applications/CrossOver ARM Preview.app/Contents/SharedSupport/CrossOver")
        let source = root.appendingPathComponent(ArmNtdllFix.subpath)
        guard let stock = try? Data(contentsOf: source), ArmNtdllFix.sha256Hex(stock) == ArmNtdllFix.stockSHA256 else {
            throw XCTSkip("Stock CrossOver ARM isn't installed.")
        }
        XCTAssertEqual(ArmNtdllFix.sha256Hex(try ArmNtdllFix.clampLookups(in: stock)), ArmNtdllFix.fixedSHA256)
    }
}
