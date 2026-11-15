# FineWine

FineWine is a menu bar app for macOS 26 and later that runs Windows programs with Wine. It
manages Wine prefixes, launches the programs installed in them, and makes a small `.app` for each
program so it can be started from Finder, Launchpad or the Dock.

It sits beside **FineWine Patcher** (`patcher-app/`), which patches a CrossOver install. FineWine
uses no CrossOver code or files: it drives a Wine runtime of our own. The patcher is unchanged
and will later become one function of this app.

> **Status: the app is built; the runtime does not run yet.** FineWine needs a Wine runtime to
> run anything. Upstream Wine builds for Apple Silicon (`scripts/build-finewine-runtime.sh`), but
> it cannot start Windows programs on stock macOS: it needs memory below 4 GB and a preserved
> x18 register, which macOS only gives to programs with an Apple-issued entitlement. See
> `docs/project-information/20-finewine-runtime-spike.md`. Until that is solved, FineWine can be
> pointed at any other Wine folder, which is enough to exercise the app.

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
- **Configuration.** Windows version and build number, Direct3D backend, Retina mode, DPI,
  virtual desktop, Metal overlay, MSync, the hypervisor flag, macOS styling for Windows controls,
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

Run the tests on their own with:

```bash
swift test --package-path finewine-app
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

The interface is in English only for now; the patcher's translations have not been carried over.

## Licence

GPL-3.0-or-later, like the rest of this repository. The icon artwork is supplied by the project
owner, who holds usage rights for it.
