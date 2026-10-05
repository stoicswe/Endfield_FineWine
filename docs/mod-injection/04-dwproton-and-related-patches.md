# 04 — dwproton: what it has, what it doesn't, and what is reusable

> **Sources:** the local clone `~/Github-Thirdparties/dwproton` (git `96594ff2`,
> dwproton-11.0-13) plus a full blob-less clone of the Wine submodule
> `https://dawn.wine/dawn-winery/wine-dwproton.git` used to search **all** refs
> (`base`, `dwproton/11.0-*`, `_cachy`, `_dw`, `_staging`, `_em`, `_valve`, …). Proton-CachyOS
> release notes and GamingOnLinux coverage for the OptiScaler integration.
> `[overall confidence: high]`

## 1. Direct answer: dwproton has **no** XXMI / EFMI / 3DMigoto patches

Searches performed (2026-09-20):

- `git grep` over the dwproton working tree: **0 hits** for `xxmi|efmi|3dmigoto|gimi`.
- `git log --all --grep` across every ref for `xxmi`, `efmi`, `3dmigoto`, `migoto`, `mod loader`:
  only unrelated upstream Wine commits (`d3dx9`/`d3dx10`/`d3dx11` work, `nsiproxy`, etc.).
- `git ls-tree -r --name-only` over `base`, `origin/dwproton/11.0-13`, `origin/_cachy`: **0 files**
  matching `xxmi|efmi|3dmigoto|migoto`.
- Same searches inside the **wine-dwproton** submodule repo (all branches incl. `dwproton/11.0-13`,
  `base`): **0 hits**.

The ACE patches dwproton *does* carry (and which this repository ports in
`patches/stage2-dwproton/`) are anti-cheat **launch** patches, not mod-loading patches — they
implement `ntoskrnl.exe` exports and spoof dispatcher probes. Nothing in them concerns DLL
injection or mod loaders. `[confidence: high]`

## 2. What dwproton *does* have in this space: the OptiScaler injection hack

Two commits, both by Stelios Tsampas (loathingkernel), present in `dwproton/11.0-13` and `_cachy`:

### 2a. `ntdll`: `HACK: ntdll: add optiscaler injection hack`

In `dlls/ntdll/loader.c`, a new `load_dll_optiscaler_hack()` is consulted from `load_dll()`:

```c
static NTSTATUS load_dll( const WCHAR *load_path, const WCHAR *libname, DWORD flags, ... )
{
    ...
    if (nts)
    {
        if ( (do_override = load_dll_optiscaler_hack(libname, override, ARRAY_SIZE(override))) )
            FIXME ( "HACK: redirecting %s to %s\n", debugstr_w(override), debugstr_w(override) );
        nts = find_dll_file( load_path, do_override ? override : libname, &nt_name, ... );
        system = FALSE;
    }
```

Mechanics:

- reads env var **`WINE_OPTISCALER_NAME`** once (cached), e.g. `dxgi.dll`;
- when the process tries to load that name **without an explicit path** (i.e. it fell through to
  "DLL not found" resolution), Wine substitutes the path
  **`\??\c:\windows\system32\umu\<name>`**;
- it verifies the substituted file actually opens (`NtOpenFile`) before committing, caching the
  success so the real DLL can still be reached by fully-qualified path.

### 2b. `kernelbase`: `HACK: kernelbase: add WINE_OPTISCALER_NAME to load optiscaler's dll from an external location`

In `dlls/kernelbase/loader.c`, `LoadLibraryExW` gets the same treatment:

```c
    if ( loaddll_optiscaler_hack(name, overrideW, ARRAY_SIZE(overrideW))
        || loaddll_upscaler_hack(name, overrideW, ARRAY_SIZE(overrideW)) )
        FIXME( "HACK: replacing %s with %s\n", ... );
    RtlInitUnicodeString( &str, overrideW[0] ? overrideW : name );
```

with the commit message noting: *"The matching intentionally matches `name.dll` exactly to allow
optiscaler to load the real dll through the fully qualified path."*

There is also a **`WINE_UPSCALER_REPLACE`** hack (FSR3/`amd_fidelityfx_*` relocation) alongside it,
and a commit removing an older `loaddll_optiscaler_hack` from `LoadLibraryExW` — i.e. this is
actively maintained plumbing, not a one-off.

### 2c. Why this matters to us

This is a **generic-capability mechanism wearing an OptiScaler name**: "when a process asks for
DLL *X* by bare name, serve it from a controlled directory instead." That is a **superset** of what
a mod loader needs (it is a *redirect*, not an injection), and it shows the upstream Proton
community's accepted shape for the problem:

- an env var names the DLL,
- a well-known directory holds the substitute,
- the real one remains reachable by full path (which is what lets a proxy chain to the original).

### 2d. Provenance and upstreaming

This did not originate in dwproton alone — it is part of the **Proton-CachyOS 11 / umu-protonfixes**
OptiScaler integration:

- Proton-CachyOS 11.0-20260506 *"added basic integration of OptiScaler into umu-protonfixes … using
  environment variables as launch options for games it allows you to inject specific DLLs"*.
- Proton-CachyOS 11.0-20260702 then removed the need to manually provide `amdxcffx64.dll`, and
  notes that *"when using the OptiScaler integration, `PROTON_FSR4_UPGRADE` will accept more
  versions … and it will control the version of the respective FidelityFX SDK dlls"*.
- dwproton rebases those Protonfixes ("protonfixes: Rebase game patches to upstream
  umu-protonfixes", `b85c6cda`) — so the mechanism rides upstream, and **dwproton's own changelogs
  contain no mod-loader entries** (searched `CHANGELOGS.md`: no `xxmi/efmi/3dmigoto/mod`).

## 3. The upstream Wine fix that dwproton *also* lacks

**Wine 11.6** (commit `a31ec8da…`, 2026-03-27, Alexandre Julliard) added
*"ntdll: Add heuristics to prefer native dll based on the version resource"* — for now, prefer
`native` when the PE's `CompanyName` isn't `Microsoft`.

- dwproton **11.0-13** is Wine **11.0** (`VERSION` = `Wine version 11.0`) → does **not** have it.
- the `wine-dwproton` **base** branch the clone's submodule points at is Wine **9.0** → does not.
- CrossOver **26.2** is Wine **11.0** → does not have it either.

Full patch text and analysis: [02-wine-dll-loading-and-mod-dlls.md](02-wine-dll-loading-and-mod-dlls.md) §2.

**Net:** on the Linux side, gacha modding under dwproton works because users do the manual
`native,builtin` overrides (or the DXVK `d3d11` is already what the game loads). There is no
EFMI-specific help to borrow from dwproton — the borrowable ideas are (a) the Wine 11.6 heuristic
and (b) the OptiScaler-style redirect.

## 4. Other Linux-side mod-injection infrastructure worth knowing about

These are Proton/Wine tools that exist because "inject a DLL into a Wine game process" is a real,
solved-but-fiddly problem:

| Project | What it is | Relevance |
|---|---|---|
| **`jokelbaf/proton-injector`** | "A DLL injector for Windows executables running under Proton/Wine on Linux. Supports both 32-bit and 64-bit targets, multiple injection methods." | Evidence that Wine-side injection is a solved, general problem; a reference implementation if we ever need an *out-of-process* injector. |
| **`wowitsjack/choochoo-loader`** | "Trainer/Cheat loader for Proton … DLL Injection Support — some patches, mods, or debuggers need to inject DLLs into the game process, **which can fail in WINE without proper handling**." | Explicitly names the failure class; worth reading for its handling notes if our `Inject` path fails. |
| **`Mac-Andreas/omp-wine-injector`** | Ports upstream's exact `CreateRemoteThread` injection into a small Windows `.exe` run **inside** the bottle via `cxstart`, so "the injection path matches official open.mp 1:1 … just executed from within Wine instead of from a native Windows host." | ⭐ The closest architectural precedent for our situation: **run the injector inside the Wine prefix rather than from outside**. XXMI already does this (it is a Windows app), but this project documents the pattern explicitly. |
| **`optiscaler/OptiScaler`** | Proxy-DLL upscaler/mod framework; supported names `dxgi.dll, d3d12.dll, version.dll, winmm.dll, wininet.dll, dbghelp.dll`. | The other big "rename a DLL and hook D3D" family; its proxy-name list is a useful reference for which DLL names are *proxyable* vs *injectable*. |

## 5. Related-but-different Endfield tooling on the Mac side

- **`wakka810/3dmigoto-arknights-endfield`** — a standalone **3DMigoto loader for Endfield**
  (`loader.exe` + `d3dx.ini` + `loader.c`, "Enable Launch with DirectX 11"). Same 3DMigoto family
  as EFMI but **external-loader based** rather than XXMI-injector based. Relevant as a
  fallback/independent datapoint if the XXMI injection path proves Wine-hostile — a standalone
  loader that spawns the game suspended is structurally immune to the injection race.
- **`Kaiozen/Endfield-CrossOver-Patcher`** (built on this repository, credits Endfield_FineWine)
  — a one-click CrossOver 26.3+/Preview patcher for *the game*. It does **not** address mods; it is
  cited only to note that the non-mod path is being productised separately from this research.
- **`mary-ext/crossover-wine-endfield`** — patched Wine modules equivalent to ours for
  CrossOver-on-Apple-Silicon; no mod-loader content either.

## 6. Bottom line for the patch decision

| Option | Origin | Effort | Risk | Verdict for now |
|---|---|---|---|---|
| `d3dcompiler_47=native,builtin` override | standard Wine feature | none | none | **do first** (config only) |
| Wine 11.6 heuristic backport (`ntdll/unix/loadorder.c`) | upstream Wine | small, self-contained patch + 3-file touch | low; conservative upstream design | candidate stage-3 patch **if** E-experiments show override-less loading is needed |
| OptiScaler-style redirect adapted to a general `WINE_LOADDLL_REPLACE` | dwproton/Proton-CachyOS | medium | medium (re-introduces a general hook) | only if the proxy path is the chosen design |
| Nothing; rely on DXMT + overrides | — | none | none | **the default plan** |

Nothing in this section implies a code change today — the experiments in
[06](06-experiment-plan.md) decide whether any of the above is ever needed.