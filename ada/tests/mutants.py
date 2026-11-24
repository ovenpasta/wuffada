#!/usr/bin/env python3
# Part of wuffada (wuffs-ada: Wuffs to Ada).
# SPDX-License-Identifier: Apache-2.0 OR MIT
"""The mutants of ada/tests/mutation.sh: deliberate faults, one at a time.

usage: mutants.py list              print "NAME WHERE PROFILE EQUIVALENT" for each mutant
       mutants.py apply NAME        apply it to the tree in the current directory
       mutants.py why NAME          print why a known-equivalent mutant is one

WHERE is "src" (a fault in the generator or in the runtime shell: apply it,
then run ./gen.sh) or "gen" (a fault in the generated Ada: run ./gen.sh, then
apply it). PROFILE is the build profile that the mutant is tested with.
Mutants 01 to 25 are the implementer's of milestone 3, R01 to R20 came from
the independent review of it, N01 to N08 cover the review's fixes, M01 to
M12 are for milestone 4a, J01 to J15 for the JPEG milestone, and W01 to W16
for the vp8/webp milestone and W17 to W33 for the webp2 milestone (fixes and
animations in the fork) (run those in both profiles: MUTATION_PROFILE; and
MUTATION_FORMATS='webp|vp8' restricts the image corpus to those formats, see
mutation.sh), T01 to T19 for the json/cbor (token I/O) milestone (run those in
both profiles, with MUTATION_TOKENS=1: see mutation.sh); T18 is T01's
fault in a form that the Ada build cannot see, and T19 is T09's (which,
in the release profile, GNAT's -gnatwc reports as a condition that is
always False). S01 to S16 are for the SIMD milestone (run them in both
profiles, with MUTATION_SIMD=1: see mutation.sh).
"""

import glob
import re
import sys

G = "internal/adagen/"
RT = "ada/src/runtime/wuffs-runtime.adb"
RTS = "ada/src/runtime/wuffs-runtime.ads"
GEN = "ada/gen/wuffs-std-"
GENS = "ada/gen/simd/wuffs-std-"
SSE42 = "ada/src/simd/wuffs-runtime-x86-sse42.ads"
CPUID = "ada/src/simd/wuffs-runtime-x86-cpuid.adb"


def rep(path, old, new, count=1):
    s = open(path).read()
    if s.count(old) != count:
        sys.exit("mutants.py: %d occurrences of %r in %s" % (s.count(old), old, path))
    open(path, "w").write(s.replace(old, new))


def nth_rep(path, old, new, k):
    """Replaces the k-th (from 0) occurrence of old in path."""
    s = open(path).read()
    i = -1
    for _ in range(k + 1):
        i = s.find(old, i + 1)
        if i < 0:
            sys.exit("mutants.py: fewer than %d occurrences of %r in %s" % (k + 1, old, path))
    open(path, "w").write(s[:i] + new + s[i + len(old):])


def drop_end_limit(k):
    """Removes the k-th End_Limit call of the generated png decoder."""
    path = GEN + "png.adb"
    s = open(path).read()
    found = [m for m in re.finditer(r"\n *Wuffs\.Base\.IO\.End_Limit \([^;]*;", s)]
    if len(found) != 4:
        sys.exit("mutants.py: %d End_Limit calls in %s" % (len(found), path))
    m = found[k]
    indent = len(m.group(0)) - len(m.group(0).lstrip("\n ")) - 1
    open(path, "w").write(s[: m.start()] + "\n" + " " * indent + "null;" + s[m.end():])


def no_checks_on_resume():
    """Skips every argument check of a coroutine that is suspended."""
    n = 0
    for path in glob.glob(GEN + "*.adb"):
        s = open(path).read()
        pattern = re.compile(
            r"\n      if ((?:(?!\n      if )[\s\S])*?)(\n      then| then)"
            r"\n         Self\.Magic := Wuffs\.Runtime\.Magic_Disabled;"
            r"\n         return Wuffs\.Base\.Error_Bad_Argument;"
        )

        def wrap(m):
            return (
                "\n      if Self.G_Active_Coroutine = 0\n        and then\n          ("
                + m.group(1)
                + ")\n      then"
                + "\n         Self.Magic := Wuffs.Runtime.Magic_Disabled;"
                + "\n         return Wuffs.Base.Error_Bad_Argument;"
            )

        s, k = pattern.subn(wrap, s)
        n += k
        open(path, "w").write(s)
    if n < 20:
        sys.exit("mutants.py: only %d argument checks found" % n)


def idct_constant():
    """Changes one multiplier of std/jpeg's scalar inverse DCT, everywhere."""
    path = GEN + "jpeg.adb"
    s = open(path).read()
    n = s.count("16#0000_1151#")
    if n < 8:
        sys.exit("mutants.py: only %d IDCT constants found" % n)
    open(path, "w").write(s.replace("16#0000_1151#", "16#0000_1152#"))


def null_flag_ignored():
    n = 0
    for path in glob.glob(GEN + "*.adb"):
        s = open(path).read()
        n += s.count("if not A_Dst_Null then")
        open(path, "w").write(
            s.replace("if not A_Dst_Null then", "if A_Dst_Null or else not A_Dst_Null then")
        )
    if n < 6:
        sys.exit("mutants.py: only %d null tests found" % n)


INTERLACE_START = "[16#FFFF_FFFF#, 16#0000_0001#, 16#0000_0002#, 16#0000_0004#, 16#0000_0000#]"
PALETTE_LENGTH = "is (if Wuffs.Base.Pixel_Buffers.Has_Palette (PB)\n         and then Palette'Length"

# name: (where, profile, function)
MUTANTS = {
    "01-shell-swizzle-from-slice-no-overlap-check": ("src", "checked", lambda: rep(
        RT, "if Share_An_Element (Dst, Dst_Palette) or else Share_An_Element (Dst, Src) then",
        "if False then")),
    "02-shell-prepare-no-overlap-check": ("src", "checked", lambda: rep(
        RT, "if Share_An_Element (Dst_Palette, Src_Palette) then", "if False then")),
    "03-shell-valid-pixel-buffer-one-byte-short": ("src", "checked", lambda: rep(
        RT, "return Wuffs.Base.Pixel_Buffers.Is_Valid (PB, Pixels'Length, Palette'Length);",
        "return Wuffs.Base.Pixel_Buffers.Is_Valid (PB, Pixels'Length + 1, Palette'Length);")),
    "04-shell-valid-pixel-buffer-skips-valid-attributes": ("src", "checked", lambda: rep(
        RT, "if not (PB.Planes (P).Offset'Valid", "if not (True")),
    "05-shell-shares-storage-off-by-one": ("src", "checked", lambda: rep(
        RT, "return First_Address (A) < Address + Size",
        "return First_Address (A) < Address + (Size - 1)")),
    "06-shell-palette-length-zero": ("src", "checked", lambda: rep(
        RTS, "then Wuffs.Base.Pixel_Formats.Palette_Byte_Length\n       else 0)",
        "then 0\n       else 0)")),
    "07-shell-copy-message-length": ("src", "checked", lambda: rep(
        RT, "Length := Integer'Min (Text'Length, Buffer'Length);",
        "Length := Integer'Min (Text'Length - 1, Buffer'Length);")),
    "09-gen-entry-no-pixels-palette-check": ("src", "checked", lambda: rep(
        G + "lower.go",
        'callNamed("Wuffs.Runtime.Share_An_Element", "A", expr(pixels), "B", expr(palette)))',
        'expr(raw("False")))')),
    "10-gen-entry-palette-not-checked-against-others": ("src", "checked", lambda: rep(
        G + "lower.go", "for _, written := range []eVar{pixels, palette} {",
        "for _, written := range []eVar{pixels} {")),
    "11-gen-io-limit-no-end-limit": ("src", "checked", lambda: rep(
        G + "lower.go",
        'return append(out, sCall{callNamed(ioPkg+".End_Limit",\n'
        '\t\t\t"M", expr(eOut{meta}), "R", expr(eOut{cursor}), "Saved", expr(saved))}), nil',
        "_ = saved\n\t\treturn out, nil")),
    "12-gen-io-bind-writer-history-position-zero": ("src", "checked", lambda: rep(
        G + "lower.go",
        'sAssign{eVar{io.meta}, callNamed(ioPkg+".Writer_Meta", "History_Position", hv.e)},',
        'sAssign{eVar{io.meta}, callNamed(ioPkg+".Writer_Meta", "History_Position", '
        'expr(raw("0")))},')),
    "13-gen-choose-wrong-alternative": ("src", "checked", lambda: rep(
        G + "lower.go", "number = j + 1", "number = len(target.candidates) - j")),
    "14-gen-choose-default-not-restored": ("src", "checked", lambda: rep(
        G + "lower.go",
        "return []stmt{sAssign{eSel{eVar{l.f.self}, target.choiceField}, "
        "raw(fmt.Sprint(number))}}, nil",
        "if number == 0 {\n\t\t\t\treturn nil, nil\n\t\t\t}\n\t\t\t"
        "return []stmt{sAssign{eSel{eVar{l.f.self}, target.choiceField}, "
        "raw(fmt.Sprint(number))}}, nil")),
    "15-gen-iterate-takes-longest-slice": ("src", "checked", lambda: rep(
        G + "lower.go",
        'rel("<", eSel{src, "Length"}, shortest), []stmt{sAssign{shortest, eSel{src, "Length"}}}}}})',
        'rel(">", eSel{src, "Length"}, shortest), []stmt{sAssign{shortest, eSel{src, "Length"}}}}}})')),
    "16-gen-initialize-leaves-swizzler": ("src", "checked", lambda: rep(
        G + "decls.go", 'p.line("Self." + f.name + " := (others => <>);")', 'p.line("null;")')),
    "17-gen-frame-config-swaps-flags": ("src", "checked", lambda: rep(
        G + "lower_call.go",
        '"Disposal", disposal, "Opaque_Within_Bounds", vs[5].e,\n'
        '\t\t\t"Overwrite_Instead_Of_Blend", vs[6].e, "Background_Color", vs[7].e)})',
        '"Disposal", disposal, "Opaque_Within_Bounds", vs[6].e,\n'
        '\t\t\t"Overwrite_Instead_Of_Blend", vs[5].e, "Background_Color", vs[7].e)})')),
    "18-gen-nullptr-test-inverted": ("src", "checked", lambda: rep(
        G + "lower_expr.go", 'if adaOp == "/=" {\n\t\t\t\tnull = eUn{"not", null}',
        'if adaOp == "=" {\n\t\t\t\tnull = eUn{"not", null}')),
    "19-gen-palette-or-else-inverted": ("src", "checked", lambda: rep(
        G + "lower_call.go",
        'branches: []ifBranch{{rel("/=", length, raw("0")), []stmt{sAssign{tmp, h1.e}}}},',
        'branches: []ifBranch{{rel("=", length, raw("0")), []stmt{sAssign{tmp, h1.e}}}},')),
    "20-gen-subtable-swaps-x-bounds": ("src", "checked", lambda: rep(
        G + "lower_call.go",
        '"T", rv.e, "IX", vs[0].e, "IY", vs[1].e, "JX", vs[2].e, "JY", vs[3].e,',
        '"T", rv.e, "IX", vs[2].e, "IY", vs[1].e, "JX", vs[0].e, "JY", vs[3].e,')),
    "21-gen-reset-does-nothing": ("src", "checked", lambda: rep(
        G + "lower_call.go",
        "l.pre = append(l.pre, sCall{call(name, eOut{rv.e})})\n\t\treturn val{}, nil",
        "_ = name\n\t\treturn val{}, nil")),
    "22-gen-message-without-package-prefix": ("src", "checked", lambda: rep(
        G + "decls.go",
        'return g.opts.PackageName + ": " + strings.ReplaceAll(z.msg[1:], "\\"", "\\"\\"")',
        'return g.opts.PackageName + " " + strings.ReplaceAll(z.msg[1:], "\\"", "\\"\\"")')),
    "23-gen-row-u32-off-by-one-row": ("src", "checked", lambda: rep(
        G + "lower_call.go", '"T", rv.e, "Y", vs[0].e, "Length", expr(eAttr{arr, "Length"}),',
        '"T", rv.e, "Y", bin("+", vs[0].e, raw("1")), "Length", expr(eAttr{arr, "Length"}),')),
    "24-gen-peek-u8-at-ignores-offset": ("src", "checked", lambda: rep(
        G + "lower_call.go",
        'callNamed(ioPkg+".Peek_U8_At", "Data", data, "R", c, "Offset", vs[0].e)',
        'callNamed(ioPkg+".Peek_U8_At", "Data", data, "R", c, "Offset", expr(raw("0")))')),
    "25-gen-io-bind-reader-not-closed-flag": ("src", "checked", lambda: rep(
        G + "lower.go",
        '"Data_Length", length, "Closed", expr(raw("False")), "History_Position", hv.e)},',
        '"Data_Length", length, "Closed", expr(raw("True")), "History_Position", hv.e)},')),

    "R01-entry-pixels-not-checked-against-src": ("src", "checked", lambda: rep(
        G + "lower.go", "case kBytes, kBytesVar, kIOReader, kIOWriter:",
        "case kBytes, kBytesVar, kIOWriter:")),
    "R02-valid-buffer-closed-not-validated": ("src", "checked", lambda: rep(
        RTS, "       and then M.Closed'Valid\n", "")),
    "R03-share-an-element-misses-last": ("src", "checked", lambda: rep(
        RT,
        "        and then First_Address (B) < First_Address (A) + SE.Storage_Offset (A'Length);\n"
        "   end Share_An_Element;",
        "        and then First_Address (B) < First_Address (A) + SE.Storage_Offset (A'Length - 1);\n"
        "   end Share_An_Element;")),
    "R04-gif-interlace-start": ("gen", "checked", lambda: rep(
        GEN + "gif.adb", INTERLACE_START, INTERLACE_START.replace("0000#]", "0001#]"))),
    "R04b-gif-interlace-start-pass2": ("gen", "checked", lambda: rep(
        GEN + "gif.adb", INTERLACE_START, INTERLACE_START.replace("0004#", "0005#"))),
    "R04c-gif-interlace-delta-last-pass": ("gen", "checked", lambda: rep(
        GEN + "gif.adb",
        "[16#01#, 16#02#, 16#04#, 16#08#, 16#08#];\n\n   --  Wuffs: const INTERLACE_COUNT",
        "[16#01#, 16#03#, 16#04#, 16#08#, 16#08#];\n\n   --  Wuffs: const INTERLACE_COUNT")),
    "R05-png-end-limit-1-skipped": ("gen", "checked", lambda: drop_end_limit(0)),
    "R18-png-end-limit-2-skipped": ("gen", "checked", lambda: drop_end_limit(1)),
    "R19-png-end-limit-3-skipped": ("gen", "checked", lambda: drop_end_limit(2)),
    "R20-png-end-limit-4-skipped": ("gen", "checked", lambda: drop_end_limit(3)),
    "R06-palette-length-ignores-has-palette": ("src", "checked", lambda: rep(
        RTS, PALETTE_LENGTH,
        "is (if (Wuffs.Base.Pixel_Buffers.Has_Palette (PB) or else PB.Planes (0).Width >= 0)\n"
        "         and then Palette'Length")),
    "R06b-palette-length-ignores-has-palette": ("src", "checked", lambda: rep(
        RTS, PALETTE_LENGTH,
        "is (if (Wuffs.Base.Pixel_Buffers.Has_Palette (PB) or else PB.Pixcfg.Pixfmt.Repr /= 0)\n"
        "         and then Palette'Length")),
    "R06c-palette-length-ignores-has-palette": ("src", "checked", lambda: rep(
        RTS, PALETTE_LENGTH,
        "is (if (Wuffs.Base.Pixel_Buffers.Has_Palette (PB)\n"
        "             or else Wuffs.Base.Pixel_Buffers.Has_Elements (PB.Planes (0)))\n"
        "         and then Palette'Length")),
    "R07-tell-me-more-swaps-x-y": ("src", "checked", lambda: rep(
        G + "lower_call.go",
        '"M", expr(eOut{obj}), "Flavor", vs[0].e, "W", vs[1].e, "X", vs[2].e, "Y", vs[3].e, '
        '"Z", vs[4].e)})',
        '"M", expr(eOut{obj}), "Flavor", vs[0].e, "W", vs[1].e, "X", vs[3].e, "Y", vs[2].e, '
        '"Z", vs[4].e)})')),
    "R08-no-argument-checks-on-resume": ("gen", "checked", no_checks_on_resume),
    "R09-initialize-does-not-zero-arrays": ("src", "checked", lambda: rep(
        G + "decls.go", '\tg.printZeroFill(p, name+" ("+i+")", typ.elem, depth+1)',
        '\tp.line("null;")')),
    "R10-nptr-set-ignores-null": ("gen", "checked", null_flag_ignored),
    "R11-transparent-black-no-overlap-check": ("src", "checked", lambda: rep(
        RT, "      if Share_An_Element (Dst, Dst_Palette) then\n         N := 0;",
        "      if Dst'Length < 0 then\n         N := 0;")),
    "R12-row-u32-one-byte-longer": ("src", "checked", lambda: rep(
        G + "lower_call.go", 'return bytesVal(arr, first, bin("+", first, count), true, false), nil',
        'return bytesVal(arr, first, bin("+", bin("+", first, count), raw("1")), true, false), nil')),
    "R13-prepare-blend-always-src": ("src", "checked", lambda: rep(
        G + "lower_call.go",
        '"Src_Pixfmt", vs[2].e, "Src_Palette", srcPalette.e, "Blend", vs[4].e), nil',
        '"Src_Pixfmt", vs[2].e, "Src_Palette", srcPalette.e, "Blend", expr(raw("0"))), nil')),
    "R14-frame-config-disposal-zero": ("src", "checked", lambda: rep(
        G + "lower_call.go", 'disposal = call(formatsPkg+".Animation_Disposal", disposal)',
        'disposal = call(formatsPkg+".Animation_Disposal", raw("0"))')),
    "R15-reader-copy-to-slice-always-disjoint": ("src", "checked", lambda: rep(
        RT, "      if not Share_An_Element (Data, Dst) then\n         IO.Limited_Copy_U32_To_Slice",
        "      if Data'Length >= 0 then\n         IO.Limited_Copy_U32_To_Slice")),
    "R16-gif-dirty-rect-y": ("gen", "checked", lambda: rep(
        GEN + "gif.adb",
        "Wuffs.Base.Ints.Max_U32 (X => Self.F_Dirty_Max_Excl_Y, Y => V_Replicate_Y1);",
        "Wuffs.Base.Ints.Max_U32 (X => Self.F_Dirty_Max_Excl_Y, Y => V_Replicate_Y0);")),
    "R17-entry-workbuf-not-checked": ("src", "checked", lambda: rep(
        G + "lower.go", "case kBytes, kBytesVar, kIOReader, kIOWriter:",
        "case kBytes, kIOReader, kIOWriter:")),

    "N01-entry-read-only-arrays-in-self-accepted": ("src", "checked", lambda: rep(
        G + "lower.go", "if v.typ.kind == kBytes || v.typ.kind == kBytesVar {\n\t\t\t\tconds",
        "if v.typ.kind == kBytesVar {\n\t\t\t\tconds")),
    "N02-entry-written-arrays-in-self-accepted": ("src", "checked", lambda: rep(
        G + "lower.go", "if v.typ.kind == kBytes || v.typ.kind == kBytesVar {\n\t\t\t\tconds",
        "if v.typ.kind == kBytes {\n\t\t\t\tconds")),
    "N03-entry-booleans-not-validated": ("src", "release", lambda: rep(
        G + "lower.go", "case v.typ.kind == kBool:\n\t\t\t\tconds = append(conds,",
        "case v.typ.kind == kBool:\n\t\t\t\t_ = append(conds,")),
    "N04-entry-bad-argument-does-not-disable": ("src", "checked", lambda: rep(
        G + "lower.go", "body = []stmt{sAssign{magic, raw(rtMagicDisabled)}, ret}",
        "body = []stmt{ret}")),
    "N05-io-limit-exits-accepted": ("src", "checked", lambda: rep(
        G + "lower.go", "if err := l.noExits(n.Body(), keyword); err != nil {",
        "if err := l.noExits(nil, keyword); err != nil {")),
    "N06-positional-library-calls-accepted": ("src", "checked", lambda: rep(
        G + "passes.go", "if _, ok := o.(eNamed); !ok && !positionalCalls[fn.s] {",
        "if _, ok := o.(eNamed); !ok && !positionalCalls[fn.s] && false {")),
    "N07-shares-storage-ignores-object-start": ("src", "checked", lambda: rep(
        RT, "        and then Address < First_Address (A) + SE.Storage_Offset (A'Length);\n"
        "   end Shares_Storage;",
        "        and then Address + 16 < First_Address (A) + SE.Storage_Offset (A'Length);\n"
        "   end Shares_Storage;")),
    "N08-reader-copy-to-slice-swapped-offsets": ("src", "checked", lambda: rep(
        RT, "               R_Base     => U.A_Offset,\n               R          => R,\n"
        "               Up_To      => Up_To,\n               Dst_Offset => U.B_Offset,",
        "               R_Base     => U.B_Offset,\n               R          => R,\n"
        "               Up_To      => Up_To,\n               Dst_Offset => U.A_Offset,")),

    # Milestone 4a.
    "M01-bulk-memset-ignores-value": ("src", "checked", lambda: rep(
        G + "lower_bulk.go", '"Dst", b.e, "Byte_Value", vs[0].e)})',
        '"Dst", b.e, "Byte_Value", expr(raw("0")))})')),
    "M02-sign-extend-rshift-shifts-by-zero": ("src", "checked", lambda: rep(
        G + "lower_call.go",
        'fmt.Sprintf("%s.Sign_Extend_Rshift_U%d", intsPkg, bits), "A", vs[0].e, "N", vs[1].e),',
        'fmt.Sprintf("%s.Sign_Extend_Rshift_U%d", intsPkg, bits), "A", vs[0].e, "N", expr(raw("0"))),')),
    "M03-sign-extend-convert-zero-extends": ("src", "checked", lambda: rep(
        G + "lower_call.go",
        'return val{e: call(intsPkg+".Sign_Extend_Convert_U"+m[1]+"_U"+m[2], vs[0].e), typ: numType(to)}, nil',
        'return val{e: call("Wuffs.U"+m[2], vs[0].e), typ: numType(to)}, nil')),
    "M04-i64-divide-swaps-operands": ("src", "checked", lambda: rep(
        G + "lower_call.go", 'callNamed(intsPkg+".I64_Divide", "A", vs[0].e, "B", vs[1].e)',
        'callNamed(intsPkg+".I64_Divide", "A", vs[1].e, "B", vs[0].e)')),
    "M05-forget-history-no-end": ("src", "checked", lambda: rep(
        G + "lower.go",
        'return append(out, sCall{callNamed(ioPkg+".End_Forget_History",\n'
        '\t\t\t"M", expr(eOut{meta}), "W", expr(eOut{cursor}), "Saved", expr(eVar{saved}))}), nil',
        "return out, nil")),
    "M06-forget-history-callee-gets-whole-array": ("src", "checked", lambda: rep(
        G + "lower_call.go",
        'first := bin("+", eAttr{v.io.data, "First"}, call(ioPkg+".Forgotten_Base", eVar{saved}))',
        'first := expr(eAttr{v.io.data, "First"})')),
    "M07-forget-history-no-reload": ("src", "checked", lambda: rep(
        G + "lower_call.go",
        'l.post = append(l.post, sCall{callNamed(ioPkg+".Reload_Forgotten",',
        '_ = append(l.post, sCall{callNamed(ioPkg+".Reload_Forgotten",')),
    "M08-bitvec256-get-u64-ignores-index": ("src", "checked", lambda: rep(
        G + "lower_call.go", 'callNamed(intsPkg+".Get_U64", "B", rv.e, "I", vs[0].e)',
        'callNamed(intsPkg+".Get_U64", "B", rv.e, "I", expr(raw("0")))')),
    "M09-make-bitvec256-reverses-elements": ("src", "checked", lambda: rep(
        G + "lower_call.go", '"E00", vs[0].e, "E01", vs[1].e, "E02", vs[2].e, "E03", vs[3].e),',
        '"E00", vs[3].e, "E01", vs[2].e, "E02", vs[1].e, "E03", vs[0].e),')),
    "M10-boolean-constant-arrays-inverted": ("src", "checked", lambda: rep(
        G + "decls.go", 's = "False"\n\t\t\tif o.AsExpr().ConstValue().Sign() != 0 {',
        's = "False"\n\t\t\tif o.AsExpr().ConstValue().Sign() == 0 {')),
    "M11-return-cusp-copies-through-the-plain-copy": ("src", "checked", lambda: rep(
        G + "lower_call.go", 'return l.procResult(ioPkg+"."+mangle(name), typU32, out,',
        'return l.procResult(ioPkg+"."+mangle(strings.TrimSuffix(name, "_return_cusp")), typU32, '
        'strings.Replace(out, "Cusp", "N", 1),')),
    "M12-writer-peek-undo-byte-reads-the-reader-way": ("src", "checked", lambda: rep(
        G + "lower_call.go", 'return val{e: callNamed(ioPkg+".Peek_Undo_Byte", "Data", data, cursor, c), typ: typU8}, nil',
        'return val{e: call("Wuffs.U8", raw("0"+cursor[:0])), typ: typU8}, nil')),

    # The JPEG milestone: the bulk methods, swizzle_ycck, row pointers,
    # status fields, and std/jpeg's own generated code.
    "J01-shell-bulk-load-u16-pairs-the-wrong-bytes": ("src", "checked", lambda: rep(
        RT, "Wuffs.Base.Slices.Bulk_Load_Host_Endian_U16 (Dst => Dst, Src => Src);",
        "Wuffs.Base.Slices.Bulk_Load_Host_Endian_U16\n           (Dst => Dst, Src => Src (Src'First + 1 .. Src'Last));")),
    "J02-gen-bulk-rows-all-into-the-first": ("src", "checked", lambda: rep(
        G + "lower_bulk.go", "row := eCall{arr.e, []expr{k}}", "row := eCall{arr.e, []expr{lo}}")),
    "J03-gen-bulk-row-offset-ignores-lo": ("src", "checked", lambda: rep(
        G + "lower_bulk.go", 'rowIndex = bin("-", k, lo)', "rowIndex = k")),
    "J04-gen-bulk-fits-counts-rows-not-elements": ("src", "checked", lambda: rep(
        G + "lower_bulk.go", 'count := bin("*", bin("-", hi, lo), raw(rowLen.String()))',
        'count := bin("-", hi, lo)')),
    "J05-gen-bulk-memset-rows-every-other-row": ("src", "checked", lambda: rep(
        G + "lower_bulk.go", '"Dst", expr(row), "Byte_Value", arg.e)})...)',
        '"Dst", expr(row), "Byte_Value", arg.e)}, sAssign{k, bin("+", k, raw("1"))})...)')),
    "J06-gen-ycck-planes-1-and-2-swapped": ("src", "checked", lambda: rep(
        G + "lower_call.go", "src, err := view(vs[6+i], false)",
        "src, err := view(vs[6+[]int{0, 2, 1, 3}[i]], false)")),
    "J07-jpeg-ycck-stride0-of-plane-1": ("gen", "checked", lambda: rep(
        GEN + "jpeg.adb", "Stride0 => V_Width0,", "Stride0 => V_Width1,")),
    "J08-shell-ycck-scratch-overlap-unchecked": ("src", "checked", lambda: rep(
        RT, "        or else Touches_A_Source (Scratch_Buffer_2K)\n", "")),
    "J09-shell-ycck-pixels-scratch-overlap-unchecked": ("src", "checked", lambda: rep(
        RT, "        or else Share_An_Element (Pixels, Scratch_Buffer_2K)\n", "")),
    "J10-shell-ycck-pixel-buffer-not-validated": ("src", "checked", lambda: rep(
        RT, "      if not Valid_Pixel_Buffer (PB => PB, Pixels => Pixels, Palette => Palette)\n",
        "      if False\n")),
    "J11-gen-row-pointer-always-row-0": ("src", "checked", lambda: rep(
        G + "lower.go", "return l.flush(sAssign{eVar{v}, iv}), nil", 'return l.flush(sAssign{eVar{v}, raw("0" + flat(iv)[:0])}), nil')),
    "J12-jpeg-decode-sos-my-not-saved": ("gen", "checked", lambda: rep(
        GEN + "jpeg.adb", "      Self.G_S_17_Decode_Sos_My := V_My;\n", "      null;\n")),
    "J13-jpeg-restart-counter-counts-up": ("gen", "checked", lambda: rep(
        GEN + "jpeg.adb", "Self.F_Restarts_Remaining := Self.F_Restarts_Remaining - 1;",
        "Self.F_Restarts_Remaining := Self.F_Restarts_Remaining + 1;")),
    "J14-jpeg-scalar-idct-constant": ("gen", "checked", idct_constant),
    "J15-jpeg-swizzle-immediately-status-ignored": ("gen", "checked", lambda: rep(
        GEN + "jpeg.adb", "G_Status := Self.F_Swizzle_Immediately_Status;", "G_Status := Wuffs.Ok_Status;")),
    # The vp8/webp milestone: nullable pixel buffers at an entry and in calls,
    # the new built-ins, the shell's swizzle_ycck, generated vp8/webp code.
    "W01-gen-entry-nullable-pixbuf-checked-when-null": ("src", "checked", lambda: rep(
        G + "lower.go", "\t\treturn bin(\"and then\", eUn{\"not\", eVar{arg.null}}, e)",
        "\t\treturn bin(\"and then\", raw(\"True\"), e)")),
    "W02-gen-entry-nullable-pixbuf-descriptor-not-checked": ("src", "checked", lambda: rep(
        G + "lower.go", "\t\tif arg.typ.kind == kNptrPixBuf {\n\t\t\town = append(own, sharesSelf(arg.pixels), sharesSelf(arg.palette))\n\t\t}",
        "\t\tif arg.typ.kind == kNptrPixBuf {\n\t\t\town = append(own[1:], sharesSelf(arg.pixels), sharesSelf(arg.palette))\n\t\t}")),
    "W03-gen-entry-nullable-pixbuf-arrays-in-self-accepted": ("src", "checked", lambda: rep(
        G + "lower.go", "\t\t\town = append(own, sharesSelf(arg.pixels), sharesSelf(arg.palette))",
        "\t\t\town = append(own)")),
    "W04-gen-ptr-to-nptr-passes-null": ("src", "checked", lambda: rep(
        G + "lower_call.go",
        "values = append(values, eVar{v.parg.v}, raw(\"False\"), eVar{v.parg.pixels}, eVar{v.parg.palette})",
        "values = append(values, eVar{v.parg.v}, raw(\"True\"), eVar{v.parg.pixels}, eVar{v.parg.palette})")),
    "W05-gen-nullptr-pixbuf-passes-not-null": ("src", "checked", lambda: rep(
        G + "lower_call.go",
        "values = append(values, raw(buffersPkg+\".Null_Pixel_Buffer\"), raw(\"True\"), arrs[0], arrs[1])",
        "values = append(values, raw(buffersPkg+\".Null_Pixel_Buffer\"), raw(\"False\"), arrs[0], arrs[1])")),
    "W06-gen-demake-pixel-blend-zero": ("src", "checked", lambda: rep(
        G + "lower_call.go", "return val{e: call(formatsPkg+\".Demake_Pixel_Blend\", vs[0].e), typ: typU8}, nil",
        "return val{e: call(\"Wuffs.U8\", bin(\"and\", call(formatsPkg+\".Demake_Pixel_Blend\", vs[0].e), raw(\"0\"))), typ: typU8}, nil")),
    "W07-gen-make-pixel-blend-src": ("src", "checked", lambda: rep(
        G + "lower_call.go", "return val{e: call(formatsPkg+\".Make_Pixel_Blend\", vs[0].e), typ: typPixelBlend}, nil",
        "return val{e: call(formatsPkg+\".Make_Pixel_Blend\", bin(\"and\", vs[0].e, raw(\"0\"))), typ: typPixelBlend}, nil")),
    "W08-gen-range-is-empty-inverted": ("src", "checked", lambda: rep(
        G + "lower_call.go", "\t\treturn val{e: call(rangesPkg+\".\"+mangle(name), rv.e), typ: ret}, nil",
        "\t\tif name == \"is_empty\" {\n\t\t\treturn val{e: eUn{\"not\", call(rangesPkg+\".Is_Empty\", rv.e)}, typ: ret}, nil\n\t\t}\n"
        "\t\treturn val{e: call(rangesPkg+\".\"+mangle(name), rv.e), typ: ret}, nil")),
    "W09-gen-range-min-max-swapped": ("src", "checked", lambda: rep(
        G + "lower_call.go", "\t\treturn val{e: call(rangesPkg+\".\"+mangle(name), rv.e), typ: ret}, nil",
        "\t\tswapped := map[string]string{\"get_min_incl\": \"Get_Max_Incl\", \"get_max_incl\": \"Get_Min_Incl\", "
        "\"is_empty\": \"Is_Empty\"}[name]\n\t\treturn val{e: call(rangesPkg+\".\"+swapped, rv.e), typ: ret}, nil")),
    "W10-shell-ycck-alpha-plane-overlap-accepted": ("src", "checked", lambda: rep(
        RT, "         or else Share_An_Element (W, Src2)\n         or else Share_An_Element (W, Src3));",
        "         or else Share_An_Element (W, Src2));")),
    "W11-vp8-box-upsampling": ("gen", "checked", lambda: rep(
        GEN + "vp8.adb", "YCC_Upsampling => Wuffs.U8'(2),", "YCC_Upsampling => Wuffs.U8'(1),")),
    "W12-vp8-filter-sharpness-shift": ("gen", "checked", lambda: rep(
        GEN + "vp8.adb", "V_Ilevel := Interfaces.Shift_Right (V_Ilevel, 1);",
        "V_Ilevel := Interfaces.Shift_Right (V_Ilevel, 2);")),
    "W13-webp-color-cache-hash": ("gen", "checked", lambda: rep(
        GEN + "webp.adb", "16#1E35_A7BD#", "16#1E35_A7BF#")),
    "W14-webp-distance-map-entry": ("gen", "checked", lambda: rep(
        GEN + "webp.adb", "16#38#, 16#05#, 16#37#", "16#38#, 16#06#, 16#37#")),
    "W15-webp-entry-checks-only-the-first-512-bytes": ("gen", "checked", lambda: rep(
        GEN + "webp.adb", "Size_In_Bits => Self'Size", "Size_In_Bits => 8 * 512", count=8)),
    "W16-webp-subtract-green-skips-blue": ("gen", "checked", lambda: rep(
        GEN + "webp.adb", "Wuffs.Runtime.Set (S => V_P, I => 0, V => Wuffs.Runtime.Get (V_P, 0) + V_G);",
        "null;")),

    # The webp2 milestone (upstream fixes and animations in the fork): the
    # generated code of std/webp and std/vp8 that changed. Run them in both
    # profiles, with MUTATION_FORMATS='webp|vp8'.
    "W17-webp-anmf-x-offset-not-doubled": ("gen", "checked", lambda: rep(
        GEN + "webp.adb", "V_X0 := 2 * V_C32;", "V_X0 := V_C32;")),
    "W18-webp-anmf-duration-units": ("gen", "checked", lambda: rep(
        GEN + "webp.adb", "Wuffs.U64 (V_C32) * 705600;", "Wuffs.U64 (V_C32) * 7056000;")),
    "W19-webp-anmf-blend-bit": ("gen", "checked", lambda: rep(
        GEN + "webp.adb", "Self.F_Frame_Overwrite_Instead_Of_Blend := (V_Flags and 16#02#) /= 0;",
        "Self.F_Frame_Overwrite_Instead_Of_Blend := (V_Flags and 16#01#) /= 0;")),
    "W20-webp-anmf-dispose-ignored": ("gen", "checked", lambda: rep(
        GEN + "webp.adb", "Self.F_Frame_Disposal := 1;", "Self.F_Frame_Disposal := 0;")),
    "W21-webp-frame-x-offset-not-applied": ("gen", "checked", lambda: rep(
        GEN + "webp.adb", "V_Dst_Bytes_Per_Row0 := Wuffs.U64 (Self.F_Frame_Rect_X0 * V_Dst_Bytes_Per_Pixel);",
        "V_Dst_Bytes_Per_Row0 := 0;")),
    "W22-webp-vp8l-bits-not-reset": ("gen", "checked", lambda: rep(
        GEN + "webp.adb", "      Self.F_Bits := 0;\n      Self.F_N_Bits := 0;\n      Self.F_Workbuf_Offset_For_Color_Indexing := 0;",
        "      Self.F_Workbuf_Offset_For_Color_Indexing := 0;")),
    "W23-webp-anmf-workbuf-offsets-stale": ("gen", "checked", lambda: rep(
        GEN + "webp.adb", "Self.F_Workbuf_Offset_For_Transform (0) := 4 * V_W * V_H + 0 * V_Transform_Size;",
        "null;")),
    "W24-webp-distance-not-clamped": ("gen", "checked", lambda: rep(
        GEN + "webp.adb", "if V_Back_Ref_Dist_Minus_1 >= 16#8000_0000# then\n            V_Back_Ref_Dist_Minus_1 := 0;",
        "if V_Back_Ref_Dist_Minus_1 >= 16#8000_0000# then\n            V_Back_Ref_Dist_Minus_1 := 1;")),
    "W25-vp8-sharpness-max-again": ("gen", "checked", lambda: rep(
        GEN + "vp8.adb", "Wuffs.Base.Ints.Min_U32 (X => V_Ilevel,", "Wuffs.Base.Ints.Max_U32 (X => V_Ilevel,")),
    "W26-vp8-level-zero-filtered": ("gen", "checked", lambda: rep(
        GEN + "vp8.adb", "if V_Level = 0 or else V_Level >= 16#8000_0000# then",
        "if V_Level >= 16#8000_0000# then")),
    # W27 to W29 used to fault std/vp8's own copy of the YCbCr conversion for
    # a frame at an offset, which is gone: swizzle_ycck now takes the offset.
    "W27-vp8-dst-x-offset-not-passed": ("gen", "checked", lambda: rep(
        GEN + "vp8.adb", "Dst_X_Offset => Self.F_Quirk_Dst_X,", "Dst_X_Offset => 0,")),
    "W28-webp-dst-quirk-y-in-wrong-half": ("gen", "checked", lambda: rep(
        GEN + "webp.adb", "(Wuffs.U64 (Self.F_Frame_Rect_Y0),\n                                                    32));",
        "(Wuffs.U64 (Self.F_Frame_Rect_Y0),\n                                                    31));")),
    "W29-shell-ycck-dst-y-offset-dropped": ("src", "checked", lambda: rep(
        RT, "Dst_Y_Offset      => Dst_Y_Offset,", "Dst_Y_Offset      => Wuffs.U32'Min (Dst_Y_Offset, 1),")),
    "W30-webp-restart-chunk-length-not-restored": ("gen", "checked", lambda: rep(
        GEN + "webp.adb", "Self.F_Sub_Chunk_Length := Self.F_Frame_Sub_Chunk_Length;", "null;")),
    # The review of the webp2 milestone: the RIFF bound of the chunk peek
    # after VP8X/ANIM, the count of a skipped still frame, the loop filter's
    # clip_m16_p15.
    "W31-webp-anim-peek-not-bounded-by-riff": ("gen", "checked", lambda: rep(
        GEN + "webp.adb", "Y => Wuffs.Base.IO.Position (G_R_Src))\n           >= 8\n      then\n         goto G_Else_4;",
        "Y => Wuffs.Base.IO.Position (G_R_Src))\n           >= 0\n      then\n         goto G_Else_4;")),
    "W32-webp-skipped-still-frame-not-counted": ("gen", "checked", lambda: rep(
        GEN + "webp.adb", "         goto G_Else_5;\n      end if;\n      Self.F_Num_Decoded_Frames_Value :=\n"
        "        Wuffs.Base.Ints.Sat_Add_U64 (X => Self.F_Num_Decoded_Frames_Value, Y => 1);",
        "         goto G_Else_5;\n      end if;")),
    "W33-vp8-clip-m16-p15-off-by-one": ("gen", "checked", lambda: rep(
        GEN + "vp8.adb", "if A_A + 16#10# <= 16#1F# then", "if A_A + 16#10# <= 16#20# then")),
    # ---- The json/cbor (token I/O) milestone.
    "T01-gen-token-major-and-minor-swapped": ("src", "checked", lambda: rep(
        G + "lower_call.go", 'adaNames := []string{"Value_Major", "Value_Minor", "Continued", "Length"}',
        'adaNames := []string{"Value_Minor", "Value_Major", "Continued", "Length"}')),
    "T02-gen-no-token-reload-after-callee": ("src", "checked", lambda: rep(
        G + "lower_call.go", '\t\t\t\tl.post = append(l.post, sCall{call(tokensPkg+".Reload", cursor, meta)})\n', "")),
    "T03-gen-no-token-save-before-callee": ("src", "checked", lambda: rep(
        G + "lower_call.go", '\t\t\t\tl.pre = append(l.pre, sCall{call(tokensPkg+".Save", meta, cursor)})\n', "")),
    "T04-gen-no-token-save-at-exit": ("src", "checked", lambda: rep(
        G + "lower.go", "\tfor _, io := range l.ioList {\n\t\tif io.cursor != nil {\n\t\t\tio.meta.writes++",
        "\tfor _, io := range l.ioList {\n\t\tif io.cursor != nil && !io.tokens {\n\t\t\tio.meta.writes++")),
    "T05-json-a-continued-bit-cleared": ("gen", "checked", lambda: nth_rep(
        GEN + "json.adb", "Continued => 1", "Continued => 0", 4)),
    "T06-json-replace-invalid-unicode-quirk-index": ("gen", "checked", lambda: rep(
        GEN + "json.adb", "F_Quirks (20)", "F_Quirks (19)", count=7)),
    "T07-cbor-text-not-checked-for-utf8": ("gen", "checked", lambda: rep(
        GEN + "cbor.adb",
        "V_N64 := Wuffs.Base.UTF8.Valid_UTF_8_Length (Data => A_Src, R => G_R_Src, Up_To => V_N64);",
        "V_N64 := Wuffs.U64'Min (V_N64, Wuffs.Base.IO.Length (G_R_Src))\n"
        "        + 0 * Wuffs.Base.UTF8.Valid_UTF_8_Length (Data => A_Src, R => G_R_Src, Up_To => V_N64);")),
    "T08-json-depth-limit-1023": ("gen", "checked", lambda: rep(
        GEN + "json.adb", "if V_Depth = 1024 then", "if V_Depth = 1023 then", count=2)),
    "T09-cbor-additional-info-26-branch": ("gen", "checked", lambda: rep(
        GEN + "cbor.adb", "elsif V_C_Minor = 16#1A# then", "elsif V_C_Minor = 16#1B# then")),
    "T10-shell-tokens-source-overlap-missed": ("src", "checked", lambda: rep(
        RT, "return Tokens (Tokens'First)'Address < First_Address (B) + SE.Storage_Offset (B'Length)",
        "return Tokens (Tokens'First)'Address < First_Address (B) - SE.Storage_Offset (B'Length)")),
    "T11-shell-token-write-index-one-beyond-accepted": ("src", "checked", lambda: rep(
        RTS, "       and then M.Ri <= M.Wi\n       and then M.Wi <= Data'Length)\n   with Inline;\n\n"
        "   --  True if the array of tokens",
        "       and then M.Ri <= M.Wi\n       and then M.Wi - 1 <= Data'Length)\n   with Inline;\n\n"
        "   --  True if the array of tokens")),
    "T12-gen-no-token-overlap-check": ("src", "checked", lambda: rep(
        G + "lower.go", '\t\t\t\tconds = append(conds, callNamed("Wuffs.Runtime.Tokens_Share_Storage",',
        '\t\t\t\t_ = append(conds, callNamed("Wuffs.Runtime.Tokens_Share_Storage",')),
    "T13-gen-token-array-in-self-unchecked": ("src", "checked", lambda: rep(
        G + "lower.go", "if v.typ.kind == kBytes || v.typ.kind == kBytesVar || v.typ.kind == kTokenArray {",
        "if v.typ.kind == kBytes || v.typ.kind == kBytesVar {")),
    "T14-gen-peek-u64le-at-offset-plus-1": ("src", "checked", lambda: rep(
        G + "lower_call.go", 'callNamed(ioPkg+".Peek_U64LE_At", "Data", data, "R", c, "Offset", vs[0].e)',
        'callNamed(ioPkg+".Peek_U64LE_At", "Data", data, "R", c, "Offset", bin("+", vs[0].e, raw("1")))')),
    "T15-gen-valid-utf8-length-up-to-plus-1": ("src", "checked", lambda: rep(
        G + "lower_call.go", '"Data", data, "R", c, "Up_To", vs[0].e)',
        '"Data", data, "R", c, "Up_To", bin("+", vs[0].e, raw("1")))')),
    "T16-shell-token-storage-half-size": ("src", "checked", lambda: rep(
        RT, "(Wuffs.U64_Array'Component_Size / System.Storage_Unit)",
        "(Wuffs.U64_Array'Component_Size / 2 / System.Storage_Unit)")),
    "T17-json-match7-true-misspelt": ("gen", "checked", lambda: rep(
        GEN + "json.adb", "A => 16#65_7572_7404#", "A => 16#65_7572_7304#")),
    "T19-cbor-additional-info-26-reads-big-endian-as-little": ("gen", "checked", lambda: rep(
        GEN + "cbor.adb",
        "V_String_Length := Wuffs.U64 (Wuffs.Base.IO.Peek_U32BE (A_Src, G_R_Src));",
        "V_String_Length := Wuffs.U64 (Wuffs.Base.IO.Peek_U32LE (A_Src, G_R_Src));")),
    "T18-gen-continued-argument-dropped": ("src", "checked", lambda: rep(
        G + "lower_call.go", "\t\t\tnamed = append(named, adaNames[i], vs[i].e)\n",
        "\t\t\tif adaNames[i] == \"Continued\" {\n\t\t\t\tnamed = append(named, adaNames[i], raw(\"0\"))\n"
        "\t\t\t\tcontinue\n\t\t\t}\n\t\t\tnamed = append(named, adaNames[i], vs[i].e)\n")),
    # The SIMD milestone.
    "S01-adler32-simd-shift-count": ("gen", "checked", lambda: rep(
        GENS + "adler32-x86_sse42.adb", "Imm8 => 5)", "Imm8 => 4)")),
    "S02-wrapper-sub-epi16-operands-swapped": ("src", "checked", lambda: rep(
        SSE42, "is (From_V8HI (B_Psubw128 (To_V8HI (X), To_V8HI (B))));",
        "is (From_V8HI (B_Psubw128 (To_V8HI (B), To_V8HI (X))));")),
    "S03-png-simd-sub-epi16-operands-swapped": ("gen", "checked", lambda: rep(
        GENS + "png-x86_sse42.adb", "V_Pa128 := Wuffs.Runtime.X86.SSE42.Mm_Sub_Epi16 (X => V_B128, B => V_C128);",
        "V_Pa128 := Wuffs.Runtime.X86.SSE42.Mm_Sub_Epi16 (X => V_C128, B => V_B128);", count=7)),
    "S04-adler32-simd-shuffle-constant": ("gen", "checked", lambda: nth_rep(
        GENS + "adler32-x86_sse42.adb", "Imm8 => 177)", "Imm8 => 180)", 0)),
    "S05-wrapper-load-offset-by-one": ("src", "checked", lambda: rep(
        SSE42, "function Make_M128i_Slice128 (A : Wuffs.Bytes) return M128I\n   is (From_V16QI (B_Lddqu (A (A'First)'Address)));",
        "function Make_M128i_Slice128 (A : Wuffs.Bytes) return M128I\n   is (From_V16QI (B_Lddqu (A (A'First + 1)'Address)));")),
    "S06-adler32-simd-tail-dropped": ("gen", "checked", lambda: rep(
        GENS + "adler32-x86_sse42.adb", "if V_Tail_Index < Wuffs.U64 (M_X.Length) then",
        "if V_Tail_Index > Wuffs.U64 (M_X.Length) then")),
    "S07-crc32-simd-byte-tail-dropped": ("gen", "checked", lambda: rep(
        GENS + "crc32-x86_sse42.adb", "      while Wuffs.U64 (M_X.Length) > 0 loop\n         V_S :=",
        "      while Wuffs.U64 (M_X.Length) > 8 loop\n         V_S :=")),
    "S08-cpuid-wrong-sse42-feature-bit": ("src", "checked", lambda: rep(
        CPUID, "SSE42_Ecx1 : constant Unsigned_32 := 16#0090_0002#;",
        "SSE42_Ecx1 : constant Unsigned_32 := 16#0090_0006#;")),
    "S09-gen-choose-always-scalar": ("src", "checked", lambda: rep(
        G + "lower.go", "branches = append(branches, ifBranch{call(haveFeature(callee.simd)), assign})",
        "branches = append(branches, ifBranch{raw(\"False\"), assign})")),
    "S10-gen-choose-always-simd": ("src", "checked", lambda: rep(
        G + "lower.go", "branches = append(branches, ifBranch{call(haveFeature(callee.simd)), assign})",
        "branches = append(branches, ifBranch{raw(\"True\"), assign})")),
    "S11-crc32-simd-wrong-clmul-selector": ("gen", "checked", lambda: nth_rep(
        GENS + "crc32-x86_sse42.adb", "B => V_Kk, Imm8 => 17);", "B => V_Kk, Imm8 => 16);", 0)),
    "S12-jpeg-simd-idct-constant": ("gen", "checked", lambda: nth_rep(
        GENS + "jpeg-x86_avx2.adb", "(A00 => 16#29CF#,", "(A00 => 16#29CE#,", 0)),
    "S13-wrapper-add-epi16-wrong-lane-view": ("src", "checked", lambda: rep(
        SSE42, "is (From_V8HI (B_Paddw128 (To_V8HI (X), To_V8HI (B))));",
        "is (From_V16QI (B_Paddb128 (To_V16QI (X), To_V16QI (B))));")),
    "S14-wrapper-min-epi16-wrong-builtin": ("src", "checked", lambda: rep(
        SSE42, 'External_Name => "__builtin_ia32_pminsw128";', 'External_Name => "__builtin_ia32_pmaxsw128";')),
    "S15-wrapper-single-u32-wrong-lane": ("src", "checked", lambda: rep(
        SSE42, "is (From_U32x4 ([A, 0, 0, 0]));", "is (From_U32x4 ([0, A, 0, 0]));")),
    "S16-deflate-bmi2-bits-constant": ("gen", "checked", lambda: rep(
        GENS + "deflate-x86_bmi2.adb", "V_N_Bits := V_N_Bits or 56;", "V_N_Bits := V_N_Bits or 48;")),
}


# Mutants that survive every test because they change nothing that can be
# observed. They were investigated in milestone 3: do not investigate again.
EQUIVALENT = {
    "R04-gif-interlace-start":
        "INTERLACE_START[4] is never read: std/gif reads INTERLACE_START[this.interlace] only "
        "right after 'this.interlace -= 1' (decode_gif.wuffs, two places), and interlace starts "
        "at 4, so the indexes read are 3, 2, 1 and 0.",
    "R16-gif-dirty-rect-y":
        "After 'while replicate_y0 < replicate_y1 { ...; replicate_y0 += 1 }' replicate_y0 equals "
        "replicate_y1 whenever the loop ran, and when it did not run replicate_y0 (dst_y + 1) is "
        "already no greater than the dirty_max_excl_y that the line before the block set, so "
        "max(dirty_max_excl_y, replicate_y0) = max(dirty_max_excl_y, replicate_y1). test_image "
        "hashes the dirty rect at every call, suspended ones included.",
    "R15-reader-copy-to-slice-always-disjoint":
        "Wuffs.Base.IO.Limited_Copy_U32_To_Slice, as compiled, gives memmove results when its "
        "two arrays overlap (test_runtime checks all 16 layouts through the shell, with the "
        "reader at two positions and three limits), so the disjoint and the _Within form cannot "
        "be told apart from outside. The shell still must dispatch: the disjoint form's proof "
        "assumes no overlap. A wrong _Within call is caught (mutant N08).",
}


def main():
    if len(sys.argv) == 2 and sys.argv[1] == "list":
        for name, (where, profile, _) in MUTANTS.items():
            print(name, where, profile, "equivalent" if name in EQUIVALENT else "-")
    elif len(sys.argv) == 3 and sys.argv[1] == "why" and sys.argv[2] in EQUIVALENT:
        print(EQUIVALENT[sys.argv[2]])
    elif len(sys.argv) == 3 and sys.argv[1] == "apply" and sys.argv[2] in MUTANTS:
        MUTANTS[sys.argv[2]][2]()
    else:
        sys.exit(__doc__)


if __name__ == "__main__":
    main()
