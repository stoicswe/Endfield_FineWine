# FineWine

FineWine is a menu bar app for macOS 26 and later that runs Windows programs with Wine. It
manages Wine prefixes, launches the programs installed in them, and makes a small `.app` for each
program so it can be started from Finder, Launchpad or the Dock.

It sits beside **FineWine Patcher** (`patcher-app/`), which patches a CrossOver install. FineWine
uses no CrossOver code or files: it drives a Wine runtime of our own. The patcher is unchanged
and will later become one function of this app.

> **Status: early.** FineWine's own runtime boots on a stock Mac and, in tests, runs ARM64 and
> x64 Windows programs (x64 through FEX) with MSync and Direct3D 11 on Metal (DXMT). No real
> game has been run on it yet. It is built by `scripts/build-finewine-runtime.sh`,
> `scripts/build-fex.sh` and `scripts/build-dxmt.sh`, and checked by
> `scripts/test-finewine-runtime.sh`. See `docs/project-information/20-finewine-runtime-spike.md`.

## What it does

- **Menu bar item.** Lists every prefix and its programs; one click starts a program. FineWine
  has no Dock icon unless its manager window is open.
- **Prefixes.** Create (from a game profile), rename, duplicate and delete. Each prefix is a
  separate Windows environment under `~/Library/Application Support/FineWine/Prefixes`.
- **Programs.** Run an installer in a prefix; FineWine then lists the programs it installed by
  reading the shortcuts it left. Programs can also be added by hand, and each can have its own
  arguments, working folder and environment variables.
- **Shortcut apps.** "Make Shortcut App" writes `~/Applications/FineWine/<Program>.app` with the
  program's own icon. The app contains no Wine code; it opens a `finewine://launch` link that
  FineWine handles.
- **Opening programs from Finder.** A `.exe` or `.msi` from outside any prefix gets a new prefix named after what it installs (the program's product name, else its cleaned-up file name), or FineWine asks whether to make one or use an existing prefix: Settings > Windows files > "Auto create prefix" or "Ask Me".
- **32-bit installers.** The runtime cannot run 32-bit programs, and most installers are 32-bit.
  One made with NSIS is installed by FineWine itself, from the script inside it, with the
  status window showing progress; see `docs/project-information/25-32-bit-programs-and-installers.md`.
  Other 32-bit programs are explained rather than failing silently.
- **Right-click a prefix** in the manager's sidebar for its actions: run an installer, find
  programs, configure, Wine tools, show its files or logs, shut down, rename, duplicate, delete.
- **Discord activity.** With "Show what I'm playing in Discord" on in Settings (it is off by
  default) and the id of a Discord application of your own entered there, the program you
  started from FineWine is your Discord activity while it runs; when a launcher starts the
  game, the game is what is shown. FineWine talks only to the Discord app on the Mac
  (`DiscordPresence.swift`).
- **Supporting Wine.** Settings and the menu bar panel link to WineHQ's donation page.
- **Quitting.** If programs are running in any prefix when FineWine is asked to quit (the power
  button, Command-Q, logging out), it lists them and asks. On a yes every program is asked to
  close; whatever has not closed after 5 seconds is ended, and then FineWine quits.
- **Status window.** While a prefix is set up or changed and while a program starts, a small
  window in the middle of the display says what FineWine is doing and for how long, so a slow
  start does not look like a stall. It takes no focus, goes away when the program's own window
  appears (or the program ends), and a click hides it. It can be turned off in Settings.
- **Configuration.** Windows version and build number, Direct3D backend, Retina mode, DPI,
  virtual desktop, Metal overlay, full-screen behaviour (a Mac full-screen Space by default), Game Mode (programs that use Direct3D, Vulkan or OpenGL run as games), starting HoYoverse games through a Steam stand-in, DLSS through MetalFX, reporting an NVIDIA GPU (the ids of an RTX 5080, for games that only offer DLSS on NVIDIA), MSync, the hypervisor flag, macOS styling for Windows controls,
  Option-as-Alt, DLL overrides,
  environment variables and Wine debug channels. Changes are written to the prefix's registry
  when applied.
- **Wine tools.** Wine Configuration (winecfg), Registry Editor, Control Panel, Add or Remove
  Programs, Task Manager, File Manager, Command Prompt and Notepad, plus restart, update and
  stop-everything.
- **Windows files.** FineWine appears under Open With for `.exe` and `.msi` files. A setting
  makes it their default app. A file from outside a prefix is always confirmed first, with a
  choice of prefix.

## Build

```bash
./finewine-app/scripts/build-app.sh
```

This runs the unit tests, builds a release binary, assembles `finewine-app/build/FineWine.app`
and signs it ad hoc. It needs the macOS 26 SDK or later (Xcode 26+), because the interface uses
Liquid Glass. Environment variables: `VERSION`, `CODESIGN_ID`, `ICON_VARIANT`, `SKIP_TESTS=1`.

**The Wine runtime is built into the app.** If `build/finewine-runtime` exists, it is copied to
`FineWine.app/Contents/Resources/Runtime` (about 860 MB). The app lists it first as "Built in",
new prefixes use it, and a prefix whose own runtime is missing falls back to it; it cannot be
removed from the list. Without a runtime in `build/` the app is built without one and says so
(`BUNDLE_RUNTIME=required` makes that an error, `BUNDLE_RUNTIME=0` skips it, `RUNTIME_DIR`
picks another folder). `scripts/build-finewine.sh` builds the runtime and then the app with it.

Run the tests on their own with:

```bash
swift test --package-path finewine-app
```

One test drives a real Wine runtime and is skipped unless it is told where one is:

```bash
FINEWINE_TEST_RUNTIME="$PWD/build/finewine-runtime" swift test --package-path finewine-app --filter RuntimeIntegrationTests
```

CI builds and tests the app in `.github/workflows/build-finewine.yml` and uploads it as the
`finewine-app` artifact. That workflow is separate from the Wine and patcher builds.

## Layout

| Path | What it holds |
|---|---|
| `Sources/FineWineCore` | Everything that isn't interface: prefixes, runtimes, profiles, registry files, launch plans, shortcut apps, icon extraction. Unit-tested. |
| `Sources/FineWine` | The SwiftUI app: menu bar panel, manager window, settings. |
| `Tests/FineWineCoreTests` | Unit tests for the core library. |
| `Resources/FW_Icon` | The app icon: the Icon Composer document and its PNG exports. |
| `Resources/MenuBarIcon.svg` | The menu bar icon, drawn as a template image. |
| `scripts/build-app.sh` | Builds and assembles the app. |
| `scripts/make-icns.swift` | Makes the `.icns` from one appearance of the icon exports. |

The app icon always uses the **dark** appearance of the artwork. `build-app.sh` makes a plain
`.icns` from the dark exports; it deliberately does not compile the `.icon` document, because
that icon would switch to the light appearance in light mode.

## Runtimes

A runtime is a folder with `bin/wine`, `bin/wineserver` and `lib/wine`. Add one in Settings:

- A folder with a `runtime.json` is a FineWine runtime and is copied into
  `~/Library/Application Support/FineWine/Runtimes`.
- Any other Wine folder is used where it is.

`runtime.json`:

```json
{
  "id": "finewine-11.21-1",
  "name": "FineWine 11.21",
  "version": "1",
  "wineVersion": "11.21",
  "architecture": "arm64",
  "graphics": {
    "dxmt": { "dllPath": "lib/dxmt", "overrides": { "d3d11": "n,b", "dxgi": "n,b", "d3d10core": "n,b" } }
  }
}
```

`graphics` tells FineWine how to switch on each Direct3D backend the runtime ships: a folder to
add to Wine's DLL path and the load order for its DLLs. A backend the runtime doesn't list has no
effect, and the Configuration tab says so.

Game-specific fixes are compiled into the runtime and switched on by settings; nothing is
swapped into a runtime per game.

## Game profiles

A profile is the starting configuration for a game: settings, plus arguments for its main
executable. Two are built in (Standard and Arknights: Endfield). More can be added as JSON files
in `~/Library/Application Support/FineWine/Profiles`:

```json
{
  "id": "my-game",
  "name": "My Game",
  "summary": "Windows 10 with DXVK.",
  "settings": { "windowsVersion": "win10", "graphicsBackend": "dxvk" },
  "executables": ["Game.exe"],
  "launchArguments": ["-dx11"]
}
```

## Development

Set `FINEWINE_HOME` to an absolute path to keep all of FineWine's data (prefixes, runtimes, logs,
shortcut apps) under that folder instead of the real locations:

```bash
FINEWINE_HOME=/tmp/finewine-dev finewine-app/build/FineWine.app/Contents/MacOS/FineWine
```

- **Multilingual support.** Built-in localization with automatic system language detection and dynamic runtime switching in Settings or via the menu bar. Supported languages: English, Simplified Chinese (`zh-Hans`), Traditional Chinese (`zh-Hant`), Korean (`ko`), and Japanese (`ja`).
- **Development.** Set `FINEWINE_HOME` to an absolute path to keep all of FineWine's data (prefixes, runtimes, logs, shortcut apps) under that folder instead of the real locations:

## Licence

GPL-3.0-or-later, like the rest of this repository. The icon artwork is supplied by the project
owner, who holds usage rights for it.
