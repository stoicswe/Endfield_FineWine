# 17 — The ARM logo freeze: a junk pc killed the main thread

> **Status: fixed for the logo freeze (Nov 2026).** In an `arm64` bottle on CrossOver ARM, with no
> Rosetta, Endfield froze at the Gryphline logo. It now reaches its menu background, and the login
> panel appears after about a minute in runs with light logging. Logging in and gameplay are **untested**, and ACE does
> not start its drivers on ARM, so the ARM variant stays experimental.

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
Started by hand with `sc` and ACE's coded `DisplayName`, both ARM64 drivers now reach `RUNNING`
with no bugcheck, which x64's drivers don't. That took these patches in `patches/ARM/stage1-macos/`:

| Patch | What the driver needed |
|---|---|
| `0010` | `wdfldr.sys`. `FuncTable` takes a single pointer, as dwproton's `wdf01000.sys` does |
| `0011` | Value names with trailing nulls, which Windows ignores and Wine's server does not |
| `0012` | Imports that aborted the driver host as spec stubs, and `PsGetProcessPeb` |
| `0013` | Reads of the kernel-mode shared page, which `instr.c` emulated only on x86 |
| `0014` | `KeCapturePersistentThreadState` |

An earlier array version of the `wdfldr` stub corrupted the driver's data, so its `c1820001` result
was not real.

ACE's service still doesn't start these drivers by itself on ARM. Started by hand, they unload
themselves about 30 seconds later, with or without the game, through `ZwUnloadDriver`. The cause
isn't known; a timeout waiting for a client would fit.

Each `winedevice` host keeps its own notify routines, so a driver only sees processes its host
references. x64 solves this with server patches `0018` and `0019`, which can't ship on CrossOver ARM
because its wineserver can't be replaced. With `group= "System Bus Extender"` on the test services,
the drivers load into the host that sees the game, and `Endfield.exe` reports `2 Ex + 1 legacy`
routines. Even so, `ACE-Service64.exe` stops as before and the drivers still unload after about 35
seconds, so that alone doesn't make ACE work.

## Login panel

The login panel is a separate QtWebEngine page over the game (`PlatformProcess.exe`, in the
`UIPlatform` window). It takes about a minute: in one timed run with light logging, `UIPlatform` was
on screen 52 seconds after the game started, and it appeared with no input. One run left for 97
seconds, with drivers started before launch, didn't show it, which isn't explained. `Load web
timeout!` and the SSL handshake errors in `chrome_debug.log` appear whether or not it shows.
