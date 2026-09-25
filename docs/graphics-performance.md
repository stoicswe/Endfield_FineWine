# Graphics & performance (D3DMetal, DX11, GPTK4)

The anti-cheat fixes get Endfield past ACE; this page is about making it *render well*. The research background (backends, Endfield's engine, the `cxbottle.conf` keys) is in [06-graphics-and-gptk.md](06-graphics-and-gptk.md); measured numbers for memory-constrained Macs are in [14-performance-on-16gb-macs.md](14-performance-on-16gb-macs.md).

**You may not need GPTK4.** CrossOver 26.3 already bundles **D3DMetal 3.0** (= GPTK 3.0), and that is what Endfield renders on out of the box — it runs well on the tested Apple M4 Pro / macOS 27.0 setup (as well as M3 / macOS 26.5) with no extra graphics work. Apple's **Game Porting Toolkit 4** upgrades that bundled D3DMetal **3.0 → 4** (DirectX 12 → **Metal 4**, MetalFX frame-generation, HDR) for the newest/fastest path — but GPTK4 is **macOS 27-era software**, so treat it as an **optional, advanced** upgrade.

> **16 GB Macs:** Endfield fits, but only just — the game's GPU allocations share unified memory with everything else, so memory, not the GPU, is the limit. Measured numbers, settings that play well, and how to recognise the memory-pressure freeze: [14-performance-on-16gb-macs.md](14-performance-on-16gb-macs.md).

> **On "Vulkan":** GPTK/D3DMetal does **not** provide Vulkan — it translates DirectX **straight to Metal**. Vulkan on Apple GPUs comes from **MoltenVK** (Vulkan → Metal), which CrossOver bundles and CXPatcher/Procyon upgrade. So there are two graphics families: **DirectX → Metal directly** (D3DMetal / DXMT — where GPTK lives) vs **DirectX/Vulkan → Vulkan → Metal** (DXVK / vkd3d + MoltenVK). The direct D3DMetal path is the faster one.

## ⚠️ Run Endfield in DirectX 11 (or, experimentally, Vulkan)

**For Endfield specifically: set the game's own renderer to DirectX 11.** Endfield defaults to Vulkan/DX12. DX12 fails under CrossOver (`vkd3d` can't compile its DXIL shaders → white screen), and Vulkan needs a newer MoltenVK than CrossOver ships ([below](#experimental-the-vulkan-renderer)). Setting the CrossOver *backend* to D3DMetal is **not** enough to reroute the game's DX12 off vkd3d — the game itself must run in **DirectX 11**:

- start it with the Gryphline launcher's **Launch with DirectX 11** (in the dropdown next to Start), which passes `-force-d3d11`, **or**
- launch `Endfield.exe` with `-force-d3d11` yourself ([`scripts/launch-endfield.sh`](../scripts/launch-endfield.sh) does).

The in-game graphics settings have no API option, and the plain Start button uses the default renderer. The backend guidance below applies once the game is on a DirectX path. A game update can reset the renderer back to Vulkan/DX12 — that's the usual cause when the white screen "comes back" ([troubleshooting.md](troubleshooting.md)).

### Experimental: the Vulkan renderer

The game's Vulkan renderer runs through MoltenVK (Vulkan → Metal), not the bottle's D3DMetal setting, so the MoltenVK in the patched app's `lib64/` decides how well it works:

- **CrossOver's bundled MoltenVK (1.2.10)** renders, but once the game recreates its swapchain (changing FPS or V-Sync does) the window stays black and the game has to be force-closed ([KhronosGroup/MoltenVK#2722](https://github.com/KhronosGroup/MoltenVK/pull/2722)). `swap-into-crossover.sh` downloads 1.4.1 by default, which predates the fix.
- **Stock MoltenVK 1.4.2** fixes the black screen. mary-ext reported three problems that remain ([#22](https://github.com/stoicswe/Endfield_FineWine/issues/22)): teleporting to Snowy Forest can hang the GPU (macOS then kills WindowServer, which logs you out), TAAU/FSR3 artifacts near Recycling Stations, and stutter until Metal's pipeline cache is built.
- **This repo's patched MoltenVK** (`patches/moltenvk`, ported from [mary-ext's fork](https://github.com/mary-ext/crossover-wine-endfield)) is meant to fix those three. Build it with `scripts/build-moltenvk.sh` (needs full Xcode), then install it with `scripts/package.sh` and `scripts/apply-modules.sh`.

Launch it with `GFXARGS=-force-vulkan scripts/launch-endfield.sh`.

On a 16 GB M4 (CrossOver 26.2, stock MoltenVK 1.4.2): the first Vulkan launch compiled shaders for ~10 minutes (~3–4 the next time), frame pacing felt smoother than DX11, and it used about half the GPU memory. There's no DLSS under Vulkan; the game offers TAAU and AMD FSR3 instead (FSR3 *Native AA* looked best, and FSR Frame Generation made it slower). Numbers and settings: [14-performance-on-16gb-macs.md](14-performance-on-16gb-macs.md#vulkan-renderer-experimental).

Upstream MoltenVK doesn't have two extensions CodeWeavers added to CrossOver's copy (`VK_EXT_transform_feedback`, `VK_NV_glsl_shader`). Endfield doesn't need them, but a DXVK game in the same CrossOver copy might.

## Pick the graphics backend

CrossOver → select the **Arknights Endfield** bottle → **Advanced Settings → Graphics**:

- **D3DMetal** *(recommended)* — DirectX 11/12 → Metal. With GPTK4, DX12 → Metal 4 is fastest, and it's the only path with **DLSS-via-MetalFX** frame generation. Force the game into **DirectX 12** mode for the full benefit.
- **DXMT** — good for DirectX 11 titles; also supports the DLSS/MetalFX toggle.
- **DXVK** — DirectX 10/11 → Vulkan → MoltenVK (fallback; extra hop, no DLSS).

Also enable **DLSS (MetalFX)** and **MSync** — or let [`scripts/create-bottle.sh`](../scripts/create-bottle.sh) set the backend and both toggles (the `cxbottle.conf` keys are listed in [06-graphics-and-gptk.md → Selecting a backend](06-graphics-and-gptk.md#selecting-a-backend-in-crossover-26)). AVX2 (from Rosetta 2 on macOS 15+, not from GPTK) needs no setting: CrossOver's `wine` wrapper already exports `ROSETTA_ADVERTISE_AVX=1`.

## Installing GPTK4 (optional)

> **Apple's GPTK is evaluation-only software — download it yourself; you may not redistribute it**, so this repo cannot bundle it. These steps target **macOS 27 (beta)** for GPTK4. On **macOS 26**, CrossOver's bundled **D3DMetal 3.0** is the matched version — no action needed.

### 1. Download from Apple

[developer.apple.com/games/game-porting-toolkit](https://developer.apple.com/games/game-porting-toolkit/) → the Downloads list ([search "Game Porting Toolkit"](https://developer.apple.com/download/all/?q=game%20porting%20toolkit)). Sign in with an Apple ID (a free Apple Developer account has historically been enough). The file you want is **"Evaluation environment for Windows games 4.x"** (listed next to "Game Porting Toolkit 4.x") — its DMG holds the D3DMetal redistributable in `redist/lib/external/`. Mount the `.dmg` (it appears under `/Volumes/…`; run `ls /Volumes/` to get its exact name).

### 2. Apply it to your **patched** CrossOver copy

Apply it to the patched copy, so you keep both the anti-cheat fixes **and** GPTK4.

**Scripted (recommended)** — point the swap script at the DMG's `redist/lib/external` and it rebuilds the patched app with D3DMetal replaced, Apple's signatures intact, and the bundle re-sealed:

```bash
GPTK_DIR="/Volumes/<mounted GPTK volume>/redist/lib/external" ./scripts/swap-into-crossover.sh
```

(Copy that folder to `~/Downloads/GPTK_4/redist/lib/external` — the script's default `GPTK_DIR` — and later rebuilds pick it up without the DMG.)

**Manual** — replace the two D3DMetal libraries (keep the `-old` backups), then re-seal the bundle:

```bash
GPTK_VOL="/Volumes/<mounted GPTK volume — check with: ls /Volumes/>"
APP="/Applications/CrossOver_Endfield_Patch.app"
cd "$APP/Contents/SharedSupport/CrossOver/lib64/apple_gptk/external"
mv D3DMetal.framework D3DMetal.framework-old
mv libd3dshared.dylib  libd3dshared.dylib-old
ditto --noextattr --noqtn "$GPTK_VOL/redist/lib/external/" .
cd - >/dev/null
xattr -rd com.apple.FinderInfo "$APP"
codesign --force --sign - --preserve-metadata=entitlements "$APP"   # editing the app broke its seal
codesign --verify --deep --strict "$APP" && echo "patched app verifies"
```

If macOS refuses to modify the app ("Operation not permitted" — App Management protects apps that have been launched), use the scripted path, which builds a fresh copy.

(The folder is `apple_gptk`, with a trailing **k**. Only the `redist/lib/external/` libraries are needed — ignore the DMG's Homebrew/Wine path, which is for *standalone* GPTK. Don't copy the DMG's `redist/lib/wine/` DLLs either: CrossOver has its own D3DMetal glue in `apple_gptk/wine/` — with native `.so` halves — and Apple's standalone-Wine DLLs are not interchangeable with it.)

**CXPatcher / Procyon (easier)** — [CXPatcher](https://github.com/italomandara/CXPatcher) drops a GPTK `.dmg`'s D3DMetal into a CrossOver copy automatically (drag CrossOver in, keep "Integrate D3DMetal (GPTK)" on, point it at your GPTK dmg). Its author has moved **GPTK4** support to the successor **[Procyon](https://github.com/italomandara/Procyon)** — use Procyon's pre-release for GPTK4. These tools patch **graphics only**; you still need this project's Wine-module swap for the anti-cheat, so apply **both** to the same CrossOver copy (e.g. run `swap-into-crossover.sh` on the CXPatcher/Procyon output).

### Caveats

- **GPTK4 wants macOS 27 (beta)** + Metal 4. On **macOS 26, stay on the bundled D3DMetal 3.0.** GPTK4 in **CrossOver 26.3**: D3DMetal **4.0b2** ("Evaluation environment for Windows games 4.0 beta 2") installed with `swap-into-crossover.sh` runs Endfield in DX11 mode on an M4 / macOS 27.0 (verified 2026-09-23; 4.0b1 was the original tested config). Keep the `-old` / `external.cxorig` backups and be ready to revert (`SKIP_GPTK=1 ./scripts/swap-into-crossover.sh` rebuilds with the stock 3.0); CrossOver 27 / Procyon may be the smoother route.
- Apple Silicon only; Rosetta 2 required.

## Performance notes

- On the reference M4 Pro the game runs well at default D3DMetal 3.0 with DX11; see [14-performance-on-16gb-macs.md](14-performance-on-16gb-macs.md) for what changes on 16 GB Macs (memory is the limit, not the GPU), which settings to lower first, and how to spot the memory-pressure freeze.
- Endfield's engine is **Unity IL2CPP** with a heavily customised renderer — see [06-graphics-and-gptk.md](06-graphics-and-gptk.md) for why only the DX11 path works and how the backends differ.