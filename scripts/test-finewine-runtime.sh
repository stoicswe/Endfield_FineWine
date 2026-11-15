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
