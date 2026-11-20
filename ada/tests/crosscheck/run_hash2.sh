#!/bin/sh
# Prints what upstream's C hashers (xxhash32, xxhash64, crc64) compute for
# the files named on the command line, in the format of ada/tests/hashexpect2.
# Nothing is written outside of a temporary directory.
#
# usage: ada/tests/crosscheck/run_hash2.sh FILE...
set -eu
here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/../../.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
"${CC:-cc}" -std=c99 -O2 -Wall -I "$root/wuffs/release/c" -o "$tmp/hash2" "$here/hash2.c"
"$tmp/hash2" "$@"
