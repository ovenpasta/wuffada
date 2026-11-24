# Part of wuffada (wuffs-ada: Wuffs to Ada).
# SPDX-License-Identifier: Apache-2.0 OR MIT

# Benchmark inputs that wuffs/test/data has only as tiny files: an Adam7
# interlaced 8-bit RGB PNG and a 16-bit RGB PNG, both made from the pixels of
# a large PNG (read with PIL).  Each row's filter is chosen with libpng's
# heuristic (smallest sum of absolute signed bytes), so all five filters
# occur.
#
# usage: python3 mkpng.py SOURCE.png INTERLACED.png SIXTEEN_BIT.png

import struct
import sys
import zlib

from PIL import Image


def chunk(kind, data):
    c = struct.pack(">I", len(data)) + kind + data
    return c + struct.pack(">I", zlib.crc32(kind + data) & 0xFFFFFFFF)


def paeth(a, b, c):
    p = a + b - c
    pa, pb, pc = abs(p - a), abs(p - b), abs(p - c)
    if pa <= pb and pa <= pc:
        return a
    return b if pb <= pc else c


def filter_rows(rows, bpp):
    out = bytearray()
    prev = bytes(len(rows[0])) if rows else b""
    for row in rows:
        n = len(row)
        cands = []
        cands.append(bytes(row))
        cands.append(bytes((row[i] - (row[i - bpp] if i >= bpp else 0)) & 255 for i in range(n)))
        cands.append(bytes((row[i] - prev[i]) & 255 for i in range(n)))
        cands.append(bytes((row[i] - (((row[i - bpp] if i >= bpp else 0) + prev[i]) >> 1)) & 255
                           for i in range(n)))
        cands.append(bytes((row[i] - paeth(row[i - bpp] if i >= bpp else 0, prev[i],
                                           prev[i - bpp] if i >= bpp else 0)) & 255
                           for i in range(n)))
        best = min(range(5), key=lambda f: sum(b if b < 128 else 256 - b for b in cands[f]))
        out.append(best)
        out += cands[best]
        prev = row
    return out


def write_png(path, w, h, depth, interlace, data):
    ihdr = struct.pack(">IIBBBBB", w, h, depth, 2, 0, 0, interlace)
    with open(path, "wb") as f:
        f.write(b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", ihdr) +
                chunk(b"IDAT", zlib.compress(bytes(data), 6)) + chunk(b"IEND", b""))


def main():
    src, interlaced, sixteen = sys.argv[1:4]
    img = Image.open(src).convert("RGB")
    w, h = img.size
    px = img.tobytes()
    stride = 3 * w

    # Adam7: (x0, y0, dx, dy) per pass.
    passes = [(0, 0, 8, 8), (4, 0, 8, 8), (0, 4, 4, 8), (2, 0, 4, 4), (0, 2, 2, 4), (1, 0, 2, 2),
              (0, 1, 1, 2)]
    data = bytearray()
    for x0, y0, dx, dy in passes:
        rows = []
        for y in range(y0, h, dy):
            row = bytearray()
            for x in range(x0, w, dx):
                row += px[y * stride + 3 * x:y * stride + 3 * x + 3]
            if row:
                rows.append(row)
        if rows:
            data += filter_rows(rows, 3)
    write_png(interlaced, w, h, 8, 1, data)

    # 16 bits per sample: each 8-bit value v becomes v * 257.
    rows = []
    for y in range(h):
        row = bytearray()
        for v in px[y * stride:(y + 1) * stride]:
            row += bytes((v, v))
        rows.append(row)
    write_png(sixteen, w, h, 16, 0, filter_rows(rows, 6))


main()
