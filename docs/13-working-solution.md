# 13 — The working solution ✅ (Endfield reaches the login screen on macOS)

> **2026-07-14: Arknights: Endfield runs on Apple Silicon macOS under a custom-patched CrossOver Wine — past the VMProtect protector, past the ACE anti-cheat, rendering through Apple's D3DMetal, to the login screen.** This was universally considered impossible (CodeWeavers rated it "Installs, Will Not Run"; the community consensus was that CrossOver + Endfield could not work). It works.

## What works
- ✅ VMProtect/TenProtect "tpshell" protector (`EndfieldBase.dll`)
- ✅ **ACE anti-cheat fully passes** — `ACE-Base64.dll`, `ACE-Service64.exe`, kernel driver `ACE-BASE.sys`; **no more driver-error-13**
- ✅ Unity engine (`unityplayer.dll`, `GameAssembly.dll`) loads and initializes
- ✅ **Graphics via Apple D3DMetal** (`using d3dmetal as the graphics backend`)
- ✅ **Login screen renders** — the game is playable to the point of account login
- ⚠️ One non-fatal residual: an ACE thread aborts on `ntoskrnl.exe.PsGetProcessExitStatus` (dw-proton's maintainer noted this abort "isn't really related" to the blocker; it's not in the em-backports). The game reaches login regardless. Trivial stub = clean follow-up.

Engine correction: the runtime modules prove Endfield is **Unity IL2CPP**, not Unreal Engine 5 as the initial research ([06](06-graphics-and-gptk.md)) said.

## The two novel discoveries (the parts nobody had solved)

Both are **Rosetta 2 bugs** in how it delivers CPU faults for x86 instructions, fixed in `dlls/ntdll/unix/signal_x86_64.c` (`segv_handler`, the `TRAP_x86_PRIVINFLT` case), alongside CrossOver's existing `handle_cet_nop`/`emulate_xgetbv` hacks:

1. **Rosetta faults on a plain NOP.** VMProtect emits multi-byte `0F 1F` NOPs pervasively (100k+ per launch); Rosetta raises an illegal-instruction fault on them and CrossOver's `handle_cet_nop` had no `0F 1F` case. → Decode the NOP length and skip it (it has no side effects). *Cleared stage 1 — the protector runs and ACE loads.*
2. **Rosetta mis-classifies a privileged instruction.** ACE's driver reads `mov rbx, cr3` (CR3, ring-0 only) as an anti-VM probe. On Linux this is a `#GP` → Wine reports `EXCEPTION_PRIV_INSTRUCTION`, which ACE's SEH expects; under Rosetta it arrives as an *invalid-opcode* fault, so Wine reported `EXCEPTION_ILLEGAL_INSTRUCTION` and ACE failed with driver-error-13. → On the Rosetta path, call Wine's existing `is_privileged_instr()` and deliver `EXCEPTION_PRIV_INSTRUCTION` (matching Linux). *Cleared the ACE driver check.*

**Both are general CrossOver-on-Apple-Silicon bugs** (they affect any VMProtect/TenProtect/kernel-anti-cheat title, cf. WineHQ Bug 45083) and are worth upstreaming to CodeWeavers.

## The complete patch set (8 files, ~394 lines)

Applied to CrossOver 26.2's Wine 11.0 (`build/wine-src`):

| File | Origin | Purpose |
|---|---|---|
| `dlls/ntdll/unix/signal_x86_64.c` | **NEW — our fixes** ([patches/stage1-macos/](../patches/stage1-macos/)) | `0F 1F` NOP-skip **+** privileged-instruction (`mov cr3`) → `PRIV_INSTRUCTION`. The two Rosetta fixes. |
| `dlls/kernel32/module.c` | dw-proton | int3-stub `KiUser*Dispatcher` spoof (fired 2×). |
| `dlls/ntdll/unix/sync.c` | dw-proton | `NtDelayExecution` via QPC (timing). |
| `dlls/ntoskrnl.exe/{ntoskrnl.c,.spec,_private.h,sync.c}` | dw-proton | 17 `ntoskrnl.exe` em-backports ACE's driver calls. |
| `dlls/win32u/vulkan.c` | build fix | `SONAME_LIBVULKAN` fallback (minimal build compiles). |

Patches: [patches/stage1-macos/](../patches/stage1-macos/) (our Rosetta fixes) + [patches/stage2-dwproton/](../patches/stage2-dwproton/) (dw-proton set). The `signal_x86_64.c` patch also contains an optional `CWC-ILLEGAL-INSTR` debug `ERR` line — harmless (fires 0×), remove for production.

## How it's deployed (the swap into CrossOver)

The custom Wine is built minimal (no graphics libs), so we **surgically swap only the patched modules** into a copy of `CrossOver.app` and let CrossOver provide D3DMetal/Metal + fonts/TLS. This is automated in [scripts/swap-into-crossover.sh](../scripts/swap-into-crossover.sh):

1. `cp -a /Applications/CrossOver.app build/CrossOver_patched.app` (must be **26.2**, matching the build).
2. Copy 3 patched modules into `Contents/SharedSupport/CrossOver/lib/wine/`:
   - `x86_64-unix/ntdll.so` (both Rosetta fixes + NtDelayExecution)
   - `x86_64-windows/kernel32.dll` (int3 hack)
   - `x86_64-windows/ntoskrnl.exe` (em-backports)
3. `codesign --force --sign -` each swapped file; remove `Contents/_CodeSignature` + `Contents/CodeResources`; `xattr -drs com.apple.quarantine`.
4. Run the game through `build/CrossOver_patched.app` (its wrapper sets up D3DMetal) against the existing bottle → login screen.

## Reproduce from scratch
`scripts/build-wine.sh` (deps→fetch→configure→build under `arch -x86_64`), apply all patches (`git apply`), rebuild, then `scripts/swap-into-crossover.sh`. Full build details: [04](04-building-crossover-wine.md).

## Follow-ups (polish, not blockers)
- Add `PsGetProcessExitStatus` as an em-backport stub to silence the one residual ACE-thread abort.
- Play-test past login (combat/rendering stability, the QPC-timing × D3DMetal interaction, DLSS fallback since it's NVIDIA-only).
- **Upstream the two Rosetta signal fixes to CodeWeavers** (with Bug 45083 as reference) — they fix a whole class of protected games on Apple Silicon.
- A distributable: bundle the patched modules as a CXPatcher-style overlay so others can apply it to their own CrossOver 26.2.
