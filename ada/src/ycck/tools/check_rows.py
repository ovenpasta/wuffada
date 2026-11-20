#!/usr/bin/env python3
"""Checks that the two set procedures of Wuffs.Base.Pixel_Buffers.Rows
(ada/src/ycck/wuffs-base-pixel_buffers-rows.adb) still have, format for
format, the code of their checked counterparts in the parent package body
(ada/src/pixel/wuffs-base-pixel_buffers.adb): Set_Color_U32_At and
Set_Color_U32_ARGB_Nonpremul_At.  The child's code is the parent's with

  - the computation of the pixel's position removed (the child is given
    it) and P renamed to Pos;
  - the alternatives for the two formats that the child does not support
    (BGRA_PREMUL_4X16LE, BGRA_BINARY) removed;
  - the `others` alternative an assertion that it cannot be reached.

Exits non-zero, naming the procedure, if that is no longer so.  Run by
ada/tests_ycck/run_all.sh.

    python3 check_rows.py
"""

import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
PARENT = os.path.join(HERE, "..", "..", "pixel", "wuffs-base-pixel_buffers.adb")
CHILD = os.path.join(HERE, "..", "wuffs-base-pixel_buffers-rows.adb")


def case_of(text, procedure):
    a = text.index("   procedure %s\n" % procedure)
    a = text.index("      case F is\n", text.index("   begin\n", a))
    b = text.index("      end case;\n", a) + len("      end case;\n")
    return text[a:b]


def expected(parent_case):
    c = re.sub(r"            P := Pixels'First \+ Pixel_Start \(PB, Pixels'Length, X, Y, \d\);\n",
               "", parent_case)
    c = re.sub(r"\bP\b", "Pos", c)
    c = re.sub(r"         when Repr_BGRA_Premul_4x16LE =>\n.*?(?=         when Repr_RGB =>)",
               "", c, flags=re.S)
    c = c.replace("            Result := Error_Unsupported_Option;\n",
                  "            --  Not a supported format: excluded by the precondition.\n"
                  "            pragma Assert (False);\n")
    return c


def main():
    parent = open(PARENT).read()
    child = open(CHILD).read()
    ok = True
    for theirs, ours in (("Set_Color_U32_At", "Set_Color_U32_At_Position"),
                         ("Set_Color_U32_ARGB_Nonpremul_At",
                          "Set_Color_U32_ARGB_Nonpremul_At_Position")):
        want = expected(case_of(parent, theirs))
        if "Pixel_Start" in want or "Result" in want:
            print("check_rows: %s in the parent no longer has the expected shape" % theirs)
            ok = False
        elif case_of(child, ours) != want:
            print("check_rows: %s differs from the parent's %s" % (ours, theirs))
            ok = False
    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()
