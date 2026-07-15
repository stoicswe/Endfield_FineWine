# 03 — CrossOver's Wine on macOS: architecture & bundle layout

> Source area: `crossover-wine-arch` (research + adversarial verify). Overall reliability: **high**.

## What CrossOver is

CrossOver (CodeWeavers) is a commercial Wine distribution. Its Wine is a **fork of upstream Wine** with CodeWeavers patches, still governed by **LGPL-2.1** for the Wine portions (`COPYING.LIB`) — which is why the source must be published. `[confidence: high]`

- Source tarballs: <https://media.codeweavers.com/pub/crossover/source/> (directory listing returns HTTP 403 to automated fetches — exact newest filename unverified).
- Git mirror: `github.com/tbodt/crossover-wine` (LGPL-2.1). The active build fork used by the community is **`Gcenx/winecx`** (branch `crossover-wine`).

## `win32on64` — the central macOS innovation

Apple removed all 32-bit code and libraries starting with **macOS 10.15 Catalina** — no 32-bit dyld, no 32-bit system libraries. Classic 32-bit Wine and classic WoW64 therefore cannot run. CrossOver's answer is **`win32on64`**:

- Runs 32-bit x86 Windows code **inside a single 64-bit macOS process**. `[confidence: high — CONFIRMED]`
- Relies on a Catalina-era kernel feature allowing a **32-bit code segment inside a 64-bit process**, set up via the **i386 LDT (local descriptor table)** / `i386_set_ldt`. On macOS 10.15.0–10.15.3, **SIP had to be disabled** for `wine32on64` to change LDT state; 10.15.4 added an entitlement removing that need. `[confidence: high — CONFIRMED via Gcenx/wine-on-mac]`
- All of Wine's own support code and every macOS dependency library stay **64-bit**; only guest Windows code runs 32-bit. 16-bit executables are unsupported.
- Requires a **custom-patched Clang/LLVM** (CodeWeavers-modified) that emits **thunk code** to marshal calls across the 32/64-bit boundary. **Stock upstream LLVM/Clang cannot build `--enable-win32on64`.** `[confidence: high — CONFIRMED]`
- Enabled with `./configure --enable-win32on64`. Resulting loader binaries are named **`wine32on64`** (and `wine32on64-preloader` — the `-preloader` suffix is `[confidence: medium]`, consistent with upstream naming but not directly confirmed).
- This is **architecturally different from Microsoft/Wine WoW64**: win32on64 is macOS-specific and compiler-dependent, which is why upstream Wine never merged it.

## Apple Silicon: it's x86_64 under Rosetta 2

**On Apple Silicon, CrossOver Wine is an x86_64 build.** The whole 64-bit Wine process is translated by Apple's **Rosetta 2** (x86_64 → arm64), and win32on64's 32-bit guest code is x86-emulated on top of that. `[confidence: high for the x86_64/Rosetta stack; PLAUSIBLE for the tidy layering]`

```
Windows API  →  Wine (x86_64)  →  Rosetta 2 (x86_64→arm64)  →  arm64 CPU
                     │
                     ├─ graphics:  D3DMetal / DXMT / DXVK+MoltenVK  →  Metal
                     └─ sync:      MSync (kqueue / Mach semaphores)
```

⚠️ **VERIFIER CAUTION:** the phrase "32-bit guest code is x86 emulated on top of Rosetta 2" **oversimplifies**. Rosetta 2 translates **only 64-bit Intel code** on Apple Silicon; running 32-bit code there was a **fragile custom hack**, not routine Rosetta translation. That very difficulty is *why* 32-bit bottles are being dropped (below).

### The arm64 transition (a strategic risk for this project)

- CodeWeavers has announced **native arm64 CrossOver** builds: Linux preview since Nov 2025, Mac in progress — intended to drop Rosetta 2 **before Apple removes Rosetta with ~macOS 28 (2027)**. `[confidence: high]`
- **CrossOver 27** retires `win32on64` / 32-bit bottles in favor of 64-bit bottles, **drops Intel Mac support entirely**, and requires Apple Silicon on **macOS 14 Sonoma or later**. `[confidence: high — CONFIRMED, with the Intel-drop detail added by the verifier]`

**Why this matters:** the dw-proton int3 hack that makes Endfield launch is `#ifdef __x86_64__` — it exists **only in an x86_64 Wine**. The platform is trending toward native arm64 exactly where that fix would vanish. See [08-risks-unknowns-open-questions.md](08-risks-unknowns-open-questions.md), risk #2.

## How CrossOver's Wine differs from Proton's Wine

| | CrossOver (macOS) | Proton (Linux) |
|---|---|---|
| 32-on-64 | `win32on64` + custom Clang thunks | classic multilib / WoW64 |
| GUI driver | mature **`winemac.drv`** (Cocoa/Quartz/Metal) | `winex11.drv` / `winewayland.drv` |
| Graphics | **D3DMetal** (DX→Metal directly), DXMT, DXVK+MoltenVK | DXVK / VKD3D over native Vulkan |
| Sync | **MSync** (kqueue / Mach semaphores) | esync/fsync (eventfd / futex) |
| App/anti-cheat hacks | CrossOver-specific | Proton/dw-proton-specific |

This divergence is why dw-proton patches **cannot be assumed to apply cleanly** to CrossOver's tree — they were written against Proton's Wine.

## Bundle layout — the files you will edit

```
/Applications/CrossOver.app/
└── Contents/
    └── SharedSupport/
        └── CrossOver/                      ← CX_ROOT (exposed at runtime)
            ├── bin/                         ← added to PATH by CrossOver
            │   ├── wine                     wineloader
            │   ├── wine64
            │   ├── wine64-preloader         (and/or wine32on64 / wine32on64-preloader)
            │   ├── wineserver               (per-prefix daemon, 64-bit macOS process)
            │   └── wineloader
            ├── lib/wine/                    ← 32-bit-side PE + .so libraries (incl. dxvk)
            ├── lib64/wine/                  ← 64-bit-side PE + .so libraries (incl. dxvk)
            │   └── apple_gpt/               ← GPTK / D3DMetal payload (CXPatcher's EXTERNAL_RESOURCES_ROOT)
            ├── lib64/libMoltenVK.dylib
            └── etc/CrossOver.conf           ← [Bottle Defaults]/[EnvironmentVariables], CX_BOTTLE_PATH
```

Runtime environment (confirmed from CodeWeavers forum output):
```
CX_ROOT      = /Applications/CrossOver.app/Contents/SharedSupport/CrossOver
PATH        += .../SharedSupport/CrossOver/bin
WINESERVER   = .../bin/wineserver
WINELOADER   = .../bin/wineloader
DYLD_LIBRARY_PATH = .../lib64
```

Bottles (prefixes) live at `~/Library/Application Support/CrossOver/Bottles/<name>/` — each with `cxbottle.conf`, `*.reg`, `drive_c`, `dosdevices`, etc. See [05-swapping-into-crossover.md](05-swapping-into-crossover.md) for editing these.

## Open questions
- Exact newest CrossOver source tarball filename/version (directory listing is 403).
- Whether modern CrossOver (26/27) still ships `wine32on64` or has fully moved to WoW64-style 32-on-64, and the exact version where `win32on64` was removed.
- The upstream Wine base version each CrossOver release forks from (needed to reason about patch rebasing — see [02](02-dwproton-ace-patches.md)).
- ⚠️ Whether CrossOver v20.0.0 shipped the modified LLVM/Clang in-tarball and v20.0.1+ removed them (**UNVERIFIABLE** from primary sources; see [04-building-crossover-wine.md](04-building-crossover-wine.md)).

## Primary sources
- Gcenx/wine-on-mac README — <https://github.com/Gcenx/wine-on-mac>
- Gcenx/winecx `configure.ac` — <https://github.com/Gcenx/winecx/blob/crossover-wine/configure.ac>
- sarimarton compile gist — <https://gist.github.com/sarimarton/471e9ff8046cc746f6ecb8340f942647>
- carette.xyz CrossOver deep-dive — <https://carette.xyz/posts/deep_dive_into_crossover/>
- CodeWeavers "What's in and out for CrossOver 27" — <https://www.codeweavers.com/blog/mjohnson/2026/6/11/whats-in-and-whats-out-for-crossover-27>
- CrossOver source — <https://www.codeweavers.com/crossover/source>
