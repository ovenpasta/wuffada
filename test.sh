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

# Every timed command below is a test run: a hang is a failure.
run_limit=900

say "Ada: the generator's golden outputs compile (zero warnings)"
mkdir "$tmp/golden"
for name in tiny coro; do
    cp "internal/adagen/testdata/$name.ads.golden" "$tmp/golden/wuffs-std-$name.ads"
    cp "internal/adagen/testdata/$name.adb.golden" "$tmp/golden/wuffs-std-$name.adb"
done
(cd ada && timeout "$run_limit" alr exec -- gprbuild -f -c -P wuffs_gen.gpr \
    -XWUFFS_EXTRA_SRC="$tmp/golden" -u wuffs-std-tiny.adb wuffs-std-coro.adb) > "$tmp/build.golden" 2>&1 ||
    { cat "$tmp/build.golden"; die "a golden output does not compile"; }
grep -v '^ *\[' "$tmp/build.golden" || true

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

say "Cross-check: what upstream's C back-end computes for advtest"
ada/tests/crosscheck/run_adv.sh > "$tmp/adv.c.trace"
echo "$(wc -l < "$tmp/adv.c.trace" | tr -d ' ') runs traced from C"
[ -s "$tmp/adv.c.trace" ] || die "empty C trace"

if grep -l 'pragma Warnings' ada/gen/wuffs-std-adler32.ad[sb] ada/gen/wuffs-std-crc32.ad[sb]; then
    die "adler32 or crc32 suppresses warnings"
fi

say "Corpus for the decoders (Go's compress/* as the independent implementation)"
mkdir "$tmp/corpus"
go run ./ada/tests/corpus -data wuffs/test/data -out "$tmp/corpus" > "$tmp/decode.manifest"
ncases="$(wc -l < "$tmp/decode.manifest" | tr -d ' ')"
echo "$ncases test cases"
[ "$ncases" -ge 500 ] || die "only $ncases decoder test cases"

say "Cross-check: upstream's C decoders over the corpus"
ada/tests/crosscheck/run_decode.sh < "$tmp/decode.manifest" > "$tmp/decode.c.trace"
echo "$(wc -l < "$tmp/decode.c.trace" | tr -d ' ') runs traced from C"
[ -s "$tmp/decode.c.trace" ] || die "empty C trace"

say "Cross-check: the same, with C built as if for a 32-bit machine"
ada/tests/crosscheck/run_decode.sh force32 < "$tmp/decode.manifest" > "$tmp/decode.c32.trace"
echo "$(wc -l < "$tmp/decode.c32.trace" | tr -d ' ') runs traced from C"
[ -s "$tmp/decode.c32.trace" ] || die "empty C trace"
cmp -s "$tmp/decode.c.trace" "$tmp/decode.c32.trace" ||
    echo "(the 32-bit trace differs from the 64-bit one, as expected where the fast paths consume input differently)"

# The tests run with a deliberately small main stack: the library must not
# need more (docs/DESIGN.md, "Stack and heap").
stack_kib=256

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
    # "dynamic,bounded" is a frame that pushes outgoing arguments; a plain
    # "dynamic" one would be unbounded.
    if grep -v -E '	(static|dynamic,bounded)$' "$tmp/su"; then
        die "a frame's size is not bounded"
    fi
    sort -t "$(printf '\t')" -k2,2nr "$tmp/su" | head -n 5
    awk -F '\t' '$2 > 8192 { bad = 1; print } END { exit bad }' "$tmp/su" || die "a frame exceeds 8192 bytes"

    say "Ada: run tests ($profile), with a ${stack_kib} KiB stack"
    (ulimit -s "$stack_kib" && timeout "$run_limit" ada/bin/test_runtime) || die "test_runtime ($profile)"

    (ulimit -s "$stack_kib" && timeout "$run_limit" ada/bin/test_m1) > "$tmp/m1.out" ||
        { cat "$tmp/m1.out"; die "test_m1 ($profile)"; }
    grep -v '^= ' "$tmp/m1.out"
    grep '^= ' "$tmp/m1.out" > "$tmp/m1.ada.trace" || true
    diff "$tmp/m1.c.trace" "$tmp/m1.ada.trace" ||
        die "test_m1's values differ from upstream's C ($profile)"
    echo "test_m1: trace is identical to upstream's C"

    (ulimit -s "$stack_kib" && timeout "$run_limit" ada/bin/test_adv) > "$tmp/adv.out" ||
        { grep -v '^= ' "$tmp/adv.out" | head -n 50; die "test_adv ($profile)"; }
    grep -v '^= ' "$tmp/adv.out"
    grep '^= ' "$tmp/adv.out" > "$tmp/adv.ada.trace" || true
    cmp "$tmp/adv.c.trace" "$tmp/adv.ada.trace" || {
        diff "$tmp/adv.c.trace" "$tmp/adv.ada.trace" | head -n 20
        die "test_adv's trace differs from upstream's C ($profile)"
    }
    echo "test_adv: trace ($(wc -l < "$tmp/adv.ada.trace" | tr -d ' ') lines) is identical to upstream's C"

    (ulimit -s "$stack_kib" && timeout "$run_limit" ada/bin/test_hashers < "$tmp/manifest") > "$tmp/hashers.out" ||
        { cat "$tmp/hashers.out"; die "test_hashers ($profile)"; }
    cat "$tmp/hashers.out"
    grep -q "^test_hashers: files checked: $nfiles\$" "$tmp/hashers.out" ||
        die "test_hashers did not check all $nfiles files ($profile)"

    (ulimit -s "$stack_kib" && timeout "$run_limit" ada/bin/test_decode < "$tmp/decode.manifest") > "$tmp/decode.out" ||
        { grep -v '^= ' "$tmp/decode.out" | head -n 50; die "test_decode ($profile)"; }
    grep -v '^= ' "$tmp/decode.out"
    grep -q "^test_decode: cases: $ncases," "$tmp/decode.out" ||
        die "test_decode did not run all $ncases cases ($profile)"
    grep '^= ' "$tmp/decode.out" > "$tmp/decode.ada.trace" || true
    cmp "$tmp/decode.c.trace" "$tmp/decode.ada.trace" || {
        diff "$tmp/decode.c.trace" "$tmp/decode.ada.trace" | head -n 20
        die "test_decode's trace differs from upstream's C ($profile)"
    }
    echo "test_decode: trace ($(wc -l < "$tmp/decode.ada.trace" | tr -d ' ') runs) is identical to upstream's C"

    say "Ada: the decoders again, built for a pretended 32-bit machine ($profile)"
    (cd ada && alr exec -- gprbuild -P wuffs_gen.gpr -XWUFFS_PROFILE="$profile" \
        -XWUFFS_TEST_TARGET=force32 test_decode.adb) > "$tmp/build32.$profile" 2>&1 ||
        { cat "$tmp/build32.$profile"; die "force32 build failed ($profile)"; }
    (ulimit -s "$stack_kib" && timeout "$run_limit" ada/bin/force32/test_decode < "$tmp/decode.manifest") > "$tmp/decode32.out" ||
        { grep -v '^= ' "$tmp/decode32.out" | head -n 50; die "test_decode, force32 ($profile)"; }
    grep -v '^= ' "$tmp/decode32.out"
    grep '^= ' "$tmp/decode32.out" > "$tmp/decode32.ada.trace" || true
    cmp "$tmp/decode.c32.trace" "$tmp/decode32.ada.trace" || {
        diff "$tmp/decode.c32.trace" "$tmp/decode32.ada.trace" | head -n 20
        die "test_decode's force32 trace differs from upstream's C ($profile)"
    }
    echo "test_decode, force32: trace ($(wc -l < "$tmp/decode32.ada.trace" | tr -d ' ') runs) is identical to upstream's C"
done

say "ALL PASS"
