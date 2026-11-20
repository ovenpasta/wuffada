#!/bin/sh
# Regenerates ada/gen (the checked-in output of wuffs-ada) and the generated
# test package under ada/tests. The output is deterministic: run from any
# directory, twice, and nothing changes.
#
# Everything is generated into a temporary directory first. The checked-in
# files are replaced only if every package was generated successfully.
#
# Each package's status-code namespace (package id) comes from the table in
# internal/adagen/package_ids.txt, which is compiled into wuffs-ada.
set -eu
cd "$(dirname "$0")"

go build -o bin/wuffs-ada ./cmd/wuffs-ada

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
mkdir "$tmp/gen" "$tmp/tests"

gen() {
    # usage: gen OUTDIR PACKAGE_NAME FILES...
    outdir="$1"
    name="$2"
    shift 2
    bin/wuffs-ada gen -package_name "$name" -wuffsroot wuffs -o "$outdir" "$@"
}

bin/wuffs-ada genstd -o "$tmp/gen"

gen "$tmp/gen" adler32 \
    wuffs/std/adler32/common_adler32.wuffs \
    wuffs/std/adler32/common_up_arm_neon.wuffs \
    wuffs/std/adler32/common_up_x86_sse42.wuffs
gen "$tmp/gen" crc32 \
    wuffs/std/crc32/common_crc32.wuffs \
    wuffs/std/crc32/common_up_arm_crc32.wuffs \
    wuffs/std/crc32/common_up_x86_sse42.wuffs
gen "$tmp/gen" lzw \
    wuffs/std/lzw/decode_lzw.wuffs \
    wuffs/std/lzw/decode_quirks.wuffs
gen "$tmp/gen" deflate \
    wuffs/std/deflate/common_consts.wuffs \
    wuffs/std/deflate/decode_deflate.wuffs \
    wuffs/std/deflate/decode_huffman_bmi2.wuffs \
    wuffs/std/deflate/decode_huffman_fast32.wuffs \
    wuffs/std/deflate/decode_huffman_fast64.wuffs \
    wuffs/std/deflate/decode_huffman_slow.wuffs
gen "$tmp/gen" zlib \
    wuffs/std/zlib/decode_quirks.wuffs \
    wuffs/std/zlib/decode_zlib.wuffs
gen "$tmp/gen" gzip \
    wuffs/std/gzip/decode_gzip.wuffs
gen "$tmp/gen" netpbm \
    wuffs/std/netpbm/decode_netpbm.wuffs
gen "$tmp/gen" bmp \
    wuffs/std/bmp/decode_bmp.wuffs
gen "$tmp/gen" gif \
    wuffs/std/gif/common_consts.wuffs \
    wuffs/std/gif/decode_gif.wuffs \
    wuffs/std/gif/decode_lzw.wuffs \
    wuffs/std/gif/decode_quirks.wuffs
gen "$tmp/gen" png \
    wuffs/std/png/common_consts.wuffs \
    wuffs/std/png/decode_filter_arm_neon.wuffs \
    wuffs/std/png/decode_filter_fallback.wuffs \
    wuffs/std/png/decode_filter_x86_sse42.wuffs \
    wuffs/std/png/decode_png.wuffs \
    wuffs/std/png/decode_swizzle_default.wuffs \
    wuffs/std/png/decode_swizzle_tricky.wuffs
gen "$tmp/gen" wbmp \
    wuffs/std/wbmp/decode_wbmp.wuffs
gen "$tmp/gen" nie \
    wuffs/std/nie/decode_nie.wuffs
gen "$tmp/gen" targa \
    wuffs/std/targa/decode_targa.wuffs

# A test-only package that exercises what the standard packages above do not
# (see the comment in the .wuffs file). Its driver is ada/tests/test_m1.adb.
gen "$tmp/tests" m1test internal/adagen/testdata/m1test.wuffs

# A test-only package of adversarial coroutines. Its driver is
# ada/tests/test_adv.adb.
gen "$tmp/tests" advtest internal/adagen/testdata/advtest.wuffs

# Success: replace the checked-in output.
# (ada/tests also holds hand-written children of generated packages, the
# wuffs-std-*-probe.ads files: only the generated test packages go.)
rm -f ada/gen/*.ads ada/gen/*.adb
for f in "$tmp"/tests/*; do
    rm -f "ada/tests/$(basename "$f")"
done
cp "$tmp"/gen/* ada/gen/
cp "$tmp"/tests/* ada/tests/
