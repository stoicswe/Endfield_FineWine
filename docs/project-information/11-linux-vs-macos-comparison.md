# 11 — Linux failure vs. our macOS failure: the log-sample comparison

> **This answers the key question: was there a log that prompted the dw-proton fix, and does that fix address OUR macOS crash?** Researched 2026-07-14 from primary sources (one agent solved WineHQ's anti-bot wall to recover the actual bug + attached log). **Verdict: the dw-proton patches are NECESSARY-BUT-NOT-SUFFICIENT — our macOS blocker is an earlier, macOS-specific failure that no public Linux report shows and that dw-proton does not fix.**

## Yes — the log samples that prompted the fix exist

| Source | The Linux failure | Stage |
|---|---|---|
| **WineHQ bug 59411** (2026-02-14, Ubuntu 25.04, wine-11.2-staging) | `wine: Call from 00006FFFFFBFD887 to unimplemented function ntoskrnl.exe.PsGetProcessImageFileName, aborting` | late (ACE loaded) |
| **dwproton issue #30** (Endfield CN) | `wine: Call from 00006FFFFFBFD917 to unimplemented function ntoskrnl.exe.PsGetProcessExitStatus, aborting` | late |
| **GE-Proton issue #433** | `wine: Call from 00006FFFFFC0D1F7 to unimplemented function msimg32.dll.AlphaBlend, aborting` + ACE dialog "driver error code (13-131104-257)" | ACE init |

On Linux the game gets **far**: WineHQ 59411's log shows ACE's kernel driver actually loading (`ntoskrnl:IoCreateDeviceSecure … L"\Device\ACE-BASE"`), **DXVK/Vulkan initializing on the GPU**, and only *then* a **clean** Wine "unimplemented function … aborting" (a graceful missing-export relay abort → winedbg). These are the failures dw-proton's commit `b816be489` fixes: its ntoskrnl **em-backports include `PsGetProcessImageFileName`** (the exact 59411 blocker), and its int3 `KiUser*Dispatcher` spoof handles the tpshell Wine-detection stage.

## Our macOS failure is a *different, earlier* fault

| | Linux (what dw-proton fixes) | **Our macOS (CrossOver 26/27)** |
|---|---|---|
| Where it dies | **After** the protector runs and **after** ACE loads (`\Device\ACE-BASE` created, DXVK up) | **Before** ACE loads at all — inside `EndfieldBase.dll` (tpshell) |
| Failure type | **Clean** `unimplemented function …, aborting` (single thread → winedbg) | **`EXCEPTION_ACCESS_VIOLATION` (c0000005) execute-fault** at constant `0x6CD268` → protector SEH re-enters itself → `detected collided unwind` ×273 → `virtual_setup_exception stack overflow` |
| `KiUser*Dispatcher` GetProcAddress | Reached (that's what the int3 hack intercepts) | **Not observed — but NOT logged** (needs `+relay`; may well happen — see [12](12-stage1-protector-fault.md)) |
| `unimplemented function` abort | Yes (the whole failure) | **Never emitted** |
| Missing ntoskrnl export | `PsGetProcessImageFileName` / `PsGetProcessExitStatus` | **N/A — we die before any ntoskrnl call** |

**No public Linux/Proton report shows our signature** — no `EndfieldBase.dll` jump to `0x6CD268`, no `collided unwind`, no `stack overflow` loop. It is **CrossOver/macOS-x86_64-specific**.

## The two-stage model (the key mental model going forward)

```
STAGE 1  — protector self-check (tpshell / EndfieldBase.dll, VMProtect/TenProtect)
           ├─ Linux:  PASSES.  The relocated protector executes its exception-based
           │          control flow correctly and proceeds to ACE init.
           └─ macOS:  FAILS HERE.  Execute-fault at 0x6CD268 → collided-unwind loop
                      → stack overflow.  ← WE ARE STUCK HERE. Not fixed by dw-proton.
STAGE 2  — ACE init (ace-base.sys shim + KiUser* dispatcher detection + timing)
           ├─ Linux:  fails on stock Wine (missing ntoskrnl export / KiUser detection / timing)
           │          → THIS is what dw-proton b816be489 fixes.
           └─ macOS:  UNREACHED — we never get here.
```

**So:** the dw-proton set actually **spans both stages** — a distinction that took a second research pass to see:
- The **int3 `KiUser*Dispatcher` spoof** (`misc/0009+0010`) targets **tpshell = `EndfieldBase.dll` = our stage-1 protector**. It is therefore a **stage-1 fix *candidate*** — possibly *our* fix. See [docs/12](12-stage1-protector-fault.md) (updated: the mechanism is now understood, with a near-exact prior-art analog in WineHQ Bug 45083, and the int3 spoof is the #1 experiment).
- The **`ntoskrnl` em-backports** target the **stage-2** ACE kernel shim — unreached until stage 1 clears.

So it is **no longer certain** our blocker is "novel and unsolved": it may be the missing tpshell int3 patch (which vanilla/GE-Proton Linux also needs), or a genuinely macOS-specific residual (Bug 45083 class). Applying the int3 spoof discriminates — that's the plan in [docs/12](12-stage1-protector-fault.md).

## Why does stage 1 pass on Linux but fail on macOS? (hypotheses)

Both platforms relocate the protector into the `0x6FFFxxxx` region (Linux abort callers are at `0x6FFFFFBFD887` etc.; our `EndfieldBase.dll` lands at `0x6FFFEE950000`). So **"it got relocated" is not the differentiator** — Linux relocates it too and the protector still runs. The macOS-specific factors that could break the protector's execute-fault/exception-trampoline scheme:

1. **Rosetta 2 translation of the protector's exception-based / self-modifying code.** VMProtect/tpshell deliberately triggers execute-faults and drives control through SEH. Rosetta's x86_64→arm64 translation of self-modifying code, DEP/execute faults, and exception delivery may produce the bad `0x6CD268` target where native x86_64 Linux does not. `[leading hypothesis]`
2. **Wine-on-macOS exception delivery (Mach exceptions / BSD signals) vs Linux signals.** The `collided unwind` loop is generic Wine ntdll unwind code (Wine 5.10 changelog); macOS's exception-delivery path through `winemac`/Mach may mishandle the protector's rapid re-fault where Linux's signal path recovers. `[leading hypothesis]`
3. **Preferred-base contention specific to CrossOver's macOS address space.** `EndfieldBase.dll` preferred base `0x180000000` is never granted under CrossOver (Wine builtins default to image base `0x180000000` via winegcc); if the constant `0x6CD268` is derived from an assumption that holds only at the preferred base, macOS's particular relocation could break it where Linux's doesn't. `[weaker — Linux relocates too]`

These are deep, macOS-specific Wine/Rosetta issues. **This is the frontier of the project and the hard part.** It does *not* make the project impossible (it's a compatibility bug, not a kernel-anti-cheat wall — risk #1 stays downgraded), but it is unsolved and may be difficult.

## What this means for the plan
- **Stage 2 (dw-proton port) is staged but blocked** behind stage 1. We still set up the build + patches now, because any stage-1 fix also requires a rebuildable Wine.
- **Stage 1 becomes the critical path.** It needs a custom Wine we can instrument and patch: test exception-handling behavior, image-base changes, and Rosetta interaction. See [docs/09](09-implementation-roadmap.md) (restructured) and [docs/12-stage1-protector-fault.md](12-stage1-protector-fault.md).
- **Honest expectation:** stage 1 may be harder than the entire dw-proton port. The next decisive, cheap-ish experiments are (a) get a custom Wine building and swapping cleanly (milestone 4), then (b) bisect whether it's the exception-delivery path or Rosetta by testing targeted Wine exception/unwind changes.

## Not our bug (ruled out)
`RyuConnor/Arknights_Endfield-Fix` (GitHub) is a **Windows-side PowerShell** workaround for a *different* access violation — a null-pointer crash in the Qt launcher `PlatformProcess.exe`, fixed with `QT_QUICK_BACKEND=d3d11`, plus ACE kernel-trace cleanup. It is **not** our `EndfieldBase.dll` game-process fault. (Noted in case the Qt backend variable ever becomes relevant to the launcher UI, but it does not address stage 1.)

## Sources
- WineHQ bug 59411 (+ attachment 80378) — <https://bugs.winehq.org/show_bug.cgi?id=59411>
- dwproton issue #30 — <https://dawn.wine/dawn-winery/dwproton/issues/30>
- GE-Proton #433 — <https://github.com/GloriousEggroll/proton-ge-custom/issues/433>
- GamingOnLinux GE-Proton 10-31 — <https://www.gamingonlinux.com/2026/02/ge-proton-10-31-brings-fixes-for-arknights-endfield-duet-night-abyss-and-more/>
- Wine 5.10 "collided unwind" changelog — <https://www.winehq.org/announce/5.10>
- TenProtect detection notes — <https://github.com/SteamDatabase/FileDetectionRuleSets/blob/main/descriptions/AntiCheat.TenProtect.md>
