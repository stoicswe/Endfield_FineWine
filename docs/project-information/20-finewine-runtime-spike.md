# FineWine runtime: upstream Wine on Apple Silicon without CrossOver (2026-11-14/15)

FineWine (`finewine-app/`) needs a Wine runtime of its own. This is what happened when upstream
Wine 11.21 was built for macOS ARM64 and started, and what it means for the plan.

## What works

- **It builds.** `scripts/build-finewine-runtime.sh` clones Wine 11.21, applies `patches/ARM`
  (minus two x86-only kernel32 patches) and `patches/runtime`, and builds the Mac side as arm64
  and the Windows side as ARM64X (`--enable-archs=arm64ec,aarch64`). Two things were needed:
  - `x86_64_CC=clang`. The ARM64EC modules contain a few x86_64 objects, and configure otherwise
    picks Homebrew's mingw gcc, whose assembler rejects Wine's code.
  - `SONAME_LIBMOLTENVK` set by hand, as in the other pipelines.
- **It packages** into `build/finewine-runtime` with a `runtime.json`, freetype, gnutls, SDL2 and
  MoltenVK bundled.
- `wine --version` and `wineserver --version` run.

## What does not work, and why

Upstream Wine does not start a Windows process on a stock Mac. There are two separate causes,
and both come down to the same thing: macOS gives ordinary ARM64 programs less than Windows on
ARM needs, and gives the rest only to programs carrying an Apple-issued entitlement.

### 1. No memory below 4 GB

Windows keeps a shared data page at the fixed address `0x7ffe0000`. Wine's loader is linked with
a 4 KB `__PAGEZERO` so that address can be mapped.

- macOS kills an ARM64 binary at `exec` if its `__PAGEZERO` is smaller than 4 GB. Tested with
  ad-hoc signed loaders at 0x1000, 0x4000, 0x10000, 0x10000000 and 0x80000000: all exit 137.
- With the standard 4 GB `__PAGEZERO` the loader starts, and Wine then fails with
  `map_fixed_area out of memory for 0x7ffe0000-0x7ffe1000`.
- A plain test program confirms it: `mmap(MAP_FIXED)` and `mach_vm_allocate(VM_FLAGS_FIXED)` at
  `0x7ffe0000` both fail.

An experiment got past this for Wine's own code: Wine refers to the page through seven
`user_shared_data` pointers, and pointing them at `0x17ffe0000` let a prefix be created. Programs
not built by us still read `0x7ffe0000` directly and would need those reads emulated.

### 2. The x18 register is not preserved

Windows on ARM keeps the thread's TEB pointer in register x18, and compiled Windows code reads it
directly. On macOS an ordinary process loses x18 on every trip through the kernel. A test program
that sets x18 and reads it back gets:

| After | x18 |
|---|---|
| nothing | kept |
| a `getpid` system call | kept |
| a page fault | zeroed |
| `sched_yield`, `usleep` | zeroed |
| a signal | zeroed |
| a busy loop long enough for a timer interrupt | zeroed |

A signal handler cannot put it back either: the value written into the saved context is zeroed
again on return (0 of 2000 attempts survived).

With the shared-page experiment applied, this is where Wine dies: the first Windows-side code,
`__wine_dbg_get_channel_flags` in ntdll, does `mov x8, x18; ldr x11, [x8, #0x60]` with x18 = 0.

### How CrossOver ARM does it

CrossOver ARM's loader (`lib/wine/aarch64-unix/wine.app`) is signed with
`com.apple.developer.cross-architecture-support`, backed by an embedded provisioning profile.
`com.apple.developer.*` entitlements are granted by Apple to a developer account; an ad-hoc or
ordinary Developer ID signature cannot claim one. That entitlement is presumably what gives
their process low memory, a preserved x18, and the TSO and 4 KB-page support an x64 emulator
wants. This was read from the installed app's code signature, not from any CodeWeavers source.

## What this means

- **Upstream Wine as shipped is not enough.** The plan assumed the hard part was FEX. A hard part
  comes earlier: running any Windows code at all. (Solved for Wine's own code; see Outcome.)
- **Native ARM Wine runs ARM64 Windows programs only.** Without an x64 emulator it cannot run
  x64 games, Arknights: Endfield included. Wine's own tools (winecfg, regedit, notepad) are
  ARM64 and would run.
- **FEX upstream is Linux-only.** Its Windows build is a PE DLL plus a small Unix helper that
  uses Linux `prctl` calls. On macOS it would need a port, and it also relies on x18.

## Ways forward

1. **Ask Apple for the entitlement.** It needs a paid Apple Developer account and Apple's
   approval. If granted, upstream Wine should run close to as-is, and it is the only route that
   also gives hardware TSO for fast x64 emulation. Whether Apple grants it to a project like this
   is unknown.
2. **Work inside what macOS allows.** Everything below is ordinary in-process work, not a way
   round a security control, but it is a real porting project:
   - Move the shared data page above 4 GB for code we build, and emulate reads of `0x7ffe0000`
     from code we don't.
   - Stop depending on x18 in code we build. libpthread reserves thread-data slot 6 "for
     Windows/WINE compatibility", so `NtCurrentTeb()` can read the TEB from there
     (`mrs tpidrro_el0`, mask the low three bits, load offset `0x30`) and Wine's assembly entry
     points can reload x18 the same way.
   - Third-party ARM64 code would need its x18 uses trapped and patched.
   - No hardware TSO, so an eventual FEX port would use its slower software mode.
3. **Keep CrossOver as the runtime for now.** FineWine Patcher keeps working as it does today.
   FineWine itself can already manage prefixes for any Wine folder it is pointed at.

## Outcome (2026-11-15): option 2 works for Wine's own code

`patches/runtime/0002-macos-arm64-run-without-x18-or-low-memory.patch` implements the in-process
route, and with it the runtime starts on a stock Mac with an ad-hoc signature:

- `wineboot --init` creates a prefix in about six seconds and exits 0.
- Wine Configuration (winecfg) opens a window, and MoltenVK creates a Vulkan instance.
- With `WINEMSYNC=1` the server reports `msync: up and running` and a prefix boots cleanly
  (`patches/runtime/0001`).
- FineWine's own code drives it: `RuntimeIntegrationTests` creates a prefix, applies settings and
  macOS styling, switches to MSync and runs a Windows command, all against this runtime.

What the patch does:

| Problem | Change |
|---|---|
| x18 is cleared by the kernel | `NtCurrentTeb()` reads the TEB from thread-specific data slot 6 (`mrs tpidrro_el0`, clear the low three bits, load offset `0x30`). The 14 assembly sites in ntdll that read TEB fields through x18 load it the same way. The Unix side stores the TEB in the slot when a thread starts. |
| No memory below 4 GB | The shared data page moves from `0x7ffe0000` to `0x17ffe0000` in the seven places Wine refers to it. |
| Loader killed at `exec` | On aarch64 the loader is linked with the default `__PAGEZERO` and segment alignment. |

Two things found on the way:

- Wine's PE modules are compiled in MSVC-compatible mode, where `__GNUC__` is not defined, so the
  `NtCurrentTeb()` change has to be in a branch that also matches clang.
- The first Windows thread does not go through `server_init_thread`, so its TEB is published in
  `server_init_process_done`.

### Generated code (2026-11-15)

A test program that writes ARM64 instructions into memory and calls them showed a third gap:
memory written first and then made executable ran, but a `PAGE_EXECUTE_READWRITE` page did not.
macOS refuses `PROT_WRITE|PROT_EXEC` on ordinary memory, and Wine's `mprotect` to that
combination failed silently.

`patches/runtime/0003` maps such a page writable and switches the host page between writable
and executable from the fault handler as the program writes to it and runs it. All three cases
now pass (`scripts/test-finewine-runtime.sh`): write then execute, writable and executable at
once, and code rewritten in place. An x64 emulator's translation cache depends on this.

What macOS allows, measured:

| Attempt | Result |
|---|---|
| Ordinary memory, written, then `mprotect` to read+execute | works |
| Ordinary memory mapped read+write+execute | refused (`EACCES`) |
| `MAP_JIT` memory with the per-thread write toggle | works, and is the fast path |
| `MAP_JIT` with `MAP_FIXED` | refused (`EINVAL`) |
| `MAP_JIT` at a hint address after `munmap` | works, lands at the hint |
| `mprotect` on a `MAP_JIT` region that is already read+write+execute | refused |

### High-resolution mode

New prefixes have Wine's Retina mode on and take their DPI from the display (192 on a 2x
display), so programs draw at the display's real resolution and keep their normal size. Checked
on Wine Configuration: a 406 x 434 point window is drawn with 812 x 868 pixels.

### x64 programs: FEX (2026-11-15)

FEX's Windows ARM64EC build is one DLL that Wine loads as `xtajit64.dll` for every x64 process.
It builds on a Mac with llvm-mingw (`scripts/build-fex.sh`) and needed three things to run here:

- **Its own x18 reads.** Ten places, in the entry and exit thunks and in the code the JIT emits
  around calls, loaded TEB fields through x18. `patches/fex/0001` changes them to the
  thread-specific data lookup. The mingw-w64 header definition of `NtCurrentTeb()` is changed
  the same way in the script's copy of the toolchain.
- **Writable and executable memory** for its translation cache: `patches/runtime/0003`.
- **Reads of `0x7ffe0000` by the x64 program**, which FEX turns into plain loads:
  `patches/runtime/0004`.

FEX's Linux helper library is not built. FEX treats it as optional, and what it offers (hardware
TSO, huge pages, naming memory regions) has no macOS equivalent without Apple's entitlement, so
FEX runs in its software memory-ordering mode.

`tests/runtime/x64-stress.c` passes under FEX: eight threads with events and locks, a
floating-point loop checked against a natively computed value, raising and continuing an
exception, generated x64 code rewritten in place, the performance counter, file I/O, and a
direct read of the shared data page.

Two x18 reads remain in the FEX DLL, both in the toolchain's prebuilt C++ exception support.

### Code this tree does not build: x18 repair

DXMT's DLLs showed the general problem: they link prebuilt mingw-w64 start-up code and C++
runtime that read the TEB through x18, and the compiler itself emits `ldr x9, [x18, #0x58]` for
thread-local variables. `patches/runtime/0005` repairs such accesses in the fault handler (an
access through x18 is performed for the instruction; an access through a zeroed copy of x18 gets
the TEB put in the register). That is also what makes third-party ARM64 programs workable.
Each repair costs a trap.

### Direct3D: DXMT works; GPTK cannot be used

- **Apple's GPTK (D3DMetal) cannot be loaded.** GPTK 1, 3 and 4.0 beta 3 were all examined: the
  framework, `libd3dshared.dylib`, the shader libraries and the Wine DLLs are x86_64 only, and
  the README describes running through Rosetta. An arm64 process cannot load x86_64 Mac
  libraries, and FEX translates Windows code, not Mac libraries. D3DMetal only fits a Wine that
  itself runs under Rosetta, which is what the patcher's x64 variant uses.
- **DXMT** (Direct3D 10 and 11 on Metal) is built as ARM64X by `scripts/build-dxmt.sh` and
  installed in the runtime. `tests/runtime/d3d11-clear.c` creates a device (feature level 11.0,
  adapter "Apple M3"), clears a render target on the GPU and reads the pixel back correctly,
  both as an ARM64 program and as an x64 program under FEX.
- A prefix selects DXMT through `WINEDLLPATH`, which needed `patches/runtime/0006`. DXMT's
  Metal bridge (`winemetal.dll`/`.so`) lives with Wine's own DLLs, because Wine only loads a
  built-in DLL that has a file in the prefix.
- **WineD3D is not a usable fallback for Direct3D 11** on macOS: device creation fails.
- **Direct3D 12 and Vulkan work in every prefix, through MoltenVK.** Direct3D 12 is Wine's own
  (vkd3d on Vulkan). `tests/runtime/d3d12-clear.c` creates a device, clears a render target on
  the GPU, reads the pixel back, then creates a swap chain on a hidden window and presents a
  frame; `tests/runtime/vulkan-device.c` creates a Vulkan instance and device ("Apple M3",
  Vulkan 1.1). Both pass as ARM64 and as x64 under FEX.
- **Direct3D 12 alongside DXMT** needed work, because with DXMT selected `dxgi.dll` is DXMT's
  and Wine's Direct3D 12 depends on Wine's DXGI. `patches/runtime/0007` builds Wine's DXGI a
  second time as `winedxgi.dll` and has Direct3D 12 use it; `patches/dxmt/0001` has DXMT's DXGI
  pass Direct3D 12 swap chains on to it. A renamed copy of `dxgi.dll` does not work: Wine finds
  a built-in DLL by the name recorded inside it. DXMT's own Direct3D 12 (an in-progress build
  option) is not used.
- **The adapter is reported as the Apple GPU**: "Apple M3", vendor `106b`, 9093 MB here, from
  DXMT and from Wine's built-in Direct3D alike. Upstream WineD3D has no Apple entries and
  reported an "NVIDIA GeForce 6800"; `patches/runtime/0008` fixes that.
  A prefix can ask for other ids: "Report an NVIDIA GPU" (off by default) reports those of an
  NVIDIA GeForce RTX 5080, `10de:2c02`, on every layer, and leaves the name and memory alone.
  Games only offer DLSS on an NVIDIA adapter. With it off, every layer says Apple, including
  DXMT with DLSS on, which would otherwise report NVIDIA's vendor id by itself.

- **DLSS as MetalFX: available for Direct3D 11.** DXMT ships its own `nvngx.dll`, which answers
  the DLSS SDK and upscales with MetalFX's temporal scaler, and an `nvapi64.dll`. Both are
  built (`-Denable_nvngx=true -Denable_nvapi=true`) and installed with Wine's DLLs. DXMT turns
  them on with `DXMT_ENABLE_NVEXT=1`, which FineWine sets for a prefix with "DLSS through
  MetalFX" on (the default) and DXMT selected. `tests/runtime/dlss-metalfx.c` initialises NGX
  on a DXMT device and fetches its capability parameters, as x64 under FEX. No frame has been
  upscaled: that needs a game or a DLSS sample.
- **DLSS for Direct3D 12 and Vulkan: as MetalFX, through MoltenVK**, super resolution and
  frame generation. `nvngx.dll` has the Direct3D 12 and Vulkan NGX entry points; the work is
  recorded in the game's command buffer and done by a MetalFX command in MoltenVK. Tested at
  the NGX level, not with a game. See [21-metal4-and-ray-tracing.md](21-metal4-and-ray-tracing.md).
- **FSR needs nothing.** It is shader code the game ships, and runs on any Direct3D layer.
- **MetalFX spatial upscaling of the whole output** is a DXMT option
  (`DXMT_METALFX_SPATIAL_SWAPCHAIN=1`), not wired into FineWine's settings yet.
- **Metal 4: nothing to switch on yet.** Neither translation layer in the runtime uses Metal 4.
  DXMT's Metal 4 code is compiled out in its source ("needs macOS 26 SDK, and we don't really
  use it at the moment"), and MoltenVK has no Metal 4 code. Apple's D3DMetal does, and is the
  one we cannot use. When DXMT or MoltenVK gain Metal 4 paths they select them at run time by
  OS and GPU, and rebuilding picks that up; FineWine sets nothing that would hold it back.
- **Ray tracing: Vulkan ray tracing works, DirectX Raytracing does not yet.** The runtime's
  MoltenVK carries `patches/moltenvk`, which map `VK_KHR_acceleration_structure`,
  `VK_KHR_ray_query` and `VK_KHR_ray_tracing_pipeline` to Metal; two tests trace rays through
  Wine from ARM64 and x64 programs. Direct3D 12 still reports
  `D3D12_RAYTRACING_TIER_NOT_SUPPORTED`: Wine's vkd3d has no DirectX Raytracing, and adding it
  on top of these extensions is the next step. See
  [21-metal4-and-ray-tracing.md](21-metal4-and-ray-tracing.md).
- **An intermittent hang at window teardown.** Seen once on 2026-11-15 in about seven runs of
  `tests/runtime/d3d9-clear.c` as an x64 program: the process never exits. The Mac main thread
  takes a fault while releasing a block in `winemac.so` (`OnMainThread`), and Wine's signal
  handler then spins in `setup_raise_exception`, because that thread has no TEB. Cause of the
  first fault not found. Not related to MoltenVK.
- **Direct3D 10** goes through DXMT's `d3d10core.dll`; it has not been exercised.

## State of the pieces

| Piece | State |
|---|---|
| `scripts/build-finewine-runtime.sh` | Builds and packages a runtime that boots. The `fetch` and `apply` steps were not re-run end to end after the last patch changes; the patches were checked by applying them to a clean tree and comparing with the source that was built. |
| `patches/runtime/0001` (MSync) | Compiles and runs on Wine 11.21. |
| `patches/runtime/0002` (x18 and low memory) | Wine's own ARM64 programs run. |
| `patches/runtime/0003` (writable and executable pages) | Generated code runs. |
| `patches/runtime/0004`–`0006` | Shared-page reads, x18 repair and DLL path order: all exercised by the test script. |
| `scripts/build-fex.sh`, `patches/fex/0001` | FEX builds and runs x64 test programs. The `fetch` and `apply` steps were not re-run from scratch. |
| `scripts/build-dxmt.sh` | DXMT builds and renders. The `fetch` step was not re-run from scratch. |
| `patches/runtime/0007`, `patches/dxmt/0001` | Direct3D 12 works with and without DXMT selected. |
| `patches/runtime/0008` | Apple GPU reported by both Direct3D layers. |
| DLSS as MetalFX | Direct3D 11: NGX and NVAPI initialise on DXMT. Direct3D 12 and Vulkan: frames upscaled and generated through NGX in tests. No game yet. |
| `scripts/test-finewine-runtime.sh` | All twelve checks pass on the current, stripped runtime. |
| FineWine.app | Unit tests pass, and the core library passes an integration test against the runtime. The app's windows were not driven by hand against it. |
