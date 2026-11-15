import XCTest
@testable import FineWineCore

/// A minimal 64-bit Windows executable with nothing in it but an import table.
enum ImportingPE {
    static func make(imports: [String], delayImports: [String] = []) -> Data {
        var file = [UInt8](repeating: 0, count: 0x600)
        func put(_ bytes: [UInt8], at offset: Int) { file.replaceSubrange(offset..<offset + bytes.count, with: bytes) }
        let pe = 0x80, optional = pe + 24, sections = optional + 240
        put([0x4D, 0x5A], at: 0)                       // "MZ"
        put(Bytes.le32(pe), at: 0x3C)
        put([0x50, 0x45, 0, 0], at: pe)                // "PE\0\0"
        put(Bytes.le16(0x8664), at: pe + 4)            // x64
        put(Bytes.le16(1), at: pe + 6)                 // one section
        put(Bytes.le16(240), at: pe + 20)              // size of the optional header
        put(Bytes.le16(0x20B), at: optional)           // 64-bit
        // One section: file offset 0x200, address 0x1000, 0x400 bytes.
        put(Bytes.le32(0x400), at: sections + 8); put(Bytes.le32(0x1000), at: sections + 12)
        put(Bytes.le32(0x400), at: sections + 16); put(Bytes.le32(0x200), at: sections + 20)

        var names = 0x1200                              // where the next name goes, as an address
        func name(_ s: String) -> Int {
            let at = names
            put(Array(s.utf8) + [0], at: 0x200 + (at - 0x1000))
            names += s.utf8.count + 1
            return at
        }
        // Import table at 0x1000: 20-byte entries, the name's address at +12.
        put(Bytes.le32(0x1000), at: optional + 112 + 1 * 8)
        for (i, dll) in imports.enumerated() { put(Bytes.le32(name(dll)), at: 0x200 + i * 20 + 12) }
        // Delay-import table at 0x1100: 32-byte entries, the name's address at +4.
        if !delayImports.isEmpty {
            put(Bytes.le32(0x1100), at: optional + 112 + 13 * 8)
            for (i, dll) in delayImports.enumerated() { put(Bytes.le32(name(dll)), at: 0x300 + i * 32 + 4) }
        }
        return Data(file)
    }
}

final class PEImportsTests: XCTestCase {
    func testReadsImportAndDelayImportTables() {
        let data = ImportingPE.make(imports: ["KERNEL32.dll", "D3D11.dll"], delayImports: ["dxgi.dll"])
        XCTAssertEqual(PEImports.importedDLLs(in: data), ["kernel32.dll", "d3d11.dll", "dxgi.dll"])
    }

    func testAProgramWithoutARenderingAPIIsNotAGame() {
        let sandbox = Sandbox()
        let plain = sandbox.root.appendingPathComponent("tool.exe"), game = sandbox.root.appendingPathComponent("game.exe")
        sandbox.write(ImportingPE.make(imports: ["KERNEL32.dll", "USER32.dll"]), to: plain)
        sandbox.write(ImportingPE.make(imports: ["KERNEL32.dll", "vulkan-1.dll"]), to: game)
        XCTAssertFalse(PEImports.usesRenderingAPI(at: plain))
        XCTAssertTrue(PEImports.usesRenderingAPI(at: game))
        for dll in ["d3d9.dll", "d3d11.dll", "d3d12.dll", "dxgi.dll", "vulkan-1.dll", "opengl32.dll"] {
            XCTAssertTrue(PEImports.renderingDLLs.contains(dll), dll)
        }
    }

    func testGarbageIsNotAnExecutable() {
        XCTAssertEqual(PEImports.importedDLLs(in: Data()), [])
        XCTAssertEqual(PEImports.importedDLLs(in: Data("not a program at all".utf8)), [])
        XCTAssertEqual(PEImports.importedDLLs(in: Data([0x4D, 0x5A] + [UInt8](repeating: 0xFF, count: 200))), [])
        XCTAssertFalse(PEImports.usesRenderingAPI(at: URL(fileURLWithPath: "/nonexistent/thing.exe")))
    }
}

final class GameModeLaunchTests: XCTestCase {
    private struct Fixture {
        let sandbox = Sandbox()
        var runtime: WineRuntime
        var prefix: Prefix
        let program = Program(name: "Game", windowsPath: #"C:\Game\Game.exe"#)

        init(gameLoader: Bool = true, imports: [String] = ["KERNEL32.dll", "d3d11.dll"]) {
            let root = sandbox.makeRuntime()
            if gameLoader {
                let loader = root.appendingPathComponent("lib/wine/aarch64-unix/FineWine Game.app/Contents/MacOS/wine-game")
                sandbox.write(Data("#!/bin/sh\nexit 0\n".utf8), to: loader)
                try! FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: loader.path)
            }
            runtime = WineRuntime(manifest: RuntimeManifest(id: "r", name: "R", version: "1", wineVersion: "11.21"), root: root, kind: .managed)
            let dir = sandbox.root.appendingPathComponent("pfx")
            prefix = Prefix(metadata: PrefixMetadata(name: "P", runtimeID: "r"), directory: dir)
            sandbox.write(ImportingPE.make(imports: imports), to: dir.appendingPathComponent("drive_c/Game/Game.exe"))
        }

        var planner: LaunchPlanner { LaunchPlanner(runtime: runtime, prefix: prefix, profile: nil, baseEnvironment: ["PATH": "/usr/bin"]) }
    }

    func testAProgramThatImportsDirect3DRunsWithTheGameLoader() throws {
        let f = Fixture()
        let env = try f.planner.plan(for: f.program).environment
        XCTAssertEqual(env["FINEWINE_LOADER"], WineRuntime.gameLoaderName)
        XCTAssertEqual(env["FINEWINE_GAME_MARKER"], f.planner.gameMarker(for: f.program).path)
        XCTAssertTrue(f.planner.gameMarker(for: f.program).path.hasPrefix(f.prefix.directory.path), "the marker belongs to the prefix")
    }

    func testAProgramThatDoesNotRenderIsLearnedFromItsMarker() throws {
        let f = Fixture(imports: ["KERNEL32.dll", "USER32.dll"])       // a launcher, say
        var env = try f.planner.plan(for: f.program).environment
        XCTAssertNil(env["FINEWINE_LOADER"], "nothing says it is a game yet")
        XCTAssertNotNil(env["FINEWINE_GAME_MARKER"], "but the runtime is told where to say so")

        // The runtime creates the marker when the program, or the game it starts, first renders.
        f.sandbox.write(Data(), to: f.planner.gameMarker(for: f.program))
        env = try f.planner.plan(for: f.program).environment
        XCTAssertEqual(env["FINEWINE_LOADER"], WineRuntime.gameLoaderName, "from then on it runs as a game")
    }

    func testGameModeOffOrARuntimeWithoutTheLoaderChangesNothing() throws {
        var f = Fixture()
        f.prefix.metadata.settings.gameMode = false
        var env = try f.planner.plan(for: f.program).environment
        XCTAssertNil(env["FINEWINE_LOADER"]); XCTAssertNil(env["FINEWINE_GAME_MARKER"])

        let old = Fixture(gameLoader: false)
        XCTAssertFalse(old.runtime.hasGameLoader)
        env = try old.planner.plan(for: old.program).environment
        XCTAssertNil(env["FINEWINE_LOADER"]); XCTAssertNil(env["FINEWINE_GAME_MARKER"])
    }

    func testOnlyProgramsGetIt() throws {
        let f = Fixture()
        XCTAssertNil(try f.planner.plan(for: WineTool.winecfg).environment["FINEWINE_LOADER"])
        XCTAssertNil(try f.planner.plan(for: WinebootAction.initialize).environment["FINEWINE_LOADER"])
    }

    func testTheProgramsOwnVariablesWin() throws {
        let f = Fixture()
        var program = f.program
        program.environment = [EnvironmentVariable(name: "FINEWINE_LOADER", value: "wine")]
        XCTAssertEqual(try f.planner.plan(for: program).environment["FINEWINE_LOADER"], "wine")
    }
}
