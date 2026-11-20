#!/bin/sh
# Regenerates fuzz_cases.txt: the calls of the differential fuzz test
# (gen.py, fixed seeds) together with what upstream Wuffs' C does for each
# (cfuzz.c).  bin/ycck_fuzz < fuzz_cases.txt then checks that the Ada
# library does the same.
#
# As ../oracle/regen.sh, the C side is built four times with ASan and
# UBSan (gcc and clang, each scalar and SIMD); the four outputs must be
# identical, or this script fails without writing anything.
#
# Usage: ./regen.sh [path/to/wuffs checkout]   (default: ../../../wuffs)
# Environment: GCC (default gcc), CLANG (default clang).
set -eu
here=$(cd "$(dirname "$0")" && pwd)
wuffs=${1:-$here/../../../wuffs}
cfile=$wuffs/release/c/wuffs-unsupported-snapshot.c
gcc=${GCC:-gcc}
clang=${CLANG:-clang}
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
{
  python3 "$here/gen.py" 9001 4000 mix
  python3 "$here/gen.py" 9002 4000 mix
  python3 "$here/gen.py" 9003 4000 mix
  python3 "$here/gen.py" 9004 1500 wide
} > "$tmp/cases.txt"
flags="-std=c99 -O2 -Wall -Wno-unused-function -Wno-attributes -fsanitize=address,undefined -fno-sanitize-recover=all"
for cc in "$gcc" "$clang"; do
  name=$(basename "$cc")
  "$cc" $flags -DWUFFS_CONFIG__AVOID_CPU_ARCH -DWUFFS_C_FILE="\"$cfile\"" -o "$tmp/$name-scalar" "$here/cfuzz.c"
  "$cc" $flags -DWUFFS_C_FILE="\"$cfile\"" -o "$tmp/$name-simd" "$here/cfuzz.c"
  "$tmp/$name-scalar" < "$tmp/cases.txt" > "$tmp/$name-scalar.out"
  "$tmp/$name-simd" < "$tmp/cases.txt" > "$tmp/$name-simd.out"
done
ref=$tmp/$(basename "$gcc")-scalar.out
status=0
for out in "$tmp"/*.out; do
  if ! cmp -s "$ref" "$out"; then
    echo "$(basename "$out" .out) disagrees with $(basename "$ref" .out):" >&2
    diff "$ref" "$out" | head -20 >&2 || true
    status=1
  fi
done
if [ $status -ne 0 ]; then
  exit 1
fi
cp "$ref" "$here/fuzz_cases.txt"
echo "wrote $here/fuzz_cases.txt: $(wc -l < "$ref") cases (gcc scalar, gcc simd, clang scalar, clang simd agree)"
awk '{ n[$38]++ } END { for (s in n) print "  status " s ": " n[s] }' "$ref"
