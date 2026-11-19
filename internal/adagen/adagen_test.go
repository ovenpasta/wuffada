// Part of wuffada (wuffs-ada: Wuffs to Ada).
// SPDX-License-Identifier: Apache-2.0 OR MIT

package adagen

import (
	"bytes"
	"flag"
	"fmt"
	"math/big"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/google/wuffs/lang/check"
	"github.com/google/wuffs/lang/parse"

	a "github.com/google/wuffs/lang/ast"
	t "github.com/google/wuffs/lang/token"
)

var update = flag.Bool("update", false, "rewrite the golden files in testdata")

// generate runs the Wuffs front end and then Generate on in-memory sources.
// names and srcs are parallel.
func generate(opts Options, names []string, srcs [][]byte) (*Output, error) {
	tm := &t.Map{}
	files := []*a.File(nil)
	for i, src := range srcs {
		tokens, _, err := t.Tokenize(tm, names[i], src)
		if err != nil {
			return nil, err
		}
		f, err := parse.Parse(tm, names[i], tokens, nil)
		if err != nil {
			return nil, err
		}
		files = append(files, f)
	}
	resolveUse := func(usePath string) ([]byte, error) {
		return nil, fmt.Errorf("no such use path %q", usePath)
	}
	if _, err := check.Check(tm, files, resolveUse); err != nil {
		return nil, err
	}
	return Generate(tm, files, opts)
}

func generateFiles(opts Options, names ...string) (*Output, error) {
	srcs := [][]byte(nil)
	for _, name := range names {
		src, err := os.ReadFile(name)
		if err != nil {
			return nil, err
		}
		srcs = append(srcs, src)
	}
	return generate(opts, names, srcs)
}

func compareGolden(tt *testing.T, got []byte, goldenFile string) {
	tt.Helper()
	if *update {
		if err := os.WriteFile(goldenFile, got, 0644); err != nil {
			tt.Fatal(err)
		}
		return
	}
	want, err := os.ReadFile(goldenFile)
	if err != nil {
		tt.Fatalf("%v (run \"go test -update\" to create it)", err)
	}
	if !bytes.Equal(got, want) {
		tt.Errorf("output differs from %s (run \"go test -update\", or ./gen.sh, and review the diff)\ngot:\n%s",
			goldenFile, got)
	}
}

func TestGolden(tt *testing.T) {
	out, err := generateFiles(Options{PackageName: "tiny", PackageID: 7}, "testdata/tiny.wuffs")
	if err != nil {
		tt.Fatal(err)
	}
	if out.UnitName != "Wuffs.Std.Tiny" || out.SpecFile != "wuffs-std-tiny.ads" || out.BodyFile != "wuffs-std-tiny.adb" {
		tt.Errorf("unexpected names: %q, %q, %q", out.UnitName, out.SpecFile, out.BodyFile)
	}
	compareGolden(tt, out.Spec, "testdata/tiny.ads.golden")
	compareGolden(tt, out.Body, "testdata/tiny.adb.golden")
}

func TestDeterministic(tt *testing.T) {
	first, err := generateFiles(Options{PackageName: "m1test", PackageID: 65535}, "testdata/m1test.wuffs")
	if err != nil {
		tt.Fatal(err)
	}
	for i := 0; i < 5; i++ {
		again, err := generateFiles(Options{PackageName: "m1test", PackageID: 65535}, "testdata/m1test.wuffs")
		if err != nil {
			tt.Fatal(err)
		}
		if !bytes.Equal(first.Spec, again.Spec) || !bytes.Equal(first.Body, again.Body) {
			tt.Fatalf("output differs between runs")
		}
	}
}

// TestCheckedIn checks that the generated Ada that is checked in (under
// ada/gen and ada/tests) is what the generator produces now.
func TestCheckedIn(tt *testing.T) {
	root := filepath.Join("..", "..")
	testCases := []struct {
		name   string
		outDir string
		files  []string
	}{{
		name:   "adler32",
		outDir: "ada/gen",
		files: []string{
			"wuffs/std/adler32/common_adler32.wuffs",
			"wuffs/std/adler32/common_up_arm_neon.wuffs",
			"wuffs/std/adler32/common_up_x86_sse42.wuffs",
		},
	}, {
		name:   "crc32",
		outDir: "ada/gen",
		files: []string{
			"wuffs/std/crc32/common_crc32.wuffs",
			"wuffs/std/crc32/common_up_arm_crc32.wuffs",
			"wuffs/std/crc32/common_up_x86_sse42.wuffs",
		},
	}, {
		name:   "m1test",
		outDir: "ada/tests",
		files:  []string{"internal/adagen/testdata/m1test.wuffs"},
	}}

	for _, tc := range testCases {
		srcs := [][]byte(nil)
		missing := false
		for _, name := range tc.files {
			src, err := os.ReadFile(filepath.Join(root, filepath.FromSlash(name)))
			if os.IsNotExist(err) {
				missing = true
				break
			} else if err != nil {
				tt.Fatal(err)
			}
			srcs = append(srcs, src)
		}
		if missing {
			tt.Logf("%s: skipped: no Wuffs checkout at ./wuffs", tc.name)
			continue
		}
		id, err := PackageID(tc.name)
		if err != nil || id == 0 {
			tt.Errorf("%s: no package id: %v", tc.name, err)
			continue
		}
		out, err := generate(Options{PackageName: tc.name, PackageID: id}, tc.files, srcs)
		if err != nil {
			tt.Errorf("%s: %v", tc.name, err)
			continue
		}
		for _, x := range []struct {
			file string
			got  []byte
		}{{out.SpecFile, out.Spec}, {out.BodyFile, out.Body}} {
			filename := filepath.Join(root, filepath.FromSlash(tc.outDir), x.file)
			want, err := os.ReadFile(filename)
			if err != nil {
				tt.Errorf("%s: %v (run ./gen.sh)", tc.name, err)
			} else if !bytes.Equal(x.got, want) {
				tt.Errorf("%s: %s is stale (run ./gen.sh)", tc.name, filename)
			}
		}
	}
}

func TestSkipsCPUArchFunctions(tt *testing.T) {
	root := filepath.Join("..", "..", "wuffs", "std", "adler32")
	names := []string{"common_adler32.wuffs", "common_up_arm_neon.wuffs", "common_up_x86_sse42.wuffs"}
	srcs := [][]byte(nil)
	for _, name := range names {
		src, err := os.ReadFile(filepath.Join(root, name))
		if os.IsNotExist(err) {
			tt.Skip("no Wuffs checkout at ./wuffs")
		} else if err != nil {
			tt.Fatal(err)
		}
		srcs = append(srcs, src)
	}
	out, err := generate(Options{PackageName: "adler32"}, names, srcs)
	if err != nil {
		tt.Fatal(err)
	}
	if got, want := strings.Join(out.Skipped, " "), "hasher.up_arm_neon hasher.up_x86_sse42"; got != want {
		tt.Errorf("skipped: got %q, want %q", got, want)
	}
	// The comments legitimately name the skipped functions, in Wuffs
	// spelling. No Ada entity may be generated for them.
	all := string(out.Spec) + string(out.Body)
	for _, s := range []string{"Up_Arm_Neon", "Up_X86_Sse42", "M128i", "Arm_Neon_U", "Cpu_Arch"} {
		if strings.Contains(all, s) {
			tt.Errorf("output mentions %q", s)
		}
	}
	for _, s := range []string{"procedure Up (Self : in out Hasher; A_X : Wuffs.Bytes) is"} {
		if !strings.Contains(all, s) {
			tt.Errorf("output does not mention %q", s)
		}
	}
}

// TestRejects checks that unsupported constructs are errors, not silently
// wrong output. Each source passes the Wuffs compiler's own checks.
func TestRejects(tt *testing.T) {
	const prelude = "pub struct foo? (\n    x : base.u32,\n    a : array[4] base.u8,\n)\n"
	testCases := []struct {
		what string
		src  string
		opts Options
		want string
	}{{
		what: "coroutine",
		src: prelude + `
			pub func foo.bar?(src: base.io_reader) {
				var c : base.u8
				c = args.src.read_u8?()
				this.x = c as base.u32
			}`,
		want: "not yet supported: coroutines",
	}, {
		what: "yield in a coroutine",
		src: prelude + `
			pub func foo.bar?() {
				yield? base."$short read"
			}`,
		want: "not yet supported: coroutines",
	}, {
		what: "non-classy struct",
		src:  "pub struct foo(\n    x : base.u32,\n)\n",
		want: "not yet supported: struct foo: non-classy structs",
	}, {
		what: "private struct",
		src:  "pri struct foo?(\n    x : base.u32,\n)\n",
		want: "not yet supported: struct foo: private structs",
	}, {
		what: "writable slice parameter",
		src: prelude + `
			pub func foo.bar!(dst: slice base.u8) {
				this.x = (args.dst.length() & 0xFF) as base.u32
			}`,
		want: "not yet supported: parameter dst of type \"slice base.u8\"",
	}, {
		what: "unsupported builtin method",
		src: prelude + `
			pub func foo.bar!(v: base.u32) {
				this.x = args.v.min(no_more_than: 4)
			}`,
		want: "not yet supported: method call",
	}, {
		what: "slicing an array",
		src: prelude + `
			pri func foo.baz!(s: roslice base.u8) {
				this.x = (args.s.length() & 0xFF) as base.u32
			}
			pub func foo.bar!() {
				this.baz!(s: this.a[.. 2])
			}`,
		want: "not yet supported: slicing",
	}, {
		what: "interface without an Ada equivalent",
		src: `pub struct foo? implements base.hasher_u64()
			pub func foo.checksum_u64() base.u64 {
				return 0
			}
			pub func foo.get_quirk(key: base.u32) base.u64 {
				return 0
			}
			pub func foo.set_quirk!(key: base.u32, value: base.u64) base.status {
				return ok
			}
			pub func foo.update!(x: roslice base.u8) {
			}
			pub func foo.update_u64!(x: roslice base.u8) base.u64 {
				return 0
			}`,
		want: "not yet supported: struct foo: implements base.hasher_u64",
	}, {
		what: "statuses without a package id",
		src:  "pub status \"#bad\"\n" + prelude,
		want: "needs a package id",
	}, {
		what: "Ada reserved word as a function name",
		src: prelude + `
			pub func foo.entry!() {
				this.x = 1
			}`,
		want: "\"Entry\" is not usable as an Ada identifier",
	}, {
		what: "names that differ only by case",
		src:  "pub const FOO : base.u32 = 1\n" + prelude,
		want: "collides with struct foo (Ada is case-insensitive)",
	}, {
		what: "assigning to an iterate variable in its loop",
		src: prelude + `
			pub func foo.bar!(s: roslice base.u8) {
				var p : roslice base.u8
				iterate (p = args.s)(length: 2, advance: 2, unroll: 1) {
					this.x = p[0] as base.u32
					p = p[1 ..]
				}
			}`,
		want: "not yet supported: assigning to the iterate variable \"p\" inside its iterate loop",
	}, {
		what: "public function returning a bool",
		src: prelude + `
			pub func foo.bar() base.bool {
				return this.x == 0
			}`,
		want: "public function returns \"base.bool\", which upstream's wuffs-c also rejects",
	}, {
		what: "local variables that differ only by case",
		src: prelude + `
			pub func foo.bar!() {
				var abc : base.u32
				var aBC : base.u32
				abc = 1
				aBC = 2
				this.x = abc ~mod+ aBC
			}`,
		want: "another local variable has the same Ada name \"V_ABC\"",
	}, {
		what: "returning a non-literal status",
		src: prelude + `
			pri func foo.baz!() base.status {
				return ok
			}
			pub func foo.bar!() base.status {
				var z : base.status
				z = this.baz!()
				return z
			}`,
		want: "not yet supported: returning a status that is not an ok, error or note literal",
	}}

	for _, tc := range testCases {
		out, err := generate(tc.opts.withName("pkg"), []string{"test.wuffs"}, [][]byte{[]byte(tc.src + "\n")})
		if err == nil {
			tt.Errorf("%s: got no error, want one containing %q. Output:\n%s", tc.what, tc.want, out.Body)
		} else if !strings.Contains(err.Error(), tc.want) {
			tt.Errorf("%s: got error %q, want one containing %q", tc.what, err, tc.want)
		}
	}
}

func (o Options) withName(name string) Options {
	o.PackageName = name
	return o
}

func TestMangle(tt *testing.T) {
	testCases := []struct{ in, want string }{
		{"update_u32", "Update_U32"},
		{"ieee_hasher", "Ieee_Hasher"},
		{"IEEE_TABLE", "IEEE_TABLE"},
		{"p__left", "P_U_Left"},
		{"x_", "X_U"},
		{"s1", "S1"},
	}
	for _, tc := range testCases {
		if got := mangle(tc.in); got != tc.want {
			tt.Errorf("mangle(%q): got %q, want %q", tc.in, got, tc.want)
		}
	}

	msgCases := []struct{ in, want string }{
		{"#unsupported option", "Error_Unsupported_Option"},
		{"$short read", "Suspension_Short_Read"},
		{"@end of data", "Note_End_Of_Data"},
		{"#bad argument (length too short)", "Error_Bad_Argument_Length_Too_Short"},
		{"#bad I/O position", "Error_Bad_I_O_Position"},
	}
	for _, tc := range msgCases {
		if got, err := mangleMessage(tc.in); err != nil || got != tc.want {
			tt.Errorf("mangleMessage(%q): got %q, %v, want %q", tc.in, got, err, tc.want)
		}
	}
}

func TestNumLiteral(tt *testing.T) {
	testCases := []struct {
		x    int64
		src  string
		want string
	}{
		{65521, "65521", "65521"},
		{0xFFFF, "0xFFFF", "16#FFFF#"},
		{0xFFFFFFFF, "0xFFFF_FFFF", "16#FFFF_FFFF#"},
		{0x0F, "0x0F", "16#0F#"},
		{0x10000, "", "16#1_0000#"},
		{12, "", "12"},
	}
	for _, tc := range testCases {
		if got := sourceLiteral(big.NewInt(tc.x), tc.src); got != tc.want {
			tt.Errorf("sourceLiteral(%d, %q): got %q, want %q", tc.x, tc.src, got, tc.want)
		}
	}
}

func TestWrap(tt *testing.T) {
	// A long chain breaks before each operator, and nothing exceeds maxCol.
	args := []expr(nil)
	for i := 0; i < 12; i++ {
		args = append(args, call("Some_Table", raw(fmt.Sprint(i)), call("Wuffs.Index", raw("V_Value"))))
	}
	p := &printer{indent: 6}
	p.stmt(sAssign{raw("V_Result"), bin("xor", args...)})
	lines := strings.Split(strings.TrimRight(p.b.String(), "\n"), "\n")
	if len(lines) != 13 {
		tt.Errorf("got %d lines, want 13:\n%s", len(lines), p.b.String())
	}
	for _, s := range lines {
		if len(s) > maxCol {
			tt.Errorf("line too long: %q", s)
		}
	}

	// Parentheses follow Ada's precedence rules.
	e := bin("or else", bin("and then", bin("<", raw("A"), raw("B")), raw("C")), eUn{"not", raw("D")})
	if got, want := flat(e), "(A < B and then C) or else not D"; got != want {
		tt.Errorf("flat: got %q, want %q", got, want)
	}
	e = bin("+", bin("*", raw("A"), raw("B")), bin("-", raw("C"), raw("D")))
	if got, want := flat(e), "A * B + (C - D)"; got != want {
		tt.Errorf("flat: got %q, want %q", got, want)
	}
}

// mustGenerate generates Ada for one in-memory source that must be accepted.
func mustGenerate(tt *testing.T, src string) string {
	tt.Helper()
	out, err := generate(Options{PackageName: "pkg", PackageID: 3}, []string{"test.wuffs"}, [][]byte{[]byte(src + "\n")})
	if err != nil {
		tt.Fatal(err)
	}
	return string(out.Spec) + string(out.Body)
}

func wantContains(tt *testing.T, got string, wants ...string) {
	tt.Helper()
	for _, want := range wants {
		if !strings.Contains(got, want) {
			tt.Errorf("output does not contain %q:\n%s", want, got)
		}
	}
}

func wantNotContains(tt *testing.T, got string, unwanted ...string) {
	tt.Helper()
	for _, s := range unwanted {
		if strings.Contains(got, s) {
			tt.Errorf("output contains %q:\n%s", s, got)
		}
	}
}

// The TestNames tests check that a Wuffs name cannot collide with, or be
// hidden by, a generator-made Ada name. The same sources are in
// testdata/m1test.wuffs, which GNAT compiles and test_m1 runs.

func TestNamesIterateTemporaries(tt *testing.T) {
	got := mustGenerate(tt, `
		pri const I1_END : base.u32 = 7
		pri const I1_POS : base.u32 = 3
		pri const G_I1_POS : base.u32 = 5
		pub struct foo? (
			h : array[8] base.u8,
		)
		pub func foo.bar!(x: roslice base.u8) base.u64 {
			var p : roslice base.u8
			var s : base.u64
			var t : base.u32
			iterate (p = args.x)(length: 1, advance: 1, unroll: 1) {
				t = (p[0] as base.u32) ~mod+ I1_END
				s ~mod+= (t as base.u64) ~mod+ (this.h[I1_POS] as base.u64)
				s ~mod+= this.h[G_I1_POS] as base.u64
			}
			return s
		}`)
	wantContains(tt, got,
		"   I1_END : constant Wuffs.U32 := 7;",
		"   I1_POS : constant Wuffs.U32 := 3;",
		"   W_G_I1_POS : constant Wuffs.U32 := 5;",
		"      G_I1_Pos : Wuffs.Index := 0;",
		"      G_I1_End : Wuffs.Index := 0;",
		"Wuffs.U32 (Wuffs.Runtime.Get (V_P, 0)) + I1_END;",
		"Self.F_H (Wuffs.Index (I1_POS))",
		"Self.F_H (Wuffs.Index (W_G_I1_POS))",
		"while G_I1_Pos < G_I1_End loop")
	wantNotContains(tt, got, " I1_Pos ", " I1_End ", " I1_Src ")
}

func TestNamesSliceTemporary(tt *testing.T) {
	got := mustGenerate(tt, `
		pri const T1 : roarray[4] base.u8 = [10, 20, 30, 40]
		pri const G_T1 : roarray[4] base.u8 = [50, 60, 70, 80]
		pub struct foo? (
			x : base.u32,
		)
		pri func foo.baz(s: roslice base.u8) base.u32 {
			return (args.s.length() & 0xFF) as base.u32
		}
		pub func foo.bar!(x: roslice base.u8) base.u32 {
			var s : base.u32
			s = this.baz(s: args.x[.. 0])
			s ~mod+= T1[s & 3] as base.u32
			s ~mod+= G_T1[s & 3] as base.u32
			return s
		}`)
	wantContains(tt, got,
		"   T1 : constant Wuffs.Bytes (0 .. 3) :=",
		"   W_G_T1 : constant Wuffs.Bytes (0 .. 3) :=",
		"      G_T1 : Wuffs.Runtime.RO_Slice_U8;",
		"Baz (Self, G_T1.Base (G_T1.First .. Wuffs.Runtime.Last (G_T1)))",
		"Wuffs.U32 (T1 (Wuffs.Index (V_S and 3)))",
		"Wuffs.U32 (W_G_T1 (Wuffs.Index (V_S and 3)))")
}

func TestNamesLoopName(tt *testing.T) {
	got := mustGenerate(tt, `
		pub struct foo? (
			x : base.u32,
		)
		pri func foo.loop_1!() base.u32 {
			this.x ~mod+= 1
			return this.x
		}
		pri func foo.g_loop_1!() base.u32 {
			this.x ~mod+= 2
			return this.x
		}
		pub func foo.bar!(n: base.u32) base.u32 {
			var s : base.u32
			while true {
				s ~mod+= this.loop_1!()
				s ~mod+= this.g_loop_1!()
				if s > args.n {
					break
				}
			}
			return s
		}`)
	wantContains(tt, got,
		"   function Loop_1 (Self : in out Foo) return Wuffs.U32;",
		"   function W_G_Loop_1 (Self : in out Foo) return Wuffs.U32;",
		"      G_Loop_1 :\n      loop",
		"V_S := V_S + Loop_1 (Self);",
		"V_S := V_S + W_G_Loop_1 (Self);",
		"exit G_Loop_1;")
}

func TestMangleGlobal(tt *testing.T) {
	testCases := []struct{ in, want string }{
		{"update", "Update"},
		{"IEEE_TABLE", "IEEE_TABLE"},
		{"v", "W_V"},
		{"V_S", "W_V_S"},
		{"a_x", "W_A_X"},
		{"m_n", "W_M_N"},
		{"f_state", "W_F_State"},
		{"g_loop_1", "W_G_Loop_1"},
		{"w_v_s", "W_W_V_S"},
		{"value", "Value"},
		{"global", "Global"},
	}
	for _, tc := range testCases {
		if got := mangleGlobal(tc.in); got != tc.want {
			tt.Errorf("mangleGlobal(%q): got %q, want %q", tc.in, got, tc.want)
		}
	}
}

// TestProvedPragmas checks that the constant-condition warning is turned off
// around lowered assertions only.
func TestProvedPragmas(tt *testing.T) {
	got := mustGenerate(tt, `
		pub struct foo? (
			x : base.u32,
		)
		pub func foo.bar!(n: base.u32) {
			var i : base.u32[..= 10]
			while i < 10,
				inv i <= 10,
			{
				assert i < 10
				i += 1
			}
			this.x = i
		}`)
	wantContains(tt, got, ""+
		"      while V_I < 10 loop\n"+
		"         pragma Warnings (\"C\");\n"+
		"         pragma Loop_Invariant (V_I <= 10);\n"+
		"         pragma Assert (V_I < 10);\n"+
		"         pragma Warnings (\"c\");\n"+
		"         V_I := V_I + 1;\n"+
		"      end loop;\n"+
		"      pragma Warnings (\"C\");\n"+
		"      pragma Assert (V_I <= 10);\n"+
		"      pragma Warnings (\"c\");\n")
	if n := strings.Count(got, "pragma Warnings"); n != 4 {
		tt.Errorf("got %d pragma Warnings, want 4", n)
	}
}

// TestNoFinalReturn checks that a value-returning function may end with a
// "while true" loop or an if-else chain that cannot fall through.
func TestNoFinalReturn(tt *testing.T) {
	got := mustGenerate(tt, `
		pub struct foo? (
			x : base.u32,
		)
		pub func foo.find(v: base.u32) base.u32 {
			var i : base.u32
			while true {
				if (i ~mod* i) >= args.v {
					return i
				}
				i ~mod+= 1
			}
		}`)
	wantContains(tt, got, ""+
		"      loop\n"+
		"         if V_I * V_I >= A_V then\n"+
		"            return V_I;\n"+
		"         end if;\n"+
		"         V_I := V_I + 1;\n"+
		"      end loop;\n"+
		"   end Find;\n")
}

// TestLongSourceName checks that the header stays within the line length
// limit whatever the source files are called.
func TestLongSourceName(tt *testing.T) {
	name := strings.Repeat("a/very/long/directory/name/", 8) + "file.wuffs"
	out, err := generate(Options{PackageName: "pkg"}, []string{name},
		[][]byte{[]byte("pub struct foo? (\n    x : base.u32,\n)\n")})
	if err != nil {
		tt.Fatal(err)
	}
	for _, text := range [][]byte{out.Spec, out.Body} {
		joined := ""
		for _, line := range strings.Split(string(text), "\n") {
			if len(line) > maxCol {
				tt.Errorf("line too long (%d): %q", len(line), line)
			}
			if strings.HasPrefix(line, "--") {
				joined += strings.TrimSpace(strings.TrimPrefix(line, "--"))
			}
		}
		if !strings.Contains(joined, name) {
			tt.Errorf("header does not name the source file:\n%s", text)
		}
	}
}

func TestPackageIDs(tt *testing.T) {
	for name, want := range map[string]uint32{"adler32": 1, "crc32": 2, "m1test": 65535, "nosuch": 0} {
		if got, err := PackageID(name); err != nil || got != want {
			tt.Errorf("PackageID(%q): got %d, %v, want %d", name, got, err, want)
		}
	}
}
