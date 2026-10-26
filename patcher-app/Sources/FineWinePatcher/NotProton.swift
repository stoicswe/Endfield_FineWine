import Foundation

/// Integrates FineWine with NotProton and Steam Play on macOS.
///
/// This registers the FineWine-patched CrossOver into NotProton's runner system and
/// creates a Steam compatibility tool entry, allowing Arknights: Endfield to be launched
/// directly from the Steam client while preserving standalone CrossOver functionality.
enum NotProton {
    static let defaultBuildName = "finewine-26.3"
    static let defaultDisplayName = "CrossOver 26.3 - Endfield FineWine - Rosetta"
    static let defaultToolName = "notproton-finewine-rosetta"
    static let defaultFlavor = "rosetta"

    struct Status: Equatable {
        let steamRoot: URL
        let steamInstalled: Bool
        let notProtonRoot: URL
        let notProtonInstalled: Bool
        let runnerDirectory: URL
        let runnerExists: Bool
        let toolDirectory: URL
        let toolExists: Bool
        let isRegistered: Bool
        let patchedApp: URL?
        let displayName: String
        let buildName: String
        let flavor: String
    }

    static var defaultSteamRoot: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Steam", isDirectory: true)
    }

    static var defaultNotProtonRoot: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/notproton", isDirectory: true)
    }

    // MARK: - Status Detection

    static func detectStatus(
        steamRoot: URL = defaultSteamRoot,
        notProtonRoot: URL = defaultNotProtonRoot,
        buildName: String = defaultBuildName,
        displayName: String = defaultDisplayName,
        toolName: String = defaultToolName,
        flavor: String = defaultFlavor,
        customPatchedApp: URL? = nil
    ) -> Status {
        let fm = FileManager.default
        let steamInstalled = fm.fileExists(atPath: steamRoot.path)
        let notProtonInstalled = fm.fileExists(atPath: notProtonRoot.path)

        let runnerDir = notProtonRoot.appendingPathComponent("runners/crossover-\(buildName)", isDirectory: true)
        let wineExecutable = runnerDir.appendingPathComponent("CrossOver/bin/wine")
        let runnerExists = fm.isExecutableFile(atPath: wineExecutable.path)

        let compatDir = steamRoot.appendingPathComponent("compatibilitytools.d/\(toolName)", isDirectory: true)
        let manifestFile = compatDir.appendingPathComponent("compatibilitytool.vdf")
        let runScript = compatDir.appendingPathComponent("run")
        let toolExists = fm.fileExists(atPath: manifestFile.path) && fm.isExecutableFile(atPath: runScript.path)

        let isRegistered = runnerExists && toolExists

        let patchedApp = customPatchedApp ?? findPatchedCrossOverApp()

        return Status(
            steamRoot: steamRoot,
            steamInstalled: steamInstalled,
            notProtonRoot: notProtonRoot,
            notProtonInstalled: notProtonInstalled,
            runnerDirectory: runnerDir,
            runnerExists: runnerExists,
            toolDirectory: compatDir,
            toolExists: toolExists,
            isRegistered: isRegistered,
            patchedApp: patchedApp,
            displayName: displayName,
            buildName: buildName,
            flavor: flavor
        )
    }

    /// Finds any FineWine-patched CrossOver in standard locations.
    static func findPatchedCrossOverApp() -> URL? {
        let fm = FileManager.default
        let candidates = [
            URL(fileURLWithPath: "/Applications/CrossOver_Endfield_Patch.app"),
            fm.homeDirectoryForCurrentUser.appendingPathComponent("Applications/CrossOver_Endfield_Patch.app")
        ]
        for candidate in candidates {
            if isPatchedCrossOver(candidate) {
                return candidate
            }
        }
        return nil
    }

    static func isPatchedCrossOver(_ app: URL) -> Bool {
        let wine = app.appendingPathComponent("Contents/SharedSupport/CrossOver/bin/wine")
        guard FileManager.default.isExecutableFile(atPath: wine.path) else { return false }
        let ntdll = app.appendingPathComponent("Contents/SharedSupport/CrossOver/lib/wine/x86_64-unix/ntdll.so")
        return FileManager.default.fileExists(atPath: ntdll.path)
    }

    // MARK: - Registration

    static func register(
        patchedApp: URL,
        steamRoot: URL = defaultSteamRoot,
        notProtonRoot: URL = defaultNotProtonRoot,
        buildName: String = defaultBuildName,
        displayName: String = defaultDisplayName,
        toolName: String = defaultToolName,
        flavor: String = defaultFlavor
    ) throws {
        let fm = FileManager.default

        guard isPatchedCrossOver(patchedApp) else {
            throw PatchError("\(patchedApp.lastPathComponent) is not a valid patched CrossOver app.")
        }

        let cxrSource = patchedApp.appendingPathComponent("Contents/SharedSupport/CrossOver", isDirectory: true)
        guard fm.fileExists(atPath: cxrSource.path) else {
            throw PatchError("CrossOver internals missing in \(patchedApp.path)")
        }

        // 1. Ensure support directories exist
        try fm.createDirectory(at: notProtonRoot, withIntermediateDirectories: true)
        let runnersRoot = notProtonRoot.appendingPathComponent("runners", isDirectory: true)
        try fm.createDirectory(at: runnersRoot, withIntermediateDirectories: true)

        let compatRoot = steamRoot.appendingPathComponent("compatibilitytools.d", isDirectory: true)
        try fm.createDirectory(at: compatRoot, withIntermediateDirectories: true)

        // 2. Stage runner
        let runnerDir = runnersRoot.appendingPathComponent("crossover-\(buildName)", isDirectory: true)
        let runnerTarget = runnerDir.appendingPathComponent("CrossOver", isDirectory: true)
        if fm.fileExists(atPath: runnerDir.path) {
            try fm.removeItem(at: runnerDir)
        }
        try fm.createDirectory(at: runnerDir, withIntermediateDirectories: true)

        // Copy internals using ditto to preserve symlinks and permissions
        let ditto = Process()
        ditto.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        ditto.arguments = ["--noextattr", "--noqtn", cxrSource.path, runnerTarget.path]
        try ditto.run()
        ditto.waitUntilExit()
        guard ditto.terminationStatus == 0 else {
            throw PatchError("Failed to copy CrossOver to NotProton runners directory (status \(ditto.terminationStatus)).")
        }

        // 3. Create Steam tool directory
        let toolDir = compatRoot.appendingPathComponent(toolName, isDirectory: true)
        if fm.fileExists(atPath: toolDir.path) {
            try fm.removeItem(at: toolDir)
        }
        try fm.createDirectory(at: toolDir, withIntermediateDirectories: true)

        // build & flavor files
        try "\(buildName)\n".write(to: toolDir.appendingPathComponent("build"), atomically: true, encoding: .utf8)
        try "\(flavor)\n".write(to: toolDir.appendingPathComponent("flavor"), atomically: true, encoding: .utf8)

        // toolmanifest.vdf
        let toolmanifest = """
        "manifest"
        {
          "version" "2"
          "commandline" "/run %verb%"
        }
        """
        try toolmanifest.write(to: toolDir.appendingPathComponent("toolmanifest.vdf"), atomically: true, encoding: .utf8)

        // compatibilitytool.vdf
        let compatVdf = """
        "compatibilitytools"
        {
          "compat_tools"
          {
            "\(toolName)"
            {
              "install_path" "."
              "display_name" "\(displayName)"
              "from_oslist" "windows"
              "to_oslist" "macos"
            }
          }
        }
        """
        try compatVdf.write(to: toolDir.appendingPathComponent("compatibilitytool.vdf"), atomically: true, encoding: .utf8)

        // run script
        let runScriptURL = toolDir.appendingPathComponent("run")
        if let existingRun = findExistingNotProtonRunScript(compatRoot: compatRoot) {
            try? fm.removeItem(at: runScriptURL)
            try fm.copyItem(at: existingRun, to: runScriptURL)
        } else {
            try standaloneRunScriptContent.write(to: runScriptURL, atomically: true, encoding: .utf8)
        }
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: runScriptURL.path)

        // 4. Endfield defaults override
        let defaultsFile = notProtonRoot.appendingPathComponent("defaults-override-\(buildName)-rosetta")
        let defaultsContent = """
        CX_GRAPHICS_BACKEND=d3dmetal
        D3DM_ENABLE_METALFX=1
        WINEMSYNC=1
        ROSETTA_ADVERTISE_AVX=1

        """
        try? defaultsContent.write(to: defaultsFile, atomically: true, encoding: .utf8)

        // 5. Update tools file if present
        let toolsFile = notProtonRoot.appendingPathComponent("tools")
        if fm.fileExists(atPath: toolsFile.path) {
            var lines = (try? String(contentsOf: toolsFile, encoding: .utf8))?
                .components(separatedBy: "\n")
                .filter { !$0.contains(buildName) && !$0.isEmpty } ?? []
            lines.append("\(toolName)\t\(buildName)\t\(flavor)\t\(displayName)")
            try? (lines.joined(separator: "\n") + "\n").write(to: toolsFile, atomically: true, encoding: .utf8)
        }
    }

    // MARK: - Unregistration

    static func unregister(
        steamRoot: URL = defaultSteamRoot,
        notProtonRoot: URL = defaultNotProtonRoot,
        buildName: String = defaultBuildName,
        toolName: String = defaultToolName
    ) throws {
        let fm = FileManager.default
        let toolDir = steamRoot.appendingPathComponent("compatibilitytools.d/\(toolName)", isDirectory: true)
        if fm.fileExists(atPath: toolDir.path) {
            try fm.removeItem(at: toolDir)
        }

        let runnerDir = notProtonRoot.appendingPathComponent("runners/crossover-\(buildName)", isDirectory: true)
        if fm.fileExists(atPath: runnerDir.path) {
            try fm.removeItem(at: runnerDir)
        }

        let toolsFile = notProtonRoot.appendingPathComponent("tools")
        if fm.fileExists(atPath: toolsFile.path),
           let content = try? String(contentsOf: toolsFile, encoding: .utf8) {
            let filtered = content.components(separatedBy: "\n")
                .filter { !$0.contains(buildName) }
                .joined(separator: "\n")
            try? filtered.write(to: toolsFile, atomically: true, encoding: .utf8)
        }
    }

    // MARK: - Helpers

    static func findExistingNotProtonRunScript(compatRoot: URL) -> URL? {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(at: compatRoot, includingPropertiesForKeys: nil) else {
            return nil
        }
        for entry in entries {
            let script = entry.appendingPathComponent("run")
            if fm.isExecutableFile(atPath: script.path) && entry.lastPathComponent.contains("notproton") {
                return script
            }
        }
        return nil
    }

    static let standaloneRunScriptContent = """
    #!/bin/sh
    # FineWine Steam compatibility tool — run script.
    set -e

    verb="$1"
    shift || true

    case "$verb" in
      getcompatpath)
        printf '%s\\n' "$STEAM_COMPAT_DATA_PATH"
        exit 0
        ;;
    esac

    export CX_HOME="$HOME/Library/Application Support/CrossOver"
    np_support="$HOME/Library/Application Support/notproton"

    CDPATH=''
    np_tool_dir=$(cd -- "$(dirname -- "$0")" 2>/dev/null && pwd) || np_tool_dir=""
    np_build=""
    np_flavor=""
    if [ -n "$np_tool_dir" ] && [ -r "$np_tool_dir/build" ]; then
      read -r np_build < "$np_tool_dir/build" || np_build=""
    fi
    if [ -n "$np_tool_dir" ] && [ -r "$np_tool_dir/flavor" ]; then
      read -r np_flavor < "$np_tool_dir/flavor" || np_flavor=""
    fi

    CX_ROOT="$np_support/runners/crossover-$np_build/CrossOver"
    export CX_ROOT

    if [ -f "$CX_ROOT/lib64/apple_gptk/external/libd3dshared.dylib" ]; then
      export CX_APPLEGPTK_LIBD3DSHARED_PATH="$CX_ROOT/lib64/apple_gptk/external/libd3dshared.dylib"
    fi

    wine_unix="$CX_ROOT/lib/wine/aarch64-unix"
    WINELOADER="$wine_unix/wine.app/Contents/MacOS/wine"
    WINESERVER="$CX_ROOT/bin/wineserver-arm64"
    if [ "$np_flavor" = rosetta ] || [ ! -x "$WINELOADER" ] || [ ! -x "$WINESERVER" ]; then
      wine_unix="$CX_ROOT/lib/wine/x86_64-unix"
      WINELOADER="$wine_unix/wine"
      WINESERVER="$CX_ROOT/bin/wineserver"
      [ -x "$WINESERVER" ] || WINESERVER="$CX_ROOT/bin/wineserver-x86"
    fi
    export WINELOADER WINESERVER

    export WINEDLLPATH="$CX_ROOT/lib/wine/x86_64-windows:$wine_unix${WINEDLLPATH:+:$WINEDLLPATH}"
    export PATH="$CX_ROOT/bin:$PATH"
    export ROSETTA_ADVERTISE_AVX="${ROSETTA_ADVERTISE_AVX:-1}"

    case "$verb" in
      waitforexitandrun)
        app_id="${STEAM_COMPAT_APP_ID:-}"
        case "$app_id" in ''|0) app_id="${SteamAppId:-}" ;; esac
        [ -n "${SteamAppId:-}" ] || export SteamAppId="$app_id"
        [ -n "${SteamGameId:-}" ] || export SteamGameId="$app_id"
        ;;
    esac

    log=/dev/null
    if [ -n "${STEAM_COMPAT_DATA_PATH:-}" ]; then
      log="$STEAM_COMPAT_DATA_PATH/finewine-run.log"
    fi
    {
      echo "=== finewine run $(date) ==="
      echo "verb=$verb"
      echo "CX_ROOT=$CX_ROOT"
      echo "WINELOADER=$WINELOADER"
      echo "STEAM_COMPAT_DATA_PATH=${STEAM_COMPAT_DATA_PATH:-}"
    } >> "$log" 2>&1 || true

    if [ -n "${STEAM_COMPAT_DATA_PATH:-}" ]; then
      export WINEPREFIX="$STEAM_COMPAT_DATA_PATH/pfx"
      mkdir -p "$WINEPREFIX"
    fi

    case "$verb" in
      run|waitforexitandrun)
        "$WINESERVER" -k > /dev/null 2>&1 || true
        sleep 1
        "$WINELOADER" "$@" >> "$log" 2>&1
        ;;
      *)
        "$WINELOADER" "$@" >> "$log" 2>&1 || true
        ;;
    esac
    """
}
