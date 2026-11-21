#!/bin/sh
# A performance baseline (a report, not a test; not part of ./test.sh): the
# generated Ada decoders, release profile, against upstream's C, for CRC-32
# and Adler-32 of a 4 MiB buffer, gzip decompression of a few megabytes, and
# decoding the largest PNGs, the largest GIF, the largest JPEGs and the
# largest lossy and lossless WebPs of wuffs/test/data to BGRA_PREMUL, and
# tokenising the three largest JSON files there.
#
# usage: ada/tests/bench/run.sh
#
# Four builds are timed, each measurement the fastest of several runs:
#   ada-scalar the project's release profile (-O2 -gnatp), built without SIMD
#              (-XWUFFS_SIMD=off)
#   ada-simd   the same with SIMD (the default), with the library's own CPU
#              detection (-XWUFFS_TEST_CPU=native)
#   c-scalar   upstream's C, cc -O2 -DWUFFS_CONFIG__AVOID_CPU_ARCH
#   c-simd     upstream's C, cc -O2 (its SIMD code paths enabled)
# It prints a table (nanoseconds per input byte, and for images also
# milliseconds per image) with the ratios ada-scalar/c-scalar and
# ada-simd/c-simd, and fails if ada-scalar and c-scalar, or ada-simd and
# c-simd, do not compute the same results.
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
    echo "crc64 30 $tmp/buffer.bin"
    echo "gzip 10 $tmp/data.gz"
    ls -S wuffs/test/data/*.png | head -n 4 | sed 's/^/png 10 /'
    ls -S wuffs/test/data/*.gif | head -n 1 | sed 's/^/gif 20 /'
    ls -S wuffs/test/data/*.jpeg | head -n 3 | sed 's/^/jpeg 10 /'
    ls -S wuffs/test/data/*.lossy.webp | head -n 1 | sed 's/^/webp 10 /'
    ls -S wuffs/test/data/*.lossless.webp | head -n 1 | sed 's/^/webp 10 /'
    ls -S wuffs/test/data/*.json | head -n 3 | sed 's/^/json 50 /'
} > "$tmp/list"

(cd ada && alr exec -- gprbuild -q -P wuffs_gen.gpr -XWUFFS_PROFILE=release -XWUFFS_SIMD=off bench_main.adb)
(cd ada && alr exec -- gprbuild -q -P wuffs_gen.gpr -XWUFFS_PROFILE=release -XWUFFS_TEST_CPU=native bench_main.adb)
"${CC:-cc}" -std=c99 -O2 -DWUFFS_CONFIG__AVOID_CPU_ARCH -I wuffs/release/c -o "$tmp/c-scalar" ada/tests/bench/bench.c
"${CC:-cc}" -std=c99 -O2 -I wuffs/release/c -o "$tmp/c-simd" ada/tests/bench/bench.c

ada/bin/scalar/bench_main < "$tmp/list" > "$tmp/ada-scalar.out"
ada/bin/native/bench_main < "$tmp/list" > "$tmp/ada-simd.out"
"$tmp/c-scalar" < "$tmp/list" > "$tmp/c-scalar.out"
"$tmp/c-simd" < "$tmp/list" > "$tmp/c-simd.out"

filter='{ print $1, $2, $3, $5 }'
for pair in "ada-scalar c-scalar" "ada-simd c-simd"; do
    set -- $pair
    if ! awk "$filter" "$tmp/$1.out" | cmp -s - "$(awk "$filter" "$tmp/$2.out" > "$tmp/cmp"; echo "$tmp/cmp")"; then
        echo "bench: the results of $1 and $2 differ" >&2
        exit 1
    fi
done
echo "results (checksums of everything computed): ada-scalar = c-scalar, ada-simd = c-simd"
echo
printf '%-8s %-28s %9s | %10s %8s %8s %8s | %9s %9s\n' kind input bytes ada-scalar ada-simd c-scalar c-simd ada/c:sc ada/c:simd
echo "(ns per input byte; for images, ms per image in the second line)"
paste -d ' ' "$tmp/ada-scalar.out" "$tmp/ada-simd.out" "$tmp/c-scalar.out" "$tmp/c-simd.out" |
    awk '{
        n = split($2, parts, "/"); name = parts[n]; bytes = $3
        a = $4; o = $9; s = $14; v = $19
        printf "%-8s %-28s %9d | %10.3f %8.3f %8.3f %8.3f | %9.2f %9.2f\n",
            $1, substr(name, 1, 28), bytes, a / bytes, o / bytes, s / bytes, v / bytes, a / s, o / v
        if ($1 == "png" || $1 == "gif" || $1 == "jpeg" || $1 == "webp")
            printf "%-8s %-28s %9s | %10.2f %8.2f %8.2f %8.2f |\n", "", "  ms per image", "", a / 1e6, o / 1e6, s / 1e6, v / 1e6
    }'
