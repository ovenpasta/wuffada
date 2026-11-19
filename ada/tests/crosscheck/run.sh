#!/bin/sh
# Prints what upstream Wuffs' C back-end computes for the m1test package: the
# trace that ada/tests/test_m1.adb must reproduce (and where that program's
# expected values come from).
#
# It builds upstream's wuffs-c from the ./wuffs checkout, generates C from
# internal/adagen/testdata/m1test.wuffs, compiles that with m1test.c (in this
# directory) against wuffs/release/c/wuffs-unsupported-snapshot.c, and runs
# the result. Nothing is written outside of a temporary directory.
#
# usage: ada/tests/crosscheck/run.sh > expected-trace.txt
# Needs Go and a C compiler ($CC, default cc).
set -eu
here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/../../.." && pwd)"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

(cd "$root/wuffs" && go build -o "$tmp/wuffs-c" ./cmd/wuffs-c)
"$tmp/wuffs-c" gen -package_name m1test "$root/internal/adagen/testdata/m1test.wuffs" > "$tmp/m1test.gen.c"
cp "$root/wuffs/release/c/wuffs-unsupported-snapshot.c" "$tmp/wuffs-base.c"
cp "$here/m1test.c" "$tmp/m1test.c"
"${CC:-cc}" -std=c99 -O1 -Wall -o "$tmp/m1test" "$tmp/m1test.c"
"$tmp/m1test"
