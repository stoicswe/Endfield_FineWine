import XCTest
@testable import FineWinePatcher

final class GPTKSourceTests: XCTestCase {

    func testDirectFolderDetection() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let redist = tempDir.appendingPathComponent("redist/lib/external", isDirectory: true)
        try FileManager.default.createDirectory(at: redist, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        // Create dummy files
        FileManager.default.createFile(atPath: redist.appendingPathComponent("libd3dshared.dylib").path, contents: Data())
        let fw = redist.appendingPathComponent("D3DMetal.framework/Resources", isDirectory: true)
        try FileManager.default.createDirectory(at: fw, withIntermediateDirectories: true)
        let plistContent = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>CFBundleShortVersionString</key>
            <string>4.0b2</string>
        </dict>
        </plist>
        """.data(using: .utf8)!
        FileManager.default.createFile(atPath: fw.appendingPathComponent("Info.plist").path, contents: plistContent)

        // Resolve from parent root
        let resolved = GPTKSource.resolve(from: tempDir)
        XCTAssertNotNil(resolved)
        XCTAssertEqual(resolved?.version, "4.0b2")
        XCTAssertTrue(resolved?.isVersion4 == true)

        // Resolve directly from redist folder
        let resolvedDirect = GPTKSource.resolve(from: redist)
        XCTAssertNotNil(resolvedDirect)
        XCTAssertEqual(resolvedDirect?.version, "4.0b2")
    }

    func testDetectMountedDoesNotCrash() {
        let sources = GPTKSource.detectMounted()
        // If the user has Game Porting Toolkit or Evaluation environment mounted, it should find it
        if FileManager.default.fileExists(atPath: "/Volumes/Game Porting Toolkit") ||
           FileManager.default.fileExists(atPath: "/Volumes/Evaluation environment for Windows games 4.0 beta 2") {
            XCTAssertFalse(sources.isEmpty, "Should find the loaded GPT disk")
            if let first = sources.first {
                XCTAssertTrue(first.isVersion4)
                XCTAssertTrue(first.version?.hasPrefix("4.0") == true,
                              "Expected a GPTK 4.x version, got \(first.version ?? "nil")")
            }
        }
    }

    /// Builds `<root>/redist/lib/external` with a D3DMetal of `version`, plus the DLL glue in
    /// `redist/lib/wine` when `glue` is set.
    private func makeRedist(version: String, glue: Bool) throws -> (root: URL, external: URL) {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let external = root.appendingPathComponent("redist/lib/external", isDirectory: true)
        let resources = external.appendingPathComponent("D3DMetal.framework/Resources", isDirectory: true)
        try fm.createDirectory(at: resources, withIntermediateDirectories: true)
        fm.createFile(atPath: external.appendingPathComponent("libd3dshared.dylib").path, contents: Data("lib".utf8))
        try PropertyListSerialization.data(fromPropertyList: ["CFBundleShortVersionString": version], format: .xml, options: 0)
            .write(to: resources.appendingPathComponent("Info.plist"))
        if glue {
            let windows = root.appendingPathComponent("redist/lib/wine/x86_64-windows", isDirectory: true)
            try fm.createDirectory(at: windows, withIntermediateDirectories: true)
            for dll in ["d3d11.dll", "dxgi.dll", "nvngx.dll"] {
                fm.createFile(atPath: windows.appendingPathComponent(dll).path, contents: Data("new \(dll)".utf8))
            }
        }
        return (root, external)
    }

    func testOnlyOlderD3DMetalRunsOnTheStockGlue() throws {
        for (version, needs) in [("3.0", false), ("4.0b1", false), ("4.0b2", false),
                                 ("4.0b3", true), ("4.0", true), ("4.1b1", true), ("4.0b20", true)] {
            let (root, external) = try makeRedist(version: version, glue: false)
            defer { try? FileManager.default.removeItem(at: root) }
            let source = try XCTUnwrap(GPTKSource(url: external))
            XCTAssertEqual(source.needsMatchingGlue, needs, version)
            XCTAssertEqual(source.installProblem != nil, needs, version)
        }
    }

    func testGlueNextToTheRedistIsFoundAndAllowsNewerD3DMetal() throws {
        let (root, external) = try makeRedist(version: "4.0b3", glue: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try XCTUnwrap(GPTKSource.resolve(from: root))
        XCTAssertEqual(source.glue?.lastPathComponent, "wine")
        XCTAssertTrue(source.needsMatchingGlue)
        XCTAssertNil(source.installProblem)
        XCTAssertEqual(source.url.standardizedFileURL, external.standardizedFileURL)
    }

    func testCrossOverAppIsAcceptedAsASource() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? fm.removeItem(at: root) }
        let (redistRoot, _) = try makeRedist(version: "4.0b3", glue: true)
        defer { try? fm.removeItem(at: redistRoot) }
        let gptk = root.appendingPathComponent("CrossOver 27.app/Contents/SharedSupport/CrossOver/lib/apple_gptk", isDirectory: true)
        try fm.createDirectory(at: gptk.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.copyItem(at: redistRoot.appendingPathComponent("redist/lib"), to: gptk)
        let source = try XCTUnwrap(GPTKSource.resolve(from: root.appendingPathComponent("CrossOver 27.app")))
        XCTAssertNotNil(source.glue)
        XCTAssertEqual(source.volumeName, "CrossOver 27")
    }

    func testInstallGlueReplacesTheStockDLLsAndLinksTheUnixHalves() throws {
        let fm = FileManager.default
        let (root, _) = try makeRedist(version: "4.0b3", glue: true)
        defer { try? fm.removeItem(at: root) }
        // CrossOver 26.3's apple_gptk: the 3.0 glue with its own set of DLLs.
        let prefix = root.appendingPathComponent("app/apple_gptk", isDirectory: true)
        let stock = prefix.appendingPathComponent("wine/x86_64-windows", isDirectory: true)
        try fm.createDirectory(at: stock, withIntermediateDirectories: true)
        try fm.createDirectory(at: prefix.appendingPathComponent("wine/x86_64-unix"), withIntermediateDirectories: true)
        for dll in ["d3d11.dll", "dxgi.dll", "atidxx64.dll"] {
            fm.createFile(atPath: stock.appendingPathComponent(dll).path, contents: Data("old".utf8))
        }

        try PatcherEngine.installGlue(root.appendingPathComponent("redist/lib/wine"), into: prefix)

        let wine = prefix.appendingPathComponent("wine")
        XCTAssertEqual(try fm.contentsOfDirectory(atPath: wine.appendingPathComponent("x86_64-windows").path).sorted(),
                       ["d3d11.dll", "dxgi.dll", "nvngx.dll"])
        XCTAssertEqual(try String(contentsOf: wine.appendingPathComponent("x86_64-windows/d3d11.dll"), encoding: .utf8), "new d3d11.dll")
        XCTAssertEqual(try fm.destinationOfSymbolicLink(atPath: wine.appendingPathComponent("x86_64-unix/d3d11.so").path),
                       "../../external/libd3dshared.dylib")
        XCTAssertTrue(fm.fileExists(atPath: prefix.appendingPathComponent("wine.cxorig/x86_64-windows/atidxx64.dll").path))

        // A second run with the same glue leaves the backup of CrossOver's own DLLs alone.
        try PatcherEngine.installGlue(root.appendingPathComponent("redist/lib/wine"), into: prefix)
        XCTAssertTrue(fm.fileExists(atPath: prefix.appendingPathComponent("wine.cxorig/x86_64-windows/atidxx64.dll").path))
    }
}
