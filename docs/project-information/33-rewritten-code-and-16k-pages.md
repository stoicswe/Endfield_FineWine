# Code a program rewrites, and 16K pages

Status on 2026-11-23: **fixed in the emulator (FEX patches 0013 and 0014), tested for x64 and
32-bit programs.** Found through issue 128: the HoYo launcher crashed when a second game that was
already on the disk was located.

## What was wrong

Some programs generate machine code while they run: a script engine, a regular-expression
compiler, a .NET or Java runtime. They write the code into memory that is both writable and
executable, run it, and later write other code to the same place. On an x86 processor that is
all there is to it. An emulator translates code once and keeps the translation, so it has to
find out when the code it translated has been replaced.

FEX finds out by taking the write permission off a page it has translated code from. The
program's next write to that page faults, FEX drops the page's translations, and makes the page
writable again.

FEX does this for one 4K page at a time, which is the page size Windows programs see. The Mac
can only change the permission of one of its own pages, and those are 16K: four 4K pages. Wine
gives such a host page every permission any of its four pages has. Two things followed:

- Taking the write permission off one 4K page did nothing while a neighbour in the same 16K
  page was writable. Inside a block of generated code the neighbours are always writable. The
  write went through without a fault and the old translation kept running.
- Making one 4K page writable again made all four writable, so the other three lost their trap
  while their translations were kept.

The result is a program that runs code it has since replaced. What happens next depends on the
two pieces of code; usually a crash a little later, in a place that has nothing to do with the
cause.

## How it showed up

In the HoYo launcher (issue 128): locating a first game worked, locating a second one closed
the launcher. The launcher passes the folder dialog a start folder once a game is linked, and
on that path it runs a regular expression. Qt compiles regular expressions to machine code
(PCRE2's compiler). The second expression's code was written where an earlier one's had been,
the earlier one's translation ran, came back with the stack pointer 0x110 bytes off, and
returned to address 0.

Nothing in the launcher's or FineWine's logs said so. The launcher writes no record of its own
for this crash, and the fault could not be delivered as a Windows exception (the stack was
already wrong), so the process just ended. It was found by running the same launcher version in
a scratch prefix, driving its page through Chromium's developer port (no mouse involved), and
reading the launcher's stack at the fault: the last return address was in PCRE2's function
that calls generated code.

The crash happened before any dialog was shown, with Wine's own folder dialog as well as with
the Mac's panels (page 32).

## What changed

**Traps cover whole host pages** (`patches/fex/0014`, `Source/Windows/Common/InvalidationTracker`).
The unit is 16K when Wine says the host is macOS, and 4K as before otherwise.

- A page is trapped together with the rest of its host page.
- A write fault drops the translations of the whole host page and gives all of its trapped
  pages their write permission back.
- When any memory becomes writable, the translations from the rest of the host pages it
  starts and ends in are dropped, because those pages can be written without a fault from then
  on.
- Writable code that shares a host page with ordinary writable data cannot be trapped at all:
  the data keeps the host page writable. FEX looks for this at the first and last host page
  of a writable code range (the host pages in between belong to the range alone) and, where it
  finds it, checks the code's bytes before each run instead. That is slower, and applies to
  at most 16K at each end of such a range.

**The check before each run works for x64 programs** (`patches/fex/0013`). FEX already had that
check (its `SMCChecks=full` setting, and one block of Mono's), but on the x64 build the handler
that drops a changed block was not marked as running inside the emulator. Wine then reported the
handler's own memory calls back to the emulator while it held a lock, the report asked for the
same lock, and the program hung the first time checked code changed. The 32-bit build was not
affected.

## Switches

- `FEX_SMCGRANULE=4096` puts the 4K unit back (the old behaviour), to rule this change in or out.
  Any power of two from 4096 to 65536 is accepted.
- `FEX_SMCCHECKS=full` checks every block before each run. Slow; for finding a fault only. It
  used to hang x64 programs and no longer does.

## Tests

`tests/runtime/code-rewrite-silent.c`, run by `scripts/test-finewine-runtime.sh` for x64, for
x64 with every block checked, and for 32-bit. Small functions are called, rewritten in place
with no call that would tell anyone, and called again:

| Case | What it covers |
|---|---|
| alone | One function on a page of a writable block, the launcher's case |
| neighbours | Functions on all pages of two host pages, each rewritten in turn |
| straddling | A function across a 4K and across a 16K boundary, half of it rewritten |
| next to data | Code on a page between pages of ordinary writable data (cannot be trapped) |
| data later | Neighbours read-only at first, made writable afterwards, and read-only again |
| with a thread | Another thread runs code on the next page while this one's is rewritten |

With `FEX_SMCGRANULE=4096` it fails ("3658 of 276443 calls ran old code"); without, it passes.

The launcher itself: with one game linked, "Find Games" for a second game crashed every time
before, and with the 4K unit put back; with the fix it opened the dialog every time, and a
second game was found and linked through a real panel. That was done with the global launcher
(HoYoPlay 1.19.0.382, the reporter's version) and stand-in game folders; the reporter used the
Chinese launcher with real games.

## What it costs

More translations are dropped per write (a 16K page's worth, not a 4K page's), so a program that
rewrites code often translates somewhat more. Nothing was measured as slower; the launcher's
browser engine, which generates code constantly, runs as before. No game was measured.

## Not covered

- Writable code next to writable data is checked before each run only at the edges of a code
  range, found when the code is translated. Memory that becomes writable later drops the
  neighbouring translations, so they are looked at again.
- Other things that rely on 4K permissions (guard pages, write watches) still get the host
  page's combined permission. That is Wine's behaviour and was not changed here.

Both FEX patches are local: FEX does not take AI-written code.
