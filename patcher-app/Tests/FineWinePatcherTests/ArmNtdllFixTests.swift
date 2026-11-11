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

    /// A file holding the build's expected instruction at every site and zeroes elsewhere.
    private func fixture(_ build: ArmNtdllFix.Build) -> Data {
        var data = Data(count: build.sites.map(\.offset).max()! + 4)
        for site in build.sites {
            for index in 0..<4 { data[site.offset + index] = UInt8((site.instruction >> (8 * UInt32(index))) & 0xff) }
        }
        return data
    }

    private func word(_ data: Data, _ offset: Int) -> UInt32 {
        (0..<4).reversed().reduce(UInt32(0)) { $0 << 8 | UInt32(data[offset + $1]) }
    }

    func testClampEncodesUbfxWithTheSameRegisters() throws {
        for build in ArmNtdllFix.builds {
            let fixed = try ArmNtdllFix.clampLookups(in: fixture(build), build: build)
            // `lsr x17, x11, #18` -> `ubfx x17, x11, #18, #29`, checked against llvm-objdump.
            XCTAssertEqual(word(fixed, build.sites[0].offset), 0xd352b971, build.name)
            for site in build.sites {
                let clamped = word(fixed, site.offset)
                XCTAssertEqual(clamped & 0x3ff, site.instruction & 0x3ff, "registers must not change")
                XCTAssertEqual((clamped >> 10) & 0x3f, 46)
            }
        }
    }

    func testChangesOnlyTheSites() throws {
        for build in ArmNtdllFix.builds {
            let original = fixture(build)
            let fixed = try ArmNtdllFix.clampLookups(in: original, build: build)
            let changed = (0..<original.count).filter { original[$0] != fixed[$0] }
            XCTAssertEqual(changed.count, build.sites.count, build.name)
            for offset in changed {
                XCTAssertTrue(build.sites.contains { offset >= $0.offset && offset < $0.offset + 4 })
            }
        }
    }

    /// Every build patches the same nine lookups; only where they sit in the file moves.
    func testBuildsPatchTheSameLookups() {
        let instructions = ArmNtdllFix.builds.map { $0.sites.map(\.instruction) }
        XCTAssertTrue(instructions.allSatisfy { $0 == instructions[0] && $0.count == 9 })
        XCTAssertEqual(Set(ArmNtdllFix.builds.map(\.stockSHA256)).count, ArmNtdllFix.builds.count)
    }

    func testRefusesUnexpectedCode() {
        let build = ArmNtdllFix.builds[0]
        var data = fixture(build)
        data[build.sites[3].offset] ^= 0xff
        XCTAssertThrowsError(try ArmNtdllFix.clampLookups(in: data, build: build))
    }

    func testRefusesAnUnknownBuild() throws {
        let cxr = tempDir.appendingPathComponent("cx", isDirectory: true)
        let url = cxr.appendingPathComponent(ArmNtdllFix.subpath)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let original = fixture(ArmNtdllFix.builds[0])
        try original.write(to: url)
        XCTAssertThrowsError(try ArmNtdllFix.apply(toCrossOverRoot: cxr))
        XCTAssertEqual(try Data(contentsOf: url), original)
        XCTAssertFalse(ArmNtdllFix.isApplied(inCrossOverRoot: cxr))
    }

    /// Runs against the real file of whichever known CrossOver ARM build is installed: the whole
    /// patch must produce the exact file recorded for it.
    func testProducesTheRecordedFileFromStock() throws {
        let apps = ["CrossOver Preview ARM.app", "CrossOver ARM Preview.app", "CrossOver Preview.app"]
        var tested = 0
        for app in apps {
            let source = URL(fileURLWithPath: "/Applications/\(app)/Contents/SharedSupport/CrossOver")
                .appendingPathComponent(ArmNtdllFix.subpath)
            guard let stock = try? Data(contentsOf: source),
                  let build = ArmNtdllFix.builds.first(where: { $0.stockSHA256 == ArmNtdllFix.sha256Hex(stock) })
            else { continue }
            XCTAssertEqual(ArmNtdllFix.sha256Hex(try ArmNtdllFix.clampLookups(in: stock, build: build)), build.fixedSHA256, build.name)
            tested += 1
        }
        if tested == 0 { throw XCTSkip("No known stock CrossOver ARM build is installed.") }
    }
}
