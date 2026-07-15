# Running Arknights: Endfield on macOS via a patched CrossOver Wine

**Project goal.** Make *Arknights: Endfield* — a game the user legally owns — **launch and run on Apple Silicon macOS** by building a custom, patched CrossOver Wine that satisfies the game's **ACE (Anti-Cheat Expert)** anti-cheat, the same way the **dw-proton / GE-Proton** projects made the identical game run on Linux. This is compatibility engineering (getting an unsupported game to boot on unsupported hardware), **not** cheating in the game and **not** DRM circumvention: none of the work here alters gameplay, grants an in-game advantage, or bypasses purchase/licensing.

**Status: research + planning complete. No code written yet.** This `docs/` folder is a hand-off package. It is written so that a future model (Opus / Sonnet) or engineer can pick up implementation without re-doing the investigation. Every load-bearing claim was fetched from primary sources (the dw-proton repo, GE-Proton issue #433, CodeWeavers docs, CXPatcher source, Apple GPTK docs, Wine source) and then **adversarially fact-checked**; confidence levels and the fact-checker's corrections are preserved in each document.

---

## Current status (2026-07-14) — ✅✅ IT WORKS: Endfield reaches the login screen

**Arknights: Endfield runs on Apple Silicon macOS under a custom-patched CrossOver Wine — past the protector, past ACE, rendering through D3DMetal, to the login screen.** Full write-up: **[13-working-solution.md](13-working-solution.md)**.

Two novel **Rosetta 2** fixes (both in `signal_x86_64.c`) plus the ported dw-proton patches:
- **Rosetta faults on a plain `0F 1F` NOP** (VMProtect emits 100k+/launch) → skip it. Cleared the protector; ACE loads.
- **Rosetta mis-reports `mov cr3` as invalid-opcode instead of `#GP`** → deliver `EXCEPTION_PRIV_INSTRUCTION` like Linux. Cleared ACE's driver-error-13.
- dw-proton set (17 ntoskrnl em-backports + int3 hack + QPC timing) applied cleanly → cleared the ACE-init blockers.
- Deployed by [swapping the 3 patched modules into a copy of CrossOver.app](../scripts/swap-into-crossover.sh) so CrossOver provides D3DMetal graphics.

Endfield is **Unity IL2CPP** (not UE5, correcting [06](06-graphics-and-gptk.md)). Build platform (64-bit CrossOver Wine, standard toolchain, no `cx-llvm`): [scripts/](../scripts/). Patches: [patches/](../patches/).

## The one-paragraph summary

On Linux, dw-proton makes Endfield launch with a small set of Wine patches: a **`kernel32` `GetProcAddress` "int3 stub" hack** (spoofs `KiUserApcDispatcher` / `KiUserCallbackDispatcher` to defeat ACE's TenProtect/"tpshell" dispatcher hooking), a stack of **`ntoskrnl.exe` kernel-function implementations** ("em-backports") that ACE calls and stock Wine lacks, and a **`NtDelayExecution` reimplementation using QueryPerformanceCounter** because ACE is timing-sensitive. Porting this to macOS is *theoretically* possible but faces four hard obstacles, in rough order of how likely each is to kill the project: (1) ACE may run a check on macOS that no user-space patch can satisfy — CodeWeavers observed ACE **force-quitting** Endfield after one launcher frame, which may be categorical rather than a fixable missing-function abort; (2) the int3 hack is guarded by `#ifdef __x86_64__`, so it only exists in an **x86_64 Wine under Rosetta 2**, not a native arm64 build — and CrossOver is actively moving *toward* native arm64; (3) building CrossOver's `win32on64` Wine requires **CodeWeavers' patched clang/LLVM**, whose sources may have been removed from CrossOver tarballs after v20.0.1; (4) ACE is timing-sensitive and the QPC busy-wait was validated only on Linux x86_64, so Rosetta 2 translation may perturb it. The recommended path front-loads the cheapest, most decisive experiments (capture the *actual* failure on stock CrossOver; try the free user-space spoofs before compiling anything) so the project is proven or killed before large effort is spent.

---

## How to read this package

Read in order if you're new; jump by subsystem if you're implementing.

| Doc | What it covers |
|---|---|
| [00-EXECUTIVE-SUMMARY.md](00-EXECUTIVE-SUMMARY.md) | The whole picture in ~2 pages: the blocker, the Linux fix, the macOS obstacles, the go/no-go decision framework. **Start here.** |
| [01-ace-anticheat-and-endfield.md](01-ace-anticheat-and-endfield.md) | What ACE is, how it's built, how Endfield ships it, and precisely what makes it launch under Wine. |
| [02-dwproton-ace-patches.md](02-dwproton-ace-patches.md) | Patch-level inventory of the dw-proton fixes: exact files, functions, code shape, and which are architecture-specific. **The core of the port.** |
| [03-crossover-wine-architecture.md](03-crossover-wine-architecture.md) | CrossOver's Wine on macOS: `win32on64`, Rosetta 2, the arm64 transition, and the app-bundle layout you'll be editing. |
| [04-building-crossover-wine.md](04-building-crossover-wine.md) | Toolchain, dependencies, `./configure` flags, and how to compile CrossOver's Wine from source. |
| [05-swapping-into-crossover.md](05-swapping-into-crossover.md) | Getting a custom Wine into `CrossOver.app`: CXPatcher's mechanism, binary swapping, code-signing, SIP, quarantine. |
| [06-graphics-and-gptk.md](06-graphics-and-gptk.md) | GPTK4 / D3DMetal / DXMT / DXVK, Endfield's engine and renderers, and how the launcher differs from the game. |
| [07-rosetta-and-windows-spoofing.md](07-rosetta-and-windows-spoofing.md) | Rosetta 2's detection surface, and every Wine-hiding / OS-spoofing lever (registry keys, ntdll exports, version tables). |
| [08-risks-unknowns-open-questions.md](08-risks-unknowns-open-questions.md) | The ranked risk register, the contradictions between sources, and the open questions that must be resolved. |
| [09-implementation-roadmap.md](09-implementation-roadmap.md) | The ordered, de-risking milestone plan with concrete commands. **The plan of record for the next session.** |
| [10-milestone-1-results.md](10-milestone-1-results.md) | ✅ **Milestone 1 done** — the real failure captured on M3/CrossOver: a VMProtect/TenProtect exception-dispatch loop in `EndfieldBase.dll`, before ACE loads. |
| [11-linux-vs-macos-comparison.md](11-linux-vs-macos-comparison.md) | ⭐ The log-sample comparison: the Linux failures dw-proton fixes are **later and different** from ours. **dw-proton is necessary-but-not-sufficient**; our blocker is a macOS-specific stage-1 fault. **Read this to understand the strategy.** |
| [12-stage1-protector-fault.md](12-stage1-protector-fault.md) | ⭐ **The critical path.** The unsolved macOS `0x6CD268` protector fault: three hypotheses (Rosetta / Wine-macOS exceptions / image base) and the ordered experiments to crack it. |
| [references.md](references.md) | Consolidated, deduplicated source list. |

## Conventions used in these docs

- **Confidence** is tagged inline as `[confidence: high/medium/low]` on the claims where it matters.
- **⚠️ VERIFIER CAUTION** marks a place where the adversarial fact-check downgraded, corrected, or refuted the original research finding. Do not skip these — several are load-bearing.
- **macOS-specific unknowns** are called out explicitly, because nearly all primary evidence is from **Linux/Proton**, and Linux→macOS portability is the central risk of the whole project.
