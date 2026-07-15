# Executive Summary

## The problem

*Arknights: Endfield* (Gryphline / Tencent, Unreal Engine 5) uses **ACE — Anti-Cheat Expert**, Tencent's anti-cheat (a rebrand of TenProtect, "TP"). On macOS through CrossOver, the game does not launch: CodeWeavers' own compatibility test shows the Gryphlink launcher rendering **a single ~1 ms frame and then the app is force-quit** by ACE. CodeWeavers rates it "Installs, Will Not Run" and officially does not work on anti-cheat issues.

## Why Linux solved it and how

ACE ships a Windows **kernel driver** (`ACE-BASE.sys`) plus a **user-mode** component. Wine/CrossOver cannot load a real Windows kernel driver — so any game that *hard-requires* the driver is impossible under Wine. Endfield is launchable because its live ACE can run in a **user-mode-capable path**, but that user-mode code still calls into Windows kernel APIs (`ntoskrnl.exe`) that stock Wine does not implement, and it probes the environment to detect Wine.

**dw-proton** (Dawn Winery, the "gacha games" Proton fork) makes Endfield launch on Linux with four Wine patches — GE-Proton's maintainer explicitly identified them as commit `b816be489…` "4 misc patches imported from upstream wine":

1. **The int3-stub hack** (`dlls/kernel32/module.c`): intercept `GetProcAddress` for `KiUserApcDispatcher` and `KiUserCallbackDispatcher` and return a naked `int3` (`0xCC`) stub instead of the real address (the original patch was commented `/* workaround for tpshell */` — tpshell = TenProtect shell). This defeats ACE's TenProtect dispatcher-hook / environment probe. **Guarded by `#ifdef __x86_64__`; gated to processes named `Endfield.exe` or `EM-Win64-Shipping.exe`; force-enable via `PROTON_ENABLE_INT3_HACK=1`.**
2. **`ntoskrnl.exe` "em-backports"** (Etaash Mathamsetty): implement/stub the kernel functions ACE calls — e.g. `KeAcquireGuardedMutex`, `PsGetProcessSessionId`, `PsGetProcessImageFileName`, `PsReferencePrimaryToken`, `MmGetPhysicalMemoryRanges`, `PsGetProcessPeb`, and ~a dozen more.
3. **`NtDelayExecution` via QPC** (`dlls/ntdll/unix/sync.c`): reimplement relative waits using `QueryPerformanceCounter` + busy-select, because "some applications are very timing sensitive."
4. The fourth patch in `b816` was a **wintrust signature-check bypass** (hiding `winex11`/`winewayland` from ACE) — dw-proton's only detection-evasion patch. It has since been **removed** and is **macOS-irrelevant** anyway (CrossOver uses `winemac.drv`). See [02](02-dwproton-ace-patches.md).

dw-proton also moved all its Wine patches **out of `patches/wine/`** into a submodule fork (`dawn-winery/wine-dwproton`, branch `base`) as of release `11.0-2` — the implementer must diff that fork, not look for `patches/wine/`.

On Linux this is enough: GamingOnLinux / AreWeAntiCheatYet report Endfield **working** on current dw-proton.

## Why macOS is harder than Linux

CrossOver's Wine on Apple Silicon is an **x86_64 build translated by Rosetta 2** to arm64, with a **`win32on64`** scheme for 32-bit code, a Metal graphics stack (D3DMetal / DXMT / DXVK+MoltenVK), and Mach-based synchronization (MSync). Every extra layer is surface area the Linux fix never had to survive:

- The int3 hack's `#ifdef __x86_64__` guard means it **only compiles into an x86_64 Wine** (i.e. the Rosetta-translated build). A future **native arm64** CrossOver would not include it — and CrossOver is moving that way (dropping Rosetta ahead of Apple removing it in ~macOS 28; CrossOver 27 retires 32-bit bottles and Intel Macs).
- Building `win32on64` requires **CodeWeavers' patched clang/LLVM**, whose source may have been removed from CrossOver tarballs after v20.0.1.
- ACE is **timing-sensitive**; the QPC busy-wait was validated on Linux x86_64, and Rosetta 2 translation could perturb timing.
- ACE may fingerprint the **Rosetta environment** specifically (CPUID brand string `VirtualApple`, missing AVX-512) — vectors that don't exist on Linux.

## The single most important open question

**Nobody has captured the *actual* failure signature of Endfield on stock CrossOver/macOS.** The only documented stock-Proton abort in the primary source (GE issue #433) was `unimplemented function msimg32.dll.AlphaBlend` — **not** an `ntoskrnl.exe` function. So it is *not yet proven* that the ntoskrnl backports are even the relevant fix on macOS, versus an ACE environment force-quit that no user-space patch can cure. ⚠️ This must be resolved **first** (it's free) before any build effort.

## Decision framework (go / no-go)

Run the cheap experiments in [09-implementation-roadmap.md](09-implementation-roadmap.md) **in order**; each is a gate:

1. **Observe the real failure** on stock CrossOver (WINEDEBUG logs). → Tells you whether the blocker is a missing function (fixable) or a categorical ACE force-quit (likely fatal).
2. **Free user-space spoofs** (winecfg → Windows 10/11; `HideWineExports`) with no rebuild. → Isolates "environment detection" from "kernel-API surface."
3. **Linux baseline + patch bisect** (prebuilt dw-proton on x86_64 Linux). → Confirms the minimal load-bearing patch set to port, with zero macOS compilation.
4. **Toolchain proof** (build *unmodified* `win32on64` Wine, swap into CrossOver, re-sign, launch a trivial app). → Validates the whole build/swap/sign/load pipeline before adding patch risk.
5. **Port the minimal patch subset**, rebuild, swap, retest Endfield. → First real integration milestone.
6. **Graphics + timing tuning** — only after it launches.

**Kill criteria:** if step 1 shows ACE force-quitting categorically with no fixable abort, or step 3 shows the fix depends on the `#ifdef __x86_64__` int3 hack *and* your only viable CrossOver base is native-arm64, the project is likely a dead end and further effort isn't warranted.

## Honest assessment

Theoretically possible, practically hard, and **not yet proven viable**. The Linux fixes prove the missing kernel functions can be stubbed and the dispatcher probe can be defeated. The wildcards are (a) whether ACE's macOS behavior is a fixable abort or a categorical force-quit, and (b) whether an x86_64-under-Rosetta CrossOver Wine — the only build the known fix compiles into — remains buildable and behaves like Linux under ACE's timing checks. The roadmap is designed to answer both cheaply and early.
