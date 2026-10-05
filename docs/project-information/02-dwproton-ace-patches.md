# 02 — The dw-proton ACE patches (patch-level inventory)

> **This is the core of the port.** These are the actual Wine patches that make Endfield launch on Linux; porting them (and resolving conflicts against CrossOver's `win32on64` fork) is milestone 6.
>
> Source: a dedicated current-tree pass that verified every patch against dw-proton **release `11.0-7`** via GitHub mirrors sharing the same git objects (dawn.wine itself is behind an Anubis proof-of-work wall). Code below was read from live `11.0-7` sources, not just historical snapshots. `[overall confidence: high]`

## ⚠️ Structural finding: `patches/wine/` no longer exists

The GE-issue link and older writeups reference a `patches/wine/` folder in dwproton. **That folder was deleted between releases `11.0-1` and `11.0-2`.** The Wine patches were baked directly as commits into a **submodule Wine fork**:

```
Wine fork:      dawn.wine/dawn-winery/wine-dwproton.git   (branch: base)
Release 11.0-7: wine submodule pinned at commit e75e5bd2bc5a0eb70852d0081485c4faa99bc3f6
```
**Implication for the implementer:** to get the patches, diff the `wine-dwproton` `base` branch against its upstream Wine base — do **not** look for `patches/wine/`. The file-based layout below (`0001-em-backports/`, `0002-misc-dw/`) is from the last snapshot that still had it (`10.0-26`); it's the cleanest representation, and **every patch was confirmed still applied in `11.0-7`** (verified in `ntoskrnl.exe.spec`, `module.c`, `sync.c`, `wintrust_main.c`).

## The fix commit, and the "4 patches" resolved

GE-Proton's maintainer identified the fix (issue #433) as dwproton commit **`b816be489049a10453b470c6a12dcf552ea41773`** — *"just 4 misc patches imported from upstream wine."* That was a loose count. The commit (author **NelloKudo**, 2026-01-26, "add more timing compatibility patches, re-organize folders") actually:
- added the **int3 spoof** patch,
- added the **int3 gate** patch,
- added the **`NtDelayExecution` QPC** patch,
- **renamed the wintrust patch** (`0003-dna/0018` → `0002-misc/0008`) and renamed the em-backports folder.

So the "4th patch" mystery from earlier drafts is **resolved**: the fourth item was the **wintrust signature-check bypass** — which has since been **removed** from the tree (see below).

## Patch family 1 — `em-backports` (`ntoskrnl.exe` implementations)

Author **Etaash Mathamsetty**. Plain portable C, **no arch guards**. These satisfy ACE's kernel-driver (`ace-base.sys`) probing of `ntoskrnl.exe` exports that stock Wine leaves unimplemented (the documented "unimplemented function in ntoskrnl.exe" hang). All 18 confirmed present in `11.0-7`'s `ntoskrnl.exe.spec`. `[confidence: high]`

| # | Function | Status |
|---|---|---|
| 0001 | `KeAcquireGuardedMutex` | implement |
| 0002 | `KeReleaseGuardedMutex` | implement |
| 0003 | `PsGetProcessSessionId` | implement |
| 0004 | `PsGetProcessCreateTimeQuadPart` | implement |
| 0005 | `PsGetThreadProcess` | implement |
| 0006 | `KeRegisterBugCheckCallback` | stub |
| 0007 | `KeRegisterBugCheckReasonCallback` | stub |
| 0008 | `KeDeregisterBugCheckReasonCallback` | stub |
| 0009 | `MmGetVirtualForPhysical` | semi-stub |
| 0010 | `PsGetProcessImageFileName` | implement |
| 0011 | `SeLocateProcessImageName` | implement |
| 0012 | `PsReferencePrimaryToken` | implement |
| 0013 | `PsGetContextThread` | implement (no arch `#ifdef`) |
| 0014 | **`create_process_object` fix** | fix in `dlls/ntoskrnl.exe/ntoskrnl.c` |
| 0015 | `SeLocateProcessImageName` follow-up fix | fix |
| 0016 | `KeCapturePersistentThreadState` | stub |
| 0017 | `MmGetPhysicalMemoryRanges` | implement |
| 0018 | `PsGetProcessPeb` | implement |

Some carry 2023-dated headers (backports of Etaash's older work); `MmGetPhysicalMemoryRanges`, `PsGetProcessPeb`, and the `create_process_object` fixup are dated July 2025. **`create_process_object` (0014) is the *only* process-creation patch — there is no wineserver patch — and is the one most likely to conflict with CrossOver's tree.**

> Superset menu: the related **`Etaash-mathamsetty/wine-ntoskrnl`** project ([07](07-rosetta-and-windows-spoofing.md)) implements *additional* functions (synchronization barriers, `KeIpiGenericCall`, `MmMapLockedPagesSpecifyCache`, flag/`INT` emulation) not all of which are in dwproton. If milestone 1 reveals an ntoskrnl function dwproton doesn't cover, pull it from there.

## Patch family 2 — `misc-dw` (the HACKs)

Mixed authors. This is **larger than earlier drafts stated** — it's not just the int3 hack + `NtDelayExecution`. `[confidence: high]`

| # | Patch | Author | Purpose | Arch |
|---|---|---|---|---|
| 0001 | `mmdevapi` allow winealsa under `PROTON_USE_WINE…` | dw | ALSA driver under env flag | portable |
| 0002 | **int3-stub spoof of `KiUserApcDispatcher`/`KiUserCallbackDispatcher`** | Ziia Shi (`mkrsym1@gmail.com`) | defeat ACE dispatcher probe | ⚠️ **x86_64 only** |
| 0003 | **gate the int3 hack** (`needs_int3_hack()`) | NelloKudo | limit to Endfield procs + env override | ⚠️ **x86_64 only** |
| 0004 | **`NtDelayExecution` relative-wait via QPC** | Etaash Mathamsetty | timing-sensitivity | portable |
| 0005 | `wdfldr.sys` add stub dll | dw | Windows Driver Framework loader stub | portable |
| 0006 | `wdfldr.sys` semi-implement `WdfVersionBind` | dw | WDF bind | portable |
| 0007 | `wdfldr.sys` populate `WdfDriverMiniportUnload` table | dw | WDF table | portable |
| 0008 | `ntoskrnl.exe` stub `KeGetCurrentIrql` | dw | IRQL stub | portable |
| 0009 | `win32u` fix `NtUserEnableMouseInPointer` | dw | mouse-in-pointer | portable |
| 0010 | **HACK `kernelbase` delay return for `VersionService.exe`** | dw | timing HACK (process-gated) | portable |
| 0011 | `ntdll` stop unwinding on access violation | dw | AV unwind fix | portable |
| 0012 | HACK `winex11` skip some overlay windows | dw | overlay | portable (X11-only, **macOS-irrelevant**) |

Note the **`wdfldr.sys` stubs** (0005–0007) — the WDF loader is what a driver like `ace-base.sys` would bind against — and a **second process-gated timing HACK** (`VersionService.exe`, 0010), alongside the int3 gate. Both are worth watching if ACE stalls under CrossOver.

## Patch A — the int3-stub hack (verbatim, current `11.0-7`) ⭐

The single most Endfield-specific and most arch-fragile fix. In `dlls/kernel32/module.c`:

```c
#ifdef __x86_64__
static BOOL needs_int3_hack(void)
{
    static volatile int cache = -1;
    if (cache == -1)
    {
        const WCHAR *p, *name = NtCurrentTeb()->Peb->ProcessParameters->ImagePathName.Buffer;
        WCHAR env[8];
        BOOL ret;
        if ((p = wcsrchr(name, '/')))  name = p + 1;
        if ((p = wcsrchr(name, '\\'))) name = p + 1;
        ret = ((!wcsicmp(name, L"Endfield.exe")) ||
               (!wcsicmp(name, L"EM-Win64-Shipping.exe")));
        if (GetEnvironmentVariableW(L"PROTON_ENABLE_INT3_HACK", env, ARRAY_SIZE(env)))
            if (_wtoi(env) == 1) ret = TRUE;
        cache = ret;
    }
    return cache;
}
static void __attribute__((naked)) int3_stub( void )
{ asm("int3\t\n" "int3\t\n" "int3\t\n" "int3\t\n"); }
#endif
```
…and in `get_proc_address()`:
```c
#ifdef __x86_64__
    if (needs_int3_hack() &&
        (strcmp(function,"KiUserApcDispatcher")==0 || strcmp(function,"KiUserCallbackDispatcher")==0))
    { FIXME("HACK: returning int3 stub instead of %s\n", function); return (FARPROC)&int3_stub; }
#endif
```

**Mechanism:** ACE resolves these two ntdll dispatcher entry points via `GetProcAddress` to hook them / probe the environment. Returning four `int3` (`0xCC`) breakpoints defeats the probe so ACE initialization proceeds. "tpshell" = Tencent/ACE `tp` shell loader.

⚠️ **Corrections vs. earlier drafts:**
- The **`/* workaround for tpshell */` comment is NOT in the current code.** It was in the *original* spoof patch (Ziia Shi, 2026-01-20) and was **deleted** when the gate patch (NelloKudo, 2026-01-24) replaced it with `needs_int3_hack()`. Don't grep current sources for it.
- The gate matches **`Endfield.exe` OR `EM-Win64-Shipping.exe`** plus **`PROTON_ENABLE_INT3_HACK=1`**. (The very first b816 version gated on `Endfield.exe` only with no env override; both were added later.)

## Patch C — `NtDelayExecution` via QPC (verbatim)

`dlls/ntdll/unix/sync.c`, relative-wait (negative-timeout) branch, author Etaash Mathamsetty. Uses `NtQueryPerformanceCounter` instead of `NtQuerySystemTime`: `[confidence: high]`
```c
else if (timeout->QuadPart < 0) {
    timeout_t when = -timeout->QuadPart, diff;
    LARGE_INTEGER now;
    NtQueryPerformanceCounter( &now, NULL );
    when += now.QuadPart;
    for (;;) {
        struct timeval tv;
        NtQueryPerformanceCounter( &now, NULL );
        diff = (when - now.QuadPart + 9) / 10;   /* QPC 100ns ticks → µs */
        if (diff <= 0) break;
        tv.tv_sec = diff / 1000000; tv.tv_usec = diff % 1000000;
        if (select( 0, NULL, NULL, NULL, &tv ) != -1) break;
    }
}
```
Commit message: *"Some applications are very timing sensitive."* ⚠️ **macOS concern:** validated on Linux x86_64; under Rosetta 2 + CrossOver MSync the busy-wait timing may diverge (risk #4 in [08](08-risks-unknowns-open-questions.md)).

## The wintrust bypass — real, but removed (and macOS-irrelevant)

The historical patch **`0003-dna/0018-wintrust-Prevent-checking-if-winex11-winewayland-are-signed.patch`** (author NelloKudo, 2025-12-31, "based on a patch from Lily; fixes DNA crashing at startup") added `needs_wintrust_fixes()` matching `EM-Win64-Shipping.exe`; in `WINTRUST_DefaultVerify`, when the verified file path was `C:\windows\system32\winex11.drv` or `…winewayland.drv`, it **forced `err = 0`** — skipping signature verification so ACE couldn't flag the Wine graphics driver as unsigned. `[confidence: high]`

- This was **the only anti-cheat *detection-evasion* patch dwproton ever carried.**
- It was renamed to `0002-misc/0008` in commit `b816`, then **dropped** — verified **absent** in `11.0-7` (`dlls/wintrust/wintrust_main.c` has 0 matches for `needs_wintrust_fixes`/`winewayland`).
- ⚠️ **macOS-irrelevant regardless:** it targets `winex11.drv` / `winewayland.drv`. CrossOver on macOS uses **`winemac.drv`**, so this exact patch does nothing here. If an analogous "hide the graphics driver from ACE's signature check" is ever needed on macOS, it would have to target `winemac.drv` — but there is **no evidence** ACE performs this check on macOS, and dwproton itself dropped it on Linux.

## No Wine-export hiding, no registry hiding, no graphics/GPTK patches

- dwproton's ACE set includes **no `wine_get_version` export hiding, no registry hiding, no Wine-presence environment-detection patch** — other than the (removed) wintrust one. `[confidence: medium-high]` Meaning: on Linux, ACE tolerates Wine's telltale exports, so dwproton doesn't bother hiding them. Whether macOS/CrossOver needs the separate `Hide_Wine_Exports` lever ([07](07-rosetta-and-windows-spoofing.md)) is an empirical question for milestone 2 — dwproton is not evidence that it's required.
- **No graphics/DXVK/VKD3D/GPTK/Apple/MoltenVK patch is ACE-related.** dwproton is a Linux Proton/CachyOS fork; its graphics patches (DXVK HDR, llasync, low-latency) don't touch anti-cheat. The macOS graphics stack ([06](06-graphics-and-gptk.md)) is an entirely separate concern.

## Architecture-portability (the crux for macOS)

| Patch | x86_64-under-Rosetta CrossOver | native arm64 CrossOver |
|---|---|---|
| int3 hack (misc 0002/0003) | ✅ **compiles** (`#ifdef __x86_64__` satisfied by the DIY x86_64 build) | ❌ **compiles out entirely** — `needs_int3_hack`, `int3_stub`, and the spoof branch vanish; `asm("int3")` is meaningless on ARM. Would need a `brk #0`-style ARM equivalent written from scratch. **Most arch-fragile patch.** |
| `NtDelayExecution` QPC (misc 0004) | ✅ portable | ✅ portable |
| em-backports (all 18) | ✅ portable C | ✅ portable C (`PsGetContextThread`/`create_process_object` use Wine's arch-abstracted types) |
| wdfldr / KeGetCurrentIrql / misc | ✅ portable | ✅ portable (winex11 overlay HACK is X11-only, moot on macOS) |

**Bottom line:** target an **x86_64 CrossOver base under Rosetta 2** — the only configuration where the load-bearing int3 dispatcher spoof exists. A native arm64 port keeps the em-backports and the QPC fix but **loses the int3 spoof**, which may be essential for ACE. This is compatible with today's DIY FOSS build ([04](04-building-crossover-wine.md)) but collides with CrossOver's native-arm64 direction (risks #2/#5 in [08](08-risks-unknowns-open-questions.md)).

## Identifiers (for grepping / porting)
```
Fix commit:   b816be489049a10453b470c6a12dcf552ea41773  (NelloKudo, 2026-01-26)
Wine fork:    dawn.wine/dawn-winery/wine-dwproton.git   branch: base
Release pin:  11.0-7 → wine submodule e75e5bd2bc5a0eb70852d0081485c4faa99bc3f6
Env override: PROTON_ENABLE_INT3_HACK=1
Files:        dlls/kernel32/module.c        (int3 hack)
              dlls/ntdll/unix/sync.c        (NtDelayExecution QPC)
              dlls/ntoskrnl.exe/ntoskrnl.c  (create_process_object fix + em-backports)
              dlls/ntoskrnl.exe/ntoskrnl.exe.spec  (exports)
              dlls/wintrust/wintrust_main.c (historical wintrust bypass — now removed)
Contributors: Etaash Mathamsetty (em-backports, NtDelayExecution QPC);
              Ziia Shi / mkrsym1 (int3 spoof); NelloKudo (gating, wintrust, reorg); "Lily" (wintrust idea)
Accessible mirrors (dawn.wine is Anubis-walled):
              github.com/dawn-winery/dwproton-mirror   github.com/NelloKudo/wine-dwproton
              github.com/TomerGamerTV/dwproton  (historical patches/wine/ tree)
```

## Open questions
- Exact commit that deleted `patches/wine/` (bounded to between `11.0-1` and `11.0-2`).
- The **Wine base version** `wine-dwproton` `base` forks from, vs. CrossOver `winecx`'s base — determines rebase difficulty.
- Whether the int3 KiUser dispatcher spoof is strictly *required* by ACE or a belt-and-suspenders APC/timing workaround (the exact ACE check is undocumented).
- Which specific `ntoskrnl` function Endfield's ACE aborts on first (⚠️ the only *documented* Endfield abort is `msimg32.dll.AlphaBlend`, not ntoskrnl — milestone 1 settles this).

## Primary sources
- GE-Proton issue #433 — <https://github.com/GloriousEggroll/proton-ge-custom/issues/433>
- dwproton mirror — <https://github.com/dawn-winery/dwproton-mirror> · wine fork proxy — <https://github.com/NelloKudo/wine-dwproton> · historical tree — <https://github.com/TomerGamerTV/dwproton>
- `Etaash-mathamsetty/wine-ntoskrnl` — <https://github.com/Etaash-mathamsetty/wine-ntoskrnl>
- (Anubis-walled) dawn.wine — <https://dawn.wine/dawn-winery/dwproton> · <https://dawn.wine/dawn-winery/wine-dwproton>
