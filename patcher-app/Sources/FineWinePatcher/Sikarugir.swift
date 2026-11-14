import Foundation

/// Integrates FineWine with Sikarugir on macOS.
///
/// Sikarugir (a free Wineskin successor; `brew install --cask sikarugir`) manages Wine engines and
/// wrappers in `~/Library/Application Support/Sikarugir`. FineWine registers a custom engine
/// built from the CrossOver 26.3 Wine source with the FineWine patches applied, so Arknights:
/// Endfield (or the Steam version) can be launched through a Sikarugir wrapper without needing
/// a CrossOver licence.
///
/// The engine tarball (`WS12WineFineWine26.3.0_1.tar.xz`) is produced by
/// `scripts/build-wine.sh engine` + `scripts/package-sikarugir-engine.sh` and is NOT bundled
/// inside the patcher app — the user must supply it.
enum Sikarugir {
    // MARK: - Constants

    static let engineName    = "WS12WineFineWine26.3.0_1"
    static let engineVersion = "26.3.0_1"
    static let engineScheme  = "WS12Wine"  // Sikarugir engine naming convention

    struct Status: Equatable {
        let sikarugirInstalled: Bool
        let sikarugirRoot: URL
        let enginesRoot: URL
        let engineInstalled: Bool
        let engineDirectory: URL
        let engineTarball: URL?
    }

    // MARK: - Default Paths

    static var defaultSikarugirRoot: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Sikarugir", isDirectory: true)
    }

    // MARK: - Status Detection

    static func detectStatus(sikarugirRoot: URL = defaultSikarugirRoot,
                             customTarball: URL? = nil) -> Status {
        let fm = FileManager.default
        let enginesRoot = sikarugirRoot.appendingPathComponent("Engines", isDirectory: true)
        let engineDir   = enginesRoot.appendingPathComponent(engineName, isDirectory: true)

        // The engine is considered installed when its `bin/wine` or `lib/wine/x86_64-unix/ntdll.so`
        // is present (same detection used for NotProton runners).
        let wineExec = engineDir.appendingPathComponent("bin/wine")
        let ntdll    = engineDir.appendingPathComponent("lib/wine/x86_64-unix/ntdll.so")
        let engineInstalled = fm.isExecutableFile(atPath: wineExec.path) ||
                              fm.fileExists(atPath: ntdll.path)

        let sikarugirInstalled = fm.fileExists(atPath: sikarugirRoot.path)

        let tarball = customTarball ?? findEngineTarball(engineName: engineName)

        return Status(
            sikarugirInstalled: sikarugirInstalled,
            sikarugirRoot: sikarugirRoot,
            enginesRoot: enginesRoot,
            engineInstalled: engineInstalled,
            engineDirectory: engineDir,
            engineTarball: tarball
        )
    }

    // MARK: - Engine Discovery

    /// Searches common locations for the engine tarball the user built.
    static func findEngineTarball(engineName: String = engineName) -> URL? {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser

        let candidates: [URL] = [
            home.appendingPathComponent("Downloads/\(engineName).tar.xz"),
            home.appendingPathComponent("Desktop/\(engineName).tar.xz"),
            URL(fileURLWithPath: "/tmp/\(engineName).tar.xz"),
        ]
        return candidates.first { fm.fileExists(atPath: $0.path) }
    }

    // MARK: - Engine Installation

    /// Installs the FineWine engine tarball into Sikarugir's Engines directory.
    ///
    /// - Parameters:
    ///   - tarball: Path to `WS12WineFineWine26.3.0_1.tar.xz`.
    ///   - sikarugirRoot: Sikarugir support root (defaults to `~/Library/Application Support/Sikarugir`).
    static func installEngine(tarball: URL,
                              sikarugirRoot: URL = defaultSikarugirRoot) throws {
        let fm = FileManager.default

        guard fm.fileExists(atPath: tarball.path) else {
            throw PatchError("Engine tarball not found at \(tarball.path).")
        }

        // 1. Ensure Engines directory exists
        let enginesRoot = sikarugirRoot.appendingPathComponent("Engines", isDirectory: true)
        try fm.createDirectory(at: enginesRoot, withIntermediateDirectories: true)

        // 2. Remove an old copy if present
        let engineDir = enginesRoot.appendingPathComponent(engineName, isDirectory: true)
        if fm.fileExists(atPath: engineDir.path) {
            try fm.removeItem(at: engineDir)
        }
        try fm.createDirectory(at: engineDir, withIntermediateDirectories: true)

        // 3. Extract tarball with `tar -xJf`
        let tar = Process()
        tar.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        tar.arguments = ["-xJf", tarball.path, "--strip-components=1", "-C", engineDir.path]
        let errPipe = Pipe()
        tar.standardError = errPipe
        try tar.run()
        tar.waitUntilExit()
        if tar.terminationStatus != 0 {
            let errMsg = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(),
                                encoding: .utf8) ?? ""
            throw PatchError("tar extraction failed (status \(tar.terminationStatus)): \(errMsg)")
        }

        // 4. Verify that wine is now executable inside the engine
        let wineExec = engineDir.appendingPathComponent("bin/wine")
        guard fm.isExecutableFile(atPath: wineExec.path) else {
            throw PatchError("Engine installed but bin/wine is not executable — the tarball may be malformed.")
        }
    }

    // MARK: - Engine Removal

    /// Removes the installed FineWine engine from Sikarugir's Engines directory.
    static func removeEngine(sikarugirRoot: URL = defaultSikarugirRoot) throws {
        let engineDir = sikarugirRoot
            .appendingPathComponent("Engines", isDirectory: true)
            .appendingPathComponent(engineName, isDirectory: true)
        if FileManager.default.fileExists(atPath: engineDir.path) {
            try FileManager.default.removeItem(at: engineDir)
        }
    }

    // MARK: - Sikarugir App Detection

    /// Returns the Sikarugir.app or Sikarugir Creator.app URL if it is installed.
    static var sikarugirApp: URL? {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser
        let candidates = [
            URL(fileURLWithPath: "/Applications/Sikarugir Creator.app"),
            URL(fileURLWithPath: "/Applications/Sikarugir.app"),
            home.appendingPathComponent("Applications/Sikarugir Creator.app"),
            home.appendingPathComponent("Applications/Sikarugir.app"),
        ]
        return candidates.first { fm.fileExists(atPath: $0.path) }
    }
}

