#!/usr/bin/env bash
# fetch-dwproton-patches.sh — pull the Endfield-relevant dw-proton Wine patches (STAGE 2).
#
# These patch Wine to satisfy ACE's *later* init stage (missing ntoskrnl exports, KiUser*Dispatcher
# tpshell detection, timing). They do NOT fix our macOS STAGE 1 blocker (the EndfieldBase.dll
# execute-fault loop) — see docs/11-linux-vs-macos-comparison.md. We stage them because any Wine
# rebuild for stage 1 will also want them, and stage 2 is next once stage 1 is cleared.
#
# Source: dawn-winery/dwproton-mirror at the fix commit b816be489 (GE issue #433). dawn.wine itself
# is behind an Anubis anti-bot wall; the GitHub mirror shares the same git objects.
#
# Usage: scripts/fetch-dwproton-patches.sh   (run from repo root; re-run to refresh)

set -uo pipefail
SHA="${DWPROTON_SHA:-b816be489049a10453b470c6a12dcf552ea41773}"
REPO="dawn-winery/dwproton-mirror"
BASE="https://raw.githubusercontent.com/${REPO}/${SHA}/patches/wine"
DEST="patches/stage2-dwproton"

mkdir -p "$DEST/misc" "$DEST/em-backports"
echo "Fetching dw-proton patches from ${REPO}@${SHA:0:12} ..."

# misc: int3 KiUser spoof (+gate), NtDelayExecution-via-QPC, wintrust (macOS-irrelevant, kept for completeness)
for p in \
  0002-misc/0008-wintrust-Prevent-checking-if-winex11-winewayland-are.patch \
  0002-misc/0009-HACK-kernel32-Spoof-GetProcAddress-of-KiUserApcDispa.patch \
  0002-misc/0010-HACK-kernel32-Lock-GetProcAddress-hack-to-when-neede.patch \
  0002-misc/0011-ntdll-Implement-NtDelayExecution-relative-wait-using.patch ; do
  curl -fsS "$BASE/$p" -o "$DEST/misc/$(basename "$p")" && echo "  ok  misc/$(basename "$p")" || echo "  FAIL $p"
done

# em-backports: all ntoskrnl.exe function implementations (0001-0017 at this commit)
curl -s "https://api.github.com/repos/${REPO}/git/trees/${SHA}?recursive=1" \
 | python3 -c "
import json,sys
for e in json.load(sys.stdin).get('tree',[]):
    p=e['path']
    if p.startswith('patches/wine/0003-em-backports/') and p.endswith('.patch'): print(p)
" | while IFS= read -r p; do
  curl -fsS "$BASE/${p#patches/wine/}" -o "$DEST/em-backports/$(basename "$p")" \
    && echo "  ok  em-backports/$(basename "$p")" || echo "  FAIL $p"
done

echo ""
echo "Done. misc=$(ls -1 "$DEST/misc" 2>/dev/null | wc -l | tr -d ' ')  em-backports=$(ls -1 "$DEST/em-backports" 2>/dev/null | wc -l | tr -d ' ')"
echo "NOTE: for the LATEST versions (this repo rebases), the patches now live baked into the fork"
echo "      dawn.wine/dawn-winery/wine-dwproton (branch 'base'); this fetch is the b816be489 snapshot."
