# 32-bit programs and installers

FineWine's runtime runs 64-bit Windows programs only. This page says why, what FineWine does
about the commonest 32-bit program there is (an installer), and what real 32-bit support would
take.

## Why 32-bit programs cannot run

Translating the instructions is not the problem: FEX, which the runtime uses for 64-bit x86
programs, translates 32-bit x86 too. The problem is memory. A 32-bit program's pointers reach
the first 4 GB of the address space and nothing else, so its code, its data and everything
Windows hands it must live there. macOS gives a native Apple silicon process no memory below
4 GB at all: a program linked to allow it is killed as it starts, and a mapping asked for there
is refused (checked on 2026-11-15, see [20-finewine-runtime-spike.md](20-finewine-runtime-spike.md)).
Wine's 32-bit-on-64-bit layer (WoW64) and FEX's 32-bit mode both use a 32-bit program's
addresses as they are, so neither can work.

What the user sees without anything further is a program that does not start; Wine's log says
`failed to start ...: c0000017`.

## What FineWine does instead

| Case | What happens |
|---|---|
| The 32-bit set-up program of the Visual C++ or DirectX runtime, started by another installer | A program that does nothing and succeeds runs in its place (`patches/runtime/0014`); the runtime has those libraries already. |
| A 32-bit installer made with NSIS | FineWine carries out the installer's script itself. See below. |
| Any other 32-bit program opened from Finder | An alert says it is 32-bit and what to look for instead (a 64-bit installer, or a portable download). |

### NSIS installers: carried out by FineWine

Most installers are 32-bit programs whatever they install, and a great many are made with NSIS
(the Nullsoft Scriptable Install System): game launchers in particular. An NSIS installer is a
small 32-bit program followed by its data, which is a compiled script (copy this file there,
write that registry value, make this shortcut) and the files. The program only interprets the
script. FineWine has an interpreter of its own for it, so no 32-bit code runs:

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
calls into, and those cannot run either. A few common ones are stood in for: `nsis7z` (unpacking
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

## Real 32-bit support: an address-translating 32-bit mode ("route B")

**Spike, 2026-11-20: the idea works.** A 32-bit console program, and one using the C runtime,
ran on the ARM64 runtime with no Rosetta. The changes, what ran and what is left are in
[patches/spike-32bit](../../patches/spike-32bit/README.md); they are not part of any build. Two
things turned out differently from the plan below:

- The window's base is a multiple of 4 GB, so a real address cut to 32 bits is already the
  program's address. Point 3 below shrinks to one direction: only "32-bit value to pointer"
  needs the base, and Wine's call layer does that through two macros.
- The window cannot be anywhere convenient. macOS keeps 6 GB to 63 GB for its shared library
  region and 63 GB to 448 GB as a guard; the spike uses 1 TB.

What follows is the plan as written before the spike.

**The idea.** Give a 32-bit program its 4 GB somewhere else: reserve a 4 GB window at a fixed
place high in the process, and have every address the program uses mean "this far into the
window". QEMU's user-mode emulation does exactly this (`guest_base`). The program never knows.

**What would have to change.**

1. *FEX's code generator.* Every memory access the translated code makes (loads, stores,
   string instructions, stack pushes and pops, indirect jumps and calls, the TLS segment
   bases) adds the window's base. FEX already confines 32-bit addresses to 32 bits before
   using them, so there is one place per kind of access, but there are many kinds, and the
   call-return stack, the code cache lookup and self-modifying-code detection all key on
   guest addresses.
2. *Wine's memory manager* (`dlls/ntdll/unix/virtual.c`). A 32-bit process's allocations,
   image mappings, stacks, TEB and PEB must come from inside the window, and every address
   returned to it must be the offset, not the real address. Wine has the notion of a 32-bit
   limit already (`limit_2g`, `address_space_limit`); it has no notion of a base.
3. *Wine's 32-to-64 call layer* (`dlls/wow64`, `dlls/wow64win`, `dlls/wow64cpu`, and FEX's
   `libwow64fex`). Every system call a 32-bit program makes passes through thunks that turn
   its 32-bit pointers into real ones and back: in arguments, inside structures, in arrays of
   structures, in window messages (hundreds of message-specific cases), in callbacks from the
   64-bit side. Today the conversion is a cast. Each would add or subtract the base, and NULL
   must stay NULL. They go through a handful of macros (`ULongToPtr`, `PtrToUlong`, `UlongToPtr`),
   which helps, but places that pass a pointer as a plain integer do not.
4. *Everything that hands the program an address of something outside the window*: the shared
   user data page, the loader's data, 64-bit-side buffers a 32-bit caller is given a pointer
   to. Each needs a copy or a mapping inside the window.
5. *A 32-bit build of Wine's Windows side* (the i386 DLLs) added to the runtime, about as
   large again as the 64-bit ones are.

**Why it is uncertain.** No one has shipped this for Wine; there is nothing to port. Getting a
console program to start is perhaps a few weeks. Getting an installer with a window through
is the long part, because of the message thunks, and a missed conversion is a crash in
whatever program happens to use it. A 32-bit game would add Direct3D on top (DXMT and vkd3d
built for 32-bit callers).

**The other route ("C").** A second Wine built for Intel runs under Rosetta, where a process
may have low memory, and is used only when a 32-bit program starts. Far less work and it runs
installers as they are, with their own pages. It needs Rosetta installed and adds a few
hundred megabytes; whether Rosetta remains available in later versions of macOS should be
checked before investing in it. A start was made on 2026-11-16 (FreeType built for Intel from
the copy in CrossOver's source bundle; Wine's configure for `--enable-archs=i386,x86_64` got
as far as the build-rules step) and then set aside in favour of the NSIS interpreter; the
scratch builds were removed.
