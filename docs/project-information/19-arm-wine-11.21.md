# 19 — CrossOver ARM on Wine 11.21

> **Status (2026-11-11): ported; the game runs in the world with DXMT, ACE's drivers still don't start.** CrossOver ARM
> preview 20261111 (build 27.0.0.41303) is built on Wine 11.21, so `patches/ARM` now targets 11.21.
> The modules build, everything they import exists in that preview, the launcher runs with its black
> margin fixed ([16](16-launcher-black-margin.md#crossover-arm)), and the game reaches its terms
> notice and login panel. `ACE-Service64` still stops without creating its driver services, exactly
> as on 11.17; see [ACE on 11.21](#ace-on-1121).

## Which Wine a CrossOver ARM build is based on

CodeWeavers publishes no CrossOver ARM source. On 2026-11-11 its source page listed only
`crossover-sources-26.3.0.tar.gz`, the directory index at
`media.codeweavers.com/pub/crossover/source/` returned 403, and every 27.x and preview name tried
(`27.0.0`, `27.0.0.41073`, `26.3.1`, `26.4.0`, `-preview`/`-beta` forms) returned 404. The base can be
read from the app instead:

```bash
strings -a "/Applications/CrossOver Preview ARM.app/Contents/SharedSupport/CrossOver/lib/wine/aarch64-unix/ntdll.so" | grep -m1 -oE 'wine-1[0-9]\.[0-9]+'
```

| Preview | Build | Reports |
|---|---|---|
| 20261015 | 27.0.0.41073 | `wine-11.17-8910-g4683e69e153` |
| 20261111 | 27.0.0.41303 | `wine-11.21-8943-gabe093fc436` |

That is CodeWeavers' branch some thousands of commits past the tag. If their branch carries later
upstream changes without the tags, the true base could be a little newer than the number suggests.

## Why the modules must match that base

The ARM payload replaces only `ntoskrnl.exe`, `rundll32.exe` and `wdfldr.sys`. They run on
CrossOver's own `ntdll` and wineserver, which can't be replaced (see "CrossOver variants" in
[patcher-app/README.md](../../patcher-app/README.md)). Linking isn't the problem: an import check
(below) found every function the 11.21 modules import in both previews. The problem is wineserver
requests. `ntoskrnl.exe` sends ten kinds of request directly, each identified by a number compiled
into the module, and Wine 11.18 inserted a request ahead of all of them:

| Request | 11.17 | 11.21 |
|---|---|---|
| `set_irp_result` | 139 | 140 |
| `create_device_manager` | 251 | 252 |
| `create_device` | 252 | 253 |
| `delete_device` | 253 | 254 |
| `get_next_device_request` | 254 | 255 |
| `get_kernel_object_ptr` | 255 | 256 |
| `set_kernel_object_ptr` | 256 | 257 |
| `grab_kernel_object` | 257 | 258 |
| `release_kernel_object` | 258 | 259 |
| `get_kernel_object_handle` | 259 | 260 |

The structures themselves didn't change, and `SERVER_PROTOCOL_VERSION` went from 961 to 971. A
module built from the wrong release links and loads, then sends `create_device` to a server that
reads it as `delete_device`. `rundll32.exe` sends no requests, so it alone would survive a mismatch.

So "use the latest Wine" means "use the Wine the installed CrossOver ARM is built on". While the
preview was on 11.17, a move to 11.21 was evaluated and rejected for that reason; preview 20261111
moved to 11.21 itself, which made the port possible.

### Checking a build's imports

`llvm-objdump -p` lists a module's imports and a DLL's exports. Two details matter: forwarded exports
print as `name (forwarded to X)` with no address column, and normal ones as `ordinal 0xRVA name`, so
the name is the second or third field. A checker that ignores this reports false misses (it flagged
`kernel32!RtlZeroMemory` and `kernelbase!HeapAlloc` on modules that work).

## Porting `patches/ARM` from 11.17 to 11.21

Each patch was tested alone against clean 11.21, forward and reversed:

| Result | Patches |
|---|---|
| Applies | `misc/0008`, `0009`, `0011`; `ace-core/0003`–`0006`, `0015`; `stage1-macos/0000`, `0008`, `0011`, `0013` |
| Upstream now, dropped | the nine `em-backports` (`PsGetThreadProcess`, `MmGetVirtualForPhysical`, `PsGetProcessImageFileName`, `SeLocateProcessImageName`, `PsReferencePrimaryToken`, `PsGetContextThread`, `MmGetPhysicalMemoryRanges` and two fixups); `stage1-macos/0014` (11.21 implements `KeCapturePersistentThreadState`) |
| Rebased | `stage1-macos/0010` (generated `configure` drifted), `stage1-macos/0012` (dropped its `PsGetProcessPeb`, now identical upstream), `ace-core/0017` |
| Depends on another | `misc/0010` applies once `misc/0009` is in |

`ace-core/0017` (process and thread notify routines) needed two changes:

- Its call to `call_process_notify_routines()` was anchored on token code an em-backport had added to
  `create_process_object`. Upstream implemented `PsReferencePrimaryToken` without it, so the call now
  sits just before `return process;`, after `get_process_image_file_name()` fills the name.
- It read `process->imageName`, the em-backport's field. Upstream stores the same 15-character short
  name as `process->image_name`.

The result is 16 patches. `scripts/build-wine-arm.sh` now defaults to `ARM_WINE_TAG=wine-11.21` and no
longer reads `em-backports/`. Applying the repo's series to a fresh 11.21 tree with the script's
`apply` step reproduces the built sources exactly. Upstream has no process or thread notify routines
of its own, so 0017 doesn't duplicate anything.

## The ntdll freeze fix on the new preview

Upstream 11.21's `RtlIsEcCode` still has no bounds check, so the logo-freeze fix
([17](17-arm-logo-freeze.md)) is still needed. Preview 20261111's `ntdll.dll` contains the same nine
`lsr xd, xn, #18` lookups with the same encodings, in the same order, at shifted offsets. They are the
only such instructions in the file. `ArmNtdllFix` now holds a table of known builds (stock hash, fixed
hash, offsets) instead of one pinned build:

| Build | Stock SHA-256 | First site |
|---|---|---|
| 41073 | `a6678f9d…` | `0xc7910` |
| 41303 | `3c2d6459…` | `0xc8380` |

A test runs the fix on whichever known preview is installed and checks the exact output hash.

## Practical notes

- **The new preview is installed as `CrossOver Preview ARM.app`.** `CrossOver Preview.app` is also 41303.
- **On ARM the server binary is `bin/wineserver-arm64`.** There is no `bin/wineserver`, so
  `wineserver -k` has to use that name, with `WINEPREFIX` set to the bottle.
- **A hand-made copy of the preview keeps its quarantine flag.** Every unsigned helper, `cxbottle`
  included, is then killed at start (exit 137). The patcher strips the flag; a manual copy needs
  `xattr -drs com.apple.quarantine` or **Open Anyway**.
- **Never copy over a signed Mach-O in place inside an app.** The kernel keeps the old signature for
  that file and kills the process (`Code Signature Invalid`). Write a new file and move it over.
- **`build-app.sh` takes `ARM_PAYLOAD_DIR`**, so a test payload can be bundled without touching
  `build/wine-arm-payload`.
- **On ARM the launcher draws through wined3d's Vulkan renderer** (MoltenVK), not DXMT, even in a
  DXMT bottle: `CX_GRAPHICS_BACKEND` doesn't apply to it.

## The game on 11.21

Started from the launcher in a bottle made by the patcher (`Arknights Endfield ARM`, MSync on, no
graphics backend set), the game gets past the old logo freeze and reaches its terms notice and login
panel. It draws with Unity's Vulkan renderer through MoltenVK. In that bottle the D3D modules it
loads are wined3d's (`set_graphics_backend using wined3d`), since `CX_GRAPHICS_BACKEND` isn't set.

- **The first launch looks hung.** With no `vulkan_pso_cache.bin`, every pipeline is built through
  MoltenVK first. `Player.log` stopped at `Unloading 134 unused Assets` for a few minutes while the
  game used about 175% CPU and 3.5 GB, then the terms notice appeared.
- **The game window is opaque.** Both `Endfield` and `UIPlatform` measured 0% transparent, and the
  launcher-alpha library is inactive in `Endfield.exe`. A window seen as black was another app's
  window covering it.
- **Starting `Endfield.exe` directly doesn't work.** With the launcher's own arguments
  (`-launcher_lang=en-us -launcher_sub_channel=6`) the game reports "It is detected that you are
  running multiple game instances" although only one exists, then crashes on exit (`nested exception
  on signal stack`). Start it from the launcher, as on x64.

## ACE on 11.21

The behaviour is unchanged from 11.17: `ACE-Setup64 -install` registers `AntiCheatExpert Protection`,
whose `ACE-Service64.exe -autorun` reports `RUNNING` and then `STOPPED` about 0.4 s later, without
calling `CreateServiceW` for `ACE-CORE`. Upstream's `ntoskrnl` changes up to 11.21 don't affect that
decision.

### Tracing only ACE's service

A relay trace of `ACE-Service64` shows every API call it makes and its result. Two things make that
usable:

- **Wine ignores `RelayFromInclude` while `RelayFromExclude` is set**, and CrossOver sets
  `RelayFromExclude` (`winex11.drv;winemac.drv;user32;gdi32;advapi32;kernel32`) in
  `HKCU\Software\Wine\Debug`. With it present, `+relay` traced every process: 500 MB in 20 s.
  Delete it and set `RelayFromInclude` to `ACE-Service64.exe`, then put it back afterwards.
- **`+relay` slows every process it is enabled in**, and with it on, the launcher barely loaded.
  Services inherit the environment of `services.exe`, which inherits it from the command that starts
  the bottle. So start the bottle with relay on and a placeholder that keeps it alive, then the
  launcher without it:

  ```bash
  wine --bottle "$B" --debugmsg "+timestamp,+pid,+tid,+service,+process,+loaddll,+relay,err+all,fixme-all" \
       --wait-children cmd /c "ping -n 900 127.0.0.1 >nul" > relay.log 2>&1 &
  sleep 12
  wine --bottle "$B" --wait-children --cx-app "C:/Program Files/GRYPHLINK/Launcher.exe" &
  ```

  Only services (ACE's included) carry the relay; the launcher and the game run at normal speed.

### What the service does before it stops

All on its main thread, in the 0.4 s after `RUNNING`:

1. **Handshake with the game.** It opens a named pipe from the game (`\\.\pipe\48f6…`), reads a
   0x208-byte header, a 12-byte one and a 0xa094-byte (41,108-byte) blob, then sets up a shared-memory
   channel: `Global\Ver_1_…_MUTEX`, `_CONNECTION`, `_SMEM` (0x3000 bytes), `_CLIENT_EVENT` and
   `_SERVER_EVENT`. A listener thread waits on `_SERVER_EVENT`. It then writes 4 bytes back on the
   pipe and closes it, and opens the game's process.
2. **Version checks.** `VerifyVersionInfoW` with a major-version `<=` test returns `FALSE`. It
   resolves `NtQuerySystemInformation`, `NtQueryInformationProcess`, `NtReadVirtualMemory`,
   `RtlGetVersion` and others by name, and calls `RtlGetNtVersionNumbers`. It loads
   `system32\ntoskrnl.exe` as a data file and reads its `VS_VERSION_INFO`.
   `Wow64DisableWow64FsRedirection` returns `FALSE`, as it does in any 64-bit process.
3. **OpenSSL starts** and looks for `/usr/local/ssl/openssl.cnf` (not found, harmless).
4. **Hashes its files.** It maps `ACE-Service64.exe` (0x319dd8 bytes) and `ACE-BASE.sys`
   (0x3ef2f8 bytes) in turn.
5. **Decides, with no API calls.** For about 190 ms (907.218 to 907.404) the thread makes no calls
   but `GetSystemTimeAsFileTime`.
6. **Reports and stops.** It resets its stop event, does a handshake on the shared-memory channel and
   signals `_CLIENT_EVENT`. The game answers at once through `_SERVER_EVENT`; the listener thread then
   sets the stop event, and the main thread reports `STOPPED` and exits with
   `FreeLibraryAndExitThread`.

No call fails in a way that would explain the stop. According to the 11.17 traces, x64's service
creates and starts the `ACE-CORE` services at step 5, so the branch is taken in that silent stretch,
from data it already has. Candidates:

- **The blob from the game**, which was 80 bytes longer on ARM than on x64 in the 11.17 traces.
- **The kernel version** from `RtlGetNtVersionNumbers` and `ntoskrnl.exe`'s version resource.
- **Reads without API calls**, such as `KUSER_SHARED_DATA` (whose `NativeProcessorArchitecture` is
  ARM64 here) or `cpuid` under emulation.

### Compared with x64

The same trace on x64 (CrossOver 26.3 patched, bottle `Arknights Endfield`) was normalized for both:
one line per call with its name, string arguments and a coarse result (zero, one, -1 or other), with
heap, locking, tick-count and string-conversion calls dropped. The two match call for call for the
first 75 calls, through hashing `ACE-BASE.sys`. Then x64 continues and ARM doesn't:

```
GetModuleHandleW / GetModuleFileNameW
GetFileAttributesW("C:\Program Files\AntiCheatExpert\ACE-CORE1024303.sys")
...  CreateFileW / ReadFile of the driver file
OpenSCManagerW
CreateServiceW("ACE-CORE1024303", "ACE-CORE*$$*24303^$$^366667.1024303", ...ACE-CORE1024303.sys)
ChangeServiceConfigW / StartServiceW
...  the same for ACE-CORE2024303
```

ARM doesn't even check whether a driver file exists. The values behind identical results do differ:

| | ARM (11.21) | x64 |
|---|---|---|
| Blob read from the game's pipe | `0xa094` (41,108 bytes) | `0xa164` (41,316 bytes) |
| `ACE-Service64.exe` size | `0x319dd8` | `0x319dd8` |

The service acts on what the game's ACE client sends it. On ARM the client builds a different, shorter
configuration (208 bytes shorter here; in the 11.17 traces the ARM blob was 80 bytes longer), and with
it the service skips the driver step. So the decision happens in the game process, in what its ACE
client finds about the system, not in the service.

Practical notes from the x64 run:

- With the relay inherited from `services.exe`, the driver host (`winedevice.exe`) is traced too and
  runs slowly. The game then showed an error after pressing Play, most likely ACE timing out; the
  service trace up to `StartServiceW` was complete.
- `HKCU\Software\Wine\Debug` was saved before the run and restored exactly afterwards on both
  bottles.

### The game's ACE client

ACE's client is `AntiCheatExpert\ACE-Base64.dll`, which the game loads about 0.5 s before it runs
`ACE-Setup64 -install`.

**Relay can't be used in the game.** With `+relay` in `Endfield.exe` (per process, see below), the
game exits before loading `ACE-Base64.dll` with "It is detected that you are running multiple game
instances, the program is about to terminate normally", although only one exists, then crashes on
the way out. The same happens when the game is started directly with `+relay`. Relay rewrites export
tables, which the game's protection evidently notices; the message is a cover.

**Plain trace channels do work.** Wine's `WINEDEBUG` takes per-process options,
`[process:]class+channel`, matched against the executable's file name, so
`endfield.exe:+ntdll,endfield.exe:+process` traces only the game and changes no code. The `ntdll`
channel logs every `NtQuerySystemInformation(Ex)` class and `process` every
`NtQueryInformationProcess` class. With these the game reached its login panel on both variants.

From `ACE-Base64.dll` loading until the service stopped, the game's main thread made the same queries
in the same order on ARM and x64, with one difference: `NtQuerySystemInformationEx` class `0xb5`
(`SystemSupportedProcessorArchitectures`). ARM made three extra calls early on and x64 four later. The
traces don't show results, but that class is where the two necessarily differ: Wine on ARM reports a
native ARM64 machine that runs x64 under emulation, and Rosetta-based x64 Wine reports native x64.

So ACE's client isn't tripping over a Wine bug. It takes its ARM64 path deliberately and sends the
service a configuration without the driver step. The two readings that fit:

1. On Windows on ARM, ACE runs without its kernel drivers at startup and loads the ARM64 drivers that
   `ACE-Setup64` installs from `ACE-CORE.sysa`/`.sysa2` later, for example after login. That would
   explain why the ARM game reaches login with no ACE error, where x64 without its drivers used to
   fail with ACE "driver error 13".
2. Something later in the ARM path fails silently. Nothing in these traces shows it.

Reporting x64 to ACE isn't an option: ACE would then start its x64 drivers, which can't run in an
ARM64 `winedevice.exe`.

## Logged in, in the world

With a login on ARM (2026-11-11), the game downloaded its resources and entered the world.

- **ACE never started its drivers.** Traced with `+service,+ntoskrnl` through login, the resource
  download and entering the world: the only ACE activity is the usual one at game start
  (`ACE-Service64` running for about 60 ms). No `ACE-CORE` service was created and no ACE driver
  loaded. There was also no ACE message, kick or disconnect while playing.
- **DirectX 11 with DXMT renders, but stalls.** In a bottle without a backend, the game runs Unity's
  Vulkan renderer through MoltenVK, and parts of the UI rendered as white blocks; MoltenVK also logs
  `'sampler' attribute parameter is out of bounds: must be between 0 and 15`, the known Vulkan-mode
  limit. With `CX_GRAPHICS_BACKEND = dxmt` in the bottle and **DirectX 11** chosen in the launcher's
  settings, the game starts with `-force-d3d11` and loads DXMT (`winemetal.dll`, DXMT's `d3d11.dll`
  and `dxgi.dll`). D3DMetal can't be used on ARM: every part CrossOver ARM ships of it (`apple_gptk`
  and `apple_gptk3`) is x86_64-only, and an ARM64 process can't load its x86_64 native half.
- **DXMT stalls far more than Vulkan.** Every shader is compiled to Metal once, which explained some
  first-session freezes, but later DXMT sessions kept hitching, including at startup, and weren't
  playable. Counting the game's 5 s+ lock waits (`RtlpWaitForCriticalSection ... wait timed out`):

  | Run | Lock waits |
  |---|---|
  | Vulkan (Auto), MSync on, through login | 3 |
  | Vulkan (Auto), MSync on, into the world, `+seh,+unwind` | 0 |
  | DXMT, MSync on, 621 s | 59 (40 loader, 13 unnamed, 6 heap) |
  | DXMT, MSync off, first 161 s | 5 (1 loader, 2 unnamed, 2 heap) |

  The runs log different amounts, so the counts are rough, but DXMT is clearly the main source and
  MSync makes it worse. The bottle went back to Auto (Vulkan) with MSync off; whether that stays
  smooth, and whether the white UI blocks come back, is the next test. That session's log also showed loader-lock
  waits of 5 s or more, with the holder changing between threads and nothing being loaded at the
  time; they weren't investigated further, since the freezes went away with the shader cache.
- **One crash on entering the world**, in the Vulkan run before switching to DXMT: Wine logged
  `call_seh_handlers invalid frame 6fffffefe6ac (0000000000052000-0000000000150000)` and
  `Exception frame is not in stack limits => unable to dispatch exception` on the game's main thread.
  The stack walk reached a "frame" inside `ntdll`'s image, the same kind of wrong unwind as the logo
  freeze ([17](17-arm-logo-freeze.md)). It didn't happen with `endfield.exe:+seh,+unwind` tracing on,
  which handles about 9,800 exceptions per world load (9,554 of them C++ `e06d7363`), so it looks
  timing-dependent.
- **`DXMT_ENABLE_NVEXT` and `D3DM_ENABLE_METALFX`** were both set in that bottle. With them the game
  tries DLSS, and CrossOver logged `HACK: redirecting nvngx.dll to D3DMetal original`, whose target
  is x86_64-only on ARM. `D3DM_ENABLE_METALFX` does nothing on ARM. Turning them off wasn't needed
  for the stutter and hasn't been tested.

### Server connection timeout

Later in the same DXMT session the game logged `[Error] [Network] Server connection timed out`
(`Player.log`, frame 6271) while still running. ACE did nothing new; its service ran only at start.
The Wine log shows process-wide stalls around it, all on the game:

- a wait of 5 s or more on the **main process heap lock** (`heap.c: main process heap section`);
- more 5 s+ waits on `loader_section` and on an unnamed lock, with one thread (`0848`) holding it
  while several waited.

With enough threads blocked, the game can't answer the server in time, so the timeout is most likely
a symptom of the stalls. A thread holding the heap lock for seconds is stopped, not working. Two
suspects:

- **MSync** (`WINEMSYNC=1`), which replaces how Wine waits on locks and events and is untested on
  CrossOver ARM. Turning it off is the next test.
- **Thread suspension**: another thread (the game's protection, or CrashSight) suspending a thread
  that holds a lock, which is slower under ARM64EC. `NtSuspendThread` has no trace in Wine 11.21, so
  this needs server-side tracing.

The first session's freezes, which went away with the shader cache, may have hidden some of these
stalls.

## Open

- **The ARM stalls behind the server timeout** (above): mostly a DXMT problem, partly MSync.
- **Vulkan's white UI blocks**, if they persist on Auto. The ARM payload now replaces CrossOver
  ARM's stock MoltenVK 1.2.10 with the patched 1.4.2 built for arm64 (`MVK_ARCH=aarch64
  scripts/build-moltenvk.sh`, which needed `aarch64` mapped to Xcode's `arm64`). Whether that cures
  them is untested; MoltenVK's 16-sampler limit is the other lead. With it, the launcher draws through
  desktop OpenGL instead of ANGLE, which the launcher-alpha library now handles
  ([16](16-launcher-black-margin.md#with-the-patched-moltenvk-the-opengl-path)).
- **The patcher's ARM defaults** (DXMT, MSync on) don't match the recommendation in
  [graphics-performance.md](../graphics-performance.md#crossover-arm-experimental-recommended-settings)
  (Auto, MSync off).
- **Whether ACE needs its drivers on ARM at all.** It has stayed quiet through login and play
  without them. Whether it loads them later, or whether the servers notice their absence over a
  longer session, is still unknown.
- **The world-entry crash** (above), if it comes back under DXMT.
- **Why that bottle had no backend and both upscaler keys.** Automated Setup writes one upscaler key
  for the chosen backend, so they were probably changed afterwards; check the patcher's bottle
  settings for ARM.
- When a newer preview ships, check its base again. If it moves past 11.21, retarget `ARM_WINE_TAG`
  and add its `ntdll.dll` to `ArmNtdllFix.builds`.
