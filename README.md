# wuffada

Memory-safe decoders for images and compressed data, in pure Ada.

wuffada compiles the [Wuffs](https://github.com/google/wuffs) standard
library to Ada, on top of a hand-written base library that is proved free of
run-time errors with SPARK. There is no C in the result, no heap allocation
in the library, and a small bounded stack.

It is not affiliated with Google or the Wuffs project.

## What you get

All 30 packages of Wuffs' standard library, as `Wuffs.Std.<Name>`:

| Kind | Packages |
|---|---|
| Images | `Png` (with APNG), `Jpeg` (baseline and progressive), `Gif`, `Webp` (lossy and lossless, still and animated), `Bmp`, `Netpbm`, `Qoi`, `Targa`, `Wbmp`, `Nie`, `Etc2`, `Thumbhash`, `Handsum`, and `Vp8` |
| Compression | `Deflate`, `Zlib`, `Gzip`, `Bzip2`, `Lzma`, `Lzip`, `Xz`, `Lzw` |
| Checksums | `Crc32`, `Crc64`, `Adler32`, `Sha256`, `Xxhash32`, `Xxhash64` |
| Tokenisers | `Json`, `Cbor` |

On x86-64 the build includes SSE4.2, AVX2 and BMI2 versions of the functions
upstream wrote with SIMD, selected at run time. A scalar-only build works on
any target.

## Why trust it

Three layers, each checked differently:

1. **The decoders are Wuffs code.** The Wuffs compiler has already proved
   every array index and every arithmetic operation in them safe. wuffada's
   generator (`wuffs-ada`, written in Go) translates the checked program to
   Ada.
2. **The base library is proved.** Wuffs' own base library is hand-written
   C that nothing proves. Its replacement here (`Wuffs.Base.*`: I/O buffers,
   pixel formats and conversion, YCbCr upsampling, tokens, UTF-8) is SPARK,
   and GNATprove proves it free of run-time errors: over 12,000 checks, with
   no assumptions and no justified exceptions.
3. **The translation is tested against upstream.** Every decoder is run
   against the C that upstream generates, over thousands of files and their
   truncated and corrupted copies, with input fed in chunks down to one byte.
   A scalar build must match upstream's scalar C byte for byte, and a SIMD
   build upstream's default build. Independent decoders (Go's standard
   library, libwebp) are a second reference where one exists.

What is *not* proved: the generated Ada itself is ordinary Ada, not SPARK.
In the `checked` profile it keeps every Ada run-time check and the
assertions lowered from the Wuffs source, as a second net. In the `release`
profile nothing is checked, and safety rests on layers 1 and 3. The thin
runtime shell between generated code and the proved library, and the SIMD
intrinsic wrappers, are tested, not proved.

Everything a *caller* supplies is validated at every public entry in both
profiles: buffer positions, pixel-buffer layouts, and that buffers do not
overlap each other or the decoder object.

## Using it

With [Alire](https://alire.ada.dev), from a checkout or a release archive:

```sh
alr with wuffs_ada --use=/path/to/wuffada/ada      # or the unpacked archive
```

Your own units must be compiled as Ada 2022 (`-gnat2022`), because the specs
use it. Only GNAT 16 has been tested.

Build options (GPR externals):

| External | Values | Meaning |
|---|---|---|
| `WUFFS_PROFILE` | `release` (default), `checked` | `checked` keeps all Ada checks and assertions |
| `WUFFS_SIMD` | `on` (default), `off` | `off` builds the scalar-only library; required off x86-64 |

A checksum:

```ada
with Ada.Text_IO;
with Wuffs.Std.Crc32;

procedure Demo is
   Hasher : Wuffs.Std.Crc32.Ieee_Hasher;
   Data   : constant Wuffs.Bytes (0 .. 8) := [49, 50, 51, 52, 53, 54, 55, 56, 57];
begin
   Wuffs.Std.Crc32.Initialize (Hasher);
   Ada.Text_IO.Put_Line (Wuffs.Std.Crc32.Update_U32 (Hasher, Data)'Image);  --  3421780262
end Demo;
```

Decoding an image takes a few more steps (read the image configuration, set
up a pixel buffer, decode the frame). [`examples/decode_image`](examples/decode_image)
is a complete program that converts PNG, JPEG, WebP, GIF, BMP and others to
PPM/PAM:

```sh
cd ada && alr exec -- gprbuild -P ../examples/decode_image.gpr -XWUFFS_PROFILE=release
../examples/bin/decode_image photo.jpg photo.ppm
```

Things to know as a caller:

- **The library never allocates.** You own every buffer and every decoder
  object. Decoders are limited records: declare them at library level or
  allocate them yourself; do not put the large ones on the stack. The WebP
  decoder is about 3.2 MB, GIF 65 KB, PNG 44 KB, JPEG 16 KB.
- **Decoders suspend.** A call returns a "short read" or "short write"
  status when it needs more input or output room; call again with more. The
  API mirrors Wuffs' C API, which upstream documents in
  [its notes](https://github.com/google/wuffs/tree/main/doc).
- **Statuses, not exceptions.** Bad input gives an error status. An Ada
  exception from the library in the `checked` profile means a bug here.

## Limits

- There is no AVIF, ICO, TIFF or JPEG XL decoder. An animated WebP's
  frames are decoded one by one, as for GIF and APNG: the caller composites
  them (blending, disposal). Its frame configs' background colour is
  transparent black: the ANIM chunk's colour is only a hint.
- A WebP file in the extended format (VP8X), including every animation,
  asks for a work buffer about as long as the file (the RIFF chunk length
  bounds every VP8 chunk, whose data is copied into it), and one whose RIFF
  chunk is longer than about 144 MiB is rejected as unsupported.
- The decoders report ICC profiles and other metadata but do not apply
  colour management.
- Speed: the checksums match upstream's SIMD build. PNG and JPEG decoding
  are 1.5 to 3 times slower than upstream's SIMD build, because the deflate
  core and the pixel converters are scalar.
- ARM SIMD is not generated.
- More in [`docs/DESIGN.md`](docs/DESIGN.md), under "Known follow-ups".

## Repository layout

| Path | What |
|---|---|
| `ada/` | The Alire crate `wuffs_ada`: proved libraries (`src/`), generated decoders (`gen/`), tests |
| `cmd/wuffs-ada`, `internal/adagen` | The generator |
| `examples/` | `decode_image` |
| `docs/DESIGN.md` | Architecture, type mapping, the proof boundary, known gaps |

The generated Ada is checked in, so using the library needs neither Go nor
a Wuffs checkout. Releases carry a `wuffs_ada-X.Y.Z.tar.gz` with the library
alone.

## Working on it

Regenerating and testing need Go, a C compiler, libwebp's development files
(libwebp and libwebpdemux), `xz` and `bzip2`, and our Wuffs fork (upstream
Wuffs with decoder fixes and features, kept in upstream's style) at the
pinned commit, `WUFFS_COMMIT` in `.github/workflows/*.yml`. The generator
builds with the fork's Wuffs compiler (`go.mod` replaces
`github.com/google/wuffs` with the fork at that commit):

```sh
git clone -b wuffada https://github.com/ovenpasta/wuffs && git -C wuffs checkout 4b527a3d
./gen.sh          # regenerate ada/gen
./test.sh         # everything, both profiles (WUFFS_ASAN=1 adds a sanitizer stage)
```

Proofs (GNATprove 16 comes through Alire; a full run takes 20 to 30 minutes):

```sh
cd ada/prove
alr exec -- gnatprove -P ../wuffs_ycck.gpr     # base, pixel and YCCK libraries
alr exec -- gnatprove -P ../wuffs_token.gpr    # tokens and UTF-8
```

## Licence

Apache-2.0 OR MIT, the same as Wuffs. Large parts are derived from Wuffs and
are also copyright The Wuffs Authors; see [`LICENSE`](LICENSE) and
[`REUSE.toml`](REUSE.toml).
