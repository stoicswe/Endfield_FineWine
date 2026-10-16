# patches/

The Wine patches that make Arknights: Endfield run on Apple Silicon macOS. All are applied to CrossOver 26.3's Wine 11.0 source. Full story: [../docs/13-working-solution.md](../docs/13-working-solution.md).

```
STAGE 1  EndfieldBase.dll (VMProtect/TenProtect "tpshell") faults on a plain 0F 1F NOP that Rosetta 2
         wrongly rejects → execute-fault loop at 0x6CD268 → stack overflow.   ✅ FIXED (stage1-macos)
STAGE 2  ACE init: missing ntoskrnl exports + KiUser*Dispatcher detection + timing + a privileged
         CR3 read Rosetta mis-reports.                                        ✅ FIXED (dwproton + stage1-macos)
```

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
