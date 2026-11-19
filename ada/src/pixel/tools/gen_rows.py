#!/usr/bin/env python3
"""Generates wuffs-base-pixel_rows.ads / .adb from upstream's C.

    python3 gen_rows.py [path/to/wuffs checkout] [output directory]

Defaults: ../../../../wuffs and .. (ada/src/pixel), relative to this file.
It also writes ada/tests_pixel/oracle/row_funcs.inc, the list of row
functions that the test oracle calls one by one.
The checked-in wuffs-base-pixel_rows.ad[sb] and row_funcs.inc must be
exactly this script's output for the pinned upstream commit; `gen_rows.py --check` exits non-zero
if they are not.

Input: wuffs/internal/cgen/base/pixconv-submodule-regular.c.  Every
`wuffs_private_impl__swizzle_*` row function (except the x86 SIMD ones) and
every `wuffs_private_impl__composite_*` helper is translated to Ada
statement by statement:

  * C's `len = min(dst_len / DB, src_len / SB)` becomes the bound of a
    `for` loop over pixels; the body of C's final `while (n >= 1)` (or
    `while (n--)`) loop becomes the body of that loop.
  * Everything else in a row function is NOT translated: the preamble
    (the palette length test, the length arithmetic, the pointer set-up),
    any unrolled `while (n >= loop_unroll_count)` loop before the final
    loop, and the return statement.  The generator checks what it can of
    the preamble (the divisors against the loop's pointer steps, the
    palette test against the loop's use of the palette), and for the rest
    it relies on a human having read it: gen_rows_vetted.txt records, per
    function, the number of loops and a hash of the untranslated text,
    and VETTED_UNROLLED below names the functions with an unrolled loop
    (each was read and is the final loop's body repeated; in
    xxx__index__src the unrolled loop writes 4 bytes per 3 byte pixel,
    the 4th overwritten by the next pixel, and stops one group early so
    that the final loop fixes the last).  If upstream changes any of that
    text, or adds a loop, generation stops until someone has vetted the
    change and run `gen_rows.py --update-vetted`.
  * Pointer arithmetic becomes indexing: `s[k]` is Src (S + k) where S is
    the Ada index of the pixel's first source byte, likewise `d[k]`, and
    `dst_palette_ptr + (i * 4)` is an index into Dst_Palette.
  * Expressions keep C's unsigned arithmetic: uint8_t and uint16_t
    operands are widened to U32 (C promotes them to int; no expression in
    this file makes that difference visible), mixed U32 / U64 operands are
    widened to U64, casts to a narrower type mask and convert.
  * The five memmove copies and the two transparent-black functions are
    written out by hand below (COPY_TEMPLATE, TRANSPARENT_*).

The translator understands only the C that this one file uses and stops
with an error on anything else.
"""

import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))

# ---------------------------------------------------------------- C side

TYPES = {"uint8_t": "u8", "uint16_t": "u16", "uint32_t": "u32",
         "uint64_t": "u64", "size_t": "u64", "bool": "bool"}
ADA_TYPE = {"u8": "U8", "u16": "U16", "u32": "U32", "u64": "U64",
            "bool": "Boolean"}
BITS = {"u8": 8, "u16": 16, "u32": 32, "u64": 64}
MASK = {"u8": "16#FF#", "u16": "16#FFFF#", "u32": "16#FFFF_FFFF#"}

# C function -> (Ada function, parameter types, result type).
COLOR = "wuffs_base__color_"
CALLS = {
    COLOR + "u32_argb_premul__as__color_u16_rgb_565":
        ("Premul_U32_As_RGB_565", ["u32"], "u16"),
    COLOR + "u16_rgb_565__as__color_u32_argb_premul":
        ("RGB_565_As_Premul_U32", ["u16"], "u32"),
    COLOR + "u32_argb_premul__as__color_u8_gray":
        ("Premul_U32_As_Gray_U8", ["u32"], "u8"),
    COLOR + "u32_argb_premul__as__color_u16_gray":
        ("Premul_U32_As_Gray_U16", ["u32"], "u16"),
    COLOR + "u32_argb_nonpremul__as__color_u32_argb_premul":
        ("Nonpremul_U32_As_Premul_U32", ["u32"], "u32"),
    COLOR + "u32_argb_premul__as__color_u32_argb_nonpremul":
        ("Premul_U32_As_Nonpremul_U32", ["u32"], "u32"),
    COLOR + "u64_argb_nonpremul__as__color_u32_argb_premul":
        ("Nonpremul_U64_As_Premul_U32", ["u64"], "u32"),
    COLOR + "u32_argb_premul__as__color_u64_argb_nonpremul":
        ("Premul_U32_As_Nonpremul_U64", ["u32"], "u64"),
    COLOR + "u64_argb_premul__as__color_u8_gray":
        ("Premul_U64_As_Gray_U8", ["u64"], "u8"),
    COLOR + "u64_argb_premul__as__color_u64_argb_nonpremul":
        ("Premul_U64_As_Nonpremul_U64", ["u64"], "u64"),
    COLOR + "u64_argb_nonpremul__as__color_u64_argb_premul":
        ("Nonpremul_U64_As_Premul_U64", ["u64"], "u64"),
    COLOR + "u64_argb_nonpremul__as__color_u8_gray":
        ("Nonpremul_U64_As_Gray_U8", ["u64"], "u8"),
    COLOR + "u32__as__color_u64": ("U32_As_U64", ["u32"], "u64"),
    COLOR + "u64__as__color_u32": ("U64_As_U32", ["u64"], "u32"),
    COLOR + "swap_u32_argb_abgr": ("Swap_U32_ARGB_ABGR", ["u32"], "u32"),
    COLOR + "swap_u64_argb_abgr": ("Swap_U64_ARGB_ABGR", ["u64"], "u64"),
}
PEEKS = {"u8": ("Peek_U8", "u8"), "u16le": ("Peek_U16LE", "u16"),
         "u16be": ("Peek_U16BE", "u16"), "u24le": ("Peek_U24LE", "u32"),
         "u24be": ("Peek_U24BE", "u32"), "u32le": ("Peek_U32LE", "u32"),
         "u32be": ("Peek_U32BE", "u32"), "u64le": ("Peek_U64LE", "u64"),
         "u64be": ("Peek_U64BE", "u64")}
PP = "wuffs_base__%s__no_bounds_check"

TOKEN = re.compile(r"""
    \s*(?:
      (?P<num>0[xX][0-9A-Fa-f]+|\d+)(?:[uU]?[lL]{0,2})
    | (?P<id>[A-Za-z_]\w*)
    | (?P<op>>>=|<<=|\+=|-=|\*=|/=|\|=|&=|>>|<<|<=|>=|==|!=|&&|\|\||
              [-+*/%&|^~!<>?:()\[\],;={}])
    )""", re.X)


class Error(Exception):
    pass


def tokenize(text):
    out, pos = [], 0
    text = text.rstrip()
    while pos < len(text):
        m = TOKEN.match(text, pos)
        if not m:
            raise Error("cannot tokenize: %r" % text[pos:pos + 40])
        pos = m.end()
        if m.group("num") is not None:
            out.append(("num", int(m.group("num"), 0)))
        elif m.group("id") is not None:
            out.append(("id", m.group("id")))
        else:
            out.append(("op", m.group("op")))
    return out


def ada_num(v):
    if v < 100:
        return str(v)
    h = "%X" % v
    groups = []
    while h:
        groups.insert(0, h[-4:])
        h = h[:-4]
    return "16#" + "_".join(groups) + "#"


def ada_name(c):
    return "_".join(w[:1].upper() + w[1:] for w in c.split("_"))


class Translator:
    """Translates one C function body (a token list) to Ada lines."""

    def __init__(self, tokens, env, pointers):
        self.t = tokens
        self.i = 0
        self.env = dict(env)        # C variable -> type
        self.locals = {}            # declared in the body: Ada name -> type
        self.pointers = pointers    # C pointer -> (Ada array, Ada index)
        self.assigned = set()

    # ---- token helpers

    def peek(self, k=0):
        return self.t[self.i + k] if self.i + k < len(self.t) else ("eof", "")

    def next(self):
        tok = self.peek()
        self.i += 1
        return tok

    def accept(self, op):
        if self.peek() == ("op", op):
            self.i += 1
            return True
        return False

    def expect(self, op):
        if not self.accept(op):
            raise Error("expected %r, found %r" % (op, self.peek()))

    def at_type(self, k=0):
        tok = self.peek(k)
        return tok[0] == "id" and tok[1] in TYPES

    # ---- conversions

    @staticmethod
    def conv(e, to):
        s, t = e
        if t == to:
            return s
        if t == "lit":
            if to == "bool":
                raise Error("literal as bool")
            return s
        if t == "bool":
            return "(if %s then 1 else 0)" % s
        if to == "bool":
            return "%s /= 0" % par(s)
        if BITS[to] > BITS[t]:
            return "%s (%s)" % (ADA_TYPE[to], s)
        return "%s (%s and %s)" % (ADA_TYPE[to], par(s), MASK[to])

    @staticmethod
    def common(a, b):
        ta, tb = a[1], b[1]
        if ta == "lit" and tb == "lit":
            return "lit"
        if "u64" in (ta, tb):
            return "u64"
        return "u32"

    def cond(self, e):
        return e[0] if e[1] == "bool" else self.conv(e, "bool")

    # ---- expressions (C precedence, lowest first)

    def expr(self):
        c = self.binary(0)
        if self.accept("?"):
            a = self.expr()
            self.expect(":")
            b = self.expr()
            t = self.common(a, b)
            if t == "lit":
                t = "u32"
            return ("(if %s then %s else %s)"
                    % (self.cond(c), self.conv(a, t), self.conv(b, t)), t)
        return c

    LEVELS = [["||"], ["&&"], ["|"], ["^"], ["&"], ["==", "!="],
              ["<", ">", "<=", ">="], ["<<", ">>"], ["+", "-"],
              ["*", "/", "%"]]
    ADA_OP = {"|": "or", "^": "xor", "&": "and", "==": "=", "!=": "/=",
              "%": "mod", "||": "or else", "&&": "and then"}

    def binary(self, level):
        if level == len(self.LEVELS):
            return self.unary()
        a = self.binary(level + 1)
        while self.peek()[0] == "op" and self.peek()[1] in self.LEVELS[level]:
            op = self.next()[1]
            b = self.binary(level + 1)
            a = self.apply(op, a, b)
        return a

    def apply(self, op, a, b):
        if op in ("||", "&&"):
            return ("%s %s %s" % (par(self.cond(a)), self.ADA_OP[op],
                                  par(self.cond(b))), "bool")
        if op in ("<<", ">>"):
            if b[1] != "lit":
                raise Error("shift by a non-constant")
            t = "u64" if a[1] == "u64" else "u32"
            if a[1] == "lit":
                raise Error("shift of a literal")
            fn = "Shift_Left" if op == "<<" else "Shift_Right"
            return ("%s (%s, %s)" % (fn, self.conv(a, t), b[0]), t)
        t = self.common(a, b)
        if t == "lit":
            va, vb = int_of(a[0]), int_of(b[0])
            v = {"+": va + vb, "-": va - vb, "*": va * vb, "|": va | vb,
                 "&": va & vb}.get(op)
            if v is None or v < 0:
                raise Error("constant expression %s" % op)
            return (ada_num(v), "lit")
        sa, sb = par(self.conv(a, t)), par(self.conv(b, t))
        if op in ("==", "!=", "<", ">", "<=", ">="):
            return ("%s %s %s" % (sa, self.ADA_OP.get(op, op), sb), "bool")
        return ("%s %s %s" % (sa, self.ADA_OP.get(op, op), sb), t)

    def unary(self):
        if self.accept("~"):
            a = self.unary()
            t = "u64" if a[1] == "u64" else "u32"
            return ("not %s" % par(self.conv(a, t)), t)
        if self.accept("!"):
            a = self.unary()
            return ("not %s" % par(self.cond(a)), "bool")
        if self.peek() == ("op", "(") and self.at_type(1) \
                and self.peek(2) == ("op", ")"):
            self.next()
            to = TYPES[self.next()[1]]
            self.next()
            a = self.unary()
            if a[1] == "lit":
                return (a[0], to)
            return (self.conv(a, to), to)
        return self.postfix()

    def postfix(self):
        tok = self.next()
        if tok[0] == "num":
            return (ada_num(tok[1]), "u64" if tok[1] > 0xFFFFFFFF else "lit")
        if tok == ("op", "("):
            e = self.expr()
            self.expect(")")
            return e
        if tok[0] != "id":
            raise Error("unexpected %r" % (tok,))
        name = tok[1]
        if self.accept("("):
            return self.call(name)
        if name in self.pointers:
            if self.accept("["):
                k = self.expr()
                self.expect("]")
                return (self.element(name, k), "u8")
            raise Error("bare pointer %s in an expression" % name)
        if name not in self.env:
            raise Error("unknown identifier %s" % name)
        return (ada_name(name), self.env[name])

    def element(self, ptr, k):
        arr, base = self.pointers[ptr]
        return "%s (%s)" % (arr, self.index(base, k))

    def index(self, base, k):
        if k[1] == "lit":
            v = int_of(k[0])
            return base if v == 0 else "%s + %d" % (base, v)
        return "%s + Index (%s)" % (base, k[0])

    def address(self):
        """ptr [+ integer expression] -> (Ada array, Ada index)."""
        tok = self.next()
        if tok[0] != "id" or tok[1] not in self.pointers:
            raise Error("expected a pointer, found %r" % (tok,))
        arr, base = self.pointers[tok[1]]
        if self.accept("+"):
            k = self.binary(len(self.LEVELS) - 1)
            return arr, self.index(base, k)
        return arr, base

    def call(self, name):
        for key, (fn, typ) in PEEKS.items():
            if name == PP % ("peek_" + key):
                arr, idx = self.address()
                self.expect(")")
                return ("%s (%s, %s)" % (fn, arr, idx), typ)
        if name in CALLS:
            fn, params, ret = CALLS[name]
        elif name in COMPOSITES:
            fn, params, ret = COMPOSITES[name]
        else:
            raise Error("unknown function %s" % name)
        args = []
        for p in params:
            if args:
                self.expect(",")
            args.append(self.conv(self.expr(), p))
        self.expect(")")
        return ("%s (%s)" % (fn, ", ".join(args)), ret)

    # ---- statements

    def block(self, depth):
        self.expect("{")
        lines = []
        while not self.accept("}"):
            lines += self.statement(depth)
        return lines

    def statement(self, depth):
        ind = "   " * depth
        if self.peek() == ("op", "{"):
            return self.block(depth)
        if self.peek() == ("id", "if"):
            self.next()
            lines = []
            word = "if"
            while True:
                self.expect("(")
                c = self.cond(self.expr())
                self.expect(")")
                lines.append("%s%s %s then" % (ind, word, c))
                lines += self.block(depth + 1)
                if self.peek() == ("id", "else"):
                    self.next()
                    if self.peek() == ("id", "if"):
                        self.next()
                        word = "elsif"
                        continue
                    lines.append("%selse" % ind)
                    lines += self.block(depth + 1)
                break
            lines.append("%send if;" % ind)
            return lines
        if self.peek() == ("id", "return"):
            self.next()
            e = self.expr()
            self.expect(";")
            return ["%sreturn %s;" % (ind, self.conv(e, self.result))]
        if self.at_type():
            typ = TYPES[self.next()[1]]
            name = self.next()[1]
            an = ada_name(name)
            if self.locals.get(an, typ) != typ:
                raise Error("%s declared with two types" % name)
            self.locals[an] = typ
            self.env[name] = typ
            if self.accept(";"):
                return []
            self.expect("=")
            e = self.expr()
            self.expect(";")
            return ["%s%s := %s;" % (ind, an, self.conv(e, typ))]
        tok = self.next()
        if tok[0] != "id":
            raise Error("unexpected statement start %r" % (tok,))
        name = tok[1]
        if self.accept("("):
            for key, (fn, typ) in PEEKS.items():
                if name == PP % ("poke_" + key):
                    arr, idx = self.address()
                    self.expect(",")
                    e = self.expr()
                    self.expect(")")
                    self.expect(";")
                    return ["%s%s (%s, %s, %s);"
                            % (ind, fn.replace("Peek", "Poke"), arr, idx,
                               self.conv(e, typ))]
            raise Error("unknown procedure call %s" % name)
        if name in self.pointers:
            self.expect("[")
            k = self.expr()
            self.expect("]")
            target, typ = self.element(name, k), "u8"
        elif name in self.env:
            target, typ = ada_name(name), self.env[name]
            self.assigned.add(ada_name(name))
        else:
            raise Error("assignment to unknown %s" % name)
        op = self.next()
        if op[0] != "op" or op[1] not in ("=", "|=", "&=", "+=", "-=",
                                           "*=", "/=", ">>=", "<<="):
            raise Error("unexpected %r after %s" % (op, name))
        e = self.expr()
        self.expect(";")
        if op[1] != "=":
            e = self.apply(op[1][:-1], (target, typ), e)
        return ["%s%s := %s;" % (ind, target, self.conv(e, typ))]


def par(s):
    """Parenthesise s unless it is already a primary."""
    if re.fullmatch(r"[\w#']+", s):
        return s
    depth = 0
    if re.match(r"[\w.']+ \(", s) or s.startswith("("):
        # one call / conversion / parenthesised expression?
        start = s.index("(")
        for pos in range(start, len(s)):
            if s[pos] == "(":
                depth += 1
            elif s[pos] == ")":
                depth -= 1
                if depth == 0:
                    if pos == len(s) - 1:
                        return s
                    break
    return "(" + s + ")"


def int_of(ada):
    if ada.startswith("16#"):
        return int(ada[3:-1].replace("_", ""), 16)
    return int(ada)


COMPOSITES = {}

# Row functions with an unrolled loop before the final per-pixel loop.
# Each has been read: the unrolled loop is equivalent to the final loop.
VETTED_UNROLLED = {
    "wuffs_private_impl__swizzle_bgr_565__index__src",
    "wuffs_private_impl__swizzle_xxx__index__src",
    "wuffs_private_impl__swizzle_xxx__index_binary_alpha__src_over",
    "wuffs_private_impl__swizzle_xxxx__index__src",
    "wuffs_private_impl__swizzle_xxxx__index_binary_alpha__src_over",
}
VETTED_FILE = os.path.join(HERE, "gen_rows_vetted.txt")


def untranslated(body):
    """(number of loops, hash of the text that is not translated)."""
    import hashlib
    loops = len(re.findall(r"\bwhile\s*\(", body))
    text = None
    for head in ("n >= 1", "n--"):
        inner = loop_body(body, head)
        if inner is not None:
            pos = body.rfind("while (%s) {" % head)
            start = body.index("{", pos)
            text = body[:start + 1] + "<LOOP>" + body[start + 1 + len(inner):]
            break
    if text is None:
        text = body
    text = re.sub(r"\s+", " ", text).strip()
    return loops, hashlib.sha256(text.encode()).hexdigest()[:16]


def check_vetted(found, update):
    """found: list of (C name, loops, hash) for every row function."""
    if update:
        with open(VETTED_FILE, "w") as f:
            f.write("# C row function, number of loops, hash of the text that\n"
                    "# gen_rows.py does not translate.  Written by\n"
                    "# `gen_rows.py --update-vetted` after a human has read the\n"
                    "# untranslated text of every function that changed.\n")
            for name, loops, digest in found:
                f.write("%s %d %s\n" % (name, loops, digest))
    vetted = {}
    for line in open(VETTED_FILE):
        if line.strip() and not line.startswith("#"):
            name, loops, digest = line.split()
            vetted[name] = (int(loops), digest)
    problems = []
    for name, loops, digest in found:
        if name not in vetted:
            problems.append("%s: not vetted" % name)
        elif vetted[name] != (loops, digest):
            problems.append("%s: untranslated text changed" % name)
        if (loops > 1) != (name in VETTED_UNROLLED):
            problems.append("%s: %d loops, and VETTED_UNROLLED says otherwise"
                            % (name, loops))
    for name in vetted:
        if name not in [f[0] for f in found]:
            problems.append("%s: vetted but no longer upstream" % name)
    if problems:
        raise Error("untranslated C has not been vetted:\n  "
                    + "\n  ".join(problems))

# ------------------------------------------------------------ extraction


def strip_comments(text):
    text = re.sub(r"/\*.*?\*/", "", text, flags=re.S)
    return re.sub(r"//[^\n]*", "", text)


def functions(text, prefix, result):
    """Yields (name, parameter text, body text) of the definitions of
    `static [inline] RESULT wuffs_private_impl__PREFIX*(...) {...}`."""
    pat = re.compile(
        r"\nstatic (?:inline )?" + result + r"\s*\n(wuffs_private_impl__"
        + prefix + r"\w*)\(([^)]*)\)\s*\{", re.S)
    for m in pat.finditer(text):
        end = text.index("\n}\n", m.end())
        yield m.group(1), m.group(2), text[m.end():end]


def loop_body(body, head):
    """The text of the last `while (head) {...}` in body, or None."""
    pos = body.rfind("while (%s) {" % head)
    if pos < 0:
        return None
    start = body.index("{", pos)
    depth = 0
    for i in range(start, len(body)):
        if body[i] == "{":
            depth += 1
        elif body[i] == "}":
            depth -= 1
            if depth == 0:
                return body[start + 1:i]
    raise Error("unbalanced loop")


def wrap(prefix, text, width=96, cont="  "):
    """Breaks one Ada statement at spaces so that lines fit."""
    out = []
    line = prefix + text
    indent = prefix + cont
    while len(line) > width:
        cut = line.rfind(" ", len(indent) + 1, width)
        # do not split inside a based literal or leave an operator dangling
        if cut <= len(indent):
            break
        out.append(line[:cut])
        line = indent + line[cut + 1:]
    out.append(line)
    return out


def emit(lines, depth):
    out = []
    pre = "   " * depth
    for ln in lines:
        stripped = ln.lstrip(" ")
        ind = pre + ln[:len(ln) - len(stripped)]
        out += wrap(ind, stripped)
    return out


# -------------------------------------------------------------- templates

COPY_TEMPLATE = """\
   procedure Copy_{k}_{k}
     (Dst : in out Bytes; Dst_Palette : Bytes; Src : Bytes; N : out Pixel_Count)
   is
      pragma Unreferenced (Dst_Palette);
      Len : constant Offset := Offset'Min (Dst'Length / {k}, Src'Length / {k});
   begin
      if Len > 0 then
         Dst (Dst'First .. Dst'First + (Len * {k} - 1)) :=
           Src (Src'First .. Src'First + (Len * {k} - 1));
      end if;
      N := Len;
   end Copy_{k}_{k};
"""

HEADER_ADS = """\
--  GENERATED by tools/gen_rows.py from upstream Wuffs'
--  internal/cgen/base/pixconv-submodule-regular.c.  Do not edit; change the
--  generator and run it again.
--
--  The pixel swizzler's row functions: each converts a row of pixels in
--  one format (Src) to another (Dst), for one blend mode.  C:
--  wuffs_private_impl__swizzle_<dst>__<src>[__<blend>]; the Ada name is
--  <Dst>_From_<Src>[_<Blend>], or the C name itself where it has no
--  "<dst>__<src>" form.  The x86 SIMD variants are not translated; these
--  are the scalar functions.
--
--  Every row function has the same shape and contract:
--
--    procedure F (Dst : in out Bytes; Dst_Palette : Bytes; Src : Bytes;
--                 N : out Pixel_Count);
--
--  It converts N pixels, from the start of Src to the start of Dst.  N is
--  the number of whole pixels that both arrays hold, min (Dst'Length /
--  dst bytes per pixel, Src'Length / src bytes per pixel), which the
--  function computes itself, as in C: there is no precondition, and
--  trailing bytes that do not make a whole pixel are left alone.  The
--  functions that look colours up in Dst_Palette do nothing and return 0
--  unless Dst_Palette'Length is exactly 1024, again as in C.  Bytes of Dst
--  after the N pixels are not changed.
--
--  No index convention to state: these take whole arrays (the caller
--  slices) and return a count of pixels.
--
--  Aliasing: Dst, the array written, must not share any element with
--  Dst_Palette or with Src.  Dst_Palette and Src are only read and may
--  overlap each other in any way (std/bmp passes parts of one array as
--  both).  (C's Copy_K_K are memmoves and would tolerate a Dst that
--  overlaps Src; the others read and write pixel by pixel.  No Wuffs code
--  in std swizzles into the array it reads from.)
--
--  Swizzle_Row calls the row function that a Row_Function value names;
--  the swizzler stores such a value where C stores a function pointer.

package Wuffs.Base.Pixel_Rows with Pure, SPARK_Mode is

   pragma Assertion_Policy (Post => Ignore);

   use Interfaces;

   --  A number of pixels.  (A count, in the signed index arithmetic of
   --  the library rather than C's uint64_t; Wuffs.Base.Pixel_Swizzler
   --  converts at its interface.)
   subtype Pixel_Count is Offset range 0 .. Index'Last + 1;

   --  Number of pixels a row function converts, given the lengths of its
   --  two arrays (which are in the same range as a count of pixels).
   function Count
     (Dst_Length, Src_Length : Pixel_Count; Dst_BPP, Src_BPP : Index) return Pixel_Count
   is (Offset'Min (Dst_Length / Dst_BPP, Src_Length / Src_BPP))
   with Pre => Dst_BPP >= 1 and then Src_BPP >= 1;

   --  True if New_Dst is Old_Dst from its element number From (counted
   --  from 0) on: only the first From elements were (possibly) written.
   function Rest_Unchanged
     (Old_Dst, New_Dst : Bytes; From : Offset) return Boolean
   is
     (Old_Dst'First = New_Dst'First
      and then Old_Dst'Last = New_Dst'Last
      and then (for all J in New_Dst'Range =>
                  (if J - New_Dst'First >= From then New_Dst (J) = Old_Dst (J))))
   with Ghost;

"""

HEADER_ADB = """\
--  GENERATED by tools/gen_rows.py from upstream Wuffs'
--  internal/cgen/base/pixconv-submodule-regular.c.  Do not edit; change the
--  generator and run it again.

with Wuffs.Base.Colors;
with Wuffs.Base.Endian;

package body Wuffs.Base.Pixel_Rows with SPARK_Mode is

   pragma Assertion_Policy (Ignore);

   use Wuffs.Base.Colors;
   use Wuffs.Base.Endian;

"""


def banner(name):
    bar = "   " + "-" * (len(name) + 6)
    return [bar, "   -- %s --" % name, bar, ""]


def row_ada_name(c):
    c = c.replace("wuffs_private_impl__swizzle_", "")
    parts = c.split("__")
    if len(parts) >= 2 and not c.startswith(("squash", "swap", "copy",
                                              "transparent")):
        name = parts[0] + "_from_" + "_".join(parts[1:])
    else:
        name = "_".join(parts)
    return ada_name(name)


def translate_composite(name, params, body):
    env, plist = {}, []
    for p in params.split(","):
        typ, pname = p.split()
        env[pname] = TYPES[typ]
        plist.append((ada_name(pname), TYPES[typ]))
    tr = Translator(tokenize("{" + body + "}"), env, {})
    tr.result = COMPOSITES[name][2]
    lines = tr.block(2)
    if tr.i != len(tr.t):
        raise Error("trailing tokens")
    fn = COMPOSITES[name][0]
    sig = ["   function %s" % fn,
           "     (%s) return %s" % (
               "; ".join("%s : %s" % (n, ADA_TYPE[t]) for n, t in plist),
               ADA_TYPE[tr.result])]
    out = banner(fn)
    out += sig + ["   is"]
    for n, t in sorted(tr.locals.items()):
        out.append("      %s : %s;" % (n, ADA_TYPE[t]))
    out.append("   begin")
    out += emit(lines, 0)
    out.append("   end %s;" % fn)
    out.append("")
    return sig, out


def translate_row(name, params, body):
    """Returns (Ada name, dst bpp, src bpp, uses palette, extra params,
    body lines)."""
    an = row_ada_name(name)
    squash = "bool nonpremul" in params
    palette = re.search(r"dst_palette_len\s*!=", body) is not None
    m = re.search(r"size_t dst_len(\d) = dst_len / (\d);", body)
    db = int(m.group(2)) if m else 1
    m = re.search(r"size_t src_len(\d) = src_len / (\d);", body)
    sb = int(m.group(2)) if m else 1
    if re.search(r"size_t len = \(dst_len < src_len \? dst_len : src_len\) / (\d);",
                 body):
        db = sb = int(re.search(
            r"dst_len : src_len\) / (\d);", body).group(1))
    text = loop_body(body, "n >= 1")
    if text is None:
        text = loop_body(body, "n--")
    if text is None:
        raise Error("no pixel loop")
    # The loop's own pointer stepping must agree with the divisors.
    tail = re.search(
        r"s \+= (?:1 \* )?(\d);\s*d \+= (?:1 \* )?(\d);\s*(?:n -= 1;)?\s*$",
        text)
    if not tail:
        raise Error("unexpected loop tail")
    if (int(tail.group(1)), int(tail.group(2))) != (sb, db):
        raise Error("loop steps %s do not match divisors %d, %d"
                    % (tail.groups(), sb, db))
    text = text[:tail.start()]
    env = {"nonpremul": "bool"} if squash else {}
    pointers = {"s": ("Src", "S"), "d": ("Dst", "D"),
                "dst_palette_ptr": ("Dst_Palette", "Dst_Palette'First")}
    tr = Translator(tokenize("{" + text + "}"), env, pointers)
    lines = tr.block(0)
    if tr.i != len(tr.t):
        raise Error("trailing tokens")
    uses_pal = any("Dst_Palette" in ln for ln in lines)
    if uses_pal != palette:
        raise Error("palette use without the length test (or vice versa)")
    return an, db, sb, palette, squash, tr.locals, lines


def row_spec(an, db, sb, palette, squash):
    if squash:
        head = ["   procedure %s" % an,
                "     (Dst : in out Bytes; Src : Bytes; Nonpremul : Boolean; N : out Pixel_Count)"]
    else:
        head = ["   procedure %s" % an,
                "     (Dst : in out Bytes; Dst_Palette : Bytes; Src : Bytes; N : out Pixel_Count)"]
    count = "Count (Dst'Length, Src'Length, %d, %d)" % (db, sb)
    if palette:
        post = ("N = (if Dst_Palette'Length = 1024 then %s else 0)" % count)
    else:
        post = "N = %s" % count
    return head, post


def generate(cfile, update_vetted=False):
    text = "\n" + strip_comments(open(cfile, encoding="utf-8").read())
    # Drop forward declarations (prototypes end in ");").
    comps = [(n, p, b) for n, p, b in
             functions(text, "composite_", r"uint(?:32|64)_t")]
    for n, p, b in comps:
        typ = "u64" if "_u64_" in n else "u32"
        COMPOSITES[n] = (ada_name(n.replace("wuffs_private_impl__", "")),
                         [typ, typ], typ)
    COMPOSITES["wuffs_private_impl__color_u64__as__color_u32__swap_u32_argb_abgr"] = (
        "U64_As_U32_Swap_U32_ARGB_ABGR", ["u64"], "u32")

    ads = [HEADER_ADS.rstrip("\n"), ""]
    adb = [HEADER_ADB.rstrip("\n"), ""]

    adb += ["   --  The compositing helpers.  Each has a contract (Global) so that",
            "   --  GNATprove proves it once, on its own, and treats calls to it as",
            "   --  calls; without one it would inline the body into every row",
            "   --  function that uses it.",
            "",
            "   --  C: wuffs_private_impl__color_u64__as__color_u32__swap_u32_argb_abgr.",
            "   function U64_As_U32_Swap_U32_ARGB_ABGR (C : U64) return U32 is",
            "     (Swap_U32_ARGB_ABGR (U64_As_U32 (C)));", ""]
    bodies = []
    for n, p, b in comps:
        sig, out = translate_composite(n, p, b)
        adb += [sig[0], sig[1], "   with Global => null;"]
        bodies += out
    adb.append("")
    adb += bodies

    rows = []
    found = []
    for n, p, b in functions(text, "swizzle_", r"uint64_t"):
        if "x86" in n:
            continue
        found.append((n,) + untranslated(b))
        if "transparent_black" in n:
            continue
        an = row_ada_name(n)
        m = re.fullmatch(r"Copy_(\d)_\1", an)
        if m:
            k = int(m.group(1))
            rows.append((an, k, k, False, False, None, None, n))
            continue
        try:
            rows.append(translate_row(n, p, b) + (n,))
        except Error as e:
            raise Error("%s: %s" % (n, e))

    check_vetted(found, update_vetted)

    enum = []
    for an, db, sb, palette, squash, locs, lines, cname in rows:
        head, post = row_spec(an, db, sb, palette, squash)
        ads.append("   --  C: %s." % cname)
        ads += head + ["   with"]
        ads += wrap("     ", "Post => " + post, cont="  ")
        ads.append("       and then Rest_Unchanged (Dst'Old, Dst, N * %d);" % db)
        ads.append("")
        if not squash:
            enum.append(an)
        adb += banner(an)
        if locs is None:
            adb += COPY_TEMPLATE.format(k=db).rstrip("\n").split("\n")
            adb.append("")
            continue
        adb += head + ["   is"]
        if not palette and not squash:
            adb.append("      pragma Unreferenced (Dst_Palette);")
        adb.append("      Len : constant Offset := "
                   "Offset'Min (Dst'Length / %d, Src'Length / %d);" % (db, sb))
        adb.append("      D   : Index;")
        if any(re.search(r"\bS\b", ln) for ln in lines):
            adb.append("      S   : Index;")
        for v, t in sorted(locs.items()):
            adb.append("      %s : %s;" % (v, ADA_TYPE[t]))
        adb.append("   begin")
        if palette:
            adb += ["      if Dst_Palette'Length /= 1024 then",
                    "         N := 0;",
                    "         return;", "      end if;"]
        adb.append("      for I in 0 .. Len - 1 loop")
        # Spell out why pixel I lies within both arrays; left to
        # themselves the provers find this slowly for some size pairs.
        adb.append("         pragma Assert")
        adb.append("           (I + 1 <= Dst'Length / %d and then I + 1 <= Src'Length / %d);"
                   % (db, sb))
        adb.append("         pragma Assert")
        adb.append("           ((I + 1) * %d <= Dst'Length and then (I + 1) * %d <= Src'Length);"
                   % (db, sb))
        adb.append("         D := Dst'First + I * %d;" % db
                   if db > 1 else "         D := Dst'First + I;")
        if any(re.search(r"\bS\b", ln) for ln in lines):
            adb.append("         S := Src'First + I * %d;" % sb
                       if sb > 1 else "         S := Src'First + I;")
        adb += emit(lines, 3)
        adb.append("         pragma Loop_Invariant")
        adb.append("           (for all J in Dst'Range =>")
        adb.append("              (if J - Dst'First >= (I + 1) * %d" % db)
        adb.append("               then Dst (J) = Dst'Loop_Entry (J)));")
        adb.append("      end loop;")
        adb.append("      N := Len;")
        adb.append("   end %s;" % an)
        adb.append("")

    # The enumeration and the dispatcher.
    ads += ["   --  One literal per row function with the standard shape (all but the",
            "   --  two Squash_ functions, which take other parameters).",
            "   type Row_Function is"]
    for k, an in enumerate(enum):
        ads.append("     %sFn_%s%s" % ("(" if k == 0 else " ", an,
                                        "," if k + 1 < len(enum) else ");"))
    ads += ["",
            "   --  Bytes per pixel of the destination and source of each row",
            "   --  function.",
            "   function Dst_BPP (Fn : Row_Function) return Index is",
            "     (case Fn is"]
    def table(sel):
        groups = {}
        for an, db, sb, palette, squash, *_ in rows:
            if not squash:
                groups.setdefault(sel(db, sb), []).append("Fn_" + an)
        out = []
        keys = sorted(groups)
        for k in keys:
            names = groups[k]
            for j, nm in enumerate(names):
                lead = "        when " if j == 0 else "           | "
                out.append(lead + nm + ("" if j + 1 < len(names)
                                         else " => %d%s" % (k, "," if k != keys[-1] else ")")))
        return out
    ads += table(lambda db, sb: db)
    ads += ["   with Post => Dst_BPP'Result in 1 .. 8;", "",
            "   function Src_BPP (Fn : Row_Function) return Index is",
            "     (case Fn is"]
    ads += table(lambda db, sb: sb)
    ads += ["   with Post => Src_BPP'Result in 1 .. 8;"]
    ads += ["",
            "   --  Calls the row function that Fn names.",
            "   procedure Swizzle_Row",
            "     (Fn          : Row_Function;",
            "      Dst         : in out Bytes;",
            "      Dst_Palette : Bytes;",
            "      Src         : Bytes;",
            "      N           : out Pixel_Count)",
            "   with",
            "     Post => N <= Count (Dst'Length, Src'Length, Dst_BPP (Fn), Src_BPP (Fn))",
            "       and then Rest_Unchanged (Dst'Old, Dst, N * Dst_BPP (Fn));",
            "",
            "end Wuffs.Base.Pixel_Rows;"]

    adb += banner("Swizzle_Row")
    adb += ["   procedure Swizzle_Row",
            "     (Fn          : Row_Function;",
            "      Dst         : in out Bytes;",
            "      Dst_Palette : Bytes;",
            "      Src         : Bytes;",
            "      N           : out Pixel_Count)",
            "   is",
            "      --  Dst as it was, for the assertions only (no code: ghost).",
            "      Old_Dst : constant Bytes := Dst with Ghost;",
            "   begin",
            "      case Fn is"]
    for an in enum:
        adb.append("         when Fn_%s =>" % an)
        adb.append("            %s (Dst, Dst_Palette, Src, N);" % an)
        adb.append("            pragma Assert")
        adb.append("              (N <= Count (Dst'Length, Src'Length, "
                   "Dst_BPP (Fn), Src_BPP (Fn)));")
        adb.append("            pragma Assert "
                   "(Rest_Unchanged (Old_Dst, Dst, N * Dst_BPP (Fn)));")
    adb += ["      end case;", "   end Swizzle_Row;", "",
            "end Wuffs.Base.Pixel_Rows;"]
    inc = ["// GENERATED by ada/src/pixel/tools/gen_rows.py.  Do not edit.",
           "// The scalar row functions, in the order of the Ada enumeration",
           "// Wuffs.Base.Pixel_Rows.Row_Function: ROW(C function, destination",
           "// bytes per pixel, source bytes per pixel).  Then the two palette",
           "// squash functions, which have other parameters."]
    for an, db, sb, palette, squash, locs, lines, cname in rows:
        if not squash:
            inc.append("ROW(%s, %d, %d)" % (cname, db, sb))
    for an, db, sb, palette, squash, locs, lines, cname in rows:
        if squash:
            inc.append("SQUASH(%s)" % cname)
    return "\n".join(ads) + "\n", "\n".join(adb) + "\n", "\n".join(inc) + "\n"


def main():
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    wuffs = args[0] if args else os.path.join(HERE, "..", "..", "..", "..", "wuffs")
    outdir = args[1] if len(args) > 1 else os.path.join(HERE, "..")
    cfile = os.path.join(wuffs, "internal", "cgen", "base",
                         "pixconv-submodule-regular.c")
    ads, adb, inc = generate(cfile, "--update-vetted" in sys.argv)
    ok = True
    incpath = os.path.join("..", "..", "tests_pixel", "oracle", "row_funcs.inc")
    for name, text in (("wuffs-base-pixel_rows.ads", ads),
                       ("wuffs-base-pixel_rows.adb", adb),
                       (incpath, inc)):
        path = os.path.join(outdir, name)
        if "--check" in sys.argv:
            if not os.path.exists(path) or open(path).read() != text:
                print("%s is not the generator's output" % path)
                ok = False
        else:
            open(path, "w").write(text)
    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()
