# Mod injection research — XXMI Launcher / EFMI on the patched CrossOver build

> **Status of this sub-package:** research only. **No source-code changes have been made or are
> planned yet.** The base game is already known to work: it launches, passes ACE, and renders
> through D3DMetal inside the bottle `Arknights Endfield` using the patched app
> `/Applications/CrossOver_Endfield_Patch.app` (CrossOver 26.2 base, Wine 11.0).
>
> This folder answers two questions:
>
> 1. **Does dwproton (or anything else upstream) already have patches for XXMI / EFMI mod
>    injection?** → No. See [04-dwproton-and-related-patches.md](04-dwproton-and-related-patches.md).
> 2. **How does the mod manager actually load mods, and what would we need to change in our
>    CrossOver context?** → See [01](01-xxmi-efmi-mod-loading.md), [02](02-wine-dll-loading-and-mod-dlls.md),
>    [03](03-crossover-backend-landscape.md) and [06](06-experiment-plan.md).

## What works today (the baseline this research builds on)

| Component | State |
|---|---|
| Patched CrossOver app (`CrossOver_Endfield_Patch.app`, v26.2) | ✅ working, built by `scripts/swap-into-crossover.sh` |
| Bottle `Arknights Endfield` (win64) | ✅ game runs, DX11 mode, `CX_GRAPHICS_BACKEND = d3dmetal` |
| ACE anti-cheat | ✅ passes (stage-1 Rosetta fixes + dw-proton stage-2 patches) |
| XXMI Launcher + EFMI | ❌ **not installed in the bottle at all** (verified 2026-09-20) — nothing has actually been attempted yet |

## Documents

| Doc | What it covers |
|---|---|
| [01-xxmi-efmi-mod-loading.md](01-xxmi-efmi-mod-loading.md) | ⭐ How XXMI Launcher and EFMI actually get mods into the game: package layout, the two injection methods, the exact `CreateRemoteThread`/`LoadLibraryW` path, `-force-d3d11`, `Mods/`, `d3dx.ini`. |
| [02-wine-dll-loading-and-mod-dlls.md](02-wine-dll-loading-and-mod-dlls.md) | Why this fails under Wine in general: builtin vs native load order, WineHQ bug 43727, the upstream Wine 11.6 fix (full patch reproduced), and what `d3d11=n,b`-style overrides really do. |
| [03-crossover-backend-landscape.md](03-crossover-backend-landscape.md) | The four D3D11 implementations that exist inside CrossOver 26.x, how `cxcompatdb.so` picks one per process, what the bottle actually contains (hash-verified), and why D3DMetal is the odd one out for a hooking framework. |
| [04-dwproton-and-related-patches.md](04-dwproton-and-related-patches.md) | The dwproton answer: no EFMI patches, but an OptiScaler DLL-load redirect hack; Proton-CachyOS' OptiScaler integration; and the Wine 11.6 upstream fix that post-dates both dwproton 11.0-13 and CrossOver 26.2. |
| [05-known-issues-and-references.md](05-known-issues-and-references.md) | Every issue / forum thread / commit found so far, with what each one *proves*, and the source inventory. |
| [06-experiment-plan.md](06-experiment-plan.md) | The ordered, cheapest-first experiment ladder to prove or kill each hypothesis — **no code changes, only runtime/config-level experiments**. |
| [07-load-ordering-and-chaining.md](07-load-ordering-and-chaining.md) | ⭐ **The layering answer:** how Wine 11.0 actually resolves bare-name vs full-path DLL loads, why 3DMigoto's chain silently ends at wined3d instead of Metal in *every* CrossOver backend, and how `[System] proxy_d3d11` forces the ordering "mod first, CrossOver mapping second" — a `d3dx.ini` change, no Wine patch. |
| [08-patcher-integration-plan.md](08-patcher-integration-plan.md) | ⭐ **Plan → implemented (2026-09-21):** how the chain fix is wired into `scripts/swap-into-crossover.sh` (optional step 7, **flags or env vars** — `--mod-chain` / `--mod-chain-revert` etc.) and `patcher-app/` (a second, bottle-side phase + UI, `ModChain.swift`), with detection, the exact `d3dx.ini` edit rules, idempotency/revert/re-apply after EFMI updates, licensing guardrails, rejected alternatives and acceptance criteria. Standing assumption: the XXMI fork honours `[System] proxy_d3d11` (verify via experiment L3). |

## Conventions

Same conventions as the parent `docs/` package: confidence is tagged inline as
`[confidence: high/medium/low]`, and `⚠️ macOS unknown` marks claims where all primary evidence is
Linux/Proton and the macOS behaviour is inferred rather than measured.

## Legal / ethical note

Modding work here is **cosmetic model-import tooling** (3DMigoto / EFMI family) of the same
compatibility-research nature as the rest of this repository: it modifies rendering at runtime, does
not alter game logic or grant an advantage, and does not circumvent DRM. Whether to run mods in an
online game, and the ToS/ban risk of doing so, is the user's decision — see the repository README's
"scope, legality, ethics" section. Nothing in this sub-package recommends defeating anti-cheat.