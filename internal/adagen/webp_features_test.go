// Part of wuffada (wuffs-ada: Wuffs to Ada).
// SPDX-License-Identifier: Apache-2.0 OR MIT

package adagen

import (
	"regexp"
	"strings"
	"testing"
)

// The tests of the generator features that std/vp8 and std/webp needed:
// make_pixel_blend and demake_pixel_blend, the accessors of range_ii_u64,
// and nullable pixel buffers ("nptr base.pixel_buffer"; passing one to a
// "ptr base.pixel_buffer", such as swizzle_ycck's, is a Wuffs type error,
// caught before the generator runs). advtest.wuffs
// (functions n1 .. n4) has the same shapes for test_adv, which compares them
// with upstream's C.

func TestPixelBlendMethods(tt *testing.T) {
	got := mustGenerate(tt, `
		pub struct foo? (
			x    : base.u32,
			util : base.utility,
		)
		pub func foo.bar!(b: base.pixel_blend, r: base.u8) {
			var c : base.pixel_blend
			c = this.util.make_pixel_blend(repr: args.r)
			this.x = (this.util.demake_pixel_blend(a: args.b) as base.u32) |
				(this.util.demake_pixel_blend(a: c) as base.u32)
		}`)
	wantContains(tt, got,
		"V_C := Wuffs.Base.Pixel_Formats.Make_Pixel_Blend (A_R);",
		"Wuffs.U32 (Wuffs.Base.Pixel_Formats.Demake_Pixel_Blend (A_B))",
		"Wuffs.U32 (Wuffs.Base.Pixel_Formats.Demake_Pixel_Blend (V_C))")
}

func TestRangeAccessors(tt *testing.T) {
	got := mustGenerate(tt, `
		pub struct foo? (
			x    : base.u64,
			util : base.utility,
		)
		pub func foo.bar!(lo: base.u64, hi: base.u64) {
			var r : base.range_ii_u64
			r = this.util.make_range_ii_u64(min_incl: args.lo, max_incl: args.hi)
			if r.is_empty() {
				return nothing
			}
			this.x = r.get_min_incl() ~mod+ r.get_max_incl()
		}`)
	wantContains(tt, got,
		"if Wuffs.Base.Ranges.Is_Empty (V_R) then",
		"Self.F_X := Wuffs.Base.Ranges.Get_Min_Incl (V_R) + Wuffs.Base.Ranges.Get_Max_Incl (V_R);")
}

// A nullable pixel buffer is four Ada parameters (descriptor, null flag,
// pixels, palette). A literal nullptr passes the null descriptor, True and
// two empty arrays of its own; a (non-null) pixel buffer argument passes
// False; a nullable one passes itself on. A method call on one says, in an
// assertion, what the Wuffs compiler proved: that it is not null.
func TestNullablePixelBuffer(tt *testing.T) {
	got := mustGenerate(tt, `
		pub struct foo? (
			x   : base.u64,
			buf : array[8] base.u8,
		)
		pub func foo.bar!(dst: ptr base.pixel_buffer) {
			var y : base.u64
			this.x = this.q!(dst: args.dst)
			y = this.q!(dst: nullptr)
			this.x ~mod+= y
			y = this.r!(dst: args.dst)
			this.x ~mod+= y
		}
		pri func foo.r!(dst: nptr base.pixel_buffer) base.u64 {
			var y : base.u64
			y = this.q!(dst: args.dst)
			return y
		}
		pri func foo.q!(dst: nptr base.pixel_buffer) base.u64 {
			var pal : slice base.u8
			if args.dst == nullptr {
				return 1
			}
			pal = args.dst.palette_or_else(fallback: this.buf[..])
			return pal.length()
		}`)
	wantContains(tt, got,
		// The parameters.
		"A_Dst : Wuffs.Base.Pixel_Buffers.Pixel_Buffer;\n      A_Dst_Null : Boolean;\n"+
			"      A_Dst_Pixels : in out Wuffs.Bytes;\n      A_Dst_Palette : in out Wuffs.Bytes)",
		// From a pixel buffer argument.
		"A_Dst_Null => False,",
		// From nullptr.
		"G_Null_Pixels_1 : Wuffs.Bytes (1 .. 0);",
		"pragma Warnings (Off, G_Null_Pixels_1);",
		"G_Null_Palette_1 : Wuffs.Bytes (1 .. 0);",
		"A_Dst => Wuffs.Base.Pixel_Buffers.Null_Pixel_Buffer,",
		"A_Dst_Null => True,",
		"A_Dst_Pixels => G_Null_Pixels_1,",
		"A_Dst_Palette => G_Null_Palette_1",
		// Passed on.
		"A_Dst_Null => A_Dst_Null,",
		// Compared with nullptr; a method call.
		"if A_Dst_Null then",
		"pragma Assert (not A_Dst_Null);")
}

// At a public entry, a nullable pixel buffer is checked only if it is not
// null, and then like any other pixel buffer, and also against the
// receiver; the null flag itself is checked first. Two pixel buffers'
// arrays must be apart from each other.
func TestNullablePixelBufferEntry(tt *testing.T) {
	got := mustGenerate(tt, `
		pub struct foo? (
			x : base.u64,
		)
		pub func foo.bar!(a: ptr base.pixel_buffer, b: nptr base.pixel_buffer, w: slice base.u8) {
			if args.b <> nullptr {
				this.x = args.b.pixel_format().bits_per_pixel() as base.u64
			}
			this.x ~mod+= args.a.pixel_format().bits_per_pixel() as base.u64
			this.x ~mod+= args.w.length()
		}`)
	wantContains(tt, got,
		"if not A_B_Null'Valid\n",
		"or else (not A_B_Null\n",
		"and then (not Wuffs.Runtime.Valid_Pixel_Buffer\n",
		"(PB => A_B,\n",
		"(A => A_B_Pixels,\n",
		"(A => A_B_Palette,\n",
		// B's arrays against the work buffer, under the null check.
		"Wuffs.Runtime.Share_An_Element (A => A_B_Pixels, B => A_W)",
		// A's against B's, under B's null check.
		"and then Wuffs.Runtime.Share_An_Element (A => A_B_Pixels, B => A_A_Pixels))",
		"and then Wuffs.Runtime.Share_An_Element (A => A_B_Palette, B => A_A_Palette))",
		"Self.Magic := Wuffs.Runtime.Magic_Disabled;")
	// Every disjunct of the condition that mentions B's arrays is under its
	// null check.
	cond := got[strings.Index(got, "if not A_B_Null'Valid"):]
	cond = cond[:regexp.MustCompile(`\n *then\n`).FindStringIndex(cond)[0]]
	sep := regexp.MustCompile(`\n *or else `).FindString(cond)
	for _, d := range strings.Split(cond, sep) {
		if strings.Contains(d, "A_B_Pixels") || strings.Contains(d, "A_B_Palette") || strings.Contains(d, "PB => A_B") {
			if !strings.HasPrefix(d, "(not A_B_Null\n") {
				tt.Errorf("a check of the nullable pixel buffer that is not under its null check: %s", d)
			}
		}
	}
}

func TestRejectsNewFeatures(tt *testing.T) {
	const prelude = "pub struct foo? (\n    x : base.u64,\n    util : base.utility,\n)\n"
	testCases := []struct {
		what string
		src  string
		want string
	}{{
		what: "range_ii_u64.intersect",
		src: prelude + `
			pub func foo.bar!(lo: base.u64, hi: base.u64) {
				var r : base.range_ii_u64
				r = this.util.make_range_ii_u64(min_incl: args.lo, max_incl: args.hi)
				r = r.intersect(r: r)
				this.x = r.get_min_incl()
			}`,
		want: "not yet supported: method call \"r.intersect(r: r)\" on a receiver of type \"base.range_ii_u64\"",
	}, {
		what: "range_ii_u64.unite",
		src: prelude + `
			pub func foo.bar!(lo: base.u64, hi: base.u64) {
				var r : base.range_ii_u64
				r = this.util.make_range_ii_u64(min_incl: args.lo, max_incl: args.hi)
				r = r.unite(r: r)
				this.x = r.get_max_incl()
			}`,
		want: "not yet supported: method call \"r.unite(r: r)\"",
	}, {
		what: "assigning to a nullable pixel buffer argument",
		src: prelude + `
			pri func foo.bar!(dst: nptr base.pixel_buffer) {
				args.dst = nullptr
				this.x = 1
			}`,
		want: "not yet supported: assigning to args.dst",
	}, {
		what: "a nullable pixel buffer local",
		src: prelude + `
			pri func foo.bar!(dst: nptr base.pixel_buffer) {
				var p : nptr base.pixel_buffer
				p = args.dst
				this.x = 1
			}`,
		want: "not yet supported: var p of type \"nptr base.pixel_buffer\"",
	}, {
		what: "parameters whose companions clash",
		src: prelude + `
			pri func foo.bar!(dst: nptr base.pixel_buffer, dst_null: base.bool) {
				if args.dst_null {
					this.x = 1
				}
			}`,
		want: "\"A_Dst_Null\"",
	}}
	for _, tc := range testCases {
		out, err := generate(Options{PackageName: "pkg"}, []string{"test.wuffs"}, [][]byte{[]byte(tc.src + "\n")})
		if err == nil {
			tt.Errorf("%s: got no error, want one containing %q. Output:\n%s", tc.what, tc.want, out.Body)
		} else if !strings.Contains(err.Error(), tc.want) {
			tt.Errorf("%s: got error %q, want one containing %q", tc.what, err, tc.want)
		}
	}
}
