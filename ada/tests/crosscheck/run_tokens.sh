#!/bin/sh
# Prints the trace of upstream Wuffs' C token decoders (json, cbor) over a
# corpus: what ada/tests/test_tokens.adb must reproduce line for line.
#
# It compiles tokens.c (in this directory) against
# wuffs/release/c/wuffs-unsupported-snapshot.c, builds the table that maps C
# status strings to Ada status codes from the Ada sources, and runs the
# result. Nothing is written outside of a temporary directory.
#
# usage: ada/tests/crosscheck/run_tokens.sh < MANIFEST > c-trace.txt
# MANIFEST is the output of ada/tests/tokcorpus. Needs Go and a C compiler
# ($CC, default cc).
set -eu
here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/../../.." && pwd)"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

(cd "$root" && go run ./ada/tests/crosscheck/statustable \
    ada/src/base/wuffs-base.ads ada/gen/wuffs-std-*.ads) > "$tmp/statuses"
"${CC:-cc}" -std=c99 -O2 -Wall -I "$root/wuffs/release/c" -o "$tmp/tokens" "$here/tokens.c"
"$tmp/tokens" "$tmp/statuses"
