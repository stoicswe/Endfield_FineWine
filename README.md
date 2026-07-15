# Cross_Wine_Custom — Arknights: Endfield on Apple Silicon macOS

Run **Arknights: Endfield** on an Apple Silicon Mac through a **custom-patched CrossOver Wine** — past the game's VMProtect/TenProtect armor, past the **ACE anti-cheat**, rendering through Apple's **D3DMetal**, all the way to the login screen and into gameplay.

As of this project, CodeWeavers rated Endfield **"Installs, Will Not Run"** and the community consensus was that CrossOver + Endfield was impossible. This repository is the first known working setup, plus the full engineering write-up of how it was found.

> **What this is:** a set of **patches** to CrossOver's (LGPL) Wine, plus **scripts** and **documentation** to build and deploy them. It does **not** contain or redistribute CrossOver, Wine, Apple's Game Porting Toolkit, or the game — you bring your own licensed copies of each.

---

## ⚠️ Please read first — scope, legality, ethics

- **Own the game.** This project assumes you have a legitimate, licensed copy of Arknights: Endfield installed via its official launcher. It does not help you obtain the game.
- **This is compatibility work, not cheating.** The anti-cheat patches only make the game **launch** on unsupported hardware — the same category of work as Valve's Proton and dw-proton do on Linux. They give **no in-game advantage**, do not modify game logic, and do not touch other players.
- **No DRM circumvention.** Nothing here cracks or bypasses licensing/DRM.
- **Your risk, your responsibility.** Running a game in an unsupported configuration may violate its Terms of Service. Whether to do so is your decision and your risk; the authors accept no liability (see LICENSE).
- **Not affiliated** with Gryphline/Hypergryph, Tencent, CodeWeavers, or Apple.

---

## What works

- ✅ VMProtect/TenProtect protector (`EndfieldBase.dll`)
- ✅ **ACE anti-cheat** (`ACE-Base64.dll`, `ACE-Service64.exe`, kernel driver `ACE-BASE.sys`) — passes fully
- ✅ Unity engine loads (Endfield is Unity IL2CPP), renders through **Apple D3DMetal**
- ✅ **Login screen + gameplay** — reported running well on an Apple M3

**Tested on:** Apple M3, macOS 26.5, CrossOver 26.2.0. Other Apple Silicon chips and nearby macOS/CrossOver-26.2 versions are expected to work but are unverified.

One cosmetic residual: a background ACE thread aborts on `ntoskrnl.exe.PsGetProcessExitStatus`; the game reaches login/gameplay regardless.

## How it works (short version)

Two newly-discovered **Rosetta 2** bugs, plus a port of the Linux **dw-proton** anti-cheat patches:

1. **Rosetta faults on a plain NOP.** VMProtect emits `0F 1F` multi-byte NOPs by the 100k; Rosetta wrongly raises an illegal-instruction fault on them, cascading into a stack-overflow loop. Fix: skip the NOP.
2. **Rosetta mis-classifies a privileged instruction.** ACE's driver reads `CR3` (`mov rbx, cr3`) as an anti-VM probe; under Rosetta this arrives as an *invalid-opcode* fault instead of `#GP`, so ACE got the wrong exception and failed with "driver error 13." Fix: deliver `EXCEPTION_PRIV_INSTRUCTION`, like Linux.
3. **dw-proton port:** 17 `ntoskrnl.exe` function backports + the `KiUser*Dispatcher` int3 spoof + a QPC-timing patch clear the ACE-init blockers.

Both Rosetta fixes are ~40 lines in `dlls/ntdll/unix/signal_x86_64.c` and help a whole class of protected games on Apple Silicon (cf. WineHQ **Bug 45083**). Full engineering story: **[docs/13-working-solution.md](docs/13-working-solution.md)** and the [docs/](docs/) set.

---

## Requirements

| | |
|---|---|
| **Mac** | Apple Silicon (M-series). Intel is not supported. |
| **macOS** | 15 (Sequoia) or newer recommended; developed on macOS 26.5. |
| **Rosetta 2** | Required (`softwareupdate --install-rosetta --agree-to-license`). The patched Wine is x86_64. |
| **CrossOver** | **26.2** specifically (the swapped modules must match the build's Wine 11.0 ABI). A licensed CrossOver install from [codeweavers.com](https://www.codeweavers.com/crossover). |
| **Xcode CLT** | `xcode-select --install` |
| **Homebrew** | [brew.sh](https://brew.sh) (Apple Silicon, `/opt/homebrew`) |
| **The game** | A licensed Arknights: Endfield, installed via the Gryphline launcher into a CrossOver bottle. |
| **Disk / time** | ~5 GB for the build tree; the build takes ~20–60 min. |
| **GPTK4** *(optional)* | Apple's Game Porting Toolkit 4 for best performance — see [below](#graphics--performance-gptk4). |

---

## Install

There are two ways to get the patched Wine into CrossOver. **Both require you to build the patched Wine first** (§1), then deploy it (§2 scripted, or §3 manual).

### 1. Build the patched Wine

```bash
git clone <your-fork-url> Cross_Wine_Custom
cd Cross_Wine_Custom

# One shot: deps -> fetch source -> apply patches -> configure -> build (~20-60 min)
./scripts/build-wine.sh all
```

Or step by step (useful if something needs attention):

```bash
./scripts/build-wine.sh deps       # Homebrew: bison, mingw-w64, meson, pkg-config, ...
./scripts/build-wine.sh fetch      # download CrossOver 26.2 Wine source (~142 MB), git-init it
./scripts/build-wine.sh apply      # git apply all 23 patches (verified to apply cleanly)
./scripts/build-wine.sh configure  # 64-bit-only, under `arch -x86_64` (Rosetta host)
./scripts/build-wine.sh build      # make -j
```

Notes:
- **No `cx-llvm` / `win32on64` needed.** Endfield is 64-bit only, so this builds a 64-bit-only Wine with the **standard toolchain** — sidestepping the (now-unavailable) patched CrossOver clang. See [docs/04](docs/04-building-crossover-wine.md).
- The build is intentionally **minimal** (no bundled fonts/TLS/graphics libs). That's fine: we swap only 3 core modules into CrossOver, which already provides everything else.

### 2. Deploy into CrossOver — scripted (recommended)

```bash
./scripts/swap-into-crossover.sh
```

This copies `/Applications/CrossOver.app` → `build/CrossOver_patched.app`, swaps in the 3 patched modules, ad-hoc-signs them, strips the bundle seal, and removes quarantine. Then run the game through `build/CrossOver_patched.app` (§4).

### 3. Deploy into CrossOver — manual

If you prefer to do it by hand (e.g. to understand or audit it):

```bash
# Copy CrossOver (must be 26.2) so the original stays intact
cp -a /Applications/CrossOver.app "$HOME/CrossOver_patched.app"
CXR="$HOME/CrossOver_patched.app/Contents/SharedSupport/CrossOver"
B="$PWD/build/wine-build64"

# Swap the 3 patched modules (back up the originals first)
cp "$CXR/lib/wine/x86_64-unix/ntdll.so"        "$CXR/lib/wine/x86_64-unix/ntdll.so.orig"
cp "$CXR/lib/wine/x86_64-windows/kernel32.dll" "$CXR/lib/wine/x86_64-windows/kernel32.dll.orig"
cp "$CXR/lib/wine/x86_64-windows/ntoskrnl.exe" "$CXR/lib/wine/x86_64-windows/ntoskrnl.exe.orig"

cp "$B/dlls/ntdll/ntdll.so"                           "$CXR/lib/wine/x86_64-unix/ntdll.so"
cp "$B/dlls/kernel32/x86_64-windows/kernel32.dll"     "$CXR/lib/wine/x86_64-windows/kernel32.dll"
cp "$B/dlls/ntoskrnl.exe/x86_64-windows/ntoskrnl.exe" "$CXR/lib/wine/x86_64-windows/ntoskrnl.exe"

# Ad-hoc sign the swapped files, drop the bundle seal + quarantine so they load
for f in x86_64-unix/ntdll.so x86_64-windows/kernel32.dll x86_64-windows/ntoskrnl.exe; do
  codesign --force --sign - "$CXR/lib/wine/$f"
done
rm -rf "$HOME/CrossOver_patched.app/Contents/_CodeSignature" \
       "$HOME/CrossOver_patched.app/Contents/CodeResources"
xattr -drs com.apple.quarantine "$HOME/CrossOver_patched.app"
```

| Patched module | Contains |
|---|---|
| `lib/wine/x86_64-unix/ntdll.so` | the two Rosetta signal fixes + `NtDelayExecution` QPC timing |
| `lib/wine/x86_64-windows/kernel32.dll` | the `KiUser*Dispatcher` int3 spoof |
| `lib/wine/x86_64-windows/ntoskrnl.exe` | the 17 `ntoskrnl.exe` em-backports |

### 4. Run the game

Point the **patched** CrossOver at your existing Endfield bottle:

```bash
CXR="$PWD/build/CrossOver_patched.app/Contents/SharedSupport/CrossOver"
"$CXR/bin/wine" --bottle "Arknights Endfield" \
  --cx-app "C:/Program Files/GRYPHLINK/games/Arknights Endfield/Endfield.exe"
```

Or launch `CrossOver_patched.app` from Finder and start Endfield from its bottle as usual. It should reach the login screen. To capture a debug log: prefix with `CX_LOG=/tmp/ef.log WINEDEBUG=+seh`.

---

## Graphics & performance (GPTK4)

**You may not need GPTK4.** CrossOver 26.2 already bundles **D3DMetal 3.0** (= GPTK 3.0), and that is what Endfield renders on out of the box — it runs well on the tested M3 / macOS 26.5 setup with no extra graphics work. Apple's **Game Porting Toolkit 4** upgrades that bundled D3DMetal **3.0 → 4** (DirectX 12 → **Metal 4**, MetalFX frame-generation, HDR) for the newest/fastest path — but GPTK4 is **macOS 27-beta-era software**, so treat it as an **optional, advanced** upgrade.

> **On "Vulkan":** GPTK/D3DMetal does **not** provide Vulkan — it translates DirectX **straight to Metal**. Vulkan on Apple GPUs comes from **MoltenVK** (Vulkan → Metal), which CrossOver bundles and CXPatcher/Procyon upgrade. So there are two graphics families: **DirectX → Metal directly** (D3DMetal / DXMT — where GPTK lives) vs **DirectX/Vulkan → Vulkan → Metal** (DXVK / vkd3d + MoltenVK). The direct D3DMetal path is the faster one.

### Pick the graphics backend

CrossOver → select the **Arknights Endfield** bottle → **Advanced Settings → Graphics**:

- **D3DMetal** *(recommended)* — DirectX 11/12 → Metal. With GPTK4, DX12 → Metal 4 is fastest, and it's the only path with **DLSS-via-MetalFX** frame generation. Force the game into **DirectX 12** mode for the full benefit.
- **DXMT** — good for DirectX 11 titles; also supports the DLSS/MetalFX toggle.
- **DXVK** — DirectX 10/11 → Vulkan → MoltenVK (fallback; extra hop, no DLSS).

Also enable **DLSS (MetalFX)** and **MSync**, and set `ROSETTA_ADVERTISE_AVX=1` in the bottle's environment for AVX2 (that comes from Rosetta 2 on macOS 15+, not from GPTK).

### Installing GPTK4

> **Apple's GPTK is evaluation-only software — download it yourself; you may not redistribute it**, so this repo cannot bundle it. These steps target **macOS 27 (beta)** for GPTK4. On **macOS 26**, CrossOver's bundled **D3DMetal 3.0** is the matched version — no action needed.

1. **Download** from Apple: [developer.apple.com/games/game-porting-toolkit](https://developer.apple.com/games/game-porting-toolkit/) → the Downloads list ([search "Game Porting Toolkit"](https://developer.apple.com/download/all/?q=game%20porting%20toolkit)). Sign in with an Apple ID (a free Apple Developer account has historically been enough). Mount the resulting `.dmg` (it appears under `/Volumes/…`; run `ls /Volumes/` to get its exact name).
2. Apply it to your **patched** CrossOver copy — do this *after* the [module swap](#2-deploy-into-crossover--scripted-recommended) so you keep both the anti-cheat fixes **and** GPTK4:

   **Manual** — replace the two D3DMetal libraries (keep the `-old` backups):
   ```bash
   GPTK_VOL="/Volumes/<mounted GPTK volume — check with: ls /Volumes/>"
   cd "$HOME/CrossOver_patched.app/Contents/SharedSupport/CrossOver/lib64/apple_gptk/external"
   mv D3DMetal.framework D3DMetal.framework-old
   mv libd3dshared.dylib  libd3dshared.dylib-old
   ditto "$GPTK_VOL/redist/lib/external/" .
   ```
   (The folder is `apple_gptk`, with a trailing **k**. Only the `redist/lib/external/` libraries are needed — ignore the DMG's Homebrew/Wine path, which is for *standalone* GPTK, not CrossOver.)

   **CXPatcher / Procyon (easier)** — [CXPatcher](https://github.com/italomandara/CXPatcher) drops a GPTK `.dmg`'s D3DMetal into a CrossOver copy automatically (drag CrossOver in, keep "Integrate D3DMetal (GPTK)" on, point it at your GPTK dmg). Its author has moved **GPTK4** support to the successor **[Procyon](https://github.com/italomandara/Procyon)** — use Procyon's pre-release for GPTK4. These tools patch **graphics only**; you still need this project's Wine-module swap for the anti-cheat, so apply **both** to the same CrossOver copy (e.g. run `swap-into-crossover.sh` on the CXPatcher/Procyon output).

### Caveats
- **GPTK4 wants macOS 27 (beta)** + Metal 4. On **macOS 26, stay on the bundled D3DMetal 3.0.** Clean GPTK4 integration into **CrossOver 26.2 specifically is unverified** — test it, keep the `-old` backups, be ready to revert; CrossOver 27 / Procyon may be the smoother route.
- Apple Silicon only; Rosetta 2 required.

---

## Repository layout

```
patches/            The Wine patches (LGPL — see below)
  stage1-macos/       our two Rosetta fixes + a build fix
  stage2-dwproton/    the ported dw-proton anti-cheat patches (em-backports + misc)
scripts/            build-wine.sh, swap-into-crossover.sh, capture/debug helpers
docs/               the full engineering write-up (start at docs/README.md)
build/              (gitignored) the Wine source + build output you generate
```

## Troubleshooting

- **"CrossOver.app is version X, expected 26.2"** — the swap needs a matching Wine ABI. Install CrossOver 26.2.
- **Game won't start / signature errors** — re-run the `codesign --force --sign -` + `xattr -drs com.apple.quarantine` steps; confirm the bundle seal was removed.
- **ACE "driver error 13" comes back** — the patched `ntdll.so`/`ntoskrnl.exe` aren't loading; verify the swap paths and that you launched the *patched* app.
- More detail and the debug-capture script: [scripts/01-capture-failure.sh](scripts/01-capture-failure.sh) and [docs/10](docs/10-milestone-1-results.md).

---

## License

- **Scripts (`scripts/`) and documentation (`docs/`, README):** [MIT](LICENSE).
- **Patches (`patches/`):** these are modifications to **Wine**, so they are **LGPL-2.1-or-later** (Wine's license) — MIT cannot relicense them. The `stage2-dwproton/` patches originate from the **dw-proton (Dawn Winery)** project and retain their upstream authors' rights (Etaash Mathamsetty, Ziia Shi / mkrsym1, NelloKudo, et al.). See [patches/README.md](patches/README.md).
- This repo **does not distribute** Wine, CrossOver, Apple's GPTK, MoltenVK, or the game. Get each from its source, under its own license.

## Credits

- **[dw-proton / Dawn Winery](https://dawn.wine/)** — the Linux ACE/Endfield patches that stage 2 ports.
- **[CodeWeavers CrossOver](https://www.codeweavers.com/crossover)** and the **[Wine](https://www.winehq.org/)** project — the foundation this builds on.
- **[Apple Game Porting Toolkit](https://developer.apple.com/games/game-porting-toolkit/)** — D3DMetal.
- **WineHQ Bug 45083** reporters — the prior art that framed the Rosetta VMProtect problem.

## Contributing / upstreaming

The two Rosetta signal-handling fixes are general CrossOver-on-Apple-Silicon bugs and are worth reporting to **CodeWeavers** (with Bug 45083 as reference). PRs to improve the build/deploy scripts, packaging (e.g. a CXPatcher-style overlay), and testing on more chips/macOS versions are welcome.
