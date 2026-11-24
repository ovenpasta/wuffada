#!/bin/sh
# A mutation check for the generator, the runtime shell and the tests: it
# applies one deliberate fault at a time (ada/tests/mutants.py) to a scratch
# copy of this tree and reports which test, if any, notices.
#
# usage: ada/tests/mutation.sh SCRATCH_DIR [NAMES]
#
# SCRATCH_DIR must not exist; it is left in place, with a log per mutant
# (remove it afterwards: it holds a copy of the tree, two build trees and
# the image corpus, a few hundred megabytes). NAMES, if given, is an
# extended regular expression: only the mutants whose names match are run.
# Nothing in this tree is changed. It is not part of ./test.sh (a mutant
# takes two to five minutes).
#
# Each mutant is built with its profile ("checked" for most) and tested with
# the generator's reject tests, test_runtime, test_m1, test_adv (compared
# with upstream's C), test_hostile,
# test_entry, test_hashers2, test_decode (compared with upstream's C),
# test_image over the chaos manifest, and test_image over the image corpus,
# compared with upstream's C. MUTATION_PROFILE=release (or checked) overrides
# the profile of every mutant.
#
# Every mutant is also tested with test_tokens over the token corpus
# (compared with upstream's C, with tokcheck's independent references and
# with chaos runs) and test_tokadv (compared with upstream's C). With
# MUTATION_TOKENS=1 only the token tests, test_runtime, test_m1, test_adv,
# test_hostile, test_entry and the Go tests are run (for the json/cbor
# mutants T01 .. T17), not the image, decompressor and hasher stages.
#
# With MUTATION_SIMD=1 (for the SIMD mutants S01 .. S16) the tests are
# instead those of a SIMD build: the generator's tests (rejects and SIMD),
# test_x86 (the wrappers against the C oracle), check_selection.sh
# (test_simd: CPU detection against __builtin_cpu_supports and the
# selection with every feature hidden in turn), test_hashers and
# test_hashers2 (every chunk size and alignment), test_decode and test_image
# (the reduced corpus, see below), compared with upstream's DEFAULT C build.
#
# LIMITATION: by default the image corpus is REDUCED, to every run that has
# reference pixels and every ninth of the others, so "SURVIVED" here does
# not mean that ./test.sh, which runs all of it, misses the fault. Set
# MUTATION_FULL=1 to use the whole corpus (slower). MUTATION_FORMATS (say
# 'webp|vp8') keeps only those formats' image runs, for mutants that only
# they can notice. Needs libwebp, as test.sh does.
set -eu
[ $# -eq 1 ] || [ $# -eq 2 ] || { echo "usage: $0 SCRATCH_DIR [NAMES]" >&2; exit 2; }
only="${2:-.}"
root="$(cd "$(dirname "$0")/../.." && pwd)"
scratch="$1"
[ ! -e "$scratch" ] || { echo "$scratch exists" >&2; exit 2; }
mkdir -p "$scratch"
scratch="$(cd "$scratch" && pwd)"

copy="$scratch/tree"
mkdir "$copy"
(cd "$root" && tar cf - --exclude=./wuffs --exclude=./ada/obj --exclude=./ada/bin --exclude=./.git \
    --exclude=./examples/obj --exclude=./examples/bin --exclude=./bin .) | (cd "$copy" && tar xf -)
ln -s "$root/wuffs" "$copy/wuffs"
cd "$copy"

tokens_only="${MUTATION_TOKENS:-}"
simd_only="${MUTATION_SIMD:-}"
# Outside the SIMD mode the traces come from upstream's SCALAR C, so the Ada
# tests must run their scalar implementations too: on a CPU with AVX2 the
# SIMD JPEG IDCT differs from the scalar one on damaged files, and every
# mutant would then look "killed by test_image(trace-vs-C)".
if [ "$simd_only" != 1 ]; then
    WUFFS_TEST_CPU_DISABLE=all
    export WUFFS_TEST_CPU_DISABLE
fi
if [ "$simd_only" = 1 ]; then
    mkdir "$scratch/corpus" "$scratch/webpref" "$scratch/dcorpus"
    "${CC:-cc}" -std=c99 -O2 -Wall -o "$scratch/webpref.bin" ada/tests/crosscheck/webpref.c -lwebpdemux -lwebp
    find wuffs/test/data ada/tests/webpcorpus -name '*.webp' | LC_ALL=C sort |
        "$scratch/webpref.bin" "$scratch/webpref" > "$scratch/webpref/list.out"
    go run ./ada/tests/imgcorpus -data wuffs/test/data -out "$scratch/corpus" -chaos "$scratch/chaos.manifest" \
        -webpref "$scratch/webpref" 2> /dev/null > "$scratch/full.manifest"
    awk '{ if ($7 != "-" || NR % 9 == 0) print }' "$scratch/full.manifest" > "$scratch/manifest"
    ada/tests/crosscheck/run_image.sh default < "$scratch/manifest" > "$scratch/c.trace"
    go run ./ada/tests/corpus -data wuffs/test/data -out "$scratch/dcorpus" 2> /dev/null > "$scratch/decode.manifest"
    ada/tests/crosscheck/run_decode.sh < "$scratch/decode.manifest" > "$scratch/decode.c.trace"
    find wuffs/test/data -maxdepth 1 -type f | LC_ALL=C sort > "$scratch/files"
    xargs go run ./ada/tests/hashexpect < "$scratch/files" > "$scratch/manifest1"
    xargs go run ./ada/tests/hashexpect2 < "$scratch/files" > "$scratch/manifest2"
    echo "$(wc -l < "$scratch/manifest" | tr -d ' ') image runs per mutant (SIMD mode)"
else
mkdir "$scratch/tokcorpus"
go run ./ada/tests/tokcorpus -data wuffs/test/data -out "$scratch/tokcorpus" > "$scratch/tokens.manifest"
ada/tests/crosscheck/run_tokens.sh < "$scratch/tokens.manifest" > "$scratch/tokens.c.trace"
ada/tests/crosscheck/run_tokadv.sh > "$scratch/tokadv.c.trace"
ada/tests/crosscheck/run.sh > "$scratch/m1.c.trace"
ada/tests/crosscheck/run_adv.sh > "$scratch/adv.c.trace"
echo "$(wc -l < "$scratch/tokens.manifest" | tr -d ' ') token decoder cases per mutant"
if [ "$tokens_only" != 1 ]; then
mkdir "$scratch/corpus" "$scratch/webpref"
"${CC:-cc}" -std=c99 -O2 -Wall -o "$scratch/webpref.bin" ada/tests/crosscheck/webpref.c -lwebpdemux -lwebp
find wuffs/test/data ada/tests/webpcorpus -name '*.webp' | LC_ALL=C sort |
    "$scratch/webpref.bin" "$scratch/webpref" > "$scratch/webpref/list.out"
go run ./ada/tests/imgcorpus -data wuffs/test/data -out "$scratch/corpus" -chaos "$scratch/chaos.all" \
    -webpref "$scratch/webpref" 2> /dev/null > "$scratch/full.all"
# MUTATION_FORMATS (an extended regular expression), if set, keeps only the
# image runs (and chaos runs) of the formats that it matches.
awk -v f="^(${MUTATION_FORMATS:-.*})\$" '$1 ~ f' "$scratch/full.all" > "$scratch/full.manifest"
awk -v f="^(${MUTATION_FORMATS:-.*})\$" '$1 ~ f' "$scratch/chaos.all" > "$scratch/chaos.manifest"
if [ "${MUTATION_FULL:-}" = 1 ]; then
    cp "$scratch/full.manifest" "$scratch/manifest"
else
    awk '{ if ($7 != "-" || NR % 9 == 0) print }' "$scratch/full.manifest" > "$scratch/manifest"
fi
ada/tests/crosscheck/run_image.sh < "$scratch/manifest" > "$scratch/c.trace"
mkdir "$scratch/dcorpus"
go run ./ada/tests/corpus -data wuffs/test/data -out "$scratch/dcorpus" 2> /dev/null > "$scratch/decode.manifest"
ada/tests/crosscheck/run_decode.sh < "$scratch/decode.manifest" > "$scratch/decode.c.trace"
find wuffs/test/data -maxdepth 1 -type f | LC_ALL=C sort | xargs go run ./ada/tests/hashexpect2 > "$scratch/manifest2"
echo "$(wc -l < "$scratch/manifest" | tr -d ' ') image runs and $(wc -l < "$scratch/chaos.manifest" | tr -d ' ') chaos runs per mutant"
fi
fi

save() {
    tar cf "$scratch/saved.tar" internal/adagen ada/src/runtime ada/src/simd ada/gen ada/tests/wuffs-std-m1test.ads \
        ada/tests/wuffs-std-m1test.adb ada/tests/wuffs-std-advtest.ads ada/tests/wuffs-std-advtest.adb \
        ada/tests/wuffs-std-tokadv.ads ada/tests/wuffs-std-tokadv.adb
}

restore() {
    rm -rf internal/adagen ada/src/runtime ada/src/simd ada/gen
    tar xf "$scratch/saved.tar"
}

# check_simd NAME PROFILE: the SIMD mode of check.
check_simd() {
    name="$1"
    profile="${MUTATION_PROFILE:-$2}"
    log="$scratch/$name.log"
    if ! (cd ada && alr exec -- gprbuild -P wuffs_gen.gpr -XWUFFS_PROFILE="$profile" test_x86.adb test_simd.adb \
        test_hashers.adb test_hashers2.adb test_decode.adb test_image.adb) >> "$log" 2>&1; then
        echo "$name: killed by the Ada build (an error or a warning)"; return
    fi
    killers=""
    if ! go test ./internal/adagen -run 'TestRejects|SIMD|X86' >> "$log" 2>&1; then
        killers="$killers go-test"
    fi
    if ! (ulimit -s 256 && timeout 600 ada/bin/test_x86) >> "$log" 2>&1; then
        killers="$killers test_x86"
    fi
    if ! (ulimit -s 256 && timeout 600 ada/tests/simd/check_selection.sh ada/bin/test_simd) >> "$log" 2>&1; then
        killers="$killers check_selection"
    fi
    if ! (ulimit -s 256 && timeout 600 ada/bin/test_hashers < "$scratch/manifest1") >> "$log" 2>&1; then
        killers="$killers test_hashers"
    fi
    if ! (ulimit -s 256 && timeout 600 ada/bin/test_hashers2 < "$scratch/manifest2") >> "$log" 2>&1; then
        killers="$killers test_hashers2"
    fi
    if ! (ulimit -s 256 && timeout 900 ada/bin/test_decode < "$scratch/decode.manifest") > "$scratch/decode.out" 2>> "$log"; then
        killers="$killers test_decode(checks)"
    fi
    if ! grep '^= ' "$scratch/decode.out" | cmp -s - "$scratch/decode.c.trace"; then
        killers="$killers test_decode(trace-vs-C)"
    fi
    if ! (ulimit -s 256 && timeout 1800 ada/bin/test_image < "$scratch/manifest") > "$scratch/image.out" 2>> "$log"; then
        killers="$killers test_image(checks)"
    fi
    grep -v '^= ' "$scratch/image.out" | tail -n 3 >> "$log" || true
    grep '^= ' "$scratch/image.out" > "$scratch/ada.trace" || true
    if ! cmp -s "$scratch/c.trace" "$scratch/ada.trace"; then
        killers="$killers test_image(trace-vs-C)"
    fi
    report "$name" "$killers"
}

# check NAME PROFILE: builds and tests the tree as it is; prints one line.
check() {
    if [ "$simd_only" = 1 ]; then
        check_simd "$@"; return
    fi
    name="$1"
    # MUTATION_PROFILE, if set, replaces every mutant's own profile.
    profile="${MUTATION_PROFILE:-$2}"
    log="$scratch/$name.log"
    # (-m: a unit whose source ./gen.sh rewrote unchanged is not compiled
    # again, in the token mode, to save time.)
    minimal=""
    [ "$tokens_only" != 1 ] || minimal="-m"
    if ! (cd ada && alr exec -- gprbuild $minimal -P wuffs_gen.gpr -XWUFFS_PROFILE="$profile" test_runtime.adb \
        test_m1.adb test_adv.adb test_hostile.adb test_entry.adb test_image.adb test_hashers2.adb \
        test_decode.adb test_tokens.adb test_tokadv.adb) >> "$log" 2>&1; then
        echo "$name: killed by the Ada build (an error or a warning)"; return
    fi
    killers=""
    if ! go test ./internal/adagen \
        -run 'TestRejects|TestCheckCalls|TestEntryChecks|TestBulk|TestRowPointer|TestSwizzleYCCK|TestStatusField|TestChoosyRefined|TestPixelBlend|TestRangeAccessors|TestNullablePixelBuffer|TestTokenWriter|TestCheckCallsTokens' \
        >> "$log" 2>&1; then
        killers="$killers go-test"
    fi
    if ! (ulimit -s 256 && timeout 600 ada/bin/test_runtime) >> "$log" 2>&1; then
        killers="$killers test_runtime"
    fi
    if ! (ulimit -s 256 && timeout 600 ada/bin/test_m1) > "$scratch/m1.out" 2>> "$log" ||
        ! grep '^= ' "$scratch/m1.out" | cmp -s - "$scratch/m1.c.trace"; then
        killers="$killers test_m1"
    fi
    if ! (ulimit -s 256 && timeout 600 ada/bin/test_adv) > "$scratch/adv.out" 2>> "$log" ||
        ! grep '^= ' "$scratch/adv.out" | cmp -s - "$scratch/adv.c.trace"; then
        killers="$killers test_adv"
    fi
    if ! (ulimit -s 256 && timeout 600 ada/bin/test_hostile) >> "$log" 2>&1; then
        killers="$killers test_hostile"
    fi
    if ! (ulimit -s 256 && timeout 600 ada/bin/test_entry) >> "$log" 2>&1; then
        killers="$killers test_entry"
    fi
    rm -rf "$scratch/tokdump"
    mkdir "$scratch/tokdump"
    if ! (echo "dump $scratch/tokdump"; echo chaos; cat "$scratch/tokens.manifest") |
        (ulimit -s 256 && timeout 900 ada/bin/test_tokens) > "$scratch/tokens.out" 2>> "$log"; then
        killers="$killers test_tokens(checks)"
    fi
    grep -v '^= ' "$scratch/tokens.out" | tail -n 4 >> "$log" || true
    if ! grep '^= ' "$scratch/tokens.out" | cmp -s - "$scratch/tokens.c.trace"; then
        killers="$killers test_tokens(trace-vs-C)"
    fi
    if ! go run ./ada/tests/tokcheck "$scratch/tokdump" >> "$log" 2>&1; then
        killers="$killers tokcheck"
    fi
    if ! (ulimit -s 256 && timeout 600 ada/bin/test_tokadv) > "$scratch/tokadv.out" 2>> "$log" ||
        ! grep '^= ' "$scratch/tokadv.out" | cmp -s - "$scratch/tokadv.c.trace"; then
        killers="$killers test_tokadv"
    fi
    if [ "$tokens_only" = 1 ]; then
        report "$name" "$killers"; return
    fi
    if ! (ulimit -s 256 && timeout 600 ada/bin/test_hashers2 < "$scratch/manifest2") >> "$log" 2>&1; then
        killers="$killers test_hashers2"
    fi
    if ! (ulimit -s 256 && timeout 900 ada/bin/test_decode < "$scratch/decode.manifest") > "$scratch/decode.out" 2>> "$log"; then
        killers="$killers test_decode(checks)"
    fi
    if ! grep '^= ' "$scratch/decode.out" | cmp -s - "$scratch/decode.c.trace"; then
        killers="$killers test_decode(trace-vs-C)"
    fi
    if ! (ulimit -s 256 && timeout 900 ada/bin/test_image < "$scratch/chaos.manifest") > "$scratch/chaos.out" 2>> "$log"; then
        killers="$killers test_image(chaos)"
    fi
    grep -v '^= ' "$scratch/chaos.out" | tail -n 3 >> "$log" || true
    if ! (ulimit -s 256 && timeout 1800 ada/bin/test_image < "$scratch/manifest") > "$scratch/image.out" 2>> "$log"; then
        killers="$killers test_image(checks)"
    fi
    grep -v '^= ' "$scratch/image.out" | tail -n 3 >> "$log" || true
    grep '^= ' "$scratch/image.out" > "$scratch/ada.trace" || true
    if ! cmp -s "$scratch/c.trace" "$scratch/ada.trace"; then
        killers="$killers test_image(trace-vs-C)"
    fi
    report "$name" "$killers"
}

# report NAME KILLERS: prints the verdict.
report() {
    if [ -z "$2" ]; then
        if python3 ada/tests/mutants.py why "$1" > /dev/null 2>&1; then
            echo "$1: SURVIVED (a known equivalent mutant: see ada/tests/mutants.py)"
        else
            echo "$1: SURVIVED"
        fi
    else
        echo "$1: killed by$2"
    fi
}

if echo "00-unchanged" | grep -q -E "$only"; then
    : > "$scratch/00-unchanged.log"
    check "00-unchanged" checked
fi

python3 ada/tests/mutants.py list | while read -r name where profile equivalent; do
    echo "$name" | grep -q -E "$only" || continue
    log="$scratch/$name.log"
    : > "$log"
    save
    if [ "$where" = gen ]; then
        if ! python3 ada/tests/mutants.py apply "$name" >> "$log" 2>&1; then
            echo "$name: INVALID (the text to replace was not found)"
            restore
            continue
        fi
        check "$name" "$profile"
    else
        if ! python3 ada/tests/mutants.py apply "$name" >> "$log" 2>&1; then
            echo "$name: INVALID (the text to replace was not found)"
        elif ! go build -o bin/wuffs-ada ./cmd/wuffs-ada >> "$log" 2>&1; then
            echo "$name: INVALID (the generator does not compile)"
        elif ! ./gen.sh >> "$log" 2>&1; then
            echo "$name: killed by the generator (it reports an error)"
        else
            check "$name" "$profile"
        fi
    fi
    restore
done
echo "done"
