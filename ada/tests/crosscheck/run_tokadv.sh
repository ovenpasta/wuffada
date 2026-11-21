#!/bin/sh
# Prints what upstream Wuffs' C back-end computes for the tokadv package
# (adversarial token-writer coroutines): the trace that
# ada/tests/test_tokadv.adb must reproduce line for line.
#
# It builds upstream's wuffs-c from the ./wuffs checkout, generates C from
# internal/adagen/testdata/tokadv.wuffs, compiles that with tokadv.c (in this
# directory) against wuffs/release/c/wuffs-unsupported-snapshot.c, and runs
# the result. Nothing is written outside of a temporary directory.
#
# usage: ada/tests/crosscheck/run_tokadv.sh > expected-trace.txt
# Needs Go and a C compiler ($CC, default cc).
set -eu
here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/../../.." && pwd)"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

(cd "$root/wuffs" && go build -o "$tmp/wuffs-c" ./cmd/wuffs-c)
"$tmp/wuffs-c" gen -package_name tokadv "$root/internal/adagen/testdata/tokadv.wuffs" > "$tmp/tokadv.gen.c"
cp "$root/wuffs/release/c/wuffs-unsupported-snapshot.c" "$tmp/wuffs-base.c"
cp "$here/tokadv.c" "$tmp/tokadv.c"
"${CC:-cc}" -std=c99 -O1 -Wall -o "$tmp/tokadv" "$tmp/tokadv.c"
"$tmp/tokadv"
