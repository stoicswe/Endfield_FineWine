# 10 — Milestone 1 results: the actual failure signature

> **Status: milestone 1 DONE.** This is the observation the whole roadmap was gated on. Captured 2026-07-14 on the real hardware. Supersedes the "unknown failure signature" caveat in earlier docs.

## Setup

| | |
|---|---|
| Hardware | Apple **M3**, macOS **26.5.2** (arm64) |
| CrossOver | **26.2.0** (release) and **27.0 Preview** (`cxpreview-20260702-rc1`) — both tested |
| Wine arch | **x86_64** (`wineserver` is `Mach-O x86_64`) → runs under **Rosetta 2**. ✅ confirms the config where the dw-proton `#ifdef __x86_64__` int3 hack compiles |
| Bottle | `Arknights Endfield`; `ProductName` already spoofed to **`Windows 11 Pro`** |
| Game | `C:/Program Files/GRYPHLINK/games/Arknights Endfield/Endfield.exe` (loads at `0x140000000`), plus `EndfieldBase.dll` (loads at `0x6FFFFC060000`) |
| Capture | `CX_LOG` + `--wait-children` via `scripts/01-capture-failure.sh` (a plain stderr redirect captures nothing — CrossOver's `bin/wine` is a Perl wrapper that detaches; see below) |

## The verdict

**The blocker is a protector (anti-tamper) exception-handling loop, NOT a kernel-driver wall and NOT a missing `ntoskrnl` function.** This is a **user-space-fixable class of problem** and is squarely on the dw-proton path. Risk #1 (categorical ACE force-quit) is **downgraded** by this evidence.

## What actually happens (direct `Endfield.exe` launch)

1. `Endfield.exe` and `EndfieldBase.dll` load fine (both `native`). **No ACE/`SGuard`/`gsp_core` module ever loads** — the failure precedes ACE bootstrap.
2. `EndfieldBase.dll` (the game's protected/anti-tamper base — VMProtect/TenProtect "tpshell") runs heavy **anti-debug / environment probing** via `NtQueryInformationProcess` (handle `-1`), hundreds of calls:

   | Class | Meaning | Hits |
   |---|---|---|
   | `0x07` | **ProcessDebugPort** (anti-debug) | 21 |
   | `0x1a` | **ProcessWow64Information** (arch/env detection) | 71 |
   | `0x22` | **ProcessExecuteFlags** (DEP state) | 137 |
   | `0x0c` | (debug/priority-related) | 350 |
   | `0x24`/`0x25` | ProcessCookie / image info | few |

3. Execution then **jumps to an invalid address `0x6CD268` and tries to execute it** → `EXCEPTION_ACCESS_VIOLATION (c0000005)` with `info[0]=8` (an **execute**/DEP fault, not a data read). `rip == 0x6CD268`; the caller unwinds through `EndfieldBase.dll`.
4. The protector's own SEH handler at **`EndfieldBase.dll+0x4b02d0` (`0x6FFFFC5102D0`)** catches it, but under Wine's exception dispatch it **re-enters itself repeatedly** — the log prints `unwind_exception_handler detected collided unwind` and re-invokes the same handler over and over.
5. This loops **273× `c0000005`** on one thread until `err:virtual:virtual_setup_exception stack overflow` — the thread dies from stack exhaustion.
6. The process then **relaunches** (a fresh `Endfield.exe` pid appears in the macOS log) — anti-tamper watchdog / re-exec behavior. No macOS `.ips` crash report is produced (it's a handled-exception loop, not an unhandled crash).

### One-line trace excerpts (from `~/endfield-debug/20260714-152216/cxlog.txt`)
```
seh:dispatch_exception code=c0000005 (EXCEPTION_ACCESS_VIOLATION) flags=0 addr=00000000006CD268
dispatch_exception  info[0]=0000000000000008     # execute-access fault
dispatch_exception  rip=00000000006cd268 rsp=...  # executing at the bad address
process:NtQueryInformationProcess (0xffffffffffffffff,0x00000022,...)   # DEP/anti-debug probe
seh:unwind_exception_handler detected collided unwind
seh:call_seh_handlers calling handler 00006FFFFC5102D0 ... returned 1   # EndfieldBase.dll handler, re-entered
err:virtual:virtual_setup_exception stack overflow 1984 bytes addr 0x6ffffff95a3d stack 0x10840 (0x10000-0x11000-0x110000)
```

## Interpretation

This is the **VMProtect/TenProtect exception-based obfuscation and anti-tamper** in `EndfieldBase.dll` (the "tpshell" the dw-proton comment names) not surviving Wine's exception-dispatch/unwind implementation. Protectors like this deliberately trigger execute-faults and drive control flow through their SEH/VEH handlers; when Wine's `KiUserExceptionDispatcher` / unwinding doesn't match Windows semantics exactly, the handler collides and loops. That is precisely the **problem class dw-proton fixes** with its `KiUser*Dispatcher` int3 spoof and related patches ([docs/02](02-dwproton-ace-patches.md)). So the macOS failure is **the same family** as the Linux one, and **user-space-addressable**.

## Milestone 1b — launcher path (CONFIRMED, run `20260714-152928`)

Ran through `GRYPHLINK/Launcher.exe` and clicked **Launch**. Result: **the game process dies in the identical `EndfieldBase.dll` loop** — same execute-fault at the **constant** address `0x6CD268` → collided unwind → stack overflow — and **retried 4 times** (4 stack overflows, 1092 `c0000005`, 261k log lines). Confirmations:
- **The launcher itself runs fine.** Full Qt5 / Qt5WebEngine / CEF stack, `CrashSight64.dll` (Tencent), `hgdownloadsdk.dll`/`hgeventlogsdk.dll`, `libcurl`, `Games.exe`, `QtWebEngineProcess.exe` all load. Only the **game child** crashes. This matches CodeWeavers' "launcher frame renders, then the app is force-quit."
- **Still no ACE module and no `ntoskrnl` unimplemented-function abort.** So the direct-`Endfield.exe` failure was **not** a launch-method artifact — it is the real blocker.
  - ⚠️ **Correction:** an earlier draft said "no `GetProcAddress("KiUser*Dispatcher")`." That is **unverified** — these runs used `+loaddll,+seh,+ntoskrnl`, and `GetProcAddress` calls only appear under `+relay`. tpshell may well resolve those dispatchers; see [docs/12](12-stage1-protector-fault.md) E1 (a `+relay` run to check).

### ⭐ New root-cause lead: image relocation / load-layout, not just exception dispatch
- `EndfieldBase.dll` has **preferred base `0x180000000`** and **Wine relocates it** every run (`relocating EndfieldBase.dll dynamic base 180000000 -> 6fffee950000`). That region is contended — Wine's own `ntoskrnl.exe` PE also has preferred base `0x180000000` and gets relocated too (`-> 6fffff710000`).
- The fault target `0x6CD268` is **constant across all runs even though `EndfieldBase.dll`'s runtime base changes** (`0x6ffffc060000` → `0x6fffef0…` → `0x6fffee950000`). So `0x6CD268` is **not** `EndfieldBase_base + offset` — it's a **fixed absolute address the protector assumes is valid**, and it's unmapped on Wine (the unwind shows `base 0 rip 6cd268` = no module). `Endfield.exe` itself loads at its preferred `0x140000000` (not relocated); `EndfieldBase.dll` does *not* get its preferred base.
- **Hypothesis:** the VMProtect/tpshell layer makes an absolute jump/allocation that is valid on Windows (where `EndfieldBase.dll` loads at `0x180000000` and/or a low region is available) but points to unmapped memory on Wine's win32on64 address-space layout after relocation. This is a **more specific and more testable** target than "generic exception dispatch," and it may explain why we never reach the `KiUser*Dispatcher` stage dw-proton patches.
- **This reframes the fix hypothesis:** the decisive experiment is now **milestone 3 (Linux dw-proton)** — does the *same* `EndfieldBase.dll` fault at `0x6CD268` on working Linux, or sail past? If it sails past, diff Wine's relocation / address-space / exception-dispatch handling between the two to pinpoint the fix. The dw-proton `KiUser*` int3 hack may be necessary only at a *later* stage we never reach here.

## Important caveats (do not over-conclude)

1. **Both runs used the same machine/CrossOver; neither had any dw-proton patch applied.** Hitting the protector loop on *stock* CrossOver is expected. What's not yet known is whether the dw-proton patch set (or a relocation fix) clears `0x6CD268` — that requires the Linux baseline (milestone 3) and a patched-Wine test (milestone 6).
2. **We did NOT observe `GetProcAddress("KiUserApcDispatcher"/"KiUserCallbackDispatcher")`** — the exact call dw-proton's int3 hack intercepts (0 hits). Either the direct launch faults before that stage, or CrossOver's Wine reaches the protector's exception machinery by a different route than Proton. So while this is the dw-proton *problem class*, it's **not yet confirmed that the specific int3 hack is the exact fix** on CrossOver. Milestone 3 (Linux bisect) + a patched-Wine test (milestone 6) will confirm.
3. The exact meaning of NtQueryInformationProcess class `0x0c` (350 hits) wasn't pinned down; `0x07`/`0x1a`/`0x22` are the load-bearing, confirmed ones.

## Practical finding: how to capture logs on CrossOver

CrossOver's `bin/wine` is a **Perl wrapper** that re-execs the real `wineloader` as a detached child, so a plain `> log 2>&1` redirect captures almost nothing (this is why the user's first runs had empty `wine.log`). The working method, now baked into `scripts/01-capture-failure.sh`:
```bash
CX_LOG="$OUTDIR/cxlog.txt" WINEDEBUG="+..." \
  "$CXBIN/wine" --bottle "$BOTTLE" --wait-children --cx-app "$TARGET"
```
`CX_LOG` routes **all** Wine debug channels (CrossOver adds `+seh,+module,+loaddll,+process,+unwind,+threadname` by default) to a file regardless of forking; `--wait-children` keeps the wrapper attached until the game's children exit.

## Next steps (updates the roadmap)

- **Milestone 1b — launcher path.** Run through `GRYPHLINK/Launcher.exe`, let it start the game (needs a GUI click), capture with `CX_LOG`. Compare: does the faithful path still stack-overflow in `EndfieldBase.dll`, or reach the ACE/`KiUser*Dispatcher` stage? This decides whether the direct-launch fault is an artifact.
- **Milestone 2 — cheap mitigations (no rebuild).** `ProductName` is already Windows 11; still try `HideWineExports`. More relevant here: test whether disabling the protector's need for the failing path helps (little user-space leverage without a rebuild — the real fix is patched Wine).
- **Milestone 3 — Linux dw-proton bisect.** Confirm which patches are load-bearing for the *same* `EndfieldBase.dll` exception behavior on Linux; that's the minimal set to port.
- **Milestone 6 — patched Wine.** The exception-dispatch/int3 patches are the direct candidates. Because the fault is an execute-fault handled by a colliding unwind, also watch Wine's `KiUserExceptionDispatcher` and `RtlUnwindEx`/`call_seh_handlers` behavior — the fix may extend beyond the two `KiUser*Dispatcher` symbols.

## Artifacts on disk
`~/endfield-debug/20260714-152216/` (the decisive direct-`Endfield.exe` run): `cxlog.txt` (76,837 lines — the real trace), `inventory.txt`, `macos-log.txt`. Earlier runs `20260714-1511xx`/`1512xx` are pre-capture-fix (near-empty `wine.log`) and only useful for the process-tree/no-crash-report observations.
