import XCTest
@testable import FineWineCore

final class RuntimeTests: XCTestCase {
    func testCompleteRuntimeIsUsable() {
        let sandbox = Sandbox()
        let root = sandbox.makeRuntime()
        let runtime = WineRuntime(manifest: RuntimeStore.inferredManifest(for: root), root: root, kind: .external)
        XCTAssertEqual(runtime.problems(), [])
        XCTAssertEqual(runtime.wineBinary?.lastPathComponent, "wine")
        XCTAssertEqual(runtime.wineserverBinary?.lastPathComponent, "wineserver")
    }

    func testMissingPiecesAreReported() {
        let sandbox = Sandbox()
        let root = sandbox.makeRuntime(wine: false, server: false)
        try! FileManager.default.removeItem(at: root.appendingPathComponent("lib"))
        let runtime = WineRuntime(manifest: RuntimeStore.inferredManifest(for: root), root: root, kind: .external)
        XCTAssertEqual(runtime.problems().count, 3)
        XCTAssertFalse(runtime.isUsable)
    }

    func testNonExecutableWineDoesNotCount() {
        let sandbox = Sandbox()
        let root = sandbox.makeRuntime()
        try! FileManager.default.setAttributes([.posixPermissions: 0o644],
                                               ofItemAtPath: root.appendingPathComponent("bin/wine").path)
        let runtime = WineRuntime(manifest: RuntimeStore.inferredManifest(for: root), root: root, kind: .external)
        XCTAssertNil(runtime.wineBinary)
    }

    func testAlternateBinaryNames() {
        let sandbox = Sandbox()
        let root = sandbox.makeRuntime(wine: false, server: false)
        for name in ["wine64", "wineserver-arm64"] {
            let file = root.appendingPathComponent("bin/\(name)")
            try! Data("#!/bin/sh\n".utf8).write(to: file)
            try! FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
        }
        let runtime = WineRuntime(manifest: RuntimeStore.inferredManifest(for: root), root: root, kind: .external)
        XCTAssertEqual(runtime.wineBinary?.lastPathComponent, "wine64")
        XCTAssertEqual(runtime.wineserverBinary?.lastPathComponent, "wineserver-arm64")
    }

    func testManifestDecodingFillsDefaults() throws {
        let manifest = try JSONDecoder().decode(RuntimeManifest.self, from: Data(#"{"id":"fw-1"}"#.utf8))
        XCTAssertEqual(manifest.name, "fw-1")
        XCTAssertEqual(manifest.architecture, "arm64")
        XCTAssertEqual(manifest.graphics, [:])
    }

    func testManifestRequiresAnID() {
        XCTAssertThrowsError(try JSONDecoder().decode(RuntimeManifest.self, from: Data(#"{"name":"x"}"#.utf8)))
    }

    func testGraphicsSpecLookup() {
        let spec = GraphicsBackendSpec(dllPath: "lib/dxmt", overrides: ["d3d11": "n,b"])
        let manifest = RuntimeManifest(id: "r", name: "R", version: "1", wineVersion: "11.21", graphics: ["dxmt": spec])
        let runtime = WineRuntime(manifest: manifest, root: URL(fileURLWithPath: "/r"), kind: .managed)
        XCTAssertEqual(runtime.graphicsSpec(for: .dxmt), spec)
        XCTAssertNil(runtime.graphicsSpec(for: .dxvk))
    }
}

final class RuntimeStoreTests: XCTestCase {
    func testEmptyStoreListsNothing() {
        XCTAssertEqual(RuntimeStore(paths: Sandbox().paths).list(), [])
    }

    func testInstallManagedCopiesAndLists() throws {
        let sandbox = Sandbox()
        let store = RuntimeStore(paths: sandbox.paths)
        let source = sandbox.makeRuntime(manifest: RuntimeManifest(id: "finewine-1.0", name: "FineWine 1.0",
                                                                   version: "1.0", wineVersion: "11.21"))
        let installed = try store.installManaged(from: source)
        XCTAssertEqual(installed.root.path, sandbox.paths.runtimes.appendingPathComponent("finewine-1.0").path)
        XCTAssertEqual(installed.kind, .managed)
        XCTAssertTrue(installed.isUsable)
        XCTAssertEqual(store.list().map(\.id), ["finewine-1.0"])
        XCTAssertEqual(store.runtime(id: "finewine-1.0")?.manifest.wineVersion, "11.21")
    }

    func testInstallReplacesTheSameID() throws {
        let sandbox = Sandbox()
        let store = RuntimeStore(paths: sandbox.paths)
        let first = sandbox.makeRuntime(manifest: RuntimeManifest(id: "r", name: "Old", version: "1", wineVersion: "11"))
        let second = sandbox.makeRuntime(manifest: RuntimeManifest(id: "r", name: "New", version: "2", wineVersion: "11"))
        try store.installManaged(from: first)
        try store.installManaged(from: second)
        XCTAssertEqual(store.list().map(\.name), ["New"])
        // No staging folders left behind.
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: sandbox.paths.runtimes.path)
        XCTAssertEqual(leftovers, ["r"])
    }

    func testInstallRejectsFoldersWithoutManifestOrWithUnsafeIDs() {
        let sandbox = Sandbox()
        let store = RuntimeStore(paths: sandbox.paths)
        XCTAssertThrowsError(try store.installManaged(from: sandbox.makeRuntime()))
        let evil = sandbox.makeRuntime(manifest: RuntimeManifest(id: "../escape", name: "x", version: "", wineVersion: ""))
        XCTAssertThrowsError(try store.installManaged(from: evil))
        XCTAssertFalse(FileManager.default.fileExists(atPath: sandbox.paths.root.appendingPathComponent("escape").path))
    }

    func testSafeIdentifiers() {
        XCTAssertTrue(RuntimeStore.isSafeIdentifier("finewine-11.21_r2"))
        for bad in ["", ".", "..", "a/b", "a b", "external:/x"] {
            XCTAssertFalse(RuntimeStore.isSafeIdentifier(bad), bad)
        }
    }

    func testRemoveManaged() throws {
        let sandbox = Sandbox()
        let store = RuntimeStore(paths: sandbox.paths)
        try store.installManaged(from: sandbox.makeRuntime(
            manifest: RuntimeManifest(id: "r", name: "R", version: "1", wineVersion: "11")))
        try store.removeManaged(id: "r")
        XCTAssertEqual(store.list(), [])
        XCTAssertNoThrow(try store.removeManaged(id: "r"))          // already gone
        XCTAssertThrowsError(try store.removeManaged(id: "../x"))
    }

    func testExternalRuntimesAreRememberedAndRemoved() throws {
        let sandbox = Sandbox()
        let store = RuntimeStore(paths: sandbox.paths)
        let root = sandbox.makeRuntime()
        let added = try store.addExternal(root)
        XCTAssertEqual(added.kind, .external)
        XCTAssertTrue(added.id.hasPrefix("external:"))
        try store.addExternal(root)                                  // adding twice keeps one entry
        XCTAssertEqual(store.list().count, 1)
        XCTAssertEqual(store.list().first?.name, root.lastPathComponent)
        try store.removeExternal(root)
        XCTAssertEqual(store.list(), [])
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.path), "removing must not delete the folder")
    }

    func testAddExternalRejectsFoldersThatAreNotWine() {
        let sandbox = Sandbox()
        let store = RuntimeStore(paths: sandbox.paths)
        XCTAssertThrowsError(try store.addExternal(sandbox.makeRuntime(wine: false))) { error in
            XCTAssertTrue(error.localizedDescription.contains("bin/wine"))
        }
        XCTAssertEqual(store.externalPaths(), [])
    }

    func testExternalRuntimeUsesItsManifestWhenPresent() throws {
        let sandbox = Sandbox()
        let store = RuntimeStore(paths: sandbox.paths)
        let root = sandbox.makeRuntime(manifest: RuntimeManifest(id: "dev", name: "Dev build", version: "0", wineVersion: "11.21"))
        XCTAssertEqual(try store.addExternal(root).id, "dev")
    }

    func testManagedListedBeforeExternal() throws {
        let sandbox = Sandbox()
        let store = RuntimeStore(paths: sandbox.paths)
        try store.addExternal(sandbox.makeRuntime())
        try store.installManaged(from: sandbox.makeRuntime(
            manifest: RuntimeManifest(id: "z", name: "Zed", version: "1", wineVersion: "11")))
        XCTAssertEqual(store.list().map(\.kind), [.managed, .external])
    }
}
