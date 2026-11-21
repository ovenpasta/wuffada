#!/bin/sh
# Checks the run-time selection of the SIMD implementations with test_simd
# (a SIMD build with the test substitute of Wuffs.Runtime.CPU, ada/tests/cpu_env):
#
#  - its "cpu" lines (the library's CPUID detection) equal what GCC's
#    __builtin_cpu_supports says (cpu_c.c, combined as upstream combines the
#    features);
#  - with WUFFS_TEST_CPU_DISABLE unset, set to each feature and set to
#    "all", its "selected" lines say exactly the detected features minus the
#    disabled ones, and test_simd passes (it checks that every choose
#    statement picked the SIMD implementation exactly for those).
#
# usage: ada/tests/simd/check_selection.sh TEST_SIMD_BINARY   (from the repository's root)
set -eu
bin="$1"
here="$(cd "$(dirname "$0")" && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
"${CC:-cc}" -O2 -Wall -o "$tmp/cpu_c" "$here/cpu_c.c"
"$tmp/cpu_c" > "$tmp/cpu.c"
"$bin" > "$tmp/out" || { cat "$tmp/out"; echo "check_selection: test_simd failed" >&2; exit 1; }
grep '^cpu ' "$tmp/out" | cmp -s - "$tmp/cpu.c" || {
    diff "$tmp/cpu.c" "$tmp/out"; echo "check_selection: CPU detection differs from __builtin_cpu_supports" >&2; exit 1; }
cat "$tmp/cpu.c"
for disable in "" x86_sse42 x86_avx2 x86_bmi2 all; do
    WUFFS_TEST_CPU_DISABLE="$disable" "$bin" > "$tmp/out" ||
        { cat "$tmp/out"; echo "check_selection: test_simd failed with \"$disable\" disabled" >&2; exit 1; }
    for f in x86_sse42 x86_avx2 x86_bmi2; do
        want="$(grep "^cpu $f " "$tmp/cpu.c" | cut -d' ' -f3)"
        if [ "$disable" = all ] || [ "$disable" = "$f" ]; then want=0; fi
        grep -q "^selected $f $want\$" "$tmp/out" ||
            { cat "$tmp/out"; echo "check_selection: $f with \"$disable\" disabled: want $want" >&2; exit 1; }
    done
    echo "disabled \"$disable\": $(grep '^choice ' "$tmp/out" | cut -d' ' -f2- | tr '\n' ';')"
done
echo "check_selection: PASS"
