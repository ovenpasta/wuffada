#!/bin/sh
# Prints the trace of upstream Wuffs' C decoders (netpbm, bmp, gif, png, wbmp, nie, targa)
# over a corpus: what ada/tests/test_image.adb must reproduce line for line.
#
# It compiles image.c (in this directory) against
# wuffs/release/c/wuffs-unsupported-snapshot.c, builds the table that maps
# C status strings to Ada status codes from the Ada sources, and runs the
# result. Nothing is written outside of a temporary directory.
#
# usage: ada/tests/crosscheck/run_image.sh < MANIFEST > c-trace.txt
# MANIFEST is the output of ada/tests/imgcorpus. Needs Go and a C compiler ($CC,
# default cc).
set -eu
here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/../../.." && pwd)"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

(cd "$root" && go run ./ada/tests/crosscheck/statustable \
    ada/src/base/wuffs-base.ads ada/gen/wuffs-std-*.ads) > "$tmp/statuses"
cp "$root/wuffs/release/c/wuffs-unsupported-snapshot.c" "$tmp/wuffs-unsupported-snapshot.c"
# The scalar code paths: the Ada ports only those, and upstream's x86 AVX2
# paths for JPEG do not always give the same pixels as its scalar ones (on
# this corpus: only for corrupted files, 386 of 36760 JPEG runs; on every
# valid file they agree).
"${CC:-cc}" -std=c99 -O2 -Wall -DWUFFS_CONFIG__AVOID_CPU_ARCH -I "$tmp" -o "$tmp/image" "$here/image.c"
"$tmp/image" "$tmp/statuses"
