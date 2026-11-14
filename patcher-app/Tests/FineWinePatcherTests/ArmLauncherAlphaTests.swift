import XCTest
@testable import FineWinePatcher

/// Guards the load command added to CrossOver ARM's winemac.so for the launcher-alpha library.
/// A wrong header edit would stop every window from opening, not just the launcher's.
final class ArmLauncherAlphaTests: XCTestCase {

    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("fw-alpha-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    private func put(_ bytes: inout [UInt8], _ offset: Int, _ value: UInt32) {
        for index in 0..<4 { bytes[offset + index] = UInt8((value >> (8 * UInt32(index))) & 0xff) }
    }

    private func word(_ bytes: [UInt8], _ offset: Int) -> UInt32 {
        (0..<4).reversed().reduce(UInt32(0)) { $0 << 8 | UInt32(bytes[offset + $1]) }
    }

    /// A 64-bit Mach-O header with one LC_SEGMENT_64 holding one section at `firstSection`,
    /// optionally followed by an LC_CODE_SIGNATURE.
    private func machO(firstSection: Int = 0x1000, signed: Bool = false) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: firstSection + 16)
        put(&bytes, 0, 0xfeedfacf)
        put(&bytes, 4, 0x0100000c)                 // CPU_TYPE_ARM64
        put(&bytes, 12, 6)                         // MH_DYLIB
        let segment = 32, segmentSize = 72 + 80
        put(&bytes, segment, 0x19)
        put(&bytes, segment + 4, UInt32(segmentSize))
        put(&bytes, segment + 64, 1)               // nsects
        put(&bytes, segment + 72 + 48, UInt32(firstSection))
        var commands = 1, size = segmentSize
        if signed {
            put(&bytes, segment + segmentSize, 0x1d)
            put(&bytes, segment + segmentSize + 4, 16)
            commands += 1; size += 16
        }
        put(&bytes, 16, UInt32(commands))
        put(&bytes, 20, UInt32(size))
        return bytes
    }

    func testAddsALoadDylibCommandInThePadding() throws {
        let original = machO()
        let edited = [UInt8](try ArmLauncherAlpha.addLoadCommand(to: Data(original)))
        XCTAssertEqual(edited.count, original.count, "nothing after the header may move")
        XCTAssertEqual(word(edited, 16), 2)
        let command = 32 + 152
        XCTAssertEqual(word(edited, command), 0xc)
        XCTAssertEqual(word(edited, 20), 152 + word(edited, command + 4))
        let name = String(decoding: edited[(command + 24)...].prefix { $0 != 0 }, as: UTF8.self)
        XCTAssertEqual(name, ArmLauncherAlpha.libraryName)
        XCTAssertTrue(ArmLauncherAlpha.hasLoadCommand(in: Data(edited)))
        XCTAssertFalse(ArmLauncherAlpha.hasLoadCommand(in: Data(original)))
    }

    func testAddingTwiceChangesNothing() throws {
        let once = try ArmLauncherAlpha.addLoadCommand(to: Data(machO()))
        XCTAssertEqual(try ArmLauncherAlpha.addLoadCommand(to: once), once)
    }

    func testRefusesWithoutRoom() {
        XCTAssertThrowsError(try ArmLauncherAlpha.addLoadCommand(to: Data(machO(firstSection: 32 + 152 + 40))))
    }

    func testRefusesASignedFile() {
        XCTAssertThrowsError(try ArmLauncherAlpha.addLoadCommand(to: Data(machO(signed: true))))
    }

    /// The whole edit against the real winemac.so when CrossOver ARM is installed: the result must
    /// list the library and carry a valid signature.
    func testEditsTheRealWinemac() throws {
        let apps = ["CrossOver Preview ARM.app", "CrossOver ARM Preview.app"]
        guard let source = apps.map({
            URL(fileURLWithPath: "/Applications/\($0)/Contents/SharedSupport/CrossOver/\(ArmLauncherAlpha.winemacSubpath)")
        }).first(where: { FileManager.default.fileExists(atPath: $0.path) }) else {
            throw XCTSkip("CrossOver ARM isn't installed.")
        }
        let cxr = tempDir.appendingPathComponent("CrossOver", isDirectory: true)
        let winemac = cxr.appendingPathComponent(ArmLauncherAlpha.winemacSubpath)
        try FileManager.default.createDirectory(at: winemac.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: source, to: winemac)
        FileManager.default.createFile(atPath: winemac.deletingLastPathComponent()
            .appendingPathComponent("fwalpha.dylib").path, contents: Data())

        try ArmLauncherAlpha.apply(toCrossOverRoot: cxr) { url in
            XCTAssertEqual(try self.tool("/usr/bin/codesign", ["--force", "--sign", "-", url.path]).status, 0)
        }

        XCTAssertTrue(ArmLauncherAlpha.isApplied(inCrossOverRoot: cxr))
        XCTAssertTrue(try tool("/usr/bin/otool", ["-L", winemac.path]).output.contains(ArmLauncherAlpha.libraryName))
        XCTAssertEqual(try tool("/usr/bin/codesign", ["--verify", winemac.path]).status, 0)
        // A second run is a no-op.
        try ArmLauncherAlpha.apply(toCrossOverRoot: cxr) { _ in XCTFail("signed again") }
    }

    private func tool(_ path: String, _ arguments: [String]) throws -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        return (process.terminationStatus, output)
    }
}
