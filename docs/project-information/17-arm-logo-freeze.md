# 17 — The ARM logo freeze: a junk pc killed the main thread

> **Status: fixed for the logo freeze (Nov 2026).** In an `arm64` bottle on CrossOver ARM, with no
> Rosetta, Endfield froze at the Gryphline logo. It now reaches its login UI. Login and gameplay are
> **untested**, and ACE does not start its drivers on ARM, so the ARM variant stays experimental.

## Symptom

The window stayed up on the logo, and `Endfield.exe` kept running with no crash report. `Player.log`
stopped after the second `HGCreateSwapchain`. x64 went on to `Unloading … Unused Serialized files`.

## Root cause

ARM64EC `ntdll` checks each unwound pc against `EcCodeBitMap`, with no bounds check:

```c
const UINT64 *map = (const UINT64 *)NtCurrentTeb()->Peb->EcCodeBitMap;
ULONG_PTR page = ptr / page_size;
return (map[page / 64] >> (page & 63)) & 1;
```

1. During exception dispatch on the game's main thread, the stack walk reaches a pc that is not code
   (`0x41006c0060xxxx`, which is UTF-16 text). Why it gets there is not known.
2. The bitmap read lands at `base + 0x8200d800c0` and faults, which is the logged fault address.
3. That fault dispatches, reaches the same pc and faults again, about 0x1260 bytes deeper each time.
4. After 200+ rounds the stack runs out and `virtual_setup_exception` calls `abort_thread(1)`.

The overflow is the last line that thread logs. The process survives, so the window stays up. It
appeared in all 4 ARM logs checked and in neither x64 log.

## Fix

CrossOver ARM's source isn't published, so `ntdll.dll` can't be rebuilt. `ArmNtdllFix.swift` patches
the 9 places this check is compiled, changing `lsr xd, xn, #18` to `ubfx xd, xn, #18, #29`. The index
is then limited to the 47 address bits the 4 GB bitmap covers. Exactly 9 bytes change. The patch
accepts only the known stock hash and must produce the tested hash, so any other CrossOver ARM build
stops with an error.

Upstream Wine and dwproton have the same unchecked code, so the patch stays needed until CrossOver
changes it.

## ACE on ARM: still open

Traces of x64 and ARM launches of byte-identical game files show:

- `ACE-Setup64` installs ARM64 `ACE-CORE` drivers from `ACE-CORE.sysa` and `.sysa2`.
- `ACE-Service64` behaves the same on both until after it checks `ACE-BASE.sys`. x64 then creates and
  starts the `ACE-CORE` services, and ARM reports `STOPPED` with exit 0.
- The pipe data from the game differs: 41,348 bytes on ARM, 41,268 on x64. Its contents aren't known.
- Replacing the bottle's `system32\ntoskrnl.exe` with the stock or x64 file changes nothing.
- x64's drivers bugcheck with `0x65636154`, which GE-Proton's notes also list as unresolved, and the
  game still reaches its menu.

The ARM64 drivers import `wdfldr.sys`, which Wine lacks and x64's drivers don't use.
`patches/ARM/stage1-macos/0010` adds a stub, but it isn't shipped. `FuncTable` takes a single pointer,
as dwproton's `wdf01000.sys` does. An earlier array version of the stub corrupted the driver's data,
so its `c1820001` result was not real.

With the corrected stub, started by hand with `sc`, both ARM64 drivers bind and then fail with
`c0000034`. They query their service key for `ImagePath` and `DisplayName` with trailing NULs in the
names, which Wine doesn't match, while the x64 driver sends clean names and continues to
`MachineGuid`. The test services also lacked ACE's coded `DisplayName`.
