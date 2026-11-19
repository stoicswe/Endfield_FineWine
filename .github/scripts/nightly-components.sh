#!/usr/bin/env bash
# nightly-components.sh — which of the two apps a set of changed files calls for building.
#
# Reads file paths (as `git diff --name-only` prints them) on standard input and prints
# "patcher=true|false" and "app=true|false":
#   patcher  FineWine Patcher.app and the patched Wine modules for CrossOver (build-wine.yml)
#   app      FineWine.app with its own Wine runtime (build-finewine-full.yml)
#
# A file that only one of them is built from calls for that one. Anything else under patches/
# or scripts/, and the workflows both builds share, calls for both: when in doubt, build.
# Documentation and files neither is built from call for nothing.
#
# With arguments, each is classified and printed ("<component> <path>"), for trying it out:
#   .github/scripts/nightly-components.sh patches/runtime/0001-x.patch scripts/package.sh
set -euo pipefail

classify() {
  case "$1" in
    # read by people, not by a build
    *.md|patches/README*|scripts/README*|docs/*|tests/*) echo none ;;

    # FineWine.app and its runtime
    finewine-app/*|runtime-extras/*|finewine-sources.lock) echo app ;;
    patches/runtime/*|patches/fex/*|patches/dxmt/*|patches/moltenvk/*) echo app ;;
    scripts/build-finewine*.sh|scripts/build-fex.sh|scripts/build-dxmt.sh) echo app ;;
    scripts/test-finewine-runtime.sh|scripts/bench-finewine-runtime.sh|scripts/test-moltenvk-raytracing.sh) echo app ;;
    scripts/lib/build-presence-helper.sh|scripts/lib/build-steam-helper.sh|scripts/lib/make-game-loader.sh) echo app ;;
    scripts/lib/compile-rt-shaders.sh|scripts/lib/fex-pkg_resources.py) echo app ;;
    .github/workflows/build-finewine*.yml) echo app ;;

    # FineWine Patcher.app and the modules it installs into CrossOver
    patcher-app/*) echo patcher ;;
    patches/x64/stage1-macos/*|patches/x64/stage2-dwproton/*) echo patcher ;;
    scripts/build-wine.sh|scripts/build-wine-arm.sh|scripts/package.sh|scripts/build-all.sh|scripts/build-local.sh) echo patcher ;;
    scripts/swap-into-crossover.sh|scripts/apply-modules.sh|scripts/lib/menu-helper.sh) echo patcher ;;
    scripts/create-bottle.sh|scripts/launch-endfield.sh|scripts/diagnose-vulkan.sh|scripts/notproton-register.sh) echo patcher ;;
    scripts/01-capture-failure.sh|scripts/fetch-dwproton-patches.sh) echo patcher ;;
    .github/workflows/build-wine.yml|.github/workflows/build.yml) echo patcher ;;

    # Both are built from these: the ARM patch series (the patcher's ARM payload and the
    # app's runtime), the shared MoltenVK patches and its build script, shared helpers, and
    # the nightly itself. Anything new under patches/ or scripts/ lands here until it is listed.
    patches/*|scripts/*) echo both ;;
    .github/workflows/nightly.yml|.github/scripts/nightly-components.sh) echo both ;;

    *) echo none ;;
  esac
}

if [ "$#" -gt 0 ]; then
  for path in "$@"; do printf '%s %s\n' "$(classify "$path")" "$path"; done
  exit 0
fi

patcher=false
app=false
while IFS= read -r path; do
  [ -n "$path" ] || continue
  case "$(classify "$path")" in
    app) app=true ;;
    patcher) patcher=true ;;
    both) app=true; patcher=true ;;
  esac
done
echo "patcher=$patcher"
echo "app=$app"
