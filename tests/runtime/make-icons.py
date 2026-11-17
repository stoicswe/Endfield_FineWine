#!/usr/bin/env python3
"""make-icons.py — writes the Windows icons tests/runtime/app-icon.c is built and run with.

  tile.ico   a square picture with nothing see-through (as game icons often are): 256, 48, 32, 16
  round.ico  a round shape on a transparent background (as most program icons are): 256, 48, 32, 16
  tiny.ico   a 32-pixel icon and nothing larger (as old programs have)

Each entry is a 32-bit DIB with its mask, which Windows and Wine read at every size.
Usage: make-icons.py <output folder>
"""
import struct
import sys
import os


def dib(size, pixel):
    """A 32-bit icon image: BITMAPINFOHEADER, BGRA rows bottom-up, then the AND mask."""
    header = struct.pack('<IiiHHIIiiII', 40, size, size * 2, 1, 32, 0, 0, 0, 0, 0, 0)
    rows = bytearray()
    for y in range(size - 1, -1, -1):
        for x in range(size):
            r, g, b, a = pixel(x / size, y / size)
            rows += bytes((b, g, r, a))
    mask_row = ((size + 31) // 32) * 4
    mask = bytes(mask_row * size)  # all zero: the alpha channel decides
    return header + bytes(rows) + mask


def ico(images):
    out = bytearray(struct.pack('<HHH', 0, 1, len(images)))
    offset = 6 + 16 * len(images)
    blobs = []
    for size, data in images:
        out += struct.pack('<BBBBHHII', size % 256, size % 256, 0, 0, 1, 32, len(data), offset)
        offset += len(data)
        blobs.append(data)
    for data in blobs:
        out += data
    return bytes(out)


def tile(x, y):
    # opaque all over: a diagonal blue-to-orange gradient
    return (int(40 + 200 * x), int(90 + 60 * y), int(220 - 180 * x), 255)


def round_shape(x, y):
    d = ((x - 0.5) ** 2 + (y - 0.5) ** 2) ** 0.5
    if d > 0.42:
        return (0, 0, 0, 0)
    return (200, 40, 60, 255) if d > 0.3 else (255, 210, 60, 255)


def main():
    folder = sys.argv[1]
    os.makedirs(folder, exist_ok=True)
    for name, pixel, sizes in (('tile', tile, (256, 48, 32, 16)),
                               ('round', round_shape, (256, 48, 32, 16)),
                               ('tiny', round_shape, (32,))):
        with open(os.path.join(folder, name + '.ico'), 'wb') as f:
            f.write(ico([(s, dib(s, pixel)) for s in sizes]))


if __name__ == '__main__':
    main()
