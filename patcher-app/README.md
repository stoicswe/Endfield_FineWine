# FineWine Patcher.app

A minimal macOS app that turns a copy of **CrossOver 26.3** into the patched build that runs
**Arknights: Endfield** on Apple Silicon. It is the GUI equivalent of
[`scripts/swap-into-crossover.sh`](../scripts/swap-into-crossover.sh)'s core module swap:

1. Copies your `CrossOver.app` into a staging folder (the original is never touched).
2. Swaps in the pre-built patched modules bundled inside the app:
   * the Wine modules — `ntdll.so`, `kernel32.dll`, `ntoskrnl.exe`, `lsass.exe`, `wineboot.exe`,
     and `wineserver` (installed at both `bin/wineserver` and
     `CrossOver-Hosted Application/wineserver`)
     (`lsass.exe` is added: stock CrossOver has none, and the new ACE-CORE driver requires it;
     `wineserver` must be swapped too — its server protocol has to match the patched `ntdll.so`,
     otherwise every wine process dies with a `version mismatch` before any window appears)
   * `lib64/libMoltenVK.dylib` (built by [`scripts/build-moltenvk.sh`](../scripts/build-moltenvk.sh))

   keeping `.cxorig` backups.
3. *(Optional)* Installs **GPTK4 / D3DMetal** from a copy **you** supply — a mounted
   *"Evaluation environment for Windows games …"* DMG (or a folder you pick). Only
   `lib64/apple_gptk/external/` is replaced (every D3DMetal glue module symlinks into it), so
   the whole D3D11/D3D12/DXGI/DLSS stack upgrades and no `lib/wine/...` DLL is touched. Keeps
   CrossOver's copy as `external.cxorig`.
4. Re-seals the whole bundle with an ad-hoc signature and removes quarantine. (Just stripping
   the seal gets the copy reported as *damaged* and its binaries killed, because a copy made by
   a downloaded app carries `com.apple.provenance` — see
   [docs/05](../docs/05-swapping-into-crossover.md#code-signing-after-modification-apple-silicon-specifics).)
5. Verifies the swap (sizes, `ntdll.so` signature, the `lib64` rpath D3DMetal needs, the
   installed GPTK4 files if selected, and the bundle signature).
6. Moves the patched app into place; an existing copy macOS won't let it delete goes to the Trash.

**Apple's Game Porting Toolkit is never bundled or redistributed** (it is evaluation-only
software). The optional GPTK4 step reads the DMG *you* mounted, under Apple's own license; if
you skip it, the patched app keeps CrossOver's bundled D3DMetal 3.0. See
[docs/graphics-performance.md](../docs/graphics-performance.md) for the GPTK4 background.
MoltenVK **is** bundled (it is Apache-2.0), since the game's Vulkan/DXVK/vkd3d paths use it.

**End users need no developer tools** — the `lib64` rpath is baked into the payload at app-build
time, so at patch time the app only uses `codesign`, `ditto` and `xattr`, which ship with macOS.

## Automated Setup

**Automated Setup…** (next to *Create Patched Copy…*) is the one-click path. It uses the CrossOver
selected on the main page and:

1. **Creates the patched copy** — `/Applications/CrossOver_Endfield_Patch.app` (falling back to
   `~/Applications` if `/Applications` isn't writable) with the same module swap, re-seal and
   verification as "Create Patched Copy…". An existing patched copy is reused; a *Re-create* toggle
   rebuilds it. The embedded patch is covered by the setup's single statistics question at the end,
   not a separate one.
2. **Graphics (optional)** — keep CrossOver's bundled D3DMetal or install **Apple's GPTK4 /
   D3DMetal 4**. The wizard links to Apple's GPTK page (you download it yourself — it is never
   bundled), detects a mounted *“Evaluation environment for Windows games …”* DMG, and lets you
   Rescan / Choose a redist folder. Picking a GPTK on a reused copy re-creates it so the new
   D3DMetal is installed.
3. **Installer** — opens the official Endfield download page and asks you to select the
   `GRYPHLINK_….exe` you downloaded.
4. **Bottle settings** — every default is editable:
   * bottle name (default `Arknights Endfield`; existing names and CrossOver's forbidden
     characters are rejected),
   * graphics backend (D3DMetal by default, plus DXMT / DXVK / WineD3D / automatic),
   * MSync on/off (on by default),
   * the backend's upscaler toggle (MetalFX for D3DMetal, NVEXT for DXMT).
5. **Create and install** — creates the bottle with the patched app's own `cxbottle`
   (`win11_64`, the same keys `scripts/create-bottle.sh` writes), starts the installer through the
   direct `bin/wine --bottle … --cx-app` path, and — when the installer exits — runs
   `cxmenu --install` so GRYPHLINK appears in the bottle's page.

The wizard writes a log of every command and its output to `~/Library/Logs/FineWinePatcher/`
(`bottle-…`, `installer-…`, `cxmenu-…`), reachable from the finished screen.

**Order matters.** The wizard creates the bottle with the *patched* app on purpose: CrossOver bakes
the creating app's bundle identifier into program launchers, so a bottle created by the stock app
keeps opening the stock app. Delete stubs the stock app created (`~/Applications/CrossOver/…`)
before re-creating them from the patched copy.

## Per-run anonymous usage statistics

There is no telemetry checkbox and no persistent reporting setting. When a **patch run** or an
**Automated Setup run** finishes — whether it succeeded or failed — the patcher shows a dialog
asking whether you want to send an anonymous report for **that run only**. The dialog includes the
exact JSON payload, an explanation of why it helps, and a list of what is never collected. Nothing
is sent automatically; the report is posted only if you choose **Send Statistics**. Choosing
**Don't Send** closes the dialog without contacting the statistics endpoint.

**Why this helps.** Release download counts cannot tell us whether the patch worked, which macOS
or CrossOver version failed, or which step breaks most often. These per-run reports let us see
failure rates and timings across real machines, so we can prioritise the compatibility and
performance fixes that actually affect players.

**What is collected.** Each report contains only:

| Field | Example | Purpose |
|---|---|---|
| `app` | `endfield-finewine-patcher` | Identifies the client |
| `event` | `patch_succeeded`, `patch_failed` | Whether the run completed |
| `appVersion` | `1.2.4` | Correlate problems with a release |
| `osMajor` | `26` | Find macOS-version-specific breakage |
| `metadata` | `gptk=true`, `duration_seconds=42`, `failed_step=3`, `cross_over_build=39832` | Diagnose the path, failing step and the exact CrossOver build |
| `logs` | *(Automated Setup only)* redacted excerpts | Show what actually failed during bottle creation / the installer |

`cross_over_build` is the source CrossOver's `CFBundleVersion` (for example `39832`). CrossOver
point builds that all report `26.3` can ship different Wine modules — the reason the patcher has to
swap `wineserver` as well — so the build number is the field that tells two reports apart. It is a
software version, not a machine or user identifier.

Automated Setup reports additionally carry `setup_backend`, `setup_msync`, `setup_upscaling` and
`installer_status` (`started` / `exited:<code>`), plus **redacted excerpts of that run's logs**
(`~/Library/Logs/FineWinePatcher/bottle-…`, `installer-…`, `cxmenu-…`). Each excerpt is capped
(4 000 characters per log, 12 000 in total, newest lines kept), and every line passes through a
redactor *before* the preview is built:

| Redacted | Becomes |
|---|---|
| Your home folder, macOS and Windows user names, other users' profiles | `~`, `<user>` |
| The bottle name (and the bottle path) | `<bottle>` |
| Host name (including `host.local`) | `<host>` |
| E-mail addresses | `<email>` |
| IP and MAC addresses | `<ip>`, `<mac>` |
| UUIDs, JWTs, `Bearer …` tokens, `token=…`/`password=…` values, long hex blobs | `<uuid>`, `<token>`, `<hash>`, `<redacted>` |
| Temporary folders, volume names, CrossOver's `Registered to:` line | `<tmp>`, `<volume>`, `<redacted>` |

Redaction is best-effort — automatic filtering cannot catch everything, so the dialog shows the
**exact** redacted payload and asks you to review it before sending. A patch report never includes
logs.

The collector is `https://endfield-fine-wine.lovable.app/api/statistics`. The request is a
best-effort HTTPS POST; there is no retry or offline queue.

**Preview — exactly what would be sent.** The confirmation dialog displays the pretty-printed
JSON built from the same encoder used by the send action, so the preview cannot drift from the
actual payload. It is shown before the Send Statistics button can be used.

After you choose **Send Statistics**, the app shows a thank-you dialog with a short confetti
celebration to acknowledge your contribution to the project.

Every patcher build runs `scripts/check-telemetry-privacy.py` plus the telemetry unit tests. The
build fails if anything can be sent automatically, if a send action appears outside the
user-confirmed dialog, if the event or metadata allowlist grows, or if the preview/disclosure
disappears.

**What is never sent.** Your home folder or user names, the bottle name, the host name, e-mail
addresses, IP/MAC addresses, UUIDs, tokens and similar identifiers (all replaced with placeholders
before the preview is built), game or account data, or a persistent identifier. The statistics
server can still observe ordinary network metadata such as the source IP address, as with any
HTTPS request.

Download totals remain release-host metrics; actual patch usage is measured only from reports the
user explicitly chooses to send.

## Mod framework (EFMI) — optional second phase

A separate **Mod Framework** window — menu bar **Tools → Mod Framework (EFMI)…** — hosts an
independent **bottle-side** phase that makes the **XXMI Launcher / EFMI** mod stack work: it
writes 3DMigoto's own chain-load option,

```ini
[System]
proxy_d3d11 = <the backend d3d11.dll inside the patched app>
```

into EFMI's `d3dx.ini`, so the mod's `d3d11.dll` hands off to this app's **D3D11→Metal backend**
instead of Wine's wined3d. (Why this is needed at all — 3DMigoto resolves its "original" as
`C:\Windows\system32\d3d11.dll`, which under CrossOver is wined3d on *every* backend — is
documented in [docs/mod-injection/](../docs/mod-injection/07-load-ordering-and-chaining.md).)

The window resolves the bottle, EFMI folder and chain target up front, shows them, and applies on
demand with its **Apply** button — runnable at any time, independently of the main window's
CrossOver patch (that app only has to exist so the chain has a target). **Revert** undoes it.
Installing XXMI Launcher + EFMI *into* the bottle is still a manual step done in the bottle itself;
this window only configures the chain once they are present.

What it does, in order:

1. Reads the bottle's graphics backend from `cxbottle.conf`
   (`CX_ACTIVE_GRAPHICS_BACKEND`, falling back to `CX_GRAPHICS_BACKEND`). A bottle on
   **wined3d** (no backend) needs no chain and the phase reports that.
2. Finds the EFMI folder (XXMI Launcher's `XXMI Launcher Config.json` → its default
   `%APPDATA%\XXMI Launcher\EFMI` → or you pick it).
3. Backs up `d3dx.ini` → `d3dx.ini.cxorig` (once), then sets `proxy_d3d11` inside `[System]`
   **only** — everything else in the file stays byte-identical, and the shipped
   `;proxy_d3d11=…` example line is kept.
4. Verifies the edit and writes a `d3dx.ini.finewine-chain` state file (app path, backend, mode,
   target, SHA-256, date) so re-runs and reverts know what they did.

Guarantees:

- **Idempotent** — re-running with the same app + backend changes nothing.
- **Byte-exact revert** — "Revert" removes only the two added lines and restores any line the
  apply replaced (recorded in the state file as `replaced_line`); if XXMI has since rewritten
  `d3dx.ini`, the pre-chain backup is used instead.
- **Backend-aware** — if you switch the bottle's backend (`d3dmetal` ↔ `dxmt` ↔ `dxvk`), re-running
  rewrites the target.
- **No CrossOver files are bundled or shipped** — the backend `d3d11.dll` is referenced at its
  location inside *your* patched app (or, when the bottle has no `Z:` mapping, copied from it into
  the EFMI folder as `d3d11_cx.dll`). It is never included in the app payload or a release.
- It never changes the bottle's `CX_GRAPHICS_BACKEND`; it adapts to it.

The same feature is available from the shell, either with flags or environment variables
(a flag always wins over its env var):

```bash
scripts/swap-into-crossover.sh --mod-chain --skip-app-patch --bottle "Arknights Endfield"   # apply
scripts/swap-into-crossover.sh --mod-chain-revert --skip-app-patch                          # undo
```

Other flags: `--app PATH` (patched app to chain against), `--importer PATH` (explicit EFMI
folder), `--chain-mode path|copy`, `--bottles-root PATH`, plus the app-patch flags
(`--src-app`, `--dest-app`, `--gptk-dir`, `--skip-gptk`, `--skip-mvk`). `--help` has the full
list; the env equivalents (`MOD_CHAIN`, `MOD_BOTTLE`, …) are documented in the script header.

After applying, verify with experiment **L3** in
[docs/mod-injection/06-experiment-plan.md](../docs/mod-injection/06-experiment-plan.md): launch
Endfield via XXMI and check `d3d11_log.txt` for *"Proxy loading active, Forcing
load_library_redirect=0"*. Note that XXMI rewrites `d3dx.ini` when it updates EFMI
(`overwrite_ini=True`), so re-run the phase (or disable that option in XXMI) after an update.

## Building the app

Requires the Xcode Command Line Tools only (no Xcode):

```bash
# 1. Build the patched Wine first (once) — produces build/wine-build64
./scripts/build-wine.sh all

# 2. Build the patched MoltenVK (once) — produces build/moltenvk-out
./scripts/build-moltenvk.sh all

# 3. Build the app around them
./patcher-app/scripts/build-app.sh
open "patcher-app/build/FineWine Patcher.app"
```

`PAYLOAD_DIR` overrides where the Wine modules come from (the `build/wine-build64` tree layout or
a flat directory with the three files); `MOLTENVK_DIR` overrides where `libMoltenVK.dylib` comes
from (default `build/moltenvk-out`, or a copy inside `PAYLOAD_DIR`). `CODESIGN_ID` sets a real
signing identity (default: ad-hoc). `ALLOW_MISSING_PAYLOAD=1` produces a payload-less smoke-test
build that refuses to patch.

### App icon

`build-app.sh` bakes in `Resources/AppIcon.icns` (a committed file). To regenerate it after
changing the source art, run `scripts/make-appicon.sh` — it renders the full macOS size set from
`Resources/appicon/appicon-source.png` with Apple tools only (`swift` + `iconutil`, no
third-party image libraries), centering the artwork on a transparent square with a 6% margin
(`MARGIN=…` to change). If `AppIcon.icns` is absent, the app simply builds without a custom icon.

## Licensing (important if you distribute the built app)

- **The app itself** (Swift sources, UI, this directory): [MIT](../LICENSE).
- **The bundled Wine modules** (`ntdll.so`, `kernel32.dll`, `ntoskrnl.exe`, `lsass.exe`, `wineboot.exe`, `wineserver`): **LGPL-2.1-or-later** —
  they are Wine, built from CodeWeavers' freely published
  [CrossOver 26.3 Wine source](https://www.codeweavers.com/crossover/source) with this repo's
  [patches](../patches/) applied (which include the
  [dw-proton](https://dawn.wine/) anti-cheat patches — see [patches/README.md](../patches/README.md)
  for authorship).
- **The bundled `libMoltenVK.dylib`**: **Apache-2.0** — MoltenVK, built from the Khronos Group
  [MoltenVK](https://github.com/KhronosGroup/MoltenVK) sources with this repo's
  [patches/moltenvk](../patches/moltenvk/) applied.
- The app's **Licenses…** window shows all of this, with the full license texts, offline.

If you publish a built `FineWine Patcher.app` (e.g. a GitHub Release), LGPL-2.1 requires you to
make the **complete corresponding source** of the Wine modules available: this repository's
patches + the exact `crossover-sources-26.3.0` archive from
[media.codeweavers.com/pub/crossover/source](https://media.codeweavers.com/pub/crossover/source/).
Apache-2.0 requires the MoltenVK license/notice to travel with the binary (the app bundles it)
and the corresponding source to be offered (this repo's MoltenVK patches + the pinned upstream
revision recorded by `scripts/build-moltenvk.sh`).
Best practice: attach (or mirror in a release) the exact source tarballs you built from, so your
source offer doesn't depend on a third-party URL staying alive.

The app never contains or redistributes CrossOver itself, Apple's Game Porting Toolkit, or the
game. It requires the user's own licensed CrossOver install as input, and links to
[codeweavers.com/store](https://www.codeweavers.com/store) for buying one.

## Layout

```
Package.swift                     SwiftPM manifest (macOS 13+)
Sources/FineWinePatcher/
  FineWinePatcherApp.swift        app entry: main window + Tools menu + the Mod Framework window
  ContentView.swift               the main window UI (the patch flow only)
  ModChainView.swift              the Mod Framework window: bottle + EFMI discovery, apply/revert chain
  PatchProgressViews.swift        the shared step-checklist and error views
  PatchTelemetryPromptView.swift  the post-patch send/skip dialog with the exact payload preview
  TelemetryThankYouView.swift     the post-send thank-you dialog with confetti
  UsageTelemetry.swift            per-run report schema, allowlists, and the one send action
  PatcherEngine.swift             the patch steps (mirrors swap-into-crossover.sh) + the mod-chain phase
  ModChain.swift                  the mod (EFMI) chain support: backend/bottle/EFMI discovery,
                                  the d3dx.ini [System] proxy_d3d11 edit, verify, revert, state file
  LicensesView.swift              the Licenses window + component metadata
Tests/FineWinePatcherTests/
  ModChainTests.swift             the mod-chain ini-editing rules (swift test)
  UsageTelemetryTests.swift       per-run prompt schema + metadata allowlist checks (swift test)
Resources/licenses/               license texts bundled into the app
Resources/AppIcon.icns            the app icon (committed; regenerate with make-appicon.sh)
Resources/appicon/                the icon source art
scripts/build-app.sh              compile + assemble + payload staging (Wine + MoltenVK) + signing
scripts/check-telemetry-privacy.py  build-time privacy gate for user-confirmed telemetry
scripts/make-appicon.sh           regenerate AppIcon.icns from the source art
scripts/make-appicon.swift        the icon renderer (ImageIO/Core Graphics)
build/                            (gitignored) the assembled .app
```
