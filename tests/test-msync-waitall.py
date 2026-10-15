# SPDX-License-Identifier: LGPL-2.1-or-later
"""Run deterministic MSync WaitAll races against a patched Wine source tree.

Usage: python3 tests/test-msync-waitall.py build/wine-src
"""

import argparse
import subprocess
import sys
import tempfile
from pathlib import Path

FIXTURE = Path(__file__).parent / 'fixtures/msync-waitall.c'


def extract_wait_objs(wine_source):
    source = (wine_source / 'dlls/ntdll/unix/msync.c').read_text()
    start = source.index('NTSTATUS msync_wait_objs(')
    return source[start:source.index('\n#else', start)]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('wine_source', type=Path)
    args = parser.parse_args()

    code = FIXTURE.read_text().replace('/* @implementation */', extract_wait_objs(args.wine_source))
    with tempfile.TemporaryDirectory(prefix='msync-waitall-') as tmp:
        c_file, binary = Path(tmp) / 'msync.c', Path(tmp) / 'msync'
        c_file.write_text(code)
        subprocess.run(['clang', '-O2', '-fno-strict-aliasing', '-Wall', '-Wextra', '-Werror',
                        '-Wno-unused-function', '-Wno-sign-compare', c_file, '-o', binary],
                       check=True)
        return subprocess.run([binary]).returncode


if __name__ == '__main__':
    sys.exit(main())
