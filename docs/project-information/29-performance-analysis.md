# Performance analysis: where the time goes in real games

Measurements only. No fixes are made until both games below have been analysed.
Machine: MacBook Pro, Apple M3 (4 performance + 4 efficiency cores), 24 GB, built-in display
3024x1964 at 120 Hz, on AC power, no thermal limit reported.

## Genshin Impact 7.2, Direct3D 11 through DXMT (2026-11-18)

Started from the HoYoPlay entry, in a full-screen Space, in the open world. Game resolution
3024x1898 (the display's full pixel size below the camera housing), Game Mode off (see below).

### The GPU is the limit

- GPU utilisation 99-100% in every reading (`ioreg -c IOAccelerator`, Device/Renderer/Tiler).
- CPU: 2.3-2.7 of 8 cores (true per-thread times from `proc_pidinfo`). Busiest thread, the
  game's main thread, 63%; the next 28%; DXMT's encode thread 16%; seven job workers 15% each.
  No thread is near 100%, so no CPU thread holds the frame rate back.
- The frame rate itself was not measured (the Metal HUD was off for this run).

### Where CPU time goes (two 4-second samples, share of busy samples)

| Layer | Share |
| --- | --- |
| Translated game code (FEX's output) | 74-76% |
| macOS libraries and kernel calls | 9-11% |
| Wine ntdll (unix side) | 4-6% |
| Metal and GPU driver | 3-4% |
| FEX itself (translating, dispatching) | 2-3% |
| DXMT (d3d11.dll and winemetal) | 2% |
| other Windows DLLs | 2% |

Wine, DXMT and FEX's own work are together about a tenth of the CPU time. The rest is the game's
own code, translated.

### Findings

1. **Rendering at 3024x1898.** Same as Zenless Zone Zero on this Mac: the base M3's GPU is
   saturated at native Retina resolution. MetalFX upscaling (dxmt patch 0004) only acts when the
   game's picture is smaller than its window, so it does nothing here. This is the largest lever.
2. **Game Mode was off.** The whole chain ran under the ordinary loader (`org.finewine.program`)
   because it was started from the HoYoPlay entry. Fixed in the app the same day
   (`LaunchPlanner.isGame`), not yet installed for this run. Game Mode gives the game priority
   on the GPU and CPU.
3. **Switching to the game stalls its main thread for about 2.4 seconds.** Activation sends a
   "displays changed" event; `display_mode_changed` then re-reads every display: all modes
   (`copy_display_modes`, NSDictionary work), EDID over IOKit, GPU lookups, and deletes and
   rewrites the display registry keys through the server (`add_gpu` -> `reg_delete_tree`). 48% of
   a 5-second sample on the thread that pumps messages. Nothing had changed on the displays.
4. **Seven job workers spin when idle**, 13% user + 2% system each, identical: about one core.
   This is the game's (Unity's) own behaviour; under FEX each spin iteration costs more than on
   x86. Two audio threads (winecoreaudio) and several others loop on `Sleep(0)`/short sleeps
   (`NtDelayExecution` -> `sched_yield`); they show up heavily in samples but use little CPU.
5. **Game threads run at priority 31** (default), not the user-interactive level the app asks
   for at launch; only DXMT's own threads (63) and a few others (37, 47) are higher.
6. **The game is told the GPU is an "AMD Radeon Pro 5300M"** (Unity's log, vendor id 106b). It
   may pick its default quality from that name.
7. **Shader caches are in use**: DXMT's `shaders_320.db` (12 MB) and a Metal cache under
   `$(getconf DARWIN_USER_CACHE_DIR)/dxmt/GenshinImpact.exe`. No compile stalls seen in samples.
8. Memory is not a constraint: 6.4 GB footprint, 38% of system memory free.

### How it was measured

`sample <pid> 4 -mayDie`, symbolised with `nm -n` on the build tree's ntdll.so, win32u.so and
winemac.so (same UUIDs as the installed ones); FEX's DLL located by matching its `.text` size to
a region in `vmmap`; true CPU per thread from `proc_pidinfo(PROC_PIDTHREADINFO)` over 10 seconds
(samples overstate threads that yield in a loop).

## Arknights: Endfield, Vulkan through MoltenVK (2026-11-18)

Started from GRYPHLINK, in a full-screen Space, 2.5 to 12 minutes after the game process
started. Swapchain 3024x1898. Game Mode on (game loader, `gamepolicyctl game-mode status`).

### Memory is the first problem

- The game's footprint grew the whole time: 25.7 GB at 2.5 minutes, 32, 38, 45, then 50.3 GB
  about ten minutes later, on a 24 GB Mac. Roughly 3 GB a minute. Resident memory stayed near
  5.8 GB; the rest is in the compressor or swap (`vmmap -summary`: 20 GB "swapped" at first
  reading, 35 GB later).
- System-wide: about 450,000 page compressions and 220,000 decompressions in one minute
  (16K pages, so 7 GB compressed a minute), `kernel_task` at 27% of a core, swap use up from
  3.2 to 4.4 GB, free memory 30%. A 4-second `sample` of the game got 44 samples per thread
  where Genshin got about 1,000: the process is being stalled.
- Where it is: 128 MB read-write anonymous blocks in Wine's allocation area, each written from
  end to end and then left cold. 181 of them at the first reading, 194 and 232 later (25 GB);
  between readings some are freed and more are made. Genshin's process has none. Another 9.5 GB
  of swapped memory is in other anonymous regions.
- The compressor holds far fewer pages (15 GB before compression) than the game has swapped
  (35 GB). Pages that are all one value are not stored, so much of this memory may be
  zero-filled. Not proven: the contents were not read (no debugger was attached to a game with
  anti-cheat).
- Not found yet: who makes the blocks. They are not FEX code buffers (code runs from 16 MB
  buffers and FEX itself uses 0.08 cores). Candidates to test with a `+virtual` trace on a
  fresh launch: the game's allocator handing memory back in pieces smaller than a 16K Mac page
  (FineWine then zeroes the piece but cannot release the page, patch 0016), `MEM_RESET` being
  ignored by Wine, or the game simply not being limited by the memory size it is told.

### GPU and CPU

- GPU utilisation 98% in the first readings, 66% in the last (while the game was also reading
  550 MB from disk in 30 seconds).
- CPU: 3.9 of 8 cores. One unnamed thread at 96% inside a single 2.7 MB block of translated
  code the whole time; the main thread 68%; UnityGfxDeviceWorker 48%; six job workers 15-24%.
- Share of busy samples (8 seconds): translated game code about 87%, macOS kernel calls 4%,
  MoltenVK 2%, FEX itself 2%, GPU driver 1%, Wine ntdll 1%. As with Genshin, the layers
  FineWine controls are a small part of the CPU time.
- All game threads run at priority 31 or lower (job workers 31, CrossFrameJob 27, background
  22), as in Genshin.

### Findings

1. **Runaway memory footprint**, above. Everything else in this run is measured under memory
   pressure, so the GPU and CPU numbers are a floor, not the game's real cost.
2. **Rendering at 3024x1898**, the same as Genshin, with the GPU at 98%.
3. **The launcher keeps working behind the game.** GRYPHLINK's web renderer
   (`QtWebEngineProcess`) uses 1.2 cores, four raster threads at 27% each, drawing in software
   (patch 0015 keeps Chromium drawing in software) for a window nobody sees; `Games.exe` uses
   another 0.6. They run at background priority, so they take efficiency cores, memory
   bandwidth and heat rather than the game's cores.
4. **One thread at a constant 96%** in a small loop of game code. Not identified.
5. "Window move completed without beginning" is logged 329 times in six minutes by winemac;
   harmless by itself but it is a sign of repeated window-move requests.

## Both games: what the analysis points at

In order of likely gain, to be decided before any fix is written:

1. Endfield's memory growth (find the allocator; nothing else matters while it runs away).
2. Resolution: both games saturate the M3's GPU at 3024x1898. Defaulting games to a lower
   render size with MetalFX upscaling (DXMT has it; MoltenVK has no automatic equivalent) is the
   largest frame-rate lever.
3. The launcher's CPU use while a game runs (GRYPHLINK measured; HoYoPlay's renderer used 10%).
4. The 2.4-second display re-scan when a game is activated.
5. Thread priorities: game threads at 31 in both games despite the user-interactive launch.
6. Game Mode for launcher-started games (already fixed in the app).
7. The GPU name Unity is given under DXMT ("AMD Radeon Pro 5300M").

Wine's, FEX's, DXMT's and MoltenVK's own CPU time is 10-15% in both games, so tuning those
layers' code paths cannot give more than a few percent.

## What was done after the analysis (2026-11-18)

Looked through the code for each finding. One defect was fixed; the rest are choices or need
the memory trace first.

- **Fixed: the display re-scan at every switch to a game** (finding 4). winemac sent a "displays
  changed" event on every activation; it now compares the displays with what Wine was last
  told and sends nothing when they are the same (runtime patch 0033). Three switches read the
  displays once instead of three times.
- **Not a defect: thread priorities** (finding 5). Wine already maps each Windows thread
  priority to a Mach priority (`apply_thread_priority` in the server). The games ask for
  "normal" for their workers, which is 31; Game Mode is what lifts a game above other apps.
- **Measured, no cost: the Metal overlay library.** Programs always start with
  `MTL_HUD_ENABLED=1` so the overlay can be toggled. With it loaded and hidden the Direct3D 11
  draw benchmark is unchanged (6.5 ms and 1.4 ms per 10,000 draws either way).
- **Found, not changed: the GPU identity DXMT gives Genshin and Zenless Zone Zero.** DXMT has a
  built-in profile for these games that reports an AMD Radeon Pro 5300M (vendor 1002, device
  7340). FineWine's `DXMT_CONFIG=dxgi.customVendorId=106b` (set when DLSS through MetalFX is
  on) overrides the vendor only, so the game sees an AMD name with Apple's vendor id. Whether
  that changes what the game does is unknown.
- **Choices that trade nothing in picture quality for speed do not exist at this resolution.**
  Both games fill the M3's GPU at 3024x1898. The options that keep the picture closest:
  Endfield supports DLSS, which FineWine runs as MetalFX temporal upscaling when the prefix
  reports an NVIDIA GPU (off by default, not yet tried with a game); Genshin has its own
  render-scale and FSR 2 settings; FineWine's automatic MetalFX spatial upscaling applies to
  Direct3D 11 games that render smaller than their window.
- **Open: the launcher's CPU use behind the game, and Endfield's memory growth.**

## Endfield's memory growth: found and fixed (2026-11-18)

A program can now be started with a memory log: its "…" menu, Diagnostics, Play with Memory
Log (runtime patch 0034, `FINEWINE_MEMORY_TRACE`). The log has a line for each memory operation
of 8 MB or more with its likely callers, and totals with the process's footprint every five
seconds. Endfield was run this way for seven minutes.

What the log and `vmmap` showed:

- The footprint rose from 1 GB at 15 s to 18.6 GB at two minutes and 40.7 GB at seven, about
  100 MB a second.
- The game did not ask for it. Reset requests: none. Decommits too small to free a 16K page:
  2 GB over the whole run. Both earlier suspects are ruled out.
- The memory was in FEX's lookup tables. Each emulated thread reserves 272 MB for them (128 MB
  of page pointers, 128 MB of page memory, 16 MB for the first-level cache). 163 were alive at
  four minutes. Of the 27 GB footprint then, 17.8 GB was in these tables.
- The tables were full in threads that had never done anything: one commit at birth, no other
  operation, and all 272 MB resident. Sorted by address, every table in one contiguous run of
  addresses was full, every table outside it empty, and the run ended in the middle of a table.
  Something was reading through the process's memory in address order.

Why reading costs memory: under Wine, FEX committed the whole 272 MB at a thread's first block.
Committed memory is readable, and macOS has no shared zero page, so reading a page that was
never written still allocates it. `tests/runtime/scan-memory.c` shows it without the game: a
program with 16 idle threads that reads its own writable memory reached 5 GB.

The fix (fex patch 0005) commits 64 KB around each fault, which is what FEX does on Windows.
Memory that FEX has not used stays reserved, cannot be read, and costs nothing.

A second logged run with that fix: the footprint no longer ran away. It reached 19.2 GB at
three minutes and stayed between 19.8 and 20.0 GB until the game was closed at nine minutes
(the first run was at 40.7 GB after seven and still rising). The lookup tables held 0.1 GB.

That run showed the same reader in a second place: 3.6 GB in Wine's ARM64EC code map, a 4 GB
table with one bit for each page of the address space, committed in full and read-only.
Runtime patch 0035 reserves it on macOS and commits a page when it is first read. With both
fixes the test program, which reads every committed page, ends at 370 MB (9 GB with neither).
A third logged run with both fixes: 15.7 GB at four minutes and level (20 GB before, at the
same point). The code map held 0.14 GB instead of 3.6 GB.

What the 20 GB was at three minutes: 9.3 GB writable memory in Wine's area (the game's own
heaps, mostly swapped out), 3.6 GB the code map, 2.4 GB graphics memory, 1.5 GB Mac-side
allocations (Metal, MoltenVK), 1.1 GB translated code.

Still open, from the third run: about 6.5 GB of the writable memory is inside the emulator's
own heap, not the game's. FEX allocates through rpmalloc, which reserves two 256 MB spans for
each thread and commits whole pages of them: 64 KB for small objects, 4 MB for medium ones,
64 MB for large ones. A thread that makes one medium allocation has 4 MB committed, and the
reader in the game turns the unused rest into real memory. Committing those pages as they
fill is the next fix. The reads are plain memory reads inside the process, not
ReadProcessMemory calls, so they cannot be answered more cheaply at that level.
