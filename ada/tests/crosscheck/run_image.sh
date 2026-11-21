#!/bin/sh
# Prints the trace of upstream Wuffs' C decoders (netpbm, bmp, gif, png, wbmp, nie, targa)
# over a corpus: what ada/tests/test_image.adb must reproduce line for line.
#
# It compiles image.c (in this directory) against
# wuffs/release/c/wuffs-unsupported-snapshot.c, builds the table that maps
# C status strings to Ada status codes from the Ada sources, and runs the
# result. Nothing is written outside of a temporary directory.
#
# usage: ada/tests/crosscheck/run_image.sh [scalar|default] < MANIFEST > c-trace.txt
# MANIFEST is the output of ada/tests/imgcorpus. Needs Go and a C compiler ($CC,
# default cc).
#
# "scalar" (the default) builds the C with -DWUFFS_CONFIG__AVOID_CPU_ARCH,
# upstream's scalar build, which a SIMD-off Ada build (or a SIMD build with
# every CPU feature hidden) must match; "default" builds it as it comes, with
# its SIMD implementations selected at run time (on x86-64: SSE4.2 PNG
# filters, the AVX2 JPEG IDCT), which a SIMD build must match. The two
# differ for some damaged JPEGs: see docs/DESIGN.md.
set -eu
case "${1:-scalar}" in
scalar) cpu_arch=-DWUFFS_CONFIG__AVOID_CPU_ARCH ;;
default) cpu_arch= ;;
*) echo "usage: run_image.sh [scalar|default]" >&2; exit 2 ;;
esac
here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/../../.." && pwd)"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

(cd "$root" && go run ./ada/tests/crosscheck/statustable \
    ada/src/base/wuffs-base.ads ada/gen/wuffs-std-*.ads ada/gen/scalar/wuffs-std-*.ads) > "$tmp/statuses"
cp "$root/wuffs/release/c/wuffs-unsupported-snapshot.c" "$tmp/wuffs-unsupported-snapshot.c"
# The scalar code paths: the Ada ports only those, and upstream's x86 AVX2
# paths for JPEG do not always give the same pixels as its scalar ones (on
# this corpus: only for corrupted files, 386 of 36760 JPEG runs; on every
# valid file they agree).
"${CC:-cc}" -std=c99 -O2 -Wall $cpu_arch -I "$tmp" -o "$tmp/image" "$here/image.c"
"$tmp/image" "$tmp/statuses"
