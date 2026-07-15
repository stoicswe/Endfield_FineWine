# 09 — Implementation roadmap (the plan of record)

> This is the ordered, de-risking plan. Each milestone is a **gate**: it produces evidence that decides whether the next (more expensive) milestone is worth starting.

## ⚡ Where we are now (2026-07-14) — the plan has forked into two stages

Milestones 0–1 (and 1b) are **done** ([docs/10](10-milestone-1-results.md), [docs/11](11-linux-vs-macos-comparison.md)). The failure is **two stages**, and the roadmap now reflects that:

- **STAGE 1 — the `EndfieldBase.dll` `0x6CD268` protector fault (CRITICAL PATH, unsolved).** macOS-specific; not fixed by dw-proton. Investigation + experiments: **[docs/12](12-stage1-protector-fault.md)**. Everything below (milestone 4 build platform) exists to enable this.
- **STAGE 2 — the dw-proton port (deferred).** Milestones 3/6 apply the staged patches ([patches/stage2-dwproton/](../patches/)) — but only *after* stage 1 is cleared, since we never reach the ACE stage today.

**Immediate next actions:** Milestone 4 (build + swap a vanilla 64-bit CrossOver Wine, prove parity) → then the stage-1 experiments in [docs/12](12-stage1-protector-fault.md). Milestones 2 (free spoofs) and 3 (Linux bisect) are **lower value now**: OS-version spoof is already applied (bottle = Windows 11 Pro), and the user has no Linux box. Skip/defer them.

The original milestone list is preserved below for reference.

## Milestone 0 — Environment inventory (30 min, no risk) — ✅ DONE (Apple M3, macOS 26.5, CrossOver 26.2 + 27-Preview, x86_64/Rosetta)

Establish exactly what you're working with before touching anything.

```bash
# CrossOver version + Wine version it bundles
/Applications/CrossOver.app/Contents/SharedSupport/CrossOver/bin/wine --version
defaults read /Applications/CrossOver.app/Contents/Info CFBundleShortVersionString

# Is the bundled Wine x86_64 or arm64? (decides whether the int3 __x86_64__ hack is relevant)
file /Applications/CrossOver.app/Contents/SharedSupport/CrossOver/bin/wineserver
file /Applications/CrossOver.app/Contents/SharedSupport/CrossOver/bin/wine64 2>/dev/null

# macOS + hardware
sw_vers ; uname -m ; sysctl -n machdep.cpu.brand_string
```
**Record:** CrossOver version, Wine base version, wine binary arch (x86_64 vs arm64), macOS version. These feed every later decision (esp. risks #2 and #3 in [08](08-risks-unknowns-open-questions.md)).

## Milestone 1 — Capture the REAL failure signature ⭐ (cheapest, most decisive) — ✅ DONE

**Result: see [docs/10-milestone-1-results.md](10-milestone-1-results.md).** The failure is a **protector (VMProtect/TenProtect) exception-dispatch loop in `EndfieldBase.dll`** (repeated execute-`c0000005` → colliding unwind → stack overflow), *before* ACE loads — a user-space-fixable class, not a kernel wall. Two follow-ups remain: **1b** (run the faithful launcher path, not direct `Endfield.exe`) and confirming the exact patch that fixes it (milestones 3/6).

Original procedure (use `scripts/01-capture-failure.sh`, which now uses `CX_LOG` + `--wait-children` — a plain stderr redirect does NOT work on CrossOver):

```bash
# In a dedicated bottle, launch the launcher/game with Wine debug logging
WINEDEBUG=+loaddll,+module,+ntoskrnl,+seh,+relay \
  <CrossOver wine> "C:/Program Files/GRYPHLINK/Launcher.exe" &> ~/endfield-launch.log
# also watch the macOS side:
log stream --predicate 'process CONTAINS "wine" OR process CONTAINS "Endfield" OR process CONTAINS "ACE"' --info
```
**Decision:**
- If you see `wine: Call from … to unimplemented function ntoskrnl.exe.<X>, aborting` → **fixable**; `<X>` names the load-bearing patch family ([02](02-dwproton-ace-patches.md)). Proceed.
- If you see `unimplemented function msimg32.dll.AlphaBlend` → note it; may be co-occurring (see [01](01-ace-anticheat-and-endfield.md)).
- If ACE **force-quits with no unimplemented-function abort** (matches CodeWeavers' 1-frame observation) → **likely categorical**; this is the **kill signal** (risk #1). Investigate whether ACE logged an environment verdict before deciding to continue.

## Milestone 2 — Free user-space spoofs (no rebuild)

Isolate "environment detection" from "kernel-API surface" for free ([07](07-rosetta-and-windows-spoofing.md)).

```bash
# set Windows 10/11 for the bottle
<CrossOver winecfg>            # GUI → Windows Version → Windows 10 (or 11)

# hide Wine exports
<CrossOver wine> reg add "HKCU\\Software\\Wine" /v HideWineExports /d Y /f
# or per-app:
<CrossOver wine> reg add "HKCU\\Software\\Wine\\AppDefaults\\Endfield.exe" /v HideWineExports /d Y /f

# retest, compare to milestone-1 baseline
```
**Decision:** ACE gets further → blocker is environment detection (spoofs help). Aborts identically → blocker is the kernel-API surface (need [02](02-dwproton-ace-patches.md) patches). Either way you've narrowed it for free.

## Milestone 3 — Linux baseline + patch bisect (no macOS compilation)

Prove the fix on the platform where it's known to work, and find the **minimal** load-bearing patch subset to port.

1. On an **x86_64 Linux** box (or VM), install Endfield under prebuilt **dw-proton** (via ProtonPlus / Heroic / Lutris). Confirm it launches — establishes the known-good baseline.
2. Bisect the 4 patches in `b816be489`:
   - Toggle the int3 hack off by *not* setting `PROTON_ENABLE_INT3_HACK` and renaming the process, or patch it out; see if it still launches.
   - Remove em-backports subsets; see which `ntoskrnl` functions are actually reached.
   - Remove the `NtDelayExecution` QPC patch; see if timing breaks.
**Output:** the **minimal patch set** that must be ported to macOS — which is exactly what milestone 6 applies. Cheap because it's all prebuilt.

## Milestone 4 — Toolchain + swap + sign pipeline proof (first build, no patch risk)

Validate the entire build → swap → sign → load pipeline with an **unmodified** Wine, so any later failure is attributable to *your patches*, not the plumbing. See [04](04-building-crossover-wine.md) + [05](05-swapping-into-crossover.md).

1. Obtain CrossOver `winecx` source **matching your installed CrossOver's Wine base version** (milestone 0).
2. Obtain the patched clang (`brew install gcenx/wine/cx-llvm`; if unavailable per issue #51, compile bundled `clang/llvm` from the tarball).
3. Build **unmodified** `wine64` then `wine32on64` (x86_64, under Rosetta).
4. Swap the built binaries/libs into a copy of `CrossOver.app` (`Contents/SharedSupport/CrossOver/bin` + `lib*/wine`), **keeping** the `/lib64/apple_gpt` payload.
5. Re-sign + de-quarantine:
   ```bash
   codesign --force --deep --sign - CrossOver_patched.app
   xattr -drs com.apple.quarantine CrossOver_patched.app
   spctl -a -vv CrossOver_patched.app
   ```
6. Launch a **trivial app** (notepad / winecfg) from the patched bundle.
**Decision:** trivial app runs → pipeline works, proceed. Fails to load/sign → resolve risks #3/#5 before any patching.

## Milestone 5 — (only if separately needed) integrate the graphics payload
If Endfield needs GPTK4/D3DMetal 4 specifically ([06](06-graphics-and-gptk.md)), stage the `/lib64/apple_gpt` payload swap CXPatcher-style. Usually deferrable until after launch.

## Milestone 6 — Port the minimal patch subset ⭐ (first real integration)

Apply the minimal load-bearing subset from milestone 3 onto the CrossOver Wine tree from milestone 4:
- the int3 `kernel32` hack (`dlls/kernel32/module.c`) — resolve conflicts with CrossOver's `win32on64` module.c;
- the required `em-backports` `ntoskrnl.exe` functions (whichever milestone 1/3 proved reached);
- the `NtDelayExecution` QPC patch (`dlls/ntdll/unix/sync.c`).

Rebuild → swap → re-sign → retest Endfield. Expect **rebase conflicts** (Proton Wine vs. `winecx`) — this is where the real engineering is. Set `PROTON_ENABLE_INT3_HACK=1` if the process-name gate doesn't match under CrossOver.
**Decision:** launcher survives past the 1-frame crash → major milestone; iterate on remaining aborts. Still force-quit → revisit risk #1/#4.

## Milestone 7 — Graphics + timing tuning (only after it launches)
- Try backends in order of likely fit: **DXMT (force DX11)** → **D3DMetal (DX12)** → **DXVK** → MoltenVK/Vulkan ([06](06-graphics-and-gptk.md)).
- Verify **timing stability** under Rosetta across a play session (QPC wait + MSync interaction, risk #4). If ACE trips intermittently on timing, this is where it shows.

---

## Dependency graph (what gates what)
```
M0 inventory ─┐
M1 real failure ⭐ ── (kill gate: categorical force-quit → STOP)
M2 free spoofs ──── narrows: env-detection vs kernel-API
M3 linux bisect ─── produces: minimal patch set
                          │
M4 pipeline proof ─── (gate: build/swap/sign works)
                          │
M6 port patches ⭐ ─── (gate: launches past 1-frame crash)
                          │
M7 graphics/timing ── playable
```

## What to hand the next session
- This roadmap + [02](02-dwproton-ace-patches.md) (the patches) + [08](08-risks-unknowns-open-questions.md) (the risks).
- The **milestone-0 inventory** and **milestone-1 failure log** — without those two artifacts, the next session is guessing.
