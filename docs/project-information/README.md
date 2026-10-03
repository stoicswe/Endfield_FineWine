# Endfield_FineWine documentation

**Arknights: Endfield** runs on Apple Silicon macOS under a custom-patched CrossOver Wine — past the VMProtect/TenProtect protector, past the **ACE (Anti-Cheat Expert)** anti-cheat, rendering through Apple's **D3DMetal**, into the login screen and gameplay. This folder holds the **user guides** and the **full engineering write-up** of how the fix was found. The [README](../README.md) is only the quick start — the details live here (and in the project wiki generated from these pages).

**Status (2026-09-23): ✅ working.** Verified on an Apple M4 Pro (24 GB, macOS 27.0, CrossOver 26.3.0), on M3 / macOS 26.5, and on a base M4 with 16 GB (playable, memory-limited — see [14](14-performance-on-16gb-macs.md)).

## User guides — start here to get the game running

| Doc | What it covers |
|---|---|
| [installation.md](installation.md) | Full requirements, building the patched Wine, deploying it into CrossOver (scripted + manual), creating the bottle, installing the game, running it, debug logging. |
| [graphics-performance.md](graphics-performance.md) | The DirectX-11 rule, backend selection (D3DMetal/DXMT/DXVK), and the optional GPTK4 upgrade. |
| [troubleshooting.md](troubleshooting.md) | Common failures and fixes (damaged bundle, white screen, error 1114, …). |
| [14-performance-on-16gb-macs.md](14-performance-on-16gb-macs.md) | Measured memory/CPU/GPU behaviour on a 16 GB M4, the memory-pressure freeze, settings that play well. |

## How it works — the solution

| Doc | What it covers |
|---|---|
| [13-working-solution.md](13-working-solution.md) | ✅ **Start here.** The two Rosetta fixes, the full patch set, the deploy, and the graphics/rpath lessons learned after it worked. |
| [10-milestone-1-results.md](10-milestone-1-results.md) | The real failure signature captured on stock CrossOver (the stage-1 protector loop) — the observation everything else was gated on. |
| [11-linux-vs-macos-comparison.md](11-linux-vs-macos-comparison.md) | The Linux-vs-macOS log comparison: why the dw-proton patches were necessary-but-not-sufficient, and the macOS-specific stage-1 fault. |
| [12-stage1-protector-fault.md](12-stage1-protector-fault.md) | The stage-1 `EndfieldBase.dll` fault: hypotheses, experiments, root cause (Rosetta rejects a plain NOP). ✅ solved. |

## Subsystem research — engineering reference

| Doc | What it covers |
|---|---|
| [01-ace-anticheat-and-endfield.md](01-ace-anticheat-and-endfield.md) | What ACE is, how Endfield ships it, and what makes it launch under Wine. |
| [02-dwproton-ace-patches.md](02-dwproton-ace-patches.md) | Patch-level inventory of the dw-proton fix: exact files, functions, code shape. |
| [03-crossover-wine-architecture.md](03-crossover-wine-architecture.md) | CrossOver's Wine on macOS: `win32on64`, Rosetta 2, the arm64 transition, bundle layout. |
| [04-building-crossover-wine.md](04-building-crossover-wine.md) | Toolchain, dependencies, `./configure` flags, building CrossOver's Wine from source. |
| [05-swapping-into-crossover.md](05-swapping-into-crossover.md) | Getting a custom Wine into `CrossOver.app`: CXPatcher's mechanism, swapping, code-signing, SIP, quarantine. |
| [06-graphics-and-gptk.md](06-graphics-and-gptk.md) | GPTK4 / D3DMetal / DXMT / DXVK, Endfield's engine and renderers, backend keys. |
| [07-rosetta-and-windows-spoofing.md](07-rosetta-and-windows-spoofing.md) | Rosetta 2's detection surface and every Wine-hiding / OS-spoofing lever. |

## Project history — research-phase archive

Written during the research/planning phase; kept as the record of how the project was de-risked. Several claims are superseded by [13](13-working-solution.md).

| Doc | What it covers |
|---|---|
| [00-EXECUTIVE-SUMMARY.md](00-EXECUTIVE-SUMMARY.md) | The pre-work summary: the blocker, the Linux fix, the macOS obstacles, the go/no-go framework. ⚠️ Superseded — e.g. it says Unreal Engine 5; the engine is **Unity IL2CPP**. |
| [08-risks-unknowns-open-questions.md](08-risks-unknowns-open-questions.md) | The ranked risk register and the contradictions between sources (top risks since resolved). |
| [09-implementation-roadmap.md](09-implementation-roadmap.md) | The ordered, de-risking milestone plan with concrete commands (milestones 0–1 done; see 10/13 for the rest). |

## Reference

- [references.md](references.md) — consolidated, deduplicated source list.
- The other components (not in `docs/`, each with its own README): **[patches/](../patches/README.md)** — the Wine patch inventory + licensing (LGPL, dw-proton provenance) · **[scripts/](../scripts/README.md)** — the build/swap/bottle/launch/capture scripts · **[patcher-app/](../patcher-app/README.md)** — the FineWine Patcher.app GUI (SwiftPM) · **[.github/workflows/](../.github)** — Wine CI builds, nightly, and the wiki generator.

### Research sub-packages

| Sub-package | What it covers |
|---|---|
| [../mod-injection/](../mod-injection/README.md) | ⭐ **Modding research (2026-09-20):** how XXMI Launcher / EFMI loads mods, whether dwproton has patches for it (no), Wine's builtin-vs-native DLL loading and the upstream Wine 11.6 fix, CrossOver's four D3D11 backends, and a documentation-only experiment plan for getting EFMI working in the `Arknights Endfield` bottle. |

## Conventions used in these docs

- **Confidence** is tagged inline as `[confidence: high/medium/low]` on the claims where it matters.
- **⚠️ VERIFIER CAUTION** marks a place where the adversarial fact-check downgraded, corrected, or refuted the original research finding. Do not skip these — several are load-bearing.
- **macOS-specific unknowns** are called out explicitly, because nearly all primary evidence is from **Linux/Proton**, and Linux→macOS portability was the central risk of the project.
- Docs numbered `00`–`09` were written during the research/planning phase; `10`–`14` track implementation results. The unnumbered pages (`installation.md`, `graphics-performance.md`, `troubleshooting.md`) are the user-facing guides.