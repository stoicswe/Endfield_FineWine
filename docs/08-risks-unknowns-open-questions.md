# 08 — Risks, unknowns, and contradictions

> Source: cross-area gap analysis (senior-engineer synthesis over all 7 verified areas). This is the register a future implementer should re-read before committing effort at each milestone.

## Risk ranking (most likely to kill the project first)

**1. ACE runs a macOS check no user-space Wine patch can satisfy.** `[the existential risk — DOWNGRADED by milestone 1]`
The live build may hard-require kernel-driver telemetry, or fingerprint the Rosetta environment (`VirtualApple` CPUID brand string, missing AVX-512, timing) and — unlike the (unproven) Steam Deck case — **not** tolerate it. CodeWeavers observed ACE **force-quitting** Endfield on CrossOver 25.1.1 after one launcher frame.
- ✅ **Milestone 1 evidence ([docs/10](10-milestone-1-results.md)) downgrades this.** The actual failure captured on M3/CrossOver 26/27 is **not** a categorical force-quit and **not** a missing-function abort — it's an **exception-dispatch loop in `EndfieldBase.dll`'s VMProtect/TenProtect anti-tamper** (repeated execute-`c0000005` → colliding unwind → stack overflow), before ACE even loads. That is a **user-space-fixable class**, on the dw-proton path. The existential risk isn't eliminated (the faithful launcher path + later ACE stages are untested — milestone 1b), but the first, decisive observation points to "fixable protector-compat" rather than "kernel wall."

**2. The Linux fixes don't port to CrossOver's Wine.**
The int3 hack is `#ifdef __x86_64__` (only an x86_64 build), and the em-backports/int3 patches target upstream/Proton Wine, not CrossOver's `winecx` + `win32on64` fork. Rebase conflicts, the arm64 transition, or 64-bit-bottle-only CrossOver 27 could make the fix non-buildable on a *supported* CrossOver.
- ✅ **Mitigant:** the DIY FOSS build ([04](04-building-crossover-wine.md)) produces an **x86_64 Wine under Rosetta 2** — exactly where the `#ifdef __x86_64__` hack *does* compile. So on today's x86_64 CrossOver base the arch guard is satisfied. The risk is future-facing (native arm64) and rebase-conflict-facing (winecx vs Proton).

**3. Build-toolchain unavailability.**
`win32on64` requires CodeWeavers' patched clang/LLVM. The `gcenx/wine/cx-llvm` bottle is reported unavailable (GabLeRoux issue #51, May 2025), and LLVM/Clang sources may have been trimmed from CrossOver tarballs after v20.0.1 (⚠️ this specific claim is **UNVERIFIABLE** but plausible). If you cannot compile a modified CrossOver Wine at all, nothing ships. → **Resolved by roadmap milestone 4.**

**4. Rosetta 2 timing / sync mismatch.**
ACE is explicitly **timing-sensitive**; the QPC busy-wait `NtDelayExecution` reimplementation and MSync were validated only on Linux x86_64. Under x86_64→arm64 translation, timing may diverge enough that ACE fails even with the kernel functions present.

**5. macOS code-signing / hardened runtime / library validation** blocks the swapped or re-signed Wine binaries from loading on current macOS. Surmountable but unproven end-to-end for a custom-Wine-swapped CrossOver. → **Resolved by roadmap milestone 4.**

**6. Graphics (lowest — downstream of "launch").**
Endfield defaults to Vulkan; D3DMetal's DX12 path has high CPU sync overhead. Even after ACE is satisfied the game may be unplayable — but this does **not** threaten the stated goal of making it *launch*.

## Contradictions between sources (resolve before relying on either side)

1. **How (or whether) dw-proton hides Wine from ACE. — RESOLVED.** The current-tree pass ([02](02-dwproton-ace-patches.md)) settled it: dw-proton's *only* detection-evasion patch was a **wintrust signature-check bypass** (hiding `winex11`/`winewayland` from ACE), which was **real historically but has been removed**, and is **macOS-irrelevant** (targets `winex11.drv`, not `winemac.drv`). dw-proton does **no** `wine_get_version`/registry hiding. Conclusion: on Linux, ACE tolerates Wine's fingerprints; export/OS spoofing ([07](07-rosetta-and-windows-spoofing.md)) is a *try-it* lever for macOS (milestone 2), **not a known requirement**.

2. **Is `ntoskrnl.exe` actually the Endfield blocker?** `ace-internals` frames the em-backports set as the fix; the `rosetta-spoofing` verifier notes the only documented Endfield abort (#433) is `msimg32.dll.AlphaBlend`, no ntoskrnl name. **The two areas disagree on what aborts first.** → Milestone 1 observation decides this.

3. **"D3DMetal is the only D3D12 path"** — **REFUTED** by its own verifier: `vkd3d 1.18` also does D3D12→Vulkan→MoltenVK. And Endfield defaults to Vulkan anyway, so forcing DX11/DX12 may be unnecessary.

4. **"ACE tolerates Wine via a Steam Deck hardware allowlist"** vs. CodeWeavers observing ACE **force-quitting** Endfield on CrossOver. The allowlist claim is **UNVERIFIABLE** — do not rely on it.

5. **Architectural direction conflict.** The working fix needs an **x86_64** Wine (int3 `#ifdef __x86_64__`), yet CrossOver is moving to **native arm64** (dropping Rosetta ahead of ~macOS 28) and CrossOver 27 retires 32-bit bottles + Intel Macs. The platform trend undermines the compile path long-term — pin to an x86_64 CrossOver base for now.

6. **Patch layout drift — bigger than numbering.** dw-proton **deleted the `patches/wine/` folder entirely** (between releases `11.0-1` and `11.0-2`) and moved the Wine patches into a submodule fork (`dawn-winery/wine-dwproton`, branch `base`). Older paths/hashes (`0002-misc/0008-0011`, `0003-em-backports`, `c4dec62a…`) are all stale. The implementer must diff the `wine-dwproton` fork, not look for `patches/wine/`. → Use [02](02-dwproton-ace-patches.md)'s current-tree inventory.

## Open questions (must be answered before / during implementation)

- **The `dwproton-patches` area is the most implementation-critical** and is (re)captured in [02](02-dwproton-ace-patches.md) — verbatim diffs, current-tree paths, and the Wine base version of the 4 patches in `b816be489`.
- **Wine base version: dw-proton vs. CrossOver `winecx`.** Without both, you can't tell whether the patches apply cleanly, need rebasing, or collide with the `win32on64` patchset.
- **The exact Endfield failure signature on macOS/CrossOver** — never captured. (Milestone 1.)
- **Execution model:** does the ACE-relevant game process run as x86_64 (under Rosetta, int3 hack compiles) or would a native arm64 build be used (hack won't compile)? The int3 gate matches both `Endfield.exe` and the 64-bit `EM-Win64-Shipping.exe`. (Milestone 2.)
- **Is CrossOver's patched clang/LLVM still obtainable** for current versions? (Milestone 4 / risk 3.)
- **Which environment checks ACE actually runs on macOS** — no primary RE confirms `VirtualApple` / AVX / `Z:` / `HKCU\Software\Wine` / `wine_get_*` are read by Endfield's ACE. All Wine-hiding is inferred from Linux.
- **End-to-end code-signing** on Sequoia/Tahoe for a swapped-Wine CrossOver — untested. (Milestone 4.)
- **QPC busy-wait × MSync × Rosetta timing** interaction — unknown. (Milestone 7.)
- **WineHQ bug 59411** full text/call stack — unrecovered (Anubis anti-bot wall); only the title was obtained, dated 2026-02-26 (after the late-Jan patch work, so possibly a newer build).

## The honest bottom line
This is **theoretically possible but not yet proven viable.** Milestones 1–3 are cheap and decisive; do not compile anything until they've said "the blocker is a fixable missing-function abort, and the minimal patch set is X." If milestone 1 shows a categorical ACE force-quit, stop.
