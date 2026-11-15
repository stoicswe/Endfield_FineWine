#!/usr/bin/env bash
# compile-rt-shaders.sh — compile the ray tracing pipeline test's shaders into one C header.
#
# Usage: scripts/lib/compile-rt-shaders.sh <shader folder> <output header>
# Each shader becomes `static const uint32_t <name>_<stage>[]`, e.g. scene.rgen -> scene_rgen.
# Needs glslangValidator (brew install glslang).
set -euo pipefail
DIR="$1"; OUT="$2"
: > "$OUT"
for f in "$DIR"/*.rgen "$DIR"/*.rmiss "$DIR"/*.rchit "$DIR"/*.rahit "$DIR"/*.rint "$DIR"/*.rcall; do
  [ -f "$f" ] || continue
  name="$(basename "$f" | tr '.' '_')"
  glslangValidator -V --target-env vulkan1.2 --vn "$name" -o "$OUT.part" "$f" >/dev/null
  # glslang's header has `const uint32_t name[]`; make it static so two programs can include it.
  sed 's/^const uint32_t/static const uint32_t/' "$OUT.part" >> "$OUT"
done
rm -f "$OUT.part"
