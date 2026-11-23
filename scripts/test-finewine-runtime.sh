#!/usr/bin/env bash
# test-finewine-runtime.sh — smoke-test a FineWine runtime built by build-finewine-runtime.sh.
#
# Checks, in a throwaway prefix, that the runtime:
#   1. creates a prefix (wineboot)
#   2. runs a Windows console program and returns its output
#   3. lets a program generate code and run it (tests/runtime/jit.c)
#   4. runs x64 programs through FEX (tests/runtime/x64-hello.c, x64-stress.c), if FEX is installed
#   4a. creates 300 x64 threads that stay alive, quickly (tests/runtime/threads.c)
#   4b. suspends an x64 thread spinning in a tight loop and reads its registers
#      (tests/runtime/suspend-spin.c)
#   4c. writes a memory log when asked: large allocations with their caller, and totals
#      (tests/runtime/memtrace.c)
#   4d. never runs x86 code in its old form after a program rewrote it without notice
#      (tests/runtime/code-rewrite-silent.c)
#   5. creates a Vulkan device and renders with Direct3D 12, both through MoltenVK, from ARM64 and
#      x64, with and without DXMT selected (tests/runtime/vulkan-device.c, d3d12-clear.c)
#   5a. builds acceleration structures (in command buffers and on the host), compacts, serializes
#      and reads them back, and traces rays with Vulkan ray queries, from ARM64 and x64
#      (tests/moltenvk/raytracing.c); then runs a ray tracing pipeline (tests/moltenvk/rtpipeline.c),
#      if the runtime's MoltenVK has ray tracing
#   5c. runs DLSS super resolution and frame generation for Direct3D 12 and Vulkan programs as
#      MetalFX (tests/runtime/dlss-d3d12.c, tests/moltenvk/metalfx.c), and checks which GPU ids
#      each layer reports with and without the prefix asking for an NVIDIA GPU
#   5d. checks the pieces of macOS Game Mode: the game loader, and that rendering programs are
#      recognised (whether macOS turns Game Mode on needs a full-screen game, and is not checked)
#   5b. renders with Direct3D 11 through DXMT, from ARM64 and from x64 (tests/runtime/d3d11-clear.c),
#      if DXMT is installed
#   6. repairs TEB accesses made through x18 (tests/runtime/arm64-x18.c)
#   6a. draws Chinese, Japanese and Korean text, and uses each language's code page when asked
#      (tests/runtime/cjk.c)
#   6b. gives the Dock a program's largest icon, drawn as a Mac app icon (tests/runtime/app-icon.c)
#   6c. with FINEWINE_TEST_ACTIVATE=1 (it switches apps three times): switching to a program does
#      not make Wine read the displays again when they have not changed (tests/runtime/idle-window.c)
#   7. boots a second prefix with MSync on
# Wine writes .update-timestamp as soon as a prefix is set up; the registry files only appear
# when its server exits, so they are not a usable marker. No windows or dialogs are shown. Exit status is 0 only if every check passes.
#
# Usage:  scripts/test-finewine-runtime.sh [runtime folder]   (default: build/finewine-runtime)
set -uo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"
RT="${1:-$REPO/build/finewine-runtime}"
SRC="$REPO/build/finewine-runtime-src"
OBJ="$REPO/build/finewine-runtime-build"
WORK="$(mktemp -d)"
trap 'for p in "$WORK"/pfx*; do [ -d "$p" ] && WINEPREFIX="$p" "$RT/bin/wineserver" -k 2>/dev/null; done; rm -rf "$WORK"' EXIT
BREW="$(command -v brew || echo /opt/homebrew/bin/brew)"
export PATH="$("$BREW" --prefix llvm)/bin:$("$BREW" --prefix lld)/bin:$PATH"
# No crash dialog, no menu entries, no Mono or Gecko download prompts, no debug output.
export WINEDEBUG=-all WINEDLLOVERRIDES="winedbg.exe=d;winemenubuilder.exe=d;mscoree=d;mshtml=d"
# DXVK writes a cache per program where it is told to, or into the folder it was started in.
export DXVK_STATE_CACHE_PATH="$WORK"
failed=0
pass(){ printf '  \033[32m✓\033[0m %s\n' "$*"; }
fail(){ printf '  \033[31m✗\033[0m %s\n' "$*"; failed=1; }

[ -x "$RT/bin/wine" ] || { echo "no runtime at $RT (run scripts/build-finewine-runtime.sh all)"; exit 2; }
echo "runtime: $RT ($("$RT/bin/wine" --version))"

export WINEPREFIX="$WORK/pfx1"
if "$RT/bin/wine" wineboot --init </dev/null >"$WORK/boot.log" 2>&1 && [ -f "$WINEPREFIX/.update-timestamp" ]; then
  pass "creates a prefix"
else fail "wineboot failed (see below)"; tail -n 5 "$WORK/boot.log"; fi

out="$("$RT/bin/wine" cmd /c echo finewine-ok </dev/null 2>/dev/null)"
case "$out" in *finewine-ok*) pass "runs a Windows console program" ;; *) fail "cmd /c echo printed: $out" ;; esac

if [ -d "$SRC/include" ] && "$RT/bin/winegcc" -b aarch64-windows -I"$SRC/include" -I"$SRC/include/msvcrt" \
     -I"$OBJ/include" -L"$RT/lib/wine/aarch64-windows" -mconsole -o "$WORK/jit.exe" "$REPO/tests/runtime/jit.c" \
     >"$WORK/jit-build.log" 2>&1; then
  out="$("$RT/bin/wine" "$WORK/jit.exe" </dev/null 2>/dev/null)"
  case "$out" in *"jit: ok"*) pass "generated code runs (written then executable, writable and executable, rewritten in place)" ;;
    *) fail "generated code did not run:"; echo "$out" | tail -n 4 ;; esac
else
  fail "could not build tests/runtime/jit.c (needs the Wine source and build trees in build/)"; tail -n 3 "$WORK/jit-build.log"
fi
if [ -d "$SRC/include" ] && "$RT/bin/winegcc" -b aarch64-windows -I"$SRC/include" -I"$SRC/include/msvcrt" \
     -I"$OBJ/include" -L"$RT/lib/wine/aarch64-windows" -mconsole -o "$WORK/x18.exe" "$REPO/tests/runtime/arm64-x18.c" \
     >"$WORK/x18-build.log" 2>&1; then
  out="$("$RT/bin/wine" "$WORK/x18.exe" </dev/null 2>/dev/null | tr -d '\r')"
  case "$out" in *"arm64-x18: ok"*) pass "ARM64 code that uses x18 for the TEB is repaired" ;;
    *) fail "x18 repair:"; echo "$out" | grep -v ': ok$' | tail -n 5 ;; esac
else
  fail "could not build tests/runtime/arm64-x18.c"; tail -n 3 "$WORK/x18-build.log"
fi

# x64 programs, translated by FEX. Needs FEX in the runtime (scripts/build-fex.sh) and the
# llvm-mingw compiler it downloads, to build the two x64 test programs.
MINGW="$REPO/build/llvm-mingw/bin/x86_64-w64-mingw32-clang"
if [ ! -f "$RT/lib/wine/aarch64-windows/xtajit64.dll.winestub" ]; then
  echo "  - x64 checks skipped: FEX is not installed in this runtime (scripts/build-fex.sh all)"
elif [ ! -x "$MINGW" ]; then
  echo "  - x64 checks skipped: no llvm-mingw in build/ (scripts/build-fex.sh toolchain)"
else
  if "$MINGW" -O1 -o "$WORK/x64-hello.exe" "$REPO/tests/runtime/x64-hello.c" >"$WORK/x64-build.log" 2>&1 \
     && "$MINGW" -O1 -o "$WORK/x64-stress.exe" "$REPO/tests/runtime/x64-stress.c" >>"$WORK/x64-build.log" 2>&1; then
    out="$("$RT/bin/wine" "$WORK/x64-hello.exe" </dev/null 2>/dev/null)"
    case "$out" in *"hello from x64: sum=500500"*) pass "runs an x64 program through FEX" ;;
      *) fail "x64 hello printed: $out" ;; esac
    out="$("$RT/bin/wine" "$WORK/x64-stress.exe" </dev/null 2>/dev/null | tr -d '\r')"
    case "$out" in *"x64-stress: ok"*) pass "x64 under FEX: threads, floating point, exceptions, generated code, timers, files, shared data page" ;;
      *) fail "x64 stress test:"; echo "$out" | grep -v ': ok$' | tail -n 6 ;; esac
  else
    fail "could not build the x64 test programs"; tail -n 3 "$WORK/x64-build.log"
  fi
  # Memory handed back and taken again reads as zeroes, 4K page by 4K page, though the Mac's
  # pages are 16K. Chromium's JavaScript engine crashes without it.
  MINGWA="$REPO/build/llvm-mingw/bin/aarch64-w64-mingw32-clang"
  if "$MINGW" -O1 -o "$WORK/decommit-x64.exe" "$REPO/tests/runtime/decommit.c" >"$WORK/decommit-build.log" 2>&1 \
     && "$MINGWA" -O1 -o "$WORK/decommit-arm64.exe" "$REPO/tests/runtime/decommit.c" >>"$WORK/decommit-build.log" 2>&1; then
    one="$("$RT/bin/wine" "$WORK/decommit-arm64.exe" </dev/null 2>/dev/null | tr -d '\r' | tail -n 1)"
    two="$("$RT/bin/wine" "$WORK/decommit-x64.exe" </dev/null 2>/dev/null | tr -d '\r' | tail -n 1)"
    case "$one|$two" in "decommit: ok|decommit: ok") pass "decommitted memory reads as zeroes when committed again, down to single 4K pages: ARM64 and x64" ;;
      *) fail "decommitted memory kept its contents (ARM64: '$one', x64: '$two')" ;; esac
  else
    fail "could not build tests/runtime/decommit.c"; tail -n 3 "$WORK/decommit-build.log"
  fi
  # Each x64 thread gets an emulator stack above 4 GB, past macOS's own mappings. Finding room
  # for it stepped over those 64K at a time: 300 threads took 420 seconds, with all other memory
  # calls of the program waiting (a game's loading screen). Now well under a second.
  if "$MINGW" -O1 -o "$WORK/threads.exe" "$REPO/tests/runtime/threads.c" >"$WORK/threads-build.log" 2>&1; then
    out="$("$RT/bin/wine" "$WORK/threads.exe" </dev/null 2>/dev/null | tr -d '\r' | tail -n 1)"
    case "$out" in "threads: ok "*) pass "x64: 300 threads alive at once start quickly (${out#threads: ok } ms)" ;;
      *) fail "creating many x64 threads is slow or fails: $out" ;; esac
  else
    fail "could not build tests/runtime/threads.c"; tail -n 3 "$WORK/threads-build.log"
  fi
  # A garbage collector suspends every thread and reads its registers. FEX looked for a suspend
  # request only at block starts and unconditional jumps back, so a thread spinning in a loop that
  # ends in a conditional jump could never be suspended and the collector waited forever
  # (Genshin Impact on its warning screen). patches/fex/0004.
  if "$MINGW" -O1 -o "$WORK/suspend-spin.exe" "$REPO/tests/runtime/suspend-spin.c" >"$WORK/suspend-spin-build.log" 2>&1; then
    out="$("$RT/bin/wine" "$WORK/suspend-spin.exe" </dev/null 2>/dev/null | tr -d '\r' | tail -n 1)"
    case "$out" in "suspend-spin: ok "*) pass "x64: a thread spinning in a tight loop can be suspended and its registers read" ;;
      *) fail "suspending a spinning x64 thread hangs or fails: $out" ;; esac
  else
    fail "could not build tests/runtime/suspend-spin.c"; tail -n 3 "$WORK/suspend-spin-build.log"
  fi
  # A program that reads through its own memory (anti-cheat does) must not turn FEX's lookup
  # tables (272 MB a thread) or Wine's ARM64EC code map (4 GB) into real memory; Arknights:
  # Endfield reached 40 GB. Both are now committed as they are used. patches/fex/0005, runtime 0035.
  if "$MINGW" -O1 -o "$WORK/scan-memory.exe" "$REPO/tests/runtime/scan-memory.c" >"$WORK/scan-memory-build.log" 2>&1; then
    mkdir -p "$WORK/scan-memory"
    out="$(FINEWINE_MEMORY_TRACE="$WORK/scan-memory" "$RT/bin/wine" "$WORK/scan-memory.exe" </dev/null 2>/dev/null | tr -d '\r' | tail -n 1)"
    mb="$(cat "$WORK/scan-memory"/scan-memory-*.log 2>/dev/null | sed -n 's/.*totals footprint=\([0-9]*\).*/\1/p' | tail -n 1)"
    case "$out" in "scan-memory: ok "*)
      if [ -n "$mb" ] && [ "$mb" -lt 1000 ]; then pass "x64: reading through all committed memory with 16 threads alive costs ${mb} MB"
      else fail "x64: reading through all committed memory grew the program to ${mb:-?} MB"; fi ;;
      *) fail "the memory scan test failed: $out" ;; esac
  else
    fail "could not build tests/runtime/scan-memory.c"; tail -n 3 "$WORK/scan-memory-build.log"
  fi
  # Wine's ARM64EC code map is committed a page at a time as it is read (runtime patch 0035).
  # Threads that read the same new page at once must all get through: the first version failed
  # every thread but the first with an access violation.
  if "$MINGW" -O1 -o "$WORK/code-map-race.exe" "$REPO/tests/runtime/code-map-race.c" >"$WORK/code-map-race-build.log" 2>&1; then
    out="$("$RT/bin/wine" "$WORK/code-map-race.exe" </dev/null 2>/dev/null | tr -d '\r' | tail -n 1)"
    case "$out" in "code-map-race: ok "*) pass "x64: 16 threads jumping into new code at the same moment all run it" ;;
      *) fail "threads entering new code together crash or hang: $out" ;; esac
  else
    fail "could not build tests/runtime/code-map-race.c"; tail -n 3 "$WORK/code-map-race-build.log"
  fi
  # Threads starting while others exit: an exiting thread freed its lookup tables before taking
  # them off FEX's list of ranges to commit on a fault, and could take a new thread's tables off
  # it instead; that thread then hung in exception handling. patches/fex/0009. The program is
  # given 60 seconds (it needs about one).
  if "$MINGW" -O1 -o "$WORK/thread-churn.exe" "$REPO/tests/runtime/thread-churn.c" >"$WORK/thread-churn-build.log" 2>&1; then
    ( "$RT/bin/wine" "$WORK/thread-churn.exe" </dev/null >"$WORK/thread-churn.out" 2>/dev/null ) & churn=$!
    n=0; while kill -0 "$churn" 2>/dev/null && [ "$n" -lt 120 ]; do sleep 0.5; n=$((n+1)); done
    if kill -0 "$churn" 2>/dev/null; then
      pkill -f "$WORK/thread-churn.exe" 2>/dev/null; wait "$churn" 2>/dev/null
      fail "x64: threads starting while others exit hang"
    else
      out="$(tr -d '\r' <"$WORK/thread-churn.out" | tail -n 1)"
      case "$out" in "thread-churn: ok "*) pass "x64: ${out#thread-churn: ok } short threads start while others exit" ;;
        *) fail "short x64 threads: $out" ;; esac
    fi
  else
    fail "could not build tests/runtime/thread-churn.c"; tail -n 3 "$WORK/thread-churn-build.log"
  fi
  # Code that is rewritten, protected and rewritten, or freed and replaced must never run in its
  # old form on any thread, with FEX's usual record of cached blocks and with the compact one
  # (FEX_COMPACTBLOCKRECORDS=1, patches/fex/0008).
  if "$MINGW" -O1 -o "$WORK/code-rewrite.exe" "$REPO/tests/runtime/code-rewrite.c" >"$WORK/code-rewrite-build.log" 2>&1; then
    out="$(FEX_COMPACTBLOCKRECORDS=0 "$RT/bin/wine" "$WORK/code-rewrite.exe" </dev/null 2>/dev/null | tr -d '\r' | tail -n 1)"
    out2="$(FEX_COMPACTBLOCKRECORDS=1 "$RT/bin/wine" "$WORK/code-rewrite.exe" </dev/null 2>/dev/null | tr -d '\r' | tail -n 1)"
    case "$out|$out2" in "code-rewrite: ok "*"|code-rewrite: ok "*) pass "x64: rewritten and replaced code never runs in its old form on 8 threads (usual and compact block records)" ;;
      *) fail "x64 code rewriting: usual records: $out; compact records: $out2" ;; esac
  else
    fail "could not build tests/runtime/code-rewrite.c"; tail -n 3 "$WORK/code-rewrite-build.log"
  fi
  # Code rewritten without a word to anyone, as a regular-expression or script compiler does,
  # must not run in its old form either: the emulator has to notice the write. It traps writes
  # a host page (16K) at a time (patches/fex/0014), and checks code it cannot trap before each
  # run (0013). x64 and, where the toolchain has it, 32-bit; also with every block checked.
  MINGW32_CRS="$REPO/build/llvm-mingw/bin/i686-w64-mingw32-clang"
  if "$MINGW" -O1 -o "$WORK/code-rewrite-silent.exe" "$REPO/tests/runtime/code-rewrite-silent.c" >"$WORK/code-rewrite-silent-build.log" 2>&1; then
    out="$("$RT/bin/wine" "$WORK/code-rewrite-silent.exe" </dev/null 2>/dev/null | tr -d '\r' | tail -n 1)"
    out2="$(FEX_SMCCHECKS=full "$RT/bin/wine" "$WORK/code-rewrite-silent.exe" </dev/null 2>/dev/null | tr -d '\r' | tail -n 1)"
    out3="code-rewrite-silent: ok (no 32-bit)"
    if [ -x "$MINGW32_CRS" ] && [ -f "$RT/lib/wine/aarch64-windows/xtajit.dll" ] \
       && "$MINGW32_CRS" -O1 -o "$WORK/code-rewrite-silent-32.exe" "$REPO/tests/runtime/code-rewrite-silent.c" >>"$WORK/code-rewrite-silent-build.log" 2>&1; then
      out3="$("$RT/bin/wine" "$WORK/code-rewrite-silent-32.exe" </dev/null 2>/dev/null | tr -d '\r' | tail -n 1)"
    fi
    case "$out|$out2|$out3" in "code-rewrite-silent: ok "*"|code-rewrite-silent: ok "*"|code-rewrite-silent: ok "*)
        pass "x64 and 32-bit: code rewritten in place without notice never runs in its old form (trapped by host page, checked where it cannot be trapped)" ;;
      *) fail "silent code rewriting: x64: '$out'; x64 with every block checked: '$out2'; 32-bit: '$out3'" ;; esac
  else
    fail "could not build tests/runtime/code-rewrite-silent.c"; tail -n 3 "$WORK/code-rewrite-silent-build.log"
  fi
  # Honkai: Star Rail's two start-up workarounds (runtime patch 0057): the first connection is
  # refused and the first signature-catalogue lookup succeeds, for StarRail.exe or when asked
  # for by FINEWINE_STARRAIL_WORKAROUNDS=1, and not otherwise.
  if "$MINGW" -O1 -o "$WORK/starrail-start.exe" "$REPO/tests/runtime/starrail-start.c" -lws2_32 -lwintrust >"$WORK/starrail-build.log" 2>&1 \
     && cp "$WORK/starrail-start.exe" "$WORK/StarRail.exe"; then
    a="$(FINEWINE_STARRAIL_WORKAROUNDS=1 "$RT/bin/wine" "$WORK/starrail-start.exe" on </dev/null 2>/dev/null | tr -d '\r' | tail -n 1)"
    b="$("$RT/bin/wine" "$WORK/starrail-start.exe" off </dev/null 2>/dev/null | tr -d '\r' | tail -n 1)"
    c="$("$RT/bin/wine" "$WORK/StarRail.exe" on </dev/null 2>/dev/null | tr -d '\r' | tail -n 1)"
    d="$(FINEWINE_STARRAIL_WORKAROUNDS=0 "$RT/bin/wine" "$WORK/StarRail.exe" off </dev/null 2>/dev/null | tr -d '\r' | tail -n 1)"
    case "$a|$b|$c|$d" in "starrail-start: on ok|starrail-start: off ok|starrail-start: on ok|starrail-start: off ok")
        pass "Star Rail start-up workarounds: on for StarRail.exe and when asked for, off for other programs and when switched off" ;;
      *) fail "Star Rail start-up workarounds: asked for: '$a'; another program: '$b'; StarRail.exe: '$c'; switched off: '$d'" ;; esac
  else
    fail "could not build tests/runtime/starrail-start.c"; tail -n 3 "$WORK/starrail-build.log"
  fi
  # Proton's compatibility switches (runtime patch 0058): each changes what a program sees
  # when it is set and nothing when it is not, for ARM64, x64 and 32-bit programs. The x64 and
  # 32-bit runs also check that the emulator reports the processors Wine does (FEX patch 0015).
  MINGW32_CS="$REPO/build/llvm-mingw/bin/i686-w64-mingw32-clang"
  MINGWA_CS="$REPO/build/llvm-mingw/bin/aarch64-w64-mingw32-clang"
  if "$MINGW" -O1 -o "$WORK/compat-x64.exe" "$REPO/tests/runtime/compat-switches.c" -lws2_32 >"$WORK/compat-build.log" 2>&1 \
     && "$MINGWA_CS" -O1 -o "$WORK/compat-arm64.exe" "$REPO/tests/runtime/compat-switches.c" -lws2_32 >>"$WORK/compat-build.log" 2>&1; then
    [ -x "$MINGW32_CS" ] && "$MINGW32_CS" -O1 -o "$WORK/compat-x86.exe" "$REPO/tests/runtime/compat-switches.c" -lws2_32 >>"$WORK/compat-build.log" 2>&1
    host_cpus="$(sysctl -n hw.ncpu)"
    bad=""
    for arch in arm64 x64 x86; do
      [ -f "$WORK/compat-$arch.exe" ] || continue
      top=1; [ "$arch" = x86 ] && top=-1
      off="$("$RT/bin/wine" "$WORK/compat-$arch.exe" </dev/null 2>/dev/null | tr -d '\r' | tail -n 1)"
      on="$(WINE_HEAP_ZERO_MEMORY=1 WINE_HEAP_DELAY_FREE=1 WINE_HEAP_TOP_DOWN=1 FINEWINE_HIDE_WINE_EXPORTS=1 WINE_CPU_TOPOLOGY=2 \
            WINE_RAM_REPORTING_BIAS=1024 WINE_DISABLE_SFN=1 WINE_BLOCK_HOSTS='example.invalid;finewine-blocked.test' \
            "$RT/bin/wine" "$WORK/compat-$arch.exe" </dev/null 2>/dev/null | tr -d '\r' | tail -n 1)"
      ram_off="$(printf '%s' "$off" | sed -n 's/.* ram=\([0-9]*\) .*/\1/p')"
      ram_on="$(printf '%s' "$on" | sed -n 's/.* ram=\([0-9]*\) .*/\1/p')"
      case "$off" in "compat: zero=0 delay=0 topdown="*" hidden=0 cpus=$host_cpus ram="*" sfn=1 blocked=0") ;; *) bad="$bad $arch without: '$off';" ;; esac
      case "$on" in "compat: zero=1 delay=1 topdown=$top hidden=1 cpus=2 ram="*" sfn=0 blocked=1") ;; *) bad="$bad $arch with: '$on';" ;; esac
      [ -n "$ram_off" ] && [ -n "$ram_on" ] && [ "$((ram_off - ram_on))" = 1024 ] || bad="$bad $arch memory: $ram_off then $ram_on;"
    done
    if [ -z "$bad" ]; then pass "Proton's compatibility switches change what ARM64, x64 and 32-bit programs see, and nothing when unset; the processor count is the Mac's"
    else fail "compatibility switches:$bad"; fi
  else
    fail "could not build tests/runtime/compat-switches.c"; tail -n 3 "$WORK/compat-build.log"
  fi
  # The single-game cases from Proton's Wine (runtime patch 0059) apply to their game and to
  # nothing else: one of them, GDI+'s measure of a lone line break, with its Steam id and without.
  if "$MINGW" -O1 -o "$WORK/game-cases.exe" "$REPO/tests/runtime/game-cases.c" -lgdiplus -lgdi32 >"$WORK/game-cases-build.log" 2>&1; then
    with_id="$(SteamGameId=882710 "$RT/bin/wine" "$WORK/game-cases.exe" </dev/null 2>/dev/null | tr -d '\r' | tail -n 1)"
    without="$("$RT/bin/wine" "$WORK/game-cases.exe" </dev/null 2>/dev/null | tr -d '\r' | tail -n 1)"
    w1="$(printf '%s' "$with_id" | sed -n 's/^game-cases: width=\([0-9]*\)$/\1/p')"
    w0="$(printf '%s' "$without" | sed -n 's/^game-cases: width=\([0-9]*\)$/\1/p')"
    if [ -n "$w1" ] && [ -n "$w0" ] && [ "$w1" -gt "$w0" ]; then
      pass "a single-game case from Proton's Wine applies with the game's Steam id and not without (a line break is $w1 wide, not $w0)"
    else fail "single-game cases: with the id '$with_id', without '$without'"; fi
  else
    fail "could not build tests/runtime/game-cases.c"; tail -n 3 "$WORK/game-cases-build.log"
  fi
  # Media playback (runtime patch 0060): Media Foundation's source reader decodes AAC audio, and
  # H.264 video when a clip can be made, through the runtime's GStreamer and macOS's own decoders,
  # for ARM64 and x64 programs. The sound is made with macOS's say and afconvert; the clip
  # needs ffmpeg (Homebrew's) to be made, and is skipped without it.
  if [ -f "$RT/lib/wine/aarch64-unix/winegstreamer.so" ] \
     && "$MINGW" -O1 -municode -o "$WORK/media-x64.exe" "$REPO/tests/runtime/media.c" -lmfplat -lmfreadwrite -lmfuuid -lole32 >"$WORK/media-build.log" 2>&1 \
     && "$MINGWA_CS" -O1 -municode -o "$WORK/media-arm64.exe" "$REPO/tests/runtime/media.c" -lmfplat -lmfreadwrite -lmfuuid -lole32 >>"$WORK/media-build.log" 2>&1; then
    say -o "$WORK/voice.aiff" "FineWine media test" >/dev/null 2>&1 && afconvert -f m4af -d aac "$WORK/voice.aiff" "$WORK/voice.m4a" >/dev/null 2>&1 || true
    clip=""
    if command -v ffmpeg >/dev/null 2>&1 && [ -f "$WORK/voice.m4a" ] \
       && ffmpeg -loglevel error -y -f lavfi -i testsrc=size=320x240:rate=30 -i "$WORK/voice.m4a" -t 2 -c:v h264_videotoolbox -b:v 400k \
            -pix_fmt yuv420p -c:a copy -shortest "$WORK/clip.mp4" >/dev/null 2>&1; then clip="$WORK/clip.mp4"; fi
    bad=""
    for arch in arm64 x64; do
      if [ -f "$WORK/voice.m4a" ]; then
        out="$("$RT/bin/wine" "$WORK/media-$arch.exe" "Z:$WORK/voice.m4a" </dev/null 2>/dev/null | tr -d '\r' | tail -n 1)"
        case "$out" in "media: audio=0 "*|"media: FAILED"*|"") bad="$bad $arch sound: '$out';" ;; "media: audio="*) ;; *) bad="$bad $arch sound: '$out';" ;; esac
      else bad="$bad no sound file could be made;"; fi
      if [ -n "$clip" ]; then
        out="$("$RT/bin/wine" "$WORK/media-$arch.exe" "Z:$clip" </dev/null 2>/dev/null | tr -d '\r' | tail -n 1)"
        case "$out" in "media: audio=0 "*) bad="$bad $arch clip: '$out';" ;; "media: audio="*" video=320x240 115200") ;; *) bad="$bad $arch clip: '$out';" ;; esac
      fi
    done
    what="AAC sound"; [ -n "$clip" ] && what="AAC sound and H.264 video"
    if [ -z "$bad" ]; then pass "media playback: $what decoded through Media Foundation, ARM64 and x64"
    else fail "media playback:$bad"; fi
  elif [ ! -f "$RT/lib/wine/aarch64-unix/winegstreamer.so" ]; then
    printf '  - %s\n' "media playback: this runtime has no GStreamer, not checked"
  else
    fail "could not build tests/runtime/media.c"; tail -n 3 "$WORK/media-build.log"
  fi
  # The emulator commits its own memory in the fault handler, also while translated code runs.
  # Registers, vector registers, flags, the x87 stack and MXCSR must come back unchanged from
  # such a fault: 192 threads each call 2048 fresh functions with all of them loaded.
  if "$MINGW" -O1 -o "$WORK/reg-fault.exe" "$REPO/tests/runtime/reg-fault.c" >"$WORK/reg-fault-build.log" 2>&1; then
    out="$("$RT/bin/wine" "$WORK/reg-fault.exe" </dev/null 2>/dev/null | tr -d '\r' | tail -n 1)"
    case "$out" in "reg-fault: ok "*) pass "x64: registers, flags and float state survive the emulator's commit faults" ;;
      *) fail "x64 state across commit faults: $out" ;; esac
  else
    fail "could not build tests/runtime/reg-fault.c"; tail -n 3 "$WORK/reg-fault-build.log"
  fi
  # FINEWINE_MEMORY_TRACE=<folder> makes each program log its large memory operations, with the
  # modules that asked for them, and totals with its footprint every five seconds (patch 0034).
  if "$MINGW" -O1 -o "$WORK/memtrace.exe" "$REPO/tests/runtime/memtrace.c" >"$WORK/memtrace-build.log" 2>&1; then
    mkdir -p "$WORK/memtrace"
    out="$(FINEWINE_MEMORY_TRACE="$WORK/memtrace" "$RT/bin/wine" "$WORK/memtrace.exe" </dev/null 2>/dev/null | tr -d '\r' | tail -n 1)"
    mlog="$(ls "$WORK/memtrace"/memtrace-*.log 2>/dev/null | head -n 1)"
    missing=""
    for want in 'reserve+commit .*size=32.00 .*callers: .*memtrace.exe' 'reset .*size=32.00' 'decommit .*size=32.00' \
                'release .*size=32.00' 'map .*size=16.00' 'unmap .*size=16.00' 'totals footprint=[1-9].* decommit-kept=[0-9]'; do
      [ -n "$mlog" ] && [ "$(grep -c -e "$want" "$mlog")" -ge 1 ] || missing="$missing [$want]"
    done
    quiet="$("$RT/bin/wine" "$WORK/memtrace.exe" </dev/null 2>/dev/null | tr -d '\r' | tail -n 1)"
    if [ "$out" = "memtrace: ok" ] && [ "$quiet" = "memtrace: ok" ] && [ -z "$missing" ]; then
      pass "memory log: large allocations with their caller, resets, decommits, mappings and totals with the footprint"
    else fail "memory log is missing lines:$missing (program said '$out')"; fi
  else
    fail "could not build tests/runtime/memtrace.c"; tail -n 3 "$WORK/memtrace-build.log"
  fi
  # An installer that starts the 32-bit setup program of a runtime Wine has built in must see
  # it succeed without it running (a stand-in runs). Any other 32-bit program runs when the
  # runtime has a 32-bit side, and otherwise must fail to start and say so.
  MINGW32="$REPO/build/llvm-mingw/bin/i686-w64-mingw32-clang"
  if [ -x "$MINGW32" ] && mkdir -p "$WORK/redist" \
     && "$MINGW32" -O1 -o "$WORK/redist/vc_redist.x64.exe" "$REPO/tests/runtime/x64-hello.c" >"$WORK/redist-build.log" 2>&1 \
     && cp "$WORK/redist/vc_redist.x64.exe" "$WORK/redist/other32.exe" \
     && "$MINGW" -O1 -municode -o "$WORK/redist/start.exe" "$REPO/tests/runtime/start-and-wait.c" >>"$WORK/redist-build.log" 2>&1; then
    one="$("$RT/bin/wine" "$WORK/redist/start.exe" vc_redist.x64.exe </dev/null 2>/dev/null | tr -d '\r')"
    two="$("$RT/bin/wine" "$WORK/redist/start.exe" other32.exe </dev/null 2>/dev/null | tr -d '\r')"
    if [ -f "$RT/lib/wine/i386-windows/ntdll.dll" ]; then other="hello from x64"; said="run"; else other="could not start"; said="fail to start"; fi
    case "$one|$two" in "started, exit code 0|$other"*) pass "32-bit setup programs of built-in runtimes are reported as installed; other 32-bit programs $said" ;;
      *) fail "32-bit stand-in: runtime setup gave '$one', another 32-bit program gave '$two'" ;; esac
  else
    echo "  - 32-bit stand-in check skipped: could not build its test programs"
  fi
  # The loopback socket pair libcurl makes before every name lookup: a connected socket must
  # know its own port. Without it a Unity game cannot reach any server.
  if "$MINGW" -O1 -o "$WORK/socketpair-x64.exe" "$REPO/tests/runtime/socketpair.c" -lws2_32 >"$WORK/socketpair-build.log" 2>&1 \
     && "$REPO/build/llvm-mingw/bin/aarch64-w64-mingw32-clang" -O1 -o "$WORK/socketpair-arm64.exe" "$REPO/tests/runtime/socketpair.c" -lws2_32 >>"$WORK/socketpair-build.log" 2>&1; then
    one="$("$RT/bin/wine" "$WORK/socketpair-arm64.exe" </dev/null 2>/dev/null | tr -d '\r' | tail -n 1)"
    two="$("$RT/bin/wine" "$WORK/socketpair-x64.exe" </dev/null 2>/dev/null | tr -d '\r' | tail -n 1)"
    case "$one|$two" in "socketpair: ok|socketpair: ok") pass "a connected local socket pair checks out the way libcurl checks it (real ports on both ends): ARM64 and x64" ;;
      *) fail "local socket pair (ARM64: '$one', x64: '$two')" ;; esac
  else
    fail "could not build tests/runtime/socketpair.c"; tail -n 3 "$WORK/socketpair-build.log"
  fi
  # Chromium's switches go to a process that has Chromium in it, and to nothing else: a
  # launcher's folder also holds programs such as 7z.exe, which fail on switches they do not know.
  if mkdir -p "$WORK/cef" && : >"$WORK/cef/libcef.dll" && : >"$WORK/cef/chrome_100_percent.pak" \
     && "$MINGW" -O1 -o "$WORK/cef/vc_redist.x64.exe" "$REPO/tests/runtime/cmdline.c" >"$WORK/cef-build.log" 2>&1 \
     && "$MINGW" -O1 -municode -o "$WORK/cef/start.exe" "$REPO/tests/runtime/start-and-wait.c" >>"$WORK/cef-build.log" 2>&1; then
    "$RT/bin/wine" "$WORK/cef/start.exe" vc_redist.x64.exe </dev/null >/dev/null 2>&1 || true
    got="$(cat "$WORK/cef/cmdline.txt" 2>/dev/null || true)"
    case "$got" in *"--disable-gpu"*|*"--in-process-gpu"*|"") fail "a plain program in a Chromium folder was started with: ${got:-nothing (it did not run)}" ;;
      *"/install /quiet /norestart"*) pass "a program that only shares a folder with Chromium keeps the command line it was given" ;;
      *) fail "unexpected command line: $got" ;; esac
  else
    fail "could not build tests/runtime/cmdline.c"; tail -n 3 "$WORK/cef-build.log"
  fi
  # The stand-in for the Steam client: a program started through it finds Steam "running".
  STEAM="$RT/share/finewine/steam/steam.exe"
  if [ ! -f "$STEAM" ]; then
    echo "  - Steam stand-in check skipped: not in this runtime (scripts/lib/build-steam-helper.sh)"
  elif "$MINGW" -O1 -o "$WORK/steam-probe.exe" "$REPO/tests/runtime/steam-probe.c" >"$WORK/steam-build.log" 2>&1; then
    mkdir -p "$WINEPREFIX/drive_c/Program Files (x86)/Steam"
    cp "$STEAM" "$WINEPREFIX/drive_c/Program Files (x86)/Steam/steam.exe"
    # In the background with a time limit: the stand-in stays until every program has gone.
    ( SteamGameId=zenlesszonezero SteamAppId=zenlesszonezero "$RT/bin/wine" 'C:\Program Files (x86)\Steam\steam.exe' \
        "$WORK/steam-probe.exe" "$WORK/steam-probe.txt" </dev/null >/dev/null 2>&1 ) &
    spid=$!; n=0
    while kill -0 "$spid" 2>/dev/null && [ "$n" -lt 60 ]; do sleep 1; n=$((n+1)); done
    if kill -0 "$spid" 2>/dev/null; then kill "$spid" 2>/dev/null; stayed=" (the stand-in did not exit by itself)"; else stayed=""; fi
    out="$(tr -d '\r' <"$WORK/steam-probe.txt" 2>/dev/null || true)"
    case "$out$stayed" in *"steam-probe: ok") pass "Steam stand-in: a program started through it finds Steam's variables, objects, window, registry and library list, and has its start acknowledged" ;;
      *) fail "Steam stand-in$stayed:"; echo "$out" | grep -v ': ok$' | tail -n 6 ;; esac
  else
    fail "could not build tests/runtime/steam-probe.c"; tail -n 3 "$WORK/steam-build.log"
  fi
fi
# What macOS calls a program, and its tray icon. A small window and a menu bar item appear for
# a few seconds.
MINGWA="$REPO/build/llvm-mingw/bin/aarch64-w64-mingw32-clang"
if [ -x "$MINGWA" ] && "$MINGWA" -O1 -mwindows -o "$WORK/CoolGame.exe" "$REPO/tests/runtime/tray.c" -lshell32 >"$WORK/tray-build.log" 2>&1; then
  ( FINEWINE_TRAY_LOG=1 FINEWINE_APP_NAME="Cool Game Deluxe" FINEWINE_APP_EXE=coolgame.exe \
      "$RT/bin/wine" "$WORK/CoolGame.exe" 7 </dev/null >"$WORK/tray.log" 2>&1 ) &
  sleep 5
  tpid="$(ps -axww -o pid,command | grep '[C]oolGame.exe' | awk '{print $1}' | head -n 1)"
  shown="$(lsappinfo info -only name "$tpid" 2>/dev/null | head -n 1 || true)"
  # The Dock goes by the bundle the process runs from, which is one of the program's own name.
  bundle="$(lsappinfo info "$tpid" 2>/dev/null | grep "bundle path" || true)"
  wait
  case "$bundle" in *'/.finewine-apps/'*'/Cool Game Deluxe.app"'*) pass "a program runs from a bundle of its own name, which is what the Dock shows" ;;
    *) fail "the program's bundle is $bundle, expected one named Cool Game Deluxe.app in the prefix" ;; esac
  tray="$(grep -c 'tray item visible=1 image=yes' "$WORK/tray.log" || true)"
  case "$shown" in *'"Cool Game Deluxe"'*)
      if [ "$tray" -ge 1 ]; then pass "macOS calls a program by its own name, and its tray icon is a menu bar item"
      else fail "the tray icon did not become a visible menu bar item"; grep finewine "$WORK/tray.log" | tail -n 2; fi ;;
    *) fail "macOS calls the program $shown, expected \"Cool Game Deluxe\"" ;; esac
else
  echo "  - program name and tray icon check skipped: could not build tests/runtime/tray.c"
fi
# Command-V pastes into a Windows text field. The Mac's clipboard is used for a moment and put
# back; the key is sent to the test program only. Needs the Accessibility permission.
MINGWA="$REPO/build/llvm-mingw/bin/aarch64-w64-mingw32-clang"
if swiftc -O -o "$WORK/axmenu" "$REPO/tests/runtime/axmenu.swift" >"$WORK/paste-build.log" 2>&1 \
   && [ "$("$WORK/axmenu" trusted)" = yes ] \
   && swiftc -O -o "$WORK/command-key" "$REPO/tests/runtime/command-key.swift" >>"$WORK/paste-build.log" 2>&1 \
   && "$MINGWA" -O1 -mwindows -o "$WORK/PasteTest.exe" "$REPO/tests/runtime/paste.c" >>"$WORK/paste-build.log" 2>&1; then
  saved="$(pbpaste 2>/dev/null || true)"
  printf 'finewine paste check' | pbcopy
  ( "$RT/bin/wine" "$WORK/PasteTest.exe" 9 </dev/null >/dev/null 2>&1 ) &
  sleep 6
  ppid_="$(ps -axww -o pid,command | grep '[P]asteTest.exe' | grep -v -e zsh -e bash | awk '{print $1}' | head -n 1)"
  "$WORK/command-key" "$ppid_" 9 || true
  wait
  printf '%s' "$saved" | pbcopy
  got="$(cat "$WORK/paste.txt" 2>/dev/null || true)"
  if [ "$got" = "finewine paste check" ]; then pass "Command-V pastes the Mac's clipboard into a Windows text field"
  else fail "Command-V left the text field with: '${got}'"; fi
else
  echo "  - paste check skipped: needs the Accessibility permission for the terminal (and swiftc)"
fi
# Direct3D 11 into a window, through a swap chain, on DXMT: what every Direct3D 11 game does.
# (The other Direct3D 11 checks render off screen.) A small window appears for a moment.
MINGWX="$REPO/build/llvm-mingw/bin/x86_64-w64-mingw32-clang"
if [ ! -f "$RT/lib/dxmt/aarch64-windows/d3d11.dll" ] && [ ! -d "$RT/lib/dxmt" ]; then
  echo "  - Direct3D 11 window check skipped: DXMT is not in this runtime"
elif "$MINGWA" -O1 -o "$WORK/d3dwin-arm64.exe" "$REPO/tests/runtime/d3d11-window.c" -ld3d11 -ldxgi -ldxguid -luuid >"$WORK/d3dwin-build.log" 2>&1 \
     && "$MINGWX" -O1 -o "$WORK/d3dwin-x64.exe" "$REPO/tests/runtime/d3d11-window.c" -ld3d11 -ldxgi -ldxguid -luuid >>"$WORK/d3dwin-build.log" 2>&1; then
  one="$(WINEDLLPATH="$RT/lib/dxmt" "$RT/bin/wine" "$WORK/d3dwin-arm64.exe" </dev/null 2>/dev/null | tr -d '\r' | tail -n 1)"
  two="$(WINEDLLPATH="$RT/lib/dxmt" "$RT/bin/wine" "$WORK/d3dwin-x64.exe" 0 0 </dev/null 2>/dev/null | tr -d '\r' | tail -n 1)"
  case "$one|$two" in "d3d11-window: ok|d3d11-window: ok") pass "Direct3D 11 presents into a window through DXMT (swap chain, clear, present, read back): ARM64 and x64" ;;
    *) fail "Direct3D 11 could not present into a window (ARM64: '$one', x64: '$two')" ;; esac
  # A picture smaller than its window in display pixels is upscaled by MetalFX, unless that is turned off.
  mkdir -p "$WORK/fxlog"
  small="$(DXMT_LOG_PATH="$WORK/fxlog" DXMT_LOG_LEVEL=info WINEDLLPATH="$RT/lib/dxmt" "$RT/bin/wine" "$WORK/d3dwin-x64.exe" 0 0 240 160 </dev/null 2>/dev/null | tr -d '\r' | tail -n 1)"
  scaled="$(cat "$WORK"/fxlog/*.log 2>/dev/null | grep -c 'MetalFX spatial upscaling 240x160' || true)"
  rm -f "$WORK"/fxlog/*.log
  FINEWINE_METALFX_AUTO=0 DXMT_LOG_PATH="$WORK/fxlog" DXMT_LOG_LEVEL=info WINEDLLPATH="$RT/lib/dxmt" "$RT/bin/wine" "$WORK/d3dwin-x64.exe" 0 0 240 160 </dev/null >/dev/null 2>&1 || true
  plain="$(cat "$WORK"/fxlog/*.log 2>/dev/null | grep -c 'MetalFX spatial upscaling' || true)"
  if [ "$small" = "d3d11-window: ok" ] && [ "$scaled" -ge 1 ] && [ "$plain" -eq 0 ]; then
    pass "a Direct3D 11 picture smaller than its window is upscaled with MetalFX, and not when that is turned off"
  else fail "MetalFX upscaling of a small picture: program said '$small', upscaled $scaled time(s), and $plain time(s) when turned off"; fi
else
  fail "could not build tests/runtime/d3d11-window.c"; tail -n 3 "$WORK/d3dwin-build.log"
fi
# The menu bar. Opening a menu once left the program stuck in the menu's event loop for good,
# so: open the application menu, close it, and see that the program still answers; then use
# its window commands. Done through the accessibility interface, so it needs that permission.
if [ -x "$MINGWA" ] && swiftc -O -o "$WORK/axmenu" "$REPO/tests/runtime/axmenu.swift" >"$WORK/axmenu-build.log" 2>&1 \
   && [ "$("$WORK/axmenu" trusted)" = yes ] \
   && "$MINGWA" -O1 -mwindows -o "$WORK/MenuTest.exe" "$REPO/tests/runtime/borderless.c" >>"$WORK/axmenu-build.log" 2>&1; then
  ( "$RT/bin/wine" "$WORK/MenuTest.exe" 800 500 22 </dev/null >/dev/null 2>&1 ) &
  sleep 6
  mpid="$(ps -axww -o pid,command | grep '[M]enuTest.exe' | grep -v -e zsh -e bash | awk '{print $1}' | head -n 1)"
  ( "$WORK/axmenu" "$mpid" press 1 >/dev/null 2>&1 & ); sleep 2
  ( "$WORK/axmenu" "$mpid" cancel >/dev/null 2>&1 & ); sleep 2
  answer="$("$WORK/axmenu" "$mpid" list 2>&1 | sed -n 2p || true)"
  ( "$WORK/axmenu" "$mpid" press 1 >/dev/null 2>&1 & ); sleep 1.5
  closed="$("$WORK/axmenu" "$mpid" pick 1 "Close Window" 2>&1 || true)"; sleep 2
  left="$(ps -axww -o pid,command | grep -c '[M]enuTest.exe' || true)"
  kill -9 "$mpid" 2>/dev/null || true; wait 2>/dev/null || true
  case "$answer" in *"Close Window"*)
      case "$closed" in *"enabled true"*) pass "the menu bar opens and closes without hanging the program; its window commands are there and usable" ;;
        *) fail "the application menu's Close Window could not be used: $closed" ;; esac ;;
    *) fail "the program stopped answering after its menu was opened (got: ${answer:-nothing})" ;; esac
else
  echo "  - menu bar check skipped: needs the Accessibility permission for the terminal (and swiftc)"
fi
# Vulkan and Direct3D 12, both through MoltenVK. These must work in every prefix, so each is run
# twice: with Wine's built-in Direct3D, and with DXMT selected the way FineWine selects it.
build_arm64(){ # output source [libs...]
  local out="$1" src="$2"; shift 2
  [ -d "$SRC/include" ] && "$RT/bin/winegcc" -b aarch64-windows -I"$SRC/include" -I"$SRC/include/msvcrt" \
    -I"$OBJ/include" -L"$RT/lib/wine/aarch64-windows" -mconsole -o "$out" "$src" "$@" >>"$WORK/gfx-build.log" 2>&1
}
have_x64=0; [ -x "$MINGW" ] && [ -f "$RT/lib/wine/aarch64-windows/xtajit64.dll.winestub" ] && have_x64=1
for t in vulkan-device d3d12-clear; do
  libs=""; [ "$t" = d3d12-clear ] && libs="-ld3d12 -ldxgi -ldxguid -luuid"
  label="Vulkan device"; [ "$t" = d3d12-clear ] && label="Direct3D 12 (Apple GPU reported, render, read back, swap chain, present)"
  # shellcheck disable=SC2086
  build_arm64 "$WORK/$t-arm64.exe" "$REPO/tests/runtime/$t.c" $libs || { fail "could not build tests/runtime/$t.c for ARM64"; continue; }
  exes="$WORK/$t-arm64.exe"
  if [ "$have_x64" = 1 ]; then
    # shellcheck disable=SC2086
    if "$MINGW" -O1 -o "$WORK/$t-x64.exe" "$REPO/tests/runtime/$t.c" $libs >>"$WORK/gfx-build.log" 2>&1; then exes="$exes $WORK/$t-x64.exe"
    else fail "could not build tests/runtime/$t.c for x64"; fi
  fi
  bad=""
  for exe in $exes; do
    for mode in builtin dxmt; do
      [ "$mode" = dxmt ] && [ ! -f "$RT/lib/dxmt/aarch64-windows/d3d11.dll" ] && continue
      if [ "$mode" = dxmt ]; then export WINEDLLPATH="$RT/lib/dxmt"; else unset WINEDLLPATH; fi
      out="$("$RT/bin/wine" "$exe" </dev/null 2>/dev/null | tr -d '\r')"
      case "$out" in *"$t: ok"*) ;; *) bad="$bad $(basename "$exe" .exe)/$mode"; echo "$out" | tail -n 2 ;; esac
      # Whichever Direct3D layer the prefix uses, the program must be told about the Apple GPU.
      if [ "$t" = d3d12-clear ]; then
        case "$out" in *"adapter: Apple "*"vendor 106b"*) ;; *) bad="$bad $(basename "$exe" .exe)/$mode(adapter)"; echo "$out" | grep '^adapter' ;; esac
      fi
    done
  done
  unset WINEDLLPATH
  archs="ARM64"; [ "$have_x64" = 1 ] && archs="ARM64 and x64"
  if [ -z "$bad" ]; then pass "$label through MoltenVK: $archs, with and without DXMT selected"
  else fail "$label failed for:$bad"; fi
done
# Ray tracing: acceleration structures and ray queries (patches/moltenvk). A triangle is put in a
# bottom-level structure, instanced in a top-level one, and a compute shader traces two rays.
VKH="$REPO/build/vulkan-headers-finewine-src/include"; [ -d "$VKH" ] || VKH="$REPO/build/vulkan-headers-src/include"
# (grep -c rather than -q: with pipefail, -q closing the pipe early would count as a failure.)
if [ "$(nm -gU "$RT/lib/libMoltenVK.dylib" 2>/dev/null | grep -c 'vkCreateAccelerationStructureKHR')" = 0 ]; then
  echo "  - ray tracing check skipped: this runtime's MoltenVK has no ray tracing (MVK_FLAVOR=finewine scripts/build-moltenvk.sh all)"
elif ! command -v glslangValidator >/dev/null || [ ! -d "$VKH" ]; then
  echo "  - ray tracing check skipped: needs glslangValidator (brew install glslang) and the Vulkan headers in build/"
elif ! glslangValidator -V --target-env vulkan1.2 --vn rayquery_spv -o "$WORK/rayquery_spv.h" "$REPO/tests/moltenvk/rayquery.comp" >"$WORK/rt-build.log" 2>&1; then
  fail "could not compile tests/moltenvk/rayquery.comp"; tail -n 3 "$WORK/rt-build.log"
elif ! build_arm64 "$WORK/rt-arm64.exe" "$REPO/tests/moltenvk/raytracing.c" -I"$VKH" -I"$WORK"; then
  fail "could not build tests/moltenvk/raytracing.c for ARM64"; tail -n 3 "$WORK/gfx-build.log"
else
  exes="$WORK/rt-arm64.exe"
  if [ "$have_x64" = 1 ]; then
    if "$MINGW" -O1 -I"$VKH" -I"$WORK" -o "$WORK/rt-x64.exe" "$REPO/tests/moltenvk/raytracing.c" >>"$WORK/gfx-build.log" 2>&1; then exes="$exes $WORK/rt-x64.exe"
    else fail "could not build tests/moltenvk/raytracing.c for x64"; fi
  fi
  bad=""
  for exe in $exes; do
    out="$("$RT/bin/wine" "$exe" </dev/null 2>/dev/null | tr -d '\r')"
    case "$out" in *"raytracing: ok"*) ;; *) bad="$bad $(basename "$exe" .exe)"; echo "$out" | tail -n 2 ;; esac
  done
  archs="ARM64"; [ "$have_x64" = 1 ] && archs="ARM64 and x64"
  if [ -z "$bad" ]; then pass "Vulkan ray tracing through MoltenVK (acceleration structures, ray queries, host builds, serialization): $archs"
  else fail "Vulkan ray tracing failed for:$bad"; fi

  # Ray tracing pipelines: ray generation, miss, closest-hit, any-hit, intersection and callable
  # shaders, shader records, a second ray from a closest-hit shader, direct and indirect dispatch.
  if [ "$(nm -gU "$RT/lib/libMoltenVK.dylib" 2>/dev/null | grep -c 'vkCmdTraceRaysKHR')" = 0 ]; then
    echo "  - ray tracing pipeline check skipped: this runtime's MoltenVK has none (MVK_FLAVOR=finewine scripts/build-moltenvk.sh all)"
  elif ! "$REPO/scripts/lib/compile-rt-shaders.sh" "$REPO/tests/moltenvk/rt" "$WORK/rtpipeline_spv.h" >"$WORK/rtp-build.log" 2>&1; then
    fail "could not compile the shaders in tests/moltenvk/rt"; tail -n 3 "$WORK/rtp-build.log"
  elif ! build_arm64 "$WORK/rtp-arm64.exe" "$REPO/tests/moltenvk/rtpipeline.c" -I"$VKH" -I"$WORK"; then
    fail "could not build tests/moltenvk/rtpipeline.c for ARM64"; tail -n 3 "$WORK/gfx-build.log"
  else
    exes="$WORK/rtp-arm64.exe"
    if [ "$have_x64" = 1 ]; then
      if "$MINGW" -O1 -I"$VKH" -I"$WORK" -o "$WORK/rtp-x64.exe" "$REPO/tests/moltenvk/rtpipeline.c" >>"$WORK/gfx-build.log" 2>&1; then exes="$exes $WORK/rtp-x64.exe"
      else fail "could not build tests/moltenvk/rtpipeline.c for x64"; fi
    fi
    bad=""
    for exe in $exes; do
      out="$("$RT/bin/wine" "$exe" </dev/null 2>/dev/null | tr -d '\r')"
      case "$out" in *"rtpipeline: ok"*) ;; *) bad="$bad $(basename "$exe" .exe)"; echo "$out" | tail -n 2 ;; esac
    done
    if [ -z "$bad" ]; then pass "Vulkan ray tracing pipelines through MoltenVK (all six shader stages, shader records, recursion, indirect): $archs"
    else fail "Vulkan ray tracing pipelines failed for:$bad"; fi
  fi
fi
"$RT/bin/wineserver" -k 2>/dev/null

# DLSS for Direct3D 12 and Vulkan programs: nvngx.dll's entry points, through Wine's vkd3d or
# Wine's Vulkan layer, to MetalFX in MoltenVK. Super resolution and frame generation, from ARM64
# and from x64 programs.
if [ ! -f "$RT/lib/wine/aarch64-windows/nvngx.dll" ]; then
  echo "  - DLSS checks for Direct3D 12 and Vulkan skipped: no nvngx.dll in this runtime (scripts/build-dxmt.sh all)"
else
  exes=""
  if build_arm64 "$WORK/dlss-d3d12-arm64.exe" "$REPO/tests/runtime/dlss-d3d12.c" -ld3d12 -ldxgi -ldxguid -luuid; then exes="$WORK/dlss-d3d12-arm64.exe"
  else fail "could not build tests/runtime/dlss-d3d12.c for ARM64"; fi
  if [ "$have_x64" = 1 ]; then
    if "$MINGW" -O1 -o "$WORK/dlss-d3d12-x64.exe" "$REPO/tests/runtime/dlss-d3d12.c" -ld3d12 -ldxgi -ldxguid -luuid >>"$WORK/gfx-build.log" 2>&1; then exes="$exes $WORK/dlss-d3d12-x64.exe"
    else fail "could not build tests/runtime/dlss-d3d12.c for x64"; fi
  fi
  bad=""
  for exe in $exes; do
    for mode in builtin dxmt; do
      [ "$mode" = dxmt ] && [ ! -f "$RT/lib/dxmt/aarch64-windows/d3d11.dll" ] && continue
      if [ "$mode" = dxmt ]; then export WINEDLLPATH="$RT/lib/dxmt"; else unset WINEDLLPATH; fi
      out="$(FINEWINE_DLSS=1 "$RT/bin/wine" "$exe" </dev/null 2>/dev/null | tr -d '\r')"
      case "$out" in *"dlss-d3d12: ok"*) ;; *) bad="$bad $(basename "$exe" .exe)/$mode"; echo "$out" | tail -n 2 ;; esac
    done
  done
  unset WINEDLLPATH
  archs="ARM64"; [ "$have_x64" = 1 ] && archs="ARM64 and x64"
  if [ -n "$exes" ]; then
    if [ -z "$bad" ]; then pass "DLSS for Direct3D 12 as MetalFX (super resolution, frame generation): $archs, with and without DXMT selected"
    else fail "DLSS for Direct3D 12 failed for:$bad"; fi
  fi

  exes=""
  if [ -d "$VKH" ]; then
    if build_arm64 "$WORK/dlss-vulkan-arm64.exe" "$REPO/tests/moltenvk/metalfx.c" -DVIA_NGX -I"$VKH"; then exes="$WORK/dlss-vulkan-arm64.exe"
    else fail "could not build tests/moltenvk/metalfx.c for ARM64"; fi
    if [ "$have_x64" = 1 ]; then
      if "$MINGW" -O1 -DVIA_NGX -I"$VKH" -o "$WORK/dlss-vulkan-x64.exe" "$REPO/tests/moltenvk/metalfx.c" >>"$WORK/gfx-build.log" 2>&1; then exes="$exes $WORK/dlss-vulkan-x64.exe"
      else fail "could not build tests/moltenvk/metalfx.c for x64"; fi
    fi
  fi
  bad=""
  for exe in $exes; do
    out="$(FINEWINE_DLSS=1 "$RT/bin/wine" "$exe" </dev/null 2>/dev/null | tr -d '\r')"
    case "$out" in *"requests go through nvngx.dll"*"metalfx: ok"*) ;; *) bad="$bad $(basename "$exe" .exe)"; echo "$out" | tail -n 2 ;; esac
  done
  if [ -n "$exes" ]; then
    if [ -z "$bad" ]; then pass "DLSS for Vulkan as MetalFX (super resolution, frame generation): $archs"
    else fail "DLSS for Vulkan failed for:$bad"; fi
  fi
fi

# The GPU a prefix can ask to be reported: an NVIDIA GeForce RTX 5080, by name and by its ids
# (10de:2c02). Set the way FineWine sets them, they must reach Vulkan, Direct3D 12 and Direct3D
# 11; left unset, with DLSS on, every layer must still say Apple (106b).
if [ "$have_x64" = 1 ] && [ -d "$VKH" ] && "$MINGW" -O1 -I"$VKH" -o "$WORK/ids-vulkan.exe" "$REPO/tests/moltenvk/metalfx.c" >"$WORK/ids-build.log" 2>&1 \
   && "$MINGW" -O1 -o "$WORK/ids-d3d12.exe" "$REPO/tests/runtime/d3d12-clear.c" -ld3d12 -ldxgi -ldxguid -luuid >>"$WORK/ids-build.log" 2>&1 \
   && "$MINGW" -O1 -o "$WORK/ids-d3d11.exe" "$REPO/tests/runtime/d3d11-clear.c" -ld3d11 -ldxgi -ldxguid -luuid >>"$WORK/ids-build.log" 2>&1; then
  bad=""
  # Run in a subshell with its messages discarded: a DXMT program is ended by Wine's server
  # when its main thread returns, and the shell would otherwise report that as "Killed".
  ids_of()( # asked(0|1) program -> the lines that carry the adapter's name and ids, joined
    exec 2>/dev/null
    if [ "$1" = 1 ]; then
      FINEWINE_DLSS=1 FINEWINE_GPU_VENDOR_ID=10de FINEWINE_GPU_DEVICE_ID=2c02 FINEWINE_GPU_NAME="NVIDIA GeForce RTX 5080" \
        WINE_D3D_CONFIG="VideoPciVendorID=0x10de,VideoPciDeviceID=0x2c02" DXMT_ENABLE_NVEXT=1 \
        DXMT_CONFIG='dxgi.customVendorId=10de;dxgi.customDeviceId=2c02;dxgi.customDeviceDesc="NVIDIA GeForce RTX 5080"' "$RT/bin/wine" "$2" </dev/null 2>/dev/null
    else
      FINEWINE_DLSS=1 DXMT_ENABLE_NVEXT=1 DXMT_CONFIG="dxgi.customVendorId=106b" "$RT/bin/wine" "$2" </dev/null 2>/dev/null
    fi | tr -d '\r' | grep -i -E '^gpu:|^adapter' | tr '\n' ' '
  )
  case "$(ids_of 1 "$WORK/ids-vulkan.exe")" in *"NVIDIA GeForce RTX 5080, vendor 10de, device 2c02"*) ;; *) bad="$bad vulkan" ;; esac
  case "$(ids_of 0 "$WORK/ids-vulkan.exe")" in *"Apple "*"vendor 106b"*) ;; *) bad="$bad vulkan(unasked)" ;; esac
  case "$(ids_of 1 "$WORK/ids-d3d12.exe")" in *"NVIDIA GeForce RTX 5080 "*"vendor 10de device 2c02"*) ;; *) bad="$bad d3d12" ;; esac
  case "$(ids_of 0 "$WORK/ids-d3d12.exe")" in *"Apple "*"vendor 106b"*) ;; *) bad="$bad d3d12(unasked)" ;; esac
  if [ -f "$RT/lib/dxmt/aarch64-windows/d3d11.dll" ]; then
    export WINEDLLPATH="$RT/lib/dxmt"
    case "$(ids_of 1 "$WORK/ids-d3d11.exe")" in *"NVIDIA GeForce RTX 5080 "*"vendor 10de device 2c02"*) ;; *) bad="$bad d3d11" ;; esac
    case "$(ids_of 0 "$WORK/ids-d3d11.exe")" in *"Apple "*"vendor 106b"*) ;; *) bad="$bad d3d11(unasked)" ;; esac
    case "$(ids_of 1 "$WORK/ids-d3d12.exe")" in *"NVIDIA GeForce RTX 5080 "*"vendor 10de device 2c02"*) ;; *) bad="$bad d3d12/dxmt" ;; esac
    unset WINEDLLPATH
  fi
  if [ -z "$bad" ]; then pass "Reported GPU: Apple's unless asked, an NVIDIA GeForce RTX 5080 by name and ids when asked, in Vulkan, Direct3D 12 and Direct3D 11"
  else fail "reported GPU wrong for:$bad"; fi
elif [ "$have_x64" = 1 ]; then
  fail "could not build the GPU id test programs"; tail -n 3 "$WORK/ids-build.log"
fi
"$RT/bin/wineserver" -k 2>/dev/null

# Game Mode. macOS only turns it on for an app that says it is a game, which for Wine means a
# second copy of the loader, in an app bundle whose Info.plist says so. Checked here: that copy exists and says so; a program told to use
# it runs under it; and the marker by which FineWine learns that a program renders appears for
# Vulkan and Direct3D programs and not for one that draws nothing. Whether macOS then turns
# Game Mode on needs a game in full screen, which this script does not show.
GAME_APP="$RT/lib/wine/aarch64-unix/FineWine Game.app"
GAME_LOADER="$GAME_APP/Contents/MacOS/wine-game"
if [ ! -x "$GAME_LOADER" ]; then
  echo "  - Game Mode check skipped: this runtime has no game loader (scripts/build-finewine-runtime.sh package)"
else
  bad=""
  [ "$(/usr/libexec/PlistBuddy -c 'Print :LSApplicationCategoryType' "$GAME_APP/Contents/Info.plist" 2>/dev/null)" = "public.app-category.games" ] || bad="$bad plist(category)"
  [ "$(/usr/libexec/PlistBuddy -c 'Print :GCSupportsGameMode' "$GAME_APP/Contents/Info.plist" 2>/dev/null)" = "true" ] || bad="$bad plist(game-mode)"
  codesign --verify "$GAME_APP" 2>/dev/null || bad="$bad signature"
  # A program told to use the game loader, and what it starts, run under it.
  if [ -f "$WORK/x64-stress.exe" ]; then
    FINEWINE_LOADER="FineWine Game.app/Contents/MacOS/wine-game" "$RT/bin/wine" "$WORK/x64-stress.exe" </dev/null >/dev/null 2>&1 &
    stress_pid=$!; seen=0
    for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
      case "$(ps -axww -o command)" in *wine-game*x64-stress*) seen=1; break ;; esac
      kill -0 "$stress_pid" 2>/dev/null || break
      perl -e 'select(undef, undef, undef, 0.1)'
    done
    wait "$stress_pid" 2>/dev/null
    [ "$seen" = 1 ] || bad="$bad loader-not-used"
  fi
  marker_after(){ # program [env...] -> yes if running it creates the marker
    local exe="$1" marker="$WORK/marker-$RANDOM"; shift
    env FINEWINE_GAME_MARKER="$marker" "$@" "$RT/bin/wine" "$exe" </dev/null >/dev/null 2>&1
    [ -f "$marker" ] && echo yes || echo no
  }
  [ -f "$WORK/vulkan-device-arm64.exe" ] && [ "$(marker_after "$WORK/vulkan-device-arm64.exe")" != yes ] && bad="$bad marker(vulkan)"
  [ -f "$WORK/d3d12-clear-arm64.exe" ] && [ "$(marker_after "$WORK/d3d12-clear-arm64.exe")" != yes ] && bad="$bad marker(d3d12)"
  [ -f "$WORK/jit.exe" ] && [ "$(marker_after "$WORK/jit.exe")" != no ] && bad="$bad marker(console-program)"
  if [ -f "$RT/lib/dxmt/aarch64-windows/d3d11.dll" ] && [ -f "$WORK/ids-d3d11.exe" ]; then
    [ "$(marker_after "$WORK/ids-d3d11.exe" WINEDLLPATH="$RT/lib/dxmt")" != yes ] && bad="$bad marker(d3d11)"
  fi
  if [ -z "$bad" ]; then pass "Game Mode: the game loader says it is a game and is used when asked; Vulkan, Direct3D 12 and Direct3D 11 programs are recognised as rendering, a console program is not"
  else fail "Game Mode:$bad"; fi
fi
"$RT/bin/wineserver" -k 2>/dev/null

# Finding a prefix's processes from outside, which FineWine's Force Shut Down depends on: every
# Wine process keeps <prefix>/.finewine-alive open, and lsof says who has it open.
if [ -f "$WORK/x64-stress.exe" ]; then
  MTL_HUD_ENABLED=1 FINEWINE_METAL_HUD=0 "$RT/bin/wine" "$WORK/x64-stress.exe" </dev/null >/dev/null 2>&1 &
  held_pid=$!; holders=0
  for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
    holders="$(/usr/sbin/lsof -t "$WINEPREFIX/.finewine-alive" 2>/dev/null | wc -l | tr -d ' ')"
    [ "$holders" -gt 0 ] && break
    kill -0 "$held_pid" 2>/dev/null || break
    perl -e 'select(undef, undef, undef, 0.1)'
  done
  wait "$held_pid" 2>/dev/null
  if [ "$holders" -gt 0 ]; then pass "a prefix's processes can be found from outside ($holders were holding its marker)"
  else fail "no process was holding $WINEPREFIX/.finewine-alive open"; fi
fi

# Full screen the way a Mac game has it, and Game Mode with it. This one covers the display with
# a black window for a few seconds, so it only runs when asked: FINEWINE_TEST_FULLSCREEN=1.
if [ "${FINEWINE_TEST_FULLSCREEN:-0}" = 1 ] && [ -x "$GAME_LOADER" ]; then
  if build_arm64 "$WORK/fullscreen.exe" "$REPO/tests/runtime/fullscreen.c" -luser32 -lgdi32; then
    # gamepolicyctl comes with Xcode, which need not be the selected developer directory.
    GP="$(xcrun --find gamepolicyctl 2>/dev/null || true)"
    [ -n "$GP" ] || GP="$(ls /Applications/Xcode*.app/Contents/Developer/usr/bin/gamepolicyctl 2>/dev/null | tail -n 1 || true)"
    FINEWINE_FULLSCREEN=space FINEWINE_LOADER="FineWine Game.app/Contents/MacOS/wine-game" \
      "$RT/bin/wine" "$WORK/fullscreen.exe" 7 </dev/null >"$WORK/fullscreen.txt" 2>/dev/null &
    fs_pid=$!; game_mode="unknown"
    if [ -n "$GP" ]; then
      game_mode="off"
      for _ in 1 2 3 4 5 6 7 8 9 10 11 12; do
        case "$("$GP" game-mode status 2>/dev/null)" in *"Game mode is "*on*) game_mode="on"; break ;; esac
        perl -e 'select(undef, undef, undef, 0.5)'
      done
    fi
    wait "$fs_pid" 2>/dev/null
    out="$(tr -d '\r' < "$WORK/fullscreen.txt")"
    case "$out" in
      *"fullscreen: ok"*)
        if [ "$game_mode" = off ]; then fail "full screen worked but macOS did not turn Game Mode on"
        else pass "full screen in a Space of its own, and back to a window (Game Mode: $game_mode)"; fi ;;
      *) fail "the full-screen test program did not finish:"; echo "$out" | tail -n 2 ;;
    esac
  else
    fail "could not build tests/runtime/fullscreen.c"; tail -n 3 "$WORK/gfx-build.log"
  fi
  # A Direct3D 9 game in exclusive full screen at a small mode (Portal: 960x600), 32-bit and x64
  # (patches/runtime/0047): the Mac's own display mode must stay as it is, the program's window
  # and screen must agree, and the pointer put in the middle of its screen must be in the
  # middle of the Mac's. Covers the display for a few seconds and moves the pointer and back.
  cat > "$WORK/macstate.swift" <<'SWIFT'
import CoreGraphics
let m = CGDisplayCopyDisplayMode(CGMainDisplayID())!
let p = CGEvent(source: nil)!.location
print("\(m.pixelWidth)x\(m.pixelHeight) \(Int(p.x)) \(Int(p.y)) \(m.width) \(m.height)")
SWIFT
  if swiftc -O -o "$WORK/macstate" "$WORK/macstate.swift" >"$WORK/d9fs-build.log" 2>&1 \
     && "$REPO/build/llvm-mingw/bin/x86_64-w64-mingw32-clang" -O1 -o "$WORK/d9fs-x64.exe" "$REPO/tests/runtime/d3d9-fullscreen.c" -ld3d9 >>"$WORK/d9fs-build.log" 2>&1 \
     && "$REPO/build/llvm-mingw/bin/i686-w64-mingw32-clang" -O1 -o "$WORK/d9fs-32.exe" "$REPO/tests/runtime/d3d9-fullscreen.c" -ld3d9 >>"$WORK/d9fs-build.log" 2>&1; then
    mac_before="$("$WORK/macstate" | cut -d' ' -f1)"; bad=""
    # Twice each: Direct3D's exclusive mode, and the way SDL does it (the program sets the mode
    # and sizes its own window; Portal), which needs the program run as DPI aware, as FineWine
    # runs games.
    for run in "d9fs-x64 0 0" "d9fs-32 0 0" "d9fs-x64 2 1" "d9fs-32 2 1"; do
      set -- $run; exe="$1"; how="$2"; aware="$3"
      [ -f "$RT/lib/wine/i386-windows/ntdll.dll" ] || [ "$exe" = d9fs-x64 ] || continue
      FINEWINE_FULLSCREEN=space FINEWINE_DPI_AWARE="$aware" perl -e 'alarm 60; exec @ARGV' "$RT/bin/wine" "$WORK/$exe.exe" 960 600 5 "$how" </dev/null >"$WORK/$exe.txt" 2>/dev/null &
      during=""
      for _ in $(seq 1 40); do
        if grep -q '^state' "$WORK/$exe.txt" 2>/dev/null; then perl -e 'select(undef, undef, undef, 0.5)'; during="$("$WORK/macstate")"; break; fi
        perl -e 'select(undef, undef, undef, 0.25)'
      done
      wait
      out="$(tr -d '\r' < "$WORK/$exe.txt")"
      state="$(echo "$out" | sed -n 's/^state: //p')"; pointer="$(echo "$out" | sed -n 's/^pointer: //p')"
      w="$(echo "$state" | sed -n 's/.* screen \([0-9]*\)x.*/\1/p')"; h="$(echo "$state" | sed -n 's/.* screen [0-9]*x\([0-9]*\).*/\1/p')"
      exe="$exe/$how"
      case "$out" in *"d3d9-fullscreen: ok"*) ;; *) bad="$bad $exe/$how:did-not-finish" ;; esac
      case "$state" in "window 0,0-$w,$h client ${w}x$h mode 960x600 "*) ;; *) bad="$bad $exe/$how:window($state)" ;; esac
      case "$pointer" in "set $((w/2)),$((h/2)) got $((w/2)),$((h/2)) client middle $((w/2)),$((h/2))") ;; *) bad="$bad $exe/$how:pointer($pointer)" ;; esac
      set -- $during
      [ "${1:-}" = "$mac_before" ] || bad="$bad $exe/$how:mac-mode-changed(${1:-none})"
      # the middle of the Mac's display, within the height of a menu bar
      if [ -n "${5:-}" ]; then
        dx=$(( ${2:-0} - $4 / 2 )); dy=$(( ${3:-0} - $5 / 2 ))
        [ "${dx#-}" -le 4 ] && [ "${dy#-}" -le 40 ] || bad="$bad $exe/$how:mac-pointer(${2:-},${3:-})"
      fi
    done
    "$RT/bin/wineserver" -k 2>/dev/null
    if [ -z "$bad" ]; then pass "Direct3D 9 full screen at 960x600 fills a Space, in exclusive mode and SDL's way: the Mac's mode is untouched, window and pointer agree (x64 and 32-bit)"
    else fail "Direct3D 9 full screen in a Space:$bad"; fi
  else
    fail "could not build the Direct3D 9 full-screen check"; tail -n 3 "$WORK/d9fs-build.log"
  fi
else
  echo "  - full-screen and Game Mode activation not checked: they cover the display (FINEWINE_TEST_FULLSCREEN=1 to run them)"
fi
"$RT/bin/wineserver" -k 2>/dev/null

# Direct3D 11 through DXMT: create a device, clear a render target on the GPU, read a pixel back.
# Run as a native ARM64 program and, when the x64 tools are there, as an x64 program under FEX.
if [ ! -f "$RT/lib/dxmt/aarch64-windows/d3d11.dll" ]; then
  echo "  - Direct3D checks skipped: DXMT is not installed in this runtime (scripts/build-dxmt.sh all)"
else
  export WINEDLLPATH="$RT/lib/dxmt"
  if [ -d "$SRC/include" ] && "$RT/bin/winegcc" -b aarch64-windows -I"$SRC/include" -I"$SRC/include/msvcrt" \
       -I"$OBJ/include" -L"$RT/lib/wine/aarch64-windows" -mconsole -o "$WORK/d3d-arm64.exe" \
       "$REPO/tests/runtime/d3d11-clear.c" -ld3d11 -ldxgi -ldxguid -luuid >"$WORK/d3d-build.log" 2>&1; then
    out="$("$RT/bin/wine" "$WORK/d3d-arm64.exe" </dev/null 2>/dev/null | tr -d '\r')"
    case "$out" in *"d3d11-clear: ok"*) pass "Direct3D 11 on Metal, ARM64 program ($(echo "$out" | sed -n 's/^adapter: //p'))" ;;
      *) fail "Direct3D 11 (ARM64):"; echo "$out" | tail -n 3 ;; esac
  else
    fail "could not build tests/runtime/d3d11-clear.c for ARM64"; tail -n 3 "$WORK/d3d-build.log"
  fi
  if [ -x "$MINGW" ] && [ -f "$RT/lib/wine/aarch64-windows/xtajit64.dll.winestub" ]; then
    if "$MINGW" -O1 -o "$WORK/d3d-x64.exe" "$REPO/tests/runtime/d3d11-clear.c" -ld3d11 -ldxgi -ldxguid -luuid >"$WORK/d3d-build.log" 2>&1; then
      out="$("$RT/bin/wine" "$WORK/d3d-x64.exe" </dev/null 2>/dev/null | tr -d '\r')"
      case "$out" in *"d3d11-clear: ok"*) pass "Direct3D 11 on Metal, x64 program under FEX" ;;
        *) fail "Direct3D 11 (x64 under FEX):"; echo "$out" | tail -n 3 ;; esac
    else
      fail "could not build tests/runtime/d3d11-clear.c for x64"; tail -n 3 "$WORK/d3d-build.log"
    fi
  fi
  # Direct3D 9 is older than anything DXMT covers and goes through WineD3D, also with DXMT selected.
  if [ "$have_x64" = 1 ]; then
    if "$MINGW" -O1 -o "$WORK/d3d9-x64.exe" "$REPO/tests/runtime/d3d9-clear.c" -ld3d9 >"$WORK/d3d9-build.log" 2>&1; then
      out="$("$RT/bin/wine" "$WORK/d3d9-x64.exe" </dev/null 2>/dev/null | tr -d '\r')"
      case "$out" in *"adapter: Apple "*"d3d9-clear: ok"*) pass "Direct3D 9 through WineD3D, x64 program under FEX" ;;
        *) fail "Direct3D 9:"; echo "$out" | tail -n 3 ;; esac
    else
      fail "could not build tests/runtime/d3d9-clear.c"; tail -n 3 "$WORK/d3d9-build.log"
    fi
  fi
  # DLSS as MetalFX: NGX initialises on a DXMT device and NVAPI answers. x64 is what games are.
  if [ -f "$RT/lib/wine/aarch64-windows/nvngx.dll" ] && [ "$have_x64" = 1 ]; then
    if "$MINGW" -O1 -o "$WORK/dlss-x64.exe" "$REPO/tests/runtime/dlss-metalfx.c" -ld3d11 -ldxguid -luuid >"$WORK/dlss-build.log" 2>&1; then
      out="$(DXMT_ENABLE_NVEXT=1 "$RT/bin/wine" "$WORK/dlss-x64.exe" </dev/null 2>/dev/null | tr -d '\r')"
      case "$out" in *"dlss-metalfx: ok"*) pass "DLSS entry points (NGX and NVAPI) initialise on DXMT, x64 under FEX" ;;
        *) fail "DLSS through MetalFX:"; echo "$out" | tail -n 3 ;; esac
    else
      fail "could not build tests/runtime/dlss-metalfx.c"; tail -n 3 "$WORK/dlss-build.log"
    fi
  fi
  unset WINEDLLPATH
fi

# Chinese, Japanese and Korean text (tests/runtime/cjk.c): each East Asian code page converts,
# the ANSI code page follows the locale a prefix is started with (FineWine's "Language for
# non-Unicode programs" sets LC_CTYPE), every font programs ask for draws all three scripts
# through GDI, also with FineWine's Mac dialog font, and DirectWrite's fallback finds a font for
# each in each locale.
if "$REPO/build/llvm-mingw/bin/aarch64-w64-mingw32-clang" -O1 -mconsole -municode -o "$WORK/cjk.exe" "$REPO/tests/runtime/cjk.c" \
     -lgdi32 -ldwrite -luuid >"$WORK/cjk-build.log" 2>&1; then
  cjk(){ "$RT/bin/wineserver" -k 2>/dev/null; env -u LANG -u LC_ALL "$@" "$RT/bin/wine" "$WORK/cjk.exe" ${CJK_CP:-0} </dev/null 2>/dev/null | tr -d '\r'; }
  out="$(cjk)"
  case "$out" in *"cjk: all checks passed"*) pass "Chinese, Japanese and Korean: code pages convert, every font draws all three (GDI), DirectWrite falls back to fonts that have them" ;;
    *) fail "Chinese, Japanese and Korean text:"; echo "$out" | grep -E "^FAIL" | head -n 5 ;; esac
  bad=""
  for pair in ja_JP:932 zh_CN:936 zh_TW:950 ko_KR:949; do
    out="$(CJK_CP="${pair#*:}" cjk LC_CTYPE="${pair%:*}.UTF-8")"
    case "$out" in *"cjk: all checks passed"*) ;; *) bad="$bad ${pair%:*}" ;; esac
  done
  [ -z "$bad" ] && pass "with each East Asian language for non-Unicode programs, the ANSI code page is that language's (932, 936, 950, 949) and text still draws" \
    || fail "language for non-Unicode programs:$bad"
  for name in "MS Shell Dlg" "MS Shell Dlg 2" "Tahoma"; do
    "$RT/bin/wine" reg add 'HKLM\Software\Microsoft\Windows NT\CurrentVersion\FontSubstitutes' /v "$name" /d "Helvetica Neue" /f >/dev/null 2>&1
  done
  out="$(cjk)"
  case "$out" in *"cjk: all checks passed"*) pass "the same with FineWine's Mac dialog font (Helvetica Neue for MS Shell Dlg and Tahoma)" ;;
    *) fail "Chinese, Japanese and Korean text with the Mac dialog font:"; echo "$out" | grep -E "^FAIL" | head -n 5 ;; esac
else
  fail "could not build tests/runtime/cjk.c"; tail -n 3 "$WORK/cjk-build.log"
fi

# The Dock icon (tests/runtime/app-icon.c, icons from tests/runtime/make-icons.py): every size of
# a program's own icon reaches the Dock, a window's larger icon replaces a small one (from a file,
# and from another module's group), Wine's stand-in logo never does, and the icon is drawn as a
# Mac app icon (1024 pixels) unless FINEWINE_MAC_ICONS=0. Each case shows a window for 2 seconds.
ICONS="$WORK/icons"
MINGWA="$REPO/build/llvm-mingw/bin/aarch64-w64-mingw32-clang"
if python3 -I "$REPO/tests/runtime/make-icons.py" "$ICONS" >"$WORK/icon-build.log" 2>&1 \
   && ( for k in round tiny; do printf '1 ICON "%s/%s.ico"\n' "$ICONS" "$k" > "$ICONS/$k.rc" \
        && "$REPO/build/llvm-mingw/bin/aarch64-w64-mingw32-windres" "$ICONS/$k.rc" -O coff -o "$ICONS/$k.res" \
        && "$MINGWA" -O1 -mwindows -o "$ICONS/icon-$k.exe" "$REPO/tests/runtime/app-icon.c" "$ICONS/$k.res" || exit 1; done ) >>"$WORK/icon-build.log" 2>&1; then
  dock(){ local out="$1"; shift; rm -f "${out:?}"; FINEWINE_APP_ICON_DUMP="$out" WINEDEBUG=+macdrv,+image "$RT/bin/wine" "$@" </dev/null 2>&1 | tr -d '\r'; }
  width(){ [ -f "$1" ] && sips -g pixelWidth "$1" 2>/dev/null | awk '/pixelWidth/{print $2}'; }
  log1="$(dock "$ICONS/round.png" "$ICONS/icon-round.exe" own)"
  case "$log1" in *"offered 4 images, largest 256 pixels"*) [ "$(width "$ICONS/round.png")" = 1024 ] \
      && pass "the Dock gets every size of a program's icon (4 of 4, up to 256 pixels), drawn as a 1024-pixel Mac app icon" \
      || fail "Dock icon not drawn as a Mac app icon (width $(width "$ICONS/round.png"))" ;;
    *) fail "the Dock did not get every size of the program's icon:"; echo "$log1" | grep -E "offered|entry" | head -n 5 ;; esac
  # Game Mode's menu and notice take the icon from the bundle on disk, not from the Dock.
  bundle="$(find "$WINEPREFIX/.finewine-apps" -maxdepth 2 -name 'icon-round*.app' 2>/dev/null | head -n 1)"
  if [ -n "$bundle" ] && [ "$(plutil -extract CFBundleIconFile raw "$bundle/Contents/Info.plist" 2>/dev/null)" = AppIcon ] \
     && sips -g pixelWidth "$bundle/Contents/Resources/AppIcon.icns" 2>/dev/null | grep -q 'pixelWidth: 1024'; then
    pass "the program's bundle carries its icon too (AppIcon.icns, 1024 pixels), which is what Game Mode shows"
  else fail "no icon in the program's bundle (${bundle:-no bundle found})"; fi
  log2="$(dock "$ICONS/tiny.png" "$ICONS/icon-tiny.exe" own)"
  case "$log2" in *"Dock icon now 32 pixels"*) case "$log2" in *"Dock icon now 256"*) fail "Wine's stand-in icon replaced a program's own" ;;
      *) pass "a window without an icon does not put Wine's logo in the Dock in place of the program's own" ;; esac ;;
    *) fail "a 32-pixel program got no Dock icon" ;; esac
  log3="$(dock "$ICONS/file.png" "$ICONS/icon-tiny.exe" file "Z:$ICONS/round.ico")"
  log4="$(dock "$ICONS/module.png" "$ICONS/icon-tiny.exe" module "Z:$ICONS/icon-round.exe")"
  case "$log3|$log4" in *"Dock icon now 256 pixels"*"|"*"Dock icon now 256 pixels"*)
      pass "a window's 256-pixel icon replaces a program's 32-pixel one: loaded from a file, and from another module's group" ;;
    *) fail "a window's larger icon did not reach the Dock (file: $(echo "$log3" | grep -c 'now 256'), module: $(echo "$log4" | grep -c 'now 256'))" ;; esac
  FINEWINE_MAC_ICONS=0 dock "$ICONS/plain.png" "$ICONS/icon-round.exe" own >/dev/null
  [ "$(width "$ICONS/plain.png")" = 256 ] && pass "FINEWINE_MAC_ICONS=0 leaves the icon as it is" \
    || fail "FINEWINE_MAC_ICONS=0 still changed the icon (width $(width "$ICONS/plain.png"))"
else
  fail "could not build the Dock icon test programs"; tail -n 3 "$WORK/icon-build.log"
fi
"$RT/bin/wineserver" -k 2>/dev/null

# MSync announces itself only once per user session, so the check is that the prefix boots
# with it switched on; a broken MSync hangs or aborts here.
# Switching to a Wine program made Wine read every display again (modes, EDID, GPUs, registry) on
# the program's message thread: 2.4 seconds in a game at each switch back to it. It now does so
# only when the displays changed (patch 0033). The check switches apps, so it runs only when asked.
if [ "${FINEWINE_TEST_ACTIVATE:-0}" = 1 ] && [ -x "$MINGW" ] && "$MINGW" -O1 -o "$WORK/idle-window.exe" "$REPO/tests/runtime/idle-window.c" -luser32 -lgdi32 >"$WORK/idle-build.log" 2>&1; then
  WINEDEBUG=trace+display "$RT/bin/wine" "$WORK/idle-window.exe" 9 >"$WORK/idle.out" 2>"$WORK/idle.err" </dev/null &
  for _ in $(seq 1 60); do grep -c ready "$WORK/idle.out" >/dev/null 2>&1 && break; sleep 0.25; done
  sleep 1; idle_pid="$(pgrep -f 'idle-window.exe' | head -n 1)"
  swift "$REPO/tests/runtime/activate.swift" "$idle_pid" 3 >/dev/null 2>&1
  sleep 1; reads="$(grep -c 'GPU count' "$WORK/idle.err")"; wait
  if [ "$reads" -le 1 ]; then pass "switching to a program three times read the displays $reads time(s), not three"
  else fail "switching to a program three times read the displays $reads times"; fi
else
  echo "  - display reads on switching to a program not checked: it switches apps (FINEWINE_TEST_ACTIVATE=1 to run it)"
fi

# Discord finds a game by the file name of a running app that is not in a bundle and has a
# window. A program runs from a bundle of its own name, so the Mac driver starts a small
# program next to it under the Windows file name (patch 0039, runtime-extras/presence-helper):
# it must be there with the program's folder and file name while the program shows a window,
# and gone when the program ends.
if [ -x "$RT/lib/wine/aarch64-unix/finewine-presence" ] && [ -x "$MINGW" ] \
   && "$MINGW" -O1 -o "$WORK/presence-game.exe" "$REPO/tests/runtime/idle-window.c" -luser32 -lgdi32 >"$WORK/presence-build.log" 2>&1; then
  mkdir -p "$WINEPREFIX/drive_c/Presence Test"
  cp "$WORK/presence-game.exe" "$WINEPREFIX/drive_c/Presence Test/presence-game.exe"
  "$RT/bin/wine" 'C:\Presence Test\presence-game.exe' 4 </dev/null >/dev/null 2>&1 &
  presence_pid=$!; seen=0
  for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20 21 22 23 24 25 26 27 28 29 30; do
    case "$(ps -axww -o command)" in *"/.finewine-apps/presence/Presence Test/presence-game.exe "*) seen=1; break ;; esac
    kill -0 "$presence_pid" 2>/dev/null || break
    perl -e 'select(undef, undef, undef, 0.1)'
  done
  wait "$presence_pid" 2>/dev/null
  # The program's process can take a few seconds to finish after its launcher has returned.
  left=1
  for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20 21 22 23 24 25 26 27 28 29 30; do
    case "$(ps -axww -o command)" in *"/.finewine-apps/presence/Presence Test/presence-game.exe "*) ;; *) left=0; break ;; esac
    perl -e 'select(undef, undef, undef, 0.5)'
  done
  if [ "$seen" = 1 ] && [ "$left" = 0 ]; then pass "a program has a stand-in under its Windows file name while it runs (for Discord)"
  else fail "presence stand-in: seen=$seen still-there=$left"; ps -axww -o pid,ppid,etime,command | grep -E "presence|Presence" | grep -v grep | cut -c1-260; fi
else
  echo "  - presence stand-in not checked: no finewine-presence in this runtime, or no llvm-mingw"
fi

# A Vulkan swap chain smaller than its window in display pixels is upscaled by MetalFX in
# MoltenVK (patches/moltenvk/0006), the switch for it can be thrown while the program runs,
# and a render size makes programs see a smaller screen (runtime patch 0040). The test
# prefix has Wine's Retina mode off, so on a display with two pixels to the point the
# program's 480x300 swap chain is half its window. A small window appears for a few seconds.
UPVKH="$REPO/build/moltenvk-finewine-src/Package/Release/MoltenVK/include"
if [ ! -x "$MINGW" ] || [ ! -f "$UPVKH/vulkan/vulkan_core.h" ]; then
  echo "  - Vulkan upscaling not checked: no llvm-mingw, or no Vulkan headers from the MoltenVK build"
elif ! "$MINGW" -O1 -I"$UPVKH" -o "$WORK/vulkan-upscale.exe" "$REPO/tests/runtime/vulkan-upscale.c" -luser32 -lgdi32 >"$WORK/upscale-build.log" 2>&1; then
  fail "could not build tests/runtime/vulkan-upscale.c"; tail -n 3 "$WORK/upscale-build.log"
else
  up_run(){ # log seconds [env...] -> runs the program, its output and MoltenVK's log in the file
    local log="$1" secs="$2"; shift 2
    env FINEWINE_GAME_PRESENCE=0 "$@" "$RT/bin/wine" "$WORK/vulkan-upscale.exe" "$secs" >"$log" 2>&1 </dev/null
  }
  up_run "$WORK/up-on.log" 2
  up_run "$WORK/up-off.log" 2 FINEWINE_METALFX_AUTO=0
  # started switched off, switched on from outside as the FineWine app does it
  up_run "$WORK/up-live.log" 6 FINEWINE_METALFX_AUTO=0 &
  up_pid=$!; live_pid=""
  for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
    if grep -aq 'vulkan-upscale: ready' "$WORK/up-live.log" 2>/dev/null; then live_pid="$(pgrep -f 'vulkan-upscale.exe 6' | tail -n 1)"; break; fi
    perl -e 'select(undef, undef, undef, 0.25)'
  done
  [ -n "$live_pid" ] && for p in $(pgrep -f 'vulkan-upscale.exe 6'); do notifyutil -s "finewine.metalfx.$p" 1 >/dev/null 2>&1; done
  wait "$up_pid" 2>/dev/null
  base="$(tr -d '\r' <"$WORK/up-on.log" | sed -n 's/.*vulkan-upscale: ok .* screen \([0-9]*\)x\([0-9]*\).*/\1 \2/p')"
  # a render size: the display's modes are set up when Wine's server starts
  "$RT/bin/wineserver" -k 2>/dev/null; "$RT/bin/wineserver" -w 2>/dev/null
  up_run "$WORK/up-size.log" 2 FINEWINE_RENDER_SCALE=75
  "$RT/bin/wineserver" -k 2>/dev/null; "$RT/bin/wineserver" -w 2>/dev/null
  sized="$(tr -d '\r' <"$WORK/up-size.log" | sed -n 's/.*vulkan-upscale: ok .* screen \([0-9]*\)x\([0-9]*\).*/\1 \2/p')"
  bad=""
  if [ "$(sysctl -n hw.optional.arm64 2>/dev/null)" = 1 ] && system_profiler SPDisplaysDataType 2>/dev/null | grep -q Retina; then
    grep -aq "MetalFX upscales the swapchain's 480 x 300 picture to 960 x 600" "$WORK/up-on.log" || bad="$bad not-upscaled"
    grep -aq "MetalFX upscales" "$WORK/up-off.log" && bad="$bad upscaled-when-off"
    grep -aq "upscaling of the swapchain switched on" "$WORK/up-live.log" || bad="$bad not-switched-live"
  fi
  for f in on off live size; do grep -aq 'vulkan-upscale: ok' "$WORK/up-$f.log" || bad="$bad program($f)"; done
  # 75% of the screen in each direction, to within a few pixels of rounding
  if [ -n "$base" ] && [ -n "$sized" ]; then
    set -- $base $sized
    [ $(( $3 * 100 - $1 * 75 )) -gt -1700 ] && [ $(( $3 * 100 - $1 * 75 )) -lt 1700 ] \
      && [ $(( $4 * 100 - $2 * 75 )) -gt -1700 ] && [ $(( $4 * 100 - $2 * 75 )) -lt 1700 ] || bad="$bad render-size($sized of $base)"
  else bad="$bad render-size(no sizes)"; fi
  if [ -z "$bad" ]; then pass "a Vulkan picture smaller than its window is upscaled with MetalFX, switched while running, and a render size shrinks the screen programs see ($sized of $base)"
  else fail "Vulkan upscaling:$bad"; grep -ah "FineWine\|vulkan-upscale" "$WORK"/up-*.log | tail -n 8; fi
fi

# Playback follows the Mac's output device (headphones connected while a game runs, patch
# 0041): a stream is given a new audio unit and must go on playing. The check does not change
# the Mac's output; it has the driver re-open the stream's device two seconds in, which is the
# same swap, and looks at how much the device took in each second. Silence is played.
if [ -x "$MINGW" ] && "$MINGW" -O1 -o "$WORK/audio-follow.exe" "$REPO/tests/runtime/audio-follow.c" -lole32 >"$WORK/audio-build.log" 2>&1; then
  out="$(FINEWINE_AUDIO_REOPEN_AFTER=2 "$RT/bin/wine" "$WORK/audio-follow.exe" 5 </dev/null 2>/dev/null | tr -d '\r' | tail -n 1)"
  case "$out" in
    "audio-follow: no output device") echo "  - audio following the output device not checked: this Mac has no output device" ;;
    "audio-follow: ok rate "*)
      rate="$(printf '%s' "$out" | sed -n 's/.* rate \([0-9]*\) .*/\1/p')"
      slow=""
      # every second, the one with the swap in it included, the device took most of a second of audio
      for frames in ${out##*per-second }; do [ "$frames" -ge $(( rate * 3 / 4 )) ] || slow="$slow $frames"; done
      if [ -n "$rate" ] && [ -z "$slow" ]; then pass "playback carries on when a stream is moved to another audio unit (the Mac's output device changing)"
      else fail "audio stalled across the swap: $out"; fi ;;
    *) fail "audio-follow: $out" ;;
  esac
else
  echo "  - audio following the output device not checked: no llvm-mingw, or the test did not build"
fi

# 32-bit programs. macOS gives an arm64 process no memory below 4 GB, so a 32-bit program's
# 4 GB are a window higher up (patches/runtime/0043, patches/fex/0011). The suite covers what
# that touches: memory, threads, exceptions, code written at run time, window messages, a small
# window with controls shown for a moment, drawing, and starting another 32-bit program.
MINGW32="$REPO/build/llvm-mingw/bin/i686-w64-mingw32-clang"
export WINEPREFIX="$WORK/pfx1"
if [ ! -f "$RT/lib/wine/aarch64-windows/xtajit.dll" ] || [ ! -f "$RT/lib/wine/i386-windows/ntdll.dll" ]; then
  echo "  - 32-bit checks skipped: this runtime has no 32-bit side (scripts/build-fex.sh and build-finewine-runtime.sh)"
elif [ ! -x "$MINGW32" ]; then
  echo "  - 32-bit checks skipped: no llvm-mingw in build/ (scripts/build-fex.sh toolchain)"
elif "$MINGW32" -O1 -o "$WORK/suite32.exe" "$REPO/tests/runtime/suite32.c" -luser32 -lgdi32 -ladvapi32 >"$WORK/suite32-build.log" 2>&1; then
  if [ -f "$WINEPREFIX/drive_c/windows/syswow64/kernel32.dll" ]; then
    pass "a new prefix gets its 32-bit system folder ($(ls "$WINEPREFIX/drive_c/windows/syswow64" | wc -l | tr -d ' ') files)"
  else fail "a new prefix has no 32-bit system folder (syswow64)"; fi
  out="$(WINEMSYNC=0 "$RT/bin/wine" "$WORK/suite32.exe" </dev/null 2>/dev/null | tr -d '\r')"
  case "$out" in *"
0 failure(s)") pass "32-bit programs: $(echo "$out" | grep -c '^ok ') checks of memory, address space, threads, exceptions, x87, segments, generated code, window messages, drawing, child processes" ;;
    *) fail "32-bit suite:"; echo "$out" | grep -v '^ok ' | tail -n 8 ;; esac
  # MSync is decided when a prefix's server starts, so the server is stopped first.
  "$RT/bin/wineserver" -k 2>/dev/null; "$RT/bin/wineserver" -w 2>/dev/null
  out="$(WINEMSYNC=1 "$RT/bin/wine" "$WORK/suite32.exe" </dev/null 2>/dev/null | tr -d '\r' | tail -n 1)"
  case "$out" in "0 failure(s)") pass "32-bit programs: the same with MSync on" ;;
    *) fail "32-bit suite with MSync on: $out" ;; esac
  "$RT/bin/wineserver" -k 2>/dev/null; "$RT/bin/wineserver" -w 2>/dev/null
  out="$("$RT/bin/wine" 'C:\windows\syswow64\cmd.exe' /c 'echo %PROCESSOR_ARCHITECTURE%' </dev/null 2>/dev/null | tr -d '\r')"
  case "$out" in x86) pass "the 32-bit command prompt runs and sees an x86 processor" ;;
    *) fail "32-bit cmd.exe printed: $out" ;; esac
  # A library whose imports are missing does not stay mapped (patches/runtime/0046): 32-bit and x64.
  mkdir -p "$WORK/fl32" "$WORK/fl64"; fl_ok=1
  for pair in "fl32:$MINGW32" "fl64:$REPO/build/llvm-mingw/bin/x86_64-w64-mingw32-clang"; do
    d="$WORK/${pair%%:*}"; cc="${pair#*:}"
    ( cd "$d" && "$cc" -shared -DDEP -o dep.dll "$REPO/tests/runtime/failed-load.c" \
        && "$cc" -shared -DBIG -o big.dll "$REPO/tests/runtime/failed-load.c" -L. -l:dep.dll \
        && "$cc" -O1 -o failed-load.exe "$REPO/tests/runtime/failed-load.c" && rm dep.dll ) >"$d/build.log" 2>&1 || fl_ok=0
  done
  if [ "$fl_ok" = 1 ]; then
    one="$(cd "$WORK/fl32" && "$RT/bin/wine" failed-load.exe </dev/null 2>/dev/null | tr -d '\r' | tail -n 1)"
    two="$(cd "$WORK/fl64" && "$RT/bin/wine" failed-load.exe </dev/null 2>/dev/null | tr -d '\r' | tail -n 1)"
    case "$one|$two" in "failed-load: ok|failed-load: ok") pass "a library whose imports are missing is unmapped again: 32-bit and x64" ;;
      *) fail "a library that failed to load stays mapped (32-bit: '$one', x64: '$two')" ;; esac
  else
    fail "could not build tests/runtime/failed-load.c"; tail -n 3 "$WORK/fl32/build.log" "$WORK/fl64/build.log"
  fi
  # Direct3D 11 from a 32-bit program, through DXMT's 32-bit Windows side: off screen, then
  # into a window (a small one appears for a moment).
  if [ ! -f "$RT/lib/dxmt/i386-windows/d3d11.dll" ]; then
    echo "  - 32-bit Direct3D 11 checks skipped: DXMT has no 32-bit side in this runtime (scripts/build-dxmt.sh build install)"
  elif "$MINGW32" -O1 -o "$WORK/d3d-32.exe" "$REPO/tests/runtime/d3d11-clear.c" -ld3d11 -ldxgi -ldxguid -luuid >"$WORK/d3d32-build.log" 2>&1 \
       && "$MINGW32" -O1 -o "$WORK/d3dwin-32.exe" "$REPO/tests/runtime/d3d11-window.c" -ld3d11 -ldxgi -ldxguid -luuid >>"$WORK/d3d32-build.log" 2>&1; then
    out="$(WINEDLLPATH="$RT/lib/dxmt" "$RT/bin/wine" "$WORK/d3d-32.exe" </dev/null 2>/dev/null | tr -d '\r')"
    case "$out" in *"d3d11-clear: ok"*) pass "Direct3D 11 on Metal, 32-bit program ($(echo "$out" | sed -n 's/^adapter: //p'))" ;;
      *) fail "Direct3D 11 from a 32-bit program: $(echo "$out" | tail -n 1)" ;; esac
    out="$(WINEDLLPATH="$RT/lib/dxmt" "$RT/bin/wine" "$WORK/d3dwin-32.exe" 0 0 </dev/null 2>/dev/null | tr -d '\r' | tail -n 1)"
    case "$out" in "d3d11-window: ok") pass "Direct3D 11 presents into a window from a 32-bit program" ;;
      *) fail "Direct3D 11 could not present into a window from a 32-bit program: '$out'" ;; esac
  else
    fail "could not build the Direct3D 11 test programs as 32-bit"; tail -n 3 "$WORK/d3d32-build.log"
  fi
  # Direct3D 9 from a 32-bit program, which is what most 32-bit games use. It goes through
  # WineD3D's OpenGL renderer and Wine's OpenGL call layer (patches/runtime/0044): a device and a
  # clear, then buffers, a texture, a draw from memory, a read-back and presenting into a window
  # (a small one appears for a moment). The OpenGL program checks the arguments that are an
  # address or an offset into a buffer; it and the drawing test are also run as x64.
  if "$MINGW32" -O1 -o "$WORK/d3d9-32.exe" "$REPO/tests/runtime/d3d9-clear.c" -ld3d9 >"$WORK/d3d9-32-build.log" 2>&1 \
     && "$MINGW32" -O1 -o "$WORK/d3d9draw-32.exe" "$REPO/tests/runtime/d3d9-draw.c" -ld3d9 >>"$WORK/d3d9-32-build.log" 2>&1 \
     && "$MINGW32" -O1 -o "$WORK/glo-32.exe" "$REPO/tests/runtime/gl-buffer-offsets.c" -lopengl32 -lgdi32 >>"$WORK/d3d9-32-build.log" 2>&1 \
     && "$REPO/build/llvm-mingw/bin/x86_64-w64-mingw32-clang" -O1 -o "$WORK/d3d9draw-x64.exe" "$REPO/tests/runtime/d3d9-draw.c" -ld3d9 >>"$WORK/d3d9-32-build.log" 2>&1 \
     && "$REPO/build/llvm-mingw/bin/x86_64-w64-mingw32-clang" -O1 -o "$WORK/glo-x64.exe" "$REPO/tests/runtime/gl-buffer-offsets.c" -lopengl32 -lgdi32 >>"$WORK/d3d9-32-build.log" 2>&1; then
    # With a time limit: closing an OpenGL context in the Mac driver hangs once in a while (a
    # known fault, see docs/project-information/25), and the script must not hang with it.
    # perl's alarm stands in for `timeout`, which macOS does not have.
    last(){ perl -e 'alarm 90; exec @ARGV' "$RT/bin/wine" "$1" </dev/null 2>/dev/null | tr -d '\r' | tail -n 1
            pkill -f "$(basename "$1")" 2>/dev/null || true; }
    out="$(last "$WORK/d3d9-32.exe")"
    case "$out" in "d3d9-clear: ok") pass "Direct3D 9, 32-bit program: device, clear, read back" ;;
      *) fail "Direct3D 9 from a 32-bit program: '$out'" ;; esac
    one="$(last "$WORK/d3d9draw-x64.exe")"; two="$(last "$WORK/d3d9draw-32.exe")"
    case "$one|$two" in "d3d9-draw: ok|d3d9-draw: ok") pass "Direct3D 9 draws from buffers, a texture and memory, and presents into a window: x64 and 32-bit" ;;
      *) fail "Direct3D 9 drawing (x64: '$one', 32-bit: '$two')" ;; esac
    # The same drawing on Vulkan, which is DXVK's Direct3D 9 on the runtime's MoltenVK (the
    # prefix setting "Direct3D 9 and older on Vulkan"; scripts/build-dxvk.sh). The 32-bit runs
    # are also the check of Vulkan in a 32-bit program (patch 0048). "msaa" is an antialiased
    # back buffer, as a game with antialiasing on has.
    if [ -f "$RT/lib/dxvk/i386-windows/d3d9.dll" ] && [ -f "$RT/lib/dxvk/aarch64-windows/d3d9.dll" ]; then
      dxvk(){ WINEDLLPATH="$RT/lib/dxvk:$RT/lib/dxmt" FINEWINE_DXVK_FEATURES=1 DXVK_LOG_LEVEL=none "$@"; }
      one="$(dxvk last "$WORK/d3d9draw-x64.exe")"; two="$(dxvk last "$WORK/d3d9draw-32.exe")"
      case "$one|$two" in "d3d9-draw: ok|d3d9-draw: ok") pass "Direct3D 9 on Vulkan (DXVK) draws and presents: x64 and 32-bit" ;;
        *) fail "Direct3D 9 on Vulkan (x64: '$one', 32-bit: '$two')" ;; esac
      out="$(dxvk perl -e 'alarm 90; exec @ARGV' "$RT/bin/wine" "$WORK/d3d9draw-32.exe" msaa </dev/null 2>&1 | tr -d '\r')"
      pkill -f d3d9draw-32.exe 2>/dev/null || true
      case "$out" in
        *mvk-error*) fail "Direct3D 9 on Vulkan with antialiasing: MoltenVK reports an error" ;;
        *"d3d9-draw: ok"*) pass "Direct3D 9 on Vulkan (DXVK) with an antialiased back buffer (32-bit)" ;;
        *) fail "Direct3D 9 on Vulkan with antialiasing: '$(printf '%s' "$out" | tail -n 1)'" ;; esac
    else
      fail "the runtime has no DXVK (lib/dxvk): run scripts/build-dxvk.sh"
    fi
    # Every texture format on both of WineD3D's renderers (patch 0050; its Vulkan renderer is
    # not what the prefix setting uses, but it is kept working): the Vulkan renderer must offer
    # what the OpenGL one offers and draw the same: whole textures, parts of them, each mip level
    # and the sampler's largest level (patch 0052). Left out of the comparison: the refilled
    # cases (ATI formats have an odd pitch), the gamma cases (the Vulkan renderer has no sRGB
    # reading or writing for Direct3D 9 yet), X1R5G5B5, which differs by one step of rounding,
    # and three rare formats the Vulkan renderer does not have.
    if "$MINGW32" -O1 -o "$WORK/d3d9formats-32.exe" "$REPO/tests/runtime/d3d9-formats.c" -ld3d9 >>"$WORK/d3d9-32-build.log" 2>&1; then
      formats(){ perl -e 'alarm 300; exec @ARGV' "$RT/bin/wine" "$WORK/d3d9formats-32.exe" </dev/null 2>/dev/null | tr -d '\r' \
                 | grep -E ' (managed|updated|dynamic|large|parts|repart|level|maxlevel|unsupported)|^d3d9-formats' \
                 | grep -vE '^(X1R5G5B5|X4R4G4B4|L6V5U5|X8L8V8U8) '
                 pkill -f d3d9formats-32.exe 2>/dev/null || true; }
      formats > "$WORK/formats-gl.txt"; WINE_D3D_CONFIG=renderer=vulkan formats > "$WORK/formats-vk.txt"
      if grep -q "d3d9-formats: done" "$WORK/formats-vk.txt" && cmp -s "$WORK/formats-gl.txt" "$WORK/formats-vk.txt"; then
        pass "Direct3D 9 texture formats: the Vulkan renderer offers and draws what the OpenGL one does ($(grep -c . "$WORK/formats-vk.txt") cases)"
      else
        fail "Direct3D 9 texture formats differ between OpenGL and Vulkan"; diff "$WORK/formats-gl.txt" "$WORK/formats-vk.txt" | head -n 8
      fi
      # The same on DXVK. Its output is not compared line by line with WineD3D's: it has
      # formats WineD3D lacks and rounds a few differently. It has to get through, and to
      # have the formats games are made of.
      WINEDLLPATH="$RT/lib/dxvk:$RT/lib/dxmt" FINEWINE_DXVK_FEATURES=1 DXVK_LOG_LEVEL=none formats > "$WORK/formats-dxvk.txt"
      missing="$(grep -E '^(A8R8G8B8|X8R8G8B8|R5G6B5|L8|A8L8|A8|DXT1|DXT3|DXT5|ATI2|RGBA16F) +unsupported' "$WORK/formats-dxvk.txt" | awk '{print $1}' | tr '\n' ' ')"
      if grep -q "d3d9-formats: done" "$WORK/formats-dxvk.txt" && [ -z "$missing" ]; then
        pass "Direct3D 9 texture formats on DXVK ($(grep -c . "$WORK/formats-dxvk.txt") cases)"
      else
        fail "Direct3D 9 texture formats on DXVK (not supported: ${missing:-none}; finished: $(grep -c 'd3d9-formats: done' "$WORK/formats-dxvk.txt"))"
      fi
    else
      fail "could not build the Direct3D 9 format test"
    fi
    one="$(last "$WORK/glo-x64.exe")"; two="$(last "$WORK/glo-32.exe")"
    case "$one|$two" in "gl-buffer-offsets: ok|gl-buffer-offsets: ok") pass "OpenGL arguments that are an address or a buffer offset: x64 and 32-bit" ;;
      *) fail "OpenGL addresses and buffer offsets (x64: '$one', 32-bit: '$two')" ;; esac
  else
    fail "could not build the Direct3D 9 and OpenGL test programs"; tail -n 3 "$WORK/d3d9-32-build.log"
  fi
else
  fail "could not build tests/runtime/suite32.c"; tail -n 3 "$WORK/suite32-build.log"
fi

# The Mac's open and save panels in place of the Windows file dialogs (runtime patch 0056).
# The item dialog, GetOpenFileName / GetSaveFileName and SHBrowseForFolder are each given the
# answer a person would give in the panel, as Unix paths, and must hand the program the
# Windows paths the way the Windows dialog does. No panel appears, except in the last two
# checks, where a real one is on screen for a second or two and nobody has to touch it.
FDM="$REPO/build/llvm-mingw/bin"
if [ ! -x "$FDM/x86_64-w64-mingw32-clang" ]; then
  echo "  - file dialog checks skipped: no llvm-mingw in build/ (scripts/build-fex.sh toolchain)"
else
  fd_ok=1
  for pair in "x86_64:fd-x64" "aarch64:fd-arm64" "i686:fd-32"; do
    "$FDM/${pair%%:*}-w64-mingw32-clang" -O1 -municode -o "$WORK/${pair##*:}.exe" "$REPO/tests/runtime/file-dialogs.c" \
      -lole32 -lshell32 -lcomdlg32 -lshlwapi -luuid >>"$WORK/fd-build.log" 2>&1 || fd_ok=0
  done
  if [ "$fd_ok" = 1 ]; then
    FD="$WINEPREFIX/drive_c/fwdlg"; FDOUT="$WORK/fd outside"
    mkdir -p "$FD/sub" "$FDOUT"; echo a > "$FD/a.txt"; echo b > "$FD/b.txt"; echo o > "$FDOUT/o.txt"
    fdrun(){   # <answer> <filter or ""> <delay or ""> <program> <mode> [expected...]
      local answer="$1" filter="$2" delay="$3"; shift 3
      ( export FINEWINE_FILE_PANEL_ANSWER="$answer"
        [ -n "$filter" ] && export FINEWINE_FILE_PANEL_ANSWER_FILTER="$filter"
        [ -n "$delay" ] && export FINEWINE_FILE_PANEL_ANSWER_DELAY="$delay"
        "$RT/bin/wine" "$@" </dev/null 2>/dev/null | tr -d '\r' | tail -n 1 )
    }
    nl=$'\n'
    for exe in fd-x64 fd-arm64 fd-32; do
      bad=""
      [ -f "$RT/lib/wine/i386-windows/ntdll.dll" ] || [ "$exe" != fd-32 ] || continue
      e="$WORK/$exe.exe"
      [ "$(fdrun "$FD/a.txt" 2 "" "$e" open 'C:\fwdlg\a.txt')" = "file-dialogs open: ok" ] || bad="$bad open"
      [ "$(fdrun "$FD/a.txt$nl$FD/b.txt" "" "" "$e" open-multi 'C:\fwdlg\a.txt' 'C:\fwdlg\b.txt')" = "file-dialogs open-multi: ok" ] || bad="$bad open-multi"
      [ "$(fdrun "$FD/sub" "" "" "$e" folder 'C:\fwdlg\sub')" = "file-dialogs folder: ok" ] || bad="$bad folder"
      [ "$(fdrun "$FD/new file.txt" "" "" "$e" save 'C:\fwdlg\new file.txt')" = "file-dialogs save: ok" ] || bad="$bad save"
      [ "$(fdrun "$FD/a.txt" 2 "" "$e" ofn 'C:\fwdlg\a.txt')" = "file-dialogs ofn: ok" ] || bad="$bad ofn"
      [ "$(fdrun "$FD/a.txt$nl$FD/b.txt" "" "" "$e" ofn-multi 'C:\fwdlg' a.txt b.txt)" = "file-dialogs ofn-multi: ok" ] || bad="$bad ofn-multi"
      [ "$(fdrun "$FD/sub" "" "" "$e" browse 'C:\fwdlg\sub')" = "file-dialogs browse: ok" ] || bad="$bad browse"
      [ "$(fdrun cancel "" "" "$e" cancel)" = "file-dialogs cancel: ok" ] || bad="$bad cancel"
      # outside the prefix: through drive Z:
      [ "$(fdrun "$FDOUT/o.txt" 2 "" "$e" open "Z:$(printf '%s' "$FDOUT/o.txt" | tr / '\\')")" = "file-dialogs open: ok" ] || bad="$bad outside-the-prefix"
      if [ -z "$bad" ]; then pass "file dialogs answer through the Mac's panels, $exe: item dialog, GetOpenFileName, SHBrowseForFolder"
      else fail "file dialogs through the Mac's panels, $exe, wrong in:$bad"; fi
    done
    one="$(FINEWINE_NATIVE_FILE_DIALOGS=0 "$RT/bin/wine" "$WORK/fd-x64.exe" enabled </dev/null 2>/dev/null | tr -d '\r' | tail -n 1)"
    two="$("$RT/bin/wine" "$WORK/fd-x64.exe" enabled </dev/null 2>/dev/null | tr -d '\r' | tail -n 1)"
    case "$one|$two" in "file-dialogs enabled: no|file-dialogs enabled: yes") pass "FINEWINE_NATIVE_FILE_DIALOGS=0 turns the Mac's panels off" ;;
      *) fail "the switch for the Mac's panels (off: '$one', on: '$two')" ;; esac
    # With a real panel on screen: an answer that comes after a delay, and a program that
    # closes its dialog itself.
    one="$(fdrun "$FD/sub" "" 1200 "$WORK/fd-x64.exe" folder 'C:\fwdlg\sub')"
    two="$(fdrun cancel "" 30000 "$WORK/fd-x64.exe" close)"
    case "$one|$two" in "file-dialogs folder: ok|file-dialogs close: ok") pass "a real open panel is shown, answers, and closes when the program closes its dialog" ;;
      *) fail "a real open panel (answer after a delay: '$one', closed by the program: '$two')" ;; esac
  else
    fail "could not build tests/runtime/file-dialogs.c"; tail -n 3 "$WORK/fd-build.log"
  fi
fi

export WINEPREFIX="$WORK/pfx2" WINEMSYNC=1 WINEDEBUG=-all
if "$RT/bin/wine" wineboot --init </dev/null >"$WORK/msync.log" 2>&1 && [ -f "$WINEPREFIX/.update-timestamp" ] \
   && [ "$("$RT/bin/wine" cmd /c echo msync-ok </dev/null 2>/dev/null | tr -d '\r')" = "msync-ok" ]; then
  pass "boots with MSync on"
else fail "MSync boot failed (see below)"; tail -n 5 "$WORK/msync.log"; fi

[ "$failed" = 0 ] && echo "all runtime checks passed" || echo "some runtime checks FAILED"
exit "$failed"
