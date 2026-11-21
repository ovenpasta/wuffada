#!/bin/sh
# Prints the trace of upstream Wuffs' C decoders (lzw, deflate, zlib, gzip)
# over a corpus: what ada/tests/test_decode.adb must reproduce line for line.
#
# It compiles decode.c (in this directory) against
# wuffs/release/c/wuffs-unsupported-snapshot.c, builds the table that maps
# C status strings to Ada status codes from the Ada sources, and runs the
# result. Nothing is written outside of a temporary directory.
#
# usage: ada/tests/crosscheck/run_decode.sh [force32|scalar] < MANIFEST > c-trace.txt
# MANIFEST is the output of ada/tests/corpus. Needs Go and a C compiler ($CC,
# default cc).
#
# With "force32", the C is built as if for a 32-bit machine in the one
# respect that Wuffs code can ask about (base.utility.cpu_arch_is_32_bit, in
# C "sizeof(void*) == 4"), to match an Ada build with
# -XWUFFS_TEST_TARGET=force32: std/deflate then takes its
# decode_huffman_fast32 path.
#
# By default the C is built as it comes (on x86-64, std/deflate's BMI2
# implementation is selected at run time), which a SIMD Ada build must
# match; with "scalar", with -DWUFFS_CONFIG__AVOID_CPU_ARCH (upstream's
# scalar build), which a SIMD-off Ada build must match. (std/deflate's BMI2
# implementation is the same code as its fast64 one, so the two traces are
# the same.)
set -eu
here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/../../.." && pwd)"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

(cd "$root" && go run ./ada/tests/crosscheck/statustable \
    ada/src/base/wuffs-base.ads ada/gen/wuffs-std-*.ads ada/gen/scalar/wuffs-std-*.ads) > "$tmp/statuses"
cp "$root/wuffs/release/c/wuffs-unsupported-snapshot.c" "$tmp/wuffs-unsupported-snapshot.c"
if [ "${1:-}" = force32 ]; then
    n="$(grep -c 'sizeof(void\*) == 4u' "$tmp/wuffs-unsupported-snapshot.c")"
    [ "$n" -ge 1 ] || { echo "run_decode.sh: nothing to force" >&2; exit 1; }
    sed -i 's/sizeof(void\*) == 4u/sizeof(void*) != 4u/' "$tmp/wuffs-unsupported-snapshot.c"
fi
cpu_arch=
if [ "${1:-}" = scalar ]; then
    cpu_arch=-DWUFFS_CONFIG__AVOID_CPU_ARCH
fi
"${CC:-cc}" -std=c99 -O2 -Wall $cpu_arch -I "$tmp" -o "$tmp/decode" "$here/decode.c"
"$tmp/decode" "$tmp/statuses"
