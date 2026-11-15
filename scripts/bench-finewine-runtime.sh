#!/usr/bin/env bash
# bench-finewine-runtime.sh — measure where the time goes in a FineWine runtime.
#
# Builds tests/runtime/bench.c four ways and tests/runtime/bench-d3d11.c and bench-d3d12.c two
# ways, runs them, and prints one table: the same work natively on the Mac, under Rosetta, as
# a Windows ARM64 program under Wine, and as a Windows x64 program under Wine and FEX. Reading
# across a row gives the cost of each layer. Times are milliseconds; lower is better. Runs
# take a few minutes; nothing is shown on screen.
#
# Usage:  scripts/bench-finewine-runtime.sh [runtime folder]   (default: build/finewine-runtime)
# Env:    WINEMSYNC=0 measures without MSync (the default here is with, as FineWine's is).
# Needs the Wine source and build trees in build/ and llvm-mingw (scripts/build-fex.sh toolchain).
set -uo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"
RT="${1:-$REPO/build/finewine-runtime}"
SRC="$REPO/build/finewine-runtime-src"; OBJ="$REPO/build/finewine-runtime-build"
MINGW="$REPO/build/llvm-mingw/bin/x86_64-w64-mingw32-clang"
WORK="$(mktemp -d)"
trap 'WINEPREFIX="$WORK/pfx" "$RT/bin/wineserver" -k 2>/dev/null; rm -rf "$WORK"' EXIT
BREW="$(command -v brew || echo /opt/homebrew/bin/brew)"
export PATH="$("$BREW" --prefix llvm)/bin:$("$BREW" --prefix lld)/bin:$PATH"
export WINEDEBUG=-all WINEDLLOVERRIDES="winedbg.exe=d;winemenubuilder.exe=d;mscoree=d;mshtml=d" WINEPREFIX="$WORK/pfx"
if [ "${WINEMSYNC:-1}" = 0 ]; then unset WINEMSYNC; SYNC="off"; else export WINEMSYNC=1; SYNC="on"; fi
[ -x "$RT/bin/wine" ] || { echo "no runtime at $RT"; exit 2; }
[ -x "$MINGW" ] || { echo "no llvm-mingw in build/ (scripts/build-fex.sh toolchain)"; exit 2; }

arm64(){ # output source [libs...]
  local out="$1" src="$2"; shift 2
  "$RT/bin/winegcc" -b aarch64-windows -O2 -I"$SRC/include" -I"$SRC/include/msvcrt" -I"$OBJ/include" \
    -L"$RT/lib/wine/aarch64-windows" -mconsole -o "$out" "$src" "$@" >>"$WORK/build.log" 2>&1
}
T="$REPO/tests/runtime"
clang -O2 -arch arm64 -o "$WORK/native" "$T/bench.c" && clang -O2 -arch x86_64 -o "$WORK/rosetta" "$T/bench.c" \
  && arm64 "$WORK/arm64.exe" "$T/bench.c" && "$MINGW" -O2 -o "$WORK/x64.exe" "$T/bench.c" \
  && arm64 "$WORK/d3d11-arm64.exe" "$T/bench-d3d11.c" -ld3d11 -ld3dcompiler -ldxguid -luuid \
  && "$MINGW" -O2 -o "$WORK/d3d11-x64.exe" "$T/bench-d3d11.c" -ld3d11 -ld3dcompiler_47 -ldxguid -luuid \
  && arm64 "$WORK/d3d12-arm64.exe" "$T/bench-d3d12.c" -ld3d12 -ld3dcompiler -ldxguid -luuid \
  && "$MINGW" -O2 -o "$WORK/d3d12-x64.exe" "$T/bench-d3d12.c" -ld3d12 -ld3dcompiler_47 -ldxguid -luuid \
  || { echo "could not build the benchmarks"; tail -n 5 "$WORK/build.log"; exit 1; }

"$RT/bin/wine" wineboot --init </dev/null >/dev/null 2>&1
echo "runtime: $RT ($("$RT/bin/wine" --version)), MSync $SYNC"
"$WORK/native" > "$WORK/native.txt"
arch -x86_64 "$WORK/rosetta" > "$WORK/rosetta.txt" 2>/dev/null || : > "$WORK/rosetta.txt"
"$RT/bin/wine" "$WORK/arm64.exe" </dev/null 2>/dev/null | tr -d '\r' > "$WORK/arm64.txt"
"$RT/bin/wine" "$WORK/x64.exe" </dev/null 2>/dev/null | tr -d '\r' > "$WORK/x64.txt"
if [ -f "$RT/lib/dxmt/aarch64-windows/d3d11.dll" ]; then
  WINEDLLPATH="$RT/lib/dxmt" "$RT/bin/wine" "$WORK/d3d11-arm64.exe" </dev/null 2>/dev/null | tr -d '\r' >> "$WORK/arm64.txt"
  WINEDLLPATH="$RT/lib/dxmt" "$RT/bin/wine" "$WORK/d3d11-x64.exe" </dev/null 2>/dev/null | tr -d '\r' >> "$WORK/x64.txt"
fi
"$RT/bin/wine" "$WORK/d3d12-arm64.exe" </dev/null 2>/dev/null | tr -d '\r' >> "$WORK/arm64.txt"
"$RT/bin/wine" "$WORK/d3d12-x64.exe" </dev/null 2>/dev/null | tr -d '\r' >> "$WORK/x64.txt"

python3 - "$WORK" <<'PY'
import re, sys
work = sys.argv[1]
cols = [("native", "native"), ("rosetta", "Rosetta"), ("arm64", "Wine ARM64"), ("x64", "Wine+FEX")]
data, order = {}, []
for key, _ in cols:
    for line in open("%s/%s.txt" % (work, key)):
        m = re.match(r"(.+?)\s+([\d.]+) ms", line)
        if not m:
            if line.strip(): print("  %s: %s" % (key, line.strip()))
            continue
        name = m.group(1).strip()
        if name not in data: data[name] = {}; order.append(name)
        data[name][key] = float(m.group(2))
print("%-36s" % "milliseconds" + "".join("%12s" % title for _, title in cols))
for name in order:
    print("%-36s" % name + "".join("%12s" % (("%.1f" if data[name][k] < 20 else "%.0f") % data[name][k] if k in data[name] else "-") for k, _ in cols))
PY
