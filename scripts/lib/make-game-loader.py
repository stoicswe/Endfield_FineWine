#!/usr/bin/env python3
"""make-game-loader.py — make the copy of Wine's loader that macOS treats as a game.

Usage: make-game-loader.py <loader> <output>

macOS turns Game Mode on for a full-screen app whose Info.plist says it is a game. Wine's
loader carries its Info.plist inside the binary. The runtime's loader says it is a utility
that does not support Game Mode; this writes a copy that says it is a game that does, by
changing three values in place. The values were written (patches/runtime) so that each change
keeps its length, which keeps every offset in the binary where it was. The caller signs the
result.
"""
import sys

CHANGES = [
    (b"<string>public.app-category.utilities</string>", b"<string>public.app-category.games</string>    "),
    (b"<key>GCSupportsGameMode</key>\n    <false/>", b"<key>GCSupportsGameMode</key>\n    <true/> "),
    (b"<key>LSSupportsGameMode</key>\n    <false/>", b"<key>LSSupportsGameMode</key>\n    <true/> "),
]

def main():
    if len(sys.argv) != 3:
        sys.exit(__doc__)
    data = open(sys.argv[1], "rb").read()
    for old, new in CHANGES:
        assert len(old) == len(new)
        if data.count(old) != 1:
            sys.exit("make-game-loader: %r is not in the loader exactly once; was it built from this tree?" % old[:40])
        data = data.replace(old, new)
    open(sys.argv[2], "wb").write(data)

if __name__ == "__main__":
    main()
