# patches/

The Wine patches that make Arknights: Endfield run on Apple Silicon macOS. All are applied to CrossOver 26.3's Wine 11.0 source. Full story: [../docs/13-working-solution.md](../docs/13-working-solution.md).

```
STAGE 1  EndfieldBase.dll (VMProtect/TenProtect "tpshell") faults on a plain 0F 1F NOP that Rosetta 2
         wrongly rejects → execute-fault loop at 0x6CD268 → stack overflow.   ✅ FIXED (stage1-macos)
STAGE 2  ACE init: missing ntoskrnl exports + KiUser*Dispatcher detection + timing + a privileged
         CR3 read Rosetta mis-reports.                                        ✅ FIXED (dwproton + stage1-macos)
```

## Layout

```
patches/x64/   the full series for CrossOver 26.3 (x86_64 Wine under Rosetta 2)
patches/ARM/   the series for the ARM variant, on public Wine 11.21
```

`patches/x64/moltenvk` serves both variants. The sections below describe `patches/x64/`.

`patches/ARM/` targets Wine 11.21, the base of CrossOver ARM preview 20261111 (build 27.0.0.41303).
The PE modules must come from the same Wine release as the CrossOver ARM build, because
`ntoskrnl.exe` talks to CrossOver's own wineserver and 11.18 renumbered the requests it uses. The
series keeps the x64 folders and numbering. The `em-backports` and our `KeCapturePersistentThreadState`
stub (`stage1-macos/0014`) are gone, because Wine 11.21 includes them; `stage1-macos/0010`, `0012`
and `ace-core/0017` were rebased. Only `ntoskrnl.exe`, `rundll32.exe` and `wdfldr.sys` are shipped
from it, so the `kernel32`, `ntdll`, `wintrust` and `win32u` patches there have no effect yet. See
"CrossOver variants" in [`patcher-app/README.md`](../patcher-app/README.md).

`stage1-macos/0010` to `0013` let ACE's ARM64 drivers start: a `wdfldr.sys` stub and `ntoskrnl` fixes.
`stage1-macos/0014` makes `CancelIPChangeNotify` wait for the cancelled request to finish; without it
the late status write corrupted freed memory in the game and crashed `GetAdaptersAddresses`. It goes
into `nsi.dll`, which is built as ARM64X from a second, `arm64ec,aarch64` build tree (doc 19).
See [17-arm-logo-freeze.md](../docs/project-information/17-arm-logo-freeze.md).

`winemac-shim/fwalpha.m` is the ARM version of `stage1-macos/0009` (the launcher's black margin).
CrossOver ARM's `winemac.so` can't be rebuilt, so this library applies the same change at runtime,
for both the Metal and the OpenGL drawing paths, and the patcher adds a load command for it to
`winemac.so`. `patches/x64/moltenvk` also serves ARM: the ARM payload carries an arm64 build. See
[16-launcher-black-margin.md](../docs/project-information/16-launcher-black-margin.md).

## `stage1-macos/` — our macOS/Rosetta-2 fixes (+ build + msync fixes)

Original to this project. The two Rosetta fixes live in `dlls/ntdll/unix/signal_x86_64.c` (`segv_handler`, `TRAP_x86_PRIVINFLT`):

- `0001-macos-rosetta-signal-fixes-nop-and-privinstr.patch`
  - **`0F 1F` NOP skip** — Rosetta raises an illegal-instruction fault on the multi-byte NOP VMProtect emits pervasively; CrossOver's `handle_cet_nop` handled `0F 1E` but not `0F 1F`. We decode the NOP length and advance past it. *Cleared stage 1.* ([../docs/12-stage1-protector-fault.md](../docs/12-stage1-protector-fault.md))
  - **Privileged-instruction fix** — Rosetta reports `mov reg,cr3` (ACE-BASE.sys's anti-VM CR3 read) as invalid-opcode instead of `#GP`, so Wine handed ACE `EXCEPTION_ILLEGAL_INSTRUCTION` where Linux gives `EXCEPTION_PRIV_INSTRUCTION`; we call Wine's existing `is_privileged_instr()` on the Rosetta path and deliver the right code. *Cleared ACE "driver error 13."* ([../docs/13-working-solution.md](../docs/13-working-solution.md))
  - Contains an optional `CWC-ILLEGAL-INSTR` debug `ERR` line (harmless; remove for production).
- `0000-build-fix-win32u-vulkan-soname-fallback.patch` — lets the minimal (no-vulkan) build compile.

- `0004-ntdll-don-t-close-the-msync-alert-index-on-thread-exit.patch`, in `dlls/ntdll/unix/thread.c`:
  - Skips closing `alert_fd` on thread exit under MSync: it holds a shared-memory index owned by the server. Closing it can close another thread's wineserver pipe and cause Unity's "SuspendThread loop failed" error.
- `0005-msync-fix-waitall-rollback.patch`, in `dlls/ntdll/unix/msync.c`:
  - When another thread wins an object partway through a WaitAll, the rollback now leaves recursively owned mutexes alone, restores abandoned mutexes as abandoned, and wakes waiters on every object it puts back. Test: `python3 tests/test-msync-waitall.py <wine-src>`.

- `0006-msync-server-one-waiter-node-per-thread.patch`, in `server/msync.c`:
  - A multi-object wait that returns early (an object became available while the client spun) leaves its registration in the wineserver until the object is signaled. On a rarely signaled object, such as a quit event, every lost race added another node for the same thread: the node pool ran out, the server printed a warning on every allocation and grew by about 1 MB/s. `add_tid()` now skips a thread that is already on the list, so each object holds at most one node per thread, and the warning prints once. The client is unchanged. Test: `tests/fixtures/msync-wait-stress.c` (build and run instructions in the file).
- `0007-ntdll-replace-stale-ntdll-symlink-in-winetemp-dir.patch`, in `dlls/ntdll/unix/loader.c`:
  - CW HACK 22144 re-execs each process through a link to the loader in `$TMPDIR/winetemp-<loader inode>-…/`, next to an `ntdll.so` symlink. The folder is keyed on the loader's inode, which survives renaming or moving the app, but the symlink was only created once, so after a rename every process fails with `could not load ntdll.so`. The symlink is now replaced atomically each time.
- `0008-rundll32-don-t-create-a-visible-window.patch`, in `programs/rundll32/rundll32.c`:
  - rundll32's helper window was created with `WS_VISIBLE`. On macOS 26 (Tahoe) that makes
    winemac.drv foreground the process (`transformProcessToForeground`), whose activation
    callbacks re-post display-change events and the clipboard manager's 2 s timer
    (`CLIPBOARD_UPDATE_DELAY`), re-entering the `CreateWindowW` message pump — rundll32 never
    reaches `InstallHinfSection`, and bottle creation dies at
    `setup:error: 'rundll32 win11Install crossover.inf' failed` / hangs (WineHQ **bug 59595**,
    reported against prefix creation on macOS 26 in March 2026; no fix merged upstream as of
    Wine master, and CrossOver 26.3 still carries the `WS_VISIBLE` window). The window is only
    a message sink for the called entry point, so the patch keeps it hidden on every platform —
    which also stops rundll32 stealing focus during bottle creation. macOS 27 is unaffected
    either way (verified on a macOS 27.2 machine: bottle creation succeeds before and after the
    patch, ~14-17 s). This is why `rundll32.exe` is now part of the shipped module set
    (`build-wine.sh` MODULES, `package.sh`, `apply-modules.sh`, `swap-into-crossover.sh`, and
    the patcher's payload) and why it is ad-hoc signed like `wineserver` (an exec'd Mach-O).

- **`0013-winemac-the-dock-shows-a-program-s-largest-icon-drawn-as-a-mac-app-icon.patch`** —
  `runtime/0030` done for CrossOver's older Mac driver. Every size of a program's icon reaches the
  Dock (the bitmap sizes were read off a reused stack and lost). The program's own icon is read
  once per process, not on every new window; that replaces CrossOver's Helldivers 2 hack. A
  window's larger icon replaces it, but Wine's stand-in logo never does. Icons are drawn the way
  FineWine draws them (every size up to 1024 pixels, a shape sized by its visible part, small
  icons crisp) in place of CrossOver's mask, which stays as the fallback. `FINEWINE_MAC_ICONS=0`
  turns the drawing off. Ships `winemac.so` and its Windows half `winemac.drv`. x64 only: the
  ARM payload is built from upstream Wine, whose `winemac.drv` would not match CrossOver ARM's
  own `winemac.so`. The runtime's Chinese, Japanese and Korean font work (`runtime/0029`) is
  FineWine's only, by the user's decision.
- **`0012-ntdll-use-pipe2-only-where-macos-has-it.patch`** — `pipe2()` exists from macOS 27
  only, and the SDK declares it with no availability annotation, so modules built with the
  macOS 27 SDK called it unconditionally and crashed on macOS 26 and older at the first pipe
  (bottle creation failed at "'rundll32 win11Install crossover.inf' failed"). It is now a weak
  reference used only when present, with Wine's `pipe()` fallback otherwise. See
  `scripts/lib/macos-gated-apis.txt`.
- **`0009-winemac-composite-the-alpha-of-blur-behind-windows.patch`** and
  **`0010-dwmapi-mark-blur-behind-windows-for-the-mac-driver.patch`** — remove the black
  margin around the Gryphline launcher. The launcher is a rounded Qt window inside a transparent
  margin; it calls `DwmEnableBlurBehindWindow`, and on Windows DWM composites that alpha. dwproton
  fixes the same symptom in `winex11` (commit `50182fc3f58c`), which macOS doesn't use, so this is a
  separate `winemac` implementation. `0010` marks windows that request blur-behind with a window
  property and pokes the driver with a no-op `SetWindowPos`. For those windows only, `0009` keeps
  per-pixel alpha across `SetLayeredWindowAttributes`, makes the Metal view and layer non-opaque,
  and stops the window surface drawing behind the Metal view. No paths or executable names are
  checked, so the game stays opaque wherever it is installed (issue #87). See
  [docs/project-information/16-launcher-black-margin.md](../docs/project-information/16-launcher-black-margin.md).

- **`0011-win32u-reuse-client-surfaces-on-swapchain-recreation.patch`** — backports Wine 11.16's
  client-surface lifetime fix to CrossOver 26.3's Wine 11.0 API. Reuses the macOS surface after
  Endfield recreates its swapchain, preventing DXMT's white/blank output after resolution,
  display-mode, V-Sync, or focus changes (issue #82).
  This is why `winemac.so` and `dwmapi.dll` are part of the shipped module set; `winemac.so`
  needs the same `lib64` rpath as `ntdll.so`.

## `stage2-dwproton/` — the ported dw-proton anti-cheat patches

The Endfield-relevant subset of dw-proton's fix commit `b816be489`, from the `dawn-winery/dwproton-mirror` (fetched by [`../scripts/fetch-dwproton-patches.sh`](../scripts/fetch-dwproton-patches.sh)). Analysis: [../docs/02-dwproton-ace-patches.md](../docs/02-dwproton-ace-patches.md).

- `misc/0009…` — int3-stub `GetProcAddress` spoof of `KiUserApcDispatcher`/`KiUserCallbackDispatcher` (`/* workaround for tpshell */`; fired 2× in the working run).
- `misc/0010…` — gates the int3 hack to `Endfield.exe` / `EM-Win64-Shipping.exe`.
- `misc/0011…` — `NtDelayExecution` relative-wait via QueryPerformanceCounter (ACE is timing-sensitive).
- `misc/0008…` — wintrust winex11/winewayland bypass. **macOS-irrelevant** (targets `winex11.drv`); applies cleanly, does nothing on `winemac.drv`; kept for completeness.
- `em-backports/0001-0017…` — the `ntoskrnl.exe` functions ACE calls (`KeAcquireGuardedMutex`, `PsGetProcessImageFileName`, `MmGetPhysicalMemoryRanges`, …). `0010` (`PsGetProcessImageFileName`) is the exact WineHQ-bug-59411 Linux blocker.
- `ace-core/` — **new (Oct 2026): support for the new `ACE-CORE<version>.sys` anti-cheat driver** that replaced `ACE-BASE.sys` and made the game stop launching (`KeBugCheckEx 0x65636157`). Ported from the downstream fork [`mary-ext/crossover-wine-endfield`](https://github.com/mary-ext/crossover-wine-endfield), which solved it. Full analysis: [../docs/project-information/14-ace-core-regression.md](../docs/project-information/14-ace-core-regression.md).
  - `0001` — the new `ntoskrnl.exe` imports CORE requests but Wine lacks: `PsGetCurrentThreadTeb`, `KeIpiGenericCall`, `KeTryToAcquireGuardedMutex`, `KeSetSystemGroupAffinityThread`, `KeRevertToUserGroupAffinityThread`, `KeGetProcessorNumberFromIndex`, `ObDereferenceObjectDeferDelete`, plus a `KeGetCurrentIrql` stub. (⚠️ necessary plumbing, **not** the bugcheck fix on its own.)
  - `0002` — update the driver security cookie once relocation has happened.
  - `0003` — **the bugcheck fix:** call `DriverInit` with bits 48–63 of the return address set (`0xFFFF800000000000`), so ACE-CORE's "called by the kernel?" check passes. Ported from dwproton `09a9cb034e`.
  - `0004` — `MmCopyMemory` stub (+ `MM_COPY_ADDRESS` in `wdm.h`). dwproton `593daa15ba`.
  - `0005` — pass only the bare service name in `DriverExtension->ServiceKeyName` / to `DriverInit`. dwproton `4acd1acf8a`.
  - `0006` — implement `PsGetProcessExitStatus` (was a `@ stub`). macos/0005 downstream.
  - `0007` — add an `lsass.exe` stub and start it from `wineboot` (ACE-CORE scans the process list for `lsass.exe` and fails `DriverInit` without one). macos/0007 downstream. **Shipping this also swaps `lsass.exe` + `wineboot.exe`** — see `scripts/{build-wine,package,apply-modules,swap-into-crossover}.sh` and the patcher payload.
  - `0008`–`0014` — kernel objects for tokens/directories (server), the MDL/section-view implementations, remaining imports/stubs, upstream alignment, and the `PsGetContextThread` thunk. See [../docs/project-information/14-ace-core-regression.md](../docs/project-information/14-ace-core-regression.md) §12–§13.
  - `0015` — real `ObRegisterCallbacks`/`ObUnRegisterCallbacks` + the `OB_OPERATION_HANDLE_*` constants, dispatching pre/post callbacks from `ObReferenceObjectByHandle`. ACE-CORE's process/thread handle-operation callbacks now actually run (previously a fake-success stub) — a correctness improvement, but it does **not** satisfy the `"Tace"` watchdog (which needs cross-process routing). See [14 §13.9](../docs/project-information/14-ace-core-regression.md).
  - `0016` — implement `IoThreadToProcess` (`PETHREAD → PEPROCESS`; was `@ stub`). Needed because ACE-CORE's Ob pre-op callback (reachable via `0015`) calls it; without it the driver host aborted into WineDbg.
  - `0017` — **experimental, tested negative:** make the process/thread `PsSet*NotifyRoutine` exports register/dispatch real callbacks (from `create_process_object`/`create_thread_object`). The dispatch fires on hardware, but `KeBugCheckEx 0x65636154` ("Tace") still occurs — so ACE-CORE's runtime ~1 s watchdog waits on something else. Kept for reference. See [14 §13.9](../docs/project-information/14-ace-core-regression.md). (`0015`–`0017` are numbered in *apply* order: Ob → `IoThreadToProcess` → notify.)
  - `0018` — **cross-process Ob handle notifications** (`server/` + `ntoskrnl` + regenerated protocol headers). Adds `IRP_CALL_OB` and `ob_register_callbacks`/`ob_unregister_callbacks` (**appended at the end of `protocol.def`** — inserting mid-file shifts every later `REQ_*` and crashes not-rebuilt client modules), an `ob_managers` list with `notify_ob_operation()` that queues a notification to each interested device manager from `open_process`/`open_thread`, and ntoskrnl `dispatch_ob` that resolves the pid/tid and invokes the registered callbacks. Verified on hardware: the cross-process path fires ~18,000× — but `"Tace"` still fires (it is **not** an Ob/handle watchdog). Correctness feature, not a fix. See [14 §13.9](../docs/project-information/14-ace-core-regression.md).
  - `0019` — **cross-process load-image notifications** (the last untried callback family). Adds `IRP_CALL_IMG` (image name carried in the IRP input buffer), fires it from `server/mapping.c:add_process_view` on every `SEC_IMAGE` view, and on a manager's registration **replays** all currently-mapped PE images (`replay_image_loads()`); ntoskrnl `dispatch_img` invokes `PsSetLoadImageNotifyRoutineEx` callbacks. Verified on hardware: ~2,960 image-load callbacks delivered across all processes (incl. the launcher/game modules), yet `"Tace"` still fires. **Closes the callback hypothesis** — `Tace` is not callback-driven. See [14 §13.9](../docs/project-information/14-ace-core-regression.md).

## `moltenvk/`

Applied by `scripts/build-moltenvk.sh` to MoltenVK v1.4.2 and its pinned SPIRV-Cross revision (`spirv-cross/*`). Builds an x86_64 `libMoltenVK.dylib` into `build/moltenvk-out`. Ported from [mary-ext/crossover-wine-endfield](https://github.com/mary-ext/crossover-wine-endfield/tree/main/patches/moltenvk); the set is applied as a series — `0004` depends on `0002`/`0003` and `0006` depends on `0002`, so none may be omitted. `0007` is original to this project, hence the interleaving.

- `spirv-cross/0001-msl-fence-device-scope-control-barriers.patch`: adds device-scope atomic fences around control barriers (MSL 3.2+). `threadgroup_barrier` alone leaves cross-threadgroup reads stale on Apple GPUs. Fixes the stuck work-queue shader in Snowy Forest.
- `0001-reject-pipeline-caches-without-the-barrier-fix.patch`: sets bit 31 of the Metal-features word in `pipelineCacheUUID` to reject cached MSL without the fences.
- `0002-use-metal-hazard-tracking-instead-of-barrier-fences.patch`: replaces per-stage `MTLFence`s with Metal's per-resource hazard tracking (`useResource`) so unrelated GPU passes can overlap. Retains the residency set.
- `0003-compile-shader-libraries-outside-the-pipeline-cache-lock.patch`: converts SPIR-V and compiles `MTLLibrary` objects outside the pipeline-cache lock (a per-module lock prevents duplicate compilation), and compiles libraries from a loaded cache in parallel.
- `0004-defer-cached-shader-libraries-and-replay-recorded-pipelines.patch`:
  - Compiles cached `MTLLibrary` objects on first use or in the background. Shares libraries with identical MSL and compile options.
  - Saves pipeline descriptors for background replay to warm Metal's shader cache. Verifies that each new recipe reconstructs the original descriptor; stores recipes after shader libraries so older readers ignore them.
  - `MVK_CONFIG_PIPELINE_CACHE_BACKGROUND_WORKERS` sets the worker count (default 4; 0 disables background work).
  - Retrieves and specializes Metal functions without the device-wide lock.
- `0005-make-vertex-positions-invariant.patch`: makes vertex and tessellation evaluation shader positions invariant so depth prepasses and subsequent EQUAL depth tests agree. Fixes TAA smearing.
- `0006-reuse-resource-tracking-nodes.patch`: reuses resource-table nodes across Metal encoder passes within one command encoder, invalidating usage with a generation counter (cleared on generation wrap or when more than 4096 nodes are retained). Uses a pointer-specific hash and power-of-two buckets to reduce lookup overhead. Metal resource-use calls are unchanged.
- `0007-don-t-hang-vkWaitForPresentKHR-on-a-stalled-present-completion.patch`: *(original to this project, not from mary-ext)* keeps `vkWaitForPresentKHR` (`VK_KHR_present_wait`) from freezing the picture.
  - Advances the completed-present ID from three independent events, so a single stalled Metal callback cannot strand a waiter: a newer present being queued (all older IDs are then displayed or superseded), the drawable actually being presented (`endPresentation` — the event the extension is defined against), and the command buffer completing (the pre-existing path, via `markPresentIdCompleted`).
  - Bounded waiting: `waitForPresent` polls in 100 ms slices and, after a 1 s grace, treats a never-signalled present as complete. The previous code passed the app's timeout straight to `condition_variable::wait_for`; a `UINT64_MAX` timeout overflowed the absolute deadline and degenerated into a busy spin — on Endfield (which uses `VK_KHR_present_wait2`) that hung the game on the last presented frame indefinitely.
  - Propagates a lost device/surface (`VK_ERROR_DEVICE_LOST` / `VK_ERROR_SURFACE_LOST_KHR`) instead of waiting on a present that can never complete. After a Metal GPU hang or page fault, `MVKQueue::handleMTLCommandBufferError()` marks the device lost, but the old predicate only checked `VK_ERROR_OUT_OF_DATE_KHR`, so the app kept looping in the wait with no way to learn the device was gone.

Known residual: ACE also called `ntoskrnl.exe.PsGetProcessExitStatus`, which dw-proton's maintainer found "not really related"; one background ACE thread used to abort on it. It is now implemented by `ace-core/0006`, so that abort is gone.

## Applying
All 31 patches are unified diffs and apply cleanly with `git apply` in this order: `em-backports/*` (numeric) → `misc/*` (numeric) → `ace-core/*` (numeric) → `stage1-macos/*` (numeric). This is automated by [`../scripts/build-wine.sh apply`](../scripts/build-wine.sh). Expect to rebase if CrossOver's Wine base changes (the dw-proton set targets the `b816be489` snapshot; the latest lives baked into `dawn.wine/dawn-winery/wine-dwproton` branch `base`).

## License / provenance

These patches modify **Wine** (https://www.winehq.org/), which is **LGPL-2.1-or-later**. As derivative works of LGPL code, **all patches here are LGPL-2.1-or-later** — the project's top-level MIT license (which covers `scripts/` and `docs/`) does **not** apply to this directory.

[Wine](https://www.winehq.org/) patches are licensed LGPL-2.1-or-later; `moltenvk/` patches, Apache-2.0 like MoltenVK and SPIRV-Cross. `stage2-dwproton/*` retain upstream authorship (Etaash Mathamsetty, Ziia Shi / mkrsym1, NelloKudo and other dw-proton contributors).

This directory does not contain Wine itself — only diffs to be applied to a Wine source tree you fetch separately.

## `runtime/` — FineWine's own Wine runtime

Applied by `scripts/build-finewine-runtime.sh` on top of `patches/ARM` (minus the two x86-only
kernel32 patches, which cannot be built as ARM64EC), against upstream Wine 11.21.

- `0001-msync-mach-semaphore-synchronization.patch` adds MSync as the macOS implementation of
  Wine's in-process synchronisation interface. The code comes from the Wine tree CodeWeavers
  publishes for CrossOver 26.3 (LGPL-2.1-or-later), with this project's fixes, moved from Wine
  11.0 to 11.21. It changes the server protocol, so the script runs `tools/make_requests` after
  applying. With `WINEMSYNC=1` a prefix boots and the server reports MSync running.
- `0002-macos-arm64-run-without-x18-or-low-memory.patch` lets Wine start on a stock Mac. macOS
  clears register x18 (where Windows on ARM keeps the TEB) and gives an ARM64 process no memory
  below 4 GB unless it holds an Apple-issued entitlement. The patch reads the TEB from
  thread-specific data slot 6 instead, moves the shared data page to `0x17ffe0000`, and links
  the loader with macOS's default layout. It covers code built from this tree only.
- `0003-ntdll-writable-and-executable-pages-on-macos-arm64.patch` makes
  `PAGE_EXECUTE_READWRITE` memory work. macOS will not map ordinary memory writable and
  executable at once, so such a page is switched between the two on demand. Programs that
  generate code at run time, which includes any x64 emulator, need this.
- `0004-ntdll-emulate-reads-of-the-shared-data-page-on-macos.patch` handles code that still
  reads the Windows shared data page at `0x7ffe0000` (third-party ARM64 programs, and x64
  programs under FEX): the fault handler performs the read from the page's real location.
- `0005-ntdll-repair-teb-accesses-made-through-x18-on-macos.patch` repairs TEB accesses made
  through x18 by code not built from this tree: prebuilt toolchain start-up code linked into
  DLLs, compiler-generated thread-local accesses, and third-party ARM64 programs.
- `0006-ntdll-search-winedllpath-before-the-built-in-directory.patch` lets a DLL folder named in
  `WINEDLLPATH` replace Wine's built-in DLLs, which is how a prefix selects DXMT.
- `0007-d3d12-winedxgi-keep-direct3d-12-working-with-another-dxgi.patch` keeps Direct3D 12
  (vkd3d on MoltenVK) working in a prefix that has DXMT selected. It builds Wine's DXGI a second
  time as `winedxgi.dll`, which DXMT never replaces, and has Direct3D 12 use it.
- `0008-wined3d-report-an-apple-gpu-as-what-it-is.patch` makes Wine's built-in Direct3D report
  an Apple GPU by its real name ("Apple M3"), Apple's vendor id and half the shared memory,
  instead of a placeholder NVIDIA card. These are the values DXMT reports.
- `0009-vkd3d-let-nvngx-record-metalfx-work-in-a-command-list.patch` gives Direct3D 12 two
  private data GUIDs through which `nvngx.dll` gets a texture's VkImage and records DLSS work
  in a command list, to be carried out by MoltenVK as MetalFX.
- `0034-ntdll-a-memory-log-for-a-running-program.patch`: `FINEWINE_MEMORY_TRACE=<folder>` makes
  each process write `<program>-<pid>.log` there: every memory operation of 8 MB or more
  (`FINEWINE_MEMORY_TRACE_MIN`) with its thread and likely callers, and totals with the footprint
  every five seconds. FineWine's "Play with Memory Log" sets it. Checked by
  `tests/runtime/memtrace.c`.
- `0035-ntdll-commit-the-arm64ec-code-map-as-it-is-read-on-macos.patch`: Wine's map of which
  pages hold ARM64EC code is 4 GB and was committed in full, read-only. On macOS a page that is
  read becomes real memory, so a program that reads through its committed memory paid for all
  of it (3.6 GB in Arknights: Endfield). The map now starts reserved and a page is committed
  when it is first read. Tested by `tests/runtime/scan-memory.c` together with fex 0005. Threads that
  fault on the same page at once all get through (`tests/runtime/code-map-race.c`; the first
  version of this patch crashed there).
- `0036-ntdll-zero-pages-for-macos-behind-a-switch.patch`: with `FINEWINE_ZERO_PAGES=1`,
  memory from NtAllocateVirtualMemory and thread stacks is backed by private mappings of one
  32 MB file of zeroes instead of anonymous memory, so reading memory that was never written
  costs nothing, as on Linux. The first write to a page is about 1 µs slower. Off by default
  until it has been run with games.
- `0037-ntdll-a-switch-to-commit-the-arm64ec-code-map-whole.patch`: `FINEWINE_EAGER_CODE_MAP=1`
  commits the map whole again, as before `0035`. Costs up to 4 GB; for finding a fault only.
- `0038-win32u-report-hardware-gpu-scheduling.patch`: `D3DKMTQueryAdapterInfo` answers
  `KMTQAITYPE_WDDM_2_7_CAPS` with hardware GPU scheduling on, which Streamline reads before
  frame generation is offered.
- `0033-winemac-read-the-displays-again-on-activation-only-when-they-changed.patch`: switching
  to a Wine program made Wine read every display again (modes, EDID, GPUs, registry keys) on the
  program's message thread, 2.4 seconds in a game. Now only when the displays differ from what
  Wine was last told. `FINEWINE_DISPLAY_RESYNC=always` brings the old behaviour back. Checked by
  `tests/runtime/idle-window.c` with `activate.swift` (`FINEWINE_TEST_ACTIVATE=1`).
- `0032-winemac-a-program-s-bundle-carries-its-icon-for-game-mode.patch`: the program's bundle in
  the prefix gets the icon as `AppIcon.icns`, which is what Game Mode's menu and notice show.
- `0031-ntdll-jump-past-macos-mappings-when-looking-for-free-memory.patch`: the search for free
  address space jumps past macOS's own mappings instead of stepping through them 64K at a time
  (creating 300 x64 threads: 420 s to 0.2 s). Checked by `tests/runtime/threads.c`.
- `0030-winemac-the-dock-shows-a-program-s-largest-icon-drawn-as-a-mac-app-icon.patch`: only one
  picture of a program's icon ever reached the Dock (Wine read the icon list off the program's
  stack after reusing it), 16 pixels as often as 256; now every size does. A window's icon
  replaces the program's when it is larger: a whole group from whichever module it was loaded
  from, or the icon itself if it was made at run time. Wine's stand-in logo for windows without
  an icon never does. The icon is drawn on Apple's icon grid, the rounded square of a Mac app
  icon: a square picture fills it, any other shape stands on a light plate.
  `FINEWINE_MAC_ICONS=0` turns the drawing off. Checked by `tests/runtime/app-icon.c`.
- `0029-win32u-dwrite-chinese-japanese-and-korean-text-with-the-mac-s-own-fonts.patch`: Chinese,
  Japanese and Korean text drew as empty boxes in every font, through GDI and DirectWrite
  (Chromium launchers), because Wine's font links and DirectWrite's fallback name Windows' and
  Linux's CJK fonts. `wine.inf` now maps the Windows names ("MS Gothic", "Microsoft YaHei",
  "PMingLiU", "Malgun Gothic", ...) to the Mac's own fonts (Hiragino, Songti, Heiti, Apple SD
  Gothic Neo) under `HKCU\Software\Wine\Fonts\Replacements`, which both read. The links then
  resolve, and are picked by the ANSI code page when MS Shell Dlg is set to a font they are not
  keyed on. DirectWrite falls back to the Windows names too, and matches a region locale
  ("zh-CN") to the mappings for its script ("zh-Hans"). Checked by `tests/runtime/cjk.c`.
- `0028-ntdll-msv1_0-use-pipe2-only-where-macos-has-it.patch`: the same as
  `x64/stage1-macos/0012` for this Wine, plus the two calls in `msv1_0`.
- `0027-ntdll-arm64ec-stop-stack-walks-that-leave-the-real-frames.patch`: the source form of the
  patcher's `ArmNtdllFix` for CrossOver ARM. `RtlWalkFrameChain` stops where there is no unwind
  data (as the x86_64 version does), and `RtlIsEcCode` no longer reads past its bitmap for a
  junk address. Without them Arknights: Endfield hung at its logo, its main thread walking the
  stack for IL2CPP for good.
- `0026-winemac-dwmapi-show-what-dxmt-draws-in-windows-that-also-paint-and-keep-their-transparency.patch`:
  two fixes for launcher windows drawn with Direct3D through DXMT. A window that was also
  painted the ordinary way (Qt fills its window once) had DXMT's view hidden for good and stayed
  white; DXMT's views are no longer hidden by a paint. And a translucent window that asks
  Windows' compositor to honour its alpha (`DwmEnableBlurBehindWindow`) had its see-through
  margin drawn black; dwmapi marks such windows and the Mac driver makes them and their Metal
  layer non-opaque. The second is `patches/x64/stage1-macos/0009` and `0010` done for this Wine.
- `0025-winemac-a-display-with-a-camera-housing-is-the-part-below-it.patch`: with full-screen
  windows in a Space of their own, a display with a camera housing is reported without the rows
  the housing is in (3024x1898 on a 14-inch MacBook Pro) and Windows' screen coordinates start
  below them. A game that sizes its window to "the display" then fits its Space exactly; before,
  the bottom of the picture was cut off and clicks landed 33 points low.
  `FINEWINE_KEEP_CAMERA_ROWS=1` turns it off.
- `0024-ntdll-winemac-start-each-program-from-a-bundle-of-its-own-name.patch`: the Dock labels a
  program with the name of the app bundle its executable is in, so every program said "wine" or
  "FineWine Game" there whatever `0017` told the rest of macOS. A program is now started through
  a small bundle of its own name in the prefix (`.finewine-apps/<game or program>/<name>.app`: a
  link to the loader and the loader's Info.plist under that name). The name is worked out before
  the program starts and handed to it in `FINEWINE_PROCESS_NAME`. Windows' own programs keep the
  plain loader. `FINEWINE_DOCK_NAMES=0` turns it off.
- `0023-winemac-one-switch-for-the-metal-hud.patch`: the system's Metal HUD menu item, View >
  Show/Hide Metal HUD and the shortcuts (Control-Command-H, Option-F12) are one switch; the
  system's item did nothing before, once the layers had a HUD setting of their own.
- `0022-winemac-command-c-v-x-a-z-as-the-control-combinations.patch`: the Mac's copy, paste,
  cut, select-all and undo chords reach Windows programs as Control with the key.
  `FINEWINE_COMMAND_SHORTCUTS=0` turns it off.
- `0021-server-report-a-connected-socket-s-real-local-port.patch`: `getsockname()` on a socket
  that was connected without being bound returned port 0 on macOS. libcurl's loopback socket
  pair check then failed, and with it every name lookup of a Unity game.
- `0020-ntdll-step-past-addresses-macos-will-not-map.patch`: a search for free memory "above
  4 GB" stopped at its first step, because macOS refuses everything below the program's own
  image with an error Wine took for out of memory.
- `0019-winemac-give-dxmt-the-interface-it-presents-through.patch`: exports the
  `macdrv_functions` structure DXMT looks up to put its Metal view into a window. Without it
  no Direct3D 10 or 11 program could present ("Failed to create metal view").
- `0018-winemac-round-the-corners-of-windows-without-a-mac-title-bar.patch`: borderless app
  windows (launchers, games in a window) get a Mac window's round corners; not full-screen,
  small or self-shaped ones. `FINEWINE_ROUNDED_WINDOWS=0` turns it off.
- `0017-winemac-programs-go-by-their-own-name-and-tray-icons-show-in-the-menu-bar.patch`: macOS
  calls a program by its own name (the one FineWine lists it under, else its version
  information, else its file name) in the menu bar, Dock and app switcher, where it said "wine";
  and notification-area ("tray") icons are menu bar items again (they were made with a custom
  view, which macOS no longer shows).
- `0016-ntdll-zero-partial-host-pages-when-memory-is-decommitted.patch`: memory that is
  decommitted and committed again must read as zeroes; with the Mac's 16K pages the 4K pages at
  the ends of a range kept their contents, and Chromium's JavaScript engine crashed on them.
- `0015-kernelbase-keep-chromium-drawing-in-the-main-process-in-software.patch`: programs with Chromium's
  files beside them (CEF, Electron) get `--in-process-gpu --disable-gpu --disable-gpu-compositing`: neither DXMT nor the Mac driver
  can draw into a window from a process that does not own it, which is what Chromium's GPU process does.
  `FINEWINE_CHROMIUM_FLAGS` names other switches, or `none`.
- `0014-ntdll-run-a-do-nothing-program-in-place-of-32-bit-runtime-setup-programs.patch`: the
  runtime cannot run 32-bit Windows programs (a native ARM64 Mac process has no memory below
  4 GB). When a program starts the 32-bit setup program of the Visual C++ or DirectX runtime
  (`vc_redist*`, `vcredist*`, `dxsetup`, `dxwebsetup`, `directx_*`, `ue4prereqsetup*`,
  `ueprereqsetup*`), a built-in program that does nothing and succeeds runs in its place, so
  the installer that started it carries on. Other 32-bit programs still fail to start.
- `0013-ntdll-keep-a-file-in-the-prefix-open-so-its-processes-can-be-found.patch` makes every
  Wine process hold `<prefix>/.finewine-alive` open, so that a frozen program can be traced to
  its prefix and ended (Force Shut Down). `ps` cannot do it: Wine overwrites a process's
  arguments and environment with its Windows command line.
- `0012-winemac-full-screen-like-mac-games-and-a-metal-hud-toggle.patch` lets a full-screen
  window live in a macOS full-screen Space of its own, or stay a borderless window on the
  desktop, instead of being raised above the menu bar; and adds a View menu and Option-F12 to
  show and hide Metal's performance overlay.
- `0011-loader-ntdll-win32u-let-a-program-run-as-a-game-for-game-mode.patch` is the runtime's
  half of macOS Game Mode: the loader works from inside the app bundle that says it is a
  game, a variable picks that copy of the loader for a program and its children, and using
  Vulkan or Direct3D 12 leaves a marker by which FineWine learns that a program renders.
- `0010-wined3d-win32u-report-the-gpu-a-prefix-asks-for.patch` lets a prefix have the GPU
  reported as another one, by name and PCI ids (an NVIDIA GeForce RTX 5080, for games that only offer DLSS
  on NVIDIA).

## `moltenvk/` (top level) — FineWine's additions to MoltenVK

Applied by `MVK_FLAVOR=finewine scripts/build-moltenvk.sh` after `patches/x64/moltenvk`, to the
MoltenVK that goes into the FineWine runtime only (`build/moltenvk-out-finewine`). The MoltenVK
builds for the CrossOver payloads do not get these. Apache-2.0, like MoltenVK.

- `0001-ray-queries-on-metal-acceleration-structures.patch` adds `VK_KHR_acceleration_structure`
  and `VK_KHR_ray_query` on macOS 15 and later: acceleration structure objects, builds, updates,
  copies, build sizes, and the descriptor type, on Metal acceleration structures.
- `0002-acceleration-structure-host-commands-serialization-and-queries.patch` adds the rest of
  that extension: building and copying on the host, the compacted-size and serialization-size
  queries, and serializing a structure and reading it back. Metal cannot serialize an
  acceleration structure, so what is written is what it was built from.
- `0003-ray-tracing-pipelines-as-one-compute-shader.patch` adds `VK_KHR_ray_tracing_pipeline`.
  Metal has no ray tracing shader stages, so a new SPIR-V pass in MoltenVKShaderConverter
  merges a pipeline's shaders into one compute shader built on ray queries, and
  `vkCmdTraceRaysKHR` dispatches it with one thread per ray.
- `spirv-cross/0001-msl-candidate-aabb-opaque-was-inverted.patch` fixes a ray query operation
  SPIRV-Cross translated to its opposite; the pipeline lowering depends on it.

- `0004-metalfx-as-a-command-and-reported-gpu-ids.patch` adds a command that records a MetalFX
  upscale or frame interpolation in a command buffer, which is what DLSS is mapped to for
  Direct3D 12 and Vulkan programs, and lets a prefix choose the GPU ids Vulkan reports.
- `0005-pipeline-cache-header-carries-the-reported-gpu-ids.patch`: with another GPU reported,
  the pipeline cache header still carried Apple's ids, so Unity (Endfield) dropped its cache and
  stopped saving it. The header now carries the reported ids.

The patches apply as a series on `0001`. Details and limits are in
[`docs/project-information/21-metal4-and-ray-tracing.md`](../docs/project-information/21-metal4-and-ray-tracing.md).

## `fex/` — the x64 emulator

Applied by `scripts/build-fex.sh` to FEX at the commit pinned in `finewine-sources.lock`.
FEX's Windows ARM64EC build is installed in the runtime as `xtajit64.dll`.

- `0001-arm64ec-read-the-teb-from-thread-specific-data-on-macos.patch` replaces FEX's ten reads
  of the TEB through x18 with the thread-specific data lookup the runtime uses.
- `0002-windows-guard-the-call-ret-stack-with-whole-host-pages.patch`: the call-return stack's
  guard pages are 64 KB, whole 16 KB Mac pages, instead of 4 KB.
- `0003-cpuid-name-an-unknown-arm-cpu-as-the-host-does.patch`: x64 programs are told the Mac's
  own name for its CPU ("Apple M3") instead of "Unknown ARM CPU" (macOS does not give programs
  the CPU ID FEX names CPUs by). The source form of the patcher's `ArmEmulatorIdentity` brand
  edit for CrossOver ARM. Its other part, the hypervisor bit, is FineWine's "Hide the hypervisor
  flag" setting (`FEX_HIDEHYPERVISORBIT=1`), on by default.
- `0004-jit-let-conditional-loops-be-suspended.patch`: a thread spinning in a loop that ends in a
  conditional jump back can be suspended. FEX looked for suspend requests only at block starts
  and unconditional jumps back, so SuspendThread + GetThreadContext on such a thread waited
  forever. Garbage collectors stop threads this way; Genshin Impact froze on its warning screen.
  Costs about 5% in a three-instruction loop, less in real ones. Tested by
  `tests/runtime/suspend-spin.c`.
- `0005-windows-commit-the-lookup-tables-a-piece-at-a-time-under-wine.patch`: each emulated
  thread reserves 272 MB for its block lookup tables. Under Wine FEX committed all of it at the
  first use; on Windows it commits 64 KB around each fault, and now does the same under Wine.
  Committed memory can be read, and on macOS a page that is only read still becomes real memory.
  Arknights: Endfield reads through its writable memory and grew to 40 GB in seven minutes.
  Tested by `tests/runtime/scan-memory.c` (16 idle threads: about 5 GB before, 370 MB after).
- `0006-rpmalloc-commit-a-page-as-its-blocks-are-handed-out.patch`: FEX's allocator committed
  a whole page at first use, 4 MB for an object up to 256 KB and 64 MB for one up to 8 MB. It
  hands blocks out in address order, so a page is now committed in 64 KB pieces as far as its
  blocks have been handed out. 6.5 GB of Endfield's 15.4 GB was in these pages. The patch
  reaches into the `External/rpmalloc` submodule; `git apply` in the FEX tree handles that.
- `0007-windows-commit-call-return-stacks-and-compile-buffers-as-they-are-used.patch`: the
  4 MB call-return stack and the 8 and 16 MB compile buffers of each thread are reserved and
  committed by the fault handler 64 KB at a time (`FEXCore::Allocator::VirtualOvercommit`).
  Only for memory that system calls never see. With 0006: 32 threads that ran 24,000 blocks
  each and then had all their memory read went from 1655 MB to 265 MB; speed unchanged.
- `0008-lookup-cache-a-compact-record-of-each-threads-cached-blocks.patch`: with
  `FEX_COMPACTBLOCKRECORDS=1`, each thread's record of the blocks it has cached is a sorted
  array of 32-bit offsets for each page of guest code instead of a hash set (about 60 bytes a
  block). Off by default; the original record is untouched. In a 32-thread test FEX's heap
  went from 103 MB to 56 MB. Tested either way by `tests/runtime/code-rewrite.c`.
- `0009-lookup-cache-remove-the-overcommit-mark-before-freeing-the-tables.patch`: an exiting
  thread freed its lookup tables and then removed their mark from the list of ranges that are
  committed on a fault; a thread starting in between could get the same address and lose its
  own mark, and then hung in exception handling. An upstream ordering bug.
  `tests/runtime/thread-churn.c` hung every time before.
- `0010-switches-to-turn-off-piecewise-commit-and-the-loop-suspend-check.patch`: for finding
  a fault without another build. `FEX_EAGERCOMMIT=1` commits lookup tables, allocator pages,
  call-return stacks and compile buffers whole again (undoes `0005`-`0007` at run time, and
  their memory saving); `FEX_NOLOOPSUSPENDCHECK=1` leaves out the check of `0004` (Genshin
  Impact then hangs again). `tests/runtime/reg-fault.c` checks that registers, flags and float
  state survive the commit faults taken in translated code.

## `dxmt/` — Direct3D on Metal

- `0001-dxgi-hand-direct3d-12-swap-chains-to-wine-s-dxgi.patch` is the DXMT half of runtime
  patch 0007: DXMT's DXGI forwards swap chain creation for a Direct3D 12 command queue to
  `winedxgi.dll`. Applied by `scripts/build-dxmt.sh` to DXMT at the commit pinned there.
- `0002-nvngx-ngx-for-direct3d-12-and-vulkan-with-frame-generation.patch` adds the Direct3D 12
  and Vulkan NGX entry points to DXMT's `nvngx.dll`, with DLSS super resolution and frame
  generation. They do no rendering themselves: each evaluation is handed to MoltenVK
  (`patches/moltenvk/0004`), for Direct3D 12 through Wine's vkd3d (`patches/runtime/0009`).
- `0003-winemetal-tell-finewine-when-a-program-starts-rendering.patch` leaves the same marker
  as runtime patch 0011 when a program starts using Direct3D 10 or 11.
- `0004-d3d11-upscale-a-picture-smaller-than-its-window-with-metalfx.patch`: a swap chain whose
  buffers are smaller than its window is in display pixels (by 5% to 4x) is upscaled to the
  window's pixels with MetalFX's spatial scaler, instead of being stretched by the window
  server. `FINEWINE_METALFX_AUTO=0` turns it off.
- `0005-nvapi-dxgi-what-streamline-asks-about-the-gpu-at-startup.patch`: adds
  `NvAPI_GetLogicalGPUFromPhysicalGPU`, where NVIDIA's Streamline stopped at startup in Endfield
  with the GPU reported as NVIDIA, and makes DXGI and NVAPI report Wine's adapter LUID so it
  agrees with `D3DKMTEnumAdapters2` and Vulkan. Whether the game then offers DLSS is untested.
- `build-arm64ec-finewine.txt` is the meson cross file `scripts/build-dxmt.sh` builds DXMT with.
  It is DXMT's own ARM64EC cross file plus one linker flag (see the comment in the file).
