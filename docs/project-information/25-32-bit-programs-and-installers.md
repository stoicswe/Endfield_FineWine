# 32-bit programs and installers

FineWine's runtime runs 32-bit Windows programs as well as 64-bit ones (since 2026-11-20:
runtime patch 0043 and FEX patch 0011). This page says what stood in the way, how it is done,
what has been tried and what has not, and what FineWine still does itself for the commonest
32-bit program there is, an installer.

## What stood in the way

Translating the instructions was never the problem: FEX, which the runtime uses for 64-bit x86
programs, translates 32-bit x86 too. The problem is memory. A 32-bit program's pointers reach
the first 4 GB of the address space and nothing else, so its code, its data and everything
Windows hands it must live there. macOS gives a native Apple silicon process no memory below
4 GB at all: a program linked to allow it is killed as it starts, and a mapping asked for there
is refused (checked on 2026-11-15, see [20-finewine-runtime-spike.md](20-finewine-runtime-spike.md)).
Wine's 32-bit-on-64-bit layer (WoW64) and FEX's 32-bit mode both use a 32-bit program's
addresses as they are, so neither works unchanged. Wine's log said
`failed to start ...: c0000017`.

## How it is done: the program's 4 GB are a window higher up

A 32-bit process reserves a 4 GB window at 1 TB (`0x10000000000`), and every address the
program uses means "this far into the window". The program never knows. (QEMU's user-mode
emulation does the same with its `guest_base`.)

- **The base is a multiple of 4 GB.** A real address in the window, cut to 32 bits, is already
  the address the program sees, so everything that truncates a pointer for 32-bit code is right
  as it is. Only the other direction, 32-bit value to real pointer, adds the base.
- **Why 1 TB.** 4 GB to 6 GB holds the process itself, 6 GB to 63 GB is macOS's shared library
  region (nothing can be mapped in its gaps) and 63 GB to 448 GB is a guard.

| Part | What changed |
|---|---|
| Wine's memory manager (`dlls/ntdll/unix/virtual.c`) | Reserves the window in a 32-bit process; allocations, images, stacks, the TEB and the PEB with a 32-bit limit come from inside it; the shared user data page is mapped a second time at window + `0x7ffe0000`; limits are compared on the truncated address |
| Wine's 32-to-64 call layer (`dlls/wow64`, `dlls/wow64win`) | `ULongToPtr` / `UlongToPtr` add the base (zero stays zero); window messages that carry a pointer, the `NtUserCall…Param` codes that do, and process-start attributes get it too |
| The Mac-side halves of 32-bit calls (every `unix_call_wow64_funcs`) | The same two macros, redefined in `include/basetsd.h` for Unix-side code, read the base that `ntdll.so` exports (`__wine_wow_window_base`) |
| The Mac driver (`winemac.drv`) | Its parameter pointers go through the same conversion |
| FEX (`libwow64fex.dll`, installed as `xtajit.dll`) | Every guest memory access in generated code goes through the window (two registers, x19 and x24, are taken out of allocation for it); the decoder, the syscall bridge and the code-invalidation tracker convert between the two kinds of address |
| The runtime | Wine is configured with `--enable-archs=arm64ec,aarch64,i386`, which adds `lib/wine/i386-windows`; FEX is built a second time as the WOW64 front end; DXMT's Windows DLLs are built a second time for 32-bit |

**64-bit programs are not touched.** The window code in FEX is compiled only into `xtajit.dll`;
the ARM64EC build (`xtajit64.dll`) has a base of zero fixed at compile time. In Wine the base
is zero in every process that is not 32-bit, so the conversions add nothing there.

**The FEX patch is local only.** FEX does not accept AI-written code; none of it goes upstream.

## What has been tried

`tests/runtime/suite32.c` is a 32-bit program of 72 checks that `scripts/test-finewine-runtime.sh`
builds and runs, with MSync off and on: arithmetic (x87, 64-bit divide), memory (allocation,
protection, file mappings, the address space ending below 2 GB), files, the registry, four
threads with locks and events, exceptions (raised, and an access violation caught and
resumed), code written at run time and rewritten, a message-only window with messages that
carry pointers, a window on screen with an edit control and a list box, drawing into a DIB
section, and starting another 32-bit program. Besides that:

- A new prefix gets its `syswow64` folder filled (856 files), which is itself done by a 32-bit
  program that loads the Mac driver.
- Microsoft's Visual C++ set-up program (`vc_redist.x64.exe`, a 32-bit bootstrapper) ran
  silently to "Apply complete, result: 0x0".

**Direct3D.** From a 32-bit program:

| | State | How |
|---|---|---|
| Direct3D 10, 11 | Works | DXMT, whose Windows DLLs are built a second time for 32-bit x86 (`scripts/build-dxmt.sh`); DXMT patch 0008 does the pointer conversion on DXMT's Mac side |
| Direct3D 9 and older, OpenGL | Works | WineD3D's OpenGL renderer and Wine's OpenGL call layer, runtime patch 0044; patch 0054 keeps a buffer lock from copying the whole buffer (a lock of a few hundred bytes in a 4 MB buffer: 330 µs before, 20 µs after) |
| Direct3D 9 and older on Vulkan | Built, off by default; Portal 2 reaches its menu and fails loading a level | The prefix setting of that name: DXVK's `d3d9.dll` on the runtime's MoltenVK. What was built, fixed and left open is in [31-direct3d-9-on-vulkan.md](31-direct3d-9-on-vulkan.md) |
| Direct3D 12, Vulkan | Start (a clear and a present pass) | Runtime patch 0048. Wine gives a 32-bit program mapped GPU memory it can reach by allocating it in the program's window and handing it to MoltenVK (`VK_EXT_external_memory_host`), so MoltenVK needs no 32-bit build. Two things in Wine's Vulkan layer assumed 32-bit addresses below 4 GB: a command pool handle and the check on a mapping's address |

The OpenGL layer needed more than the base. Its 32-bit thunks ran everything the size of a
pointer through `ULongToPtr`, which was harmless while the base was zero: sizes and offsets
(which are numbers) and, worst, the many OpenGL arguments that are an address *or* an offset
into the bound buffer object (vertex array pointers, the indices of an indexed draw, pixel data
read or written). Those now get the base only while no buffer is bound to the binding point
they are read through. The test script runs `d3d9-clear.c`, `d3d9-draw.c` (buffers, a texture,
a draw from memory, a read-back, presenting into a window) and `gl-buffer-offsets.c` as 32-bit
programs; the last fails without the buffer rule. The generated file `unix_thunks.c` was
changed directly: running Wine's `make_opengl` again would undo most of it.

**A real game: Portal (2026-11-20).** Portal is a 32-bit Direct3D 9 game started from Steam.
It reaches its main menu through FineWine's Steam tool. Getting there found what the test
programs had not, all of it now fixed and covered by `suite32.c` or the test script:

| What the game showed | Cause | Fix |
|---|---|---|
| "Out of memory" | The window is a reserved area, and Wine serves any allocation from reserved areas first: the emulator's per-thread tables (150 to 500 MB a thread) went into the program's own 2 or 4 GB | Runtime patch 0045: only a request confined to the window is served from it |
| (same) | Windows was told the Mac had 6 GB with 8 GB free: physical pages counted in 16K, reported in 4K. Also wrong for 64-bit programs | 0045 |
| "Failed to load the launcher DLL" | FEX's x87 slow path read its own register stack with a guest memory load; it had worked only while FEX's memory was inside the window | FEX patch 0012 |
| (would have followed) | The game's allocator (mimalloc) calls `VirtualAlloc2` with an alignment and no upper limit, which the 32-bit call layer passed on unlimited | 0045 |
| "Failed to allocate minimum memory requirement" | Steam's client library could not load (below), the game retried thousands of times, and each failed load left 21 MB mapped | Runtime patch 0046: a library whose imports fail is unmapped |
| A crash in the Miles sound library | `pop %es`: FEX reads the segment descriptor table, its own data, with a guest load | FEX patch 0012: the table is allocated inside the window |
| The game quits: no Steam | The Steam bridge was 64-bit only | 0046 (redirect for `steamclient.dll`), a 32-bit `lsteamclient.dll` in `lib/steam-bridge/wine/i386-windows`, and the base added in the bridge's one 32-bit pointer type (`runtime-extras/steam-bridge/lsteamclient/window32.patch`); the app puts the 32-bit bridge in the prefix's `syswow64` |

The lesson for the next such bug: after 0045, FEX's and Wine's 64-bit-side memory is outside
the window, so a 64-bit-side pointer that reaches 32-bit code, or FEX data read with a guest
memory operation, faults at once instead of working by accident. In a trace it shows as an
access to window + (the low 32 bits of a 64-bit-side address).

**What it costs.** `tests/runtime/bench.c` as a 32-bit program against the same as x64, on an
Apple M3 (2026-11-20): integer sieve, matrix multiply, memory copy, pointer chase, atomics and
locks are within about 10% either way; a 64-bit hash loop takes 1.8 times as long (64-bit
arithmetic in 32-bit code); `sin`/`cos`/`sqrt` take 7 times as long (32-bit code uses the x87
unit, which the emulator computes in software); `QueryPerformanceCounter` 4 times.
`bench-d3d11.c` (10,000 draws a frame through DXMT): 6.0 ms with new constants each draw and
2.0 ms with nothing changing, against 7.4 ms and 1.6 ms as x64.

**Known fault: a hang when an OpenGL program closes.** About one run in eight of
`d3d9-draw.c` as a 32-bit program never exits: the test's checks have passed, and while the
Direct3D device is released the Mac driver's OpenGL context teardown (`-[NSOpenGLContext
dealloc]` on WineD3D's worker thread, which waits for the main thread) never returns, with the
program's own thread spinning. A window-closing hang of the same look was seen once with a
64-bit program before any of the 32-bit work, so it is the Mac driver's, not the window's. A
Direct3D 9 game could hang this way when it quits. Not fixed; the test script gives those
checks a time limit.

**Not tried yet:** playing a level of a 32-bit game (Portal was seen at its main menu only),
installers with their pages shown and clicked through, and audio. An address formed as base plus index does not wrap at 4 GB as on a real 32-bit CPU. A
missed pointer conversion shows as a crash in whatever program uses that call;
`WINEDEBUG=+seh` names the Mac-side function it happened in.

## What FineWine still does itself

| Case | What happens |
|---|---|
| The 32-bit set-up program of the Visual C++ or DirectX runtime, started by another installer | A program that does nothing and succeeds runs in its place (`patches/runtime/0014`); the runtime has those libraries already. `FINEWINE_NO_REDIST_STANDIN=1` runs the real one. |
| A 32-bit installer made with NSIS | FineWine carries out the installer's script itself (below). If that fails and the runtime runs 32-bit programs, the installer is started as a program instead. |
| Any other 32-bit program | Runs. With a runtime that has no 32-bit side (`lib/wine/i386-windows` and `xtajit.dll`; an older or a foreign one), an alert says so. |

A prefix made before this gets its `syswow64` folder from Wine's own update step the first
time the new runtime starts it, and its `xtajit.dll` from FineWine (`PrefixService.refreshEmulator`):
a prefix keeps its own copy of the emulator, and Wine loads that copy.

### NSIS installers: carried out by FineWine

Most installers are 32-bit programs whatever they install, and a great many are made with NSIS
(the Nullsoft Scriptable Install System): game launchers in particular. An NSIS installer is a
small 32-bit program followed by its data, which is a compiled script (copy this file there,
write that registry value, make this shortcut) and the files. The program only interprets the
script. FineWine has an interpreter of its own for it, so no 32-bit code runs (it was written
when none could, and is kept because it is quick and shows nothing on screen):

- `NSISArchive` (`finewine-app/Sources/FineWineCore/NSISArchive.swift`) finds the data in the
  file, decompresses it (zlib or LZMA, each file on its own or all as one stream) and hands
  out the script and the files.
- `NSISScript` (`NSISScript.swift`) carries the script out against the prefix's C: drive, the
  way an installer run silently (`/S`) would: the start-up function, then every selected
  section. Files are written under `drive_c`. Registry writes are collected and imported with
  `regedit` afterwards, in the 32-bit view of the registry unless the script asked for the
  64-bit one, as on Windows. Shortcuts are collected, and FineWine lists their programs and
  makes its shortcut apps from them.
- `AppModel.install32Bit` is where the app decides: an opened `.exe` that is 32-bit and NSIS
  goes this way, with the status window saying what is being written.

**What cannot be done.** Installers use add-ons ("plugins"), which are 32-bit DLLs the script
calls into, and the interpreter does not run them. A few common ones are stood in for: `nsis7z` (unpacking
an embedded 7-Zip archive, done with the Mac's `bsdtar`), `System::Int64Op`, `nsExec` (the
command is noted, not run), `UserInfo`, `nsProcess`. Calls to all others are skipped and
counted in the report. Programs the installer would have run during installation are not run.
The installer's own pages are never shown: the defaults are taken, as in a silent install.

**Installers that do their work in an add-on.** Many launchers have a custom window, which is
an add-on, and the add-on decides when to call back into the script to install. Run plainly,
such a script installs nothing. Two fallbacks cover them:

1. If the normal run wrote no files, the script functions whose address the script hands to
   an add-on (a callback) are tried, the one that unpacks the most files first.
2. A program the script refers to, in a shortcut or to start it, that is not where the script
   says but is exactly once somewhere below the install folder, is copied to where it should
   be. (The add-on would have put it there.)

The GRYPHLINK launcher's installer is of this kind, and is what this was built against: its
section is empty, the install function is handed to `Widget.dll` as a callback, and the add-on
copies `Launcher.exe` up from the versioned folder. With both fallbacks it installs in about a
second and the launcher runs.

**Not supported yet**, each reported as such when met: installers made with an ANSI build of
NSIS (NSIS 2, and ANSI builds of NSIS 3); bzip2 compression. LZMA is implemented (through the
Mac's liblzma) but has not been tried on a real installer, and nor has the `nsis7z` stand-in.
Inno Setup, InstallShield and other kinds of installer are not read at all.

**Trying one by hand:**

```bash
FINEWINE_NSIS_SAMPLE=/path/to/setup.exe FINEWINE_NSIS_OUT=/tmp/drive_c swift test --filter NSISSampleTests
```

prints what the installer would do, into a folder used as the C: drive. `NSISTests` builds
small installers in memory and checks the interpreter against them.

## How it got here

The NSIS interpreter came first (2026-11-16), when 32-bit programs could not run at all. A
time-boxed spike on 2026-11-20 showed the window idea working for console programs; its two
diffs and notes are kept in [patches/spike-32bit](../../patches/spike-32bit/README.md) and are
superseded by the patches named at the top.

**The route not taken.** A second Wine built for Intel runs under Rosetta, where a process
may have low memory, and is used only when a 32-bit program starts. Far less work and it runs
installers as they are, with their own pages. It needs Rosetta installed and adds a few
hundred megabytes; whether Rosetta remains available in later versions of macOS should be
checked before investing in it. A start was made on 2026-11-16 (FreeType built for Intel from
the copy in CrossOver's source bundle; Wine's configure for `--enable-archs=i386,x86_64` got
as far as the build-rules step) and then set aside in favour of the NSIS interpreter; the
scratch builds were removed.
