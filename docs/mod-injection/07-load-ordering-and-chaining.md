# 07 — Load ordering: keeping CrossOver's Metal mapping at the bottom of the chain

> **Answers the question:** *"the mod platform's `d3d11.dll` gets swapped in; since we also need
> CrossOver's D3D→Metal mapping, is there a way to force the ordering so the mod's interception is
> always in front of, and CrossOver's mapping always after, the mod?"*
>
> **Short answer: yes — and no Wine patch is required.** The ordering lever already exists
> *inside 3DMigoto* (`[System] proxy_d3d11`, the chain-load option), and it is the only mechanism
> that reliably expresses "mod first, CrossOver mapping second". A global "load order" knob does
> not, and cannot, do this job — the reasons are below, verified against Wine 11.0's loader source
> and 3DMigoto's source.
>
> Sources: `dawn-winery/wine-dwproton` tag `dwproton/11.0-13` — `dlls/ntdll/loader.c`
> (`find_dll_file`, `load_dll`, `load_native_dll`, `find_existing_module`), read in full; the
> upstream `bo3b/3Dmigoto` tree — `DirectX11/D3D11Wrapper.cpp` (`InitD311`, `ReplaceOnMatch`),
> `DirectX11/IniHandler.cpp` (the `[System]` keys), `Dependencies/d3dx.ini`; XXMI's
> `model_importer.py` (`overwrite_ini` default). `[overall confidence: high]`

## 1. The three resolution rules that actually decide the order

Everything hinges on how Wine 11.0 (`dlls/ntdll/loader.c`) resolves a DLL name. There are two
radically different paths, and the mod platform uses **both**:

### Rule A — a load by **bare name** (`LoadLibrary("d3d11.dll")`, or the game's import table)

`find_dll_file()` does, in order:

1. **API sets** → **activation-context (SxS) redirection**,
2. **`find_basename_module( libname )`** → if a module whose *base name* matches is already loaded
   in this process, **return it and load nothing**,
3. otherwise `open_known_dll()` → the KnownDLLs/builtin path — **this is where Wine's load order
   and therefore CrossOver's backend redirect act**.

```c
        else
        {
            if (status != STATUS_SXS_KEY_NOT_FOUND) return status;
            if ((*pwm = find_basename_module( libname ))) return STATUS_SUCCESS;   /* ← base-name dedupe */
            if (!open_known_dll( libname, nt_name, pwm, mapping, image_info, id )) /* ← builtin/backend */
                return STATUS_SUCCESS;
        }
```

**Consequences:**

- **Whoever is loaded first under the name `d3d11.dll` wins the name.** Every later bare-name load
  returns that module. There is no "ordering" knob that changes this — it is a hard rule.
- CrossOver's backend is injected exactly at step 3, for bare-name loads. That is why the game gets
  Metal today while `system32\d3d11.dll` is still the wined3d file (hash-verified, see
  [03 §2](03-crossover-backend-landscape.md)).

### Rule B — a load by **full path** (`LoadLibraryEx("C:\Windows\system32\d3d11.dll")`, or the
injected mod DLL's absolute path)

```c
    else if (!(status = RtlDosPathNameToNtPathName_U_WithStatus( libname, nt_name, NULL, NULL )))
        status = open_dll_file( nt_name, pwm, mapping, image_info, id );
    ...
static NTSTATUS load_native_dll( ... )
{
    ...
    if ((*pwm = find_existing_module( module )))  /* already loaded */
```

`find_existing_module()` dedupes by **file identity** (`TimeDateStamp` + `CheckSum` +
`NtAreMappedFilesTheSame`), *not* by base name. So:

- a full-path load of a **different file** with the same base name **loads a second module**,
  bypassing the search path, the load order, and CrossOver's backend redirect;
- a full-path load of the **same file** that is already loaded returns the already-loaded module.

**This is why 3DMigoto's proxy mode works at all on Windows** (it loads the system `d3d11.dll` by
full path while it is itself loaded as `d3d11.dll` from the game dir — two modules, same name),
and it is the property we can exploit to force the layering.

## 2. How 3DMigoto resolves its "original" — and why that is the failure point here

`InitD311()` (`DirectX11/D3D11Wrapper.cpp`) — the chain-resolution code, abridged:

```c
	if (G->CHAIN_DLL_PATH[0])          /* ← [System] proxy_d3d11 was set */
	{
		LogInfo("Proxy loading active, Forcing load_library_redirect=0\n");
		G->load_library_redirect = 0;

		/* resolve relative to 3DMigoto's own directory first, then as given */
		... GetModuleFileName(migoto_handle, sysDir, ...); wcscat(sysDir, G->CHAIN_DLL_PATH);
		hD3D11 = LoadLibrary(sysDir);
		if (!hD3D11) hD3D11 = LoadLibrary(G->CHAIN_DLL_PATH);
	}
	else
	{
		/* We'll look for this in DLLMainHook to avoid callback to self.
		   We need the system d3d11 in order to find the original proc addresses. */
		hD3D11 = LoadLibraryEx(L"original_d3d11.dll", NULL, 0);   /* sentinel name */
		if (hD3D11 == NULL)
		{
			LoadLibraryEx(L"SUPPRESS_3DMIGOTO_REDIRECT", NULL, 0);
			ret = GetSystemDirectoryW(libPath, ...);
			wcscat_s(libPath, ..., L"\\d3d11.dll");
			hD3D11 = LoadLibraryEx(libPath, NULL, 0);            /* ← full path */
		}
	}
	/* then: GetProcAddress(hD3D11, "D3D11CreateDeviceAndSwapChain") etc. */
```

and the sentinel is translated by 3DMigoto's own `LoadLibraryExW` hook
(`ReplaceOnMatch()`):

```c
	if (_wcsicmp(lpLibFileName, our_name) == 0)      /* "original_d3d11.dll" */
	{
		... GetSystemDirectoryW(fullPath, ...); wcscat_s(fullPath, ..., L"\\" library);
		return fnOrigLoadLibraryExW(fullPath, hFile, dwFlags);   /* → C:\Windows\system32\d3d11.dll */
	}
```

### The failure point, stated plainly

Under CrossOver, `C:\Windows\system32\d3d11.dll` is the **wined3d** file — verified by hash in our
bottle. The *backend* implementation lives elsewhere and is only reachable through bare-name
resolution (`lib64/apple_gptk/wine/x86_64-windows/d3d11.dll` for D3DMetal, `lib/dxmt/x86_64-windows/d3d11.dll`
for DXMT, `lib/dxvk/x86_64-windows/d3d11.dll` for DXVK — see
[03 §1](03-crossover-backend-landscape.md)).

So by default, in **every** CrossOver backend, 3DMigoto's chain terminates at:

```
mod d3d11  →  C:\Windows\system32\d3d11.dll  =  wined3d          ← WRONG for us
```

instead of

```
mod d3d11  →  backend d3d11 (Metal shim / DXMT / DXVK)  →  Metal
```

This is not a Wine bug and not a CrossOver bug — it is 3DMigoto correctly loading the *Windows
system path*, which under CrossOver is not where the backend lives. It also applies to the
**injected** variant, because the injected DLL runs the same `InitD311()` and needs the original's
proc addresses just the same. ⚠️ Inferred-but-strong: the same code path is used in both modes.
`[confidence: high on the code path, medium on the exact runtime behaviour — see §5 tests]`

## 3. The answer: force the ordering with 3DMigoto's own chain option

`d3dx.ini`, `[System]` section (documented in upstream `Dependencies/d3dx.ini`):

```ini
[System]
proxy_d3d11=<path or name>     ; chain load another wrapper instead of the system DLL
load_library_redirect=2        ; 0=off, 1=nvapi only, 2=d3d11+nvapi forced back to the mod folder
```

Semantics worth knowing before touching it:

- `proxy_d3d11` is resolved **relative to 3DMigoto's own directory first** (the dir of the loaded
  `d3d11.dll`), then as a plain path. So the robust form is to **copy CrossOver's backend
  `d3d11.dll` next to EFMI's `d3d11.dll` under a different name** and reference it relatively.
- Setting it forces `load_library_redirect = 0` ("allow all through unchanged") — this is the
  intended configuration for chaining; the chained proxy must not be re-hooked or it loops back
  into 3DMigoto.
- Full-path loads dedupe by **file identity** (Rule B), so if CrossOver has already loaded that
  same backend file, the chain will simply attach to the **already-loaded backend module** rather
  than creating a duplicate — which is exactly the layering we want:
  ```
  game call → mod d3d11 (hooks) → backend d3d11 (already loaded, same file) → Metal
  ```

### Concrete targets for our build

`z:` maps to `/` in this bottle (`dosdevices/z: -> /`), so the app bundle is visible in-bottle. The
chain target for each backend, as seen from inside the bottle:

| Bottle backend | `proxy_d3d11` target |
|---|---|
| `d3dmetal` (current) | `Z:\Applications\CrossOver_Endfield_Patch.app\Contents\SharedSupport\CrossOver\lib64\apple_gptk\wine\x86_64-windows\d3d11.dll` |
| `dxmt` | `Z:\Applications\CrossOver_Endfield_Patch.app\Contents\SharedSupport\CrossOver\lib\dxmt\x86_64-windows\d3d11.dll` |
| `dxvk` | `Z:\Applications\CrossOver_Endfield_Patch.app\Contents\SharedSupport\CrossOver\lib\dxvk\x86_64-windows\d3d11.dll` |

(The DXMT copy also carries `d3d10core.dll`, `dxgi.dll`, `nvapi64.dll`, `nvngx.dll`,
`winemetal.dll` in the same directory — its own dependencies resolve by bare name, which is what
we want: those bare-name loads are exactly the ones CrossOver's redirect handles.)

> **Preferred form** (robust to app-bundle paths): copy the backend `d3d11.dll` into the EFMI
> folder as e.g. `d3d11_cxmetal.dll` / `d3d11_cxdxmt.dll` and set
> `proxy_d3d11=d3d11_cxdxmt.dll`. Same file identity → same dedupe behaviour, and no dependency on
> where CrossOver happens to be installed.

> **Verified against EFMI's actual config (2026-09-21):** EFMI's shipped
> `d3dx.ini` (`SpectrumQT/EFMI-Package` → `EFMI/d3dx.ini`) already contains a `[System]` section
> with `;proxy_d3d11=d3d11_helix.dll` **commented out** and `load_library_redirect = 2`. So
> applying the chain is a one-line uncomment + path inside a section that already exists — the
> option is not something we would be adding to the fork. The XXMI DLL fork's sources are at
> `SpectrumQT/XXMI-Libs-Package` ("XXMI DLL is a fork of 3dmigoto"), which is the tree to confirm
> against that `IniHandler` still reads `[System] proxy_d3d11` (upstream does, at
> `DirectX11/IniHandler.cpp:4143`).

## 4. What does *not* work as an "ordering" mechanism (and why)

| Mechanism | What it actually does | Why it doesn't answer the question |
|---|---|---|
| `WINEDLLOVERRIDES` / `AppDefaults\…\DllOverrides` (`native,builtin`) | Changes **which file wins for a bare-name load** | It is the *same lever* CrossOver's `cxcompatdb.so` uses for the backend (its strings expose `add_dll_overrides`, `add_load_order_override`, `parse_dll_overrides_hack`). Setting our own value for `d3d11` can therefore **fight** the backend override rather than compose with it. Fine for `d3dcompiler_47` (nothing else claims it); risky for `d3d11`/`dxgi`. |
| Loading the backend *before* the mod so a later bare-name load "finds" it | — | Backwards: the mod must be in front. And once the backend module exists, a bare-name load returns it — which is how the game works today without mods, but it gives the mod nothing to hook into. |
| The Wine 11.6 `CompanyName` heuristic ([02 §2](02-wine-dll-loading-and-mod-dlls.md)) | Prefers a non-Microsoft native file at bare-name resolution | Only affects Rule A (bare name). It can help the **proxy** variant get loaded, but it does nothing for the mod→backend chain, and it is not present in our Wine 11.0 anyway. |
| A global "load order" env/registry knob | does not exist | Wine has no ordering concept beyond per-module builtin/native; Windows' DLL search order is about *finding files*, not about stacking wrappers. |

## 5. Experiments that confirm or refute this (add to [06](06-experiment-plan.md))

| # | Test | Signal |
|---|---|---|
| L1 | With mods installed, run `WINEDEBUG=+loaddll` and record the order of `d3d11.dll` loads in the `Endfield.exe` process | Shows whether the mod's DLL or the backend is loaded first, and how many `d3d11`-named modules exist. |
| L2 | Read EFMI's `d3d11_log.txt` (3DMigoto's own log) | 3DMigoto logs the chain: `Trying to load original_d3d11.dll` → the resolved path + `GetProcAddress` results. If it shows `C:\Windows\system32\d3d11.dll`, the default chain ended at wined3d — confirms §2. |
| L3 | Set `[System] proxy_d3d11=<backend dll>` and re-run L2 | `Proxy loading active, Forcing load_library_redirect=0` should appear, and the chain should resolve to the backend file. |
| L4 | Verify the backend was *already* loaded when the chain attaches (`+loaddll`) | Confirms Rule-B identity dedupe is attaching to the live backend module rather than loading a second one. |
| L5 | Switch backend (`d3dmetal` ↔ `dxmt`) and repeat L3 | Establishes which backend the chain survives. |

## 6. Practical caveats for the config-only route

1. **XXMI rewrites `d3dx.ini` on deploy.** `model_importer.py` defaults to `overwrite_ini: bool = True`,
   so a hand-edited `proxy_d3d11` will be clobbered when EFMI updates. Mitigation at launcher
   level: disable "overwrite ini" in XXMI's settings (it restores/keeps a user `d3dx.ini`),
   or re-apply the `[System]` section after updates. No code change in our repository is needed.
2. **`load_library_redirect=2` is 3DMigoto's default** and is part of why the whole scheme is
   order-sensitive: it steals the game's own `C:\Windows\system32\d3d11.dll` loads and re-points
   them at the mod folder. Under CrossOver that is *good* (keeps the mod in front) — but it must
   not be fighting `proxy_d3d11`, which is why chaining forces it to `0`.
3. **The backend file must be visible in the bottle.** Verified: `z:` → `/`, so the app bundle is
   reachable. If a future CrossOver version changes `dosdevices`, use the copy-next-to-EFMI form.
4. **`nvapi64` interaction:** DXMT's directory ships its own `nvapi64.dll`/`nvngx.dll`, and
   CrossOver already has a `redirect_nvngx_to_d3dmetal` hack. XXMI removes its own `nvapi64.dll`
   (per [#117](05-known-issues-and-references.md)) — keep that, and don't add ours back.
5. **D3DMetal's chain target is a 114 KB shim**, not a full implementation. Chaining to it is
   structurally valid, but whether 3DMigoto's hooks behave across the shim→framework boundary is
   unmeasured — that is what L3/L5 are for. DXMT's target is a full 4.7 MB implementation and is
   the closer analogue to the Linux/Proton case where EFMI is known to work.

## 7. One-paragraph summary

The layering the user wants is expressible, but not through any global ordering knob. Wine resolves
bare-name loads by *base name* (first-loaded wins) and routes system DLLs through the KnownDLLs/
builtin path where CrossOver's backend redirect acts, while full-path loads dedupe by *file
identity* and load whatever file is named. 3DMigoto resolves its "original" as a **full path to
`C:\Windows\system32\d3d11.dll`**, which in CrossOver is the wined3d copy on every backend — so its
chain silently terminates at wined3d instead of Metal. The fix is 3DMigoto's own first-class
chain-load option, `[System] proxy_d3d11`, pointed at CrossOver's backend `d3d11.dll` (DXMT's or
the D3DMetal shim), which attaches to the already-loaded backend module by file identity. That is
a `d3dx.ini` configuration change plus a DLL copy inside the bottle — no Wine patches, no source
changes.