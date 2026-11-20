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
# LIMITATION: by default the image corpus is REDUCED, to every run that has
# reference pixels and every ninth of the others, so "SURVIVED" here does
# not mean that ./test.sh, which runs all of it, misses the fault. Set
# MUTATION_FULL=1 to use the whole corpus (slower).
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

mkdir "$scratch/corpus"
go run ./ada/tests/imgcorpus -data wuffs/test/data -out "$scratch/corpus" -chaos "$scratch/chaos.manifest" \
    2> /dev/null > "$scratch/full.manifest"
if [ "${MUTATION_FULL:-}" = 1 ]; then
    cp "$scratch/full.manifest" "$scratch/manifest"
else
    awk '{ if ($7 != "-" || NR % 9 == 0) print }' "$scratch/full.manifest" > "$scratch/manifest"
fi
ada/tests/crosscheck/run_image.sh < "$scratch/manifest" > "$scratch/c.trace"
ada/tests/crosscheck/run.sh > "$scratch/m1.c.trace"
ada/tests/crosscheck/run_adv.sh > "$scratch/adv.c.trace"
mkdir "$scratch/dcorpus"
go run ./ada/tests/corpus -data wuffs/test/data -out "$scratch/dcorpus" 2> /dev/null > "$scratch/decode.manifest"
ada/tests/crosscheck/run_decode.sh < "$scratch/decode.manifest" > "$scratch/decode.c.trace"
find wuffs/test/data -maxdepth 1 -type f | LC_ALL=C sort | xargs go run ./ada/tests/hashexpect2 > "$scratch/manifest2"
echo "$(wc -l < "$scratch/manifest" | tr -d ' ') image runs and $(wc -l < "$scratch/chaos.manifest" | tr -d ' ') chaos runs per mutant"

save() {
    tar cf "$scratch/saved.tar" internal/adagen ada/src/runtime ada/gen ada/tests/wuffs-std-m1test.ads \
        ada/tests/wuffs-std-m1test.adb ada/tests/wuffs-std-advtest.ads ada/tests/wuffs-std-advtest.adb
}

restore() {
    rm -rf internal/adagen ada/src/runtime ada/gen
    tar xf "$scratch/saved.tar"
}

# check NAME PROFILE: builds and tests the tree as it is; prints one line.
check() {
    name="$1"
    # MUTATION_PROFILE, if set, replaces every mutant's own profile.
    profile="${MUTATION_PROFILE:-$2}"
    log="$scratch/$name.log"
    if ! (cd ada && alr exec -- gprbuild -P wuffs_gen.gpr -XWUFFS_PROFILE="$profile" test_runtime.adb \
        test_m1.adb test_adv.adb test_hostile.adb test_entry.adb test_image.adb test_hashers2.adb \
        test_decode.adb) >> "$log" 2>&1; then
        echo "$name: killed by the Ada build (an error or a warning)"; return
    fi
    killers=""
    if ! go test ./internal/adagen \
        -run 'TestRejects|TestCheckCalls|TestEntryChecks|TestBulk|TestRowPointer|TestSwizzleYCCK|TestStatusField|TestChoosyRefined' \
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
    if [ -z "$killers" ]; then
        if python3 ada/tests/mutants.py why "$name" > /dev/null 2>&1; then
            echo "$name: SURVIVED (a known equivalent mutant: see ada/tests/mutants.py)"
        else
            echo "$name: SURVIVED"
        fi
    else
        echo "$name: killed by$killers"
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
