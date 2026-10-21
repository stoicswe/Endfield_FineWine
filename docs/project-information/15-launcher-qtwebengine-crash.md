# 15 — The Gryphline launcher crash (QtWebEngine renderer) — investigated, unresolved

> **Status: UNRESOLVED (Oct 2026).** The **Gryphline launcher** (`Launcher.exe` →
> `Games.exe`, a QtWebEngine / Chromium app) starts, shows its window for a second or two,
> then closes. The **game itself launches fine** (see the workaround). This is **not** ACE and
> **not** the app-bundle/plist changes — it is a Chromium-under-Wine renderer failure.

## Symptom

- Clicking the GRYPHLINK/Endfield link in the CrossOver bottle opens the launcher window, which
  then disappears within ~1–2 s. (The game can be started directly; see below.)
- `Launcher.exe` is only a bootstrap: it spawns `Games.exe` (the real QtWebEngine UI) and exits
  (that part is normal).

## Root cause (captured)

The launcher's Chromium **renderer** process dies:

```
"C:\Program Files\GRYPHLINK\1.6.0\QtWebEngineProcess.exe" --type=renderer --no-sandbox ...
...
wine: Unhandled exception 0xe0000008 in thread 614 at address 00006FFFFFAAD8B7, starting debugger...
```

- `0xe0000008` is raised **non-continuably** in four threads at once — the
  `CompositorTileWorker1..4` (plus a `GpuMemoryThread`) — right after the renderer starts its
  compositor. The vectored handler that declines it lives in Chromium's own
  `Qt5WebEngineCore.dll`. So **Chromium itself raises its fatal/OOM code** here.
  `[CONFIRMED: /tmp/cx-broad.log]`
- `0xe0000008` is Chromium's "out of memory" fatal: per the
  [qt6windows7](https://github.com/crystalidea/qt6windows7) project, Chromium reports a failed
  shared-memory allocation as OOM and dies with `0xe0000008`, and **"without a working GPU
  `cc::BitmapRasterBufferProvider` wants a shared memory bitmap per tile, so the first paint
  kills the renderer."** The affected processes are exactly the compositor tile workers.
  `[CONFIRMED: matching code + process names]`

## What we ruled out (all reproduced with fresh captures)

| Hypothesis / test | Result |
|---|---|
| Broken ACE / Wine module regression | No `KeBugCheckEx`, no unimplemented-function abort; ACE unrelated |
| macOS bundle-id / plist patch (`CrossOvEF`, `.EF` versions) | The failing process is a **Windows** process; it never reads the macOS bundle. Direct-launch and a **stock-CrossOver CLI** run survived. `[not the cause]` |
| High Resolution Mode (`RetinaMode`) | Crash persists with it off |
| Graphics backend (d3dmetal / auto / others) | Crash persists |
| GPU raster flags (`--ignore-gpu-blocklist --enable-gpu-rasterization --enable-zero-copy`) | Crash persists |
| MSync off (`WINEMSYNC=0`) | Crash persists |
| `--single-process --no-sandbox --disable-gpu` | Crash persists |
| **Instrumented Wine syscalls** — `NtCreateSection`, `NtMapViewOfSection`, `NtAllocateVirtualMemory`, `NtProtectVirtualMemory`, `NtCreateNamedPipeFile` (all log a `warn:` on failure) | **Zero failures** across the crashing runs |

The instrumented runs are the key result: **no Wine kernel-side call fails.** So there is no
targeted Wine patch to write for this — the "OOM" is decided inside Chromium, not triggered by a
failing Wine syscall.

## Why this is hard / open

- It is a **Chromium-on-Wine** renderer incompatibility (its compositor/GPU/shared-memory path),
  not a single missing export or object-namespace bug we can emulate the way the ACE patches do.
  The qt6windows7 fix targets Windows 7 (named sections + lockdown token); Wine reports Windows 11,
  so that specific fix does not apply (and our instrumentation confirms section creation does not fail).
- It is **flaky**: sometimes the renderer prints the fatal `0xe0000008`; other times it dies
  silently and `Games.exe` then exits. CLI launches of the same bottle were observed to survive
  while GUI launches crashed, which is consistent with a race around the first paint.

## Workaround: use the direct wine path, not the GUI's Start button

The crash is specific to the **CrossOver GUI's Start path** (`cxmenu --start …`). The same launcher
**runs fine started directly** via `wine --bottle … --cx-app "C:/Program Files/GRYPHLINK/Launcher.exe"`
— verified: that invocation stayed up, while the GUI path died. So the workaround is to launch
through the direct path rather than the GUI's Start button.

- **Direct launcher path:** run `Launcher.exe` through
  `wine --bottle "Arknights Endfield" --cx-app "C:/Program Files/GRYPHLINK/Launcher.exe"` (the exact
  command is in [installation.md §5](../installation.md#5-run-the-game)). Use it to install, update
  and play.
- **Direct game launch (skip the launcher):** `scripts/launch-endfield.sh` starts `Endfield.exe`
  with `-force-d3d11` once the game is installed (the game has its own login UI).

## Evidence

Captures live under `/tmp/cx-*.log` (transient on this machine):
`cx-click.log` (first fatal), `cx-broad.log` (fatal + broadened instrumentation),
`cx-diag*.log` / `cx-msync0.log` / `cx-single.log` (no fatal those runs).

## Open questions / possible next steps (if revisited)

- Whether Chromium's OOM is genuinely a failed allocation or a **limit/accounting** read from Wine
  (e.g. `NtQuerySystemInformation` classes, `GetProcessMitigationPolicy`) — instrumenting those,
  and Chromium's `DiscardVirtualMemory` path, is the next place to look.
- Whether a **working GPU path** for Chromium under Wine (so it does not software-raster tiles)
  would hide the bug — the documented way to avoid `0xe0000008`.
- Whether this is specific to the **x86_64-under-Rosetta** build (a native arm64 Wine might behave
  differently; the launcher is Chromium's own x86_64 code either way).
