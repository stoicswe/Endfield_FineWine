#!/usr/bin/env bash
# test-moltenvk-raytracing.sh — run the ray tracing test natively against a MoltenVK build.
#
# Compiles the shaders in tests/moltenvk to SPIR-V and the test programs (raytracing.c:
# acceleration structures and ray queries; rtpipeline.c: ray tracing pipelines; metalfx.c:
# MetalFX upscaling and frame generation) as Mac programs, and runs them against libMoltenVK.dylib. No Wine involved, which makes it the quick way
# to check MoltenVK changes. Needs glslangValidator (brew install glslang).
#
# Usage:  scripts/test-moltenvk-raytracing.sh [path to libMoltenVK.dylib]
#         (default: build/moltenvk-out-finewine/libMoltenVK.dylib)
set -euo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"
DYLIB="${1:-$REPO/build/moltenvk-out-finewine/libMoltenVK.dylib}"
HEADERS="$REPO/build/vulkan-headers-finewine-src/include"
[ -d "$HEADERS" ] || HEADERS="$REPO/build/vulkan-headers-src/include"
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
[ -f "$DYLIB" ] || { echo "no MoltenVK at $DYLIB (MVK_FLAVOR=finewine scripts/build-moltenvk.sh all)"; exit 2; }
[ -d "$HEADERS" ] || { echo "no Vulkan headers at $HEADERS"; exit 2; }
command -v glslangValidator >/dev/null || { echo "glslangValidator not found (brew install glslang)"; exit 2; }

glslangValidator -V --target-env vulkan1.2 --vn rayquery_spv -o "$WORK/rayquery_spv.h" "$REPO/tests/moltenvk/rayquery.comp" >/dev/null
clang -arch arm64 -O1 -I"$HEADERS" -I"$WORK" -o "$WORK/raytracing" "$REPO/tests/moltenvk/raytracing.c"
MOLTENVK_DYLIB="$DYLIB" MVK_CONFIG_LOG_LEVEL="${MVK_CONFIG_LOG_LEVEL:-1}" "$WORK/raytracing"

# The ray tracing pipeline test: its shaders (tests/moltenvk/rt) go into one header, an array each.
"$REPO/scripts/lib/compile-rt-shaders.sh" "$REPO/tests/moltenvk/rt" "$WORK/rtpipeline_spv.h"
clang -arch arm64 -O1 -I"$HEADERS" -I"$WORK" -o "$WORK/rtpipeline" "$REPO/tests/moltenvk/rtpipeline.c"
MOLTENVK_DYLIB="$DYLIB" MVK_CONFIG_LOG_LEVEL="${MVK_CONFIG_LOG_LEVEL:-1}" "$WORK/rtpipeline"

# MetalFX through the command DLSS is mapped to, and the ids a prefix can ask to be reported
# (an NVIDIA GeForce RTX 5080 is vendor 10de, device 2c02).
clang -arch arm64 -O1 -I"$HEADERS" -o "$WORK/metalfx" "$REPO/tests/moltenvk/metalfx.c"
MOLTENVK_DYLIB="$DYLIB" MVK_CONFIG_LOG_LEVEL="${MVK_CONFIG_LOG_LEVEL:-1}" "$WORK/metalfx"
MOLTENVK_DYLIB="$DYLIB" MVK_CONFIG_LOG_LEVEL="${MVK_CONFIG_LOG_LEVEL:-1}" FINEWINE_GPU_VENDOR_ID=10de FINEWINE_GPU_DEVICE_ID=2c02 \
  EXPECT_GPU_VENDOR_ID=10de EXPECT_GPU_DEVICE_ID=2c02 "$WORK/metalfx" | grep -E '^gpu:|^metalfx:'
