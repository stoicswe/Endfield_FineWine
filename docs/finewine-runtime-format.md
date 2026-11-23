# FineWine runtime descriptions (`runtime.json`)

FineWine (the standalone app) runs Windows programs with a *runtime*: a Wine build plus a small
file, `runtime.json`, that tells the app what the build is and how to start it. The runtime
inside FineWine.app has one, and you can write one for another Wine build so that FineWine can
create prefixes with it.

This page is the format. It is at version 2; a file without the version 2 fields means what it
always did.

## Two ways to lay a runtime out

**The build and its description together.** `runtime.json` is at the root of the Wine build,
beside `bin/` and `lib/`. This is how FineWine's own runtime is packaged. Adding such a folder
(Settings → Add Runtime…) copies the whole folder into FineWine's Runtimes folder.

**A description by itself.** A folder with nothing in it but `runtime.json`, whose `root` says
where the Wine build is. Adding it copies only the description; the build stays where it is and
is never changed. This is the way to describe a Wine build that belongs to another app.

A folder with no `runtime.json` at all can still be added if it has `bin/wine`, `bin/wineserver`
and `lib/wine`. It is used where it is and is taken to have no FineWine features.

## Fields

| Field | Type | Default | Meaning |
|---|---|---|---|
| `id` | text | required | Unique name. Letters, digits, `.`, `-`, `_` only: it is used as a folder name. |
| `name` | text | the id | What the app shows. |
| `version` | text | empty | Your version of this runtime. |
| `wineVersion` | text | empty | The Wine release it is based on; shown as a label. |
| `architecture` | text | `arm64` | The Mac-side architecture of the build. |
| `graphics` | object | none | Direct3D backends the build ships, see below. |
| `formatVersion` | number | 1 | The format the file is written in. Write `2` when you use any field below. A file with a higher number than the app knows is refused. |
| `root` | text | the file's folder | Where the Wine build is: an absolute path, or one starting with `~/`. |
| `loader` | text | `bin/wine`, then `bin/wine64` | The program that starts Wine, relative to the build. |
| `server` | text | `bin/wineserver`, then `bin/wineserver-arm64` | The Wine server, relative to the build. |
| `libraryPath` | list of text | `["lib"]` | Folders of Mac libraries, relative to the build. They go on `DYLD_FALLBACK_LIBRARY_PATH`. |
| `environment` | object | none | Variables every Wine process gets. See placeholders below. |
| `capabilities` | list of text | every capability | The FineWine features the build has. See the list below. |
| `prefixSetup` | list of text | `["wineboot", "--init"]` | The arguments the loader is given to set a new prefix up. Placeholders work here too. |

`loader`, `server` and `libraryPath` must be relative paths that stay inside the build (no
leading `/` or `~`, no `..`).

### Placeholders

In `environment` values and `prefixSetup` arguments:

| Placeholder | Replaced with |
|---|---|
| `${root}` | the Wine build |
| `${folder}` | the folder `runtime.json` is in |
| `${prefix}` | the prefix the process runs in |
| `${home}` | the user's home folder |

### What FineWine sets by itself

Every process gets `WINEPREFIX` (the prefix), `WINESERVER` (the server above), `PATH` (the
loader's folder first), `DYLD_FALLBACK_LIBRARY_PATH`, `WINEDLLOVERRIDES` and `WINEDEBUG`. From
FineWine's own environment only `PATH`, `HOME`, `USER`, `LOGNAME`, `TMPDIR`, `LANG`, `LC_ALL`
and `SHELL` are passed on.

The order is: FineWine's variables, then the description's `environment`, then the prefix's
settings and the user's own variables for that prefix. A later one replaces an earlier one. A
description may not set `WINEPREFIX`: the app finds a prefix's processes by it.

### Capabilities

A capability is a FineWine feature that needs code inside the runtime. Leave `capabilities` out
only for a build made from this repository's patches; for any other Wine build, list what it
really has (often nothing: `[]`). For a capability a runtime lacks, the prefix setting is greyed
out and nothing is passed to the runtime for it.

| Capability | The setting it covers | What the runtime is given |
|---|---|---|
| `upscaling` | Automatic MetalFX upscaling, render size, the menu switch | `FINEWINE_METALFX_AUTO`, `FINEWINE_RENDER_SCALE` |
| `dlss` | DLSS through MetalFX | `FINEWINE_DLSS`, `DXMT_ENABLE_NVEXT` |
| `gpuIdentity` | Report an NVIDIA GPU | `FINEWINE_GPU_*`, `WINE_D3D_CONFIG`, `DXMT_CONFIG` |
| `fullScreenModes` | How programs go full screen | `FINEWINE_FULLSCREEN` |
| `roundedWindows` | Rounded window corners | `FINEWINE_ROUNDED_WINDOWS` |
| `gameMode` | Game Mode | `FINEWINE_LOADER`, `FINEWINE_GAME_MARKER`; needs `lib/wine/aarch64-unix/FineWine Game.app` |
| `steamStandIn` | Start HoYoverse games through the Steam stand-in | needs the stand-in file in the build |
| `metalHUD` | Metal's overlay, shown and hidden while running | `FINEWINE_METAL_HUD` |
| `msync` | MSync | `WINEMSYNC` |
| `emulator` | The FEX settings | `FEX_HIDEHYPERVISORBIT`, `FEX_COMPACTBLOCKRECORDS` |
| `zeroPages` | Zero pages | `FINEWINE_ZERO_PAGES` |
| `macIcons` | Mac-style icons | `FINEWINE_MAC_ICONS` |
| `macFileDialogs` | Mac open and save panels | `FINEWINE_NATIVE_FILE_DIALOGS` |

Settings that are written to the prefix's registry (Windows version, Retina mode, DPI, virtual
desktop, DLL overrides, the Option keys) work with any Wine and need no capability.

### Graphics backends

`graphics` lists Direct3D translation layers the build ships, keyed by backend name (`dxmt`):

```json
"graphics": {
  "dxmt": { "dllPath": "lib/dxmt", "overrides": { "d3d11": "n,b" } }
}
```

`dllPath` is a folder of Wine DLLs relative to the build; it is put on `WINEDLLPATH`.
`overrides` are added to `WINEDLLOVERRIDES`. A prefix set to a backend the runtime does not
list uses Wine's own Direct3D.

One more key is not a choice of backend: `dxvk-d3d9`, DXVK's Direct3D 9
(`{ "dllPath": "lib/dxvk", "overrides": {} }`, with `i386-windows/d3d9.dll` and
`aarch64-windows/d3d9.dll` in that folder, marked as Wine builtins). A runtime that lists it
offers the prefix setting "Direct3D 9 and older on Vulkan": with the setting on, the folder
goes on `WINEDLLPATH` ahead of the backend's, and `FINEWINE_DXVK_FEATURES=1` and
`DXVK_LOG_LEVEL=none` are set. Without the key the setting is greyed out and does nothing.

## Example: a description by itself

```json
{
  "formatVersion": 2,
  "id": "example-wine-10",
  "name": "Example Wine 10",
  "wineVersion": "10.0",
  "architecture": "x86_64",
  "root": "/Applications/Example.app/Contents/Resources/wine",
  "loader": "bin/wine64",
  "server": "bin/wineserver",
  "libraryPath": ["lib", "lib/external"],
  "environment": {
    "EXAMPLE_DATA": "${root}/share/example"
  },
  "capabilities": []
}
```

Put it in a folder of its own, as `runtime.json`, and add that folder in FineWine's settings.

## What the app checks

A runtime is offered for new prefixes only when all of this holds; otherwise the app says which
part failed:

- `formatVersion` is one the app knows.
- `root`, when given, is absolute (or `~/…`) and the folder exists.
- The loader and the server exist and are executable.
- `lib/wine` exists in the build.
- No path leads out of the build, and `environment` does not set `WINEPREFIX`.

## CrossOver

CrossOver's folder (`CrossOver.app/Contents/SharedSupport/CrossOver`) is refused when it is
added as it is. Its `bin/wine` is a script that works only with CrossOver's bottles: started
for a FineWine prefix it ignores the prefix and stops with "Unable to find the 'default'
bottle".

A description that names another `loader` in that folder is accepted, because it says how the
build is to be started instead. Writing one is up to you, and so is finding out which variables
that Wine needs; FineWine does not ship or test one. Keep in mind:

- It needs a CrossOver the user has installed and licensed. Nothing of it may be copied.
- Its capabilities are `[]`: none of FineWine's features are in it.
- A prefix made this way is a plain Wine prefix, not a CrossOver bottle.

## Limits of the format

A description can only state things. It cannot run a script of its own before or after a
program, and it cannot change how FineWine lays a prefix out. A Wine build that needs either is
not something this format covers yet.
