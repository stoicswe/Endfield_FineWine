#!/usr/bin/env bash
# build-all.sh — build everything this repository ships, in order:
#
#   1. the x64 payload      (Wine modules + MoltenVK)          scripts/build-local.sh
#   2. the ARM payload      (ARM modules + arm64 MoltenVK)     scripts/build-local.sh
#   3. FineWine Patcher.app (bundles both payloads)            scripts/build-local.sh
#   4. FineWine.app         (the menu bar prefix manager)      finewine-app/scripts/build-app.sh
#
# Steps 1-3 are one run of build-local.sh, which skips any stage whose output is newer than its
# inputs. A failure stops the script; FineWine.app is only built once the patcher has built.
#
# Usage:  scripts/build-all.sh [all|x64|arm]
#   all  (default) both payloads, the patcher, then FineWine.app
#   x64  only the x64 payload in the patcher, then FineWine.app
#   arm  only the ARM payload rebuilt (x64 reused), then FineWine.app
# Env:
#   FORCE=1          rebuild everything (passed to build-local.sh)
#   ARM_MODE         source | stock | skip (passed to build-local.sh)
#   SKIP_PATCHER=1   build only FineWine.app
#   SKIP_FINEWINE=1  build only the patcher (same as running build-local.sh)
#   FINEWINE_VERSION sets FineWine.app's version; CODESIGN_ID, SKIP_TESTS and ICON_VARIANT are
#                    passed to its build-app.sh as they are
set -euo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"
TARGET="${1:-all}"

case "$TARGET" in
  all|x64|arm) ;;
  -h|--help) sed -n '2,22p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
  *) echo "usage: scripts/build-all.sh [all|x64|arm]" >&2; exit 2 ;;
esac

log(){ printf '\n\033[1m==> %s\033[0m\n' "$*"; }
started=$(date +%s)

if [ "${SKIP_PATCHER:-0}" != "1" ]; then
  log "FineWine Patcher.app ($TARGET)"
  "$REPO/scripts/build-local.sh" "$TARGET"
fi

if [ "${SKIP_FINEWINE:-0}" != "1" ]; then
  log "FineWine.app"
  # The patcher's build has its own VERSION; FineWine's is independent, so only an explicit
  # FINEWINE_VERSION reaches it.
  ( unset VERSION; [ -n "${FINEWINE_VERSION:-}" ] && export VERSION="$FINEWINE_VERSION"
    "$REPO/finewine-app/scripts/build-app.sh" )
fi

log "Built in $(( ($(date +%s) - started) / 60 )) min"
[ "${SKIP_PATCHER:-0}" = "1" ]  || echo "  $REPO/patcher-app/build/FineWine Patcher.app"
[ "${SKIP_FINEWINE:-0}" = "1" ] || echo "  $REPO/finewine-app/build/FineWine.app"
