# 12 — Stage 1: the `EndfieldBase.dll` protector fault (the critical path)

> The macOS-specific blocker that must be cracked before dw-proton (stage 2) matters. Background: [10](10-milestone-1-results.md) (capture), [11](11-linux-vs-macos-comparison.md) (Linux vs macOS). **Updated 2026-07-14 with a prior-art hunt + Wine-source analysis — the mechanism is now understood and there is a concrete #1 experiment.**

## ✅ SOLVED (2026-07-14): Rosetta rejects a plain NOP; skip it

Built a custom x86_64 CrossOver-26.2 Wine, reproduced the fault, instrumented the illegal-instruction handler to log the faulting bytes, and found the root cause. **It was simpler than the AVX-512 hypothesis** (which was wrong).

**The exception sequence:** before the `0x6CD268` execute-fault, the first exception is an **`EXCEPTION_ILLEGAL_INSTRUCTION` (c000001d)** inside `EndfieldBase.dll`'s `.tvm0` (VMProtect VM). The protector's SEH handler processes it and, during its unwind, jumps to `0x6CD268` → the collided-unwind loop → stack overflow. So `0x6CD268` is the protector's mis-computed recovery from an illegal instruction; the illegal instruction is the root cause.

**The instruction (captured via instrumentation):**
```
0f 1f c1   =   nop ecx   (multi-byte NOP, group 0F 1F /0)
```
**Rosetta 2 raises an illegal-instruction fault on a plain NOP.** Wine's `segv_handler` (`TRAP_x86_PRIVINFLT`) already has a CrossOver hack, `handle_cet_nop`, that skips CET-space `0F 1E` (RDSSP) NOPs Rosetta wrongly faults on — **but it has no case for `0F 1F`.** So our NOP fell through to `c000001d`. VMProtect emits `0F 1F` NOPs *pervasively* (23,227 of them fire in one launch), and each one Rosetta rejects.

**The fix** (`patches/stage1-macos/`, applied to `dlls/ntdll/unix/signal_x86_64.c`): add a `case 0x1F` to `handle_cet_nop` that decodes the multi-byte NOP's length (modrm + optional SIB + displacement) and advances `RIP` past it. A `0F 1F /0` NOP has **zero side effects**, so skipping it is semantically exact and safe.

**Result:** `c000001d` = 0, `0x6CD268` = 0, stack overflow = 0. **The protector runs, and ACE fully loads** — `ACE-Base64.dll`, `ACE-Setup64.exe`, `ACE-Service64.exe`, and the kernel driver `ACE-BASE.sys` (registering `\Device\ACE-BASE`). **This is exact parity with working Linux/dw-proton** — the game then hits the *stage-2* `ntoskrnl.exe.KeAcquireGuardedMutex` abort that dw-proton's em-backports fix ([02](02-dwproton-ace-patches.md), [11](11-linux-vs-macos-comparison.md)).

**Why this matters generally:** this is a Rosetta-2 NOP-handling gap that affects *any* VMProtect/TenProtect-protected game under CrossOver on Apple Silicon (cf. Bug 45083). The fix belongs upstream in CrossOver's `handle_cet_nop` alongside their existing `0F 1E` case.

> The AVX-512 / `emulate_xgetbv` hypothesis below was **wrong** — kept only as a record of the investigation. The actual instruction was a NOP, not AVX-512.

<details><summary>Superseded AVX-512 hypothesis (for the record)</summary>

Earlier reasoning suspected `emulate_xgetbv` over-advertising AVX-512 (`0xe7`) on macOS 15+, leading the protector to run an AVX-512 instruction Rosetta rejects. The instruction-byte capture disproved it (`0f 1f c1` is a NOP, not AVX-512).
</details>

## The fault (now fully mechanistically understood)

Inside the game process, `EndfieldBase.dll` (Tencent **TenProtect "tpshell"** runtime = VMProtect-style anti-tamper that runs **before** ACE; 35 MB image, 27 MB `.tvm0` VM section; preferred base `0x180000000`, relocated to `0x6FFFxxxx`) does anti-debug probes (`NtQueryInformationProcess` ProcessDebugPort/ProcessWow64Information/**ProcessExecuteFlags**), then — from inside its own SEH unwind handler at `EndfieldBase.dll+0x4b02d0` — **jumps to the constant absolute address `0x6CD268`, which is UNMAPPED on macOS**:

```
jmp 0x6CD268 (unmapped) → c0000005 EXECUTE fault (info[0]=8)
  → the fault happens INSIDE an RtlUnwindEx handler, so Wine's unwind_exception_handler reports it as a
     "collided unwind" and RESUMES the original unwind (this is correct, Windows-faithful behavior)
  → the resumed unwind re-invokes the handler continuation → re-jmps to the SAME 0x6CD268 → re-faults
  → each re-fault nests a fresh exception frame → after ~273 the guard page is hit →
     virtual_setup_exception "stack overflow" → abort_thread(1) → game relaunches → loop
```

### What the Wine-source analysis established (high confidence)
- **The collided-unwind loop and stack-overflow are portable C — byte-identical on macOS and Linux** (`dlls/ntdll/signal_x86_64.c` `unwind_exception_handler`, `RtlUnwindEx` collided case; `dlls/ntdll/unix/virtual.c` `virtual_setup_exception`). **Wine is NOT buggy here** — it faithfully resumes an unwind whose handler happens to re-fault. The loop is a *symptom*.
- **The root cause is that `0x6CD268` is mapped+executable on Linux but unmapped on macOS.** On Linux the `jmp` succeeds and control proceeds to ACE init; on macOS it re-faults forever. A Wine-side recursion cap would only turn the loop into one clean crash — **it would not make the game run.**
- **`info[0]=8` (execute-fault) survives only because DEP is ENABLED** in the process. `segv_handler` downgrades an execute-fault to a read-fault *unless* `NtQueryInformationProcess(ProcessExecuteFlags)` reports DEP enabled — and the protector's own anti-debug enables it. On macOS, `ERROR_sig` (the x86 page-fault error byte that yields bit `0x08`) is **synthesized by Rosetta 2**, not delivered by hardware — a prime macOS/Linux divergence point.
- The `~273` count differs from Linux partly because Apple Silicon uses **16 KB host pages** (fewer nested frames fit) vs Linux 4 KB.

## ⭐ Prior art (answering "has anyone hit this / added context")

**Yes — a near-exact, documented-but-UNFIXED analog:**
- **WineHQ Bug 45083** — a VMProtect-3.x 64-bit app (MetaTrader 5) that **runs fine on Linux Wine but faults on macOS Wine** with the **identical exception family**: recursive `c0000005` + `RtlUnwindEx` + "setup_exception stack overflow." STATUS **NEW**, empty "Fixed by" field; analyst conclusion: *"incompatibility of the software protection scheme with Wine on macOS."* This confirms our fault is a **known class** (VMProtect exception recursion under Wine-on-macOS), genuinely macOS-specific, and **never solved publicly**.
- **Bug 34254** — same terminal signature, different (generic C++ EH) root cause.
- **vinegar #382** — identical `virtual_setup_exception stack overflow … 0x6ffff…` kill for Roblox/Hyperion (another protector) in the same relocated range. Unfixed.
- **dawn issue #12** "macOS is detected as Virtual Machine" — VMProtect detects Wine-on-macOS as a VM (suspected CPUID/hypervisor-bit handling by Rosetta) where Linux doesn't. Adjacent.

**No public report shows our exact signature** (`0x6CD268` from `EndfieldBase.dll+0x4b02d0`) — but the mechanism is corroborated on all sides.

## ⚠️ Correction to an earlier assumption
Earlier docs said "on Linux the same protector runs fine." **The Linux control was dw-proton (PATCHED), not vanilla.** Vanilla/GE-Proton without the dw-proton tpshell hack *also* fails on Endfield (GE #433). So it is **not yet proven** that our fault is purely macOS-specific vs. simply the missing tpshell patch — and that ambiguity is exactly what the #1 experiment resolves. (Also: our earlier "no `KiUser*Dispatcher` GetProcAddress" claim is **unreliable** — we never ran `+relay`, and `GetProcAddress` calls only appear in relay logs. tpshell may well be resolving them.)

## The candidate FIX (we already have it staged)

The **dw-proton "workaround for tpshell"** int3 spoof — [patches/stage2-dwproton/misc/0009…](../patches/) + `0010…` (already fetched):
- In `dlls/kernel32/module.c` `get_proc_address()`, when the process is `Endfield.exe` and it resolves **`KiUserApcDispatcher`** or **`KiUserCallbackDispatcher`**, return a naked 4×`int3` (`0xCC`) stub instead of Wine's real dispatcher.
- **Why it plausibly fixes `0x6CD268`:** Wine's dispatchers differ from Windows in **both address and prologue bytes**. tpshell reads them and **computes a branch target from their contents/address** → under Wine it derives a *wrong constant target* (the shape of `0x6CD268`). The int3 stub short-circuits that computation with a controlled breakpoint the protector expects to catch in its own SEH.
- `#ifdef __x86_64__`-guarded → applies mechanically to CrossOver's x86_64-under-Rosetta tree.
- **This is the only known-good fix for this exact title on the reference platform.** It is despite our uncertainty the highest-probability single lever.

## Reprioritized experiments (Mac-only, ordered by information/cost)

**E1 — `+relay` trace, NO build (cheap, decisive for the fix hypothesis).**
Re-run with `WINEDEBUG=+relay,+seh,+virtual` (targeted — relay is huge; filter via `HKCU\Software\Wine\Debug` `RelayInclude`, or accept a large log and grep). Confirm whether tpshell calls `GetProcAddress("KiUserApcDispatcher"/"KiUserCallbackDispatcher")`, and capture the **first** collided unwind's handler `ControlPc` and the value it branches to (is `0x6CD268` computed from the dispatcher readback?). This tells us *before building anything* whether the int3 spoof is even applicable.

**E2 — Build + apply the int3 spoof, test (the #1 fix experiment).**
Build 64-bit CrossOver Wine ([scripts/build-wine.sh](../scripts/build-wine.sh)), apply `misc/0009+0010`, swap, run Endfield.
- **If it runs past `0x6CD268`** → root cause was the dispatcher-readback branch; the "macOS-specific" framing was largely an artifact; proceed to **stage 2** (the ntoskrnl/timing failures dw-proton also fixes).
- **If it still loops** → we've **isolated the macOS residual** to CrossOver's exception-delivery/memory-layout (E3/E4) — and *that* is a clean, specific bug report to send CodeWeavers (with Bug 45083 + the dw-proton patch as the Linux-works reference).

**E3 — Memory-layout: make `0x6CD268` valid (if E2 still loops).**
The productive lever if the target is genuinely computed as `0x6CD268`: ensure that low page is mapped/executable under CrossOver as it is on Linux. Likely tied to **CrossOver/Apple-Silicon lacking the Linux `wine-preloader` low-memory reservation**. Investigate the low-address map; try reserving/mapping the region.

**E4 — DEP / ProcessExecuteFlags (cheap, complementary).**
`info[0]=8` only survives because DEP is reported enabled. Patch/hook `NtQueryInformationProcess(ProcessExecuteFlags)` (or the segv_handler downgrade) so the execute-fault is reported as a read fault, and see if that matches Linux and dodges the fatal path.

**E5 — Rosetta synthesized-fields (last resort).**
If E2–E4 fail, the residue points at Rosetta synthesizing `ERROR_sig`/`EFlags.TF`/debug-register state differently than the Linux kernel, poisoning the protector's computed target. Instrument `ERROR_sig` and the CONTEXT fields; compare to a known-good Windows CONTEXT.

**E0 — housekeeping before trusting any trace:** confirm CrossOver 26.2/27's tree already contains the 2024 Tim Clem / CrossOver collided-unwind fixes `47f94fcf5f8e` + `a9843953156b` (context/xstate corruption on collided-unwind resume). If absent, they could mutate observed CONTEXT.

## Honest assessment (updated — more hopeful, still hard)
There is now a **concrete, staged, known-good-on-Linux candidate fix** and a cheap experiment (E1) to validate its premise before any build. Best case: the int3 spoof just works and stage 1 collapses. Worst case: it isolates a genuine, unfixed Wine-on-macOS VMProtect exception/memory bug (Bug 45083 class) — hard, but then we have a precise, well-evidenced report for CodeWeavers rather than a mystery. Either way E1→E2 is the path. Risk #1 (kernel wall) stays downgraded.

## Sources
- WineHQ Bug 45083 — <https://bugs.winehq.org/show_bug.cgi?id=45083> · Bug 34254 · Wine-Bug 56401
- dw-proton int3 spoof commits `c4dec62a…` + `dd60ea7312…` (staged in [patches/](../patches/))
- Wine `dlls/ntdll/signal_x86_64.c` (`unwind_exception_handler`, `RtlUnwindEx` collided case), `dlls/ntdll/unix/virtual.c` (`virtual_setup_exception`), `dlls/ntdll/unix/signal_x86_64.c` (`segv_handler`)
- CrossOver collided-unwind fixes `47f94fcf5f8e`, `a9843953156b` (Tim Clem / CodeWeavers, 2024)
- SteamDB TenProtect/ACE detection rules; dawn issue #12 (macOS-detected-as-VM)
