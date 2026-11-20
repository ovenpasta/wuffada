# Part of wuffada (wuffs-ada: Wuffs to Ada).
# SPDX-License-Identifier: Apache-2.0 OR MIT
#
# Writes the JPEG files of this directory with Pillow (which uses the
# system's libjpeg), for ada/tests/imgcorpus: progressive images (Pillow's
# progressive script uses spectral selection and successive approximation,
# which the encoder in ada/tests/imgcorpus/jpeg.go does not do for AC
# coefficients), libjpeg's own restart markers, optimized Huffman tables,
# CMYK, RGB (keep_rgb), custom quantization tables and metadata. The files
# are checked in, so that the corpus does not depend on what is installed;
# this script is how they were made (Pillow 11.1.0, libjpeg 6.2 API):
#
#   python3 -I ada/tests/jpegcorpus/make.py ada/tests/jpegcorpus
#
# The pixels are a deterministic function of the position, so the output is
# the same on every run with the same Pillow and libjpeg.

import io
import math
import os
import sys

from PIL import Image


def picture(mode, w, h, seed):
    im = Image.new("RGB", (w, h))
    px = []
    for y in range(h):
        for x in range(w):
            fx, fy = x / (w + 1), y / (h + 1)
            r = 128 + 100 * math.sin(6 * fx + seed) + 20 * math.cos(13 * fx * fy)
            g = 128 + 90 * math.cos(5 * fy - seed + 4 * fx) + 25 * math.sin((x * y) % 11)
            b = 255 * fx * fy + 40 * math.sin((x + y) % 7)
            px.append(tuple(max(0, min(255, int(v))) for v in (r, g, b)))
    im.putdata(px)
    if mode == "RGB":
        return im
    if mode == "L":
        return im.convert("L")
    # CMYK: from the RGB picture, with some black.
    c = Image.new("CMYK", (w, h))
    cpx = []
    for i, (r, g, b) in enumerate(px):
        k = int(127 + 127 * math.sin(i / 9))
        cpx.append((255 - r, 255 - g, 255 - b, k))
    c.putdata(cpx)
    return c


def main(out):
    n = 0

    def save(name, im, **kw):
        nonlocal n
        b = io.BytesIO()
        im.save(b, "JPEG", **kw)
        with open(os.path.join(out, name + ".jpeg"), "wb") as f:
            f.write(b.getvalue())
        n += 1

    sizes = [(1, 1), (5, 3), (16, 16), (17, 9), (37, 23), (64, 64)]
    for i, (w, h) in enumerate(sizes):
        rgb = picture("RGB", w, h, i)
        for sub in (0, 1, 2):
            save("rgb-%dx%d-s%d" % (w, h, sub), rgb, subsampling=sub, quality=70 + 4 * i)
            save("rgb-%dx%d-s%d-prog" % (w, h, sub), rgb, subsampling=sub, progressive=True)
            if i % 2 == 0:
                save("rgb-%dx%d-s%d-prog-opt" % (w, h, sub), rgb, subsampling=sub, progressive=True,
                     optimize=True, quality=90)
        save("gray-%dx%d" % (w, h), picture("L", w, h, i))
        save("gray-%dx%d-prog" % (w, h), picture("L", w, h, i), progressive=True)
        save("cmyk-%dx%d" % (w, h), picture("CMYK", w, h, i))
        if i % 2 == 1:
            save("cmyk-%dx%d-prog" % (w, h), picture("CMYK", w, h, i), progressive=True)
        save("keeprgb-%dx%d" % (w, h), rgb, keep_rgb=True, subsampling=0)

    big = picture("RGB", 160, 120, 7)
    for sub in (0, 1, 2):
        for blocks in (1, 3, 50):
            save("rst-blocks%d-s%d" % (blocks, sub), big, subsampling=sub, restart_marker_blocks=blocks)
        save("rst-rows1-s%d" % sub, big, subsampling=sub, restart_marker_rows=1)
        save("rst-blocks2-s%d-prog" % sub, big, subsampling=sub, restart_marker_blocks=2, progressive=True)
    save("rst-rows2-gray-prog", picture("L", 90, 70, 3), restart_marker_rows=2, progressive=True)
    save("rst-blocks5-cmyk", picture("CMYK", 45, 33, 2), restart_marker_blocks=5)

    for q in (1, 5, 50, 95, 100):
        save("quality%d" % q, big, quality=q, subsampling=2)
        save("quality%d-prog" % q, big, quality=q, subsampling=1, progressive=True)
    save("qtables-flat", big, qtables=[[1] * 64, [2] * 64], subsampling=2)
    save("qtables-coarse", big, qtables=[[255] * 64, [128] * 64], subsampling=0, progressive=True)
    save("qtables-ramp", big, qtables=[list(range(1, 65)), list(range(64, 0, -1))], subsampling=1)

    for (w, h) in [(1000, 2), (2, 1000), (301, 5), (5, 301)]:
        save("odd-%dx%d" % (w, h), picture("RGB", w, h, 1), subsampling=2)
        save("odd-%dx%d-prog" % (w, h), picture("RGB", w, h, 1), subsampling=2, progressive=True)

    exif = b"Exif\x00\x00MM\x00\x2a\x00\x00\x00\x08" + bytes(60)
    icc = bytes(200)
    save("meta-exif-icc-comment", big, exif=exif, icc_profile=icc, comment=b"wuffada", subsampling=2)
    save("meta-exif-icc-comment-prog", big, exif=exif, icc_profile=icc, comment=b"x" * 300, progressive=True)
    print("make.py: %d files" % n)


if __name__ == "__main__":
    main(sys.argv[1])
