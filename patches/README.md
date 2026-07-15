# patches/

The Wine patches that make Arknights: Endfield run on Apple Silicon macOS. All are applied to CrossOver 26.2's Wine 11.0 source. Full story: [../docs/13-working-solution.md](../docs/13-working-solution.md).

```
STAGE 1  EndfieldBase.dll (VMProtect/TenProtect "tpshell") faults on a plain 0F 1F NOP that Rosetta 2
         wrongly rejects → execute-fault loop at 0x6CD268 → stack overflow.   ✅ FIXED (stage1-macos)
STAGE 2  ACE init: missing ntoskrnl exports + KiUser*Dispatcher detection + timing + a privileged
         CR3 read Rosetta mis-reports.                                        ✅ FIXED (dwproton + stage1-macos)
```

## `stage1-macos/` — our two macOS/Rosetta-2 fixes (+ a build fix)

Original to this project. Both live in `dlls/ntdll/unix/signal_x86_64.c` (`segv_handler`, `TRAP_x86_PRIVINFLT`):

- `0001-macos-rosetta-signal-fixes-nop-and-privinstr.patch`
  - **`0F 1F` NOP skip** — Rosetta raises an illegal-instruction fault on the multi-byte NOP VMProtect emits pervasively; CrossOver's `handle_cet_nop` handled `0F 1E` but not `0F 1F`. We decode the NOP length and advance past it. *Cleared stage 1.* ([../docs/12-stage1-protector-fault.md](../docs/12-stage1-protector-fault.md))
  - **Privileged-instruction fix** — Rosetta reports `mov reg,cr3` (ACE-BASE.sys's anti-VM CR3 read) as invalid-opcode instead of `#GP`, so Wine handed ACE `EXCEPTION_ILLEGAL_INSTRUCTION` where Linux gives `EXCEPTION_PRIV_INSTRUCTION`; we call Wine's existing `is_privileged_instr()` on the Rosetta path and deliver the right code. *Cleared ACE "driver error 13."* ([../docs/13-working-solution.md](../docs/13-working-solution.md))
  - Contains an optional `CWC-ILLEGAL-INSTR` debug `ERR` line (harmless; remove for production).
- `0000-build-fix-win32u-vulkan-soname-fallback.patch` — lets the minimal (no-vulkan) build compile.

## `stage2-dwproton/` — the ported dw-proton anti-cheat patches

The Endfield-relevant subset of dw-proton's fix commit `b816be489`, from the `dawn-winery/dwproton-mirror` (fetched by [`../scripts/fetch-dwproton-patches.sh`](../scripts/fetch-dwproton-patches.sh)). Analysis: [../docs/02-dwproton-ace-patches.md](../docs/02-dwproton-ace-patches.md).

- `misc/0009…` — int3-stub `GetProcAddress` spoof of `KiUserApcDispatcher`/`KiUserCallbackDispatcher` (`/* workaround for tpshell */`; fired 2× in the working run).
- `misc/0010…` — gates the int3 hack to `Endfield.exe` / `EM-Win64-Shipping.exe`.
- `misc/0011…` — `NtDelayExecution` relative-wait via QueryPerformanceCounter (ACE is timing-sensitive).
- `misc/0008…` — wintrust winex11/winewayland bypass. **macOS-irrelevant** (targets `winex11.drv`); applies cleanly, does nothing on `winemac.drv`; kept for completeness.
- `em-backports/0001-0017…` — the `ntoskrnl.exe` functions ACE calls (`KeAcquireGuardedMutex`, `PsGetProcessImageFileName`, `MmGetPhysicalMemoryRanges`, …). `0010` (`PsGetProcessImageFileName`) is the exact WineHQ-bug-59411 Linux blocker.

Known residual: ACE also calls `ntoskrnl.exe.PsGetProcessExitStatus`, which is **not** in this set (dw-proton's maintainer found that abort "not really related"); one background ACE thread aborts on it, but the game reaches login regardless. A stub would silence it.

## Applying

All 23 patches are unified diffs and apply cleanly with `git apply` in this order: `em-backports/*` (numeric) → `misc/*` (numeric) → `stage1-macos/0000` → `stage1-macos/0001`. This is automated by [`../scripts/build-wine.sh apply`](../scripts/build-wine.sh). Expect to rebase if CrossOver's Wine base changes (the dw-proton set targets the `b816be489` snapshot; the latest lives baked into `dawn.wine/dawn-winery/wine-dwproton` branch `base`).

## License / provenance

These patches modify **Wine** (https://www.winehq.org/), which is **LGPL-2.1-or-later**. As derivative works of LGPL code, **all patches here are LGPL-2.1-or-later** — the project's top-level MIT license (which covers `scripts/` and `docs/`) does **not** apply to this directory.

- `stage2-dwproton/*` are from the **dw-proton / Dawn Winery** project and retain their upstream authorship: Etaash Mathamsetty (em-backports, NtDelayExecution), Ziia Shi / mkrsym1 (int3 spoof), NelloKudo (gating), and other dw-proton contributors. They are redistributed here under LGPL-2.1 with attribution.
- `stage1-macos/*` are authored by this project, but as modifications to Wine's `signal_x86_64.c` / `win32u` they are likewise **LGPL-2.1-or-later**.

This directory does not contain Wine itself — only diffs to be applied to a Wine source tree you fetch separately.
