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
}
