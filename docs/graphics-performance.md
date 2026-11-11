# Graphics & performance (D3DMetal, DX11, GPTK4)

The anti-cheat fixes get Endfield past ACE; this page is about making it *render well*. The research background (backends, Endfield's engine, the `cxbottle.conf` keys) is in [06-graphics-and-gptk.md](06-graphics-and-gptk.md); measured numbers for memory-constrained Macs are in [14-performance-on-16gb-macs.md](14-performance-on-16gb-macs.md).

**You may not need GPTK4.** CrossOver 26.3 already bundles **D3DMetal 3.0** (= GPTK 3.0), and that is what Endfield renders on out of the box — it runs well on the tested Apple M4 Pro / macOS 27.0 setup (as well as M3 / macOS 26.5) with no extra graphics work. Apple's **Game Porting Toolkit 4** upgrades that bundled D3DMetal **3.0 → 4** (DirectX 12 → **Metal 4**, MetalFX frame-generation, HDR) for the newest/fastest path — but GPTK4 is **macOS 27-era software**, so treat it as an **optional, advanced** upgrade.

> **16 GB Macs:** Endfield fits, but only just — the game's GPU allocations share unified memory with everything else, so memory, not the GPU, is the limit. Measured numbers, settings that play well, and how to recognise the memory-pressure freeze: [14-performance-on-16gb-macs.md](14-performance-on-16gb-macs.md).

> **On "Vulkan":** GPTK/D3DMetal does **not** provide Vulkan — it translates DirectX **straight to Metal**. Vulkan on Apple GPUs comes from **MoltenVK** (Vulkan → Metal), which CrossOver bundles and CXPatcher/Procyon upgrade. So there are two graphics families: **DirectX → Metal directly** (D3DMetal / DXMT — where GPTK lives) vs **DirectX/Vulkan → Vulkan → Metal** (DXVK / vkd3d + MoltenVK). The direct D3DMetal path is the faster one.

## Renderer: DirectX 11 (recommended) or Vulkan

**For Endfield specifically, DirectX 11 is the most-tested renderer.** The game defaults to Vulkan/DX12. **Vulkan works** through MoltenVK — the patched app bundles a patched MoltenVK — while **DirectX 12 fails** under CrossOver (`vkd3d` can't compile its DXIL shaders → white screen). Setting the CrossOver *backend* to D3DMetal is **not** enough to reroute the game's DX12 off vkd3d — the game itself must run in **DirectX 11** or **Vulkan**:

- start it with the Gryphline launcher's **Launch with DirectX 11** (in the dropdown next to Start), which passes `-force-d3d11`. This is the supported way, **or**
- launch `Endfield.exe` with `-force-d3d11` yourself ([`scripts/launch-endfield.sh`](../scripts/launch-endfield.sh) does). This direct launch is not supported and can stop at a black window on recent game builds.

The in-game graphics settings have no API option, and the plain Start button uses the default renderer. The backend guidance below applies once the game is on a DirectX path. A game update can reset the renderer back to DirectX 12 — that's the usual cause when the white screen "comes back" ([troubleshooting.md](troubleshooting.md)).

### The Vulkan renderer

The game's Vulkan renderer runs through MoltenVK (Vulkan → Metal), not the bottle's D3DMetal setting. The patched app bundles the patched MoltenVK, so **Vulkan works out of the box** — the version notes below explain what older MoltenVK builds got wrong:

- **CrossOver's stock MoltenVK (1.2.10)** also renders, but once the game recreates its swapchain (changing FPS or V-Sync does) the window stays black and the game has to be force-closed ([KhronosGroup/MoltenVK#2722](https://github.com/KhronosGroup/MoltenVK/pull/2722)). `swap-into-crossover.sh` downloads 1.4.2 by default (set `MVK_VER` to pin another release), which includes the fix, and the Patcher bundles the patched 1.4.2.
- **Stock MoltenVK 1.4.2** fixes the black screen. mary-ext reported three problems that remain ([#22](https://github.com/stoicswe/Endfield_FineWine/issues/22)): teleporting to Snowy Forest can hang the GPU (macOS then kills WindowServer, which logs you out), TAAU/FSR3 artifacts near Recycling Stations, and stutter until Metal's pipeline cache is built.
- **This repo's patched MoltenVK** (`patches/x64/moltenvk`, ported from [mary-ext's fork](https://github.com/mary-ext/crossover-wine-endfield)) is meant to fix those three. The FineWine Patcher ships it from 1.1.0 on (nightlies included), so you don't need to build it. To build it yourself, use `scripts/build-moltenvk.sh` (needs full Xcode), then `scripts/package.sh` and `scripts/apply-modules.sh`.
- **After swapping MoltenVK (or changing `MVK_CONFIG_USE_METAL_ARGUMENT_BUFFERS`), delete the game's pipeline cache** — `…/LocalLow/Gryphline/Endfield/vulkan_pso_cache.bin` was compiled by the previous module build and can be reused after the change, drawing some meshes with wrong shader/descriptor data (e.g. bushes/grass as odd, stretched polygons). It is not cleared automatically; delete it manually and let the game rebuild it. See [troubleshooting.md → In-game graphics](troubleshooting.md#in-game-graphics).

Launch it with `GFXARGS=-force-vulkan scripts/launch-endfield.sh`. This uses the direct launch, which is not supported and can stop at a black window on recent game builds.

On a 16 GB M4 (CrossOver 26.2, stock MoltenVK 1.4.2): the first Vulkan launch compiled shaders for ~10 minutes (~3–4 the next time), frame pacing felt smoother than DX11, and it used about half the GPU memory. There's no DLSS under Vulkan; the game offers TAAU and AMD FSR3 instead (FSR3 *Native AA* looked best, and FSR Frame Generation made it slower). Numbers and settings: [14-performance-on-16gb-macs.md](14-performance-on-16gb-macs.md#vulkan-renderer).

Upstream MoltenVK doesn't have two extensions CodeWeavers added to CrossOver's copy (`VK_EXT_transform_feedback`, `VK_NV_glsl_shader`). Endfield doesn't need them, but a DXVK game in the same CrossOver copy might.

## Pick the graphics backend

CrossOver → select the **Arknights Endfield** bottle → **Advanced Settings → Graphics**:

- **D3DMetal** — DirectX 11/12 → Metal, with DLSS upscaling served by MetalFX. GPTK updates replace this backend's D3DMetal payload.
- **DXMT** — DirectX 11 → Metal; supports DLSS upscaling through MetalFX when its NGX resource-parameter fix is present (see below).
- **DXVK** — DirectX 10/11 → Vulkan → MoltenVK (fallback; extra hop, no DLSS).

Enable **MSync**. For DLSS upscaling, enable **DLSS (MetalFX)** with D3DMetal or a DXMT build containing the [NGX resource-parameter fix](technical.md#dlss-under-dxmt-stock-and-patched-builds). With CrossOver 26.3's stock DXMT 0.80, use **TAAU** or **AMD FSR3** until that fix is included; FineWine 1.2.3 preserves the source app's DXMT modules. [`scripts/create-bottle.sh`](../scripts/create-bottle.sh) can set the backend and backend-specific toggle (the `cxbottle.conf` keys are listed in [06-graphics-and-gptk.md → Selecting a backend](06-graphics-and-gptk.md#selecting-a-backend-in-crossover-26)). AVX2 (from Rosetta 2 on macOS 15+, not from GPTK) needs no setting: CrossOver's `wine` wrapper already exports `ROSETTA_ADVERTISE_AVX=1`.

## CrossOver ARM (experimental): recommended settings

These are for an `arm64` bottle made by the FineWine Patcher from **CrossOver Preview ARM**
(preview 20261111, build 27.0.0.41303), which runs Endfield with no Rosetta. They come from testing
on one machine on 2026-11-11, and they differ from x64:

| Setting | ARM | Why |
|---|---|---|
| Graphics backend | **Auto** (no `CX_GRAPHICS_BACKEND`) | The game's Vulkan renderer runs through MoltenVK. **DXMT** renders, but the game stalls every few seconds: in testing, 59 waits of 5 s or more in a 10-minute session, enough to cause hitching and `Server connection timed out`. **D3DMetal** isn't available on ARM: Apple ships it for x86_64 only. |
| MSync | **Off** (`WINEMSYNC = "0"`) | With DXMT, turning it off cut the stalls about threefold. |
| Renderer | The launcher's plain **Start** (Vulkan) | Don't use **Launch with DirectX 11** here; on ARM the DirectX 11 paths are the ones that stall. |
| Upscaling | **TAAU** or **AMD FSR3** | There's no DLSS under Vulkan, so `DXMT_ENABLE_NVEXT` and `D3DM_ENABLE_METALFX` aren't needed. With them on, CrossOver tries to redirect `nvngx.dll` to D3DMetal's x86_64-only copy. |

In the bottle's `cxbottle.conf`, the `[EnvironmentVariables]` section then holds just:

```
"WINEMSYNC" = "0"
```

Things to expect:

- **The first launch looks frozen** for several minutes while every pipeline is compiled through
  MoltenVK (`vulkan_pso_cache.bin` doesn't exist yet). Later launches are faster.
- **The patcher replaces CrossOver ARM's stock MoltenVK 1.2.10** with this repo's patched 1.4.2,
  built for arm64. Copies patched before that still have 1.2.10, where changing FPS or V-Sync can
  leave the window black, and some UI elements drew as **white blocks**; re-patch to get the fixes.
  Whether the patched build cures the white blocks is still being tested.
- **ACE's kernel drivers don't load on ARM.** The game still logged in and played in testing, with
  no ACE message, but longer sessions are untested.
- **One crash on entering the world** has been seen (a failed exception dispatch); entering again
  worked.

Details and measurements: [19-arm-wine-11.21.md](project-information/19-arm-wine-11.21.md).

## Installing GPTK4 (optional)

> **Apple's GPTK is evaluation-only software — download it yourself; you may not redistribute it**, so this repo cannot bundle it. These steps target **macOS 27 (beta)** for GPTK4. On **macOS 26**, CrossOver's bundled **D3DMetal 3.0** is the matched version — no action needed.

> **[FineWine Patcher.app](../patcher-app/README.md) can do this for you:** mount the *"Evaluation environment for Windows games …"* DMG and the patcher's optional **GPTK4 / D3DMetal** step installs it into the copy it creates (`lib64/apple_gptk/external/`, plus the D3DMetal DLLs from the DMG's `redist/lib/wine/`). It is never bundled or redistributed — the app reads the DMG you supplied. The manual steps below are the equivalent if you prefer the shell script or a CXPatcher/Procyon workflow.

### 1. Download from Apple

[developer.apple.com/games/game-porting-toolkit](https://developer.apple.com/games/game-porting-toolkit/) → the Downloads list ([search "Game Porting Toolkit"](https://developer.apple.com/download/all/?q=game%20porting%20toolkit)). Sign in with an Apple ID (a free Apple Developer account has historically been enough). The file you want is **"Evaluation environment for Windows games 4.x"** (listed next to "Game Porting Toolkit 4.x") — its DMG holds the D3DMetal redistributable in `redist/lib/external/`. Mount the `.dmg` (it appears under `/Volumes/…`; run `ls /Volumes/` to get its exact name).

### 2. Apply it to your **patched** CrossOver copy

Apply it to the patched copy, so you keep both the anti-cheat fixes **and** GPTK4.

**Scripted (recommended)** — point the swap script at the DMG's `redist/lib/external` and it rebuilds the patched app with D3DMetal and its DLLs (from the sibling `redist/lib/wine`) replaced, Apple's signatures intact, and the bundle re-sealed:

```bash
GPTK_DIR="/Volumes/<mounted GPTK volume>/redist/lib/external" ./scripts/swap-into-crossover.sh
```

(Copy the DMG's whole `redist/lib` to `~/Downloads/GPTK_4/redist/lib` — the script's default `GPTK_DIR` is its `external` — and later rebuilds pick it up without the DMG.)

**Manual** — replace the two D3DMetal libraries and the D3DMetal DLLs (keep the `-old` backups), then re-seal the bundle:

```bash
GPTK_VOL="/Volumes/<mounted GPTK volume — check with: ls /Volumes/>"
APP="/Applications/CrossOver_Endfield_Patch.app"
cd "$APP/Contents/SharedSupport/CrossOver/lib64/apple_gptk/external"
mv D3DMetal.framework D3DMetal.framework-old
mv libd3dshared.dylib  libd3dshared.dylib-old
ditto --noextattr --noqtn "$GPTK_VOL/redist/lib/external/" .
cd ../wine
mv x86_64-windows x86_64-windows-old && mv x86_64-unix x86_64-unix-old && mkdir x86_64-unix
ditto --noextattr --noqtn "$GPTK_VOL/redist/lib/wine/x86_64-windows/" x86_64-windows/
for so in "$GPTK_VOL"/redist/lib/wine/x86_64-unix/*.so; do ln -s ../../external/libd3dshared.dylib "x86_64-unix/$(basename "$so")"; done
cd - >/dev/null
xattr -rd com.apple.FinderInfo "$APP"
codesign --force --sign - --preserve-metadata=entitlements "$APP"   # editing the app broke its seal
codesign --verify --deep --strict "$APP" && echo "patched app verifies"
```

If macOS refuses to modify the app ("Operation not permitted" — App Management protects apps that have been launched), use the scripted path, which builds a fresh copy.

(The folder is `apple_gptk`, with a trailing **k**. Only `redist/lib/external/` and the DLLs in `redist/lib/wine/x86_64-windows/` are needed — ignore the DMG's Homebrew/Wine path, which is for *standalone* GPTK. The DLLs go into `apple_gptk/wine/`, never into `lib/wine/`. CrossOver's own `apple_gptk/wine/` DLLs are Apple's D3DMetal glue too, built for 3.0, and each `x86_64-unix/*.so` there is just a link to `external/libd3dshared.dylib`.)

**CXPatcher / Procyon (easier)** — [CXPatcher](https://github.com/italomandara/CXPatcher) drops a GPTK `.dmg`'s D3DMetal into a CrossOver copy automatically (drag CrossOver in, keep "Integrate D3DMetal (GPTK)" on, point it at your GPTK dmg). Its author has moved **GPTK4** support to the successor **[Procyon](https://github.com/italomandara/Procyon)** — use Procyon's pre-release for GPTK4. These tools patch **graphics only**; you still need this project's Wine-module swap for the anti-cheat, so apply **both** to the same CrossOver copy (e.g. run `swap-into-crossover.sh` on the CXPatcher/Procyon output).

### Caveats

- **GPTK4 wants macOS 27 (beta)** + Metal 4. On **macOS 26, stay on the bundled D3DMetal 3.0.** GPTK4 in **CrossOver 26.3**: D3DMetal **4.0b2** ("Evaluation environment for Windows games 4.0 beta 2") installed with `swap-into-crossover.sh` runs Endfield in DX11 mode on an M4 / macOS 27.0 (verified 2026-09-23; 4.0b1 was the original tested config). Keep the `-old` / `external.cxorig` backups and be ready to revert (`SKIP_GPTK=1 ./scripts/swap-into-crossover.sh` rebuilds with the stock 3.0); CrossOver 27 / Procyon may be the smoother route.
- **D3DMetal 4.0b3 and later must be installed with their own DLLs.** Their DLLs call into the framework through a jump table, and CrossOver 26.3's D3DMetal 3.0 DLLs pass it garbage: every DirectX 11 program crashes inside `d3d11.dll` as it loads, then hangs on Wine's loader lock (seen first with the CN Gryphline launcher). 4.0b1 and 4.0b2 still run with CrossOver's 3.0 DLLs. The patcher and `swap-into-crossover.sh` install the DMG's DLLs automatically and refuse a 4.0b3+ framework without them. A CrossOver 27 app also works as the source: it ships D3DMetal 4.0b3 with matching DLLs in `lib/apple_gptk/`.
- Apple Silicon only; Rosetta 2 required.

## Performance notes

- On the reference M4 Pro the game runs well at default D3DMetal 3.0 with DX11; see [14-performance-on-16gb-macs.md](14-performance-on-16gb-macs.md) for what changes on 16 GB Macs (memory is the limit, not the GPU), which settings to lower first, and how to spot the memory-pressure freeze.
- Endfield's engine is **Unity IL2CPP** with a heavily customised renderer — see [06-graphics-and-gptk.md](06-graphics-and-gptk.md) for why only the DX11 path works and how the backends differ.
