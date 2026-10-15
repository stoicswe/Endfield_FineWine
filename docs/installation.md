# Installation & setup

How to get **Arknights: Endfield** running on an Apple Silicon Mac with the patched CrossOver Wine: build it, deploy it into a copy of CrossOver, create the game's bottle, install the game, and launch. The engineering background for each stage is in [04-building-crossover-wine.md](04-building-crossover-wine.md) (build), [05-swapping-into-crossover.md](05-swapping-into-crossover.md) (swap + code-signing), and [13-working-solution.md](13-working-solution.md) (the whole story).

## Requirements

| | |
|---|---|
| **Mac** | Apple Silicon (M-series). Intel is not supported. |
| **macOS** | 15 (Sequoia) or newer recommended; tested on macOS 27.0 and macOS 26.5. |
| **Rosetta 2** | Required (`softwareupdate --install-rosetta --agree-to-license`). The patched Wine is x86_64. |
| **CrossOver** | **26.3** specifically (the swapped modules must match the build's Wine 11.0 ABI). A licensed CrossOver install from [codeweavers.com](https://www.codeweavers.com/crossover). |
| **Xcode CLT** | `xcode-select --install` |
| **Homebrew** | [brew.sh](https://brew.sh) (Apple Silicon, `/opt/homebrew`) |
| **The game** | A licensed Arknights: Endfield, installed via the Gryphline launcher into a CrossOver bottle. |
| **Disk / time** | ~5 GB for the build tree; the build takes ~20–60 min. |
| **GPTK4** *(highly recommended)* | Apple's Game Porting Toolkit 4 for best performance (120 FPS, ~50% less RAM) — see [technical.md](technical.md). |

## 1. Build the patched Wine

```bash
git clone <your-fork-url> Endfield_FineWine
cd Endfield_FineWine

# One shot: deps -> fetch source -> apply patches -> configure -> build (~20-60 min)
./scripts/build-wine.sh all
```

Or step by step (useful if something needs attention):

```bash
./scripts/build-wine.sh deps       # Homebrew: bison, mingw-w64, meson, pkg-config, ...
./scripts/build-wine.sh fetch      # download CrossOver 26.3 Wine source (~142 MB), git-init it
./scripts/build-wine.sh apply      # git apply all 24 patches (verified to apply cleanly)
./scripts/build-wine.sh configure  # 64-bit-only, under `arch -x86_64` (Rosetta host)
./scripts/build-wine.sh build      # make -j
```

Notes:

- **No `cx-llvm` / `win32on64` needed.** Endfield is 64-bit only, so this builds a 64-bit-only Wine with the **standard toolchain** — sidestepping the (now-unavailable) patched CrossOver clang. See [04-building-crossover-wine.md](04-building-crossover-wine.md).
- The build is intentionally **minimal** (no bundled fonts/TLS/graphics libs). That's fine: we swap only 3 core modules into CrossOver, which already provides everything else.
- The patch set and what each patch does: [patches/README.md](../patches/README.md).

## 2. Deploy into CrossOver — scripted (recommended)

```bash
./scripts/swap-into-crossover.sh
```

This copies `/Applications/CrossOver.app` into a staging folder, swaps in the patched modules (plus GPTK4's D3DMetal if `GPTK_DIR` points at it — see [graphics-performance.md](graphics-performance.md)), re-seals the whole bundle with an ad-hoc signature, verifies it, and moves it into place as `/Applications/CrossOver_Endfield_Patch.app`. It also creates a double-clickable **`Arknights Endfield.app`** beside it that launches the game directly (step 5).

## 3. Deploy into CrossOver — manual

If you prefer to do it by hand (e.g. to understand or audit it):

```bash
# Copy CrossOver (must be 26.3) so the original stays intact
APP="/Applications/CrossOver_Endfield_Patch.app"
ditto --noextattr --noqtn /Applications/CrossOver.app "$APP"
CXR="$APP/Contents/SharedSupport/CrossOver"
B="$PWD/build/wine-build64"

# Swap the 3 patched modules (move the originals aside as backups)
for f in x86_64-unix/ntdll.so x86_64-windows/kernel32.dll x86_64-windows/ntoskrnl.exe; do
  mv "$CXR/lib/wine/$f" "$CXR/lib/wine/$f.cxorig"
done
cp "$B/dlls/ntdll/ntdll.so"                           "$CXR/lib/wine/x86_64-unix/ntdll.so"
cp "$B/dlls/kernel32/x86_64-windows/kernel32.dll"     "$CXR/lib/wine/x86_64-windows/kernel32.dll"
cp "$B/dlls/ntoskrnl.exe/x86_64-windows/ntoskrnl.exe" "$CXR/lib/wine/x86_64-windows/ntoskrnl.exe"

# ntdll.so needs CrossOver's lib64 rpath (cxcompatdb -> gnutls -> D3DMetal), then an ad-hoc signature
install_name_tool -add_rpath "@loader_path/../../../lib64" "$CXR/lib/wine/x86_64-unix/ntdll.so"
codesign --force --sign - "$CXR/lib/wine/x86_64-unix/ntdll.so"

# Re-seal the outer bundle ad-hoc (nested CodeWeavers signatures and the app's entitlements are
# kept) and verify it BEFORE the first launch — a bundle with a broken seal gets flagged as
# "damaged" and every binary in it is killed. Don't just delete the seal.
xattr -drs com.apple.quarantine "$APP"; xattr -rd com.apple.FinderInfo "$APP"
codesign --force --sign - --preserve-metadata=entitlements "$APP"
codesign --verify --deep --strict "$APP" && echo "patched app verifies"
```

Why re-seal instead of stripping the seal: [05-swapping-into-crossover.md → Verified recipe](05-swapping-into-crossover.md#verified-recipe-2026-09-crossover-2620--macos-270--m4).

| Patched module | Contains |
|---|---|
| `lib/wine/x86_64-unix/ntdll.so` | the two Rosetta signal fixes + `NtDelayExecution` QPC timing |
| `lib/wine/x86_64-windows/kernel32.dll` | the `KiUser*Dispatcher` int3 spoof |
| `lib/wine/x86_64-windows/ntoskrnl.exe` | the 17 `ntoskrnl.exe` em-backports |

Prefer a GUI? The [FineWine Patcher.app](../patcher-app/README.md) does the same module swap + re-seal without any developer tools.

## 4. Create the bottle and install the game

```bash
./scripts/create-bottle.sh    # "Arknights Endfield": Windows 11 64-bit, D3DMetal + DLSS + MSync
```

Then install the Gryphline launcher into it: download the Windows launcher from [endfield.gryphline.com](https://endfield.gryphline.com), use CrossOver → **Arknights Endfield** → *Install Application into Bottle* (or `/Applications/CrossOver_Endfield_Patch.app/Contents/SharedSupport/CrossOver/bin/wine --bottle "Arknights Endfield" --wait-children ~/Downloads/GRYPHLINK_<version>.exe`), keep the default install location, log in, and let the launcher download the game.

Prefer the GUI for the bottle too? Create a *Windows 11 64-bit* bottle named `Arknights Endfield` and set Graphics → D3DMetal, DLSS → on, MSync → on. `UPDATE=1 ./scripts/create-bottle.sh` re-applies the settings to an existing bottle. If the launcher crashes under Rosetta with leftover Wine processes, use `MSYNC=0 BACKEND=d3dmetal UPDATE=1 ./scripts/create-bottle.sh` to disable MSync for that bottle.

## 5. Run the game

**Double-click `Arknights Endfield.app`.** The installer creates it next to the patched CrossOver
(`/Applications`, if that's where you put `CrossOver_Endfield_Patch.app`); you can also (re)create
it any time with `./scripts/make-launcher-app.sh`. It **opens the Gryphline launcher**
(`Launcher.exe`) through the *direct* wine path — install, update and start the game from there.

> **Why an alias at all?** The launcher's Chromium web UI crashes when started from the CrossOver
> app's bottle **Start** button, but it stays up when started via the direct `wine --cx-app` path
> this app uses — [docs/15](project-information/15-launcher-qtwebengine-crash.md).

**Or start the game directly** (once it's installed — the game has its own login screen), which
skips the launcher entirely and adds `-force-d3d11`:

```bash
# Easy launcher script (handles wineserver cleanup, graphics args, debug logging):
./scripts/launch-endfield.sh

# Or invoke wine directly:
CXR="/Applications/CrossOver_Endfield_Patch.app/Contents/SharedSupport/CrossOver"
"$CXR/bin/wine" --bottle "Arknights Endfield" \
  --cx-app "C:/Program Files/GRYPHLINK/games/Arknights Endfield/Endfield.exe" -force-d3d11
```

To make the alias point at the game instead of the launcher:
`./scripts/make-launcher-app.sh --target "C:/Program Files/GRYPHLINK/games/Arknights Endfield/Endfield.exe" --gfxargs "-force-d3d11"`.

### Debug logging

To capture a debug log, run `DEBUG=light ./scripts/launch-endfield.sh` (Wine errors only — cheap enough to leave on while playing) or `DEBUG=1 ./scripts/launch-endfield.sh` (the full CrossOver log — heavy). Calling `bin/wine` yourself? Pass channels with `--debugmsg` (e.g. `--debugmsg err+all`), not `WINEDEBUG`: CrossOver's wrapper overwrites that variable — with `-all`, or with `CX_LOG` set, with its own heavy default channel list.

## See also

- [graphics-performance.md](graphics-performance.md) — graphics backends and the optional GPTK4 upgrade.
- [troubleshooting.md](troubleshooting.md) — when something goes wrong.
- [14-performance-on-16gb-macs.md](14-performance-on-16gb-macs.md) — memory-constrained Macs.
- [scripts/README.md](../scripts/README.md) — every script, including the failure-capture helper.
