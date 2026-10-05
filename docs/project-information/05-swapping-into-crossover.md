# 05 — Getting a custom Wine into CrossOver.app (CXPatcher, code-signing, SIP, quarantine)

> Source area: `swapping-wine` (research + adversarial verify). Overall reliability: **high**.

## The headline

**SIP does not protect `CrossOver.app`, so you do not need `csrutil disable` to patch it.** SIP filesystem protection in `/Applications` covers only Apple's *preinstalled* apps (Safari, Terminal, Console, App Store, Notes, …). User-installed apps like CrossOver are freely modifiable with normal permissions. `[confidence: high — CONFIRMED]` The real barriers are **(1) code-signing integrity** of the bundle and **(2) Gatekeeper/quarantine**.

## What CXPatcher does (and does not do)

**CXPatcher** (`italomandara/CXPatcher`) is a SwiftUI drag-and-drop app that upgrades a *copy* of CrossOver with newer **graphics dependencies** — DXVK, D3DMetal/GPTK, MoltenVK, optionally DXMT. Mechanism (verified from `Utils.swift` / `Config.swift`): `[confidence: high — CONFIRMED]`

- Copies bundled replacement resources into the CrossOver tree via `safeResCopy` / `safeFileCopy`, **renaming any pre-existing target to `<name>_orig`** first.
- Disables files by renaming to `<name>_disabled` (`disable()` helper; `restoreFile`/`enable` revert).
- **Strips the bundle's code signature by default** (`var removeSignaure = true`): it moves/disables `Contents/CodeResources` and `Contents/_CodeSignature` rather than re-signing. There is **no `codesign`/`xattr`/`spctl` call anywhere** in its source.
  - ⚠️ Line-number nit from verifier: those two paths are at `Config.swift` **L112–113**, not L212–213 as the research first stated. Mechanism is correct.
- Overrides the bottle path to a `CXP`-prefixed folder (default `/Users/${USER}/CXPBottles`) by editing the embedded `CrossOver.conf`.
- Outputs **`CrossOver_patched.app`**, leaving the original untouched.

Relevant constants (verified verbatim in `Config.swift`):
```
SUPPORTED_CROSSOVER_VERSION = "23.7"
DEFAULT_CX_BOTTLES_PATH     = /Users/${USER}/CXPBottles
EXTERNAL_RESOURCES_ROOT     = /lib64/apple_gpt        # the GPTK / D3DMetal payload
WINE_RESOURCES_ROOT         = Crossover
```
Target paths it touches: `Contents/SharedSupport/CrossOver`, `/lib/wine/dxvk`, `/lib64/wine/dxvk`, `/lib64/libMoltenVK.dylib`, `/lib64/libMoltenVK-latest.dylib`, `/lib64/apple_gpt`, gstreamer dirs. Patched DLL names referenced: `d3d11`, `d3d12`, `dxgi`, `atidxx64`, plus wine core `ntdll.dll`, `kernelbase.dll`, `winegstreamer.dll`, `wineboot.exe`, `winecfg.exe`. Env toggles it documents: `CXPATCHER_SKIP_NTDLLHACKS=1`, `CXPATCHER_SKIP_DXVK_ENV=1`, `NAS_DISABLE_UE4_HACK=1`, `NAS_TONEMAP_C`.

### ⚠️ CXPatcher alone is INSUFFICIENT for this project

CXPatcher **does not replace the wine binary** or inject custom low-level components. Its maintainer confirmed (Discussion #239) there is **no supported path for injecting low-level components like ntsync**; a custom sync/kernel implementation requires **building a hybrid Wine**, not dropping in a DLL. `[confidence: high — CONFIRMED]`

**Implication:** the ACE fixes we need — custom `ntoskrnl.exe` functions, the int3 `kernel32` hack, Wine-hiding — **cannot** be delivered via CXPatcher. You must build a custom `win32on64` Wine ([04](04-building-crossover-wine.md)) and swap the actual binaries/libraries. CXPatcher is still useful as (a) a proven *pattern* for editing the bundle and stripping the signature, and (b) the tool for the *graphics* layer (D3DMetal/DXMT/DXVK) once the game launches.

## Swapping the real Wine binaries

This is a known community technique. `[confidence: high — CONFIRMED for single-file swaps]`

- Replace executables in `CrossOver.app/Contents/SharedSupport/CrossOver/bin` (e.g. `Gcenx/CrossOver-fixes` documents copying a rebuilt `wine64-preloader` in, "replace when prompted," as a Sonoma 14 fix).
  - ⚠️ That source demonstrates swapping **one preloader** as a bugfix, not a full custom-tree swap. Extending to a full custom `win32on64` Wine tree is a **reasonable extrapolation, not directly demonstrated** — validate it in the toolchain experiment ([09](09-implementation-roadmap.md) milestone 4).
- Also swap the `lib/wine` and `lib64/wine` PE + `.so` libraries for the custom build's equivalents.
- ⚠️ **Open question:** the exact filename manifest under `lib/wine` that must be replaced for a full swap (vs. just `bin/` preloaders) is not definitively documented. And whether swapping the whole Wine tree preserves D3DMetal/GPTK integration (which ships as a CrossOver-specific payload at `/lib64/apple_gpt`) is unverified — you may need to swap Wine but **keep** the `apple_gpt` payload.

## Code-signing after modification (Apple Silicon specifics)

Editing binaries inside a signed `.app` invalidates the bundle seal (`CodeResources`). Under **hardened runtime + library validation**, replacement dylibs not signed by Apple or the **same Team ID** won't load. `[confidence: medium — PLAUSIBLE; not verified against a live current-macOS CrossOver bundle]`

Two approaches:
- **(A) Strip the signature** (what CXPatcher does): remove/disable `Contents/CodeResources` + `Contents/_CodeSignature` so the loader falls back to unsigned-load behavior.
- **(B) Ad-hoc re-sign** the whole bundle:
  ```bash
  codesign --force --deep --sign - CrossOver_patched.app     # '-' = ad-hoc, no certificate
  ```
  On **Apple Silicon every Mach-O must carry at least an ad-hoc signature to execute**, so (B) is the more robust route for swapped x86_64/arm64 binaries. If library validation blocks a swapped lib, the relevant entitlement is `com.apple.security.cs.disable-library-validation`.

Verify & de-quarantine:
```bash
codesign -dv --entitlements :- CrossOver_patched.app   # inspect signature + entitlements
spctl -a -vv CrossOver_patched.app                     # Gatekeeper assessment
xattr -drs com.apple.quarantine CrossOver_patched.app  # remove quarantine (or: xattr -cr)
```
⚠️ No single authoritative primary doc gives an end-to-end re-sign recipe for a *custom-Wine-swapped* CrossOver; the commands above are community-aggregated macOS standard practice. Prove them on a trivial app first ([09](09-implementation-roadmap.md) milestone 4).

### Verified recipe (2026-09, CrossOver 26.3.0 / macOS 27.0 / M4)

(A) **fails** once the copy carries a `com.apple.provenance` xattr. macOS attaches it to files created by apps that were Gatekeeper-checked after download — observed here with a shell spawned by an AI coding agent; terminals such as iTerm2 or VS Code's should behave the same, while Terminal.app (an Apple app) isn't provenance-tracked, which is likely why (A) worked originally — and a provenance-tagged bundle has its signature checked at first exec. With the seal stripped, **every binary inside is SIGKILLed** (`wineserver --version` exits 137, even unmodified ones) and a *"CrossOver_Endfield_Patch" is damaged and can't be opened* dialog appears on every attempt. After that first failure macOS also tags the bundle with `com.apple.macl` and blocks further edits inside it (moving the whole bundle to the Trash still works).

(B) with `--deep` (untested here) would re-sign **every** nested binary ad-hoc, throwing away CodeWeavers' signatures (and, without `--preserve-metadata`, their entitlements). What works cleanly — and what [`scripts/swap-into-crossover.sh`](../scripts/swap-into-crossover.sh) now does — is re-sealing **only the outer bundle**:

```bash
# on a fresh copy that has never been launched (the script stages it in $TMPDIR, then mv's it into place)
xattr -drs com.apple.quarantine CrossOver_Endfield_Patch.app
xattr -rd  com.apple.FinderInfo  CrossOver_Endfield_Patch.app   # else: "resource fork, Finder information, or similar detritus not allowed"
codesign --force --sign - --preserve-metadata=entitlements CrossOver_Endfield_Patch.app
codesign --verify --deep --strict CrossOver_Endfield_Patch.app  # must pass before first launch
```

- Nested binaries keep CodeWeavers' Developer ID signatures. `bin/wineloader` and `bin/wineserver` carry `com.apple.security.cs.disable-library-validation`, so they load the ad-hoc-signed `ntdll.so`.
- The swapped PE modules (`kernel32.dll`, `ntoskrnl.exe`) need no signature of their own — stock CrossOver's PE files have none; the bundle seal covers them.
- The main executable keeps its entitlements (`apple-events`, `allow-unsigned-executable-memory`, camera/mic) but loses the hardened runtime: with runtime + an ad-hoc signature, library validation would reject the CodeWeavers-signed `Python.framework`/`Sparkle.framework`. No restricted entitlements are involved, so an ad-hoc signature is allowed to carry them.
- GPTK's `D3DMetal.framework` / `libd3dshared.dylib` keep Apple's signature ("Software Signing") when copied with `ditto --noextattr`.
- Replace swapped files with `mv`+`cp` rather than overwriting in place, and don't launch the bundle before it verifies — a failed first launch leaves it tagged and read-only (see above).

## Bottle structure (for reference)

- Default: `~/Library/Application Support/CrossOver/Bottles/<name>/`
- Per-bottle files: `cxbottle.conf`, `*.reg`, `drive_c`, `dosdevices`, `cxassoc.conf`, `cxmenu.conf`, `cxnsplugin.conf`, `desktopdata`, `windata`.
- Bottle-path override: `Contents/SharedSupport/CrossOver/etc/CrossOver.conf` → `[Bottle Defaults]` / `[EnvironmentVariables]` → `CX_BOTTLE_PATH`.
- The user-space spoofs in [07](07-rosetta-and-windows-spoofing.md) (winecfg version, `HideWineExports` registry value) are applied **per-bottle** in the `*.reg` files — you can try them with **no rebuild** (roadmap milestone 2).

## Open questions
- ~~Whether current CrossOver (25/26) requires ad-hoc re-sign after a binary swap, or whether signature-stripping still suffices on Sequoia/Tahoe Apple Silicon.~~ **Answered (2026-09):** stripping only works while the copy has no `com.apple.provenance` xattr; re-sealing the outer bundle ad-hoc works either way — see [Verified recipe](#verified-recipe-2026-09-crossover-2620--macos-270--m4).
- The definitive `lib/wine` swap manifest for a full custom-Wine swap.
- Whether a full Wine-tree swap preserves the `/lib64/apple_gpt` D3DMetal integration.
- Whether CrossOver ships hardened runtime + library validation on current versions (affects whether unsigned swapped libs load).

## Primary sources
- CXPatcher — <https://github.com/italomandara/CXPatcher> (README, `Utils.swift`, `Config.swift`)
- CXPatcher Discussion #239 (ntsync / can't inject low-level components) — <https://github.com/italomandara/CXPatcher/discussions/239>
- Gcenx/CrossOver-fixes — <https://github.com/Gcenx/CrossOver-fixes>
- CodeWeavers: change the bottle directory — <https://support.codeweavers.com/change-the-bottle-directory-in-crossover-mac>
- Apple / SIP — <https://support.apple.com/en-us/102149>
