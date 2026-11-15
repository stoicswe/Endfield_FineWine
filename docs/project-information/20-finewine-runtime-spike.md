# FineWine runtime spike: upstream Wine on Apple Silicon without CrossOver (2026-11-14)

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

- **"Upstream Wine + our patches" is not enough on its own.** The plan assumed the hard part was
  FEX. The hard part comes earlier: running any Windows code at all.
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

## State of the pieces

| Piece | State |
|---|---|
| `scripts/build-finewine-runtime.sh` | Fetch, apply, configure, build and package all ran. The packaged runtime does not start Windows programs, for the reasons above. |
| `patches/runtime/0001-msync-…patch` | MSync moved from the CrossOver 26.3 Wine source to Wine 11.21. Applies cleanly after `patches/ARM`. Not compiled or run yet. |
| FineWine.app | Complete against a stand-in runtime; 157 unit tests pass. Not yet run against a working Wine of ours, because there isn't one. |
