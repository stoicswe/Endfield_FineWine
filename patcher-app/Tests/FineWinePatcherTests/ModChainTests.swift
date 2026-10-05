import XCTest
@testable import FineWinePatcher

/// Exercises the mod (EFMI) chain ini-editing logic — the same rules the shell implementation
/// (scripts/swap-into-crossover.sh's mod-chain step) verifies byte-exactly on the real EFMI
/// d3dx.ini: keep everything outside [System] untouched, keep the commented example, end up with
/// exactly one active proxy_d3d11, survive re-runs, revert byte-identically, and preserve CRLF.
final class ModChainTests: XCTestCase {

    // A trimmed-down stand-in for EFMI's d3dx.ini that has the same shape where it matters:
    // a [Loader] section before [System], the commented proxy examples inside [System], and
    // other keys that must survive untouched.
    private let sampleINI = """
    [Loader]
    target = Endfield.exe
    loader = XXMI Launcher.exe
    module = d3d11.dll

    [System]
    screen_width = 1920
    screen_height = 1080

    ;proxy_d3d9=d3d9_helix.dll
    ;proxy_d3d11=d3d11_helix.dll

    dll_initialization_delay = 0
    load_library_redirect = 2

    [Device]
    full_screen = 0
    hide_cursor = 0
    """

    private let target = "Z:\\Applications\\CrossOver_Endfield_Patch.app\\Contents\\SharedSupport\\CrossOver\\lib\\dxmt\\x86_64-windows\\d3d11.dll"

    private var workDir: URL!
    private var ini: URL!

    override func setUpWithError() throws {
        workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("finewine-modchain-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
        ini = workDir.appendingPathComponent("d3dx.ini")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: workDir)
    }

    private func write(_ text: String) throws {
        try text.data(using: .utf8)!.write(to: ini)
    }

    private func read() throws -> String {
        try String(contentsOf: ini, encoding: .utf8)
    }

    private func toCRLF(_ data: Data) -> Data {
        var out: [UInt8] = []
        for byte in data {
            if byte == 10 { out.append(contentsOf: [13, 10]) } else { out.append(byte) }
        }
        return Data(out)
    }

    // MARK: - apply

    func testApplyKeepsCommentedExampleAndInsertsAfterIt() throws {
        try write(sampleINI)
        let replaced = try ModChain.applyChainToIni(ini, target: target, backend: "dxmt", shortHash: "abcd1234efgh")
        XCTAssertNil(replaced)
        let text = try read()
        XCTAssert(text.contains(";proxy_d3d11=d3d11_helix.dll\n"))
        XCTAssert(text.contains("proxy_d3d11 = \(target)\n"))
        XCTAssert(text.contains("FineWine chain: backend=dxmt"))
        // the rest of [System] and the other sections survive
        XCTAssert(text.contains("load_library_redirect = 2"))
        XCTAssert(text.contains("dll_initialization_delay = 0"))
        XCTAssert(text.contains("[Device]\nfull_screen = 0"))
        XCTAssert(text.contains("[Loader]\ntarget = Endfield.exe"))
    }

    func testApplyIsIdempotent() throws {
        try write(sampleINI)
        _ = try ModChain.applyChainToIni(ini, target: target, backend: "dxmt", shortHash: "abcd1234efgh")
        let once = try read()
        _ = try ModChain.applyChainToIni(ini, target: target, backend: "dxmt", shortHash: "abcd1234efgh")
        let twice = try read()
        XCTAssertEqual(once, twice)
        // exactly one active proxy_d3d11 line
        XCTAssertEqual(once.components(separatedBy: "\n").filter {
            $0.trimmingCharacters(in: .whitespaces).hasPrefix("proxy_d3d11 ")
        }.count, 1)
    }

    func testApplyReplacesAUserChainAndReportsIt() throws {
        let userLine = "proxy_d3d11 = C:\\some\\user\\chain.dll"
        try write(sampleINI.replacingOccurrences(
            of: ";proxy_d3d11=d3d11_helix.dll",
            with: ";proxy_d3d11=d3d11_helix.dll\n\(userLine)"))
        let replaced = try ModChain.applyChainToIni(ini, target: target, backend: "dxmt", shortHash: "abcd1234efgh")
        XCTAssertEqual(replaced, userLine)
        let text = try read()
        XCTAssert(text.contains("proxy_d3d11 = \(target)"))
        XCTAssertFalse(text.contains(userLine))
        // and exactly one active line, ours
        XCTAssertEqual(text.components(separatedBy: "\n").filter {
            $0.trimmingCharacters(in: .whitespaces).hasPrefix("proxy_d3d11 ")
        }.count, 1)
    }

    func testApplyWithoutSystemSectionFails() throws {
        try write("[Loader]\ntarget = Endfield.exe\n")
        XCTAssertThrowsError(try ModChain.applyChainToIni(ini, target: target, backend: "dxmt", shortHash: "abcd1234efgh"))
    }

    // MARK: - revert

    func testRevertIsByteIdentical() throws {
        try write(sampleINI)
        let original = try read()
        _ = try ModChain.applyChainToIni(ini, target: target, backend: "dxmt", shortHash: "abcd1234efgh")
        try text2State(originalLine: nil)
        try ModChain.revert(importerDir: workDir)
        XCTAssertEqual(try read(), original)
    }

    func testRevertRestoresAReplacedUserChain() throws {
        let userLine = "proxy_d3d11 = C:\\some\\user\\chain.dll"
        try write(sampleINI.replacingOccurrences(
            of: ";proxy_d3d11=d3d11_helix.dll",
            with: ";proxy_d3d11=d3d11_helix.dll\n\(userLine)"))
        let before = try read()
        let replaced = try ModChain.applyChainToIni(ini, target: target, backend: "dxmt", shortHash: "abcd1234efgh")
        XCTAssertEqual(replaced, userLine)
        try text2State(originalLine: replaced)
        try ModChain.revert(importerDir: workDir)
        XCTAssertEqual(try read(), before)
    }

    /// Simulate what PatcherEngine's apply step records in the state file.
    private func text2State(originalLine: String?) throws {
        var state = "backend = dxmt\nmode = path\ntarget = \(target)\n"
        if let originalLine { state += "replaced_line = \(originalLine)\n" }
        try state.data(using: .utf8)!.write(to: workDir.appendingPathComponent(ModChain.stateFileName))
    }

    // MARK: - CRLF

    func testCRLFFileKeepsItsLineEndings() throws {
        try toCRLF(sampleINI.data(using: .utf8)!).write(to: ini)
        let crlfOriginal = try Data(contentsOf: ini)
        _ = try ModChain.applyChainToIni(ini, target: target, backend: "dxmt", shortHash: "abcd1234efgh")
        let applied = try Data(contentsOf: ini)
        // no bare LF line after a CR — i.e. every line ending is still CRLF
        XCTAssertFalse(applied.contains(Data([13, 10, 10])))
        XCTAssert(applied.contains(Data("proxy_d3d11 = \(target)\r\n".utf8)))
        try text2State(originalLine: nil)
        try ModChain.revert(importerDir: workDir)
        XCTAssertEqual(try Data(contentsOf: ini), crlfOriginal)
    }

    // MARK: - backend parsing

    func testBackendParsingPrefersTheActiveBackend() {
        let conf = """
        "DXMT_ENABLE_NVEXT" = "1"
        "CX_GRAPHICS_BACKEND" = "d3dmetal"
        "CX_ACTIVE_GRAPHICS_BACKEND" = "dxmt"
        "WINEMSYNC" = "0"
        """
        XCTAssertEqual(ChainBackend.fromBottleConf(conf), .dxmt)
        XCTAssertEqual(ChainBackend.fromBottleConf("\"CX_GRAPHICS_BACKEND\" = \"dxvk\"\n"), .dxvk)
        XCTAssertNil(ChainBackend.fromBottleConf("\"WINEMSYNC\" = \"0\"\n"))   // wined3d: no chain
    }

    func testBackendSubpaths() {
        XCTAssertEqual(ChainBackend.d3dmetal.crossoverSubpath,
                       "lib64/apple_gptk/wine/x86_64-windows/d3d11.dll")
        XCTAssertEqual(ChainBackend.dxmt.crossoverSubpath, "lib/dxmt/x86_64-windows/d3d11.dll")
        XCTAssertEqual(ChainBackend.dxvk.crossoverSubpath, "lib/dxvk/x86_64-windows/d3d11.dll")
    }
}
