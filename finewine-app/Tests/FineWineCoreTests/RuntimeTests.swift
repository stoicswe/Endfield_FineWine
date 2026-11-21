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

    /// CrossOver's folder has bin/wine, bin/wineserver and lib/wine, but its wine is a script
    /// that only knows CrossOver's bottles.
    func testCrossOverIsNotARuntime() throws {
        let sandbox = Sandbox()
        let root = sandbox.makeRuntime()
        sandbox.write("#!/usr/bin/perl\n", to: root.appendingPathComponent("bin/cxbottle"))
        let runtime = WineRuntime(manifest: RuntimeStore.inferredManifest(for: root), root: root, kind: .external)
        XCTAssertTrue(runtime.isCrossOver)
        XCTAssertEqual(runtime.problems(), [tr("runtime_problem.crossover")])
        XCTAssertFalse(runtime.isUsable)

        let store = RuntimeStore(paths: sandbox.paths, bundledRoot: nil)
        XCTAssertThrowsError(try store.addExternal(root))
        XCTAssertEqual(store.externalPaths(), [])

        // by where it is, too: the folder inside the app
        let inApp = sandbox.makeRuntime(at: sandbox.root.appendingPathComponent("CrossOver.app/Contents/SharedSupport/CrossOver"))
        XCTAssertTrue(WineRuntime(manifest: RuntimeStore.inferredManifest(for: inApp), root: inApp, kind: .external).isCrossOver)
    }

    // MARK: Descriptions of other Wine builds (format 2)

    /// A folder with nothing but a runtime.json, describing a Wine build somewhere else.
    private func describedRuntime(_ sandbox: Sandbox, _ change: (inout RuntimeManifest, URL) -> Void = { _, _ in })
        -> (runtime: WineRuntime, build: URL) {
        let build = sandbox.root.appendingPathComponent("build-\(UUID().uuidString)", isDirectory: true)
        let fm = FileManager.default
        try! fm.createDirectory(at: build.appendingPathComponent("libexec"), withIntermediateDirectories: true)
        try! fm.createDirectory(at: build.appendingPathComponent("lib/wine"), withIntermediateDirectories: true)
        for name in ["loader", "server"] {
            let file = build.appendingPathComponent("libexec/\(name)")
            try! Data("#!/bin/sh\nexit 0\n".utf8).write(to: file)
            try! fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
        }
        var manifest = RuntimeManifest(id: "other-wine", name: "Other Wine", version: "1", wineVersion: "10.0",
                                       formatVersion: 2, root: build.path, loader: "libexec/loader",
                                       server: "libexec/server", libraryPath: ["lib", "lib64"],
                                       environment: ["OTHER_ROOT": "${root}/share", "OTHER_PREFIX": "${prefix}"],
                                       capabilities: ["msync"])
        change(&manifest, build)
        let folder = sandbox.root.appendingPathComponent("description-\(UUID().uuidString)", isDirectory: true)
        try! fm.createDirectory(at: folder, withIntermediateDirectories: true)
        try! JSONEncoder().encode(manifest).write(to: folder.appendingPathComponent(RuntimeStore.manifestName))
        let read = RuntimeStore.readManifest(in: folder)!
        return (WineRuntime(manifest: read, root: folder, kind: .external), build)
    }

    func testDescriptionOfABuildElsewhere() {
        let sandbox = Sandbox()
        let (runtime, build) = describedRuntime(sandbox)
        XCTAssertEqual(runtime.problems(), [])
        XCTAssertEqual(runtime.root.path, build.path)
        XCTAssertNotEqual(runtime.folder.path, build.path)
        XCTAssertEqual(runtime.wineBinary?.path, build.appendingPathComponent("libexec/loader").path)
        XCTAssertEqual(runtime.wineserverBinary?.path, build.appendingPathComponent("libexec/server").path)
        XCTAssertEqual(runtime.binDirectory.path, build.appendingPathComponent("libexec").path)
        XCTAssertEqual(runtime.libraryDirectories.map(\.lastPathComponent), ["lib", "lib64"])
        XCTAssertEqual(runtime.capabilities, [.msync])
        XCTAssertFalse(runtime.supports(.upscaling))
    }

    func testOldDescriptionsHaveEveryCapabilityAndPlainFoldersNone() {
        let sandbox = Sandbox()
        let old = sandbox.makeRuntime(manifest: RuntimeManifest(id: "fw", name: "FW", version: "1", wineVersion: "11.21"))
        let manifest = RuntimeStore.readManifest(in: old)!
        XCTAssertNil(manifest.capabilities)
        XCTAssertEqual(WineRuntime(manifest: manifest, root: old, kind: .managed).capabilities, Set(RuntimeCapability.allCases))
        let plain = sandbox.makeRuntime()
        XCTAssertEqual(WineRuntime(manifest: RuntimeStore.inferredManifest(for: plain), root: plain, kind: .external).capabilities, [])
    }

    func testDescriptionProblems() {
        let sandbox = Sandbox()
        XCTAssertEqual(describedRuntime(sandbox) { m, _ in m.formatVersion = 99 }.runtime.problems(),
                       [tr("runtime_problem.newer_format")])
        XCTAssertEqual(describedRuntime(sandbox) { m, _ in m.root = "/nowhere/at/all" }.runtime.problems(),
                       [tr("runtime_problem.root_missing", "/nowhere/at/all")])
        XCTAssertEqual(describedRuntime(sandbox) { m, _ in m.root = "relative/place" }.runtime.problems(),
                       [tr("runtime_problem.bad_path", "relative/place")])
        XCTAssertEqual(describedRuntime(sandbox) { m, _ in m.loader = "libexec/absent" }.runtime.problems(),
                       [tr("runtime_problem.named_missing", "libexec/absent")])
        XCTAssertTrue(describedRuntime(sandbox) { m, _ in m.loader = "../outside" }.runtime.problems()
            .contains(tr("runtime_problem.bad_path", "../outside")))
        XCTAssertEqual(describedRuntime(sandbox) { m, _ in m.environment = ["WINEPREFIX": "/x"] }.runtime.problems(),
                       [tr("runtime_problem.bad_variable", "WINEPREFIX")])
    }

    /// CrossOver's folder is refused by itself, and accepted once a description names the
    /// loader to start in it.
    func testCrossOverWithADescriptionThatNamesItsLoader() {
        let sandbox = Sandbox()
        let (runtime, _) = describedRuntime(sandbox) { m, build in
            sandbox.write("#!/usr/bin/perl\n", to: build.appendingPathComponent("bin/cxbottle"))
        }
        XCTAssertTrue(runtime.isCrossOver)
        XCTAssertEqual(runtime.problems(), [])
        var bare = runtime
        bare.manifest.loader = nil
        XCTAssertEqual(bare.problems(), [tr("runtime_problem.crossover")])
    }

    func testDescriptionIsInstalledAndRemovedWithoutTouchingTheBuild() throws {
        let sandbox = Sandbox()
        let (runtime, build) = describedRuntime(sandbox)
        let store = RuntimeStore(paths: sandbox.paths, bundledRoot: nil)
        let installed = try store.installManaged(from: runtime.folder)
        XCTAssertTrue(installed.isUsable)
        XCTAssertEqual(installed.root.path, build.path)
        try store.removeManaged(id: installed.id)
        XCTAssertTrue(FileManager.default.fileExists(atPath: build.appendingPathComponent("libexec/loader").path))

        // an unusable one is not installed
        let broken = describedRuntime(sandbox) { m, _ in m.id = "broken"; m.loader = "libexec/absent" }.runtime
        XCTAssertThrowsError(try store.installManaged(from: broken.folder))
        XCTAssertNil(store.runtime(id: "broken"))
    }

    func testLaunchPlanFollowsTheDescription() throws {
        let sandbox = Sandbox()
        let (runtime, build) = describedRuntime(sandbox) { m, _ in m.prefixSetup = ["setup-tool", "--into", "${prefix}"] }
        var prefix = try PrefixStore(paths: sandbox.paths).create(name: "P", runtimeID: runtime.id, profile: nil)
        prefix.metadata.settings.syncMode = .msync
        prefix.metadata.settings.metalFXUpscaling = false
        prefix.metadata.settings.environment = [EnvironmentVariable(name: "OTHER_PREFIX", value: "mine")]
        let planner = LaunchPlanner(runtime: runtime, prefix: prefix, baseEnvironment: ["PATH": "/usr/bin"])
        let env = planner.environment()
        XCTAssertEqual(env["OTHER_ROOT"], build.path + "/share")
        XCTAssertEqual(env["OTHER_PREFIX"], "mine")                    // the prefix has the last word
        XCTAssertEqual(env["WINEPREFIX"], prefix.directory.path)
        XCTAssertEqual(env["WINESERVER"], build.appendingPathComponent("libexec/server").path)
        XCTAssertEqual(env["PATH"], build.appendingPathComponent("libexec").path + ":/usr/bin")
        XCTAssertTrue(env["DYLD_FALLBACK_LIBRARY_PATH"]!.hasPrefix(build.path + "/lib:" + build.path + "/lib64:"))
        XCTAssertEqual(env["WINEMSYNC"], "1")                          // a capability it has
        XCTAssertNil(env["FINEWINE_METALFX_AUTO"])                     // and ones it has not
        XCTAssertNil(env["FINEWINE_FULLSCREEN"])
        XCTAssertNil(env["FINEWINE_DLSS"])

        let setup = try planner.plan(for: .initialize)
        XCTAssertEqual(setup.executable.path, build.appendingPathComponent("libexec/loader").path)
        XCTAssertEqual(setup.arguments, ["setup-tool", "--into", prefix.directory.path])
        XCTAssertEqual(try planner.plan(for: .restart).arguments, ["wineboot", "--restart"])
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

    // MARK: The runtime built into the app

    func testTheBuiltInRuntimeIsListedFirstAndHidesAnInstalledCopyOfItself() throws {
        let sandbox = Sandbox()
        let manifest = RuntimeManifest(id: "finewine-11.21-1", name: "FineWine", version: "1", wineVersion: "11.21")
        let inApp = sandbox.makeRuntime(manifest: manifest)
        let store = RuntimeStore(paths: sandbox.paths, bundledRoot: inApp)
        try store.installManaged(from: sandbox.makeRuntime(manifest: manifest))            // the same runtime, installed
        try store.installManaged(from: sandbox.makeRuntime(manifest: RuntimeManifest(id: "a-other", name: "A", version: "1", wineVersion: "10")))

        let list = store.list()
        XCTAssertEqual(list.map(\.id), ["finewine-11.21-1", "a-other"])
        XCTAssertEqual(list.first?.kind, .bundled)
        XCTAssertEqual(store.runtime(id: "finewine-11.21-1")?.root.path, inApp.path, "the one in the app is the one used")
    }

    func testAnAppWithoutARuntimeHasNoBuiltInOne() {
        let sandbox = Sandbox()
        XCTAssertNil(RuntimeStore(paths: sandbox.paths, bundledRoot: sandbox.root.appendingPathComponent("nothing")).bundled)
        XCTAssertNil(RuntimeStore(paths: sandbox.paths, bundledRoot: nil).bundled)
    }

    func testAPrefixWithoutAUsableChoiceUsesTheBuiltInRuntime() throws {
        let sandbox = Sandbox()
        let inApp = sandbox.makeRuntime(manifest: RuntimeManifest(id: "builtin", name: "FineWine", version: "1", wineVersion: "11.21"))
        let service = PrefixService(paths: sandbox.paths, runtimes: RuntimeStore(paths: sandbox.paths, bundledRoot: inApp))
        for id in [nil, "gone-runtime"] as [String?] {
            let prefix = Prefix(metadata: PrefixMetadata(name: "P", runtimeID: id), directory: sandbox.root.appendingPathComponent("pfx"))
            XCTAssertEqual(try service.runtime(for: prefix).id, "builtin")
        }
        let none = PrefixService(paths: sandbox.paths, runtimes: RuntimeStore(paths: sandbox.paths, bundledRoot: nil))
        let prefix = Prefix(metadata: PrefixMetadata(name: "P", runtimeID: "gone-runtime"), directory: sandbox.root.appendingPathComponent("pfx"))
        XCTAssertThrowsError(try none.runtime(for: prefix))
    }
}
