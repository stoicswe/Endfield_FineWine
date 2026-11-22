# FineWine

FineWine is a menu bar app for macOS 26 and later that runs Windows programs with Wine. It
manages Wine prefixes, launches the programs installed in them, and makes a small `.app` for each
program so it can be started from Finder, Launchpad or the Dock.

It uses no CrossOver code or files and no Rosetta 2: it drives a Wine runtime built from this
repository. It sits beside **FineWine Patcher** ([`patcher-app/`](../patcher-app/README.md)),
which patches a CrossOver install instead.

> **Status: beta.** The runtime runs ARM64, x64 and 32-bit Windows programs (x64 and 32-bit
> through FEX) with MSync, Direct3D 10/11 on Metal (DXMT) and Vulkan and Direct3D 12 through
> MoltenVK. Games have been run on it, with rough edges still. 32-bit support is new: installers,
> ordinary programs, Direct3D 9 to 11 and OpenGL; Direct3D 12 and Vulkan do not work from a
> 32-bit program yet. One 32-bit game has been tried: Portal, from Steam, reaches its main menu.

Contents: [What it does](#what-it-does) · [Build](#build) ·
[Technical architecture](#technical-architecture) · [Runtimes](#runtimes) ·
[Game profiles](#game-profiles) · [Development](#development) ·
[Licences](#licences) · [Credits](#credits)

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
- **Importing a CrossOver bottle.** "Import CrossOver Bottle…" makes a prefix from a copy of a
  bottle (a clone on the same drive, so it takes no extra room). The bottle is only read. The
  C: drive and registry come over, the Windows user folder is renamed, and FineWine's Wine then
  updates the system files. 32-bit bottles and bottles with programs running are refused.
- **Steam.** "Install in Steam" (Settings > Steam) adds FineWine to the Mac Steam client's
  compatibility tools, beside NotProton's or Bridgeplay's, which are what switch that list on;
  FineWine does not patch Steam. A Windows game started with Play then runs on FineWine's
  runtime in a prefix of its own, with Steam sign-in and the Steamworks API through the
  runtime's bridge. See [runtime-extras/steam-bridge](../runtime-extras/steam-bridge/README.md).
- **Opening programs from Finder.** A `.exe` or `.msi` from outside any prefix gets a new prefix
  named after what it installs, or FineWine asks whether to make one or use an existing prefix:
  Settings > Windows files > "Auto create prefix" or "Ask Me". FineWine appears under Open With
  for these files, and a setting makes it their default app.
- **32-bit programs and installers.** Most installers are 32-bit, whatever they install. One
  made with NSIS is installed by FineWine itself, from the script inside it; other 32-bit
  programs run in the runtime. See
  [25-32-bit-programs-and-installers.md](../docs/project-information/25-32-bit-programs-and-installers.md).
- **Right-click a prefix** in the manager's sidebar for its actions: run an installer, find
  programs, configure, Wine tools, show its files or logs, shut down, rename, duplicate, delete.
- **External drives.** A prefix can live on any APFS or Mac OS Extended drive, in
  `FineWine/Prefixes` on it. A drive's prefixes leave the list when it is unplugged and come
  back when it is plugged in again. See
  [27-prefixes-on-external-drives.md](../docs/project-information/27-prefixes-on-external-drives.md).
- **Moving and snapshots.** A prefix moves between this Mac and a drive with progress and Cancel,
  and shortcuts keep working. A snapshot saves the whole prefix next to it (an instant APFS
  clone) or on another drive; a prefix can be restored from one, or a snapshot made into a new
  prefix. See
  [28-moving-prefixes-and-snapshots.md](../docs/project-information/28-moving-prefixes-and-snapshots.md).
- **Configuration.** Windows version and build number, Direct3D backend, Retina mode, DPI,
  virtual desktop, Metal overlay, full-screen behaviour (a Mac full-screen Space by default),
  Game Mode, automatic MetalFX upscaling and render size, DLSS through MetalFX, reporting an
  NVIDIA GPU, starting HoYoverse games through a Steam stand-in, MSync, the emulator's settings,
  macOS styling for Windows controls, Mac-style app icons, Option-as-Alt, the language for
  non-Unicode programs, DLL overrides, environment variables and Wine debug channels.
- **Wine tools.** Wine Configuration, Registry Editor, Control Panel, Add or Remove Programs,
  Task Manager, File Manager, Command Prompt and Notepad, plus restart, update and
  stop-everything.
- **Status window.** While a prefix is set up or changed and while a program starts, a small
  window says what FineWine is doing and for how long. It takes no focus and can be turned off.
- **Discord activity.** Off by default. With it on and the id of a Discord application of your
  own entered in Settings, the program you started is your Discord activity while it runs.
  FineWine talks only to the Discord app on the Mac.
- **Updates.** FineWine checks this repository's GitHub releases, downloads the new version,
  checks its checksum and signature, and replaces itself.
- **Quitting.** If programs are running when FineWine is asked to quit, it lists them and asks.
  On a yes every program is asked to close; whatever has not closed after 5 seconds is ended.
- **Languages.** English, Arabic, Japanese, Korean, Simplified Chinese and Traditional Chinese,
  following the system language or chosen in Settings.

## Build

Requirements: an Apple Silicon Mac, Xcode 26 or later (the macOS 26 SDK; the interface uses
Liquid Glass) and, for the runtime, [Homebrew](https://brew.sh). The build scripts install the
Homebrew tools they need.

**Everything, runtime included** (well over an hour from scratch):

```bash
./scripts/build-finewine.sh
```

It builds, in order: MoltenVK (FineWine flavour), the llvm-mingw compiler, the Wine runtime, FEX
and DXMT, runs the runtime checks, and then builds `FineWine.app` with the runtime inside it.
`./scripts/build-finewine.sh runtime` stops before the app; `./scripts/build-finewine.sh app`
builds only the app.

**The app only:**

```bash
./finewine-app/scripts/build-app.sh
```

This runs the unit tests, builds a release binary, assembles `finewine-app/build/FineWine.app`
and signs it ad hoc. Environment variables: `VERSION`, `CODESIGN_ID`, `ICON_VARIANT`,
`SKIP_TESTS=1`.

If `build/finewine-runtime` exists it is copied to `FineWine.app/Contents/Resources/Runtime`
(about 860 MB) and listed first as "Built in". Without one the app is built without a runtime and
says so (`BUNDLE_RUNTIME=required` makes that an error, `BUNDLE_RUNTIME=0` skips it,
`RUNTIME_DIR` picks another folder).

The build stamps the real SDK version into the binary (`scripts/lib/stamp-sdk-version.sh`):
SwiftPM records the deployment target there instead, and macOS draws an app whose binary names an
SDK older than 26 without Liquid Glass. The app runs on macOS 26 and later; the runtime is built
for macOS 15 and later.

**Tests:**

```bash
swift test --package-path finewine-app
```

Tests that drive a real Wine runtime are skipped unless they are told where one is:

```bash
FINEWINE_TEST_RUNTIME="$PWD/build/finewine-runtime" swift test --package-path finewine-app --filter RuntimeIntegrationTests
```

`scripts/test-finewine-runtime.sh` checks the runtime itself and
`scripts/bench-finewine-runtime.sh` measures it.

CI builds and tests the app in `.github/workflows/build-finewine.yml`, and the whole runtime in
`build-finewine-full.yml`.

## Technical architecture

### The app

| Path | What it holds |
|---|---|
| `Sources/FineWineCore` | Everything that isn't interface: prefixes, runtimes, profiles, registry files, launch plans, shortcut apps, icon extraction, bottle import, updates. Unit-tested. |
| `Sources/FineWine` | The SwiftUI app: menu bar panel, manager window, settings, update window. |
| `Tests/FineWineCoreTests` | Unit tests for the core library. |
| `Resources/FW_Icon` | The app icon: the Icon Composer document and its PNG exports. |
| `Resources/MenuBarIcon.svg` | The menu bar icon, drawn as a template image. |
| `scripts/build-app.sh` | Builds and assembles the app. |
| `scripts/make-icns.swift` | Makes the `.icns` from one appearance of the icon exports. |

The app never links Wine. It starts the runtime's loader as a separate process with an
environment it builds from the runtime's description, the prefix's settings and the program's own
(`LaunchPlan.swift`). Settings that Windows keeps in the registry are written to the prefix's
registry files; the rest are environment variables the patched runtime reads. Prefixes are found
again by a file Wine keeps open in them, which is also how FineWine knows what is running.

The app icon always uses the **dark** appearance of the artwork. `build-app.sh` makes a plain
`.icns` from the dark exports; it does not compile the `.icon` document, because that icon would
switch to the light appearance in light mode.

### The runtime

A native ARM64 Wine with everything a game needs beside it, built by the scripts in
[`scripts/`](../scripts/) from the exact commits named in
[`finewine-sources.lock`](../finewine-sources.lock):

| Layer | What it does | Built by | Our changes |
|---|---|---|---|
| **Wine 11.21** | The Windows environment, as native ARM64 code | `build-finewine-runtime.sh` | [`patches/runtime`](../patches/runtime) (55 patches) |
| **FEX** | Runs x64 and 32-bit Windows code inside Wine's ARM64 processes (`xtajit64.dll` and the ARM64EC library; `xtajit.dll` for 32-bit); no Rosetta | `build-fex.sh` | [`patches/fex`](../patches/fex) |
| **DXMT** | Direct3D 10 and 11 on Metal, and NVIDIA's NGX (DLSS) as MetalFX | `build-dxmt.sh` | [`patches/dxmt`](../patches/dxmt) |
| **MoltenVK** | Vulkan on Metal; Direct3D 12 reaches it through Wine's vkd3d | `MVK_FLAVOR=finewine build-moltenvk.sh` | [`patches/moltenvk`](../patches/moltenvk): ray tracing, MetalFX |
| **GnuTLS, Nettle, GMP, FreeType** | TLS and fonts for Wine | `build-finewine-deps.sh` | none |
| **Steam stand-in, presence helper** | Small programs of our own | [`runtime-extras`](../runtime-extras) | |
| **Steam bridge** | Valve's `lsteamclient`, the `steam.exe` helper and the overlay helper, for games started from the Mac Steam client | `build-steam-bridge.sh` | [`runtime-extras/steam-bridge`](../runtime-extras/steam-bridge), runtime patch 0042 |

What the Wine patches are for:

- **Running on a stock Mac at all.** macOS gives a process no memory below 4 GB and does not
  preserve the x18 register, both of which Windows ARM64 code relies on. Patches 0002 to 0005
  work around both without Apple's entitlement
  ([20-finewine-runtime-spike.md](../docs/project-information/20-finewine-runtime-spike.md)).
- **32-bit programs.** With no memory below 4 GB, a 32-bit program's 4 GB are a window at 1 TB:
  Wine's memory manager and call layer and FEX's generated code add the window's base to every
  32-bit address (patch 0043, FEX patch 0011).
- **16K pages.** macOS uses 16K memory pages where Windows expects 4K; several Wine and FEX
  patches make partial pages behave, and keep the emulator from committing memory it never uses
  ([30-emulator-memory-on-macos.md](../docs/project-information/30-emulator-memory-on-macos.md)).
- **Speed.** MSync (Mach semaphores for Windows synchronisation), a faster search for free
  memory, and measured defaults
  ([22-performance.md](../docs/project-information/22-performance.md),
  [29-performance-analysis.md](../docs/project-information/29-performance-analysis.md)).
- **Behaving like a Mac game.** Full-screen Spaces, Game Mode, the Metal HUD, rounded windows,
  Dock icons, Mac fonts for Chinese, Japanese and Korean text, audio that follows the Mac's
  output device
  ([23-behaving-like-a-mac-game.md](../docs/project-information/23-behaving-like-a-mac-game.md)).
- **Graphics.** DXMT's window interface, MetalFX upscaling, the GPU a prefix reports, ray
  tracing in MoltenVK
  ([21-metal4-and-ray-tracing.md](../docs/project-information/21-metal4-and-ray-tracing.md)).

Game-specific fixes are compiled into the runtime and switched on by settings; nothing is
swapped into a runtime per game.

## Runtimes

A runtime is a Wine build plus a `runtime.json` that says what the build is and how to start it.
The one inside the app is listed first; others are added in Settings:

- A folder with a `runtime.json` beside `bin/` and `lib/` is copied into
  `~/Library/Application Support/FineWine/Runtimes`.
- A folder holding only a `runtime.json` whose `root` names a Wine build elsewhere describes
  that build where it is.
- A plain Wine folder with no description is used where it is, with no FineWine features.

A description can also name the loader and server, library folders, environment variables and
the FineWine features (capabilities) the build has; settings for a feature a runtime lacks are
greyed out. CrossOver's folder is refused as it is, because its `bin/wine` only works with
CrossOver's bottles. The whole format:
[docs/finewine-runtime-format.md](../docs/finewine-runtime-format.md).

## Game profiles

A profile is the starting configuration for a game: settings, plus arguments for its main
executable. Two are built in (Standard and Arknights: Endfield). More can be added as JSON files
in `~/Library/Application Support/FineWine/Profiles`:

```json
{
  "id": "my-game",
  "name": "My Game",
  "summary": "Windows 10 with DXMT.",
  "settings": { "windowsVersion": "win10", "graphicsBackend": "dxmt" },
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

## Licences

**FineWine itself** (the Swift sources, the interface, the build scripts, `runtime-extras`):
[GNU GPL-3.0-or-later](../LICENSE). The icon artwork is supplied by the project owner, who holds
usage rights for it.

**The patches** are changes to other projects and stay under the licence of the project each one
changes.

**What a built `FineWine.app` contains**, each under its own licence:

| Component | Licence | Upstream |
|---|---|---|
| Wine 11.21 | LGPL-2.1-or-later | [winehq.org](https://www.winehq.org/) · [source](https://gitlab.winehq.org/wine/wine) |
| FEX | MIT | [FEX-Emu/FEX](https://github.com/FEX-Emu/FEX) |
| DXMT | LGPL-2.1-or-later | [3Shain/dxmt](https://github.com/3Shain/dxmt) |
| LLVM 15 (libraries inside DXMT) | Apache-2.0 with LLVM exceptions | [llvm/llvm-project](https://github.com/llvm/llvm-project) |
| MoltenVK | Apache-2.0 | [KhronosGroup/MoltenVK](https://github.com/KhronosGroup/MoltenVK) |
| GnuTLS | LGPL-2.1-or-later | [gnutls.org](https://www.gnutls.org/) |
| Nettle | LGPL-3.0-or-later or GPL-2.0-or-later | [lysator.liu.se/~nisse/nettle](https://www.lysator.liu.se/~nisse/nettle/) |
| GMP | LGPL-3.0-or-later or GPL-2.0-or-later | [gmplib.org](https://gmplib.org/) |
| FreeType | FreeType License or GPL-2.0 | [freetype.org](https://freetype.org/) |
| lsteamclient (Steam bridge) | Steamworks SDK licence | [ValveSoftware/Proton](https://github.com/ValveSoftware/Proton) |
| steam.exe helper (Steam bridge) | BSD 3-Clause | [ValveSoftware/Proton](https://github.com/ValveSoftware/Proton), macOS port from [NotProton](https://github.com/NotProtonNot/NotProton) |

Windows-side code is compiled with [llvm-mingw](https://github.com/mstorsjo/llvm-mingw), whose
runtime libraries (mingw-w64, compiler-rt, libc++) are linked into those modules under their own
permissive licences.

**Corresponding source.** If you distribute a built app, the LGPL components require their
complete source to be available. For this project that is
[`finewine-sources.lock`](../finewine-sources.lock), which names every upstream by exact commit
or checksum, plus the [`patches/`](../patches) applied to them and the scripts that build them.
GnuTLS, GMP and FreeType are built from CodeWeavers' published
[CrossOver source archive](https://media.codeweavers.com/pub/crossover/source/), also pinned
there.

FineWine contains nothing of CrossOver's own code, Apple's Game Porting Toolkit or any game.

## Credits

FineWine exists because of these projects:

- **[Wine](https://www.winehq.org/)** — the foundation. FineWine links to
  [WineHQ's donation page](https://www.winehq.org/donate) from its settings.
- **[FEX-Emu](https://fex-emu.com/)** ([source](https://github.com/FEX-Emu/FEX)) — x64
  emulation on ARM64.
- **[DXMT](https://github.com/3Shain/dxmt)** by Feifan He — Direct3D 10/11 on Metal.
- **[MoltenVK](https://github.com/KhronosGroup/MoltenVK)** by the Khronos Group — Vulkan on
  Metal — and **[SPIRV-Cross](https://github.com/KhronosGroup/SPIRV-Cross)**, its shader
  translator.
- **[vkd3d](https://gitlab.winehq.org/wine/vkd3d)** — Direct3D 12 on Vulkan, part of Wine.
- **[llvm-mingw](https://github.com/mstorsjo/llvm-mingw)** by Martin Storsjö and
  **[LLVM](https://llvm.org/)** — the Windows compiler.
- **MSync** by Zebediah Figura and Marc-Aurel Zent — Windows synchronisation on Mach
  semaphores (runtime patch 0001).
- **[CodeWeavers](https://www.codeweavers.com/)** — for the Mac work they contribute to Wine
  and for publishing the sources CrossOver is built from.
- **[GnuTLS](https://www.gnutls.org/)**, **[Nettle](https://www.lysator.liu.se/~nisse/nettle/)**,
  **[GMP](https://gmplib.org/)** and **[FreeType](https://freetype.org/)**.
- **[Valve](https://github.com/ValveSoftware/Proton)** — `lsteamclient` and the Steam helper,
  from Proton — and **[NotProton](https://github.com/NotProtonNot/NotProton)** and
  **[Bridgeplay](https://github.com/raymondchins/Bridgeplay)**, whose macOS ports of them the
  Steam bridge uses and whose Steam Play support it relies on.
- **[dw-proton / Dawn Winery](https://dawn.wine/)** — the Linux work on these games that showed
  what they need.
