# Emulator memory on macOS: analysis and strategy (2026-11-18)

Follows [29-performance-analysis.md](29-performance-analysis.md). Two fixes are in (FEX lookup
tables, Wine's ARM64EC code map) and took Arknights: Endfield from 40 GB and rising to a level
15.7 GB. This document analyses what is left, what a change to FEX's allocator would do, and
which strategy serves every game. Nothing described under "Options" is built yet.

## The rule behind all of it

On macOS a page of anonymous memory that is read, and never written, becomes a real page and
counts in the footprint. Linux hands out one shared zero page for such reads. Measured natively,
1 GB each:

| Memory                                   | Read costs | Read time | First write |
|------------------------------------------|-----------:|----------:|------------:|
| Anonymous (what Wine uses today)         |    1025 MB |     72 ms |       50 ms |
| Private mapping of a 1 GB sparse file    |       1 MB |     83 ms |      155 ms after a read |
| Private mappings of one 2 MB zero file   |       1 MB |     29 ms |       73 ms (144 ms after a read) |

So any memory that is committed (readable) and unused is free only until something reads it.
Endfield has a reader: plain reads inside the process, through all committed memory in address
order. Other games with anti-cheat or memory scanners will behave the same way; games without
one pay nothing for committed, unused memory.

The emulator was written for Linux, where committing far more than is used costs nothing.
Under Wine on macOS each of those habits is a liability.

## What is committed and unused

Test program, 32 x64 threads (scratch test, same method as `tests/runtime/scan-memory.c`):

| State                                  | Footprint before a scan | After reading all committed memory |
|----------------------------------------|------------------------:|-----------------------------------:|
| Threads idle                           |                   61 MB |                             661 MB |
| Each thread ran 24,000 small functions |                  109 MB |                            1655 MB |

The emulator uses about 2 to 3 MB for each thread and commits 20 to 50 MB. What that is, for
each thread:

| Structure                         | Committed for each thread | Who touches it          |
|-----------------------------------|--------------------------:|-------------------------|
| Heap (rpmalloc), two 256 MB spans |  9 MB idle, 18 MB active  | all emulator code       |
| Compile buffers (IR, backend)     |  16 MB + 8 MB once it has compiled | emulator code only |
| Call-return stack                 |                      4 MB | generated code only     |
| Thread stacks (Wine)              |                3 x 1 MB   | everything              |
| Lookup tables                     |  fixed: 64 KB pieces      |                         |

Endfield with both fixes, 150 seconds in, 15.4 GB footprint, about 200 threads:

| Part                                             |     MB |
|--------------------------------------------------|-------:|
| Emulator heap (425 spans)                        |   6552 |
| Graphics memory                                  |   2400 |
| Game's own large allocations                     |   1644 |
| Mac-side allocations (Metal, MoltenVK)           |   1455 |
| Translated code                                  |   1059 |
| Small allocations, other                         |    626 |
| Call-return stacks (4 MB regions)                |    348 |
| Thread stacks (1 MB regions)                     |    213 |
| Compile buffers                                  |    188 |
| Lookup tables                                    |    142 |
| Code map                                         |    141 |

The emulator heap is the largest single item, four times the game's own large allocations.

## Why the heap is so large

rpmalloc gives each thread a heap. A heap takes 256 MB spans (reserved, cheap) and cuts them
into pages by object size:

| Object size      | Page size | Committed when the page is first used |
|------------------|----------:|---------------------------------------|
| up to 4 KB       |     64 KB | all 64 KB                             |
| up to 256 KB     |      4 MB | all 4 MB                              |
| up to 8 MB       |     64 MB | all 64 MB                             |
| larger           |     exact | exact                                 |

A thread that allocates one 300 KB vector has 64 MB committed. Inside a page, rpmalloc hands
out blocks in address order and keeps a count of how many it has handed out
(`block_initialized`); freed blocks are reused before new ones are taken. So the used part of a
page is always a prefix, and everything after it has never been touched.

Of the 425 spans in Endfield, 258 held under 8 MB, and 19 held over 60 MB each, 2.8 GB
together.

**Part of the 6.5 GB is real use, and I cannot yet say how much.** FEX keeps, for each thread,
a set of every block that thread has looked up (`CachedCodePages`, a map of sets, about 60 bytes
for each thread and block in the test). Endfield has roughly 1 GB of translated code; a thread
that runs much of the game legitimately holds 100 MB or more of this. My estimate is 1 to 2 GB
real and 4.5 to 5.5 GB committed and unused. Only a measurement settles it.

## Costs that decide the design

Measured under Wine on this Mac (native ARM64 program):

| Operation                                      | Cost    |
|------------------------------------------------|--------:|
| Commit, any piece from 16 KB to 256 KB         |  0.5 µs |
| Commit 4 MB                                    |  1.4 µs |
| First write to a 16K page                      |  0.8 µs |
| Decommit 64 KB                                 |  1.5 µs |
| Commit from a fault handler (64 KB)            |  5.0 µs |

Committing in small pieces is nearly free: a thread that fills 100 MB of heap in 64 KB pieces
spends 0.8 ms on it in total. Fault-driven commit costs ten times more a piece and is still
small. It has one hard limit: it only works for memory that Windows-side code touches. A
buffer passed to a system call is written by Wine's Unix side, which checks that the pages are
committed and fails the call otherwise. Heap memory is passed to system calls; call-return
stacks and compile buffers are not.

## Options

### A. Commit emulator memory as it is used

Three separate changes inside FEX, all local patches.

1. **rpmalloc: commit a page's prefix.** Commit only the header piece when a page is created,
   and extend the commit in 64 KB pieces as `block_initialized` advances. The check sits in
   `page_initialize_blocks`, which is already the slow path, so allocation speed is unchanged.
   The mark fits in spare bits of the page header (no layout change). Decommit and reuse of a
   page reset it. Expected in Endfield: 4.5 to 5.5 GB. Risk: this is the allocator under every
   x64 program; a mistake crashes all of them. The logic is small and the suite runs it hard.
2. **Call-return stack: commit on fault.** Reserve 4 MB, commit 64 KB around the starting
   point, let the existing fault handler commit more. Only generated code touches it. Expected:
   0.35 to 0.6 GB. Low risk.
3. **Compile buffers: commit on fault.** Same mechanism for the IR and backend buffers.
   Expected: 0.2 to 1.2 GB (it varied between runs). Low risk.

What A does not cover: the game's own committed and unused memory, Wine's thread stacks (1 MB
committed each where Windows commits a few pages), and anything in other games I have not
seen.

A cheaper variant of A1 is to shrink rpmalloc's page sizes (4 MB to 1 MB, 64 MB to 16 MB). It
is a change of constants, cuts the waste to a quarter and does not remove it. I do not
recommend it over A1.

### B. Make reads free: a zero page for Wine

Back committed memory with private mappings of one small file of zeroes instead of anonymous
memory. Reads then share the file's pages and cost nothing (table at the top); the first write
to a page copies it and makes it private, as now.

- Covers everything at once: emulator, game, Wine, every future game, with no per-structure
  work. It makes macOS behave as Linux does here.
- Speed: reads of untouched memory get faster (29 ms against 72 ms a GB). The first write to
  a page gets slower, 1.1 µs against 0.76 µs, about 0.35 µs more for each 16K page: 0.2 s over
  the life of a game that touches 10 GB. A page that is read and then written costs 2.2 µs.
- Risk: it changes the core of Wine's memory code (reserve, commit, decommit) for every
  program. Open questions that need a prototype: executable memory (a region allocated
  writable and later made executable would have file-backed pages; macOS code-signing rules
  may object), the number of kernel map entries for hundreds of GB of reservations (one for
  each template-sized piece; a 64 to 128 MB template keeps it in the low thousands), and
  interaction with write watches and FineWine's write/execute page flipping.

### C. Reduce what the emulator really uses

Independent of scanners, and only worth doing once A shows the real figure.

- `CachedCodePages`: a map of sets, about 60 bytes for each thread and block. A flat sorted
  array would be about 8.
- Per-thread second-level lookup memory: 64 KB for each page of game code a thread runs, up
  to 128 MB a thread. 142 MB in Endfield, so not a priority.

These touch FEX's lookup paths and can cost speed; they need benchmarks before and after.

## Recommendation

1. A1, A2, A3 first. They are contained, their speed cost is measured and negligible, and A1
   alone addresses the largest item. Add an emulator-heap line (used against committed) to the
   memory log at the same time, so the next Endfield run states the real use instead of my
   estimate.
2. Prototype B behind a switch that is off by default, run the suite and both games with it,
   and decide on the evidence. If it holds, it is the general answer for all games and A
   becomes a second line of defence.
3. Decide on C from the measured real use.

Expected Endfield footprint after step 1: 9 to 11 GB (estimate).

## What was built (2026-11-18)

Options A and B, on the user's decision; C is left for later.

**A, in FEX** (patches/fex 0006 and 0007):

- rpmalloc commits a page in 64 KB pieces as its blocks are handed out.
- Call-return stacks and compile buffers are reserved and committed by the fault handler.

Test with 32 x64 threads that each ran 24,000 small functions:

| Build                      | In use | After reading all committed memory |
|----------------------------|-------:|-----------------------------------:|
| Before A                   | 109 MB |                            1655 MB |
| With A                     | 109 MB |                             265 MB |
| With A and B switched on   | 109 MB |                             143 MB |

Speed with A: compiling 48,000 blocks takes 594 to 604 ms (585 to 695 before), and starting
256 threads that run them and exit takes 2.8 to 3.1 s (2.9 to 3.0 before). No measurable
change.

**B, in Wine** (runtime patch 0036), a prototype behind `FINEWINE_ZERO_PAGES=1`, off by
default. Memory from NtAllocateVirtualMemory and thread stacks is backed by private mappings
of one 32 MB file of zeroes. Checked natively before building it: memory backed this way can
be written and then made executable, and flipped between writable and executable, exactly as
anonymous memory can. Cost under Wine: the first write to a fresh 64 KB piece takes 1.9 µs
instead of 0.9, a decommit 2.6 µs instead of 1.5.

To try it with a game: in the prefix's Configuration tab, add the environment variable
`FINEWINE_ZERO_PAGES` with value `1`. The full runtime suite passes with it on (42 checks).

**A bug found on the way.** The first version of the code-map fix (runtime patch 0035) crashed
when two threads read the same uncommitted page of the map at once: the second thread's fault
arrived after the first had committed the page and was taken for a real access violation. It
did not happen in the Endfield run, but `tests/runtime/code-map-race.c` hits it every time.
Fixed in 0035.

Not built: a used-against-committed line for the emulator heap in the memory log. With A in,
what is committed is what is used to within 64 KB a page, so the next logged run shows the
real use directly.

## Endfield with A (fourth logged run, 2026-11-18)

Zero pages off. The footprint was level at 11.3 GB three minutes in (15.7 GB before A, 20 GB
before the code-map fix, 40 GB and rising at the start of the day).

| Part                           | Before A | With A |
|--------------------------------|---------:|-------:|
| Emulator heap                  |  6552 MB | 2357 MB |
| Call-return stacks             |   348 MB |    4 MB |
| Compile buffers                |   188 MB |   27 MB |
| Lookup tables                  |   142 MB |  150 MB |
| Game's own large allocations   |  1644 MB | 1650 MB |
| Thread stacks (1 MB regions)   |   213 MB |  216 MB |

The 2.4 GB left in the emulator heap is what FEX really uses, a little above the 1 to 2 GB
estimated. It is concentrated: 8 of the 422 spans hold 1.4 GB, two of them the full 256 MB.
That is the per-thread record of translated blocks (option C). The thread stacks and whatever
the game itself commits and does not use are what B would address.
