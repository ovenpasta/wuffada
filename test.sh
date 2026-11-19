#!/bin/sh
# Regenerates the Ada code, builds it in both profiles and runs every test.
# Exits non-zero on the first failure. Needs Go, a C compiler (cc, for the
# cross-check against upstream's C back-end), Alire (alr) with the project's
# GNAT toolchain, and the Wuffs checkout at ./wuffs.
set -eu
cd "$(dirname "$0")"

say() { printf '\n==== %s\n' "$*"; }
die() { printf 'test.sh: FAIL: %s\n' "$*" >&2; exit 1; }

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

say "Go: build, vet, gofmt"
go build ./...
go vet ./...
unformatted="$(gofmt -l cmd internal ada/tests)"
[ -z "$unformatted" ] || die "gofmt wants to reformat: $unformatted"

say "Generate (twice: the output must not change)"
./gen.sh
mkdir "$tmp/first"
cp ada/gen/*.ad[sb] ada/tests/wuffs-std-*.ad[sb] "$tmp/first"
./gen.sh
for f in "$tmp"/first/*; do
    name="$(basename "$f")"
    if [ -f "ada/gen/$name" ]; then
        cmp "$f" "ada/gen/$name" || die "non-deterministic output: $name"
    else
        cmp "$f" "ada/tests/$name" || die "non-deterministic output: $name"
    fi
done
ls -l ada/gen

say "Go: test"
go test ./...

# The independent expectations: Adler-32 and CRC-32 from Go's standard
# library, for every file at the top level of Wuffs' test data.
find wuffs/test/data -maxdepth 1 -type f | LC_ALL=C sort > "$tmp/files"
xargs go run ./ada/tests/hashexpect < "$tmp/files" > "$tmp/manifest"
nfiles="$(wc -l < "$tmp/manifest" | tr -d ' ')"
[ "$nfiles" -ge 100 ] || die "only $nfiles test data files found"

say "Cross-check: what upstream's C back-end computes for m1test"
ada/tests/crosscheck/run.sh > "$tmp/m1.c.trace"
echo "$(wc -l < "$tmp/m1.c.trace" | tr -d ' ') values traced from C"
[ -s "$tmp/m1.c.trace" ] || die "empty C trace"

if grep -l 'pragma Warnings' ada/gen/*.ad[sb]; then
    die "ada/gen suppresses warnings"
fi

for profile in checked release; do
    say "Ada: build, profile $profile (forced, so that every warning shows)"
    (cd ada && alr exec -- gprbuild -f -P wuffs_gen.gpr -XWUFFS_PROFILE="$profile") > "$tmp/build.$profile" 2>&1 ||
        { cat "$tmp/build.$profile"; die "build failed ($profile)"; }
    grep -v '^ *\[' "$tmp/build.$profile" || true
    nwarn="$(grep -c -i -E 'warning|\(style\)' "$tmp/build.$profile" || true)"
    echo "warnings and style messages ($profile): $nwarn"
    [ "$nwarn" -eq 0 ] || die "the $profile build has warnings"

    say "Ada: constants are read-only data ($profile)"
    nm "ada/obj/gen/$profile/wuffs-std-crc32.o" | grep -i ' r wuffs__std__crc32__ieee_table$' ||
        die "IEEE_TABLE is not in a read-only section"

    say "Ada: stack frames ($profile): the largest in generated code and its runtime glue"
    cat "ada/obj/gen/$profile"/wuffs-std-*.su "ada/obj/gen/$profile"/wuffs-runtime*.su > "$tmp/su"
    if grep -v 'static$' "$tmp/su"; then
        die "a frame's size is not static"
    fi
    sort -t "$(printf '\t')" -k2,2nr "$tmp/su" | head -n 5
    awk -F '\t' '$2 > 8192 { bad = 1; print } END { exit bad }' "$tmp/su" || die "a frame exceeds 8192 bytes"

    say "Ada: run tests ($profile)"
    ada/bin/test_runtime || die "test_runtime ($profile)"
    ada/bin/test_m1 > "$tmp/m1.out" || { cat "$tmp/m1.out"; die "test_m1 ($profile)"; }
    grep -v '^= ' "$tmp/m1.out"
    grep '^= ' "$tmp/m1.out" > "$tmp/m1.ada.trace" || true
    diff "$tmp/m1.c.trace" "$tmp/m1.ada.trace" ||
        die "test_m1's values differ from upstream's C ($profile)"
    echo "test_m1: trace is identical to upstream's C"
    ada/bin/test_hashers < "$tmp/manifest" > "$tmp/hashers.out" || { cat "$tmp/hashers.out"; die "test_hashers ($profile)"; }
    cat "$tmp/hashers.out"
    grep -q "^test_hashers: files checked: $nfiles\$" "$tmp/hashers.out" ||
        die "test_hashers did not check all $nfiles files ($profile)"
done

say "ALL PASS"
