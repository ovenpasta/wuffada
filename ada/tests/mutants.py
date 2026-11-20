#!/usr/bin/env python3
# Part of wuffada (wuffs-ada: Wuffs to Ada).
# SPDX-License-Identifier: Apache-2.0 OR MIT
"""The mutants of ada/tests/mutation.sh: deliberate faults, one at a time.

usage: mutants.py list              print "NAME WHERE PROFILE" for each mutant
       mutants.py apply NAME        apply it to the tree in the current directory

WHERE is "src" (a fault in the generator or in the runtime shell: apply it,
then run ./gen.sh) or "gen" (a fault in the generated Ada: run ./gen.sh, then
apply it). PROFILE is the build profile that the mutant is tested with.
Mutants 01 to 25 are the implementer's of milestone 3, R01 to R20 came from
the independent review of it, and N01 to N08 cover the review's fixes.
"""

import glob
import re
import sys

G = "internal/adagen/"
RT = "ada/src/runtime/wuffs-runtime.adb"
RTS = "ada/src/runtime/wuffs-runtime.ads"
GEN = "ada/gen/wuffs-std-"


def rep(path, old, new, count=1):
    s = open(path).read()
    if s.count(old) != count:
        sys.exit("mutants.py: %d occurrences of %r in %s" % (s.count(old), old, path))
    open(path, "w").write(s.replace(old, new))


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
}


def main():
    if len(sys.argv) == 2 and sys.argv[1] == "list":
        for name, (where, profile, _) in MUTANTS.items():
            print(name, where, profile)
    elif len(sys.argv) == 3 and sys.argv[1] == "apply" and sys.argv[2] in MUTANTS:
        MUTANTS[sys.argv[2]][2]()
    else:
        sys.exit(__doc__)


if __name__ == "__main__":
    main()
