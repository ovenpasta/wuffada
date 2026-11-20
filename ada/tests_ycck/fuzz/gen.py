#!/usr/bin/env python3
"""Case generator of the differential fuzz test (written by the independent
reviewer of the YCCK milestone; adopted unchanged apart from this text).

    gen.py SEED N [profile]      profile: mix (default) or wide

Prints N random calls of swizzle_ycck, one per line, 37 numbers each (see
cfuzz.c for their meaning): mostly valid calls with every kind of sampling
layout, origin, clipping, stride and plane length, some of them wide (around
the chunk boundaries) or huge and clipped, and about a fifth with one or two
arguments replaced by edge values.  regen.sh turns them into fuzz_cases.txt.
"""
import sys, random, math
seed = int(sys.argv[1]); N = int(sys.argv[2]); prof = sys.argv[3] if len(sys.argv) > 3 else "mix"
R = random.Random(seed)
ACC = [0x81008888, 0x90008888, 0xA0000888, 0x80000888, 0x80000565, 0x20000008, 0x2000000B,
       0x2010000B, 0x21000088, 0x81040008, 0x82040008, 0x83040008, 0x82008888, 0x8100BBBB,
       0xA1008888, 0xA2008888, 0xB0008888]
REJ = [0x02000008, 0x22000088, 0x30008888, 0x8200BBBB, 0x83008888, 0xA100BBBB, 0xA200BBBB,
       0xA3008888, 0x40020888, 0x41038888, 0x50038888, 0x60020888, 0x61038888, 0x70038888,
       0xC0020888, 0xD0038888, 0x00000000, 0x80000444, 0x81080008]
def bpp(fmt):
    if (fmt >> 16) & 3: return 0
    bits = sum([0,1,2,3,4,5,6,7,8,10,12,16,24,32,48,64][(fmt >> (4*i)) & 15] for i in range(4))
    return bits // 8 if bits % 8 == 0 else 0
WIDE = [479, 480, 481, 482, 671, 672, 673, 674, 959, 960, 961, 1343, 1344, 1345, 1346, 1439, 1440, 1441, 1919, 1920, 1921, 2015, 2016, 2017, 2018, 2688, 2689]
EDGE = [0, 1, 2, 3, 4, 5, 0xFFFE, 0xFFFF, 0x10000, 0x10001, 0x3FFFF, 0x40000, 0x7FFFFFFF, 0x80000000, 0xFFFFFFFF]
def lcm(a, b): return a * b // math.gcd(a, b)
def one():
    four = R.random() < 0.5
    np_ = 4 if four else 3
    if R.random() < 0.85:
        mh = R.choice([1, 2, 2, 2, 3, 4, 4]); mv = R.choice([1, 2, 2, 2, 3, 4, 4])
        hs = [R.choice([d for d in range(1, 5) if mh % d == 0]) for _ in range(np_)]
        vs = [R.choice([d for d in range(1, 5) if mv % d == 0]) for _ in range(np_)]
        hs[R.randrange(np_)] = mh; vs[R.randrange(np_)] = mv
    else:
        hs = [R.randint(1, 4) for _ in range(np_)]; vs = [R.randint(1, 4) for _ in range(np_)]
    mh = max(hs); mv = max(vs)
    ih = [mh // h for h in hs]; iv = [mv // v for v in vs]
    lh = 1; lv = 1
    for a in ih: lh = lcm(lh, max(a, 1))
    for a in iv: lv = lcm(lv, max(a, 1))
    ups = R.choice([0, 0, 1, 1, 2, 2, 1, 2, 3, 255] if R.random() < 0.2 else [0, 1, 2])
    wide = R.random() < (0.12 if prof == "mix" else (1.0 if prof == "wide" else 0.0))
    if wide:
        dx = R.choice(WIDE) * R.choice([1, 1, 1, 2]) + R.choice([0, 0, 0, -1, 1, 2, 3]); dy = R.randint(1, 5)
    else:
        dx = R.choice([1, 2, 3, 4, 5, 6, 7, 8, 9]) if R.random() < 0.3 else R.randint(1, 70)
        dy = R.choice([1, 2, 3, 4, 5, 6, 7, 8, 9]) if R.random() < 0.4 else R.randint(1, 40)
    x0 = 0; y0 = 0
    if ups == 0 or R.random() < 0.03:
        if R.random() < 0.5: x0 = lh * R.randint(0, 6)
        if R.random() < 0.5: y0 = lv * R.randint(0, 6)
        if R.random() < 0.08: x0 = R.randint(0, 9)
        if R.random() < 0.08: y0 = R.randint(0, 9)
    x1 = x0 + dx; y1 = y0 + dy
    ew = -(-dx // lh) * lh + lh * R.choice([0, 0, 0, 1, 2, 5]); eh = -(-dy // lv) * lv + lv * R.choice([0, 0, 0, 1, 2, 3])
    ws = []; hts = []; ss = []; lens = []
    for k in range(np_):
        w = ew // ih[k]; h = eh // iv[k]
        if k == 3 and ih[k] == 1 and iv[k] == 1 and R.random() < 0.4: w = dx; h = dy
        if R.random() < 0.02: w += R.choice([-1, 1])
        if R.random() < 0.02: h += R.choice([-1, 1])
        w = max(w, 0); h = max(h, 0)
        r = R.random()
        s = w if r < 0.5 else (w + R.randint(1, 9) if r < 0.9 else (0 if r < 0.94 else R.randint(0, max(w, 1))))
        fl = 0 if h == 0 else (h - 1) * s + w
        r = R.random()
        ln = fl if r < 0.6 else (fl + R.randint(1, 20) if r < 0.96 else max(fl - R.randint(1, 3), 0))
        ws.append(w); hts.append(h); ss.append(s); lens.append(ln)
    hs = hs + [0] * (4 - np_); vs = vs + [0] * (4 - np_)
    if not four:
        if R.random() < 0.3:
            ws.append(R.randint(0, 5)); hts.append(R.randint(0, 5)); ss.append(R.randint(0, 9))
            lens.append((0 if hts[3] == 0 else (hts[3] - 1) * ss[3] + ws[3]) + R.choice([0, 0, 0, 3, -1]))
            lens[3] = max(lens[3], 0)
        else:
            ws.append(0); hts.append(0); ss.append(0); lens.append(0)
        if R.random() < 0.03: hs[3] = R.randint(0, 5)
        if R.random() < 0.03: vs[3] = R.randint(0, 5)
    fmt = R.choice(ACC) if R.random() < 0.93 else R.choice(REJ)
    b = bpp(fmt)
    r = R.random()
    dw = x1 if r < 0.5 else max(0, x1 + R.randint(-5, 5)) if r < 0.9 else R.randint(0, x1 + 3)
    r = R.random()
    dh = y1 if r < 0.5 else max(0, y1 + R.randint(-5, 5)) if r < 0.9 else R.randint(0, y1 + 3)
    if four:
        model = R.choice([0, 6, 7, 0x80]) if R.random() < 0.9 else R.choice([1, 2, 3, 4, 5, 8, 0x3F, 0x40, 0x41, 0x7F, 0x81, 0xFF])
    else:
        model = R.choice([0, 4, 0x40]) if R.random() < 0.8 else R.choice([1, 2, 3, 5, 6, 7, 8, 0x3F, 0x41, 0x7F, 0x80, 0x81, 0xFF])
    scratch = 2048 if R.random() < 0.95 else R.choice([0, 1, 2047, 2049, 5000])
    # huge-rect variant: stride-0 planes, clipped by a small destination
    if prof != "wide" and R.random() < 0.04:
        big = R.choice([0xFFFF, 0xFFFE, 0xFFFD, 0x8000, 0x10000, 40000])
        if R.random() < 0.5:
            x0 = 0 if ups else R.choice([0, 0, lh * 3, (big // lh - 2) * lh]); x1 = big
            dx = x1 - x0
            if dx > 0:
                ew = -(-dx // lh) * lh + lh * R.choice([0, 0, 1])
                for k in range(np_):
                    ws[k] = ew // ih[k] if ih[k] else ws[k]
                    if k == 3 and ih[k] == 1 and iv[k] == 1 and hts[k] == dy and R.random() < 0.5: ws[k] = dx
                    ss[k] = R.choice([0, ws[k], ws[k] + 1]) if hts[k] * ws[k] < 4000000 else 0
                    lens[k] = 0 if hts[k] == 0 else (hts[k] - 1) * ss[k] + ws[k]
            dw = R.choice([R.randint(0, 40), R.randint(600, 700)]) if R.random() < 0.9 else dw
        else:
            y0 = 0 if ups else R.choice([0, 0, lv * 3, (big // lv - 2) * lv]); y1 = big
            dy = y1 - y0
            if dy > 0:
                eh = -(-dy // lv) * lv + lv * R.choice([0, 0, 1])
                for k in range(np_):
                    hts[k] = eh // iv[k] if iv[k] else hts[k]
                    if k == 3 and ih[k] == 1 and iv[k] == 1 and ws[k] == dx and R.random() < 0.5: hts[k] = dy
                    ss[k] = R.choice([0, 0, 1, ws[k]]) if ws[k] < 60 else 0
                    lens[k] = 0 if hts[k] == 0 else (hts[k] - 1) * ss[k] + ws[k]
            dh = R.randint(0, 40)
        if dw * dh > 60000: dh = max(1, 60000 // max(dw, 1))
    # mutations
    if R.random() < (0.2 if prof == "mix" else 0.0):
        for _ in range(R.choice([1, 1, 2])):
            f = R.randrange(11); k = R.randrange(4); e = R.choice(EDGE)
            if f == 0: x0 = e
            elif f == 1: x1 = e
            elif f == 2: y0 = e
            elif f == 3: y1 = e
            elif f == 4: ws[k] = e
            elif f == 5: hts[k] = e
            elif f == 6: ss[k] = e
            elif f == 7: hs[k] = R.choice([0, 5, 6, 8, 255, 1, 2, 3, 4])
            elif f == 8: vs[k] = R.choice([0, 5, 6, 8, 255, 1, 2, 3, 4])
            elif f == 9: lens[k] = R.choice([0, 1, lens[k] + 1, max(lens[k] - 1, 0)])
            elif f == 10: dw = R.choice([0, 1, dw]); dh = R.choice([0, 1, dh])
    if dw * dh > 400000: dh = max(1, 400000 // max(dw, 1))
    p0w = dw * (b if b else 4); dstride = p0w + R.choice([0, 0, 0, 1, 3, 8])
    dseed = R.getrandbits(40) * 4 + R.choice([0, 0, 0, 1, 2, 2])
    f = [fmt, dw, dh, p0w, dstride, x0, x1, y0, y1]
    for k in range(4): f += [ws[k], hts[k], ss[k], hs[k], vs[k]]
    f += lens + [model, ups, scratch, dseed]
    return " ".join(str(v) for v in f)
for _ in range(N): print(one())
