# 14 — The ACE-CORE regression (Oct 2026): why the game stopped launching

> **Status: the `0x65636157` bug check is FIXED and hardware-verified; the game now fails one
> ACE stage later with a "security component" error. See §12.**
> This doc consolidates the Oct-2026 regression (issue [#43](https://github.com/stoicswe/Endfield_FineWine/issues/43)),
> cross-checks it against other ACE-on-Wine projects, and lays out the ranked hypotheses
> and the experiments that will settle them. Everything here is either **CONFIRMED** from a
> primary log/source or **HYPOTHESIS** — tags are inline. Do not treat the patch plan at the
> end as a verified fix; the evidence below says the missing exports alone are **not** enough.
>
> ### ★ UPDATE (2026-10-15): the fix is in `mary-ext/crossover-wine-endfield`
>
> The downstream fork has **already solved this**. Two patches are load-bearing, and the
> first confirms hypothesis **H1** outright:
>
> 1. **`wine/dwproton/0004`** (upstream commit `09a9cb034e`, mkrsym1, 2026-09-17) —
>    *"Call DriverInit with bits 48-64 of return address set."* ACE-CORE inspects the
>    driver-init **return address** and **bug-checks at entry when it is not a kernel
>    address** (bits 48–63 clear = user space = Wine/emulator). The patch ORs
>    `0xFFFF800000000000` into the return address on the stack before jumping to
>    `DriverInit`, so ACE's check passes. The downstream describes this as the fix for
>    "*an ACE-CORE bug check at entry*" — i.e. the `KeBugCheckEx 0x65636157` in issue #43.
> 2. **`wine/macos/0007`** (Mary, 2026-10-15) — *"lsass: Add a stub and start it from
>    wineboot."* ACE-CORE also **scans the process list for `lsass.exe`** and fails
>    `DriverInit` when none exists; stock CrossOver 26.3 / Wine 11.0 has no `lsass.exe`.
>
> Supporting patches in the same fork: `dwproton/0005` (`MmCopyMemory` stub), `0006`
> (`DriverExtension->ServiceKeyName` = service name only), `0007` (keep section views mapped
> while a locked MDL uses them), `0008` (`PsGetContextThread` thunk); `upstream/0037–0042`
> (the MDL implementations `0007` depends on); `upstream/0006` (security cookie after
> relocation); `macos/0005` (`PsGetProcessExitStatus`). See **§11**.

## TL;DR

- A late-2026 Endfield update replaced the ACE kernel driver **`ACE-BASE.sys` with a new
  `ACE-CORE<version>.sys`** (observed: `ACE-CORE106010071.sys`). `[CONFIRMED: issue #43]`
- The new driver's `DriverEntry` **maps and enters, then calls `KeBugCheckEx 0x65636157`** —
  i.e. ACE deliberately aborts. `[CONFIRMED: log in #43; reproduced by a second reporter]`
- Seven `ntoskrnl.exe` imports are reported unimplemented at load
  (`PsGetCurrentThreadTeb`, `KeIpiGenericCall`, `KeTryToAcquireGuardedMutex`,
  `KeSetSystemGroupAffinityThread`, `KeRevertToUserGroupAffinityThread`,
  `KeGetProcessorNumberFromIndex`, `ObDereferenceObjectDeferDelete`). `[CONFIRMED: log]`
- **⚠️ But the unimplemented imports are probably not the trigger.** The same reporter
  (`LANCYPANCY`, #43) tested an **older CORE build that imports none of the seven and still
  bugchecks identically**, while an older BASE build that imports six of them **initialises
  and reaches `RUNNING`**. The stop code is hit during `DriverEntry`, and the captured
  trace shows `RtlPcToFileHeader(&PsProcessType, …)` returning the ntoskrnl image base
  immediately before the bugcheck. `[CONFIRMED: #43 controlled comparison]`
- The new CORE is a **hardened "Neac"-generation ACE driver that validates the kernel image
  itself** (anti-emulator / anti-hook integrity checks: signature-scan `MmGetVirtualForPhysical`,
  parse `ntoskrnl.exe`, read `KeServiceDescriptorTableShadow`, read the IDT `KiPageFault`
  entry). Wine cannot satisfy those checks. `[HYPOTHESIS, high confidence — see "What the
  new driver actually does" below]`
- Prior art corroborates "missing exports are necessary but not sufficient": the Valve
  Proton tracker (#9331) cherry-picked the upstream `KeTryToAcquireGuardedMutex` family and
  **still could not launch the affected ACE games**. `[CONFIRMED: Proton #9331]`

**Bottom line:** the practical fix is *not* just to implement the seven exports. It is to
find the specific kernel-image check that fires `0x65636157` and neutralise/emulate it — the
same class of work as the stage-1 `EndfieldBase.dll` protector fix, not the stage-2
"export missing" work.

---

## 1. What changed

| | Before (working) | After (broken) |
|---|---|---|
| Kernel driver | `ACE-BASE.sys` (1.0.x) | `ACE-CORE<build>.sys` (e.g. `106010071`, `29.6.2608.440`, `24.3.2511.316`) |
| User-mode | `ACE-BASE64.dll` injection | unchanged in the parts we can see |
| Init outcome | `DriverEntry` returns `0`; service reaches `RUNNING` | `DriverEntry` **never returns**; `KeBugCheckEx 0x65636157` |
| ntoskrnl imports | subset already covered by the FineWine dW-proton backports | **+7 new imports** (list above) |

The switch from `ACE-BASE` to `ACE-CORE` was *not* a rename: a pre-update working log shows
BASE being loaded, and the old saved package already contained CORE, so the change is
**driver selection/activation**, not file renaming. `[CONFIRMED: #43]`

Observed hash for the tested CORE: `ACE-CORE106010071.sys`
SHA-256 `7b77fe118b51c8baf4a448eb2bec9c630389ad5431ffcc06c68d51579ace689d`. `[CONFIRMED: #43]`

## 2. The failure trace, decoded

Distilled from the `Endfield.cxlog` in #43:

```text
trace:process:ExpandEnvironmentStringsW  "C:\Program Files\AntiCheatExpert\ACE-CORE106010071.sys"
trace:module:map_image_into_view          mapped at 0x100400000-0x1007f5000  (.text/.rdata/.CRT/.gfids/.reloc)
warn:module:import_dll  No implementation for ntoskrnl.exe.PsGetCurrentThreadTeb          -> 0xF60000
warn:module:import_dll  No implementation for ntoskrnl.exe.KeIpiGenericCall               -> 0xF60024
warn:module:import_dll  No implementation for ntoskrnl.exe.KeTryToAcquireGuardedMutex     -> 0xF60048
warn:module:import_dll  No implementation for ntoskrnl.exe.KeSetSystemGroupAffinityThread  -> 0xF6006C
warn:module:import_dll  No implementation for ntoskrnl.exe.KeRevertToUserGroupAffinityThread -> 0xF60090
warn:module:import_dll  No implementation for ntoskrnl.exe.KeGetProcessorNumberFromIndex  -> 0xF600B4
warn:module:import_dll  No implementation for ntoskrnl.exe.ObDereferenceObjectDeferDelete  -> 0xF600D8
trace:loaddll:build_module  Loaded .../ACE-CORE106010071.sys at 0000000100400000: native
trace:module:process_attach (L"ACE-CORE106010071.sys") - START
trace:module:process_attach (L"ACE-CORE106010071.sys") - END
err:ntoskrnl:KeBugCheckEx 65636157 0 0 0 0
```

Notes:

- `0x65636157` is a **custom ACE bugcheck code**, not a documented Windows `BUGCHECK_*`
  value. As bytes it is `57 61 63 65` = ASCII "Wace" (or reversed "ecaW"); it does **not**
  map to a standard code and should be treated as ACE's own "refuse to continue" marker.
  `[CONFIRMED: not in the WDK bugcheck list]`
- Wine's `import_dll` thunk address for a missing export is a Wine-internal stub
  (`0xF600xx` here), **outside the mapped driver and outside the ntoskrnl image**. If CORE
  inspects or executes one of those pointers during `DriverEntry` it is not getting real
  kernel code. `[CONFIRMED behaviour of Wine's loader]`
- The error text says "right after the driver's entry point returns", but the controlled
  trace from #43 corrected this: the bugcheck happens **inside `DriverEntry`, before it
  returns**, right after `RtlPcToFileHeader(&PsProcessType, …)` yields the ntoskrnl image
  base. `[CONFIRMED: #43]`

## 3. What the new ("Neac") driver actually does

The seven missing imports are not a random grab-bag — they are a fingerprint. Independent
reverse-engineering of a **newer-generation ACE ("Neac") kernel driver** (xia0ji233,
"某FPS游戏反作弊分析", 2026-03-05 — a Delta-Force-class title) shows the same API set being
resolved at runtime with `MmGetSystemRoutineAddress`: `[CONFIRMED: blog; HYPOTHESIS: same
family as Endfield's CORE]`

```
KeGetProcessorNumberFromIndex, KeSetSystemGroupAffinityThread,
KeRevertToUserGroupAffinityThread, KeGetCurrentProcessorNumberEx,
KeIpiGenericCall, KeGenericCallDpc, KeSignalCallDpcDone, KeSignalCallDpcSynchronize,
KeQueryActiveProcessorCount(Ex), PsGetProcessSessionId, SeLocateProcessImageName, ...
```

and its `DriverEntry` performs, in order:

1. **Signature-scan `MmGetVirtualForPhysical`** and `RtlCompareMemory` it against the exact
   real-kernel prologue `48 8B 04 D0 48 C1 E0 19 48 BA` — an **anti-hook / anti-emulator**
   check (the blog author notes simulators can't reproduce it, so they force
   `RtlCompareMemory` to return "match").
2. `MmGetSystemRoutineAddress` the API list above.
3. **Get the ntoskrnl image base and parse it** (walk the module list, `RtlImageNtHeader`).
4. **Read `KeServiceDescriptorTableShadow+0x10`** (the SSDT size field).
5. **Read IDT entry `0xE`** (`KiPageFault`) and verify its bytes.
6. Read assorted kernel flags, logging anomalies (`OwNeacSafe.log`).
7. Register object/process/thread/load-image callbacks and a minifilter port; spawn threads
   that do **IPI-broadcast (`KeIpiGenericCall`) cross-processor memory scans**.

This is the machine that produces the failure shape we see: step 3 is exactly where the
Endfield CORE's trace lands (`RtlPcToFileHeader(&PsProcessType)` → ntoskrnl base → **bugcheck**).
Wine's ntoskrnl is a Wine-built PE: its `MmGetVirtualForPhysical` does **not** contain the
real Windows prologue, it does **not** expose `KeServiceDescriptorTableShadow`/an IDT the way
the checks expect, and a parse/pattern-scan of its headers will not match. Any of those is a
plausible trigger for a deliberate `KeBugCheck`. `[HYPOTHESIS, high confidence]`

> **Ethics/scope note.** This is compatibility work in the same category as before — making
> Wine look enough like Windows for ACE's *own* init path to proceed. It is explicitly **not**
> "disable the anti-cheat": the goal stays the repo's stated one (let ACE run uninterrupted).
> See the [README scope note](../README.md) and the licence section.

## 4. What the current FineWine build is missing

The FineWine patch set is pinned to dw-proton's fix commit `b816be489` (≈ `11.0-7` era,
Wine 10.x) and rebased onto **CrossOver 26.3 / Wine 11.0**. Checking the *patched* tree
(`build/wine-src`, `git diff`) and Wine master: `[CONFIRMED against source]`

| Export | Vanilla CrossOver 26.3 (Wine 11.0) | FineWine patches | dw-proton `11.0-14` |
|---|---|---|---|
| `KeAcquireGuardedMutex` / `…Unsafe` / `KeReleaseGuardedMutex` | ❌ | ✅ (em-backports 0001/0002) | ✅ |
| `PsGetProcessSessionId`, `PsGetProcessImageFileName`, `PsGetThreadProcess`, `PsReferencePrimaryToken`, `PsGetContextThread`, `MmGetPhysicalMemoryRanges`, `KeRegisterBugCheck*`, `KeCapturePersistentThreadState`, … | ❌ (stubs) | ✅ (em-backports 0001–0017) | ✅ |
| `PsGetCurrentThreadTeb` | ❌ | ❌ | ⚠️ present on some branches, not on others |
| `KeIpiGenericCall` | ❌ | ❌ | ❌ |
| `KeTryToAcquireGuardedMutex` | ❌ | ❌ | ❌ |
| `KeSetSystemGroupAffinityThread` | ❌ | ❌ | ❌ |
| `KeRevertToUserGroupAffinityThread` | ❌ | ❌ | ❌ |
| `KeGetProcessorNumberFromIndex` | ❌ | ❌ | ❌ |
| `ObDereferenceObjectDeferDelete` | ❌ (not even a spec line) | ❌ | ❌ |
| `KeGetCurrentIrql` | ❌ | ❌ (dw-proton misc `0008` has it) | ✅ stub |
| `PsGetProcessExitStatus` | ❌ (stub) | ❌ (stub) — known residual | ⚠️ implemented on some branches |

Wine master (the 11.18-era tree) **still lacks** all six "new" exports, so this is not a
"rebase to newer Wine" problem — nobody upstream has them yet. `[CONFIRMED]`

## 5. Prior art — what other projects did with similar ACE breakage

| Project | Situation | What they did | Outcome |
|---|---|---|---|
| **dw-proton** (Linux) | Endfield kept working after the Jan-2026 ACE change while GE-Proton broke | Carried the "4 misc patches" (int3 dispatcher spoof, gate, `NtDelayExecution` QPC) + em-backports | Endfield launches on Linux **[CONFIRMED: GE #433]** |
| **GE-Proton** | Endfield ACE broke Jan-2026 | Imported dw-proton's patches into GE-Proton 10-30/10-31 | Fixed **[CONFIRMED: GamingOnLinux/SteamDeckHQ]** |
| **Valve Proton #9331** | `Duet Night Abyss` (+2 others) fail on `ACE-BASE` after an update: `unimplemented ntoskrnl.exe.KeAcquireGuardedMutex` | Upstreamed & cherry-picked `KeTryToAcquireGuardedMutex`/`KeAcquire…`/`KeRelease…` (Wine MR 2044) | **Exports landed, games still crashed** — "just those cherry-picks are not enough" **[CONFIRMED: #9331]** |
| **dw-proton issue #30** | Endfield abort: `unimplemented ntoskrnl.exe.PsGetProcessExitStatus` | Implemented the stub | dw-proton maintainer: the abort was "not really related" **[CONFIRMED]** |
| **`Etaash-mathamsetty/wine-ntoskrnl`** | A scratch fork for anti-cheat drivers (Vanguard, Denuvo, ACE) | Implements extra ntoskrnl exports, incl. `KeGetProcessorNumberFromIndex` (semi-stub) and `KeIpiGenericCall` (only a synchronous fallback `function(context)`; the real multi-CPU IPI version is `#if 0`); instruction emulation (parity/INT) for Vanguard | Reference code, **never merged**; last touched 2022 **[CONFIRMED]** |
| **Wine bug 49224** | `denuvo-anti-cheat.sys` crashed on `KeGenericCallDpc`/`KeSignalCallDpc*` | Implemented the DPC-broadcast family in Wine | Landed — same *class* of "kernel anti-cheat needs an executive primitive" fix **[CONFIRMED]** |
| **`donnaskiez/ac`**, **`LaggyTMD/nte-driver-analysis`** | RP/analysis of Tencent ACE drivers | Documented that ACE user-mode injection carries most of the load and the `.sys` is one of several | Background only **[CONFIRMED: read]** |

Two independent conclusions fall out of this:

1. **Every "missing export" fix on record is a by-product, not the cure.** The pattern
   `wine: Call … to unimplemented function ntoskrnl.exe.X` is the *symptom that surfaces
   first*; the anti-cheat always has a *second* wall behind it (Proton #9331 is the clearest
   case). Endfield's new CORE has the bugcheck wall.
2. **No public project has yet fixed the `ACE-CORE` / `0x65636157` wall** — neither on Linux
   nor on macOS. So there is no patch to port; this is original work. `[CONFIRMED: no
   upstream/project hit for `0x65636157`]`

## 6. Ranked hypotheses for `KeBugCheckEx 0x65636157`

> **UPDATE (2026-10-15): H1 is CONFIRMED** — the check is on the **`DriverInit` return
> address** (kernel vs user space), and `dwproton/0004` defeats it. See §11. The table below
> is kept as the record of how it was narrowed down.

| # | Hypothesis | Evidence for | Evidence against | Test |
|---|---|---|---|---|
| **H1** | **Kernel-image integrity / anti-emulator check fails.** After `RtlPcToFileHeader` gives the ntoskrnl base, CORE validates a byte pattern (e.g. `MmGetVirtualForPhysical`), PE fields, `KeServiceDescriptorTableShadow`, or the IDT, and bugchecks when it can't. | Matches the exact trace position (`RtlPcToFileHeader(&PsProcessType)` → bugcheck); matches the "Neac" RE's `DriverEntry`; explains why an *old CORE with no new imports* also bugchecks. | The bugcheck is *during* init, so the precise failing compare is not yet identified. | Frida/LD_PRELOAD-style trace of `RtlCompareMemory`/`MmGetSystemRoutineAddress`/`RtlImageNtHeader` during CORE load, on the Mac, and dump the compared buffers. |
| **H2** | **Missing executive primitives make a pointer NULL/invalid, and CORE treats that as tamper.** `KeIpiGenericCall`, `KeGetProcessorNumberFromIndex`, affinity APIs resolve to the Wine `0xF600xx` stub (IAT) or NULL (`MmGetSystemRoutineAddress`); CORE checks the pointer lies inside `ntoskrnl`. | The seven imports; the `MmGetSystemRoutineAddress` list in the RE; ACE resolving-and-checking its API pointers is documented. | Old CORE imports **none** of the seven and still bugchecks (though it may resolve them at runtime via `MmGetSystemRoutineAddress`). | Implement/stub the seven (cheap) and re-run; if it still bugchecks, H2 is refuted. |
| **H3** | **CrossOver 26.3 / Rosetta-specific.** Something about the x86_64-under-Rosetta Wine or the `KeBugCheck` path differs from Linux (where BASE still worked). | macOS-only failure; Rosetta mitigations already needed for stage 1. | A second reporter sees the analogous wall; the Linux BASE/CORE story may already be heading the same way. | Compare a Linux `dwproton-11.0-14` run against the new CORE (does Linux also bugcheck now?). |
| **H4** | **Wine/CrossOver is *detected* as an emulator via CPU/IDT/timing and CORE refuses.** | ACE's job; Rosetta spoofing doc (07). | Old BASE ran on Wine without an emulator check firing; but CORE is a new generation. | Trace what CORE reads (CPUID, IDT, `KUSER_SHARED_DATA`, `RtlGetVersion`). |

H1 is the leading hypothesis because it uniquely explains the **"old CORE, no new imports,
same bugcheck"** observation *and* the trace position. H2 is cheap to falsify and should be
done first anyway (it also silences the loader warnings).

## 7. Experiment plan (settle H1 vs H2)

1. **Reproduce with a clean, instrumented runtime.** Use `scripts/01-capture-failure.sh`
   with `WINEDEBUG=+ntoskrnl,+module,+loaddll,+relay` (filtered) so the *exact* call
   immediately before `KeBugCheckEx` is visible, not just the import warnings.
2. **Falsify H2 (cheap, do first):** implement the seven exports (§8) and re-run. If the game
   still `KeBugCheckEx 0x65636157`s, H2 is out.
3. **Instrument the checks (H1):** hook `ntoskrnl`'s `RtlCompareMemory`, `RtlImageNtHeader`,
   `MmGetSystemRoutineAddress`, and `RtlPcToFileHeader` (Wine `+relay` or an LD_PRELOAD-style
   shim in the macOS build) and log arguments/results during CORE load. The RE predicts a
   failing `RtlCompareMemory` against a code signature.
4. **Diff the emulated kernel surface into a report:** `KeServiceDescriptorTableShadow`,
   IDT, PE `TimeDateStamp`/`CheckSum` of Wine's `ntoskrnl.exe`, versus the values a real
   Windows kernel would present. Whatever CORE reads that doesn't exist will stand out.
5. **Only then** write the targeted fix (a spoof/emulation in Wine — cf. stage-1's
   `signal_x86_64.c` work), and re-test end to end on the reference Mac.

## 8. Patch plan — the missing exports (necessary plumbing; probably *not* sufficient)

**✅ IMPLEMENTED (staged, compiles; needs a hardware test).** The new imports live in
[`patches/stage2-dwproton/ace-core/0001-ntoskrnl-Implement-ACE-CORE-new-imports.patch`](../../patches/stage2-dwproton/ace-core/0001-ntoskrnl-Implement-ACE-CORE-new-imports.patch)
(applied by `scripts/build-wine.sh` between the `misc` and `stage1-macos` sets). It adds each
export to `ntoskrnl.exe.spec` and a faithful / semi-stub implementation to `ntoskrnl.c` /
`sync.c`. Verified to `git apply` cleanly on the whole series and to compile
(`make dlls/ntoskrnl.exe/all`). This is the §5 "necessary plumbing" — the actual bugcheck fix
is `ace-core/0003` (see §11), not this.

What `0001` implements:

- `dlls/ntoskrnl.exe/sync.c`
  - `KeTryToAcquireGuardedMutex(PKGUARDED_MUTEX)` → non-blocking acquire:
    `InterlockedDecrement`; success if the result is ≥ 0, otherwise restore the count and
    return `FALSE`. (Cf. Wine MR 2044.)
- `dlls/ntoskrnl.exe/ntoskrnl.c`
  - `PsGetCurrentThreadTeb(void)` → `return NtCurrentTeb();` (the caller's own TEB; avoids
    needing a new `teb` field on Wine's `struct _KTHREAD`).
  - `KeGetProcessorNumberFromIndex(ULONG, PPROCESSOR_NUMBER *)` → validates against
    `KeQueryActiveProcessorCountEx(ALL_PROCESSOR_GROUPS)`, fills `Group=0`, `Number=index`,
    returns `STATUS_SUCCESS` / `STATUS_INVALID_PARAMETER` (Etaash-style semi-stub, sufficient
    for enumeration).
  - `KeSetSystemGroupAffinityThread(PGROUP_AFFINITY, PGROUP_AFFINITY)` /
    `KeRevertToUserGroupAffinityThread(PGROUP_AFFINITY)` → query/set thread group affinity via
    `NtQuery/SetInformationThread(…, ThreadGroupInformation, …)`, saving/restoring the
    previous affinity (mirrors Wine's existing `KeSetSystemAffinityThreadEx`).
  - `KeIpiGenericCall(fn, ctx)` → synchronous fallback `return fn(ctx);` (as in Etaash's fork,
    where the real cross-CPU broadcast is `#if 0`; a semi-stub that never blocks on an IPI we
    cannot deliver).
  - `ObDereferenceObjectDeferDelete(obj)` → `ObDereferenceObject(obj);` (the documented
    deferral to a worker thread is an optimisation; a direct deref is a faithful semi-stub).
  - `KeGetCurrentIrql(void)` → `return 0;` inside the existing `#ifdef __x86_64__` block
    (dw-proton misc `0008` stub).
- `dlls/ntoskrnl.exe/ntoskrnl.exe.spec` — exports each as `@ stdcall …`.

Not (yet) included: `PsGetProcessExitStatus` remains Wine's `@ stub` (the pre-existing
known residual); a real `STATUS_PENDING` implementation is a trivial follow-up if the abort
there proves to matter.

Also not included (candidate follow-ups, only add if instrumentation shows CORE touching
them): the "Neac" RE lists `MmGetSystemRoutineAddress` lookups Wine still doesn't export —
`KeIsExecutingDpc`, `KeRegisterProcessorChangeCallback`,
`KeDeregisterProcessorChangeCallback`, `KeInvalidateAllCaches`,
`MmAllocateContiguousNodeMemory` — which currently resolve to `NULL` for the driver.

> ⚠️ **Do not upstream any Endfield-specific work to dw-proton** (their `AGENTS.md` is explicit:
> anti-cheat research belongs to the other project; see the repo note in §9). Keep all of this
> in FineWine's `patches/`.

## 9. Where this leaves the project

- The stage-1 protector fix and the stage-2 dw-proton backports got Endfield **to login** on
  an earlier ACE. The Oct-2026 update moved the goalposts to a **kernel-image-integrity-
  hardened CORE driver** whose failure is a *deliberate* ACE bugcheck, structurally different
  from the missing-export aborts the project has solved before.
- This is the same *shape* of problem as stage 1 (protector rejects Wine's environment →
  need a Wine-side emulation), and the same investigated method applies: capture, instrument,
  identify the single failing check, then spoof it surgically.
- It is **not** guaranteed winnable — ACE can always add another check; the project's own risk
  register ([08](08-risks-unknowns-open-questions.md)) flags "ACE runs a check no user-space
  patch can satisfy" as the existential risk. **This round was winnable:** the check was the
  `DriverInit` return-address kernel-bit test (H1), and the downstream fork already defeats it
  plus the `lsass.exe` requirement (§11). Adequate *user-space* fixes exist; there is no
  evidence of a hard kernel wall.

## 10. Sources

New in this doc:
- Endfield_FineWine issue **#43** — the regression report + two independent investigations
  (`LANCYPANCY`'s controlled CORE-vs-BASE comparison; `Shalistera`'s WoA `ACE-CORE.sysa`
  observation). <https://github.com/stoicswe/Endfield_FineWine/issues/43>
- xia0ji233, **"某FPS游戏反作弊分析"** (2026-03-05) — RE of a "Neac"-generation ACE kernel
  driver: `DriverEntry` order, `MmGetVirtualForPhysical` signature check, API list,
  `KeServiceDescriptorTableShadow`, IDT `KiPageFault`, `KeIpiGenericCall` IPI scans.
  <https://xia0ji233.github.io/2026/03/05/Game7/index.html>
- Valve **Proton issue #9331** — "Implement `KeTryToAcquireGuardedMutex`/`KeAcquireGuardedMutex`/
  `KeReleaseGuardedMutex`"; upstream Wine **MR 2044**; maintainer: cherry-picks "not enough".
  <https://github.com/ValveSoftware/Proton/issues/9331>
- Wine bug **49224** — Denuvo `KeGenericCallDpc`/`KeSignalCallDpc*` (analogous executive
  primitive gap). <https://bugs.winehq.org/show_bug.cgi?id=49224>
- `Etaash-mathamsetty/wine-ntoskrnl` — reference implementations (`KeGetProcessorNumberFromIndex`,
  `KeIpiGenericCall`, instruction emulation). <https://github.com/Etaash-mathamsetty/wine-ntoskrnl>
- dw-proton issue **#30** (Endfield `PsGetProcessExitStatus`). <https://dawn.wine/dawn-winery/dwproton/issues/30>
- Wine MR **2044** (guarded-mutex implementations, merged upstream). <https://gitlab.winehq.org/wine/wine/-/merge_requests/2044>
- `LaggyTMD/nte-driver-analysis` (Tencent ACE driver roles). <https://github.com/LaggyTMD/nte-driver-analysis>
- **`mary-ext/crossover-wine-endfield`** — the downstream fork that fixed ACE-CORE (patches
  below). <https://github.com/mary-ext/crossover-wine-endfield>

Existing sources are consolidated in [references.md](references.md).

## 11. The downstream fix — ported into `patches/stage2-dwproton/ace-core/`

`mary-ext/crossover-wine-endfield` (forked from this project) already runs the new ACE-CORE.
It fetches **pinned commits** from `dawn.wine/dawn-winery/wine-dwproton` branches `_upstream`
(Wine backports) and `_dw` (dw-proton game patches) via
`scripts/fetch-wine-patches.sh`, then applies `upstream/* → dwproton/* → macos/*`.

**Status: the ACE-CORE fix is ported into this repo** as
`patches/stage2-dwproton/ace-core/0002…0007` (see [patches/README.md](../../patches/README.md)).
The whole series (31 patches) applies cleanly, and `ntoskrnl.exe`, `lsass.exe` and
`wineboot.exe` build (`make dlls/ntoskrnl.exe/all programs/lsass/all programs/wineboot/all`).

| # | Ported as | Downstream id | What it fixes for ACE-CORE |
|---|---|---|---|
| **1** | `ace-core/0003` | `dwproton/0004` (`09a9cb034e`) | **`KeBugCheckEx 0x65636157`** — sets bits 48–63 of the `DriverInit` return address so ACE's "invoked by the kernel?" check passes. Also patches `instr.c` (`vectored_handler` kernel-bit `Rip` fixup). |
| **2** | `ace-core/0007` | `macos/0007` | ACE-CORE scans the process list for `lsass.exe` and fails `DriverInit` without one. Adds `programs/lsass` + starts it from `wineboot`; ships `lsass.exe` + a patched `wineboot.exe`. |
| 3 | `ace-core/0005` | `dwproton/0006` (`4acd1acf8a`) | `DriverExtension->ServiceKeyName` / keyname passed to `DriverInit` must be the bare service name, not the full registry path. |
| 3 | `ace-core/0004` | `dwproton/0005` (`593daa15ba`) | `MmCopyMemory` export (stub) + `MM_COPY_ADDRESS` in `wdm.h`. |
| 5 | `ace-core/0002` | `upstream/0006` | Update the driver security cookie once relocation has happened. |
| 5 | `ace-core/0006` | `macos/0005` | Real `PsGetProcessExitStatus` (was a `@ stub`). |
| 4 | `ace-core/0010` | `dwproton/0007` (`84407729bf`) | Keep section views mapped while a locked MDL uses them (see §13). |
| 4 | `ace-core/0014` | `dwproton/0008` (`dac7007ad0`) | `PsGetContextThread` as a thunk around a helper. Without it ACE-CORE calls `KeBugCheckEx` before login. |
**Shipped-module changes.** Because ACE-CORE needs `lsass.exe` (absent from stock CrossOver)
and the patched `wineboot.exe`, the installers now carry five Wine modules. Updated:
`scripts/build-wine.sh` (`MODULES`), `scripts/package.sh`, `scripts/apply-modules.sh`,
`scripts/swap-into-crossover.sh`, and the `patcher-app` payload
(`PatcherEngine.swift`, `build-app.sh`). `lsass.exe` is installed as a *new* file
(stock CrossOver has none; the swap helpers allow that for this one module).

**⚠️ Hardware test still required.** Compilation is verified; actual launch has not been
re-tested here. Deploy and run with `WINEDEBUG=+ntoskrnl,+module,+loaddll`: the
`import_dll` warnings for the seven exports should be gone, and `KeBugCheckEx 0x65636157`
should no longer appear. For an existing bottle, ensure `wineboot` re-runs so the `lsass.exe`
stub is started (recreate the bottle, or run `wineboot`/restart the bottle).

---

## 12. Hardware test (2026-10-15): bug check gone, new "security component" wall

Tested on a real Apple‑Silicon Mac (M‑series) with a patched `CrossOver_Endfield_Patch.app`
(the `ace-core` series above deployed) and a fresh bottle `Arknights Endfield`, launching
`Endfield.exe` both **directly** and **through the Gryphline launcher (`Games.exe`)**.
Captured with `CX_LOG` and `WINEDEBUG=+ntoskrnl,+module,+loaddll,+seh,+process`.

### 12.1 The bug check is fixed `[CONFIRMED]`

- **No `KeBugCheckEx 0x65636157`**, no `unimplemented` imports — the import warnings for the
  seven exports are gone.
- `lsass.exe` (the stub from `ace-core/0007`) **starts** and stays up.
- ACE‑CORE loads (`ACE-CORE1024303.sys`, `ACE-CORE2024303.sys`) in `winedevice.exe` hosts and
  runs past `DriverInit`; its only faults are two handled reads of
  `KUSER_SHARED_DATA.TickCount` (`0xFFFFF78000000320`), which Wine's `ntoskrnl` vectored
  handler emulates. ACE user‑mode also loads (`ACE-Base64.dll`, `ACE-Service64.exe`,
  `ACE-Setup64.exe`, `ACE-Base.dat`).

**This is further than the reports in issue #43**, which stop at *"unable to load driver"
`(1-1720-1000015145)`*; we now reach a later ACE stage.

### 12.2 New fix ported: kernel objects for **tokens** and **directories** `[CONFIRMED]`

The ACE‑CORE driver opens a kernel object for **every process token** it enumerates. Stock
CrossOver's `wineserver` refuses this:

```
fixme:ntoskrnl:kernel_object_from_handle No constructor for type L"Token"
fixme:ntoskrnl:alloc_kernel_object set_object_reference failed: 0xc0000008
fixme:ntoskrnl:ObReferenceObject failed to grab 0x000000003FD10 reference
```

- Added `patches/stage2-dwproton/ace-core/0008` (token) + `0009` (directory), ported from the
  downstream's `upstream/0024` + `0002` (`server/token.c`, `server/change.c` —
  `get_kernel_obj_list` instead of `no_kernel_obj_list`).
- **The `wineserver` must be shipped for this to take effect** (unlike the other modules,
  this change is in the server, not a DLL). Added `server/wineserver` to
  `scripts/build-wine.sh` `MODULES`, `scripts/package.sh`, `scripts/apply-modules.sh`, and
  `scripts/swap-into-crossover.sh` (CrossOver ships the same binary at both `bin/wineserver`
  and `CrossOver-Hosted Application/wineserver` — both are replaced and ad‑hoc signed).
- After deploying: **`set_object_reference failed` is gone**. (The remaining
  `No constructor for type L"Token"` line is an informational `FIXME` — the object is then
  allocated and now succeeds.)

### 12.3 The new wall: ACE Center `(1-1812-1020)` `[CONFIRMED]`

The game now shows ACE's own dialog and exits (launcher and direct paths are identical):

> **ACE Center** — *"An exception occurred when the game security component was running,
> please close unnecessary software or other games, or restart the machine and try again."*
> `(1-1812-1020)`

Evidence from the captured runs:

- The game main thread sits in the `EndfieldBase.dll` protector (`0F 1F` NOP skips), loads
  `msimg32.dll`, then builds the error dialog (`blue_button_bmp`, `RtlCaptureStackBackTrace`).
- No Wine‑level crash: no unhandled fault in any ACE module; no `unimplemented function …,
  aborting` (so this is **not** the `msimg32.dll.AlphaBlend` abort from GE‑Proton #433).
- `ACE-Setup64.exe -install -g24303` and `ACE-Service64.exe -autorun` both run and exit
  cleanly ~1 s later, immediately before the dialog.

### 12.4 `ACE-Helper.exe` is missing and nothing creates it `[CONFIRMED]`

The game calls `CreateProcessInternalW` for
`…\AntiCheatExpert\ACE-Helper.exe 5000 3`, but:

- **No `NtCreateUserProcess`** results (the launch fails — the file does not exist).
- The file exists **nowhere** in the bottle, and **no new `.exe` is created** anywhere during
  a launch (whole‑bottle sweep after the run).
- The launcher's own integrity check reports **1690/1690 files present**, so `ACE-Helper.exe`
  is **not a game file** — ACE itself is expected to produce/install it.
- **`fs_usage -f filesys` (definitive):** during a full launch the *only* file the game writes
  into the bottle is a 22‑byte hex token in `…/AppData/Local/Temp/onominan.tmp`; the only
  `ACE-Helper.exe` events are six `fstatat64` existence checks by `Endfield.exe`. Nothing
  creates, renames, or extracts a helper binary **anywhere**. The "self‑extracting image /
  write‑file" hypothesis is therefore **disproven** for this component.

This is the strongest concrete lead for `(1-1812-1020)`: an ACE helper component the game
expects to be installed, which Wine never produces.

### 12.5 Tooling limitation: file/network channels are unavailable

`WINEDEBUG=+file`, `+wininet`, `+ws2_32`, `+relay` produce **no output** in this build (a
trivial `dir` gives 8089 lines but 0 `:file:` lines) — only `ntoskrnl/seh/module/process/
loaddll` emit. **File and network operations are therefore not observable via `WINEDEBUG`
here.** Use an OS‑level tracer instead: **`sudo fs_usage -f filesys` works** and was used for
the §12.4 result (`sudo -v` first so the backgrounded `sudo fs_usage` reuses the ticket; the
output buffers, so let it run its full window before stopping it).

### 12.6 Open questions / next steps

1. Does `…\AntiCheatExpert\ACE-Helper.exe` exist on a Windows or Parallels‑WoA install? If
   yes, where does it come from (shipped by the game, or written by ACE)? A trustworthy
   Windows reference install (e.g. Parallels, per issue #43) would settle this quickly.
   **Network probe (2026-10-15):** `sudo fs_usage -f network` prints no remote addresses
   (only local `mDNSResponder`/launchd socket connects); the ACE binaries contain **no
   download URLs** (only DigiCert OCSP/CRL), so there is **no evidence ACE downloads the
   helper**. `tcpdump 'udp port 53'` captured 0 packets on this host (PKTAP/BPF quirk) —
   re‑try with `-i en0` if a DNS answer is needed.
2. If it is a **self‑extracted image**, confirm the source container (`ACE-Base64.dll` has
   four `This program cannot be run in DOS mode` strings, but only its own valid MZ/PE header
   was found, so a naive embedded‑PE scan does not locate them — the container is likely
   packed/encrypted). Then look for a Wine write/execute mismatch on the extracted file.
3. DW‑proton (`dwproton/patches/wine`) runs Endfield's ACE fine on Linux; if #1 shows the
   helper is produced there, diff the relevant DW‑proton patch. Note `dwproton/0007`
   (keep section views mapped while a locked MDL uses them) + `upstream/0037–0042` are the
   only DW‑proton patches **not** ported here (§11) — worth re‑testing if the failure turns
   out to be an MDL/section‑view issue.

---

## 13. The MDL/section‑view fix (2026‑10‑15): a real advance to a new ACE wall

The §12.6 lead was right: the failure was an **MDL/section‑view** issue, not a missing file.

### 13.1 What ACE‑CORE actually does `[CONFIRMED]`

The driver host (`winedevice.exe`) calls, in sequence:

```
fixme:ntoskrnl:MmProbeAndLockPages (mdl, 1, 2): stub
fixme:ntoskrnl:MmMapLockedPagesSpecifyCache (mdl, 0, 1, NULL, 0, 32): stub   <-- returns NULL
fixme:ntoskrnl:MmUnlockPages (mdl): stub
```

CrossOver 26.3's `ntoskrnl.exe` has these as **stubs** (`MmMapLockedPagesSpecifyCache`
returns `NULL`; `MmProbeAndLockPages`/`MmUnlockPages`/`MmUnmapLockedPages` do nothing;
`MmBuildMdlForNonPagedPool` does nothing). ACE dereferences the `NULL` map pointer — the
"exception in the security component".

> Note: `ntoskrnl.exe.spec` lists these as `@ stdcall` (not `@ stub`), so a spec‑only
> cross‑diff is misleading — the *bodies* are stubs. Verify against the source.

### 13.2 The fix `[CONFIRMED]`

Ported `upstream/0037,0039,0040,0042` (the MDL implementations) + `dwproton/0007`
(keep section views mapped while a locked MDL uses them) as
**`patches/stage2-dwproton/ace-core/0010`**. They conflict as raw patches (our base is
newer), so the change was applied by hand and re‑exported as a clean patch.

- `MmProbeAndLockPages`/`MmUnlockPages` set/clear `MDL_PAGES_LOCKED`.
- `MmBuildMdlForNonPagedPool` sets `MDL_SOURCE_IS_NONPAGED_POOL` + `MappedSystemVa`.
- `MmMapLockedPagesSpecifyCache` → `MmMapLockedPages` (real `StartVa + ByteOffset`).
- `MmUnmapLockedPages` clears `MDL_MAPPED_TO_SYSTEM_VA`.
- `dwproton/0007`: `ZwUnmapViewOfSection` defers unmapping a view while a locked MDL maps
  it (`mapped_views` list; `add_mapped_view` on `MmMapLockedPages`, `remove_mapped_view` on
  `MmUnmapLockedPages`/`IoFreeMdl`).

### 13.3 Effect on hardware `[CONFIRMED]`

| Stage | Unhandled write fault `0x10042AA83` → `0x7FF001D40188` | Bug check |
|---|---|---|
| Before (stubs) | present | none (ACE error dialog) |
| MDL impls only | present | `0x65636154` ("Tace") |
| + `dwproton/0007` | **gone** | `0x65636154` ("Tace") |

So the NULL deref and the section‑view write fault are both fixed. ACE‑CORE now
*deliberately* `KeBugCheckEx 0x65636154` (**"Tace"**, little‑endian ASCII) — a **new, later**
wall than the original `0x65636157` ("Wace") `DriverInit` check. (`0x6563615x` decodes to
the four‑byte strings "Wace"/"Tace".)

**Still open:** what `"Tace"` checks. The bug check fires on the driver host's watchdog
thread ~0.3 s after the process‑enumeration + KUSER_SHARED_DATA phase, with no preceding
unhandled fault — so it looks like another ACE anti‑emulator/consistency check. `/tmp/ef-mdl3.log`
has the full trace.

### 13.4 Small missing pieces ported (no change to the wall)

Ported the downstream's remaining non‑test ntoskrnl bits as **`ace-core/0011`**
(`FsRtlGetFileSize`, `PsGetProcessPeb`, `PsDereferencePrimaryToken`, `KdChangeOption` stub) —
all four were stubs/missing here. Result: **no change** — still `KeBugCheckEx 0x65636154`
("Tace"), identical exception list. They were added for parity with the downstream.

Just before the `"Tace"` bug check, the driver host also registers a filesystem minifilter:

```
fixme:fltmgr:FltRegisterFilter ...
fixme:fltmgr:FltStartFiltering (00000000DEADBEAF): stub
```

`dlls/fltmgr.sys` returns a fake filter handle and "success" (the downstream does not touch
fltmgr), so `"Tace"` is not simply "the filter failed to start". Tested (negative): a stub
`ACE-Helper.exe` (the `lsass.exe` stub copied into `AntiCheatExpert\`) makes the game's
`CreateProcess`/`NtCreateUserProcess` succeed and the process stay resident, but
`KeBugCheckEx 0x65636154` **still fires**. So ACE‑Helper's absence is not the trigger.

**Next for `"Tace"`:** a Windows/Parallels reference trace of `ACE-CORE` reaching this stage
(the trigger looks like another deliberate anti‑emulator/consistency check, possibly tied to
the `FltRegisterFilter`/`FltStartFiltering` minifilter handshake, which Wine stubs).

### 13.5 What the wider community has (and hasn't) solved (2026‑10‑15)

Searched DW‑proton (the known‑good Linux reference), the GE‑Proton tracker and the web. There
is **no documented fix for `0x65636154` ("Tace")** anywhere — this is past what anyone has
posted. The relevant prior art:

- **DW‑proton #55 (NIKKE)**: ACE *"Unable to load driver"* after a client patch; fixed in
  `dwproton-11.0-13`. Its release notes say the fix *"should also apply to other games if/when
  they get similar updates"* — and it **is** the upstream MDL + section‑view patch group we
  ported as `ace-core/0010`. So the documented Endfield/NIKKE ACE fix is already in.
- **DW‑proton #64 (Arknights: Endfield, Exit 222)**: blamed `Inbv*` /
  `PsGetProcessExitProcessCalled` stubs — **rejected as AI slop** (the real cause was the
  reporter's own launch command; vanilla worked).
- **DW‑proton #66 (CODM)**: after fixing driver load, ACE hit `IoGetBaseFileSystemDeviceObject`
  — closed (competitive game, unsupported).
- **DW‑proton #34 (CZN)/#30 (Endfield)** and **DW‑proton #10 (NTE)**: the same "Unable to load
  driver" / `Token` kernel‑object logs we saw; #10's resolution was unrelated (Wayland driver).

### 13.6 Parity stubs added (`ace-core/0012`)

Implemented the exports those reports name, which this base still has as `@ stub` (and a
`@ stub` aborts via `__wine_spec_unimplemented_stub` if a driver calls it): the `Inbv*` family,
`PsGetProcessExitProcessCalled`, `SeQueryInformationToken`, and
`IoGetBaseFileSystemDeviceObject`. Tested: **no change** — none of them are actually called in
our run (0 stub aborts), so this is hardening for other ACE builds, not the `"Tace"` fix.

**Conclusion:** `"Tace"` remains undocumented. The next real step is a Windows/Parallels
reference trace of `ACE-CORE` reaching this stage.

### 13.7 Aligned em-backports to current upstream (`ace-core/0013`)

Cross-diffed our `em-backports/*` against the downstream's current `upstream/*` series (the
reorg in `mary-ext@a0ebeae`). Every downstream function is present; the implementations
differed in ~10 places, mostly cosmetic/win64‑equivalent (e.g. `FASTCALL` calling convention).
Ported the semantically-different ones to the current upstream versions:

- `PsGetContextThread` → 3‑arg `(PETHREAD, CONTEXT*, KPROCESSOR_MODE)` (spec `(ptr ptr long)`).
- `PsReferencePrimaryToken` → open the token (`NtOpenProcessToken` + `ObReferenceObjectByHandle(SeTokenObjectType)`).
- `SeLocateProcessImageName` → `NtQueryInformationProcess(ProcessImageFileName)` via `ObOpenObjectByPointer`.
- `MmGetPhysicalMemoryRanges` → allocated 2-range array with a **byte** base address (`MmLowestPhysicalPage * PageSize`); the old code returned a page number as the base.
- `KeAcquire/ReleaseGuardedMutex[Unsafe]` + `KeInitializeGuardedMutex` → `FASTCALL` + `DEFINE_FASTCALL1_WRAPPER` (+ `-fastcall` spec).

Tested: **no change** — still `KeBugCheckEx 0x65636154` ("Tace"). So the `em-backports`↔
`upstream` delta is *not* the residual cause; this is parity/correctness work.

**Net:** the load-bearing part of `mary-ext@a0ebeae` (the upstream MDL impls + `dwproton/0007`)
was already in as `ace-core/0010`, and the remaining differences don't explain `"Tace"`.

### 13.8 Dynamic tracing attempt (2026‑10‑15): too invasive to observe `"Tace"`

Instrumented Wine to get the answer from the runtime:

1. **Backtrace at the bug check.** `KeBugCheckEx` (which just logs + `ExitProcess(code)`)
   was made to dump `RtlCaptureStackBackTrace`, giving the call chain:
   `ntdll/kernel32 thread start → ACE-CORE+0x192783 → ACE-CORE+0x1C7033 → KeBugCheckEx(0x65636154)`
   (ACE-CORE mapped at `0x100400000`). So `"Tace"` is raised from an ACE-CORE **worker thread**
   inside the packed `.tvm0` section (`RVA 0x1C7033`, caller `0x192783`).
2. **Live code dump** at those frames (raw bytes → `x86_64-w64-mingw32-objdump`) shows the code
   is **VMProtect/TenProtect-virtualized**: `movabs` opaque constants + `pushfq`/`add`/`popf`
   opaque predicates + `jmp reg` computed dispatches + `call rel32` into VM offsets. There is no
   readable check, and the `"Tace"`/`"Wace"` constants are not in the image (computed at runtime).
3. **Single-step RIP tracer.** Added a `FINE_WINE_VMTRACE` (env or `C:\vmtrace`) single-step
   tracer to the `ntoskrnl` vectored handler (ring buffer of RIPs, dumped at `KeBugCheckEx`).
   Result: with stepping active, ACE **never reaches `Tace`** — it fails earlier with
   **"Unable to connect to ACE service" `(1-1705-0)`**. The ~1000× slowdown trips ACE's own
   service‑connection timeout. So full single-step tracing is *self‑defeating* here.
   (Also: `WINEDEBUG`/env vars don't reach the driver host, so its per‑single‑step `+seh` logging
   ballooned the log to ~3.9 GB for ~0 observable benefit.)

**Conclusion:** `"Tace"` is a deliberate, virtualized self-check that can't be observed by
in‑process single-stepping without changing ACE's behaviour. Combined with §13.7, there is no
practical Wine-side lever left; a Windows/Parallels reference trace (or upstream coordination)
is the realistic path. The tracer was reverted.
