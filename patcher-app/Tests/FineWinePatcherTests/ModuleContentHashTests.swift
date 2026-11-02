import XCTest
@testable import FineWinePatcher

/// `verify()` must compare the module's code, not its signature layout. Re-signing a Mach-O
/// rewrites `__LINKEDIT.vmsize` to fit the new signature, and simply removing the signature does
/// not restore the original value. A payload signed on the CI runner and a copy re-signed on the
/// user's Mac can therefore differ in the header even when the executable code is identical.
final class ModuleContentHashTests: XCTestCase {

    func testContentHashIgnoresSignatureAllocation() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("fw-hash-\(UUID().uuidString)")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }

        let original = root.appendingPathComponent("original.so")
        let resigned = root.appendingPathComponent("resigned.so")
        try fm.copyItem(at: URL(fileURLWithPath: "/usr/bin/true"), to: original)
        try fm.copyItem(at: original, to: resigned)

        // Simulate the swap: the installed copy is re-signed locally.
        let codesign = Process()
        codesign.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        codesign.arguments = ["--force", "--sign", "-", resigned.path]
        codesign.standardOutput = Pipe()
        codesign.standardError = Pipe()
        try codesign.run()
        codesign.waitUntilExit()
        XCTAssertEqual(codesign.terminationStatus, 0)

        let originalData = try Data(contentsOf: original)
        let resignedData = try Data(contentsOf: resigned)
        XCTAssertNotEqual(originalData, resignedData, "the fixture must exercise different signatures")

        XCTAssertEqual(PatcherEngine.contentHash(original), PatcherEngine.contentHash(resigned))
    }
}
