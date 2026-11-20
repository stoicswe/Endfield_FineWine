# Spike: 32-bit Windows programs without low memory (2026-11-20)

**Superseded** by `patches/runtime/0043` and `patches/fex/0011`, which the build scripts apply
and which go much further (windows, the Mac-side thunks, prefix creation). Kept as the record of
the experiment.

Not applied by any build script. These two diffs are the whole of a time-boxed experiment that
got a 32-bit x86 console program to run on FineWine's ARM64 runtime, with no Rosetta. Background
and what is left: [docs/project-information/25-32-bit-programs-and-installers.md](../../docs/project-information/25-32-bit-programs-and-installers.md).

## The idea

macOS gives an ARM64 process no memory below 4 GB, where a 32-bit program must live. So its
4 GB are a window higher up, at 1 TB (`0x10000000000`). The base is a multiple of 4 GB, which
is what makes this small: a real address in the window, cut to 32 bits, *is* the address the
program sees, so everything that already truncates a pointer for 32-bit code is right as it is,
and only the other direction (32-bit value to real pointer) needs the base added.

The base had to be found: 4 GB to 6 GB holds the process itself, 6 GB to 63 GB is the system's
shared library region (nothing can be mapped in its gaps), and 63 GB to 448 GB is a guard.

## The files

| File | Applies to | What it does |
|---|---|---|
| `wine-32bit-window.diff` | Wine 11.21 with `patches/ARM` and `patches/runtime` applied | Reserves the window; allocations and images with a 32-bit limit go inside it; the shared data page is mapped a second time at window + `0x7ffe0000`; the 32-to-64 call layer (`wow64`, `wow64win`) adds the base when it turns a 32-bit value into a pointer |
| `fex-guest-window.diff` | FEX at the pinned commit with `patches/fex` applied | Every guest memory access in generated code goes through the window (two scratch registers, x19 and x24, taken out of allocation); the decoder reads guest code through it; the syscall bridge reads the guest stack through it |
| `hello32.c`, `printf32.c` | | The two test programs |

**The FEX diff is a local patch only.** FEX does not accept AI-written code; none of this goes
upstream.

## Building it again

Wine has to be configured with `--enable-archs=i386,aarch64` (the runtime's own build is
`arm64ec,aarch64`) and `i386_CC=clang`; FEX with `-DMINGW_TRIPLE=aarch64-w64-mingw32`, which
builds `libwow64fex.dll`. That file goes into the prefix as `system32/xtajit.dll`: a prefix
keeps its own copy and Wine loads that one.

## What ran

- `hello32.exe` (no C runtime, `WriteFile` to the console): printed its line, exit status 0.
- `printf32.exe` (C runtime, heap, `printf`, arguments): printed the right values, including
  `sizeof(void*)=4`.
- A 32-bit `rundll32.exe` loaded kernel32, user32, gdi32, advapi32, ucrtbase, win32u and the
  Mac driver before failing in the driver's start-up.

Both programs were run with `WINEBOOTSTRAPMODE=1`, which lets the 32-bit system libraries load
straight from the build tree. Without it they fail: the prefix's `syswow64` folder is empty,
because the step of prefix creation that fills it is itself a 32-bit program that uses the Mac
driver.

## Not done

- Anything with a window: the Mac driver's start-up fails in a 32-bit process.
- The Mac-side halves of 32-bit calls (`unix_call_wow64_funcs` in each library) still turn
  32-bit values into pointers without the base.
- Exceptions, callbacks from the 64-bit side, more than one thread, self-modifying code: not
  exercised.
- An address formed as base plus index does not wrap at 4 GB as it would on a real 32-bit CPU.
- Cost: two more instructions on every guest memory access and two fewer registers. Not measured.
- Direct3D for 32-bit callers.
