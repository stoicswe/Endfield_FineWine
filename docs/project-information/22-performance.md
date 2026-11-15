# Performance of the FineWine stack: measurements and what was done (2026-11-15)

Asked for: a look at the whole stack, x64 through FEX and ARM64, to make sure each layer is
the fastest implementation that is also reliable. This is measured, not estimated, on an
Apple M3 with macOS 27. No game was run: these are small workloads that isolate one layer
each. `scripts/bench-finewine-runtime.sh` reproduces the table.

## The numbers

The same work four ways: natively on the Mac, under Rosetta (for reference; FineWine does not
use it), as a Windows ARM64 program under Wine, and as a Windows x64 program under Wine and
FEX. Milliseconds, lower is better. Final runtime, MSync on.

| Test | Native | Rosetta | Wine ARM64 | Wine + FEX |
|---|---:|---:|---:|---:|
| Integer (sieve) | 30 | 40 | 20 | 38 |
| Integer (hash loop) | 514 | 445 | 502 | 426 |
| Floating point (matrix multiply) | 50 | 33 | 48 | 66 |
| Maths library (sqrt, sin, cos) | 92 | 228 | 336 | 495 |
| Memory (copy and fill 64 MB) | 40 | 84 | 47 | 43 |
| Memory (pointer chase) | 1121 | 1175 | 1141 | 1147 |
| Indirect calls | 166 | 281 | 164 | 446 |
| Atomics, one thread | 39 | 43 | 71 | 72 |
| Atomics, four threads contended | 976 | 648 | 728 | 866 |
| Plain loads and stores, four threads | 576 | 696 | 473 | 755 |
| QueryPerformanceCounter (5M) | | | 94 | 119 |
| GetTickCount64 (5M) | | | 4 | 27 |
| VirtualAlloc and free (200k) | | | 544 | 599 |
| Heap alloc and free (2M) | | | 40 | 74 |
| Create and close a handle (300k) | | | 4467 | 4520 |
| File write and read 4 KB (100k) | | | 248 | 265 |
| Events (100k round trips) | | | 426 | 342 |
| Mutex (1M uncontended) | | | 501 | 512 |
| Semaphore (1M uncontended) | | | 497 | 505 |
| Critical section (20M) | | | 77 | 256 |
| SRW lock (20M) | | | 155 | 310 |
| Generated code (20k rewrites) | | | 182 | 398 |
| Direct3D 11, 10k draws with new constants (ms per frame) | | | 6.0 | 8.3 |
| Direct3D 11, 10k draws, nothing changes | | | 1.7 | 3.0 |
| Direct3D 12, 10k draws with new constants | | | 6.0 | 8.3 |
| Direct3D 12, 10k draws, nothing changes | | | 3.9 | 4.2 |

Run-to-run variation is a few percent on most rows; the contended and pointer-chase rows move
more with what else the machine is doing.

## What the numbers say, layer by layer

**FEX (x64 translation).** Straight-line integer, memory and floating-point code runs at or
near native speed. The weak spot is calls through pointers, 2.7 times native (Rosetta: 1.7),
which is what virtual calls and script interpreters are made of. FEX is the only x64
translator that runs inside an ARM64 Wine process, so there is no alternative to compare; it
is built in release mode for ARMv8.5, without assertions.

**FEX's emulation of x86 memory ordering (TSO).** Left on. Turning it off (`FEX_TSOENABLED=0`)
changed the threaded tests by about 10 percent, within noise on the others, and FEX's own
documentation says it breaks multithreaded programs. Not worth it.

**Wine's synchronisation: the largest finding.** Without MSync every wait on a Windows mutex,
semaphore or event is a request to Wine's server: 11.5 µs per mutex or semaphore operation,
15.8 µs per event round trip. With MSync they are Mach semaphores inside the program: 0.5 µs
and 4.3 µs, **23 and 4 times faster**. Creating a handle is 30 percent slower with MSync
(11 to 15 µs), which matters far less. The whole test suite passes with MSync on for every
check, so it is now the default for new prefixes.

One reliability trap came with it: a program started with MSync cannot join a server that was
started without it, and exits without a message. FineWine now stops a prefix's server before
it applies a change of synchronisation mode.

**Wine's own code.** It was compiled for a 2011 ARM baseline, in which atomic operations are
retry loops. Every Apple silicon Mac implements ARMv8.4-A, which has them as single
instructions. Rebuilt with `-march=armv8.4-a`: critical sections 141 to 77 ms, SRW locks 353
to 155 ms (ARM64), and 290 to 256 and 429 to 310 under FEX. `-mcpu=apple-m1` would be the
natural flag but crashes clang 23 on Wine's exception-handling code.

**Scheduling.** A process at background priority is kept on the efficiency cores: the
indirect-call test took 483 ms there against 163 ms. Wine maps Windows thread priorities to
macOS's itself, but the process as a whole inherits its priority from whatever launched it.
FineWine now launches every program at user-interactive priority explicitly. Game Mode (below)
goes further for full-screen games.

**Direct3D 11 (DXMT) and Direct3D 12 (vkd3d on MoltenVK).** About 0.6 µs per draw with new
constants on ARM64 and 0.8 µs under FEX, for both. A frame of 5,000 draws costs 3 to 4 ms of
CPU. The two paths are close enough that neither is the weak one.

**MoltenVK's settings.** Two were tried against the Direct3D 12 benchmark. Encoding Metal
commands as Vulkan ones are recorded (`MVK_CONFIG_PREFILL_METAL_COMMAND_BUFFERS=1`) made a
frame 2.3 times slower (7 to 16 ms). Asynchronous queue submission
(`MVK_CONFIG_SYNCHRONOUS_QUEUE_SUBMITS=0`) made no difference. The defaults stay.

## What was changed

| Change | Where | Effect |
|---|---|---|
| MSync is the default for new prefixes | `PrefixSettings.syncMode` | Mutex, semaphore: 23x. Events: 4x. |
| A change of synchronisation mode stops the prefix first | `PrefixService.applySettings` | No silent failure to start. |
| Wine's Windows side built for ARMv8.4-A | `scripts/build-finewine-runtime.sh` | Locks 1.2 to 2.3x. |
| Programs launched at user-interactive priority | `SystemProcessRunner` | Not left on efficiency cores. |
| Game Mode for programs that render | see below | macOS gives the game priority while full screen. |

Existing prefixes keep the synchronisation mode they were saved with.

## Game Mode

macOS turns Game Mode on by itself when an app that says it is a game is full screen. It reads
that from the running executable's Info.plist, which Wine's loader carries inside the binary;
neither upstream Wine nor CrossOver's loader says it. Because it is read from the executable,
a program cannot become a game once it is running. So:

- The runtime has the loader twice: `wine`, which says it is not a game, and `wine-game`,
  which says it is (`LSApplicationCategoryType` games, `GCSupportsGameMode` and
  `LSSupportsGameMode` true). `scripts/lib/make-game-loader.py` makes the second from the first.
- FineWine runs a program, and everything it starts, with `wine-game` when the program is
  known to render with a GPU API. It knows in two ways: the executable imports Direct3D,
  DXGI, Vulkan or OpenGL, which is checked before the first launch; or the runtime has left a
  marker because the program, or a game its launcher started, created a Vulkan instance
  (Vulkan and Direct3D 12) or asked DXMT for the GPU (Direct3D 10 and 11).
- So a game that loads its rendering API at run time, or that is started by a launcher, is
  recognised from its second run on.
- The prefix setting "Game Mode" (on by default) turns all of it off.

**Not verified:** that macOS actually turns Game Mode on. That needs a game in full screen on
the display, which the tests deliberately never show. What is tested is every step up to it:
the loader says it is a game, is used when asked, and rendering programs leave the marker.
`gamepolicyctl game-mode status` (in Xcode) says whether Game Mode is on while a game runs.
macOS decides; nothing here can force it, and it needs the game to be full screen.

## Found and left alone

- **Wine's maths library** is 3.6 times slower than the Mac's for `sin`/`cos` (336 against
  92 ms). Games that link the Windows C runtime dynamically use it. It is portable C from
  musl; replacing it is its own piece of work.
- **Calls into Wine's server** cost about 5 µs each: 15 µs to create and close a handle,
  2.7 µs to allocate and free memory. That is the server's design, and MSync already takes
  the frequent callers away from it.
- **Code generated at run time** costs 9 µs per rewrite on ARM64 and 20 µs under FEX. macOS
  will not map memory writable and executable at once, so the runtime switches a page between
  the two on a fault. It matters to programs with their own JIT (.NET, JavaScript engines)
  and to FEX's warm-up, not to steady-state game code. Using macOS's per-thread JIT switch
  instead would remove the system call from each switch.
- **Shader and pipeline caches between runs.** Wine's vkd3d keeps no pipeline cache on disk,
  so a Direct3D 12 game translates its shaders again on every launch. Not measured here;
  this is where first-run and per-launch stutter would come from.
- **High-resolution mode** is on by default, so a game that picks "native" renders at the
  panel's full pixel count. That is a GPU cost chosen for sharpness; DLSS through MetalFX is
  the way to get it back.
- **FEX is built without link-time optimisation** and DXMT's shader compiler with LLVM
  assertions on. Both are how their projects build; neither was measured.

## What this does not tell us

Nothing here is a game. GPU-bound performance, shader compilation stutter, streaming, audio
and anti-cheat overhead are not in these numbers. The next measurement that matters is a
frame-time capture of a real title, which needs the game to be launched and logged in to.
