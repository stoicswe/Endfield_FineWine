# 18 — D3DMetal 4.0b3 over CrossOver's 3.0 DLLs: the CN launcher crash

> **Status: fixed (Nov 2026).** The patcher installs the D3DMetal DLLs that come with a GPTK, refuses
> a 4.0b3+ framework without them, and repairs copies patched before that. A second report, a
> "Failed to create OpenGL context" dialog in the global launcher on 1.4.2, is **not reproduced** and
> still needs logs.

## Symptom

A user on the CN Gryphline launcher (`Hypergryph Launcher\1.6.0\Games.exe`) reported that it only ran
with DXMT. With D3DMetal it never showed a window. The machine was an Apple M5 on macOS 27.3, with
CrossOver 26.3.0 patched by FineWine.

Their log ([how it was collected](#collecting-launcher-logs)) showed the main thread of `Games.exe`
faulting inside `d3d11.dll`'s `DllMain`, which runs while `Qt5Gui.dll` is still loading:

```
process_attach (L"d3d11.dll") - START
EXCEPTION_ACCESS_VIOLATION addr=0000000212AFEAE0  info[1]=FFFFFFFFFFFFFFF0
...                                  (the handler faults again, over and over)
stack overflow 1984 bytes
err:sync:RtlpWaitForCriticalSection ... "loader_section" wait timed out in thread 0144, blocked by 0140
```

The faulting thread held the loader lock, so every other thread in the process waited on it for
good: no window and no crash report.

## Root cause

The two halves of D3DMetal in the patched app came from different releases:

| Half | Location | CN user | Matches |
|---|---|---|---|
| Framework | `lib64/apple_gptk/external/D3DMetal.framework` | **4.0b3** | GPTK DMG / CrossOver 27 |
| Windows-side DLLs ("glue") | `lib64/apple_gptk/wine/x86_64-windows/*.dll` | **3.0** | stock CrossOver 26.3 |

The DLL sizes (114,240-byte `d3d11.dll`, plus `atidxx64.dll`) are CrossOver 26.3's D3DMetal 3.0 set.
The fault address maps into D3DMetal 4.0b3: the function's unwind entry (`0x139` bytes, FDE
`0x353779` bytes after its start) appears only in that build, at a slide of `0x212973000`. It is
`D3D10CreateBlob`, faulting on `movq %rax, (%rbx)` with `rbx = 0xfffffffffffffff0`, the out-pointer
its caller passed.

From 4.0b3 on, Apple's DLLs reach the framework through a jump table (their `d3d11.dll` embeds the
string `jump_table.h`). The 3.0 DLLs use `__wine_unix_call` instead, so they call the wrong
functions with garbage arguments. It isn't specific to the CN launcher: every DirectX 11 program
crashes that way, the global launcher included.

How the mix arose: the patcher's GPTK step replaced only `apple_gptk/external`, and the docs said not
to copy the DMG's `redist/lib/wine` DLLs. That was safe through 4.0b2 and broke with 4.0b3.

## Reproduction

Each pairing was installed into the patched x64 app (`apple_gptk` backed up first) and the global
launcher was started for 40 s:

| Trial | DLLs | Framework | Result |
|---|---|---|---|
| A | 3.0 | 4.0b3 | Same crash, stack overflow and loader-lock hang as the CN log |
| B | 3.0 | 4.0b2 | Runs; Qt creates its OpenGL contexts |
| C | 3.0 | 3.0 (stock) | Runs; Qt creates its OpenGL contexts |

The working copy on the development machine has CrossOver 27's matched 4.0b3 set: its `d3d11.dll`
and framework are byte-identical to CrossOver 27.0.0.41073's `lib/apple_gptk`.

## The fix (patcher and `swap-into-crossover.sh`)

- **Install the matching DLLs.** A GPTK source's glue is the `wine` folder next to its `external`
  (the DMG's `redist/lib/wine`, or a CrossOver app's `apple_gptk/wine`). The patcher copies
  `x86_64-windows/*.dll` into `apple_gptk/wine` and makes each `x86_64-unix/*.so` a link to
  `../../external/libd3dshared.dylib`, CrossOver's layout. CrossOver's own copy is kept as
  `wine.cxorig`.
- **Refuse the bad mix.** Only 3.x, 4.0b1 and 4.0b2 may run on the stock DLLs. A newer framework
  without glue is rejected with an explanation, and isn't auto-selected.
- **Accept CrossOver 27 as a source.** It ships 4.0b3 with matching DLLs.
- **Repair existing copies** (`D3DMetalRepair.swift`). A copy counts as mixed when a 4.0b3+ framework
  sits on DLLs without `jump_table.h`, or a 3.0 framework on DLLs with it. The main window shows
  **Repair D3DMetal**, and Automated Setup repairs before creating a bottle. The repair prefers glue
  built with that exact framework (matched by hash) from a mounted DMG or a CrossOver app in
  `/Applications`; otherwise it restores CrossOver's 3.0 framework from `external.cxorig`.

Not verified: that the 4.0b3 DMG's `redist/lib/wine/x86_64-windows` DLLs are the same files CrossOver
27 ships. Both are Apple builds, and the CrossOver 27 path is tested.

## The OpenGL dialog (not reproduced)

A 1.4.2 user saw a `Games - GRYPHLINK` dialog: "Failed to create OpenGL context for format
QSurfaceFormat(version 2.0 … alphaBufferSize 8 …)". Qt's launcher creates a desktop OpenGL context
through `opengl32` and `winemac`, not through D3DMetal. With stock 3.0 and the 1.4.2 `winemac.so` and
`dwmapi.dll` (trial C), and with trial B, `wgl:create_context` succeeded twice and the launcher ran.
Trial A crashes before Qt starts, so it doesn't explain the dialog either. Still needed from that
user: chip, macOS version, GPTK version, whether 1.4.1 worked, and a log.

## Collecting launcher logs

Users can run this in Terminal with the patched app and bottle in place (edit `APP=` or `BOTTLE=` at
the top if they were renamed). It starts the launcher with debug channels, waits until it is closed
or Ctrl+C is pressed, and leaves a zip on the Desktop with home-folder paths replaced by `~`:

```bash
bash <<'EOF'
APP="${APP:-/Applications/CrossOver_Endfield_Patch.app}"
BOTTLE="${BOTTLE:-Arknights Endfield}"
CXBIN="$APP/Contents/SharedSupport/CrossOver/bin"
BP="$HOME/Library/Application Support/CrossOver/Bottles/$BOTTLE"
OUT="$HOME/Desktop/finewine-launcher-logs-$(date +%Y%m%d-%H%M%S)"; mkdir -p "$OUT"; touch "$OUT/.start"
find "$BP/drive_c" -maxdepth 5 -iname '*launcher*.exe' -not -ipath '*/windows/*' -not -iname '*unins*' 2>/dev/null > "$OUT/launchers-found.txt"
EXE="${EXE:-$(grep -vi gryphlink "$OUT/launchers-found.txt" | head -1)}"; EXE="${EXE:-$(head -1 "$OUT/launchers-found.txt")}"
[ -n "$EXE" ] || { echo "No launcher found in bottle '$BOTTLE'"; exit 1; }
WINEXE="C:${EXE#"$BP/drive_c"}"
{ sw_vers; uname -m; sysctl -n machdep.cpu.brand_string
  defaults read "$APP/Contents/Info" CFBundleShortVersionString
  echo "launcher: $WINEXE"; ls -la "$(dirname "$EXE")"
  otool -l "$APP/Contents/SharedSupport/CrossOver/lib/wine/x86_64-unix/ntdll.so" | grep -A2 LC_RPATH
  ls -la "$APP/Contents/SharedSupport/CrossOver/lib64/apple_gptk/wine/x86_64-unix" "$APP/Contents/SharedSupport/CrossOver/lib64/apple_gptk/wine/x86_64-windows"
  cat "$BP/cxbottle.conf"; } > "$OUT/inventory.txt" 2>&1
WINEPREFIX="$BP" "$CXBIN/wineserver" -k 2>/dev/null
echo "Launching $WINEXE - reproduce the problem, then close the launcher (or press Ctrl+C)."
QT_LOGGING_RULES="qt.*.debug=true" QSG_INFO=1 QT_DEBUG_PLUGINS=1 \
QTWEBENGINE_CHROMIUM_FLAGS="--enable-logging=stderr --v=1" \
CX_LOG="$OUT/cxlog.txt" "$CXBIN/wine" --bottle "$BOTTLE" \
  --debugmsg "+seh,+loaddll,+process,+module,+dxgi,+d3d,+d3d11,+wgl,+opengl,warn+all,fixme-all" \
  --wait-children --cx-app "$WINEXE" > "$OUT/stdout-stderr.txt" 2>&1
WINEPREFIX="$BP" "$CXBIN/wineserver" -k 2>/dev/null
find "$HOME/Library/Logs/DiagnosticReports" -newer "$OUT/.start" -type f 2>/dev/null | while read -r f; do cp "$f" "$OUT/"; done
for f in "$OUT"/*.txt "$OUT"/*.ips; do [ -f "$f" ] && sed -i '' "s#$HOME#~#g" "$f"; done
cd "$HOME/Desktop" && zip -qr "$OUT.zip" "$(basename "$OUT")" && echo "Done. Please send: $OUT.zip"
EOF
```

It prefers a launcher outside `GRYPHLINK` (the CN one) and records every candidate in
`launchers-found.txt`. In practice the useful evidence is in `cxlog.txt`: whether D3DMetal engaged
(`set_graphics_backend using d3dmetal`), DLL loads, faults and graphics calls. The Qt and Chromium
settings added almost nothing to `stdout-stderr.txt` in testing. The command is x64-only; on
CrossOver ARM the server binary is `wineserver-arm64`.
