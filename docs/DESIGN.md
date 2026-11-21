# wuffada — design

Goal: **pure Ada, memory-safe, native decoding of images** (and the other Wuffs
formats), with no C in the trusted base.

Two halves:

1. **`Wuffs.Base.*`** — a hand-written Ada/SPARK replacement for Wuffs'
   hand-written C base library (`wuffs/internal/cgen/base/`). This is the part
   Wuffs itself does *not* prove, so we prove it: GNATprove, absence of runtime
   errors, no unjustified assumptions.
2. **`wuffs-ada`** — a Go code generator (an "adagen" sibling of upstream's
   `internal/cgen`) that turns checked Wuffs ASTs into ordinary Ada
   (`Wuffs.Std.*`). The Wuffs compiler has already proved this code; we keep
   Ada's runtime checks on as a second net and lower Wuffs' proof facts into
   Ada subtypes, assertions and contracts.

Upstream is pinned at `google/wuffs@a87f0bb` (2026-11-18). A checkout lives in
`./wuffs/` (git-ignored); the Go module depends on the same commit.

## Layout

| Path | What | SPARK |
|---|---|---|
| `ada/src/root/wuffs.ads` | scalar + array types shared by everything | yes |
| `ada/src/base/` | `Wuffs.Base.*` core, hand-written | **yes, proved** |
| `ada/src/pixel/` | `Wuffs.Base.Pixel*`: pixel formats, buffers, swizzler, hand-written (`ada/wuffs_pixel.gpr`) | **yes, proved** |
| `ada/src/ycck/` | `Wuffs.Base.Pixel_Swizzler_YCCK`, `Color_YCC`, `Pixel_Buffers.Rows`: YCbCr/YCCK conversion and chroma upsampling for JPEG/VP8, hand-written (`ada/wuffs_ycck.gpr`) | **yes, proved** |
| `ada/src/token/` | `Wuffs.Base.Tokens`, `Wuffs.Base.UTF8`: token values, token-buffer cursors and UTF-8 for the json/cbor token decoders, hand-written (`ada/wuffs_token.gpr`) | **yes, proved** |
| `ada/src/runtime/` | `Wuffs.Runtime.*`, glue the generated code needs that SPARK cannot express (slice handles, interfaces) | no |
| `ada/gen/` | generator output, `Wuffs.Std.<pkg>` (checked in); `scalar/` and `simd/` hold the six packages that differ | no |
| `ada/src/simd/` | `Wuffs.Runtime.X86`: vector types, intrinsic wrappers, CPU detection | no |
| `ada/tests/` | test drivers | no |
| `cmd/wuffs-ada/`, `internal/adagen/` | the generator (Go) | — |

Two GNAT projects so the halves build independently: `ada/wuffs_base.gpr`
(root + base, has the `Prove` package) and `ada/wuffs_gen.gpr`
(root + runtime + gen + tests). Toolchain comes from Alire:
`cd ada && alr exec -- gprbuild -P wuffs_base.gpr`,
`alr exec -- gnatprove -P wuffs_base.gpr`.

## Type mapping

| Wuffs | Ada |
|---|---|
| `u8 u16 u32 u64` | `Wuffs.U8 .. U64` (modular, `Interfaces.Unsigned_N`) |
| `u32[..= 4095]` and other refinements | a `subtype ... range` of the modular type |
| `bool` | `Boolean` |
| `array[N] T` | constrained array, index `0 .. N-1` |
| `slice T` as a parameter of base code | `in`/`in out` unconstrained `Wuffs.Bytes` etc. — bounds travel with the array, SPARK-provable |
| `slice T` as a re-assignable value in generated code | `Wuffs.Runtime` slice handle (GNAT fat pointer); every index still bounds-checked |
| `struct` | `limited record`; never copied, never returned by value |
| `implements base.X` | Ada limited interface in `Wuffs.Runtime` |
| `base.token_writer` | a `Wuffs.U64_Array` of tokens plus a `Token_Buffer_Meta`, with a cursor like a byte writer's |
| `nptr base.image_config` etc., `nptr base.pixel_buffer` | the object (for a pixel buffer: descriptor, pixels and palette arrays) plus a `_Null : Boolean`; nothing is read or written when it is True, and everything is validated at entry when it is False |
| `status` | `Wuffs.Status` (root package): a small value record (category + code), no pointers; base status constants live in `Wuffs.Base` |
| `~mod+ ~mod- ~mod*` | native modular operators |
| `~sat+ ~sat-` | `Wuffs.Base.Ints` saturating functions |
| `assert`, loop `inv`/`pre`/`post`, func `pre`/`post` | `pragma Assert`, `pragma Loop_Invariant`, `Pre`/`Post` aspects |
| checker-deduced bounds (`MBounds`) | used to pick the narrowest subtype for locals/temporaries where cheap |

Index arithmetic uses the signed `Wuffs.Index` (capped at 2**62), not modular
types, so a bad index is an Ada check failure, never a silent wrap.

## The SPARK boundary

All *computation* in the base library is written as SPARK subprograms over
array parameters with contracts (e.g. `Peek_U32LE (Data, Pos)` with
`Pre => Has (Data, Pos, 4)`; a swizzle function is
`(Dst : in out Bytes; Palette : Bytes; Src : Bytes) return Index`).
Anything that must *hold* a reference to caller memory across calls
(I/O buffer handles, pixel-buffer plane handles) is a thin shell in
`Wuffs.Runtime` with `SPARK_Mode => Off` that does nothing but slice and call
into SPARK code. No arithmetic, no loops in the shell.

Proof target: GNATprove `--mode=all --level=2`, zero unproved checks, no
`pragma Assume` / `Annotate (False_Positive)` without a written justification
that a reviewer accepted. Functional correctness is covered by tests against
upstream's C output on `wuffs/test/data`, not by proof.

Prover effort is bounded by a **step limit, not wall-clock time** (decided by
the project lead), so a proof passes or fails identically on a loaded or slow
machine. The limit lives in the `Prove` package of each proved project and is
set with margin over the largest step count any check needs.

**Aliasing.** SPARK assumes distinct array parameters do not overlap, but the
C functions being replaced are `memmove`s and Wuffs code does copy within one
array (deflate history, the JPEG bitstream buffer). Proved two-array
operations therefore *require* disjoint actuals, and every one that Wuffs can
call on a single array has a proved same-array `_Within` variant. The runtime
shell, which knows the underlying object of each slice handle, picks the
variant. We do not rely on GNAT happening to emit `memmove`.

Pixel operations (swizzle, `Prepare`, pixel-buffer setters) have no `_Within`
variants (decided by the project lead). Their rule is: the array that is
*written* must be disjoint from every array *read* in the same call; read-only
arrays may overlap each other (upstream's BMP decoder shares one scratch array
between source and destination palette). The runtime shell checks this by
address range before calling the proved code and returns a bad-argument status
if a caller's buffers violate it, in every profile. No decoder in upstream's
`std` creates such an overlap itself.

A token array must share no storage with any byte-array argument; the shell
rejects that at entry by address range (stricter than C).

`Swizzle_YCCK` writes two arrays, the pixels and the 2 KiB scratch buffer;
each must be disjoint from every other array argument and from each other.

**Proved-callers-only packages.** `Wuffs.Base.Pixel_Buffers.Rows`,
`Pixel_Buffers.Row_Start` and the `Endian` pokes take their safety from
preconditions and return no status. Generated code and the runtime shell must
never call `Pixel_Buffers.Rows`; it exists for `Swizzle_YCCK`, which
establishes the preconditions from its own checked entry tests.

**Type-valid records.** "No precondition" on a proved entry point means: for
arguments whose fields hold values of their subtypes. In the release profile
nothing enforces subtype ranges, so the shell validates every caller-supplied
record field (`'Valid`) before the proved code sees it.

**Index conventions.** `Wuffs.Index` is capped at 2**62 - 1 so the sum of two
indices fits `Wuffs.Offset`. Generated calls into base/runtime subprograms
with several same-typed parameters use named association.

## Coroutines

Wuffs coroutines resume in the middle of loops. Ada forbids `goto` into a
compound statement, so the generator lowers any construct that *contains a
suspension point* to flat labels + gotos at the top level of the subprogram,
with a `case` dispatch on the saved suspension point at entry. Constructs
without suspension points stay structured. Locals live across a suspension are
saved in the decoder record (port of upstream's liveness analysis). Validated
by hand with GNAT 16.

## Stack and heap

The library allocates nothing and uses a small, bounded stack.

* `ada/gnat.adc`: `No_Recursion`, `No_Secondary_Stack`, `No_Allocators`,
  `No_Implicit_Heap_Allocations`.
* Every frame is limited to 8 KiB: `-Werror=stack-usage=8192` and `-gnatwe`
  (`wuffs_common.gpr`) make an oversized frame or any warning a build error. `-fstack-usage` `.su` files are reviewed.
* Decoder records are `limited`, can be hundreds of KiB, and are placed by the
  *caller* (library level or caller's heap). Generated code never declares one
  locally, never returns one, never builds one with an aggregate
  (`Self := (others => <>)` materialises a temporary on the stack in GNAT):
  `Initialize` assigns field by field / loops in place.
* No function returns an unconstrained array. No local array above 1 KiB in
  generated code: larger ones move into the decoder record.
* Wuffs `const` tables become library-level `constant` arrays (rodata).

## Checks

Profile `checked` (default): all Ada runtime checks, assertions and
`-fstack-check` on. Profile `release`: `-gnatp`, nothing checked, including
the preconditions and predicates of the proved base library (decided by the
project lead: the base is proved and the generated code is Wuffs-proved, so
release trusts both). Both profiles are tested. A check failure in generated
code means a generator or base-library bug, since Wuffs has proved the source;
it must never be reachable from input data. The `checked` profile and the
differential tests against upstream C are what catch generator bugs.

## SIMD

x86 SIMD is generated for the functions upstream wrote in Wuffs: crc32,
adler32, crc64, four PNG filters, deflate's BMI2 path and the JPEG IDCT.
ARM functions are skipped. The hand-written swizzlers in the proved libraries
are scalar.

* `ada/src/simd` (not SPARK): `Wuffs.Runtime.X86` vector types and one thin
  wrapper per Wuffs cpu_arch method over the GCC builtin that implements the
  intrinsic upstream's C uses (`METHODS.md` is the table). The loads and the
  store are the only code that uses addresses; their preconditions are the
  lengths the Wuffs checker proved.
* Each SIMD function is in a private child unit (`Wuffs.Std.<Pkg>.X86_SSE42`,
  `X86_AVX2`, `X86_BMI2`), the only units compiled with `-m` switches
  (`ada/wuffs_simd.gpr`). `test.sh` checks with objdump that nothing else
  holds an instruction beyond SSE2, so the default build runs on any x86-64.
* `choose` selects at run time through `Wuffs.Runtime.CPU`: upstream's CPUID
  bits, cached. One test more than upstream: AVX2 also needs the operating
  system to save the AVX state (OSXSAVE and XCR0), where upstream's AVX2 code
  would die with an illegal instruction.
* `-XWUFFS_SIMD=off` builds the scalar-only library (`ada/gen/scalar`, the
  code as it was before SIMD). It is required for targets other than x86-64.
* A SIMD build is compared with upstream's default C build, a scalar build
  (and a SIMD build with features hidden) with upstream's scalar build.
* The wrappers cannot be proved (an intrinsic has no Ada body): they are
  tested against digests from a C program that calls the real intrinsics.

Limits:

* AddressSanitizer does not instrument the vector load and store builtins,
  so the sanitizer stage says nothing about those accesses. The checked
  profile's preconditions and, in release, the Wuffs checker's proof cover
  them.
* The SIMD units need optimisation: two wrappers pass computed immediates
  that GCC only accepts once folded, so `-O0` fails to compile them.
* GNAT 16.1 miscompiles an `others` aggregate of a vector type with 8-bit
  lanes (zeroes); the wrappers do not use one.
* PNG and JPEG decoding are still 1.5-3x slower than upstream's SIMD build:
  the deflate core and the swizzlers are scalar.

## Milestones

1. Done: base core proved; generator M1 (adler32, crc32).
2. In progress, in parallel:
   * Generator: use the proved base, coroutine lowering, I/O, `use`;
     lzw, deflate, zlib, gzip.
   * Base: pixel formats, pixel buffer, pixel swizzler, proved. Done.
3. Done: image decoders netpbm, bmp, gif, png, wbmp, nie, targa, qoi, etc2,
   thumbhash, handsum; hashers and decompressors sha256, xxhash32/64, crc64,
   bzip2, lzma, lzip, xz; YCCK swizzle proved, about 0.9-1.1x of upstream's
   scalar C.
4. Done: JPEG (baseline and progressive) and WebP (lossy VP8 and lossless
   VP8L), scalar paths.
5. Done: json and cbor. Every package of upstream's std is now generated.
6. Done: x86 SIMD for the functions upstream wrote in Wuffs.
7. Next: SIMD swizzlers; the known follow-ups below.

## Known follow-ups

From the review of generator milestone 4a; none affects generated `std` code.

* `io_forget_history`: a block, then `undo_byte`, then a second block with a
  callee in the same call leaves the rebase point ahead of the cursor. Checked
  raises from a base precondition, release diverges, upstream C is undefined.
  No `std` package has this shape. The generator should reject or guard it.
* `test.sh` has no xz input with a BCJ filter, so that path (the only heavy
  user of `io_forget_history`) is untested there. Upstream C itself fails on
  some BCJ files under chunked destinations; those need trace-only
  expectations.
* The "roomy" decode schedules are looser than needed: bzip2 works with a
  1-byte destination and lzma's real minimum is 274 bytes.
* The new decompressors are not in the AddressSanitizer stage or the
  hostile-caller tests (no short or zero work buffer).
* Still rejected at generation time: writer `io_limit`, private and
  non-classy structs, local arrays over 1 KiB, slice types other than u8,
  tables from non-destination memory, token readers, and an extended-token
  write whose `value_extension` is a constant below 2**32 (upstream's C
  computes that case in 32 bits).
* CBOR: two upstream behaviours are reproduced as they are: an array or map
  whose zero length is not inline is treated as indefinite-length, and an
  empty chunk inside an indefinite-length string ends the item early.
* JSON/CBOR: the decoders make no progress below their minimum buffer sizes
  (json: 100 source bytes; cbor: 9 source bytes and 2 tokens), as upstream.
  JSON tokenising is 1.8-3.8x slower than upstream's scalar C.
* JSON tests: a mutant that clears the continued bit of a string token of
  65532 bytes or more on the byte-at-a-time path survives the suite; a
  70000-byte string under random 1-12 byte source fills kills it. One shell
  overlap mutant survives because no test ends a token array inside the
  first 8 bytes of the decoder object.
* `Wuffs.Base.UTF8.Valid_UTF_8_Length` belongs with the IO package; it lives
  in `ada/src/token` because the IO package was frozen when it was written.
* JPEG: the reference is upstream's *scalar* C build. Upstream's AVX2 IDCT
  saturates in 16-bit lanes where its scalar IDCT wraps, so the two upstream
  builds give different pixels for out-of-range coefficients in corrupt
  files; on valid files they and the Ada agree byte for byte.
* WebP: upstream behaviours the Ada reproduces because it follows upstream
  C byte for byte: the VP8 loop-filter sharpness clamp uses `max` where the
  VP8 specification has `min` (pixels differ from libwebp by up to 15 when
  sharpness is non-zero); a lossless image inside an extended (VP8X)
  container is not decodable; `workbuf_len` omits the alpha plane for
  VP8X+ALPH+VP8; animations are rejected. Files hitting these are compared
  with upstream C only.
* WebP: `Wuffs.Std.Webp.Decoder` is about 3.2 MB (Huffman tables and the
  embedded VP8 decoder). Callers must declare it at library level or
  allocate it; it never goes on the library's stack.
* WebP tests: no damaged file has a chunk size exactly one below what its
  header needs (one surviving mutant); `test.sh` requires libwebp.
* JPEG: the comparison with Go's `image/jpeg` is a gross-error check only.
  On the default (triangle-filter) upsampling path its tolerance does not
  catch subtle errors; that path rests on the byte-exact C comparison.

## Open decisions (owner: project lead)

* Modular integers do not trap on overflow of Wuffs' *checked* `+`. Option:
  emit `pragma Assert` for them in the `checked` profile (cost: size/speed).
* Whether generated code should later be made SPARK-provable as well
  (would need the loop/case form of coroutines and a different slice model).
