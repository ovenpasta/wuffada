# Part of wuffada (wuffs-ada: Wuffs to Ada).
# SPDX-License-Identifier: Apache-2.0 OR MIT
#
# Writes the WebP files of this directory, for ada/tests/imgcorpus. The files
# are checked in, so that the corpus does not depend on what is installed;
# this script is how they were made:
#
#   python3 -I ada/tests/webpcorpus/make.py ada/tests/webpcorpus
#
# It needs a C compiler and libwebp's headers and library (it was run with
# libwebp 1.5.0), and writes three kinds of files:
#
#  * lossy-*, lossless-*, alpha-*: encoded by libwebp's advanced API
#    (webpenc.c in this directory, compiled on the fly), which exposes what
#    cwebp would: quality, method, the loop filter's type, strength and
#    sharpness, segments, token partitions, alpha compression, filtering and
#    quality, lossless effort.
#  * vp8l-*: VP8L bitstreams written by the encoder in this file, which
#    chooses every feature explicitly: each transform (predictor with every
#    mode and tile size, cross colour, subtract green, colour indexing with
#    1 to 256 colours, so 8, 4, 2 and 1 pixels per byte), colour caches of
#    every size or none, one or many Huffman groups (an entropy image),
#    simple and normal Huffman codes (with and without a maximum symbol,
#    every repeat code, single-symbol codes), back-references at every kind
#    of distance (the 120 plane codes and plain distances). The pixels are
#    arbitrary, not the image of anything: any valid bitstream will do for a
#    comparison of decoders.
#  * container-*: RIFF containers assembled here around such payloads:
#    VP8X with ICCP, EXIF and XMP chunks, unknown chunks, ALPH chunks with
#    every filter and both compression methods (the VP8L one written here),
#    odd chunk lengths with padding, animations (ANIM and ANMF), and
#    deliberately invalid layouts (wrong order, missing VP8X flags, ALPH
#    with VP8L, bad sizes) for the decoders' error paths.
#
# Everything is a deterministic function of the code below (and of the
# libwebp version, for the first kind).

import os
import struct
import subprocess
import sys
import tempfile


# ---- Deterministic random numbers.

class Rng:
    def __init__(self, seed):
        self.s = (seed * 2654435761 + 12345) & 0xFFFFFFFF

    def next(self):
        self.s = (self.s * 1664525 + 1013904223) & 0xFFFFFFFF
        return self.s >> 8

    def below(self, n):
        return self.next() % n

    def chance(self, num, den):
        return self.below(den) < num


# ---- Pictures (RGBA, row by row).

def picture(w, h, seed, kind="smooth", alpha="opaque"):
    r = Rng(seed)
    px = bytearray()
    for y in range(h):
        for x in range(w):
            if kind == "smooth":
                cr = (x * 255 // max(1, w - 1) + seed * 17) & 0xFF
                cg = (y * 255 // max(1, h - 1) + seed * 31) & 0xFF
                cb = ((x + y) * 4 + (x * y) // 7) & 0xFF
            elif kind == "noise":
                cr, cg, cb = r.below(256), r.below(256), r.below(256)
            elif kind == "edges":
                v = 230 if ((x // 5) + (y // 3)) % 2 else 20
                cr, cg, cb = v, 255 - v, (x * 9) & 0xFF
            else:  # "mixed": smooth with noise and blocks
                cr = (x * 3 + (r.below(40) if (x // 8 + y // 8) % 3 == 0 else 0)) & 0xFF
                cg = (y * 5 + (x // 4) * 9) & 0xFF
                cb = (128 + ((x - w // 2) * (y - h // 2)) // 3) & 0xFF
            if alpha == "opaque":
                a = 255
            elif alpha == "gradient":
                a = (x * 255 // max(1, w - 1)) & 0xFF
            elif alpha == "binary":
                a = 255 if (x + 2 * y) % 5 else 0
            elif alpha == "noise":
                a = r.below(256)
            else:  # "holes": mostly opaque, some transparent
                a = 0 if (x * x + y * y) % 11 == 0 else 255
            px += bytes((cr, cg, cb, a))
    return bytes(px)


def palette_picture(w, h, ncolors, seed, alpha=False):
    r = Rng(seed)
    pal = []
    for i in range(ncolors):
        pal.append((r.below(256), r.below(256), r.below(256), r.below(256) if alpha else 255))
    px = bytearray()
    for y in range(h):
        for x in range(w):
            i = ((x // 3) * 7 + (y // 2) * 3 + r.below(2)) % ncolors
            px += bytes(pal[i])
    return bytes(px)


# ---- libwebp, through webpenc.c.

HERE = os.path.dirname(os.path.abspath(__file__))
TMP = tempfile.mkdtemp()
ENC = os.path.join(TMP, "webpenc")


def build_encoder():
    subprocess.check_call(["cc", "-O2", "-o", ENC, os.path.join(HERE, "webpenc.c"), "-lwebp"])


def libwebp(w, h, rgba, **opts):
    src = os.path.join(TMP, "in.rgba")
    dst = os.path.join(TMP, "out.webp")
    with open(src, "wb") as f:
        f.write(rgba)
    args = [ENC, str(w), str(h), src, dst] + ["%s=%s" % (k, v) for k, v in sorted(opts.items())]
    subprocess.check_call(args)
    with open(dst, "rb") as f:
        return f.read()


# ---- RIFF.

def chunk(fourcc, data, pad=True):
    b = fourcc + struct.pack("<I", len(data)) + data
    if pad and len(data) % 2:
        b += b"\x00"
    return b


def riff(body, size=None):
    if size is None:
        size = 4 + len(body)
    return b"RIFF" + struct.pack("<I", size) + b"WEBP" + body


def chunks_of(webp):
    """The (fourcc, payload) chunks of a RIFF WebP file."""
    out = []
    i = 12
    while i + 8 <= len(webp):
        fourcc = webp[i:i + 4]
        n = struct.unpack("<I", webp[i + 4:i + 8])[0]
        out.append((fourcc, webp[i + 8:i + 8 + n]))
        i += 8 + n + (n & 1)
    return out


def vp8x(flags, w, h):
    return chunk(b"VP8X", struct.pack("<I", flags) + struct.pack("<I", w - 1)[:3] + struct.pack("<I", h - 1)[:3])


ICC_FLAG, ALPHA_FLAG, EXIF_FLAG, XMP_FLAG, ANIM_FLAG = 0x20, 0x10, 0x08, 0x04, 0x02


# ---- A VP8L encoder.

class Bits:
    def __init__(self):
        self.out = bytearray()
        self.acc = 0
        self.n = 0

    def put(self, v, n):
        assert 0 <= v < (1 << n) or n == 0
        self.acc |= v << self.n
        self.n += n
        while self.n >= 8:
            self.out.append(self.acc & 0xFF)
            self.acc >>= 8
            self.n -= 8

    def bytes(self):
        b = bytearray(self.out)
        if self.n:
            b.append(self.acc & 0xFF)
        return bytes(b)


def huffman_lengths(freq, limit):
    """Code lengths (a dict symbol -> length) for the symbols with non-zero
    frequency, at most limit bits long, of a complete code."""
    syms = [s for s in sorted(freq) if freq[s] > 0]
    if len(syms) == 1:
        return {syms[0]: 1}
    f = {s: freq[s] for s in syms}
    while True:
        # Plain Huffman, by repeated merging (ties broken by symbol order).
        nodes = [(f[s], i, [s]) for i, s in enumerate(syms)]
        depth = {s: 0 for s in syms}
        uid = len(nodes)
        while len(nodes) > 1:
            nodes.sort()
            a, b = nodes[0], nodes[1]
            for s in a[2] + b[2]:
                depth[s] += 1
            nodes = nodes[2:] + [(a[0] + b[0], uid, a[2] + b[2])]
            uid += 1
        if max(depth.values()) <= limit:
            return depth
        f = {s: (f[s] + 1) // 2 for s in syms}


def canonical(lengths):
    """Canonical codes (deflate's rule): symbol -> (code, length)."""
    maxlen = max(lengths.values())
    count = [0] * (maxlen + 2)
    for l in lengths.values():
        count[l] += 1
    nxt = [0] * (maxlen + 2)
    code = 0
    for l in range(1, maxlen + 1):
        code = (code + count[l - 1]) << 1
        nxt[l] = code
    out = {}
    for s in sorted(lengths):
        l = lengths[s]
        out[s] = (nxt[l], l)
        nxt[l] += 1
    return out


def put_code(bw, code):
    c, l = code
    for i in range(l - 1, -1, -1):
        bw.put((c >> i) & 1, 1)


class Code:
    """A prefix code as written to the bitstream."""

    def __init__(self, codes):
        self.codes = codes  # symbol -> (code, length); empty means 0 bits.

    def put(self, bw, sym):
        if len(self.codes) == 1:
            assert sym in self.codes
            return  # A single symbol takes no bits.
        put_code(bw, self.codes[sym])


REVERSED = [False]

CL_ORDER = [17, 18, 0, 1, 2, 3, 4, 5, 16, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15]


def write_code(bw, nsyms, freq, rng, style="auto"):
    """Writes a prefix code for an alphabet of nsyms symbols in which the
    symbols of freq (with non-zero counts) occur, and returns it."""
    used = sorted(s for s in freq if freq[s] > 0)
    if not used:
        used, freq = [0], {0: 1}
    if style == "simple-only":
        style = "simple" if len(used) <= 2 and max(used) < 256 else "normal"
    if style == "auto":
        if len(used) <= 2 and max(used) < 256 and rng.chance(2, 3):
            style = "simple"
        else:
            style = "normal"
    if style == "simple":
        assert len(used) <= 2 and max(used) < 256
        # Two symbols in increasing order. (In decreasing order, decoders
        # disagree: libwebp gives the smaller symbol the code 0, as the
        # canonical code of two symbols of length 1, while Wuffs and Go give
        # it to the first one. Only vp8l-simple-reversed does that, on
        # purpose: REVERSED.)
        bw.put(1, 1)
        bw.put(len(used) - 1, 1)
        first = used[-1] if REVERSED[0] else used[0]
        if first < 2 and rng.chance(1, 2):
            bw.put(0, 1)
            bw.put(first, 1)
        else:
            bw.put(1, 1)
            bw.put(first, 8)
        if len(used) == 1:
            return Code({used[0]: (0, 0)})
        second = used[0] if first == used[1] else used[1]
        bw.put(second, 8)
        return Code({first: (0, 1), second: (1, 1)})

    lengths = huffman_lengths({s: freq[s] for s in used}, 15)
    full = [lengths.get(s, 0) for s in range(nsyms)]
    # Run-length tokens: (symbol, extra bits value, extra bits count).
    toks = []
    i = 0
    prev = 8
    while i < nsyms:
        l = full[i]
        run = 1
        while i + run < nsyms and full[i + run] == l:
            run += 1
        if l == 0 and run >= 3 and rng.chance(4, 5):
            n = min(run, 138)
            if n >= 11:
                toks.append((18, n - 11, 7))
            else:
                toks.append((17, n - 3, 3))
            i += n
            continue
        if l != 0 and l == prev and run >= 3 and rng.chance(4, 5):
            n = min(run, 6)
            toks.append((16, n - 3, 2))
            i += n
            continue
        toks.append((l, 0, 0))
        if l != 0:
            prev = l
        i += 1
    # A maximum symbol count, if the trailing tokens are all zeros.
    count = len(toks)
    while count > 0 and toks[count - 1][0] in (0, 17, 18):
        count -= 1
    use_max = count >= 2 and count < len(toks) and rng.chance(2, 3)
    if use_max:
        toks = toks[:count]
    clfreq = {}
    for t in toks:
        clfreq[t[0]] = clfreq.get(t[0], 0) + 1
    cllen = huffman_lengths(clfreq, 7)
    clcodes = Code(canonical(cllen))
    n_cl = 19
    while n_cl > 4 and cllen.get(CL_ORDER[n_cl - 1], 0) == 0:
        n_cl -= 1
    bw.put(0, 1)
    bw.put(n_cl - 4, 4)
    for k in range(n_cl):
        bw.put(cllen.get(CL_ORDER[k], 0), 3)
    if use_max:
        bw.put(1, 1)
        v = count - 2
        k = 0
        while v >= (1 << (2 + 2 * k)):
            k += 1
        bw.put(k, 3)
        bw.put(v, 2 + 2 * k)
    else:
        bw.put(0, 1)
    for sym, extra, nbits in toks:
        clcodes.put(bw, sym)
        if nbits:
            bw.put(extra, nbits)
    return Code(canonical(lengths))


DISTANCE_MAP = [
    0x18, 0x07, 0x17, 0x19, 0x28, 0x06, 0x27, 0x29, 0x16, 0x1A,
    0x26, 0x2A, 0x38, 0x05, 0x37, 0x39, 0x15, 0x1B, 0x36, 0x3A,
    0x25, 0x2B, 0x48, 0x04, 0x47, 0x49, 0x14, 0x1C, 0x35, 0x3B,
    0x46, 0x4A, 0x24, 0x2C, 0x58, 0x45, 0x4B, 0x34, 0x3C, 0x03,
    0x57, 0x59, 0x13, 0x1D, 0x56, 0x5A, 0x23, 0x2D, 0x44, 0x4C,
    0x55, 0x5B, 0x33, 0x3D, 0x68, 0x02, 0x67, 0x69, 0x12, 0x1E,
    0x66, 0x6A, 0x22, 0x2E, 0x54, 0x5C, 0x43, 0x4D, 0x65, 0x6B,
    0x32, 0x3E, 0x78, 0x01, 0x77, 0x79, 0x53, 0x5D, 0x11, 0x1F,
    0x64, 0x6C, 0x42, 0x4E, 0x76, 0x7A, 0x21, 0x2F, 0x75, 0x7B,
    0x31, 0x3F, 0x63, 0x6D, 0x52, 0x5E, 0x00, 0x74, 0x7C, 0x41,
    0x4F, 0x10, 0x20, 0x62, 0x6E, 0x30, 0x73, 0x7D, 0x51, 0x5F,
    0x40, 0x72, 0x7E, 0x61, 0x6F, 0x50, 0x71, 0x7F, 0x60, 0x70,
]


def plane_distance(code, w):
    v = DISTANCE_MAP[code - 1]
    d = (v >> 4) * w + 8 - (v & 15)
    return d if d >= 1 else 1


def prefix_encode(v):
    """VP8L's prefix coding of v >= 1: (prefix symbol, extra value, extra bits)."""
    d = v - 1
    if d < 4:
        return d, 0, 0
    hb = d.bit_length() - 1
    second = (d >> (hb - 1)) & 1
    nbits = hb - 1
    return 2 * hb + second, d & ((1 << nbits) - 1), nbits


def cache_key(argb, bits):
    return ((argb * 0x1E35A7BD) & 0xFFFFFFFF) >> (32 - bits)


# CLAMPED: for a distance of 1, use a plane code whose distance is below 1
# (on an image narrower than 8 pixels), which RFC 9649 (and libwebp, and Go)
# take as 1. Only vp8l-narrow-clamped does that, on purpose.
CLAMPED = [False]


def raw_plane_distance(code, w):
    v = DISTANCE_MAP[code - 1]
    return (v >> 4) * w + 8 - (v & 15)


def tokenize(px, w, h, cache_bits, group_of, rng, backrefs, plane_codes=True):
    n = len(px)
    cache = [0] * (1 << cache_bits) if cache_bits else None
    toks = []
    pos = 0
    while pos < n:
        g = group_of(pos % w, pos // w)
        best = None
        if backrefs and pos > 0 and rng.chance(backrefs, 10):
            cands = set()
            if plane_codes:
                for c in range(1, 121):
                    cands.add(plane_distance(c, w))
            for _ in range(6):
                cands.add(1 + rng.below(pos))
            for d in sorted(cands):
                if d > pos:
                    continue
                L = 0
                while pos + L < n and L < 4096 and px[pos + L] == px[pos + L - d]:
                    L += 1
                if L >= 1 and (best is None or L > best[0]):
                    best = (L, d)
        if best is not None and (best[0] >= 2 or rng.chance(1, 4)):
            L, d = best
            if rng.chance(1, 3) and L > 1:
                L = 1 + rng.below(L)
            code = None
            if plane_codes:
                for c in range(1, 121):
                    if plane_distance(c, w) == d:
                        code = c
                        break
            if CLAMPED[0] and d == 1:
                for c in range(1, 121):
                    if raw_plane_distance(c, w) < 1:
                        code = c
                        break
            elif code is None or rng.chance(1, 5):
                code = d + 120
            toks.append(("ref", g, L, code))
            if cache is not None:
                for k in range(L):
                    q = px[pos + k]
                    cache[cache_key(q, cache_bits)] = q
            pos += L
            continue
        p = px[pos]
        if cache is not None and cache[cache_key(p, cache_bits)] == p and rng.chance(3, 4):
            toks.append(("cache", g, cache_key(p, cache_bits)))
        else:
            toks.append(("lit", g, p))
        if cache is not None:
            cache[cache_key(p, cache_bits)] = p
        pos += 1
    return toks


def write_tokens(bw, w, h, cache_bits, ngroups, toks, rng, style="auto"):
    nsym_green = 280 + ((1 << cache_bits) if cache_bits else 0)
    freqs = [[{} for _ in range(5)] for _ in range(ngroups)]

    def inc(g, t, s):
        freqs[g][t][s] = freqs[g][t].get(s, 0) + 1

    for t in toks:
        g = t[1]
        if t[0] == "lit":
            p = t[2]
            inc(g, 0, (p >> 8) & 0xFF)
            inc(g, 1, (p >> 16) & 0xFF)
            inc(g, 2, p & 0xFF)
            inc(g, 3, (p >> 24) & 0xFF)
        elif t[0] == "cache":
            inc(g, 0, 280 + t[2])
        else:
            inc(g, 0, 256 + prefix_encode(t[2])[0])
            inc(g, 4, prefix_encode(t[3])[0])
    codes = []
    for g in range(ngroups):
        cs = []
        for k, nsyms in enumerate([nsym_green, 256, 256, 256, 40]):
            cs.append(write_code(bw, nsyms, freqs[g][k], rng, style))
        codes.append(cs)
    for t in toks:
        cs = codes[t[1]]
        if t[0] == "lit":
            p = t[2]
            cs[0].put(bw, (p >> 8) & 0xFF)
            cs[1].put(bw, (p >> 16) & 0xFF)
            cs[2].put(bw, p & 0xFF)
            cs[3].put(bw, (p >> 24) & 0xFF)
        elif t[0] == "cache":
            cs[0].put(bw, 280 + t[2])
        else:
            sym, extra, nbits = prefix_encode(t[2])
            cs[0].put(bw, 256 + sym)
            bw.put(extra, nbits)
            sym, extra, nbits = prefix_encode(t[3])
            cs[4].put(bw, sym)
            bw.put(extra, nbits)


def sub_image(bw, px, w, h, rng, cache_bits=0, backrefs=3, style="auto"):
    """An entropy-coded image without transforms or meta codes."""
    if cache_bits:
        bw.put(1, 1)
        bw.put(cache_bits, 4)
    else:
        bw.put(0, 1)
    toks = tokenize(px, w, h, cache_bits, lambda x, y: 0, rng, backrefs)
    write_tokens(bw, w, h, cache_bits, 1, toks, rng, style)


def ceil_shift(v, b):
    return (v + (1 << b) - 1) >> b


def vp8l_stream(bw, w, h, rng, transforms=(), cache_bits=0, meta_bits=0, ngroups=1,
                backrefs=3, data="noise", style="auto", subcache=0, group_pattern="random"):
    """A level-0 VP8L image stream (what follows the 5-byte header, or an
    ALPH chunk's VP8L payload). transforms is a list of (type, param):
    (0, size_bits) predictor, (1, size_bits) cross colour, (2, None)
    subtract green, (3, ncolors) colour indexing."""
    xs = w
    ncolors = 0
    for typ, param in transforms:
        bw.put(1, 1)
        bw.put(typ, 2)
        if typ in (0, 1):
            bw.put(param - 2, 3)
            tw, th = ceil_shift(xs, param), ceil_shift(h, param)
            tpx = []
            for i in range(tw * th):
                if typ == 0:
                    mode = rng.below(14)
                    tpx.append((rng.below(256) << 24) | (rng.below(256) << 16) | (mode << 8) | rng.below(256))
                else:
                    tpx.append(rng.next() & 0xFFFFFFFF)
            sub_image(bw, tpx, tw, th, rng, subcache)
        elif typ == 3:
            ncolors = param
            bw.put(ncolors - 1, 8)
            pal = [rng.next() & 0xFFFFFFFF for _ in range(ncolors)]
            sub_image(bw, pal, ncolors, 1, rng, 0, 1)
            bits = 3 if ncolors <= 2 else 2 if ncolors <= 4 else 1 if ncolors <= 16 else 0
            xs = ceil_shift(xs, bits)
    bw.put(0, 1)

    # The main pixels.
    n = xs * h
    px = []
    if ncolors:
        bits = 3 if ncolors <= 2 else 2 if ncolors <= 4 else 1 if ncolors <= 16 else 0
        per = 1 << bits
        ib = 8 >> bits
        idx = 0
        for i in range(n):
            g = 0
            for j in range(per):
                if rng.chance(1, 3):
                    idx = rng.below(ncolors)
                g |= idx << (j * ib)
            px.append((0xFF << 24) | (rng.below(4) << 16) | (g << 8) | rng.below(4))
    elif data == "two":
        # Two colours whose channels all differ, the second one's larger in
        # some channels and smaller in others: two-symbol codes.
        two = [0x10F0_33C0, 0xE020_77A0]
        for i in range(n):
            px.append(two[rng.below(2)])
    else:
        for i in range(n):
            if data == "noise" or i == 0 or rng.chance(1, 4):
                px.append(rng.next() & 0xFFFFFFFF if data != "green" else (rng.below(256) << 8) | 0xFF000000)
            elif rng.chance(1, 2):
                px.append(px[i - 1])
            else:
                px.append(px[max(0, i - xs)])
    if cache_bits:
        bw.put(1, 1)
        bw.put(cache_bits, 4)
    else:
        bw.put(0, 1)
    group_of = lambda x, y: 0
    if meta_bits:
        bw.put(1, 1)
        bw.put(meta_bits - 2, 3)
        ew, eh = ceil_shift(xs, meta_bits), ceil_shift(h, meta_bits)
        groups = []
        for i in range(ew * eh):
            if group_pattern == "random":
                groups.append(rng.below(ngroups))
            else:
                groups.append(i % ngroups)
        groups[-1] = ngroups - 1  # So that there are ngroups groups.
        epx = [(0xFF << 24) | ((g >> 8) << 16) | ((g & 0xFF) << 8) | rng.below(256) for g in groups]
        sub_image(bw, epx, ew, eh, rng, subcache)
        group_of = lambda x, y: groups[(y >> meta_bits) * ew + (x >> meta_bits)]
    else:
        bw.put(0, 1)
        ngroups = 1
    toks = tokenize(px, xs, h, cache_bits, group_of, rng, backrefs)
    write_tokens(bw, xs, h, cache_bits, ngroups, toks, rng, style)


def vp8l_payload(w, h, seed, alpha_hint=0, **kw):
    rng = Rng(seed)
    bw = Bits()
    bw.put(0x2F, 8)
    bw.put(w - 1, 14)
    bw.put(h - 1, 14)
    bw.put(alpha_hint, 1)
    bw.put(0, 3)
    vp8l_stream(bw, w, h, rng, **kw)
    return bw.bytes()


def vp8l_file(w, h, seed, **kw):
    return riff(chunk(b"VP8L", vp8l_payload(w, h, seed, **kw)))


# ---- ALPH chunks.

def filter_alpha(a, w, h, method):
    out = bytearray(len(a))
    for y in range(h):
        for x in range(w):
            i = y * w + x
            if method == 0:
                pred = 0
            elif method == 1:  # horizontal
                pred = (a[i - w] if y > 0 else 0) if x == 0 else a[i - 1]
            elif method == 2:  # vertical
                pred = (a[i - 1] if x > 0 else 0) if y == 0 else a[i - w]
            else:  # gradient
                if y == 0:
                    pred = a[i - 1] if x > 0 else 0
                elif x == 0:
                    pred = a[i - w]
                else:
                    g = a[i - 1] + a[i - w] - a[i - w - 1]
                    pred = 0 if g < 0 else 255 if g > 255 else g
            out[i] = (a[i] - pred) & 0xFF
    return bytes(out)


def alph_chunk(alpha, w, h, filt, compression, seed, preprocessing=0, **kw):
    f = filter_alpha(alpha, w, h, filt)
    hdr = bytes([compression | (filt << 2) | (preprocessing << 4)])
    if compression == 0:
        return chunk(b"ALPH", hdr + f)
    # VP8L, header-less: the (filtered) alpha values in the green channel.
    rng = Rng(seed)
    bw = Bits()
    vp8l_alpha_stream(bw, f, w, h, rng, **kw)
    return chunk(b"ALPH", hdr + bw.bytes())


def vp8l_alpha_stream(bw, values, w, h, rng, transforms=(), cache_bits=0):
    """Encodes values (one byte per pixel) as a level-0 VP8L stream with the
    values in the green channel: no transforms, or colour indexing."""
    xs = w
    px = [0xFF000000 | (v << 8) for v in values]
    for typ, param in transforms:
        bw.put(1, 1)
        bw.put(typ, 2)
        if typ == 3:
            distinct = sorted(set(values))
            assert len(distinct) <= 256
            bw.put(len(distinct) - 1, 8)
            pal = [0xFF000000 | (v << 8) for v in distinct]
            # Delta coded.
            deltas = [pal[0]] + [sum(((((pal[i] >> s) & 0xFF) - ((pal[i - 1] >> s) & 0xFF)) & 0xFF) << s
                                     for s in (0, 8, 16, 24)) for i in range(1, len(pal))]
            sub_image(bw, deltas, len(pal), 1, rng, 0, 0)
            bits = 3 if len(pal) <= 2 else 2 if len(pal) <= 4 else 1 if len(pal) <= 16 else 0
            per = 1 << bits
            ib = 8 >> bits
            index = {v: i for i, v in enumerate(distinct)}
            nxs = ceil_shift(w, bits)
            npx = []
            for y in range(h):
                for X in range(nxs):
                    g = 0
                    for j in range(per):
                        x = X * per + j
                        if x < w:
                            g |= index[values[y * w + x]] << (j * ib)
                    npx.append(0xFF000000 | (g << 8))
            px, xs = npx, nxs
        elif typ == 2:
            pass  # subtract green: green is unchanged by it.
        else:
            raise ValueError(typ)
    bw.put(0, 1)
    if cache_bits:
        bw.put(1, 1)
        bw.put(cache_bits, 4)
    else:
        bw.put(0, 1)
    bw.put(0, 1)  # No meta codes.
    toks = tokenize(px, xs, h, cache_bits, lambda x, y: 0, rng, 4)
    write_tokens(bw, xs, h, cache_bits, 1, toks, rng)


# ---- The corpus.

def main(out):
    build_encoder()
    files = {}

    def save(name, data):
        assert name not in files
        files[name] = data

    # Lossy, from libwebp.
    sizes = [(1, 1), (2, 3), (15, 15), (16, 16), (17, 17), (31, 9), (33, 47), (100, 3), (3, 100)]
    for i, (w, h) in enumerate(sizes):
        rgba = picture(w, h, i, "mixed")
        save("lossy-%dx%d" % (w, h), libwebp(w, h, rgba, quality=70, rgb=1))
    save("lossy-wide-640x2", libwebp(640, 2, picture(640, 2, 3, "smooth"), rgb=1))
    save("lossy-tall-2x400", libwebp(2, 400, picture(2, 400, 4, "smooth"), rgb=1))
    for q in [0, 5, 25, 50, 90, 100]:
        save("lossy-q%d" % q, libwebp(37, 29, picture(37, 29, q, "mixed"), quality=q, rgb=1))
    for m in range(0, 7):
        save("lossy-method%d" % m, libwebp(40, 24, picture(40, 24, m, "edges"), method=m, rgb=1))
    for strength in [0, 30, 100]:
        for sharp in [0, 3, 7]:
            save("lossy-simple-f%d-s%d" % (strength, sharp),
                 libwebp(48, 40, picture(48, 40, strength + sharp, "edges"), filter_type=0,
                         filter_strength=strength, filter_sharpness=sharp, autofilter=0, quality=40, rgb=1))
    for sharp in range(8):
        save("lossy-strong-s%d" % sharp,
             libwebp(48, 40, picture(48, 40, 10 + sharp, "mixed"), filter_type=1, filter_strength=60,
                     filter_sharpness=sharp, autofilter=0, quality=30, rgb=1))
    save("lossy-autofilter", libwebp(48, 40, picture(48, 40, 21, "mixed"), autofilter=1, rgb=1))
    for seg in [1, 2, 3, 4]:
        for sns in [0, 100]:
            save("lossy-seg%d-sns%d" % (seg, sns),
                 libwebp(64, 48, picture(64, 48, seg * 3 + sns, "mixed"), segments=seg, sns_strength=sns,
                         quality=50, rgb=1))
    # libwebp only honours "partitions" at methods 0 to 2: at the default
    # method it always writes one token partition.
    for part in [0, 1, 2, 3]:
        save("lossy-partitions%d" % (1 << part),
             libwebp(64, 72, picture(64, 72, part, "noise"), partitions=part, method=0, quality=80, rgb=1))
    for m, part, w, h in [(1, 1, 33, 47), (2, 2, 200, 136), (1, 3, 17, 129), (2, 3, 64, 72)]:
        save("lossy-partitions%d-m%d-%dx%d" % (1 << part, m, w, h),
             libwebp(w, h, picture(w, h, part + m, "mixed"), partitions=part, method=m, quality=60, rgb=1))
    save("lossy-sharpyuv", libwebp(33, 21, picture(33, 21, 5, "edges"), use_sharp_yuv=1, rgb=1))
    save("lossy-preprocessing", libwebp(33, 21, picture(33, 21, 6, "noise"), preprocessing=1, rgb=1))
    save("lossy-noise-q100", libwebp(32, 32, picture(32, 32, 7, "noise"), quality=100, rgb=1))

    # Lossy with alpha (VP8X, ALPH, VP8), from libwebp.
    for comp in [0, 1]:
        for filt in [0, 1, 2]:
            for kind in ["gradient", "binary", "noise"]:
                save("alpha-c%d-f%d-%s" % (comp, filt, kind),
                     libwebp(29, 19, picture(29, 19, comp * 7 + filt, "mixed", kind), alpha_compression=comp,
                             alpha_filtering=filt, quality=60))
    for aq in [0, 50, 100]:
        save("alpha-quality%d" % aq, libwebp(30, 30, picture(30, 30, aq, "smooth", "noise"), alpha_quality=aq))
    save("alpha-1x1", libwebp(1, 1, picture(1, 1, 1, "smooth", "noise")))
    save("alpha-17x33-holes", libwebp(17, 33, picture(17, 33, 2, "edges", "holes")))
    save("alpha-wide-300x3", libwebp(300, 3, picture(300, 3, 3, "smooth", "gradient")))

    # Lossless, from libwebp.
    for i, (w, h) in enumerate([(1, 1), (2, 3), (17, 9), (64, 33), (3, 100), (500, 2)]):
        save("lossless-%dx%d" % (w, h), libwebp(w, h, picture(w, h, i, "mixed", "gradient"), lossless=1))
    for n in [1, 2, 3, 4, 11, 16, 17, 200, 256]:
        save("lossless-palette%d" % n, libwebp(37, 23, palette_picture(37, 23, n, n, alpha=n % 2 == 0), lossless=1))
    for q in [0, 25, 75, 100]:
        for m in [0, 3, 6]:
            save("lossless-q%d-m%d" % (q, m),
                 libwebp(64, 48, picture(64, 48, q + m, "mixed", "binary"), lossless=1, quality=q, method=m))
    save("lossless-noise", libwebp(40, 40, picture(40, 40, 9, "noise", "noise"), lossless=1))
    save("lossless-exact", libwebp(40, 30, picture(40, 30, 10, "mixed", "holes"), lossless=1, exact=1))
    save("lossless-near60", libwebp(40, 30, picture(40, 30, 11, "smooth"), lossless=1, near_lossless=60))
    save("lossless-big-256x192", libwebp(256, 192, picture(256, 192, 12, "mixed", "gradient"), lossless=1,
                                         quality=100, method=5))

    # VP8L bitstreams with chosen features.
    for typ, name in [(0, "predictor"), (1, "crosscolor")]:
        for bits in [2, 3, 5, 9]:
            save("vp8l-%s-b%d" % (name, bits), vp8l_file(23, 19, 100 + typ * 10 + bits, transforms=[(typ, bits)]))
    save("vp8l-predictor-wide", vp8l_file(300, 7, 120, transforms=[(0, 2)]))
    save("vp8l-subgreen", vp8l_file(23, 19, 130, transforms=[(2, None)]))
    save("vp8l-all3", vp8l_file(41, 27, 131, transforms=[(2, None), (0, 3), (1, 4)]))
    save("vp8l-all3-reordered", vp8l_file(41, 27, 132, transforms=[(1, 2), (2, None), (0, 2)]))
    for n in [1, 2, 3, 4, 5, 16, 17, 255, 256]:
        save("vp8l-index%d" % n, vp8l_file(29, 11, 140 + n, transforms=[(3, n)]))
        save("vp8l-index%d-odd" % n, vp8l_file(1 + n % 7, 5, 150 + n, transforms=[(3, n)]))
    save("vp8l-index4-predictor", vp8l_file(29, 11, 160, transforms=[(3, 4), (0, 2)]))
    save("vp8l-index16-all", vp8l_file(33, 17, 161, transforms=[(2, None), (3, 16), (1, 2), (0, 3)]))
    for cb in [1, 4, 8, 11]:
        save("vp8l-cache%d" % cb, vp8l_file(31, 23, 170 + cb, cache_bits=cb, data="runs"))
    save("vp8l-cache11-subcache", vp8l_file(31, 23, 182, cache_bits=11, subcache=3, transforms=[(0, 2)]))
    save("vp8l-nocache-runs", vp8l_file(31, 23, 183, data="runs", backrefs=8))
    for mb, ng in [(2, 2), (3, 7), (4, 16), (9, 1), (2, 64)]:
        save("vp8l-groups%d-b%d" % (ng, mb), vp8l_file(37, 29, 190 + ng, meta_bits=mb, ngroups=ng, data="runs"))
    save("vp8l-groups256", vp8l_file(64, 64, 200, meta_bits=2, ngroups=256, data="runs", group_pattern="cycle"))
    save("vp8l-groups-cache", vp8l_file(37, 29, 201, meta_bits=3, ngroups=5, cache_bits=6, data="runs"))
    save("vp8l-simple-codes", vp8l_file(19, 13, 210, data="two", backrefs=0, style="simple-only"))
    save("vp8l-green-only", vp8l_file(19, 13, 218, data="green", backrefs=0))
    save("vp8l-normal-codes", vp8l_file(19, 13, 211, style="normal", data="runs"))
    REVERSED[0] = True
    save("vp8l-simple-reversed", vp8l_file(19, 13, 217, data="two", backrefs=0, style="simple-only"))
    REVERSED[0] = False
    save("vp8l-backrefs-far", vp8l_file(130, 40, 212, data="runs", backrefs=9))
    save("vp8l-1x1", vp8l_file(1, 1, 213))
    save("vp8l-1x1-index1", vp8l_file(1, 1, 214, transforms=[(3, 1)]))
    save("vp8l-tall-2x700", vp8l_file(2, 700, 215, data="runs", transforms=[(0, 4)]))
    save("vp8l-alpha-hint", vp8l_file(9, 9, 216, alpha_hint=1))
    CLAMPED[0] = True
    save("vp8l-narrow-clamped", vp8l_file(5, 9, 219, data="runs", backrefs=9))
    CLAMPED[0] = False

    # Containers.
    lossy = libwebp(24, 16, picture(24, 16, 30, "mixed"), quality=60, rgb=1)
    vp8 = dict(chunks_of(lossy))[b"VP8 "]
    vp8l = vp8l_payload(24, 16, 300, transforms=[(2, None)])
    icc = b"\x00\x00\x02\x0c" + bytes(range(256)) * 2
    exif = b"Exif\x00\x00II*\x00" + bytes(41)
    xmp = b"<x:xmpmeta xmlns:x='adobe:ns:meta/'/>"
    for name, payload, fourcc in [("vp8", vp8, b"VP8 "), ("vp8l", vp8l, b"VP8L")]:
        save("container-%s-simple-odd-pad" % name, riff(chunk(fourcc, payload + (b"" if len(payload) % 2 else b"\x00"))))
        save("container-vp8x-%s" % name, riff(vp8x(0, 24, 16) + chunk(fourcc, payload)))
        save("container-vp8x-%s-meta" % name,
             riff(vp8x(ICC_FLAG | EXIF_FLAG | XMP_FLAG, 24, 16) + chunk(b"ICCP", icc) + chunk(fourcc, payload) +
                  chunk(b"EXIF", exif) + chunk(b"XMP ", xmp)))
        save("container-vp8x-%s-meta-before" % name,
             riff(vp8x(ICC_FLAG | EXIF_FLAG | XMP_FLAG, 24, 16) + chunk(b"ICCP", icc) + chunk(b"EXIF", exif) +
                  chunk(b"XMP ", xmp + b"!") + chunk(fourcc, payload)))
        save("container-vp8x-%s-unknown" % name,
             riff(vp8x(0, 24, 16) + chunk(b"ABCD", b"xyz") + chunk(b"\x00\x00\x00\x00", b"") + chunk(fourcc, payload)))
        save("container-vp8x-%s-noiccflag" % name, riff(vp8x(0, 24, 16) + chunk(b"ICCP", icc) + chunk(fourcc, payload)))
        save("container-vp8x-%s-noexifflag" % name, riff(vp8x(0, 24, 16) + chunk(b"EXIF", exif) + chunk(fourcc, payload)))
        save("container-vp8x-%s-noxmpflag" % name, riff(vp8x(0, 24, 16) + chunk(b"XMP ", xmp) + chunk(fourcc, payload)))
        save("container-vp8x-%s-iccp-late" % name,
             riff(vp8x(ICC_FLAG | ANIM_FLAG, 24, 16) + chunk(b"ANIM", bytes(6)) + chunk(b"ICCP", icc) +
                  chunk(fourcc, payload)))
        save("container-vp8x-%s-bigger-canvas" % name, riff(vp8x(0, 25, 17) + chunk(fourcc, payload)))
        save("container-vp8x-%s-smaller-canvas" % name, riff(vp8x(0, 23, 15) + chunk(fourcc, payload)))
        save("container-%s-riff-short" % name, riff(chunk(fourcc, payload), size=4 + 8 + len(payload) // 2))
        save("container-%s-riff-long" % name, riff(chunk(fourcc, payload), size=4 + 8 + len(payload) + 1000))
        save("container-%s-riff-odd" % name, riff(chunk(fourcc, payload), size=4 + 8 + len(payload) + 1))
        save("container-%s-chunk-short" % name, riff(fourcc + struct.pack("<I", len(payload) - 3) + payload))
        save("container-%s-chunk-long" % name, riff(fourcc + struct.pack("<I", len(payload) + 3) + payload))
        save("container-%s-trailing" % name, riff(chunk(fourcc, payload) + chunk(b"JUNK", b"trailing")))
    save("container-vp8x-flags-reserved", riff(vp8x(0xC0, 24, 16) + chunk(b"VP8L", vp8l)))
    save("container-vp8x-huge", riff(vp8x(0, 0x4000, 0x4000) + chunk(b"VP8L", vp8l)))
    save("container-vp8x-size9", riff(chunk(b"VP8X", bytes(9)) + chunk(b"VP8L", vp8l)))
    save("container-vp8x-twice", riff(vp8x(0, 24, 16) + vp8x(0, 24, 16) + chunk(b"VP8L", vp8l)))
    save("container-not-webp", b"RIFF" + struct.pack("<I", 4 + 8 + len(vp8l)) + b"WEBQ" + chunk(b"VP8L", vp8l))
    save("container-unknown-first", riff(chunk(b"VP8Y", vp8l)))
    save("container-vp8l-badsig", riff(chunk(b"VP8L", b"\x2e" + vp8l[1:])))
    save("container-vp8l-badversion", riff(chunk(b"VP8L", vp8l[:4] + bytes([vp8l[4] | 0x20]) + vp8l[5:])))
    save("container-vp8-badstart", riff(chunk(b"VP8 ", vp8[:3] + b"\x9d\x01\x2b" + vp8[6:])))
    save("container-vp8-interframe", riff(chunk(b"VP8 ", bytes([vp8[0] | 1]) + vp8[1:])))
    save("container-vp8-zerowidth", riff(chunk(b"VP8 ", vp8[:6] + b"\x00\x00" + vp8[8:])))

    # ALPH chunks, assembled: every filter, raw and VP8L compression.
    w, h = 24, 16
    alphas = {
        "gradient": bytes((x * 10 + y * 3) & 0xFF for y in range(h) for x in range(w)),
        "few": bytes([0, 64, 128, 255][(x // 3 + y // 2) % 4] for y in range(h) for x in range(w)),
        "noise": bytes(Rng(5).below(256) for _ in range(w * h)),
    }
    for kind, a in sorted(alphas.items()):
        for filt in range(4):
            for comp in [0, 1]:
                kw = {}
                if comp == 1 and kind == "few":
                    kw = {"transforms": [(3, None)]}
                if comp == 1 and kind == "gradient" and filt == 3:
                    kw = {"cache_bits": 5}
                save("container-alph-%s-f%d-c%d" % (kind, filt, comp),
                     riff(vp8x(ALPHA_FLAG, w, h) + alph_chunk(a, w, h, filt, comp, filt * 2 + comp, **kw) +
                          chunk(b"VP8 ", vp8)))
    a = alphas["gradient"]
    save("container-alph-preprocessing", riff(vp8x(ALPHA_FLAG, w, h) + alph_chunk(a, w, h, 1, 0, 1, preprocessing=1) +
                                             chunk(b"VP8 ", vp8)))
    save("container-alph-compression2", riff(vp8x(ALPHA_FLAG, w, h) + chunk(b"ALPH", b"\x02" + a) + chunk(b"VP8 ", vp8)))
    save("container-alph-compression3", riff(vp8x(ALPHA_FLAG, w, h) + chunk(b"ALPH", b"\x03" + a) + chunk(b"VP8 ", vp8)))
    save("container-alph-short", riff(vp8x(ALPHA_FLAG, w, h) + chunk(b"ALPH", b"\x00" + a[:100]) + chunk(b"VP8 ", vp8)))
    save("container-alph-long", riff(vp8x(ALPHA_FLAG, w, h) + chunk(b"ALPH", b"\x00" + a + a[:50]) + chunk(b"VP8 ", vp8)))
    save("container-alph-noflag", riff(vp8x(0, w, h) + chunk(b"ALPH", b"\x00" + a) + chunk(b"VP8 ", vp8)))
    save("container-alph-flag-noalph", riff(vp8x(ALPHA_FLAG, w, h) + chunk(b"VP8 ", vp8)))
    save("container-alph-vp8l", riff(vp8x(ALPHA_FLAG, w, h) + chunk(b"ALPH", b"\x00" + a) + chunk(b"VP8L", vp8l)))
    save("container-alph-flag-vp8l", riff(vp8x(ALPHA_FLAG, w, h) + chunk(b"VP8L", vp8l)))
    save("container-alph-twice", riff(vp8x(ALPHA_FLAG, w, h) + chunk(b"ALPH", b"\x00" + a) +
                                      chunk(b"ALPH", b"\x00" + a) + chunk(b"VP8 ", vp8)))
    save("container-alph-after-iccp", riff(vp8x(ALPHA_FLAG | ICC_FLAG, w, h) + chunk(b"ICCP", icc) +
                                           chunk(b"ALPH", b"\x04" + filter_alpha(a, w, h, 1)) + chunk(b"VP8 ", vp8)))
    save("container-alph-before-iccp", riff(vp8x(ALPHA_FLAG | ICC_FLAG, w, h) + chunk(b"ALPH", b"\x00" + a) +
                                            chunk(b"ICCP", icc) + chunk(b"VP8 ", vp8)))
    save("container-alph-canvas-mismatch", riff(vp8x(ALPHA_FLAG, w + 1, h) + chunk(b"ALPH", b"\x00" + a) +
                                                chunk(b"VP8 ", vp8)))

    # Animations (ANIM, ANMF), which std/webp does not decode.
    anmf = struct.pack("<I", 0)[:3] * 2 + struct.pack("<I", w - 1)[:3] + struct.pack("<I", h - 1)[:3] + \
        struct.pack("<I", 100)[:3] + b"\x00"
    save("container-anim-1frame", riff(vp8x(ANIM_FLAG, w, h) + chunk(b"ANIM", bytes(4) + b"\x00\x00") +
                                       chunk(b"ANMF", anmf + chunk(b"VP8L", vp8l))))
    save("container-anim-2frames", riff(vp8x(ANIM_FLAG, w, h) + chunk(b"ANIM", bytes(4) + b"\x03\x00") +
                                        chunk(b"ANMF", anmf + chunk(b"VP8 ", vp8)) +
                                        chunk(b"ANMF", anmf + chunk(b"VP8L", vp8l))))
    save("container-anim-noflag", riff(vp8x(0, w, h) + chunk(b"ANIM", bytes(6)) +
                                       chunk(b"ANMF", anmf + chunk(b"VP8L", vp8l))))

    for name, data in sorted(files.items()):
        with open(os.path.join(out, name + ".webp"), "wb") as f:
            f.write(data)
    print("make.py: %d files, %d bytes" % (len(files), sum(len(d) for d in files.values())))


if __name__ == "__main__":
    if len(sys.argv) != 2:
        sys.exit("usage: make.py OUTDIR")
    main(sys.argv[1])
