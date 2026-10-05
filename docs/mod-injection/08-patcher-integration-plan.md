# 08 — Integration plan: adding mod-chain support to the patching tools

> **Scope of this document:** a **plan**, written during the research phase. **No code has been
> changed yet.** It specifies how `[System] proxy_d3d11` support ([07](07-load-ordering-and-chaining.md))
> would be added to the two patching tools in this repository:
>
> - `scripts/swap-into-crossover.sh` — the shell reference implementation, and
> - `patcher-app/` (`FineWine Patcher.app`) — the GUI equivalent, `PatcherEngine.swift` + `ContentView.swift`.
>
> The repository convention (documented in `patcher-app/README.md`) is that **the app mirrors the
> script's steps**, so the plan is: specify the step once, implement it in the script first, then
> port it to the app.

> **✅ IMPLEMENTED (2026-09-21).** Everything below §2 is now in the tree, with the user's stated
> assumption — *the XXMI fork honours `[System] proxy_d3d11`* — recorded here as the standing
> caveat (verify with experiment L3 before trusting a "mods load" run):
>
> | Piece | Where |
> |---|---|
> | Shell step (reference implementation) | `scripts/swap-into-crossover.sh` — optional step 7, runnable with **flags or env vars** (a flag wins): `--mod-chain` / `--mod-chain-revert`, `--bottle`, `--app`, `--importer`, `--chain-mode path\|copy`, `--bottles-root` (for scratch-bottle testing), `--skip-app-patch` (run only the mod step); env equivalents `MOD_CHAIN`, `MOD_BOTTLE`, `MOD_APP`, `MOD_IMPORTER`, `MOD_CHAIN_MODE`, `MOD_BOTTLES_ROOT`, `SKIP_APP_PATCH` |
> | App phase | `patcher-app/Sources/FineWinePatcher/ModChain.swift` (`ChainBackend`, `BottleInfo`, `ChainPlan`, `ModChain`) + the mod-phase state in `PatcherEngine.swift` (`applyModChain`/`revertModChain`) + the "Mod chain (EFMI)" group box in `ContentView.swift` |
> | Tests | `patcher-app/Tests/FineWinePatcherTests/ModChainTests.swift` (`swift test`, 9 tests: apply/re-apply idempotence, commented-example preserved, user-chain replaced + restored, no-`[System]` error, byte-identical revert, CRLF preserved, backend parsing) |
> | Verified behaviour | against a scratch bottle + the real EFMI `d3dx.ini`: apply is a no-op on re-run, revert is **byte-identical** (LF and CRLF), copy mode stages `d3d11_cx.dll` and reverts cleanly, a user-set `proxy_d3d11` is recorded as `replaced_line` and restored on revert, wined3d/absent backend skips cleanly |

## 1. Why this belongs in the patcher tools (and not in `patches/`)

The chain fix is a **bottle-side configuration** change, not a Wine change:

| Component | Touched? | Why |
|---|---|---|
| `patches/` (Wine patches, LGPL) | **no** | Nothing in Wine needs to change. The loader already supports full-path chain loads, and `proxy_d3d11` is a 3DMigoto feature. |
| `patcher-app/` payload (`ntdll.so`, `kernel32.dll`, `ntoskrnl.exe`) | **no** | The payload is the anti-cheat set only; it stays untouched. |
| Bottle `d3dx.ini` (EFMI's) | **yes** | One line in the `[System]` section. |
| Patching tools (script + app) | **yes** | They are where CrossOver-root knowledge already lives, and where an end-user-facing "one button" belongs. |

Two structural reasons it fits the patcher specifically:

1. **The chain target lives inside the patched app bundle.** The correct `proxy_d3d11` value is a
   path into `CrossOver_Endfield_Patch.app/Contents/SharedSupport/CrossOver/lib{64}/…/d3d11.dll`.
   The patcher is the only component that knows both the bottle and the (just-created) app path.
2. **Licensing guardrail.** CrossOver's DLLs are proprietary. The fix must therefore be applied
   **by copying from the user's own CrossOver install at patch time** — the backend `d3d11.dll`
   must **never be bundled** into the patcher payload or a release. This keeps the existing
   licensing story (`patcher-app/README.md` §Licensing) intact.

## 2. The edit, precisely

EFMI's shipped `d3dx.ini` (`SpectrumQT/EFMI-Package` → `EFMI/d3dx.ini`) **already contains** the
`[System]` section with the chain option present but commented out, plus the loader-redirect
default we want to keep:

```ini
[System]
;proxy_d3d9=d3d9_helix.dll
;proxy_d3d11=d3d11_helix.dll
...
load_library_redirect = 2
```

So the whole change is:

1. uncomment/replace `proxy_d3d11` in `[System]` with the backend target,
2. leave `load_library_redirect = 2` as-is — `InitD311()` **forces it to `0` at runtime whenever
   `CHAIN_DLL_PATH` is set** (`LogInfo("Proxy loading active, Forcing load_library_redirect=0")`),
   so the file value must not be edited by the tool. `[confidence: high]`

Everything else in the file (the `[Loader]`, `[Include]`, `[Rendering]` sections the launcher
manages) must be preserved **byte-for-byte**.

### The target table (source of truth for both implementations)

Resolved from the patched app's CrossOver root (`$APP/Contents/SharedSupport/CrossOver`), read
from inside the bottle (`dosdevices/z: -> /`, verified in our bottle):

| `CX_GRAPHICS_BACKEND` | chain target (in-bottle form) |
|---|---|
| `d3dmetal` | `Z:\Applications\<App>.app\Contents\SharedSupport\CrossOver\lib64\apple_gptk\wine\x86_64-windows\d3d11.dll` |
| `dxmt` | `Z:\Applications\<App>.app\Contents\SharedSupport\CrossOver\lib\dxmt\x86_64-windows\d3d11.dll` |
| `dxvk` | `Z:\Applications\<App>.app\Contents\SharedSupport\CrossOver\lib\dxvk\x86_64-windows\d3d11.dll` |
| *(wined3d / unset)* | **not needed** — the default chain already ends at the system `d3d11.dll`, which *is* wined3d in that case. The tool should report this and skip. |

Notes that both implementations must honour:

- `dosdevices/z: -> /` exists in this bottle but is **not guaranteed** in general (a future bottle
  could map only `y:` or nothing). The tool must verify the `Z:\…` path resolves **inside the
  bottle** (i.e. the host path `/Applications/<App>.app/…` is reachable through the bottle's `z:`),
  and fall back to the **copy-next-to-EFMI** form (below) if it is not.
- **Copy fallback / robustness mode:** copy the backend `d3d11.dll` into the EFMI folder as
  `d3d11_cx.dll` and set `proxy_d3d11=d3d11_cx.dll`. Same file identity → same full-path dedupe
  behaviour ([07 §1 Rule B](07-load-ordering-and-chaining.md)), and independent of where the app
  is installed. Cost: a stale copy if the user upgrades CrossOver; mitigated by recording the
  source hash in the state file and re-copying on re-run.
- The DXMT directory carries `d3d10core.dll`, `dxgi.dll`, `nvapi64.dll`, `nvngx.dll`,
  `winemetal.dll` as siblings. Those are resolved by **bare name** at load time, which is exactly
  the load path CrossOver's `cxcompatdb` redirect handles — so we should **not** copy them, only
  the `d3d11.dll`. (Copying them could shadow the redirect with a stale version.)

## 3. Detection (what the tool must find before it can act)

| Input | How to get it | Fallback |
|---|---|---|
| **Bottle** | enumerate `~/Library/Application Support/CrossOver/Bottles/*/` | user picks one |
| **Backend** | `cxbottle.conf`: `CX_ACTIVE_GRAPHICS_BACKEND`, else `CX_GRAPHICS_BACKEND` | user picks (`d3dmetal`/`dxmt`/`dxvk`) |
| **EFMI folder** | `XXMI Launcher Config.json` (stored at the launcher's install root as `XXMI Launcher Config.json`; key path `Importers.EFMI.Importer.importer_path`) | ① default `%APPDATA%\XXMI Launcher\EFMI` → in-bottle `drive_c/users/<user>/AppData/Roaming/XXMI Launcher/EFMI`; ② **ask** (file picker) |
| **`d3dx.ini`** | must exist in the EFMI folder — its presence is the "EFMI is installed" test | error with instructions |
| **Patched app root** | the app the tool just created (script: `$DEST_APP`; app: `PatcherEngine.patchedApp`) | user picks the patched app |

Validation gate: if the EFMI folder or the game folder can't be found, the mod-chain step must
**fail cleanly with a message**, not abort the whole app patch — they are independent phases.

## 4. Step specification (shared by both implementations)

```
Step "Staging mod (EFMI) chain support"
  1. Resolve backend  → chain target path (table above) + verify the file exists in the patched app
  2. Locate EFMI folder (d3dx.ini present)
  3. Backup d3dx.ini → d3dx.ini.cxorig        (only if no backup exists yet)
  4. Edit d3dx.ini:
       - in [System]: set proxy_d3d11 = <target>
       - add/refresh marker line:  ; FineWine chain: <backend> <target-hash8> <date>
  5. Write state file  EFMI/d3dx.ini.finewine-chain:
       { app_path, backend, target, target_sha256, mode: "path"|"copy", applied_at }
  6. Verify:
       - d3dx.ini contains the marker and the proxy_d3d11 line inside [System]
       - (mode "copy") the copied DLL exists and matches the source size
  7. Report: which backend, which target, and the instruction to launch via XXMI and check
             EFMI/d3d11_log.txt for "Proxy loading active, Forcing load_library_redirect=0"
```

**Idempotency and lifecycle:**

| Situation | Behaviour |
|---|---|
| Re-run with same app + backend | no-op except refreshing the marker date |
| User switched backend (`d3dmetal` → `dxmt`) | rewrite `proxy_d3d11` to the new target; in *copy* mode re-copy and update the hash |
| User updated CrossOver under the same app path | same as backend switch (target file content changed → re-copy in copy mode) |
| **XXMI updated EFMI and clobbered `d3dx.ini`** (`overwrite_ini: bool = True` default in `model_importer.py`) | the marker/state file survives, the `[System]` line does not → re-run the step, which detects "state file present but marker missing" and re-applies |
| User wants it gone | restore `d3dx.ini.cxorig`, delete the state file (and the copied DLL in copy mode) |

The tool should also surface the *user-level* mitigation for the clobber case: turning **off**
XXMI's "overwrite ini" option means a hand-maintained `d3dx.ini` survives EFMI updates.

## 5. Shell script design (`scripts/swap-into-crossover.sh`)

Add an **optional, env-gated** phase so the default behaviour of the script is unchanged:

```
MOD_CHAIN=1                      # opt-in
MOD_BOTTLE="Arknights Endfield"  # default: the repo's documented bottle name
MOD_APP="$DEST_APP"              # the patched app just created by this script
MOD_IMPORTER=""                  # optional explicit EFMI folder override
MOD_CHAIN_MODE="path"            # "path" (Z:\ absolute) | "copy" (stage next to EFMI)
```

Behaviour sketch (to be implemented when we leave the research phase):

```bash
# ---------------------------------------------------------------- 7. mod chain (optional)
if [ "${MOD_CHAIN:-0}" = "1" ]; then
  BP="$HOME/Library/Application Support/CrossOver/Bottles/$MOD_BOTTLE"
  backend=$(sed -n 's/.*"CX_ACTIVE_GRAPHICS_BACKEND" *= *"\([^"]*\)".*/\1/p' "$BP/cxbottle.conf" \
         || sed -n 's/.*"CX_GRAPHICS_BACKEND" *= *"\([^"]*\)".*/\1/p' "$BP/cxbottle.conf")
  case "$backend" in
    d3dmetal) rel="lib64/apple_gptk/wine/x86_64-windows/d3d11.dll" ;;
    dxmt)     rel="lib/dxmt/x86_64-windows/d3d11.dll" ;;
    dxvk)     rel="lib/dxvk/x86_64-windows/d3d11.dll" ;;
    *)        echo "backend '$backend' needs no chain — skipping"; return 0 ;;
  esac
  src="$CXR/$rel"
  dosdev=$(readlink "$BP/dosdevices/z:"); [ "$dosdev" = "/" ] || { … fall back to copy mode … }
  bottle_target=$( … translate "$src" to "Z:$src" … )
  … locate EFMI dir (config json → default %APPDATA% → prompt) …
  … backup d3dx.ini, edit [System] proxy_d3d11, write marker + state file, verify …
fi
```

Two deliberate details:

- The step is placed **after** the app is fully assembled and signed (it reads files from the
  *patched* app, so it must run after step 5/6), but is **independent of it** — if the app already
  exists and only the mod chain is wanted, the script should allow running the phase alone
  (`MOD_CHAIN=1 SKIP_APP_PATCH=1`), because re-patching a multi-GB bundle to tweak one `ini` line
  is hostile.
- The `d3dx.ini` edit must be done with the same care as the module swap: **back up first, verify
  after**, and never rewrite the whole file.

## 6. App design (`patcher-app/`)

### 6.1 Engine (`PatcherEngine.swift`)

The app's current steps are all **app-bundle** steps. The mod chain is a **bottle** step, so it
should be a second, independently-runnable phase rather than a 5th step of the existing one:

```swift
enum ChainBackend: String { case d3dmetal, dxmt, dxvk, none }   // + target subpath per case

struct ChainTarget { let backend: ChainBackend; let crossoverSubpath: String }   // mirrors PayloadModule

struct ChainPlan {            // everything step 1–6 needs, resolved up-front so the UI can show it
    let bottle: URL, backend: ChainBackend, importerDir: URL, d3dxIni: URL
    let mode: Mode            // .path(Z:\ absolute) | .copy(next to EFMI)
    let targetPathInBottle: String, sourceFile: URL
}

final class PatcherEngine {
    // existing: patch(source:destination:)
    func applyModChain(plan: ChainPlan) { … same step list pattern: [locate, backup, edit, verify] }
    func revertModChain(plan: ChainPlan)
}
```

Reuse the existing conventions:

- `PatchError` for clean failures with actionable messages;
- `run("/usr/bin/codesign", …)`-style helpers stay app-side only (no signing needed here — the
  copied/staged DLL is not modified, so it needs **no** re-signing; if the app ever ships a
  modified DLL it would have to be ad-hoc signed like the payload, which is another reason not to
  modify it);
- verification by size + a real hash (`CryptoKit.SHA256`) rather than size alone, because the
  chain target is not a file we produce.

### 6.2 UI (`ContentView.swift`)

A second GroupBox below the existing one, shown only when a bottle with an installed EFMI is
detected (or always, with a "not detected" state):

```
┌ Mod chain (EFMI) ────────────────────────────────────────────┐
│  Bottle:      [ Arknights Endfield ▾ ]      backend: dxmt    │
│  EFMI folder: ~/…/XXMI Launcher/EFMI   [Choose…]             │
│  ☑ Chain EFMI's d3d11 to CrossOver's d3d11 (proxy_d3d11)     │
│     target: lib\dxmt\x86_64-windows\d3d11.dll                │
│  [ Apply ]  [ Revert ]                                       │
└──────────────────────────────────────────────────────────────┘
```

Copy for the toggle should state the *why* in one line ("makes 3DMigoto hand off to CrossOver's
D3D11→Metal backend instead of Wine's wined3d") — this is a non-obvious setting and the app's
style so far explains its steps.

### 6.3 What the app must **not** do

- **Never bundle CrossOver DLLs** in `Resources/payload/` (licensing, §1).
- **Never** edit `d3dx.ini` outside the `[System]` section, and never rewrite the file wholesale —
  the launcher and EFMI manage the rest of it, and the file is user-modifiable state.
- **Never** auto-change the bottle's `CX_GRAPHICS_BACKEND`. Switching backends for modding
  ([06 Stage C](06-experiment-plan.md)) stays a **manual, documented** decision; the tool should
  read the backend and adapt, not choose one.

## 7. Rejected alternatives (recorded so we don't rediscover them)

| Alternative | Why rejected |
|---|---|
| **XXMI "Custom Launch → Bypass" + Inject Libraries listing CrossOver's backend `d3d11.dll` first** | Injection order would load the backend as an extra library *around* the mod — the opposite of the required order (mod in front, backend below), and dependent on `run_direct_injector`'s ordering (XXMI dll first, then extras). |
| **Copying the backend `d3d11.dll` into the bottle's `system32`** | Directly contradicts the parent docs' warning (docs/13): swapping the D3D DLLs breaks `unityplayer.dll` init (error 1114); and it would change what *every* process in the bottle loads, not just the mod chain. |
| **Wine 11.6 `prefer_native_heuristics` backport instead** | Only changes *bare-name* load order ([02 §2](02-wine-dll-loading-and-mod-dlls.md)); does not create the mod→backend chain, which needs a full-path target. Complementary at most, and it isn't needed if `proxy_d3d11` works. |
| **Editing the bottle's `CX_GRAPHICS_BACKEND` automatically** | Out of scope and risky (the game's DX11 path is what currently works); the tool adapts to the backend, it doesn't pick one. |
| **Shipping a pre-staged `d3dx.ini`** | XXMI/EFMI own that file and rewrite it on update (`overwrite_ini=True`); we would be fighting their package manager. The marker + re-apply design exists precisely because of this. |

## 8. Acceptance criteria (when this leaves research)

1. `MOD_CHAIN=1 MOD_APP=… ./scripts/swap-into-crossover.sh` on the current bottle leaves
   `d3dx.ini` byte-identical except the `proxy_d3d11` line + marker; re-run is a no-op; revert
   restores the original file exactly.
2. `FineWine Patcher.app` shows the EFMI state (bottle, backend, EFMI folder, target) before
   applying, and fails with an actionable message when EFMI isn't installed rather than guessing.
3. Launching Endfield via XXMI with the chain applied produces `Proxy loading active, Forcing
   load_library_redirect=0` in `EFMI/d3d11_log.txt`, and `WINEDEBUG=+loaddll` shows the backend
   `d3d11.dll` being attached by file identity rather than loaded twice (L3/L4 in
   [06](06-experiment-plan.md)).
4. Switching the bottle backend and re-running the step rewrites the target without leaving the
   old copy behind (copy mode) and without touching anything else.
5. No CrossOver-owned file is added to the repository or to any release artifact.

## 9. Open questions (to resolve with experiments L1–L5 before/while implementing)

1. Does the **XXMI fork's** `d3d11.dll` still honour `[System] proxy_d3d11`? Upstream 3DMigoto
   parses it (`IniHandler.cpp:4143`), and EFMI's shipped `d3dx.ini` still ships the option — strong
   evidence yes — but the XXMI fork "removed legacy projects", so confirm via L3's log line before
   building UI around it.
2. Does the **D3DMetal shim** resolve its framework dependency correctly when chain-loaded by
   full path from a foreign directory? (`path` mode loads it from `Z:\…\apple_gptk\wine\…` — the
   same directory it normally loads from, so likely fine; *copy* mode would move it — prefer
   `path` mode for `d3dmetal`.)
3. Does DXMT's `winemetal.dll` dependency resolve when DXMT's `d3d11.dll` is loaded from the
   EFMI folder (copy mode)? Bare-name resolution → CrossOver redirect should answer it; if not,
   `path` mode is the fallback.
4. Does anything in ACE's integrity checks care that the game's D3D11 chain now has an extra
   module? Unmeasured; L-experiments on the DX11 path will show it, and this is a *record and
   escalate* item, not something to work around.