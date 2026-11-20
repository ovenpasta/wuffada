#!/bin/sh
# Builds and times the YCCK swizzle on both sides and prints a table:
# nanoseconds per pixel (best of several rounds) for a 1600 x 1200 4:2:0
# image, for five destination formats, with basic and with fancy
# upsampling.
#
#   Ada           Wuffs.Base.Pixel_Swizzler_YCCK, release switches (-O2 -gnatp)
#   gcc scalar    upstream C, gcc -O2, WUFFS_CONFIG__AVOID_CPU_ARCH
#   clang scalar  upstream C, clang -O2, WUFFS_CONFIG__AVOID_CPU_ARCH
#   gcc simd      upstream C, gcc -O2 (AVX2 colour conversion)
#   clang simd    upstream C, clang -O2 (AVX2 conversion and h2v2 upsampling)
#
# It also checks that every program computed the same pixels.  Not a test:
# the numbers depend on the machine and on what else it is doing.
#
# Usage: ./bench.sh [path/to/wuffs checkout]   (default: ../../../wuffs)
set -eu
here=$(cd "$(dirname "$0")" && pwd)
wuffs=${1:-$here/../../../wuffs}
cfile=$wuffs/release/c/wuffs-unsupported-snapshot.c
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
(cd "$here/../.." && alr exec -- gprbuild -q -P tests_ycck/bench/ycck_bench.gpr)
ada=$here/../../bin/ycck_bench
for cc in gcc clang; do
  $cc -O2 -DWUFFS_CONFIG__AVOID_CPU_ARCH -DWUFFS_C_FILE="\"$cfile\"" -o "$tmp/$cc-scalar" "$here/bench_c.c"
  $cc -O2 -DWUFFS_C_FILE="\"$cfile\"" -o "$tmp/$cc-simd" "$here/bench_c.c"
done
printf '%-15s %-6s %8s %11s %13s %9s %11s %10s %12s\n' format ups Ada 'gcc scalar' 'clang scalar' 'gcc simd' 'clang simd' 'Ada/gcc' 'Ada/clang'
for f in 82008888:BGRA_PREMUL 81008888:BGRA_NONPREMUL 90008888:BGRX A0000888:RGB 80000565:BGR_565; do
  repr=${f%%:*}
  name=${f##*:}
  for ups in 0 1; do
    a=$("$ada" "$repr" $ups)
    gs=$("$tmp/gcc-scalar" "$repr" $ups)
    cs=$("$tmp/clang-scalar" "$repr" $ups)
    gv=$("$tmp/gcc-simd" "$repr" $ups)
    cv=$("$tmp/clang-simd" "$repr" $ups)
    da=$(echo "$a" | sed 's/.*16#\(.*\)#.*/\1/')
    for other in "$gs" "$cs" "$gv" "$cv"; do
      if [ "$(echo "$other" | cut -d' ' -f2)" != "$da" ]; then
        echo "$name ups=$ups: the programs computed different pixels" >&2
        exit 1
      fi
    done
    na=${a%% *}; ng=${gs%% *}; nc=${cs%% *}; ngv=${gv%% *}; ncv=${cv%% *}
    printf '%-15s %-6s %8s %11s %13s %9s %11s %10s %12s\n' "$name" \
      "$([ $ups = 0 ] && echo basic || echo fancy)" "$na" "$ng" "$nc" "$ngv" "$ncv" \
      "$(echo "$na $ng" | awk '{printf "%.2f", $1 / $2}')" \
      "$(echo "$na $nc" | awk '{printf "%.2f", $1 / $2}')"
  done
done
