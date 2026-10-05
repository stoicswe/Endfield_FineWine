# 06 — Experiment plan (documentation only — nothing here changes source code)

> Every experiment below is a **runtime / configuration** change in the bottle or a
> read-only observation. No patches to Wine, no changes to `patches/`, `scripts/` or the game.
> Ordered cheapest-first, and each step is designed so its outcome **discriminates between
> hypotheses** rather than just "worked/didn't".

## 0. Ground rules for the experiments

- Snapshot the bottle state before touching it (at minimum: copy `cxbottle.conf` and `user.reg`;
  both already have `.bak` files from earlier work).
- Change **one dial at a time**. The three dials are:
  1. the game's renderer (DX11 vs Vulkan/DX12) — must be DX11 regardless,
  2. the bottle's graphics backend (`CX_GRAPHICS_BACKEND`: `d3dmetal` / `dxmt` / `dxvk`),
  3. the DLL overrides (`d3d11`, `dxgi`, `d3dcompiler_47`, `nvapi64`).
- Capture a log for every run: `DEBUG=1 scripts/launch-endfield.sh` writes
  `~/endfield-debug/<ts>/cxlog.txt`; for mod-specific signals add `WINEDEBUG=+loaddll,+seh`
  (`+loaddll` prints every module load — the single most useful channel for this work).
- Success criteria are stated per experiment; if an experiment cannot be run, record *why* in the
  results table at the bottom.

## Stage A — prove the plumbing before involving mods at all

### A1. Does an injected DLL get into the game process at all? (the base question)

**Setup:** install XXMI Launcher portable inside the `Arknights Endfield` bottle
(the launcher is a Windows app; XXMI portable requires Wine 9.22+, and our build is Wine 11.0 —
satisfies [#76](05-known-issues-and-references.md)). Install EFMI from the launcher. Do **not**
enable any override. Launch via XXMI with the game already confirmed working.

**Read:** the launcher log + `WINEDEBUG=+loaddll`.

| Outcome | Meaning |
|---|---|
| `Inject` returns `0`, and `+loaddll` shows `…\EFMI\d3d11.dll` loaded in the `Endfield.exe` process | Injection works; the problem was never the injection. Go straight to Stage C. |
| Error `130 LOADLIBRARY_FAIL` / `400 THREAD_FAIL` | The remote load itself fails. Look for ACE closing the process (compare with [#343](05-known-issues-and-references.md)) vs a Wine-specific thread/load failure. |
| Error `300`-style *"d3d11.dll is missing expected entry point"* | The **module-name collision** ([02 §1](02-wine-dll-loading-and-mod-dlls.md)). Go to A2. |
| Game crashes with `0x80000003` in `UnityPlayer.dll`, no `3DM-*.dmp` | ACE killed it — this is a *different* project (anti-cheat), out of scope for mod-loading research; record and stop. |

### A2. Does the module-name collision exist here? (`WINEDEBUG=+loaddll` observation, no config change)

Launch with `WINEDEBUG=+loaddll` and grep for how `d3d11` is resolved inside the game process:

```
…\EFMI\d3d11.dll        ← the mod's DLL actually loaded  (good)
C:\windows\system32\d3d11.dll   ← builtin wined3d served instead  (the #51 failure)
```

**Expected on our build:** the builtin, because there is no `d3d11` override and our Wine 11.0
lacks the 11.6 heuristic. If so, Stage B is the fix path. `[confidence: high that this is
measurable; medium that it is the blocker]`

### A3. Sanity: does the game still run after each bottle change?

After every backend/override change, confirm the unmodded game still reaches the login screen and
renders (the parent docs' known failure is a white screen from DX12/Vulkan, and error 1114 from
D3D-DLL tampering). Any regression here invalidates the mod test that follows.

## Stage B — make the right `d3d11` win (config only)

### B1. `d3dcompiler_47` override (lowest risk, do first)

```
WINEDLLOVERRIDES="d3dcompiler_47=n,b"
```
(or a per-app `AppDefaults\Endfield.exe\DllOverrides` entry).

Purpose: removes the known EFMI correctness problem
([#325](05-known-issues-and-references.md)) independently of everything else, and is the
lowest-risk change in the whole plan (the game already ships a native `d3dcompiler_47.dll`).
**Pass:** mods' shaders compile / no flat-mesh. Nothing else changes.

### B2. Add `d3d11` and `dxgi` overrides

```
WINEDLLOVERRIDES="d3d11=n,b;dxgi=n,b;d3dcompiler_47=n,b"
```

Purpose: let a native mod `d3d11.dll` win over builtin. This is the recipe from the only
macOS data point ([#117](05-known-issues-and-references.md)) and the standard Linux recipe.

⚠️ **Interaction to watch:** with `CX_GRAPHICS_BACKEND=d3dmetal`, the game's backend is chosen by
`cxcompatdb.so`, not by `system32/d3d11.dll`. Forcing `d3d11=native` may therefore change which
implementation the game actually gets. Watch for: (a) the game still rendering (D3DMetal still
applied — check the log line `using d3dmetal as the graphics backend`), or (b) falling back to
wined3d (slower/broken). If (b), the backend dial in Stage C becomes mandatory rather than optional.

### B3. Remove/neutralise `nvapi64`

Per [#117](05-known-issues-and-references.md): delete `nvapi64.dll` from the EFMI folder (and note
that CrossOver's own `lib/dxmt/x86_64-windows/nvapi64.dll` exists for the DXMT backend). XXMI ≥2.x
already removes it on deploy; verify it is gone rather than assume.

## Stage C — choose the backend the hook can live with

### C1. Switch the bottle backend to DXMT, keep everything from B

Set `CX_GRAPHICS_BACKEND=dxmt` for the bottle (bottle configuration, **not** a file swap), keep the
game on DX11, re-run A1/A2.

Why DXMT first: it is the only configuration where a **D3D11 interposer is independently reported
working on macOS under CrossOver** (ReShade, r/macgaming + the CodeWeavers tip page), and its
`d3d11.dll` is a full native implementation (4.7 MB) rather than the 114 KB D3DMetal forwarder —
see [03 §1](03-crossover-backend-landscape.md).

| Outcome | Meaning |
|---|---|
| Mods render | ⭐ done — the whole problem was backend + load order. |
| Same `300`/collision errors | The collision is backend-independent → the Wine 11.6 heuristic or a redirect patch becomes the interesting lever (Stage D). |
| Game no longer renders | DXMT incompatible with this game/build; try DXVK (C2) and record. |

### C2. DXVK as the fallback backend

`CX_GRAPHICS_BACKEND=dxvk`. This is the closest structural analogue to the Linux/Proton setups where
EFMI is proven working, at the cost of the Vulkan→MoltenVK hop (and it matches the CodeWeavers
observation that d3d11 wrapper mods work *with* DXVK and not without it).

### C3. D3DMetal as the *last* candidate

Only if C1/C2 both fail: try the mod stack **on the current d3dmetal backend** to characterise
whether the GPTK shim is hookable at all. Expectation (unmeasured): the shim forwards to
`D3DMetal.framework` and a hook may survive or may not — this experiment exists to measure that,
not because it is expected to succeed.

## Stage D — only if B/C are insufficient

These are **not** code changes to this repository; they are listed so the decision is recorded.

| Lever | What | When it is worth it |
|---|---|---|
| Backport Wine 11.6 `prefer_native_heuristics` into our patched `ntdll.so` | upstream `ntdll/unix/loadorder.c` (+ `loader.c`, `unix_private.h`) | If A2 shows the collision and B2's overrides are insufficient or too blunt (they are global/per-app, not per-DLL-instance). The patch is small, self-contained and upstream-designed to be conservative. |
| A general `WINE_LOADDLL_REPLACE`-style redirect (adapted from dwproton's `WINE_OPTISCALER_NAME`) | dwproton/Proton-CachyOS mechanism | Only if we decide the **proxy** design (serve the mod DLL by redirect) is preferable to injection. Higher blast radius; would need to be scoped carefully. |
| Use `wakka810/3dmigoto-arknights-endfield`'s standalone loader instead of XXMI's injector | external-loader 3DMigoto | If the *injection race* (GameBanana 228030) is the blocker: an external loader that starts the game suspended removes the race by construction. |
| Injection-timing mitigations inside XXMI settings | user-level: Start method = Shell, Custom Launch → Bypass + Inject Libraries | Always try these first — they are free and are the documented community fixes. |

## Stage E — the ACE question (separate, and expected to be hard)

If A1 shows injection working but the game dies (the [#343](05-known-issues-and-references.md)
signature), the mod-loading research stops and this becomes an anti-cheat problem:

- Compare our patched ACE path with the reported Windows behaviour: does the game produce a
  deliberate breakpoint / no `3DM-*.dmp`?
- Our stage-2 patches satisfy ACE **at init**. Whether ACE performs a later module/integrity check
  that a foreign `d3d11.dll` trips is **unknown and out of scope for the mod-loading work**. Any
  such finding should be recorded and escalated, not patched around — see the repo's ethics note.

## Stage L — load-ordering / chain experiments (see [07](07-load-ordering-and-chaining.md))

Run these *after* Stage A tells us the injection works (or alongside it), because they measure the
mod→backend chain rather than the injection itself.

| # | Test | Signal |
|---|---|---|
| L1 | `WINEDEBUG=+loaddll` with mods active | order and count of `d3d11.dll`-named modules in the game process |
| L2 | read EFMI's `d3d11_log.txt` | which file 3DMigoto resolved as its "original" (`original_d3d11.dll` → `C:\Windows\system32\d3d11.dll` = wined3d by default) |
| L3 | set `[System] proxy_d3d11=<backend d3d11.dll>` | `Proxy loading active, Forcing load_library_redirect=0` + chain resolves to the backend file |
| L4 | re-check `+loaddll` with L3 | whether the chain attaches to the *already loaded* backend module (file-identity dedupe) or loads a second copy |
| L5 | repeat L3 with `d3dmetal` ↔ `dxmt` | which backend the chain survives |

> **Good news found while planning the integration (2026-09-21):** EFMI's shipped
> `d3dx.ini` (`SpectrumQT/EFMI-Package` → `EFMI/d3dx.ini`) **already contains the `[System]`
> section with `proxy_d3d11` commented out** and `load_library_redirect = 2`. So L3 is a one-line
> uncomment plus a path, not a new option. It also reveals that the package's `[Loader] launch =`
> line hard-codes `C:\Program Files\GRYPHLINK\games\EndField Game\Endfield.exe` — our install uses
> `…\games\Arknights Endfield\Endfield.exe`, so autodetection should not rely on that folder name.
> How to wire this into the patcher tooling is specified in
> [08-patcher-integration-plan.md](08-patcher-integration-plan.md).

## Results table (fill in as experiments run)

| Exp | Date | Config | Result | Log path |
|---|---|---|---|---|
| A1 | — | not yet run | — | — |
| A2 | — | not yet run | — | — |
| B1 | — | not yet run | — | — |
| B2 | — | not yet run | — | — |
| C1 | — | not yet run | — | — |
| L1–L5 | — | not yet run | — | — |

## Current best-guess order of operations (pre-experiment, for the record)

1. Install XXMI + EFMI in the bottle (Stage A1).
2. `d3dcompiler_47=n,b` (B1) — free, fixes a known EFMI-on-Wine defect.
3. If collision observed (A2) → `d3d11=n,b;dxgi=n,b` (B2) and re-test.
4. If still failing or the backend degrades → switch bottle to `dxmt` (C1) and re-test, keeping
   D3DMetal for unmodded sessions.
5. Only after the above: consider Wine-side patches (Stage D).