# 06 — Graphics: GPTK4 / D3DMetal / DXMT / DXVK, and Endfield's renderers

> Source area: `gptk-graphics` (research + adversarial verify). Overall reliability: **high**.
>
> **Scope note:** Graphics is a **downstream** concern. The anti-cheat is the launch blocker; graphics only matters *after* the game gets past ACE. Nothing in this doc unblocks the launch. It exists so the future implementer knows the backend landscape when tuning a game that already boots.

## The launcher vs. the game (important distinction)

- The Endfield launcher (**GRYPHLINK / Gryphlink**) is a **CEF/Chromium-style web UI**. Process evidence: it spawns `QtWebEngineProcess.exe` (Qt WebEngine) and `CefViewWing.exe` (Chromium Embedded Framework). `[confidence: high — CONFIRMED]`
- Therefore **"the launcher works on GPTK4" says almost nothing about the game's 3D path** — a CEF UI has trivial GPU needs. Don't over-index on launcher success.
- CodeWeavers' test: on macOS 26 (Tahoe) with CrossOver 25.1.1, a **~1 ms Gryphlink launcher frame renders, then ACE force-quits the app**. `[confidence: high — CONFIRMED]` The blocker is anti-cheat, not graphics.

## Endfield's engine and renderers

- **Unreal Engine 5** (not Unity). `[confidence: high — CONFIRMED]`
- Renderers: **Vulkan (default/native)**, **DirectX 12** (alternative; can crash on some systems), **DirectX 11** (compatibility fallback). `[confidence: high]`
- ⚠️ Minor conflicting chatter exists (a few social posts claim "modified Unity"; one guide phrases the default as DX12) but the weight of reputable sources supports **UE5 / Vulkan-default / DX11-fallback**.

**Consequence for the Metal stack:** Endfield defaults to **Vulkan**, but the mature macOS translation paths are DirectX→Metal. So the practical question (once ACE is satisfied) is whether to:
- force **DirectX 11** and use **DXMT** or **DXVK**, or
- force/allow **DirectX 12** and use **D3DMetal**, or
- keep **Vulkan** and run it via **MoltenVK** (not the recommended path).

There is a community guide "disable Vulkan, force DirectX 11" for Endfield — likely the pragmatic macOS choice, but **unverified downstream of the anti-cheat fix**.

## The macOS graphics backends

### GPTK / D3DMetal (Apple, closed source)
- Apple's **Game Porting Toolkit** pairs a Wine environment with **`D3DMetal.framework`** (~134 MiB), which translates **Direct3D 11 and 12 directly to Metal** (skipping the DXVK→MoltenVK hops).
- **GPTK4** (released **June 2026**): its **D3DMetal 4** translator converts **DirectX 12 → Metal 4** (Apple's newest graphics API); DX11 titles fall back to Metal 3. `[confidence: high — CONFIRMED]`
- ⚠️ **CrossOver 26 bundles D3DMetal 3.0, NOT GPTK4.** GPTK4 (June 2026) postdates CrossOver 26 (Feb 2026). Using GPTK4 with CrossOver likely requires **manual integration** (CXPatcher-style payload swap into `/lib64/apple_gpt`) or a later CrossOver point release. **This is the crux of the user's "launcher works on GPTK4" note** — GPTK4 is newer than what CrossOver ships, so it's a manual add.
- Trade-off: D3DMetal's GPU-sync model adds **CPU overhead**, worst for modern D3D12 pipelines. `[confidence: medium — PLAUSIBLE, community-sourced]`

### DXMT (`3Shain/dxmt`, open source, CodeWeavers-funded)
- Metal-based **D3D11 / D3D10** translation layer targeting D3D11.1 feature level; shader converter **`airconv`** transpiles DXBC → LLVM IR / Apple AIR. `[confidence: high for existence; PLAUSIBLE for internals]`
- Latest **v0.80 (2026-04-23)**; timeline v0.71 (2025-11) → v0.72 (2025-12, in CrossOver 26) → v0.73 (2026-01) → v0.74 (2026-03) → v0.80 (2026-04). First release **v0.50 = 2025-04-26** (a 2025-onward project). `[confidence: high — CONFIRMED via GitHub API]`
- **No shipping D3D12** (README says D3D11/10 only), though a `d3d12` directory exists in-tree (experimental). Users report large gains vs. DXVK+MoltenVK for D3D11.
- ⚠️ Submodule paths the research cited (`external/nvapi`, `include/native/directx`) look **inaccurate** — nvapi is at `src/nvapi` in the tree. Don't rely on those paths.

### DXVK + MoltenVK (open source)
- Classic two-hop: DirectX 9/10/11 → **Vulkan (DXVK)** → **Metal (MoltenVK)**. Broad D3D9/10/11 support; **no D3D12** (D3D12 goes via **vkd3d** → Vulkan → MoltenVK instead).

### ⚠️ Correction: D3DMetal is NOT the only way to run D3D12
The research's "D3DMetal is the only D3D12-capable path" was **REFUTED**. `vkd3d 1.18` (bundled in CrossOver 26) also translates **D3D12 → Vulkan → MoltenVK → Metal**. D3DMetal is only the backend that does D3D12 **directly** to Metal.

## Selecting a backend in CrossOver 26

CrossOver 26's Advanced Settings expose **five per-bottle backends**: `Auto | DXMT | D3DMetal | DXVK | Wine (wined3d)`. `[confidence: high — CONFIRMED]`
- Enabling D3DMetal or DXVK applies to **all apps in the bottle**.
- Extra toggles: **DLSS-powered-by-MetalFX** (D3DMetal + DXMT only), **MSync** (Mach-semaphore sync), **High Resolution Mode** (192 DPI, disables pixel doubling).
- ⚠️ The `cxbottle.conf` variable names `WINED3DMETAL` / `WINEDXVK` (0/1) are **not documented** in CodeWeavers' GUI-only settings doc — treat the exact key names/syntax as **unverified**. No `WINEDXMT`-style key was confirmed. Set backends via the GUI, or reverse-engineer the conf keys empirically.

## CrossOver 26 graphics stack (for reference)
```
Wine 11.0 · Wine Mono 10.4.1 · vkd3d 1.18 (D3D12→Vulkan) · DXMT v0.72 · D3DMetal 3.0
```

## Open questions
- Which CrossOver/Whisky version, if any, bundles **D3DMetal 4 / GPTK4** (only D3DMetal 3.0 confirmed bundled as of CrossOver 26). How to manually integrate GPTK4 into a custom bundle.
- For Endfield's game process once ACE is bypassed: which backend (D3DMetal DX12 vs forced-DX11 via DXMT/DXVK vs Vulkan/MoltenVK) actually yields a playable result.
- Whether Endfield's Vulkan default runs under CrossOver via MoltenVK, or whether forcing DX11/DX12 is mandatory.
- Exact `cxbottle.conf` backend-selection syntax.

## Primary sources
- Apple GPTK — <https://developer.apple.com/games/game-porting-toolkit/> · AppleGamingWiki — <https://www.applegamingwiki.com/wiki/Game_Porting_Toolkit>
- GPTK4 coverage — <https://appleinsider.com/articles/26/06/17/apples-game-porting-toolkit-4-is-a-big-improvement-for-modern-game-coders>
- CrossOver 26 Advanced Settings — <https://support.codeweavers.com/en_US/advanced-settings-in-crossover-mac-26>
- DXMT — <https://github.com/3Shain/dxmt>
- Endfield settings (force DX11) — <https://nerdschalk.com/arknights-endfield-disable-vulcan-force-directx-11/>
- CrossOver compatibility: Endfield — <https://www.codeweavers.com/compatibility/crossover/arknights-endfield>
