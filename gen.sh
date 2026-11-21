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
gen "$tmp/gen" qoi \
    wuffs/std/qoi/decode_qoi.wuffs
gen "$tmp/gen" xxhash32 \
    wuffs/std/xxhash32/common_xxhash32.wuffs
gen "$tmp/gen" xxhash64 \
    wuffs/std/xxhash64/common_xxhash64.wuffs
gen "$tmp/gen" crc64 \
    wuffs/std/crc64/common_crc64.wuffs \
    wuffs/std/crc64/common_up_x86_sse42.wuffs
gen "$tmp/gen" bzip2 \
    wuffs/std/bzip2/decode_bzip2.wuffs \
    wuffs/std/bzip2/decode_flush_fast.wuffs \
    wuffs/std/bzip2/decode_flush_slow.wuffs \
    wuffs/std/bzip2/decode_huffman_fast.wuffs \
    wuffs/std/bzip2/decode_huffman_slow.wuffs
gen "$tmp/gen" lzma \
    wuffs/std/lzma/decode_bitstream_fast.wuffs \
    wuffs/std/lzma/decode_bitstream_slow.wuffs \
    wuffs/std/lzma/decode_lzma.wuffs \
    wuffs/std/lzma/decode_quirks.wuffs
gen "$tmp/gen" lzip \
    wuffs/std/lzip/decode_lzip.wuffs
gen "$tmp/gen" thumbhash \
    wuffs/std/thumbhash/decode_quirks.wuffs \
    wuffs/std/thumbhash/decode_thumbhash.wuffs
gen "$tmp/gen" etc2 \
    wuffs/std/etc2/decode_etc2.wuffs
gen "$tmp/gen" handsum \
    wuffs/std/handsum/decode_handsum.wuffs
gen "$tmp/gen" sha256 \
    wuffs/std/sha256/common_sha256.wuffs
gen "$tmp/gen" xz \
    wuffs/std/xz/decode_filter.wuffs \
    wuffs/std/xz/decode_quirks.wuffs \
    wuffs/std/xz/decode_xz.wuffs
gen "$tmp/gen" jpeg \
    wuffs/std/jpeg/common_consts.wuffs \
    wuffs/std/jpeg/decode_idct_default.wuffs \
    wuffs/std/jpeg/decode_idct_x86_avx2.wuffs \
    wuffs/std/jpeg/decode_jpeg.wuffs \
    wuffs/std/jpeg/decode_load_smooth.wuffs \
    wuffs/std/jpeg/decode_mcu_default.wuffs \
    wuffs/std/jpeg/decode_mcu_progressive_ac_high_bits.wuffs \
    wuffs/std/jpeg/decode_mcu_progressive_ac_low_bit.wuffs \
    wuffs/std/jpeg/decode_mcu_progressive_dc_high_bits.wuffs \
    wuffs/std/jpeg/decode_mcu_progressive_dc_low_bit.wuffs \
    wuffs/std/jpeg/decode_quirks.wuffs
gen "$tmp/gen" vp8 \
    wuffs/std/vp8/common_consts.wuffs \
    wuffs/std/vp8/decode_bitstream.wuffs \
    wuffs/std/vp8/decode_coefficients.wuffs \
    wuffs/std/vp8/decode_filter_default.wuffs \
    wuffs/std/vp8/decode_header_partition.wuffs \
    wuffs/std/vp8/decode_idct_default.wuffs \
    wuffs/std/vp8/decode_macroblocks.wuffs \
    wuffs/std/vp8/decode_predict_default.wuffs \
    wuffs/std/vp8/decode_quirks.wuffs \
    wuffs/std/vp8/decode_reconstruct.wuffs \
    wuffs/std/vp8/decode_vp8.wuffs
gen "$tmp/gen" webp \
    wuffs/std/webp/decode_alph_default.wuffs \
    wuffs/std/webp/decode_huffman.wuffs \
    wuffs/std/webp/decode_pixels_slow.wuffs \
    wuffs/std/webp/decode_transform.wuffs \
    wuffs/std/webp/decode_vp8l.wuffs \
    wuffs/std/webp/decode_webp.wuffs

gen "$tmp/gen" json \
    wuffs/std/json/common_consts.wuffs \
    wuffs/std/json/decode_json.wuffs \
    wuffs/std/json/decode_quirks.wuffs
gen "$tmp/gen" cbor \
    wuffs/std/cbor/decode_cbor.wuffs

# A test-only package that exercises what the standard packages above do not
# (see the comment in the .wuffs file). Its driver is ada/tests/test_m1.adb.
gen "$tmp/tests" m1test internal/adagen/testdata/m1test.wuffs

# A test-only package of adversarial coroutines. Its driver is
# ada/tests/test_adv.adb.
gen "$tmp/tests" advtest internal/adagen/testdata/advtest.wuffs

# A test-only package of adversarial token-writer coroutines. Its driver is
# ada/tests/test_tokadv.adb.
gen "$tmp/tests" tokadv internal/adagen/testdata/tokadv.wuffs

# Success: replace the checked-in output.
# (ada/tests also holds hand-written children of generated packages, the
# wuffs-std-*-probe.ads files: only the generated test packages go.)
rm -f ada/gen/*.ads ada/gen/*.adb
for f in "$tmp"/tests/*; do
    rm -f "ada/tests/$(basename "$f")"
done
cp "$tmp"/gen/* ada/gen/
cp "$tmp"/tests/* ada/tests/
