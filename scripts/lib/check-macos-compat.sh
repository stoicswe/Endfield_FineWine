#!/usr/bin/env bash
# check-macos-compat.sh — checks that built Mac binaries run on the oldest macOS they support.
#
#   scripts/lib/check-macos-compat.sh <oldest macOS, e.g. 26.0> <file or folder>...
#
# For each Mach-O file found:
#   - its minimum macOS (LC_BUILD_VERSION minos) must not be newer than the one given; a newer
#     one means the build was made without a deployment target, and dyld may refuse it or
#     every newer function becomes a hard dependency;
#   - every weak import from the system (libSystem) must be listed in macos-gated-apis.txt:
#     a weak system import is a function the oldest supported macOS lacks, and each must be
#     used behind a check (see that file).
# Exits 1 and names each problem when there is one.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
LIST="$HERE/macos-gated-apis.txt"
OLDEST="${1:?usage: check-macos-compat.sh <oldest macOS> <file or folder>...}"; shift
[ $# -gt 0 ] || { echo "usage: check-macos-compat.sh <oldest macOS> <file or folder>..." >&2; exit 2; }

allowed="$(grep -v '^[[:space:]]*#' "$LIST" | awk 'NF {print $1}')"
version_gt(){ [ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | tail -n 1)" = "$1" ] && [ "$1" != "$2" ]; }

problems=0 checked=0
while IFS= read -r -d '' f; do
  file -b "$f" 2>/dev/null | grep -q 'Mach-O' || continue
  checked=$((checked + 1))
  minos="$(otool -l "$f" 2>/dev/null | awk '/LC_BUILD_VERSION/{b=1} b&&/minos/{print $2; exit}')"
  if [ -n "$minos" ] && version_gt "$minos" "$OLDEST"; then
    echo "  ✗ $f: built for macOS $minos and later; must run on $OLDEST"
    problems=$((problems + 1))
  fi
  while read -r sym; do
    [ -n "$sym" ] || continue
    if ! printf '%s\n' "$allowed" | grep -qxF "$sym"; then
      echo "  ✗ $f: $sym is newer than macOS $OLDEST and not known to be gated (scripts/lib/macos-gated-apis.txt)"
      problems=$((problems + 1))
    fi
  done < <(nm -m "$f" 2>/dev/null | awk '/weak external/ && /from libSystem/ {print $(NF-2)}')
done < <(for p in "$@"; do if [ -d "$p" ]; then find "$p" -type f -print0; else printf '%s\0' "$p"; fi; done)

if [ "$problems" -gt 0 ]; then
  echo "macOS $OLDEST compatibility: $problems problem(s) in $checked Mach-O file(s)"
  exit 1
fi
echo "macOS $OLDEST compatibility: $checked Mach-O file(s) OK"
