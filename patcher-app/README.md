# FineWine Patcher.app

A minimal macOS app that turns a copy of **CrossOver 26.2** into the patched build that runs
**Arknights: Endfield** on Apple Silicon. It is the GUI equivalent of
[`scripts/swap-into-crossover.sh`](../scripts/swap-into-crossover.sh)'s core Wine-module swap:

1. Copies your `CrossOver.app` (the original is never touched).
2. Swaps in the three pre-built patched Wine modules bundled inside the app
   (`ntdll.so`, `kernel32.dll`, `ntoskrnl.exe`), keeping `.cxorig` backups.
3. Ad-hoc signs the swapped files, strips the bundle seal, removes quarantine.
4. Verifies the swap (sizes, `ntdll.so` signature, and the `lib64` rpath D3DMetal needs).

Out of scope by design: the optional GPTK4 / MoltenVK graphics upgrades (Apple's GPTK may not
be redistributed) — see the [main README](../README.md#graphics--performance-gptk4) for those.

**End users need no developer tools** — the `lib64` rpath is baked into the payload at app-build
time, so at patch time the app only uses `codesign` and `xattr`, which ship with macOS.

## Building the app

Requires the Xcode Command Line Tools only (no Xcode):

```bash
# 1. Build the patched Wine first (once) — produces build/wine-build64
./scripts/build-wine.sh all

# 2. Build the app around it
./patcher-app/scripts/build-app.sh
open "patcher-app/build/FineWine Patcher.app"
```

`PAYLOAD_DIR` overrides where the modules come from (the `build/wine-build64` tree layout or a
flat directory with the three files). `CODESIGN_ID` sets a real signing identity (default:
ad-hoc). `ALLOW_MISSING_PAYLOAD=1` produces a payload-less smoke-test build that refuses to patch.

### App icon

`build-app.sh` bakes in `Resources/AppIcon.icns` (a committed file). To regenerate it after
changing the source art, run `scripts/make-appicon.sh` — it renders the full macOS size set from
`Resources/appicon/appicon-source.png` with Apple tools only (`swift` + `iconutil`, no
third-party image libraries), centering the artwork on a transparent square with a 6% margin
(`MARGIN=…` to change). If `AppIcon.icns` is absent, the app simply builds without a custom icon.

## Licensing (important if you distribute the built app)

- **The app itself** (Swift sources, UI, this directory): [MIT](../LICENSE).
- **The bundled payload** (`ntdll.so`, `kernel32.dll`, `ntoskrnl.exe`): **LGPL-2.1-or-later** —
  they are Wine, built from CodeWeavers' freely published
  [CrossOver 26.2 Wine source](https://www.codeweavers.com/crossover/source) with this repo's
  [patches](../patches/) applied (which include the
  [dw-proton](https://dawn.wine/) anti-cheat patches — see [patches/README.md](../patches/README.md)
  for authorship).
- The app's **Licenses…** window shows all of this, with the full license texts, offline.

If you publish a built `FineWine Patcher.app` (e.g. a GitHub Release), LGPL-2.1 requires you to
make the **complete corresponding source** of the payload available: this repository's patches +
the exact `crossover-sources-26.2.0` archive from
[media.codeweavers.com/pub/crossover/source](https://media.codeweavers.com/pub/crossover/source/).
Best practice: attach (or mirror in a release) the exact source tarball you built from, so your
source offer doesn't depend on a third-party URL staying alive.

The app never contains or redistributes CrossOver itself, Apple's Game Porting Toolkit,
MoltenVK, or the game. It requires the user's own licensed CrossOver install as input, and links
to [codeweavers.com/store](https://www.codeweavers.com/store) for buying one.

## Layout

```
Package.swift                     SwiftPM manifest (macOS 13+)
Sources/FineWinePatcher/
  FineWinePatcherApp.swift        app entry
  ContentView.swift               the single-window UI
  PatcherEngine.swift             the patch steps (mirrors swap-into-crossover.sh)
  LicensesView.swift              the Licenses window + component metadata
Resources/licenses/               license texts bundled into the app
Resources/AppIcon.icns            the app icon (committed; regenerate with make-appicon.sh)
Resources/appicon/                the icon source art
scripts/build-app.sh              compile + assemble + payload staging + signing
scripts/make-appicon.sh           regenerate AppIcon.icns from the source art
scripts/make-appicon.swift        the icon renderer (ImageIO/Core Graphics)
build/                            (gitignored) the assembled .app
```
