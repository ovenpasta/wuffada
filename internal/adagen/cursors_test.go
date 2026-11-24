// Part of wuffada (wuffs-ada: Wuffs to Ada).
// SPDX-License-Identifier: Apache-2.0 OR MIT

package adagen

import (
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"testing"
)

// TestIsolateCursors checks that a call of a procedure that is not inlined
// gets a copy of the cursor, in every kind of nested statement, and that the
// Inline_Always primitives get the cursor itself.
func TestIsolateCursors(tt *testing.T) {
	w := &variable{kind: varLocal, name: "G_W_Dst", typ: typWriter}
	r := &variable{kind: varLocal, name: "G_R_Src", typ: typReader}
	f := &fn{}
	l := &lowerer{f: f}
	outOfLine := sCall{callNamed("Wuffs.Runtime.Writer_Limited_Copy_U32_From_Reader",
		"Data", raw("A_Dst"), "W", expr(eVar{w}), "Up_To", raw("3"),
		"Src_Data", raw("A_Src"), "R", expr(eOut{eVar{r}}), "N", expr(eOut{raw("G_T9")}))}
	inlined := sCall{callNamed(ioPkg+".Write_U8_Fast", "Data", raw("A_Dst"), "W", expr(eOut{eVar{w}}),
		"V", raw("1"))}
	body := []stmt{
		inlined,
		sIf{branches: []ifBranch{{raw("C"), []stmt{sLoop{cond: raw("D"), body: []stmt{outOfLine}}}}},
			els: []stmt{sCase{sel: raw("E"), arms: []caseArm{{"1", []stmt{outOfLine}}}}}},
		outOfLine,
	}
	f.body = l.isolateCursors(body)
	p := &printer{}
	p.stmts(f.body)
	got := p.b.String()
	tw, tr := l.cursorCopies[w], l.cursorCopies[r]
	if tw == nil || tr == nil || len(l.cursorCopies) != 2 {
		tt.Fatalf("cursor copies: %v", l.cursorCopies)
	}
	// Three isolated calls (in a loop in an if, in a case arm in the else
	// part, at the top level), with one temporary per cursor.
	for _, want := range []string{
		tw.name + " := G_W_Dst;", tr.name + " := G_R_Src;",
		"W => " + tw.name + ",", "R => " + tr.name + ",",
		"G_W_Dst := " + tw.name + ";", "G_R_Src := " + tr.name + ";",
	} {
		if n := strings.Count(got, want); n != 3 {
			tt.Errorf("%d times %q, want 3:\n%s", n, want, got)
		}
	}
	// Copy, call, copy back, in that order.
	if !regexp.MustCompile(`(?s)` + tw.name + ` := G_W_Dst;\s*` + tr.name + ` := G_R_Src;\s*` +
		`Wuffs\.Runtime\.Writer_Limited_Copy_U32_From_Reader[^;]*;\s*G_W_Dst := ` + tw.name +
		`;\s*G_R_Src := ` + tr.name + `;`).MatchString(got) {
		tt.Errorf("not copy, call, copy back:\n%s", got)
	}
	if !strings.Contains(got, "Wuffs.Base.IO.Write_U8_Fast (Data => A_Dst, W => G_W_Dst, V => 1);") {
		tt.Errorf("the inlined call is not direct:\n%s", got)
	}
}

// TestInlinedCursorProcs checks inlinedCursorProcs against the proved
// specs: every declaration of each of those procedures is Inline_Always.
func TestInlinedCursorProcs(tt *testing.T) {
	root := filepath.Join("..", "..", "ada", "src")
	specs := map[string]string{
		ioPkg:     filepath.Join(root, "base", "wuffs-base-io.ads"),
		tokensPkg: filepath.Join(root, "token", "wuffs-base-tokens.ads"),
	}
	texts := map[string]string{}
	for pkg, path := range specs {
		b, err := os.ReadFile(path)
		if err != nil {
			tt.Fatal(err)
		}
		texts[pkg] = string(b)
	}
	for full := range inlinedCursorProcs {
		i := strings.LastIndex(full, ".")
		pkg, name := full[:i], full[i+1:]
		text, ok := texts[pkg]
		if !ok {
			tt.Errorf("%s: unknown package", full)
			continue
		}
		decls := regexp.MustCompile(`(?s)\n   procedure `+name+`\b.*?;\n\n`).FindAllString(text, -1)
		if len(decls) == 0 {
			tt.Errorf("%s: not declared", full)
		}
		for _, d := range decls {
			if !strings.Contains(d, "Inline_Always") {
				tt.Errorf("%s: not Inline_Always:%s", full, d)
			}
		}
	}
}

// TestOutOfLineCursorFuncs checks outOfLineCursorFuncs against the proved
// specs: every function there with a cursor parameter is either an
// expression function (inlined) or in the list.
func TestOutOfLineCursorFuncs(tt *testing.T) {
	root := filepath.Join("..", "..", "ada", "src")
	specs := map[string]string{
		ioPkg:             filepath.Join(root, "base", "wuffs-base-io.ads"),
		tokensPkg:         filepath.Join(root, "token", "wuffs-base-tokens.ads"),
		"Wuffs.Base.UTF8": filepath.Join(root, "token", "wuffs-base-utf8.ads"),
	}
	decl := regexp.MustCompile(`(?s)\n   function (\w+)\s*\(([^)]*)\)\s*return [\w.]+(\s+is\b)?`)
	cursor := regexp.MustCompile(`:\s*(IO\.)?(Reader|Writer|Token_Writer|Token_Reader)\b`)
	found := map[string]bool{}
	for pkg, path := range specs {
		b, err := os.ReadFile(path)
		if err != nil {
			tt.Fatal(err)
		}
		for _, m := range decl.FindAllStringSubmatch(string(b), -1) {
			if !cursor.MatchString(m[2]) {
				continue
			}
			full := pkg + "." + m[1]
			if m[3] == "" {
				found[full] = true
				if !outOfLineCursorFuncs[full] {
					tt.Errorf("%s: takes a cursor, has a body and is not in outOfLineCursorFuncs", full)
				}
			}
		}
	}
	for full := range outOfLineCursorFuncs {
		if !found[full] {
			tt.Errorf("%s: in outOfLineCursorFuncs but not a function with a body and a cursor parameter", full)
		}
	}
}

// TestSelfArraysCopyAndIndexArithmetic checks two forms that let GCC do
// better: a copy between two different array fields of the receiver calls
// the base library's two-array form directly (no run-time overlap test),
// while a copy within one field, or from a slice handle, does not; and a
// checked "+" or "-" in an index is computed in Wuffs.Index.
func TestSelfArraysCopyAndIndexArithmetic(tt *testing.T) {
	got := mustGenerate(tt, `
		pub struct foo?(a : array[32] base.u8, b : array[4] array[16] base.u8, n : base.u64)
		pub func foo.run!(o : base.u32[..= 8], s : slice base.u8) {
			var k : base.u32[..= 3]
			assert args.o <= (args.o + 8) via "a <= (a + b): 0 <= b"(b: 8)
			assert args.o <= (args.o + 4) via "a <= (a + b): 0 <= b"(b: 4)
			this.n = this.a[args.o .. args.o + 8].copy_from_slice!(s: this.b[k][.. 8])
			this.n = this.a[args.o .. args.o + 4].copy_from_slice!(s: this.a[16 .. 20])
			this.n = this.a[.. 8].copy_from_slice!(s: args.s)
			this.n = this.a[(args.o + 1) as base.u64] as base.u64
		}`)
	wantContains(tt, got,
		"Wuffs.Base.Slices.Copy_From_Slice (Dst => Self.F_A",
		".. (Wuffs.Index (A_O) + 8) - 1),",
		"Src => Self.F_B (Wuffs.Index (V_K)) (0 .. 7),",
		"Wuffs.Base.Slices.Copy_Within",
		"Wuffs.Runtime.Copy_From_Slice",
	)
	if n := strings.Count(got, "Wuffs.Base.Slices.Copy_From_Slice"); n != 1 {
		tt.Errorf("%d direct two-array copies, want 1:\n%s", n, got)
	}
}

// TestSelfArrayCopyDispatch checks, case by case, when copy_from_slice calls
// the base library's two-array Copy_From_Slice directly: only for parts of
// two DIFFERENT array components of the receiver. Two parts of one component
// (two slices of it, or two rows of one array of arrays, which may be the
// same row) may overlap and go to Copy_Within or the run-time shell, and so
// does anything that goes through a slice local, whatever it was made from.
func TestSelfArrayCopyDispatch(tt *testing.T) {
	const direct = "Wuffs.Base.Slices.Copy_From_Slice"
	for _, c := range []struct {
		name, body string
		isDirect   bool
		wants      []string
	}{
		{"two components", `this.n = this.a[.. 8].copy_from_slice!(s: this.c[.. 8])`, true,
			[]string{direct + " (Dst => Self.F_A (0 .. 7),", "Src => Self.F_C (0 .. 7),"}},
		{"two slices of one component", `this.n = this.a[0 .. 8].copy_from_slice!(s: this.a[4 .. 12])`, false,
			[]string{"Wuffs.Base.Slices.Copy_Within (Data => Self.F_A,"}},
		{"two rows of one component", `this.n = this.b[args.i][..].copy_from_slice!(s: this.b[args.j][2 ..])`, false,
			[]string{"Wuffs.Runtime.Copy_From_Slice (Dst => Self.F_B (Wuffs.Index (A_I)),"}},
		{"two constant rows of one component", `this.n = this.b[1][..].copy_from_slice!(s: this.b[2][..])`, false,
			[]string{"Wuffs.Runtime.Copy_From_Slice (Dst => Self.F_B (1),"}},
		{"one row of one component", `this.n = this.b[args.i][..].copy_from_slice!(s: this.b[args.i][2 ..])`, false,
			[]string{"Wuffs.Base.Slices.Copy_Within (Data => Self.F_B (Wuffs.Index (A_I)),"}},
		{"a row from another component", `this.n = this.b[args.i][.. 8].copy_from_slice!(s: this.a[.. 8])`, true,
			[]string{direct + " (Dst => Self.F_B (Wuffs.Index (A_I)) (0 .. 7),", "Src => Self.F_A (0 .. 7),"}},
		{"a component from a row", `this.n = this.a[.. 16].copy_from_slice!(s: this.b[args.j][..])`, true,
			[]string{direct + " (Dst => Self.F_A (0 .. 15),", "Src => Self.F_B (Wuffs.Index (A_J)),"}},
		{"a slice local made from a field, as the source", "s = this.a[..]\n\t\t\tthis.n = this.c[..].copy_from_slice!(s: s)", false,
			[]string{"Wuffs.Runtime.Copy_From_Slice (Dst => Self.F_C,"}},
		{"a slice local made from a field, as the destination", "s = this.a[..]\n\t\t\tthis.n = s.copy_from_slice!(s: this.c[..])", false,
			[]string{"Wuffs.Runtime.Copy_From_Slice (Dst => V_S.Base", "Src => Self.F_C,"}},
	} {
		got := mustGenerate(tt, `
		pub struct foo?(a : array[32] base.u8, c : array[32] base.u8, b : array[4] array[16] base.u8, n : base.u64)
		pub func foo.run!(i : base.u32[..= 3], j : base.u32[..= 3]) {
			var s : slice base.u8
			`+c.body+`
		}`)
		if n := strings.Count(got, direct); (n == 1) != c.isDirect || n > 1 {
			tt.Errorf("%s: %d direct two-array copies, want direct=%v:\n%s", c.name, n, c.isDirect, got)
		}
		for _, want := range c.wants {
			if !strings.Contains(got, want) {
				tt.Errorf("%s: output does not contain %q:\n%s", c.name, want, got)
			}
		}
	}
}

// TestModularIndexArithmetic checks which operators of an index or slice
// bound are computed in Wuffs.Index: Wuffs' checked "+" and "-" on u8 to
// u32 operands, but not "~mod+", "~mod-" (0 ~mod- 1 is the type's maximum,
// not -1) or the saturating operators, at any depth, nor anything on u64.
func TestModularIndexArithmetic(tt *testing.T) {
	got := mustGenerate(tt, `
		pub struct foo?(t : array[256] base.u8, n : base.u64)
		pub func foo.run!(k : base.u8, m : base.u8[..= 100], h : base.u16[..= 255], w : base.u64[..= 200], o : base.u32[..= 8]) {
			this.n = this.t[args.k ~mod- 1] as base.u64
			this.n = this.t[args.k ~mod+ 1] as base.u64
			this.n = this.t[args.h ~sat- 1] as base.u64
			this.n = this.t[args.m ~sat+ 100] as base.u64
			this.n = this.t[(args.m + 1) ~mod- 2] as base.u64
			this.n = this.t[(args.h ~mod- 1) & 0xFF] as base.u64
			if (args.k ~mod- 1) < 100 {
				this.n = this.t[(args.k ~mod- 1) + 1] as base.u64
			}
			this.n = this.t[args.w + 1] as base.u64
			this.n = this.t[(args.k ~mod- 1) ..].length()
			this.n = this.t[.. args.k ~mod+ 1].length()
			this.n = this.t[args.h ~sat- 1 ..].length()
			assert args.o <= (args.o + 8) via "a <= (a + b): 0 <= b"(b: 8)
			this.n = this.t[args.o .. args.o + 8].length()
			if args.k >= 4 {
				this.n = this.t[args.k - 4 ..].length()
			}
		}`)
	wantContains(tt, got,
		// ~mod- and ~mod+ as an index, in the modular type.
		"Self.F_N := Wuffs.U64 (Self.F_T (Wuffs.Index (A_K - 1)));",
		"Self.F_N := Wuffs.U64 (Self.F_T (Wuffs.Index (A_K + 1)));",
		// The saturating operators keep their functions.
		"(Self.F_T (Wuffs.Index (Wuffs.Base.Ints.Sat_Sub_U16 (X => A_H, Y => 1))))",
		"(Self.F_T (Wuffs.Index (Wuffs.Base.Ints.Sat_Add_U8 (X => A_M, Y => 100))))",
		// A ~mod- of a checked +: all of it modular.
		"Self.F_N := Wuffs.U64 (Self.F_T (Wuffs.Index ((A_M + 1) - 2)));",
		// Under a mask.
		"Self.F_N := Wuffs.U64 (Self.F_T (Wuffs.Index (A_H - 1 and 16#FF#)));",
		// A checked + of a ~mod-: the + in Wuffs.Index, the ~mod- not.
		"Self.F_N := Wuffs.U64 (Self.F_T (Wuffs.Index (A_K - 1) + 1));",
		// u64: never in Wuffs.Index.
		"Self.F_N := Wuffs.U64 (Self.F_T (Wuffs.Index (A_W + 1)));",
		// Slice bounds.
		"Self.F_N := Wuffs.U64 (Self.F_T (Wuffs.Index (A_K - 1) .. Self.F_T'Last)'Length);",
		"Self.F_N := Wuffs.U64 (Self.F_T (0 .. Wuffs.Index (A_K + 1) - 1)'Length);",
		"(Wuffs.Index (Wuffs.Base.Ints.Sat_Sub_U16 (X => A_H, Y => 1))\n",
		"Self.F_N := Wuffs.U64 (Self.F_T (Wuffs.Index (A_O) .. (Wuffs.Index (A_O) + 8) - 1)'Length);",
		"Self.F_N := Wuffs.U64 (Self.F_T (Wuffs.Index (A_K) - 4 .. Self.F_T'Last)'Length);",
	)
	wantNotContains(tt, got, "Wuffs.Index (A_K) - 1", "Wuffs.Index (A_K) + 1", "Wuffs.Index (A_H) - 1",
		"Wuffs.Index (A_M) + 1", "Wuffs.Index (A_W)")
}
