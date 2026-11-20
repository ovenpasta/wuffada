#!/bin/sh
# A performance baseline (a report, not a test; not part of ./test.sh): the
# generated Ada decoders, release profile, against upstream's C, for CRC-32
# and Adler-32 of a 4 MiB buffer, gzip decompression of a few megabytes, and
# decoding the largest PNGs, the largest GIF and the largest JPEGs of
# wuffs/test/data to BGRA_PREMUL.
#
# usage: ada/tests/bench/run.sh
#
# Four builds are timed, each measurement the fastest of several runs:
#   ada      the project's release profile (-O2 -gnatp), as committed
#   ada-O3   the same sources and switches with -O3 added on the command line
#            (in a temporary build tree; no project file is changed)
#   c-scalar upstream's C, cc -O2 -DWUFFS_CONFIG__AVOID_CPU_ARCH
#   c-simd   upstream's C, cc -O2 (its SIMD code paths enabled)
# It prints a table (nanoseconds per input byte, and for images also
# milliseconds per image) with the ratios ada/c-scalar and ada/c-simd, and
# fails if the four builds do not compute the same results.
set -eu
root="$(cd "$(dirname "$0")/../../.." && pwd)"
cd "$root"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

# The inputs.
head -c 4194304 wuffs/test/data/harvesters.bmp > "$tmp/buffer.bin" 2> /dev/null || true
if [ "$(wc -c < "$tmp/buffer.bin")" -lt 4194304 ]; then
    cat wuffs/test/data/*.bmp wuffs/test/data/*.png | head -c 4194304 > "$tmp/buffer.bin"
fi
cat wuffs/test/data/*.txt wuffs/test/data/*.bmp wuffs/test/data/*.json 2> /dev/null | head -c 12000000 | gzip -6 > "$tmp/data.gz"
[ "$(wc -c < "$tmp/data.gz")" -le 4194304 ] || { echo "bench: data.gz is too large" >&2; exit 1; }
{
    echo "crc32 30 $tmp/buffer.bin"
    echo "adler32 30 $tmp/buffer.bin"
    echo "gzip 10 $tmp/data.gz"
    ls -S wuffs/test/data/*.png | head -n 4 | sed 's/^/png 10 /'
    ls -S wuffs/test/data/*.gif | head -n 1 | sed 's/^/gif 20 /'
    ls -S wuffs/test/data/*.jpeg | head -n 3 | sed 's/^/jpeg 10 /'
} > "$tmp/list"

(cd ada && alr exec -- gprbuild -q -P wuffs_gen.gpr -XWUFFS_PROFILE=release bench_main.adb)
(cd ada && alr exec -- gprbuild -q -P wuffs_gen.gpr -XWUFFS_PROFILE=release \
    --relocate-build-tree="$tmp/o3" bench_main.adb -cargs -O3)
"${CC:-cc}" -std=c99 -O2 -DWUFFS_CONFIG__AVOID_CPU_ARCH -I wuffs/release/c -o "$tmp/c-scalar" ada/tests/bench/bench.c
"${CC:-cc}" -std=c99 -O2 -I wuffs/release/c -o "$tmp/c-simd" ada/tests/bench/bench.c

ada/bin/bench_main < "$tmp/list" > "$tmp/ada.out"
"$tmp/o3/bin/bench_main" < "$tmp/list" > "$tmp/ada-O3.out"
"$tmp/c-scalar" < "$tmp/list" > "$tmp/c-scalar.out"
"$tmp/c-simd" < "$tmp/list" > "$tmp/c-simd.out"

# (Upstream's x86 AVX2 code for JPEG does not always give the same pixels as
# its scalar code, which is what the Ada ports (in test.sh's corpus, only for
# corrupted files): JPEG results are compared with c-scalar only, and a
# difference from c-simd is reported.)
for other in ada-O3 c-scalar c-simd; do
    filter='{ print $1, $2, $3, $5 }'
    if [ "$other" = c-simd ]; then
        filter='$1 != "jpeg" { print $1, $2, $3, $5 }'
    fi
    if ! awk "$filter" "$tmp/ada.out" | cmp -s - "$(awk "$filter" "$tmp/$other.out" > "$tmp/cmp"; echo "$tmp/cmp")"; then
        echo "bench: the results of ada and $other differ" >&2
        exit 1
    fi
done
if ! awk '$1 == "jpeg" { print $2, $5 }' "$tmp/ada.out" | cmp -s - "$(awk '$1 == "jpeg" { print $2, $5 }' "$tmp/c-simd.out" > "$tmp/cmp"; echo "$tmp/cmp")"; then
    echo "(for JPEG, c-simd's pixels differ from c-scalar's and ada's, as expected)"
fi
echo "results (checksums of everything computed) are identical in all four builds (JPEG: but c-simd)"
echo
printf '%-8s %-28s %9s | %8s %8s %8s %8s | %7s %7s %7s\n' kind input bytes ada ada-O3 c-scalar c-simd ada/sc ada/simd O3/O2
echo "(ns per input byte; for png and gif, ms per image in the second line)"
paste -d ' ' "$tmp/ada.out" "$tmp/ada-O3.out" "$tmp/c-scalar.out" "$tmp/c-simd.out" |
    awk '{
        n = split($2, parts, "/"); name = parts[n]; bytes = $3
        a = $4; o = $9; s = $14; v = $19
        printf "%-8s %-28s %9d | %8.3f %8.3f %8.3f %8.3f | %7.2f %7.2f %7.2f\n",
            $1, substr(name, 1, 28), bytes, a / bytes, o / bytes, s / bytes, v / bytes, a / s, a / v, o / a
        if ($1 == "png" || $1 == "gif" || $1 == "jpeg")
            printf "%-8s %-28s %9s | %8.2f %8.2f %8.2f %8.2f |\n", "", "  ms per image", "", a / 1e6, o / 1e6, s / 1e6, v / 1e6
    }'
