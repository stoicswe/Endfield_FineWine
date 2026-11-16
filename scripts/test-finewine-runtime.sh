#!/usr/bin/env bash
# test-finewine-runtime.sh — smoke-test a FineWine runtime built by build-finewine-runtime.sh.
#
# Checks, in a throwaway prefix, that the runtime:
#   1. creates a prefix (wineboot)
#   2. runs a Windows console program and returns its output
#   3. lets a program generate code and run it (tests/runtime/jit.c)
#   4. runs x64 programs through FEX (tests/runtime/x64-hello.c, x64-stress.c), if FEX is installed
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
  # 32-bit programs cannot run here (no memory below 4 GB). An installer that starts the 32-bit
  # setup program of a runtime Wine has built in must see it succeed; any other 32-bit program
  # must still fail to start, and say so.
  MINGW32="$REPO/build/llvm-mingw/bin/i686-w64-mingw32-clang"
  if [ -x "$MINGW32" ] && mkdir -p "$WORK/redist" \
     && "$MINGW32" -O1 -o "$WORK/redist/vc_redist.x64.exe" "$REPO/tests/runtime/x64-hello.c" >"$WORK/redist-build.log" 2>&1 \
     && cp "$WORK/redist/vc_redist.x64.exe" "$WORK/redist/other32.exe" \
     && "$MINGW" -O1 -municode -o "$WORK/redist/start.exe" "$REPO/tests/runtime/start-and-wait.c" >>"$WORK/redist-build.log" 2>&1; then
    one="$("$RT/bin/wine" "$WORK/redist/start.exe" vc_redist.x64.exe </dev/null 2>/dev/null | tr -d '\r')"
    two="$("$RT/bin/wine" "$WORK/redist/start.exe" other32.exe </dev/null 2>/dev/null | tr -d '\r')"
    case "$one|$two" in "started, exit code 0|could not start"*) pass "32-bit setup programs of built-in runtimes are reported as installed; other 32-bit programs fail to start" ;;
      *) fail "32-bit stand-in: runtime setup gave '$one', another 32-bit program gave '$two'" ;; esac
  else
    echo "  - 32-bit stand-in check skipped: could not build its test programs"
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
    case "$out$stayed" in *"steam-probe: ok") pass "Steam stand-in: a program started through it finds Steam's variables, objects, window and registry" ;;
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
  wait
  tray="$(grep -c 'tray item visible=1 image=yes' "$WORK/tray.log" || true)"
  case "$shown" in *'"Cool Game Deluxe"'*)
      if [ "$tray" -ge 1 ]; then pass "macOS calls a program by its own name, and its tray icon is a menu bar item"
      else fail "the tray icon did not become a visible menu bar item"; grep finewine "$WORK/tray.log" | tail -n 2; fi ;;
    *) fail "macOS calls the program $shown, expected \"Cool Game Deluxe\"" ;; esac
else
  echo "  - program name and tray icon check skipped: could not build tests/runtime/tray.c"
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
"$RT/bin/wineserver" -k 2>/dev/null

# MSync announces itself only once per user session, so the check is that the prefix boots
# with it switched on; a broken MSync hangs or aborts here.
export WINEPREFIX="$WORK/pfx2" WINEMSYNC=1 WINEDEBUG=-all
if "$RT/bin/wine" wineboot --init </dev/null >"$WORK/msync.log" 2>&1 && [ -f "$WINEPREFIX/.update-timestamp" ] \
   && [ "$("$RT/bin/wine" cmd /c echo msync-ok </dev/null 2>/dev/null | tr -d '\r')" = "msync-ok" ]; then
  pass "boots with MSync on"
else fail "MSync boot failed (see below)"; tail -n 5 "$WORK/msync.log"; fi

[ "$failed" = 0 ] && echo "all runtime checks passed" || echo "some runtime checks FAILED"
exit "$failed"
