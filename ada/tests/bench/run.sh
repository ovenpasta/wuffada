#!/bin/sh
# A performance baseline (a report, not a test; not part of ./test.sh): the
# generated Ada decoders, release profile, against upstream's C: CRC-32,
# Adler-32 and CRC-64 of a 4 MiB buffer; gzip, bzip2, lzma and xz
# decompression of the same few megabytes; decoding the largest PNGs (plus an
# Adam7-interlaced and a 16-bit PNG made from harvesters.png, if python3 has
# PIL), the largest GIF, the largest JPEGs and the largest lossy and lossless
# WebPs of wuffs/test/data to BGRA_PREMUL; and tokenising the three largest
# JSON files there.
#
# usage: ada/tests/bench/run.sh
#
# Five builds are timed, each measurement the fastest of several runs, each
# program pinned to one CPU (taskset, if present):
#   ada-sc   the project's release profile (-O2 -gnatp), built without SIMD
#            (-XWUFFS_SIMD=off)
#   ada-simd the same with SIMD (the default), with the library's own CPU
#            detection (-XWUFFS_TEST_CPU=native)
#   gcc-sc   upstream's C, gcc -O2 -DWUFFS_CONFIG__AVOID_CPU_ARCH
#   clang-sc upstream's C, clang -O2 -DWUFFS_CONFIG__AVOID_CPU_ARCH
#   c-dflt   upstream's C, gcc -O2 (its SIMD code paths enabled)
# It prints a table (nanoseconds per input byte, and for images also
# milliseconds per image) with the ratios ada-sc/gcc-sc, ada-sc/clang-sc and
# ada-simd/c-dflt, and the spread: the largest (median / fastest - 1) of the
# five programs, in percent.  It fails if the scalar programs, or ada-simd
# and c-dflt, do not compute the same results.
#
# Environment:
#   BENCH_CPU=N        the CPU to pin to (default 3)
#   BENCH_ONLY=REGEX   only the measurements whose kind matches (grep -E)
#   BENCH_NOBUILD=1    do not build the Ada programs (use ada/bin/...)
#   BENCH_ADA_SC=PATH, BENCH_ADA_SIMD=PATH  other Ada programs to time
#   BENCH_REPS=K       multiply every repetition count by K
#   BENCH_SAVE=DIR     also keep the raw outputs and the table in DIR
#   BENCH_REUSE_C=DIR  take the three C programs' outputs from a BENCH_SAVE
#                      directory of an earlier run (same BENCH_ONLY and
#                      BENCH_REPS) instead of running them
set -eu
root="$(cd "$(dirname "$0")/../../.." && pwd)"
cd "$root"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
cpu="${BENCH_CPU:-3}"
k="${BENCH_REPS:-1}"
pin=""
if command -v taskset > /dev/null 2>&1; then
    pin="taskset -c $cpu"
fi

# The inputs.
head -c 4194304 wuffs/test/data/harvesters.bmp > "$tmp/buffer.bin" 2> /dev/null || true
if [ "$(wc -c < "$tmp/buffer.bin")" -lt 4194304 ]; then
    cat wuffs/test/data/*.bmp wuffs/test/data/*.png | head -c 4194304 > "$tmp/buffer.bin"
fi
cat wuffs/test/data/*.txt wuffs/test/data/*.bmp wuffs/test/data/*.json 2> /dev/null | head -c 12000000 > "$tmp/data"
gzip -6 < "$tmp/data" > "$tmp/data.gz"
bzip2 -9 < "$tmp/data" > "$tmp/data.bz2"
lzma -6 < "$tmp/data" > "$tmp/data.lzma"
xz -6 < "$tmp/data" > "$tmp/data.xz"
for f in data.gz data.bz2 data.lzma data.xz; do
    [ "$(wc -c < "$tmp/$f")" -le 4194304 ] || { echo "bench: $f is too large" >&2; exit 1; }
done
pngs=""
if python3 -c 'import PIL' 2> /dev/null; then
    python3 ada/tests/bench/mkpng.py wuffs/test/data/harvesters.png "$tmp/harvesters.adam7.png" \
        "$tmp/harvesters.16bit.png"
    pngs="$tmp/harvesters.adam7.png $tmp/harvesters.16bit.png"
else
    echo "bench: python3 has no PIL: no interlaced or 16-bit PNG" >&2
fi
{
    echo "crc32 30 $tmp/buffer.bin"
    echo "adler32 30 $tmp/buffer.bin"
    echo "crc64 30 $tmp/buffer.bin"
    echo "gzip 10 $tmp/data.gz"
    echo "bzip2 5 $tmp/data.bz2"
    echo "lzma 5 $tmp/data.lzma"
    echo "xz 5 $tmp/data.xz"
    ls -S wuffs/test/data/*.png | head -n 4 | sed 's/^/png 10 /'
    for p in $pngs; do echo "png 10 $p"; done
    ls -S wuffs/test/data/*.gif | head -n 1 | sed 's/^/gif 20 /'
    ls -S wuffs/test/data/*.jpeg | head -n 3 | sed 's/^/jpeg 10 /'
    ls -S wuffs/test/data/*.lossy.webp | head -n 1 | sed 's/^/webp 10 /'
    ls -S wuffs/test/data/*.lossless.webp | head -n 1 | sed 's/^/webp 10 /'
    ls -S wuffs/test/data/*.json | head -n 3 | sed 's/^/json 50 /'
} | awk -v k="$k" -v only="${BENCH_ONLY:-.}" '$1 ~ only { print $1, $2 * k, $3 }' > "$tmp/list"

if [ -z "${BENCH_NOBUILD:-}" ]; then
    (cd ada && alr exec -- gprbuild -q -P wuffs_gen.gpr -XWUFFS_PROFILE=release -XWUFFS_SIMD=off bench_main.adb)
    (cd ada && alr exec -- gprbuild -q -P wuffs_gen.gpr -XWUFFS_PROFILE=release -XWUFFS_TEST_CPU=native bench_main.adb)
fi
gcc -std=c99 -O2 -DWUFFS_CONFIG__AVOID_CPU_ARCH -I wuffs/release/c -o "$tmp/gcc-sc" ada/tests/bench/bench.c
clang -std=c99 -O2 -DWUFFS_CONFIG__AVOID_CPU_ARCH -I wuffs/release/c -o "$tmp/clang-sc" ada/tests/bench/bench.c
gcc -std=c99 -O2 -I wuffs/release/c -o "$tmp/c-dflt" ada/tests/bench/bench.c
cp "${BENCH_ADA_SC:-ada/bin/scalar/bench_main}" "$tmp/ada-sc"
cp "${BENCH_ADA_SIMD:-ada/bin/native/bench_main}" "$tmp/ada-simd"

echo "load before: $(cut -d ' ' -f 1-3 /proc/loadavg)"
progs="ada-sc ada-simd gcc-sc clang-sc c-dflt"
if [ -n "${BENCH_REUSE_C:-}" ]; then
    progs="ada-sc ada-simd"
    for p in gcc-sc clang-sc c-dflt; do
        # The inputs' temporary directory differs from run to run.
        awk -v d="$tmp" '$2 !~ /^wuffs\// { n = split($2, a, "/"); $2 = d "/" a[n] } { print }' \
            "$BENCH_REUSE_C/$p.out" > "$tmp/$p.out"
    done
fi
for p in $progs; do
    $pin "$tmp/$p" < "$tmp/list" > "$tmp/$p.out"
done
echo "load after: $(cut -d ' ' -f 1-3 /proc/loadavg)"

filter='{ print $1, $2, $3, $5 }'
for pair in "ada-sc gcc-sc" "clang-sc gcc-sc" "ada-simd c-dflt"; do
    set -- $pair
    awk "$filter" "$tmp/$2.out" > "$tmp/cmp"
    if ! awk "$filter" "$tmp/$1.out" | cmp -s - "$tmp/cmp"; then
        echo "bench: the results of $1 and $2 differ" >&2
        exit 1
    fi
done
{
    echo "results (checksums of everything computed): ada-sc = gcc-sc = clang-sc, ada-simd = c-dflt"
    echo
    printf '%-8s %-24s %8s | %8s %8s %8s %8s %8s | %7s %7s %7s | %6s\n' kind input bytes \
        ada-sc ada-simd gcc-sc clang-sc c-dflt a/gcc a/clang simd/c spread
    echo "(ns per input byte; for images, ms per image in the second line; spread in %)"
    paste -d ' ' "$tmp/ada-sc.out" "$tmp/ada-simd.out" "$tmp/gcc-sc.out" "$tmp/clang-sc.out" "$tmp/c-dflt.out" |
        awk '{
            n = split($2, parts, "/"); name = parts[n]; bytes = $3
            a = $4; o = $10; s = $16; c = $22; v = $28
            sp = 0
            for (i = 0; i < 5; i++) { d = $(6 * i + 6) / $(6 * i + 4) - 1; if (d > sp) sp = d }
            printf "%-8s %-24s %8d | %8.3f %8.3f %8.3f %8.3f %8.3f | %7.2f %7.2f %7.2f | %6.1f\n",
                $1, substr(name, 1, 24), bytes, a / bytes, o / bytes, s / bytes, c / bytes, v / bytes,
                a / s, a / c, o / v, sp * 100
            if ($1 == "png" || $1 == "gif" || $1 == "jpeg" || $1 == "webp")
                printf "%-8s %-24s %8s | %8.2f %8.2f %8.2f %8.2f %8.2f |\n", "", "  ms per image", "",
                    a / 1e6, o / 1e6, s / 1e6, c / 1e6, v / 1e6
        }'
} > "$tmp/table"
cat "$tmp/table"
if [ -n "${BENCH_SAVE:-}" ]; then
    mkdir -p "$BENCH_SAVE"
    cp "$tmp"/*.out "$tmp/table" "$tmp/list" "$BENCH_SAVE/"
fi
