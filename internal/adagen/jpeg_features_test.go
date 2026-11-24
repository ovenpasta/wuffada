// Part of wuffada (wuffs-ada: Wuffs to Ada).
// SPDX-License-Identifier: Apache-2.0 OR MIT

package adagen

import (
	"strings"
	"testing"
)

// The tests of the generator features that std/jpeg needed: status fields,
// choosy functions with refined parameters, the bulk methods, pointers to
// rows of a field and swizzle_ycck. advtest.wuffs (functions z1 and z2) has
// the same shapes for test_adv, which compares them with upstream's C.

func TestStatusField(tt *testing.T) {
	got := mustGenerate(tt, `
		pub struct foo? (
			s : base.status,
			x : base.u32,
		)
		pub func foo.bar!(x: base.u32) {
			if args.x > 3 {
				this.s = base."#bad argument"
			} else {
				this.s = ok
			}
			if this.s.is_error() {
				this.x = 1
			}
		}`)
	wantContains(tt, got,
		"F_S : Wuffs.Status := Wuffs.Ok_Status;",
		"Self.F_S := Wuffs.Ok_Status;\n", // Initialize.
		"Self.F_S := Wuffs.Base.Error_Bad_Argument;",
		"if Wuffs.Is_Error (Self.F_S) then")
}

// Two functions with the same refined parameter types are alternatives of a
// choose statement (typeOf makes a new adaType for each refinement).
func TestChoosyRefinedSignature(tt *testing.T) {
	got := mustGenerate(tt, `
		pub struct foo? (
			x : base.u32,
		)
		pri func foo.mix!(a: base.u32[..= 9], b: base.u8[..= 3]),
			choosy,
		{
			this.x = args.a + (args.b as base.u32)
		}
		pri func foo.mix_other!(a: base.u32[..= 9], b: base.u8[..= 3]) {
			this.x = args.a ~mod* (args.b as base.u32)
		}
		pub func foo.bar!(c: base.u32) {
			if args.c > 0 {
				choose mix = [mix_other]
			} else {
				choose mix = [mix]
			}
			this.mix!(a: 4, b: 2)
		}`)
	wantContains(tt, got,
		"Self.G_Choosy_Mix := 1;",
		"if Self.G_Choosy_Mix = 1 then\n         Mix_Other (Self => Self, A_A => A_A, A_B => A_B);",
		"G_Choosy_Default_Mix (Self => Self, A_A => A_A, A_B => A_B);")
}

func TestBulkMethods(tt *testing.T) {
	got := mustGenerate(tt, `
		pub struct foo? (
			buf  : array[16] base.u8,
			rows : array[3] array[4] base.u16,
			u32s : array[3] base.u32,
		)
		pub func foo.bar!(w: slice base.u8, n: base.u32[..= 2]) {
			this.rows[args.n .. 3].bulk_load_host_endian!(src: args.w)
			this.rows[.. 1].bulk_save_host_endian!(dst: this.buf[3 .. 12])
			this.u32s[1 .. 3].bulk_load_host_endian!(src: this.buf[2 ..])
			this.u32s[.. 2].bulk_save_host_endian!(dst: args.w)
			this.buf[2 .. 10].bulk_load_host_endian!(src: this.buf[1 ..])
			this.buf[4 .. 12].bulk_save_host_endian!(dst: this.buf[..])
			this.rows[1 .. 2].bulk_memset!(byte_value: 7)
			this.u32s[.. 3].bulk_memset!(byte_value: 1)
			args.w[.. 0].bulk_memset!(byte_value: 2)
		}`)
	wantContains(tt, got,
		// Rows: all or nothing, then one call per row with its part of the
		// byte slice.
		// The bounds are evaluated once, before anything is copied.
		"G_T1 := Wuffs.Index (A_N);",
		"G_T2 := 3;",
		"if Wuffs.Base.Slices.Bulk_Fits (Count => (G_T2 - G_T1) * 4,",
		"Size => 2,",
		"while G_T3 < G_T2 loop",
		"(Dst => Self.F_Rows (G_T3),\n",
		"Wuffs.Runtime.Subslice_IJ (S => G_T4,\n",
		"I => (G_T3 - G_T1) * 8,\n",
		"J => (G_T3 - G_T1) * 8 + 8);",
		"Src => G_T5.Base (G_T5.First .. Wuffs.Runtime.Last (G_T5)));",
		"G_T10 := Wuffs.Runtime.Subslice_IJ (S => G_T9, I => G_T8 * 8, J => G_T8 * 8 + 8);",
		"(Dst => G_T10.Base (G_T10.First .. Wuffs.Runtime.Last (G_T10)),\n",
		"Src => Self.F_Rows (G_T8));",
		// One array of wider numbers: its Ada slice.
		"Wuffs.Runtime.Bulk_Load_Host_Endian_U32 (Dst => Self.F_U32s (1 .. 2),",
		"Wuffs.Runtime.Bulk_Save_Host_Endian_U32 (Dst => A_W, Src => Self.F_U32s (0 .. 1));",
		// Bytes, with the address dispatch (the other part of the one
		// field goes through a handle).
		"Wuffs.Runtime.Bulk_Load_Host_Endian_U8 (Dst => Self.F_Buf (2 .. 9),\n",
		"Wuffs.Runtime.Bulk_Save_Host_Endian_U8 (Dst => Self.F_Buf,\n",
		// Memsets need no shell.
		// A memset of rows: its value is evaluated once too.
		"G_T16 := 7;",
		"Wuffs.Base.Slices.Bulk_Memset_U16 (Dst => Self.F_Rows (G_T17), Byte_Value => G_T16);",
		"Wuffs.Base.Slices.Bulk_Memset_U32 (Dst => Self.F_U32s (0 .. 2), Byte_Value => 1);",
		"Wuffs.Base.Slices.Bulk_Memset_U8 (Dst => A_W (A_W'First .. (A_W'First + 0) - 1),")
	// Never the proved forms for disjoint arrays directly, for two parts of
	// one field.
	wantNotContains(tt, got, "Wuffs.Base.Slices.Bulk_Load_Host_Endian_U8 (", "Wuffs.Base.Slices.Bulk_Save_Host_Endian_U8 (",
		"Dst => Self.F_Buf (2 .. 9), Src => Self.F_Buf")
}

// The bulk methods in a coroutine, after a suspension point: the
// temporaries are assigned after it (checkTemps would fail otherwise).
func TestBulkInCoroutine(tt *testing.T) {
	got := mustGenerate(tt, `
		pub struct foo? (
			rows : array[3] array[4] base.u16,
		)
		pub func foo.bar?(src: base.io_reader, w: slice base.u8) {
			var c : base.u8
			c = args.src.read_u8?()
			this.rows[.. 2].bulk_load_host_endian!(src: args.w)
			c = args.src.read_u8?()
			this.rows[(c & 1) as base.u32 .. 2].bulk_save_host_endian!(dst: args.w)
		}`)
	resume := strings.Index(got, "<<G_Resume_2>>")
	load := strings.Index(got, "Bulk_Load_Host_Endian_U16")
	save := strings.Index(got, "Bulk_Save_Host_Endian_U16")
	if resume < 0 || load < 0 || save < 0 || !(load < resume && resume < save) {
		tt.Errorf("unexpected order of resume label, load and save:\n%s", got)
	}
}

func TestRowPointer(tt *testing.T) {
	got := mustGenerate(tt, `
		pub struct foo? (
			tabs : array[3] array[8] base.u16,
			x    : base.u32,
		)
		pub func foo.bar!(i: base.u32[..= 2], j: base.u32[..= 7]) {
			var p : nptr roarray[8] base.u16
			var k : base.u32
			p = this.tabs[args.i][..] as ptr array[8] base.u16
			while k < 2,
					inv p <> nullptr,
			{
				this.x ~mod+= p[args.j] as base.u32
				k += 1
			}
		}`)
	wantContains(tt, got,
		"V_P : Wuffs.Offset := -1;",
		"V_P := Wuffs.Index (A_I);",
		"pragma Loop_Invariant (V_P /= -1);",
		"Wuffs.U32 (Self.F_Tabs (V_P) (Wuffs.Index (A_J)))")
}

func TestSwizzleYCCK(tt *testing.T) {
	got := mustGenerate(tt, `
		pub struct foo? (
			swizzler : base.pixel_swizzler,
			scratch  : array[2048] base.u8,
			pal      : array[1024] base.u8,
		)
		pub func foo.bar!(dst: ptr base.pixel_buffer, workbuf: slice base.u8) base.status {
			var s0 : slice base.u8
			var st : base.status
			if args.workbuf.length() >= 64 {
				s0 = args.workbuf[.. 64]
			}
			st = this.swizzler.swizzle_ycck!(
				dst: args.dst,
				dst_palette: args.dst.palette_or_else(fallback: this.pal[..]),
				dst_x_offset: 2, dst_y_offset: 5,
				x_min_incl: 0, x_max_excl: 8, y_min_incl: 0, y_max_excl: 8,
				src0: s0, src1: s0, src2: s0, src3: this.scratch[.. 0],
				width0: 8, width1: 8, width2: 8, width3: 0,
				height0: 8, height1: 8, height2: 8, height3: 0,
				stride0: 8, stride1: 8, stride2: 8, stride3: 0,
				h0: 1, h1: 1, h2: 1, h3: 0,
				v0: 1, v1: 1, v2: 1, v3: 0,
				ycc_model: 0, ycc_upsampling: 1,
				scratch_buffer_2k: this.scratch[..])
			return st
		}`)
	wantContains(tt, got,
		"Wuffs.Runtime.Swizzle_YCCK",
		"(PB => A_Dst,",
		"Pixels => A_Dst_Pixels,",
		"Palette => A_Dst_Palette,",
		"Dst_X_Offset => 2,",
		"Dst_Y_Offset => 5,",
		"Src0 => V_S0.Base (V_S0.First .. Wuffs.Runtime.Last (V_S0)),",
		"Width0 => 8,",
		"V3 => 0,",
		"YCC_Upsampling => 1,",
		"Result => G_T",
		// The scratch buffer, a part of the receiver, through a handle.
		"Scratch_Buffer_2K => G_T",
		// The entry checks of a pixel buffer argument.
		"Wuffs.Runtime.Valid_Pixel_Buffer",
		"Wuffs.Runtime.Share_An_Element (A => A_Dst_Pixels, B => A_Workbuf)")
	wantNotContains(tt, got, "Scratch_Buffer_2K => Self.", "Pixel_Buffers.Rows")
}

func TestRejectsJpegFeatures(tt *testing.T) {
	const prelude = `pub struct foo? (
			x    : base.u32,
			buf  : array[16] base.u8,
			rows : array[3] array[4] base.u16,
			deep : array[2] array[2] array[4] base.u16,
			tabs : array[3] array[8] base.u16,
			taba : array[3] array[8] base.u16,
			flat : array[8] base.u16,
		)
		`
	testCases := []struct{ what, src, want string }{{
		what: "bulk method without hi",
		src: `pub func foo.bar!() {
				this.buf[2 ..].bulk_memset!(byte_value: 0)
			}`,
		want: `a bulk method whose receiver is not "x[lo .. hi]" (with hi)`,
	}, {
		what: "bulk method on rows of rows",
		src: `pub func foo.bar!(w: slice base.u8) {
				this.deep[.. 1].bulk_load_host_endian!(src: args.w)
			}`,
		want: "a bulk method on a slice of",
	}, {
		what: "bulk method on a whole slice argument",
		src: `pub func foo.bar!(w: slice base.u8) {
				args.w.bulk_memset!(byte_value: 0)
			}`,
		want: `a bulk method whose receiver is not "x[lo .. hi]"`,
	}, {
		what: "pointer into two fields",
		src: `pub func foo.bar!(i: base.u32[..= 2]) {
				var p : nptr roarray[8] base.u16
				p = this.tabs[args.i][..] as ptr array[8] base.u16
				this.x = p[0] as base.u32
				p = this.taba[args.i][..] as ptr array[8] base.u16
				this.x ~mod+= p[1] as base.u32
			}`,
		want: "a pointer variable that points into two different fields",
	}, {
		what: "pointer to a whole array",
		src: `pub func foo.bar!() {
				var p : nptr roarray[8] base.u16
				p = this.flat[..] as ptr array[8] base.u16
				this.x = p[0] as base.u32
			}`,
		want: `a pointer to "this.flat[..] as ptr array[8] base.u16"`,
	}, {
		what: "pointer that is only null",
		src: `pub func foo.bar!() {
				var p : nptr roarray[8] base.u16
				p = nullptr
				if this.x > 0 {
					p = nullptr
				}
			}`,
		want: "a pointer variable that is only ever null",
	}, {
		what: "pointer compared outside of an assertion",
		src: `pub func foo.bar!(i: base.u32[..= 2]) {
				var p : nptr roarray[8] base.u16
				p = this.tabs[args.i][..] as ptr array[8] base.u16
				if p <> nullptr {
					this.x = 1
				}
			}`,
		want: "with nullptr outside of an assertion",
	}, {
		what: "pointer live across a suspension",
		src: `pub func foo.bar?(src: base.io_reader) {
				var p : nptr roarray[8] base.u16
				var c : base.u8
				p = this.tabs[2][..] as ptr array[8] base.u16
				this.x = p[0] as base.u32
				c = args.src.read_u8?()
				if p == nullptr {
					this.x = c as base.u32
				}
			}`,
		// (The Wuffs compiler forgets that a pointer is not null at a
		// suspension point, so only a null test can be live across one.)
		want: "a pointer that is live across a suspension point",
	}}
	for _, tc := range testCases {
		out, err := generate(Options{PackageName: "pkg", PackageID: 9}, []string{"test.wuffs"},
			[][]byte{[]byte(prelude + tc.src + "\n")})
		if err == nil {
			tt.Errorf("%s: got no error, want one containing %q. Output:\n%s", tc.what, tc.want, out.Body)
		} else if !strings.Contains(err.Error(), tc.want) {
			tt.Errorf("%s: got error %q, want one containing %q", tc.what, err, tc.want)
		}
	}
}

// The shell procedures that generated code calls with two or more
// arguments name them all (checkCalls), also in the bulk loops.
func TestCheckCallsBulk(tt *testing.T) {
	bad := []stmt{
		sCall{call("Wuffs.Runtime.Bulk_Load_Host_Endian_U16", raw("D"), raw("S"))},
		sIf{branches: []ifBranch{{call("Wuffs.Base.Slices.Bulk_Fits", raw("C"), raw("2"), raw("L")), nil}}},
		sCall{call("Wuffs.Runtime.Swizzle_YCCK", raw("PB"), raw("P"))},
	}
	for _, s := range bad {
		if err := checkCalls([]stmt{s}); err == nil {
			tt.Errorf("no error for a positional call: %#v", s)
		}
	}
}
