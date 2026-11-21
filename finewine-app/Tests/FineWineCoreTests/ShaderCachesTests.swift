import XCTest
@testable import FineWineCore

final class ShaderCachesTests: XCTestCase {
    func testOnlyAChangeOfWhatDrawsDirect3DClearsThem() {
        var old = PrefixSettings(), new = PrefixSettings()
        XCTAssertFalse(ShaderCaches.rendererChanged(from: old, to: new))
        XCTAssertFalse(ShaderCaches.rendererChanged(from: nil, to: new), "a prefix that was never applied has nothing cached")
        new.metalHUD = true
        XCTAssertFalse(ShaderCaches.rendererChanged(from: old, to: new), "another setting")
        new.legacyDirect3DOnVulkan = true
        XCTAssertTrue(ShaderCaches.rendererChanged(from: old, to: new), "Direct3D 9 to Vulkan")
        XCTAssertTrue(ShaderCaches.rendererChanged(from: new, to: old), "and back")
        old = PrefixSettings(); new = PrefixSettings(); new.graphicsBackend = .wined3d
        XCTAssertTrue(ShaderCaches.rendererChanged(from: old, to: new), "another backend for Direct3D 10 and 11")
    }

    func testClearingRemovesTheCachesOfThePrefixsProgramsAndMetals() throws {
        let sandbox = Sandbox(), fm = FileManager.default
        let system = sandbox.root.appendingPathComponent("cache")
        let dir = sandbox.root.appendingPathComponent("pfx")
        try fm.createDirectory(at: dir.appendingPathComponent("drive_c/Game"), withIntermediateDirectories: true)
        var metadata = PrefixMetadata(name: "P", runtimeID: "r")
        metadata.programs = [Program(name: "Game", windowsPath: #"C:\Game\Game.exe"#)]
        let prefix = Prefix(metadata: metadata, directory: dir)

        let dxvkInPrefix = ShaderCaches.dxvkDirectory(inPrefix: dir).appendingPathComponent("Game.dxvk-cache")
        let dxvkBesideTheGame = dir.appendingPathComponent("drive_c/Game/Game.dxvk-cache")
        let dxmt = system.appendingPathComponent("dxmt/Game.exe/shaders_320.db")
        let metal = system.appendingPathComponent("org.finewine.game/com.apple.metal/1/functions.data")
        // What must stay: another game's DXMT cache, another program's Metal cache, the game.
        let otherDXMT = system.appendingPathComponent("dxmt/Other.exe/shaders_320.db")
        let otherMetal = system.appendingPathComponent("com.apple.finder/com.apple.metal/1/functions.data")
        let game = dir.appendingPathComponent("drive_c/Game/Game.exe")
        for file in [dxvkInPrefix, dxvkBesideTheGame, dxmt, metal, otherDXMT, otherMetal, game] { sandbox.write("x", to: file) }

        let removed = ShaderCaches(systemCacheDirectory: system).clear(for: prefix)
        XCTAssertEqual(removed.count, 4)
        for gone in [dxvkInPrefix, dxvkBesideTheGame, dxmt, metal] {
            XCTAssertFalse(fm.fileExists(atPath: gone.path), gone.path)
        }
        for kept in [otherDXMT, otherMetal, game] {
            XCTAssertTrue(fm.fileExists(atPath: kept.path), kept.path)
        }

        // Without the system folder (a service that was not given it) only the prefix's own go.
        for file in [dxvkInPrefix, dxmt] { sandbox.write("x", to: file) }
        ShaderCaches(systemCacheDirectory: nil).clear(for: prefix)
        XCTAssertFalse(fm.fileExists(atPath: dxvkInPrefix.path))
        XCTAssertTrue(fm.fileExists(atPath: dxmt.path))
    }
}
