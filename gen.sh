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

# A test-only package that exercises what the standard packages above do not
# (see the comment in the .wuffs file). Its driver is ada/tests/test_m1.adb.
gen "$tmp/tests" m1test internal/adagen/testdata/m1test.wuffs

# Success: replace the checked-in output.
rm -f ada/gen/*.ads ada/gen/*.adb ada/tests/wuffs-std-*.ads ada/tests/wuffs-std-*.adb
cp "$tmp"/gen/* ada/gen/
cp "$tmp"/tests/* ada/tests/
