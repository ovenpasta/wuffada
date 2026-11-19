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
| `ada/src/runtime/` | `Wuffs.Runtime.*`, glue the generated code needs that SPARK cannot express (slice handles, interfaces) | no |
| `ada/gen/` | generator output, `Wuffs.Std.<pkg>` (checked in) | no |
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

Not in scope yet. `choose` statements resolve to the scalar default.

## Milestones

1. Done: base core proved; generator M1 (adler32, crc32).
2. In progress, in parallel:
   * Generator: use the proved base, coroutine lowering, I/O, `use`;
     lzw, deflate, zlib, gzip.
   * Base: pixel formats, pixel buffer, pixel swizzler, proved.
3. First image decoders (netpbm, bmp, gif, png).
4. Remaining decoders (jpeg + YCCK swizzle, webp, ...), remaining formats.

## Open decisions (owner: project lead)

* Modular integers do not trap on overflow of Wuffs' *checked* `+`. Option:
  emit `pragma Assert` for them in the `checked` profile (cost: size/speed).
* Whether generated code should later be made SPARK-provable as well
  (would need the loop/case form of coroutines and a different slice model).
