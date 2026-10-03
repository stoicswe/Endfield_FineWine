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

## `stage2-dwproton/` — the ported dw-proton anti-cheat patches

The Endfield-relevant subset of dw-proton's fix commit `b816be489`, from the `dawn-winery/dwproton-mirror` (fetched by [`../scripts/fetch-dwproton-patches.sh`](../scripts/fetch-dwproton-patches.sh)). Analysis: [../docs/02-dwproton-ace-patches.md](../docs/02-dwproton-ace-patches.md).

- `misc/0009…` — int3-stub `GetProcAddress` spoof of `KiUserApcDispatcher`/`KiUserCallbackDispatcher` (`/* workaround for tpshell */`; fired 2× in the working run).
- `misc/0010…` — gates the int3 hack to `Endfield.exe` / `EM-Win64-Shipping.exe`.
- `misc/0011…` — `NtDelayExecution` relative-wait via QueryPerformanceCounter (ACE is timing-sensitive).
- `misc/0008…` — wintrust winex11/winewayland bypass. **macOS-irrelevant** (targets `winex11.drv`); applies cleanly, does nothing on `winemac.drv`; kept for completeness.
- `em-backports/0001-0017…` — the `ntoskrnl.exe` functions ACE calls (`KeAcquireGuardedMutex`, `PsGetProcessImageFileName`, `MmGetPhysicalMemoryRanges`, …). `0010` (`PsGetProcessImageFileName`) is the exact WineHQ-bug-59411 Linux blocker.

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

Known residual: ACE also calls `ntoskrnl.exe.PsGetProcessExitStatus`, which is **not** in this set (dw-proton's maintainer found that abort "not really related"); one background ACE thread aborts on it, but the game reaches login regardless. A stub would silence it.

## Applying

All 24 patches are unified diffs and apply cleanly with `git apply` in this order: `em-backports/*` (numeric) → `misc/*` (numeric) → `stage1-macos/*` (numeric). This is automated by [`../scripts/build-wine.sh apply`](../scripts/build-wine.sh). Expect to rebase if CrossOver's Wine base changes (the dw-proton set targets the `b816be489` snapshot; the latest lives baked into `dawn.wine/dawn-winery/wine-dwproton` branch `base`).

## License / provenance

These patches modify **Wine** (https://www.winehq.org/), which is **LGPL-2.1-or-later**. As derivative works of LGPL code, **all patches here are LGPL-2.1-or-later** — the project's top-level MIT license (which covers `scripts/` and `docs/`) does **not** apply to this directory.

[Wine](https://www.winehq.org/) patches are licensed LGPL-2.1-or-later; `moltenvk/` patches, Apache-2.0 like MoltenVK and SPIRV-Cross. `stage2-dwproton/*` retain upstream authorship (Etaash Mathamsetty, Ziia Shi / mkrsym1, NelloKudo and other dw-proton contributors).

This directory does not contain Wine itself — only diffs to be applied to a Wine source tree you fetch separately.
