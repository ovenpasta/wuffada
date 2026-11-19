# wuffada

Pure Ada, memory-safe native decoding of images (and the other Wuffs formats).
Two halves: a hand-written **SPARK-proved base library** replacing Wuffs'
hand-written C base, and **`wuffs-ada`**, a Go generator that compiles Wuffs
packages to ordinary Ada. `docs/DESIGN.md` is the architecture and is binding;
read it before changing anything.

## Working rules

- The project lead makes the decisions. Recommend, then wait on anything that
  is a real choice; record open decisions in `docs/DESIGN.md`.
- **Ask before every commit.** Never commit, amend, or push unprompted.
- **No attribution in commits.** No `Co-Authored-By` trailer, no "Generated
  with" line, nothing naming Claude or Anthropic in commit messages.
- Work is done by an implementer agent and checked afterwards by a separate
  reviewer agent that did not write it. Agents never run state-changing git.
- Report results exactly. "Proved" and "passes" mean it was run on the final
  tree. Say what was not run.

## Layout

| Path | What |
|---|---|
| `docs/DESIGN.md` | architecture, type mapping, milestones, open decisions |
| `ada/src/root/wuffs.ads` | shared scalar/array/status types (architect-owned) |
| `ada/src/base/` | `Wuffs.Base.*`, hand-written, SPARK, proved |
| `ada/src/runtime/` | `Wuffs.Runtime.*`, non-SPARK glue for generated code |
| `ada/gen/` | generator output `Wuffs.Std.*` (checked in, never hand-edited) |
| `ada/tests/`, `ada/tests_base/` | generator tests; base-library tests + C oracle |
| `cmd/wuffs-ada/`, `internal/adagen/` | the generator (Go) |
| `wuffs/` | upstream checkout, pinned at `a87f0bb`, git-ignored, read-only |

## Commands

Ada tools come from Alire; run them from `ada/`.

```sh
# Base library: prove, then test in both profiles
cd ada
alr exec -- gnatprove -P wuffs_base.gpr              # must end "all checks proved"
alr exec -- gprbuild -P wuffs_base_tests.gpr && bin/base_tests
alr exec -- gprbuild -P wuffs_base_tests.gpr -XWUFFS_PROFILE=release && bin/base_tests
tests_base/oracle/regen.sh                           # regenerate expected values from upstream C

# Generator: regenerate ada/gen, build both profiles, run everything
./gen.sh
./test.sh
```

If `wuffs/` is missing: `git clone https://github.com/google/wuffs && git -C wuffs checkout a87f0bb`.

## Hard rules for the code

**Base library (`ada/src/base`)**
- `SPARK_Mode => On` everywhere. GNATprove at the project's level, zero
  unproved checks.
- No `pragma Assume`, `pragma Annotate (GNATprove, ...)`, `SPARK_Mode => Off`,
  or raised proof level/timeouts without the lead's sign-off.
- Never make a proof pass by adding a precondition that generated code cannot
  establish; compare with what the C function assumes. Never weaken a
  postcondition silently.
- Two-array operations require disjoint actuals; anything Wuffs can call on a
  single array needs a proved `_Within` variant. Do not rely on GNAT emitting
  `memmove`.
- Expected test values come from upstream's C (the oracle) or are derived
  independently, never from the code under test.

**Generated code and generator**
- The generator must reject, with an error, any construct it does not handle.
  No silent fallthrough.
- Generator-invented identifiers live in the `G_` namespace; see
  `internal/adagen/names.go`.
- Calls with two or more same-typed parameters use named association.
- Output is deterministic; `ada/gen` is only ever changed by `./gen.sh`.
- Package ids are append-only in `internal/adagen/package_ids.txt`.

**Stack and heap (everything)**
- `ada/gnat.adc`: no recursion, no secondary stack, no allocators, no implicit
  heap allocation.
- Frames over 8 KiB and all warnings are build errors (`wuffs_common.gpr`).
- Decoder records are `limited`, placed by the caller, never declared locally,
  never returned, never built with a whole-record aggregate.
- No function returns an unconstrained array. No local array over 1 KiB.

**Types**
- Values are modular `Wuffs.U8..U64`; indices and lengths are the signed,
  checked `Wuffs.Index`. Be explicit at every conversion between the two.
- Endian and Slices take Ada indices; IO works in offsets from `Data'First`.

## Ownership when agents work in parallel

Base work owns `ada/src/base`, `ada/tests_base`, `ada/wuffs_base*.gpr`.
Generator work owns the Go tree, `ada/src/runtime`, `ada/gen`, `ada/tests`,
`ada/wuffs_gen.gpr`, `gen.sh`, `test.sh`. `ada/src/root`, `ada/gnat.adc`,
`ada/wuffs_common.gpr` and `docs/DESIGN.md` change only through the architect.
