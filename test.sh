#!/bin/sh
# Regenerates the Ada code, builds it in both profiles and runs every test.
# Exits non-zero on the first failure. Needs Go, a C compiler (cc, for the
# cross-check against upstream's C back-end), libwebp's headers and library
# (for ada/tests/crosscheck/webpref.c, the second reference decoder for
# WebP), Alire (alr) with the project's GNAT toolchain, and the Wuffs
# checkout at ./wuffs.
#
# Everything temporary (at most about 800 MB: the test corpora and traces;
# 768 MB measured with WUFFS_ASAN=1) goes to one directory under
# ${TMPDIR:-/tmp}, which is removed at the end.
#
# With WUFFS_ASAN=1 in the environment, it also builds the image tests a
# third time, for the release profile with -fsanitize=address (in the
# temporary directory), and runs them: the hostile-caller tests, the chaos
# runs and the whole image corpus (compared with upstream's C again).
set -eu
cd "$(dirname "$0")"

say() { printf '\n==== %s\n' "$*"; }
die() { printf 'test.sh: FAIL: %s\n' "$*" >&2; exit 1; }

tmp="$(mktemp -d)" || die "cannot make a temporary directory"
trap 'rm -rf "$tmp"' EXIT
# Fail now, and clearly, rather than half way with a truncated file.
avail_kb="$(df -Pk "$tmp" | awk 'NR == 2 { print $4 }')"
[ "${avail_kb:-0}" -ge 1048576 ] ||
    die "less than 1 GB free in $tmp (${avail_kb:-?} KB): set TMPDIR to a directory with more room"

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
# xxhash32, xxhash64, crc64 and sha256: Go (crypto/sha256, hash/crc64 and an
# xxHash written for this test) and upstream's C must agree first.
xargs go run ./ada/tests/hashexpect2 < "$tmp/files" > "$tmp/manifest2"
xargs ada/tests/crosscheck/run_hash2.sh < "$tmp/files" > "$tmp/manifest2.c"
cmp "$tmp/manifest2" "$tmp/manifest2.c" || die "Go's and upstream C's xxhash32/xxhash64/crc64/sha256 differ"
echo "xxhash32, xxhash64, crc64, sha256 of $nfiles files: Go and upstream's C agree"

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
# Wuffs.Base.Pixel_Buffers.Rows is for proved callers only (docs/DESIGN.md).
if grep -l 'Pixel_Buffers.Rows' ada/gen/*.ad[sb] ada/src/runtime/*.ad[sb] ada/src/runtime/*/*.ad[sb]; then
    die "generated code or the runtime shell uses Wuffs.Base.Pixel_Buffers.Rows"
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

say "WebP reference pixels from libwebp (ada/tests/crosscheck/webpref.c)"
mkdir "$tmp/webpref"
"${CC:-cc}" -std=c99 -O2 -Wall -o "$tmp/webpref.bin" ada/tests/crosscheck/webpref.c -lwebp ||
    die "cannot build webpref.c: libwebp's headers and library are needed"
find wuffs/test/data ada/tests/webpcorpus -name '*.webp' | LC_ALL=C sort > "$tmp/webp.list"
"$tmp/webpref.bin" "$tmp/webpref" < "$tmp/webp.list" > "$tmp/webpref/list.out" || die "webpref failed"
echo "$(grep -c ' ok$' "$tmp/webpref/list.out") of $(wc -l < "$tmp/webp.list" | tr -d ' ') WebP files decoded by libwebp"

say "Corpus for the image decoders (Go's image/png, image/gif, image/jpeg and x/image/webp, and libwebp, as the independent implementations)"
mkdir "$tmp/imgcorpus"
go run ./ada/tests/imgcorpus -data wuffs/test/data -out "$tmp/imgcorpus" -chaos "$tmp/chaos.manifest" \
    -webpref "$tmp/webpref" > "$tmp/image.manifest" || die "imgcorpus failed"
nchaos="$(wc -l < "$tmp/chaos.manifest" | tr -d ' ')"
[ "$nchaos" -ge 3000 ] || die "only $nchaos chaos runs"
nimgcases="$(wc -l < "$tmp/image.manifest" | tr -d ' ')"
nimgrefs="$(grep -c -v ' - [^ ]*$' "$tmp/image.manifest" || true)"
njpeg="$(grep -c '^jpeg ' "$tmp/image.manifest" || true)"
njpegrefs="$(grep '^jpeg ' "$tmp/image.manifest" | grep -c -v ' - [^ ]*$' || true)"
nwebp="$(grep -c -E '^(webp|vp8) ' "$tmp/image.manifest" || true)"
nwebprefs="$(grep -E '^(webp|vp8) ' "$tmp/image.manifest" | grep -c -v ' - [^ ]*$' || true)"
echo "$nimgcases runs, $nimgrefs of them with reference pixels; JPEG: $njpeg runs, $njpegrefs with reference pixels; WebP and VP8: $nwebp runs, $nwebprefs with reference pixels"
[ "$nimgcases" -ge 30000 ] || die "only $nimgcases image test runs"
[ "$nimgrefs" -ge 800 ] || die "only $nimgrefs image test runs with reference pixels"
[ "$njpeg" -ge 30000 ] || die "only $njpeg JPEG test runs"
[ "$njpegrefs" -ge 1000 ] || die "only $njpegrefs JPEG test runs with reference pixels"
[ "$nwebp" -ge 40000 ] || die "only $nwebp WebP and VP8 test runs"
[ "$nwebprefs" -ge 900 ] || die "only $nwebprefs WebP and VP8 test runs with reference pixels"

say "Cross-check: upstream's C image decoders over the corpus"
ada/tests/crosscheck/run_image.sh < "$tmp/image.manifest" > "$tmp/image.c.trace"
echo "$(wc -l < "$tmp/image.c.trace" | tr -d ' ') lines traced from C"
[ -s "$tmp/image.c.trace" ] || die "empty C trace"

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
    # Per package: the largest frame of a generated subprogram and the
    # largest of what the compiler adds (type initialization and the like;
    # "<built-in>" in the .su files). The limits are far below the 8192 that
    # the build enforces, so that growth shows up here first: a frame that
    # grows with the size of a decoder's record (as the Put_Image procedure
    # that Ada 2022 gives a tagged type did) would pass them soon.
    echo "package: largest frame, largest compiler-generated frame (bytes)"
    for su in "ada/obj/gen/$profile"/wuffs-std-*.su; do
        pkg="$(basename "$su" .su)"
        own="$(grep -v '^<built-in>' "$su" | awk -F '\t' '$2 > m { m = $2 } END { print m + 0 }')"
        implicit="$(grep '^<built-in>' "$su" | awk -F '\t' '$2 > m { m = $2 } END { print m + 0 }')"
        echo "$pkg: $own, $implicit"
        [ "$own" -le 2048 ] || die "$pkg: a subprogram's frame exceeds 2048 bytes ($profile)"
        [ "$implicit" -le 128 ] || die "$pkg: a compiler-generated frame exceeds 128 bytes ($profile)"
    done

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
    (ulimit -s "$stack_kib" && timeout "$run_limit" ada/bin/test_hashers2 < "$tmp/manifest2") > "$tmp/hashers.out" ||
        { cat "$tmp/hashers.out"; die "test_hashers2 ($profile)"; }
    cat "$tmp/hashers.out"
    grep -q "^test_hashers2: files checked: $nfiles\$" "$tmp/hashers.out" ||
        die "test_hashers2 did not check all $nfiles files ($profile)"

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
    (ulimit -s "$stack_kib" && timeout "$run_limit" ada/bin/test_hostile) || die "test_hostile ($profile)"
    (ulimit -s "$stack_kib" && timeout "$run_limit" ada/bin/test_entry) || die "test_entry ($profile)"

    # The chaos runs: other arguments at every resumption. No trace to
    # compare; the program checks what it can and must not raise.
    (ulimit -s "$stack_kib" && timeout "$run_limit" ada/bin/test_image < "$tmp/chaos.manifest") > "$tmp/chaos.out" ||
        { grep -v '^= ' "$tmp/chaos.out" | head -n 50; die "test_image, chaos runs ($profile)"; }
    grep -q "^test_image: cases: $nchaos," "$tmp/chaos.out" || die "test_image did not run all $nchaos chaos runs ($profile)"
    echo "test_image, chaos runs: $(grep -v '^= ' "$tmp/chaos.out" | tr '\n' ' ')"

    (ulimit -s "$stack_kib" && timeout "$run_limit" ada/bin/test_image < "$tmp/image.manifest") > "$tmp/image.out" ||
        { grep -v '^= ' "$tmp/image.out" | head -n 50; die "test_image ($profile)"; }
    grep -v '^= ' "$tmp/image.out"
    grep -q "^test_image: cases: $nimgcases, compared with the reference decoder: $nimgrefs\$" "$tmp/image.out" ||
        die "test_image did not run all $nimgcases runs, or did not compare all $nimgrefs references ($profile)"
    grep '^= ' "$tmp/image.out" > "$tmp/image.ada.trace" || true
    cmp "$tmp/image.c.trace" "$tmp/image.ada.trace" || {
        diff "$tmp/image.c.trace" "$tmp/image.ada.trace" | head -n 20
        die "test_image's trace differs from upstream's C ($profile)"
    }
    echo "test_image: trace ($(wc -l < "$tmp/image.ada.trace" | tr -d ' ') lines) is identical to upstream's C"

    say "Example: examples/decode_image ($profile), with a ${stack_kib} KiB stack"
    (cd ada && alr exec -- gprbuild -f -P ../examples/decode_image.gpr -XWUFFS_PROFILE="$profile") > "$tmp/build.example" 2>&1 ||
        { cat "$tmp/build.example"; die "the example does not build ($profile)"; }
    if grep -i -E 'warning|\(style\)' "$tmp/build.example"; then
        die "the example's build has warnings ($profile)"
    fi
    for f in bricks-color.png bricks-dither.png hibiscus.primitive.png hippopotamus.interlaced.png \
        animated-red-blue.gif hippopotamus.interlaced.gif bricks-color.jpeg bricks-gray.jpeg \
        peacock.progressive.jpeg peacock.s1x1-444.jpeg harvesters.jpeg \
        bricks-color.lossless.webp bricks-color.lossy.webp hippopotamus.masked-with-muybridge.lossy.webp \
        harvesters.lossless.webp hibiscus.regular.lossy.webp; do
        (ulimit -s "$stack_kib" && timeout "$run_limit" examples/bin/decode_image "wuffs/test/data/$f" "$tmp/example.pnm") ||
            die "decode_image $f ($profile)"
        go run ./ada/tests/pnmcheck "wuffs/test/data/$f" "$tmp/example.pnm" || die "decode_image $f: wrong pixels ($profile)"
    done
    for f in hippopotamus.bmp hippopotamus.ppm hippopotamus.nie hat.wbmp bricks-color.qoi; do
        (ulimit -s "$stack_kib" && timeout "$run_limit" examples/bin/decode_image "wuffs/test/data/$f" "$tmp/example.pnm") ||
            die "decode_image $f ($profile)"
        echo "decode_image: $f: $(wc -c < "$tmp/example.pnm" | tr -d ' ') bytes written"
    done
    # Errors are reported with the status' message.
    head -c 3000 wuffs/test/data/bricks-color.png > "$tmp/truncated.png"
    head -c 300 wuffs/test/data/animated-red-blue.gif > "$tmp/truncated.gif"
    head -c 2000 wuffs/test/data/bricks-color.jpeg > "$tmp/truncated.jpeg"
    printf '\377\330\377\303\000\013' > "$tmp/lossless.jpeg"
    printf 'BMxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx' > "$tmp/bad.bmp"
    head -c 2000 wuffs/test/data/bricks-color.lossy.webp > "$tmp/truncated-lossy.webp"
    head -c 300 wuffs/test/data/hat.lossless.webp > "$tmp/truncated-lossless.webp"
    expect_failure() {
        if (ulimit -s "$stack_kib" && timeout "$run_limit" examples/bin/decode_image "$1" "$tmp/example.pnm") 2> "$tmp/example.err"; then
            die "decode_image $1 did not fail ($profile)"
        fi
        cat "$tmp/example.err"
        [ "$(cat "$tmp/example.err")" = "$2" ] || die "decode_image $1: expected the message: $2 ($profile)"
    }
    expect_failure "$tmp/truncated.png" "decode_frame: deflate: truncated input"
    expect_failure "$tmp/truncated.gif" "decode_image_config: gif: truncated input"
    expect_failure "$tmp/bad.bmp" "decode_image_config: bmp: bad header"
    expect_failure "$tmp/truncated.jpeg" "decode_frame: jpeg: truncated input"
    expect_failure "$tmp/lossless.jpeg" "decode_image_config: jpeg: unsupported lossless coding"
    # A status of std/vp8, through std/webp.
    expect_failure "$tmp/truncated-lossy.webp" "decode_frame: vp8: truncated input"
    expect_failure ada/tests/webpcorpus/container-vp8-interframe.webp "decode_image_config: vp8: unsupported VP8 file"
    expect_failure "$tmp/truncated-lossless.webp" "decode_frame: webp: truncated input"
    expect_failure go.mod "the input is not a PNG, GIF, JPEG, WebP, BMP, Netpbm, NIE, QOI, ETC2 (PKM) or WBMP file"
    # A file name longer than the program accepts (and so nowhere near the
    # run-time library's own limits).
    if (examples/bin/decode_image wuffs/test/data/hippopotamus.bmp \
        "$tmp/$(awk 'BEGIN { while (n++ < 1100) printf "a" }')") 2> "$tmp/example.err"; then
        die "decode_image accepted a 1100 character file name ($profile)"
    fi
    grep -q "a file name is empty or longer than 1024 characters" "$tmp/example.err" ||
        die "decode_image: the wrong message for a long file name ($profile)"
    [ -z "$(find "$tmp" -maxdepth 1 -name 'aaaa*')" ] || die "decode_image created a file for a long name"
done

if [ "${WUFFS_ASAN:-}" = 1 ]; then
    say "Ada: the image tests with AddressSanitizer (release profile)"
    (cd ada && alr exec -- gprbuild -q -P wuffs_gen.gpr -XWUFFS_PROFILE=release --relocate-build-tree="$tmp/asan" \
        test_hostile.adb test_entry.adb test_image.adb -cargs -fsanitize=address -g -largs -fsanitize=address) \
        > "$tmp/build.asan" 2>&1 || { cat "$tmp/build.asan"; die "the AddressSanitizer build failed"; }
    export ASAN_OPTIONS=detect_leaks=0
    timeout "$run_limit" "$tmp/asan/bin/test_hostile" || die "test_hostile (ASan)"
    timeout "$run_limit" "$tmp/asan/bin/test_entry" || die "test_entry (ASan)"
    timeout "$run_limit" "$tmp/asan/bin/test_image" < "$tmp/chaos.manifest" > "$tmp/chaos.out" 2> "$tmp/asan.err" ||
        { cat "$tmp/asan.err" | head -n 50; grep -v '^= ' "$tmp/chaos.out" | head -n 20; die "test_image, chaos runs (ASan)"; }
    echo "test_image, chaos runs: $(grep -v '^= ' "$tmp/chaos.out" | tr '\n' ' ')"
    timeout 3600 "$tmp/asan/bin/test_image" < "$tmp/image.manifest" > "$tmp/image.out" 2> "$tmp/asan.err" ||
        { cat "$tmp/asan.err" | head -n 50; grep -v '^= ' "$tmp/image.out" | head -n 20; die "test_image (ASan)"; }
    grep -v '^= ' "$tmp/image.out"
    grep '^= ' "$tmp/image.out" | cmp - "$tmp/image.c.trace" || die "test_image's trace differs from upstream's C (ASan)"
    [ ! -s "$tmp/asan.err" ] || { head -n 50 "$tmp/asan.err"; die "AddressSanitizer reported something"; }
    echo "AddressSanitizer: nothing reported; trace identical to upstream's C"
fi

say "ALL PASS"
