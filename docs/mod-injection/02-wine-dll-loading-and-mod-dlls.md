# 02 — Wine DLL loading, builtin-vs-native, and the upstream fix

> **Sources:** upstream Wine commit `a31ec8da9572672e04ae46792a398da942649875` (patch text fetched in
> full), WineHQ bug 43727 (title/summary), XXMI issue #51 (maintainer's own diagnosis), the XXMI
> Linux flat-mesh issue #325, and standard Wine loader documentation. `[overall confidence: high]`

## 1. The core problem: one name, two candidate modules

Windows resolves a DLL by **base name**. Wine has to decide, per load, whether to serve its own
**builtin** implementation or a **native** Windows file. It does this via a *load order* setting
that defaults to `builtin` for the DLLs Wine implements — which includes **`d3d11`**, **`dxgi`** and
**`d3dcompiler_47`**.

A mod stack that ships a file called `d3d11.dll` therefore has to beat Wine's builtin. Historically
that meant a manual override:

```
d3d11 = native,builtin      (n,b)
dxgi  = native,builtin
d3dcompiler_47 = native,builtin
```

### The Wine bug behind it

**WineHQ bug 43727** — *"native dlls exists in the same exe directory wont first load before builtin
same name dlls"*: a native DLL sitting in the application directory is **not** preferred over
Wine's builtin of the same name, unlike on Windows where the application directory comes first in
the search order. This is the bug the modding ecosystem has been papering over with `native,builtin`
overrides for years. `[confidence: high]`

### How it manifests in XXMI specifically

XXMI issue **#51** (*"d3d11.dll is missing expected entry point"*) — the maintainer's own diagnosis:

> "Well, it may happen only if your OS serves **wrong DLL** (i.e. **real d3d11.dll**) via
> `LoadLibraryExW`."

That is the collision in one sentence: the injector asks the OS to load
`<…>/EFMI/d3d11.dll` **by full path**, and the loader hands back a module *named* `d3d11.dll` that
is not 3DMigoto's (Wine's builtin, or another already-loaded d3d11), so the entry-point check fails
and the launcher reports error `300`. The direct-inject path (`LoadLibraryW` inside the game
process) is exposed to the same collision.

**Wine 11.6's modding fix is exactly the upstream response to this class of problem.**

## 2. The upstream fix — Wine 11.6 (2026-03-27)

```
commit a31ec8da9572672e04ae46792a398da942649875
Author: Alexandre Julliard
Date:   Fri, 27 Mar 2026
Subject: ntdll: Add heuristics to prefer native dll based on the version resource.

    For now checking that CompanyName isn't "Microsoft".

 dlls/ntdll/unix/loader.c       |   7 +-
 dlls/ntdll/unix/loadorder.c    | 116 +++++++++++++++++++++++++++++++--
 dlls/ntdll/unix/unix_private.h |   2 +-
```

**What it does** (from the patch text):

- `get_load_order()` gains two new parameters: the PE image's **version resource** and its length.
  The callers (`load_builtin`, `load_so_dll`, `load_main_exe`) pass the version resource that
  `pe_mapping` already carries.
- A new `prefer_native_heuristics()` walks the version resource structure
  (`VS_FIXEDFILEINFO` → `StringFileInfo` → first child (usually `040904B0`) → `CompanyName`),
  and returns *prefer native* when:
  - the resource has a valid `VS_FIXEDFILEINFO` signature, **and**
  - the `CompanyName` string does **not** start with `Microsoft`.
- When it triggers, the effective load order becomes **`LO_NATIVE_BUILTIN`** (`native,builtin`)
  for that module, exactly as if the user had set an override — but only for *explicit paths*
  (the same branch that already handled "main exe with an explicit path").

```c
    /* now some heuristics for explicit paths */
    if (basename != module + 1)
    {
        if (!main_exe_loaded)  /* if loading the main exe, try native first */
        {
            ret = LO_NATIVE_BUILTIN;
            goto done;
        }
        if (prefer_native_heuristics( nt_name, version_res, version_len ))
        {
            ret = LO_NATIVE_BUILTIN;
            goto done;
        }
    }
```

**Why this is interesting for us:** XXMI's `d3d11.dll` and `d3dcompiler_47.dll` are exactly
"custom DLLs whose company is not Microsoft". With this patch, Wine prefers the mod's file over its
own builtin **automatically**, which is precisely the class of manual override that the Mac/Windows
XXMI users have to do by hand today (and which upstream community reports say stopped being needed
for several mod loaders after Wine 11.6).

### ⚠️ Version availability — the gap we sit in

| Runtime | Wine base | Has the 11.6 heuristic? |
|---|---|---|
| **CrossOver 26.2** (our `CrossOver_Endfield_Patch.app`) | Wine **11.0** | ❌ no |
| **dwproton 11.0-13** (wine-dwproton, `dwproton/11.0-13`) | Wine **11.0** (`VERSION` = `Wine version 11.0`) | ❌ no |
| dwproton `base` branch (what the `dwproton` clone's submodule points at) | Wine **9.0** | ❌ no |
| Wine 11.6+ | Wine **11.6** | ✅ yes |

`[confidence: high]` — verified directly: our repo's README states the 26.2 ABI is Wine 11.0; the
wine-dwproton clone's `VERSION` files were read; the commit date is 2026-03-27 (after Wine 11.0).

### ⚠️ What the heuristic does *not* fix

It only changes **load order** for modules being loaded normally. It does **not** make
`CreateRemoteThread`+`LoadLibraryW` of an arbitrary path behave differently, and it does not resolve
the "same base name already loaded" question. So it helps the **proxy-style** modding path (mod DLL
placed where the game will load it) much more than the **late-injection** path. See
[06](06-experiment-plan.md) for which experiments distinguish these.

## 3. What a `native,builtin` override actually does

`WINEDLLOVERRIDES="d3d11=n,b"` (or a registry entry under
`HKCU\Software\Wine\AppDefaults\<app>\DllOverrides`) tells Wine: for `d3d11.dll`, try a **native**
file first, fall back to builtin. That is the standard, documented mechanism, and it is exactly what
the known-good XXMI-on-macOS report used:

> **XXMI issue #117 (CrossOver 25.0.0, M-series Mac):** *"set dll overrides: `d3d11`,`d3dcompiler_47` = `n,b` — delete nvapi"*
> … the reporter got mods loading (with known cosmetic gaps: some faces, outlines, JPG/PNG textures).
> The maintainer's reply: *"Mac is not a target platform, and will never be one."*

`[confidence: medium-high]` — this is a working recipe on **CrossOver 25**, reported by a user; we
have not reproduced it on our 26.2 build yet.

**Two caveats that matter specifically for our build:**

1. **An override can fight the CrossOver graphics backend.** In our bottle, `system32/d3d11.dll` is
   the stock **wined3d** DLL (hash-identical to CrossOver's copy), and D3DMetal is engaged
   *per-process* by `cxcompatdb.so`, not by the file in `system32`. Forcing `d3d11=native` changes
   which file wins and can therefore change which backend the game actually gets. See
   [03](03-crossover-backend-landscape.md) — and the parent docs' warning (docs/13) that overwriting
   the D3D DLLs with the `apple_gptk` copies breaks `unityplayer.dll` init (error 1114).
2. **`d3dcompiler_47` is the safe one.** The game already ships its own native
   `d3dcompiler_47.dll` (4.5 MB) next to `Endfield.exe`, and XXMI ships another. Nothing in our ACE
   or backend stack depends on Wine's builtin compiler, so `d3dcompiler_47=native,builtin` is the
   lowest-risk, highest-value override (it is exactly what fixes the Linux flat-mesh issue #325).

## 4. Note on injection + `CreateRemoteThread` under Wine

`VirtualAllocEx`/`WriteProcessMemory`/`CreateRemoteThread`/`LoadLibraryW` are all implemented in
Wine, and injection between two processes in the **same prefix** is known to work — this is how
whole families of Windows mod tools are used under Proton. The failure modes are narrower than
"injectors don't work on Wine":

- **32-bit ↔ 64-bit mismatch** (WoW64) — not our case, Endfield is x64 and the bottle is win64.
- **Anti-cheat blocking the thread / the module** — an ACE problem, not a loader problem.
- **Module-name collision with a builtin** — the #51 symptom above.
- **Injection racing ahead of the game's own d3d11 load** — the documented "Start method = Shell"
  workaround.

`[confidence: medium]` — the mechanics are standard, but the *specific* failure mode we will hit is
unmeasured until we run experiment E1 in [06](06-experiment-plan.md).