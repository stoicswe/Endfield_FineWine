# Troubleshooting

Common failures when running Arknights: Endfield through the patched CrossOver build, and what to do about them. For deeper engineering detail, follow the links into the research docs. To capture logs for a bug report, see [Debug logging](installation.md#debug-logging) in [installation.md](installation.md).

## Setup & deployment

- **"CrossOver.app is version X, expected 26.3"** — the swap needs a matching Wine ABI. Install CrossOver 26.3.
- **"CrossOver_Endfield_Patch is damaged and can't be opened" (over and over) / binaries killed with exit 137** — the patched bundle's signature seal is missing or broken. Click **Cancel** (not *Move to Trash*), then re-run `./scripts/swap-into-crossover.sh`, which re-seals it (it moves an old copy macOS won't let it delete to the Trash). If you edited files inside the patched app by hand, re-seal it: `codesign --force --sign - --preserve-metadata=entitlements /Applications/CrossOver_Endfield_Patch.app`. Details: [05-swapping-into-crossover.md → Verified recipe](05-swapping-into-crossover.md#verified-recipe-2026-09-crossover-2620--macos-270--m4).
- **ACE "driver error 13" comes back** — the patched `ntdll.so`/`ntoskrnl.exe` aren't loading; verify the swap paths and that you launched the *patched* app.
- **Start programs from the CrossOver window**, not from the per-program app stubs CrossOver creates in `~/Applications/CrossOver/` (also what Spotlight/Launchpad find). Those stubs' signatures don't verify (`codesign`: "code has no resources but signature indicates they must be present"), so macOS can report them as damaged.
- **GRYPHLINK isn't listed in the bottle** (CrossOver shows only "Uninstall GRYPHLINK") — the launcher's shortcuts weren't registered with CrossOver's menus (seen after installing the launcher from the command line). Re-register them, then reopen the bottle's page: `/Applications/CrossOver_Endfield_Patch.app/Contents/SharedSupport/CrossOver/bin/cxmenu --bottle "Arknights Endfield" --install`.

## In-game graphics

- **White / blank screen (very common after a game update)** — the game shipped an update that reset its renderer to **Vulkan or DirectX 12**, and neither works well under CrossOver 26.3 (DX12 → `vkd3d` can't compile the game's DXIL/SM6 shaders → `Cannot load DXIL conversion library`; Vulkan needs a newer MoltenVK, see below). **Fix: run the game in DirectX 11** — start it with the launcher's **Launch with DirectX 11** (dropdown next to the Start button; the plain Start button uses the default renderer), or launch Unity with `-force-d3d11`. DX11 uses the mature D3DMetal/DXMT path and renders correctly. Do **not** try to fix this by overwriting CrossOver's `d3d11/d3d12/dxgi.dll` with the `apple_gptk` copies — that breaks `unityplayer.dll` init (Windows error **1114**); those D3DMetal DLLs are only meant to be loaded through CrossOver's own backend mechanism. Background: [graphics-performance.md](graphics-performance.md).
- **Vulkan mode: the screen goes black after you change FPS or V-Sync** — CrossOver's MoltenVK doesn't survive the game recreating its swapchain. The game keeps running but won't close normally; stop it with:
  ```bash
  CXR="/Applications/CrossOver_Endfield_Patch.app/Contents/SharedSupport/CrossOver"
  WINEPREFIX="$HOME/Library/Application Support/CrossOver/Bottles/Arknights Endfield" CX_ROOT="$CXR" "$CXR/bin/wineserver" -k
  ```
  Then install MoltenVK 1.4.2 or the patched one ([graphics-performance.md](graphics-performance.md#experimental-the-vulkan-renderer)), or play in DirectX 11.
- **Vulkan mode: logged out with every app closed after teleporting to Snowy Forest** — a GPU hang that makes macOS kill WindowServer ([#22](https://github.com/stoicswe/Endfield_FineWine/issues/22)). The patched MoltenVK is meant to fix this; with stock MoltenVK, play that area in DirectX 11.
- **`unityplayer.dll` "missing or corrupt" (error 1114)** — a DLL-init failure, usually from swapping graphics DLLs (see above) or launching `Endfield.exe` directly without the launcher's working directory. Restore CrossOver's default `d3d11/d3d12/dxgi.dll`, and launch via the Gryphline launcher.
- **High Resolution Mode** (the bottle's Advanced Settings) renders a white screen — leave it off ([#2](https://github.com/stoicswe/Endfield_FineWine/issues/2)).
- **Black screen on later launches** — reported in [#2](https://github.com/stoicswe/Endfield_FineWine/issues/2); the reporter's workaround was to delete the game's registry data (`HKCU\Software\Gryphline\Endfield` and `…\Gryphline\sdk_data\…` — settings and login cache, e.g. via CrossOver → *Run Command* → `regedit`) and log in again. That resets the in-game settings.

## General

- **Two copies of the game running** — e.g. a direct `launch-endfield.sh` start plus one from the launcher. They fight over the same files ("The process cannot access the file…" in `Player.log`); quit both and start one.
- **Freeze with sound still playing on a 16 GB Mac** — the memory-pressure freeze described in [14-performance-on-16gb-macs.md](14-performance-on-16gb-macs.md); force-quit, free memory, relaunch.
- **Something else?** Capture a failure log with [`scripts/01-capture-failure.sh`](../scripts/01-capture-failure.sh) and open an issue. How the capture loop was used to find the original failure: [10-milestone-1-results.md](10-milestone-1-results.md).