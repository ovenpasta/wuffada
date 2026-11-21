--  Part of wuffada (wuffs-ada: Wuffs to Ada).
--  SPDX-License-Identifier: Apache-2.0 OR MIT

--  Wuffs.Runtime.X86.SSE42: the methods of Wuffs `base.x86_sse42_utility`
--  and `base.x86_m128i`, one Ada subprogram per Wuffs method, named after it
--  (Wuffs `x._mm_add_epi8(b: y)` is Mm_Add_Epi8 (X => x, B => y)).
--
--  Each is what upstream's C back-end emits for the method (the table in
--  wuffs/internal/cgen/builtin.go, writeBuiltinCPUArchX86: a call of one
--  _mm_* intrinsic, with its argument casts), written with the GCC builtin
--  that GCC's own header (emmintrin.h, pmmintrin.h, tmmintrin.h, smmintrin.h,
--  wmmintrin.h) uses for that intrinsic.  Where the header uses a GCC vector
--  operator instead of a builtin (_mm_add_epi8 is "(__v16qu)a + (__v16qu)b")
--  the binding is the builtin with the same semantics (paddb128).  Where it
--  builds a vector from scalars (_mm_set_epi32, _mm_setzero_si128,
--  _mm_cvtsi32_si128), the Ada builds the same lanes with an aggregate.
--  The whole table, with the intrinsic and builtin of each method, is
--  ada/src/simd/METHODS.md.
--
--  Every subprogram here is inlined (Inline_Always) into its caller, which
--  must be compiled with the options of upstream's target attribute for
--  "cpu_arch >= x86_sse42": -msse4.2 -mpclmul -mpopcnt (see
--  ada/wuffs_gen.gpr).  This unit is compiled with them too.  An Imm8 or
--  Index argument must be a static value within the range that the C
--  intrinsic accepts: the generator checks that, and GCC rejects anything
--  else ("the last argument must be an 8-bit immediate").
--
--  Loads and stores take an array and are the only subprograms that use an
--  address.  Their precondition is the length that the Wuffs checker
--  proved (the method's "advance": 16 bytes, or 8 u16 values); in the
--  checked profile it is checked at every call, in the release profile
--  nothing is (as for every other check).

with System;

package Wuffs.Runtime.X86.SSE42 with Preelaborate, SPARK_Mode => Off is

   ---------------------------------------------------------------------------
   --  base.x86_sse42_utility
   ---------------------------------------------------------------------------

   --  _mm_set_epi8 (a15, ..., a00): lane i is ai.
   function Make_M128i_Multiple_U8
     (A00, A01, A02, A03, A04, A05, A06, A07,
      A08, A09, A10, A11, A12, A13, A14, A15 : Unsigned_8)
      return M128I
   with Inline_Always;

   --  _mm_set_epi32 (a03, a02, a01, a00): lane i is ai.
   function Make_M128i_Multiple_U32 (A00, A01, A02, A03 : Unsigned_32) return M128I
   with Inline_Always;

   --  _mm_set1_epi8 (a).
   function Make_M128i_Repeat_U8 (A : Unsigned_8) return M128I with Inline_Always;

   --  _mm_set1_epi16 (a).
   function Make_M128i_Repeat_U16 (A : Unsigned_16) return M128I with Inline_Always;

   --  _mm_cvtsi32_si128 (a): lane 0 of four 32-bit lanes is a, the rest 0.
   function Make_M128i_Single_U32 (A : Unsigned_32) return M128I with Inline_Always;

   --  _mm_cvtsi64_si128 (a): lane 0 of two 64-bit lanes is a, lane 1 is 0.
   function Make_M128i_Single_U64 (A : Unsigned_64) return M128I with Inline_Always;

   --  _mm_lddqu_si128 (a.ptr): the 16 bytes at A's first element.
   function Make_M128i_Slice128 (A : Wuffs.Bytes) return M128I
   with Inline_Always, Pre => A'Length >= 16;

   --  _mm_lddqu_si128 (a.ptr): the 8 u16 values at A's first element.
   function Make_M128i_Slice_U16lex8 (A : Wuffs.U16_Array) return M128I
   with Inline_Always, Pre => A'Length >= 8;

   --  _mm_setzero_si128 ().
   function Make_M128i_Zeroes return M128I with Inline_Always;

   --  wuffs_base__peek_u64le__no_bounds_check (a.ptr): the 4 u16 values at
   --  A's first element, A (A'First) in the lowest 16 bits.
   function Make_U64_Slice_U16lex4 (A : Wuffs.U16_Array) return Unsigned_64
   with Inline_Always, Pre => A'Length >= 4;

   ---------------------------------------------------------------------------
   --  base.x86_m128i
   ---------------------------------------------------------------------------

   --  _mm_storeu_si128 (a.ptr, x): X's 16 bytes to A's first 16 elements.
   procedure Store_Slice128 (X : M128I; A : in out Wuffs.Bytes)
   with Inline_Always, Pre => A'Length >= 16;

   --  (uint32_t) _mm_cvtsi128_si32 (x).
   function Truncate_U32 (X : M128I) return Unsigned_32 with Inline_Always;

   --  (uint64_t) _mm_cvtsi128_si64 (x).
   function Truncate_U64 (X : M128I) return Unsigned_64 with Inline_Always;

   function Mm_Abs_Epi16 (X : M128I) return M128I with Inline_Always;
   function Mm_Add_Epi8 (X, B : M128I) return M128I with Inline_Always;
   function Mm_Add_Epi16 (X, B : M128I) return M128I with Inline_Always;
   function Mm_Add_Epi32 (X, B : M128I) return M128I with Inline_Always;
   function Mm_And_Si128 (X, B : M128I) return M128I with Inline_Always;
   function Mm_Avg_Epu8 (X, B : M128I) return M128I with Inline_Always;
   function Mm_Blendv_Epi8 (X, B, Mask : M128I) return M128I with Inline_Always;
   function Mm_Clmulepi64_Si128 (X, B : M128I; Imm8 : Integer) return M128I with Inline_Always;
   function Mm_Cmpeq_Epi16 (X, B : M128I) return M128I with Inline_Always;
   function Mm_Extract_Epi32 (X : M128I; Imm8 : Integer) return Unsigned_32 with Inline_Always;
   function Mm_Extract_Epi64 (X : M128I; Imm8 : Integer) return Unsigned_64 with Inline_Always;
   function Mm_Madd_Epi16 (X, B : M128I) return M128I with Inline_Always;
   function Mm_Maddubs_Epi16 (X, B : M128I) return M128I with Inline_Always;
   function Mm_Min_Epi16 (X, B : M128I) return M128I with Inline_Always;
   function Mm_Or_Si128 (X, B : M128I) return M128I with Inline_Always;
   function Mm_Packs_Epi16 (X, B : M128I) return M128I with Inline_Always;
   function Mm_Packus_Epi16 (X, B : M128I) return M128I with Inline_Always;
   function Mm_Sad_Epu8 (X, B : M128I) return M128I with Inline_Always;
   function Mm_Shuffle_Epi32 (X : M128I; Imm8 : Integer) return M128I with Inline_Always;
   function Mm_Slli_Epi32 (X : M128I; Imm8 : Integer) return M128I with Inline_Always;
   function Mm_Slli_Si128 (X : M128I; Imm8 : Integer) return M128I with Inline_Always;
   function Mm_Sub_Epi8 (X, B : M128I) return M128I with Inline_Always;
   function Mm_Sub_Epi16 (X, B : M128I) return M128I with Inline_Always;
   function Mm_Unpacklo_Epi8 (X, B : M128I) return M128I with Inline_Always;
   function Mm_Xor_Si128 (X, B : M128I) return M128I with Inline_Always;

private

   ---------------------------------------------------------------------------
   --  The GCC builtins (gcc/config/i386/i386-builtin.def), with the vector
   --  types of their prototypes.
   ---------------------------------------------------------------------------

   function B_Lddqu (P : System.Address) return V16QI
   with Import, Convention => Intrinsic, External_Name => "__builtin_ia32_lddqu";
   procedure B_Storedqu (P : System.Address; V : V16QI)
   with Import, Convention => Intrinsic, External_Name => "__builtin_ia32_storedqu";
   function B_Vec_Ext_V4SI (A : V4SI; N : Integer) return Integer_32
   with Import, Convention => Intrinsic, External_Name => "__builtin_ia32_vec_ext_v4si";
   function B_Vec_Ext_V2DI (A : M128I; N : Integer) return Integer_64
   with Import, Convention => Intrinsic, External_Name => "__builtin_ia32_vec_ext_v2di";

   function B_Pabsw128 (A : V8HI) return V8HI
   with Import, Convention => Intrinsic, External_Name => "__builtin_ia32_pabsw128";
   function B_Paddb128 (A, B : V16QI) return V16QI
   with Import, Convention => Intrinsic, External_Name => "__builtin_ia32_paddb128";
   function B_Paddw128 (A, B : V8HI) return V8HI
   with Import, Convention => Intrinsic, External_Name => "__builtin_ia32_paddw128";
   function B_Paddd128 (A, B : V4SI) return V4SI
   with Import, Convention => Intrinsic, External_Name => "__builtin_ia32_paddd128";
   function B_Pand128 (A, B : M128I) return M128I
   with Import, Convention => Intrinsic, External_Name => "__builtin_ia32_pand128";
   function B_Pavgb128 (A, B : V16QI) return V16QI
   with Import, Convention => Intrinsic, External_Name => "__builtin_ia32_pavgb128";
   function B_Pblendvb128 (A, B, M : V16QI) return V16QI
   with Import, Convention => Intrinsic, External_Name => "__builtin_ia32_pblendvb128";
   function B_Pclmulqdq128 (A, B : M128I; I : Integer) return M128I
   with Import, Convention => Intrinsic, External_Name => "__builtin_ia32_pclmulqdq128";
   function B_Pcmpeqw128 (A, B : V8HI) return V8HI
   with Import, Convention => Intrinsic, External_Name => "__builtin_ia32_pcmpeqw128";
   function B_Pmaddwd128 (A, B : V8HI) return V4SI
   with Import, Convention => Intrinsic, External_Name => "__builtin_ia32_pmaddwd128";
   function B_Pmaddubsw128 (A, B : V16QI) return V8HI
   with Import, Convention => Intrinsic, External_Name => "__builtin_ia32_pmaddubsw128";
   function B_Pminsw128 (A, B : V8HI) return V8HI
   with Import, Convention => Intrinsic, External_Name => "__builtin_ia32_pminsw128";
   function B_Por128 (A, B : M128I) return M128I
   with Import, Convention => Intrinsic, External_Name => "__builtin_ia32_por128";
   function B_Packsswb128 (A, B : V8HI) return V16QI
   with Import, Convention => Intrinsic, External_Name => "__builtin_ia32_packsswb128";
   function B_Packuswb128 (A, B : V8HI) return V16QI
   with Import, Convention => Intrinsic, External_Name => "__builtin_ia32_packuswb128";
   function B_Psadbw128 (A, B : V16QI) return M128I
   with Import, Convention => Intrinsic, External_Name => "__builtin_ia32_psadbw128";
   function B_Pshufd (A : V4SI; N : Integer) return V4SI
   with Import, Convention => Intrinsic, External_Name => "__builtin_ia32_pshufd";
   function B_Pslldi128 (A : V4SI; N : Integer) return V4SI
   with Import, Convention => Intrinsic, External_Name => "__builtin_ia32_pslldi128";
   function B_Pslldqi128 (A : M128I; N : Integer) return M128I
   with Import, Convention => Intrinsic, External_Name => "__builtin_ia32_pslldqi128";
   function B_Psubb128 (A, B : V16QI) return V16QI
   with Import, Convention => Intrinsic, External_Name => "__builtin_ia32_psubb128";
   function B_Psubw128 (A, B : V8HI) return V8HI
   with Import, Convention => Intrinsic, External_Name => "__builtin_ia32_psubw128";
   function B_Punpcklbw128 (A, B : V16QI) return V16QI
   with Import, Convention => Intrinsic, External_Name => "__builtin_ia32_punpcklbw128";
   function B_Pxor128 (A, B : M128I) return M128I
   with Import, Convention => Intrinsic, External_Name => "__builtin_ia32_pxor128";

   ---------------------------------------------------------------------------
   --  Completions.
   ---------------------------------------------------------------------------

   function Make_M128i_Multiple_U8
     (A00, A01, A02, A03, A04, A05, A06, A07,
      A08, A09, A10, A11, A12, A13, A14, A15 : Unsigned_8)
      return M128I
   is (From_U8x16
         ([A00, A01, A02, A03, A04, A05, A06, A07, A08, A09, A10, A11, A12, A13, A14, A15]));

   function Make_M128i_Multiple_U32 (A00, A01, A02, A03 : Unsigned_32) return M128I
   is (From_U32x4 ([A00, A01, A02, A03]));

   --  Not "From_U8x16 ([others => A])": GNAT 16.1 compiles that aggregate of
   --  a vector type with 8-bit lanes to zeroes (also at -O0).  The lanes are
   --  replicated in a 64-bit integer instead.
   function Make_M128i_Repeat_U8 (A : Unsigned_8) return M128I
   is (From_U64x2
         ([16#0101_0101_0101_0101# * Unsigned_64 (A), 16#0101_0101_0101_0101# * Unsigned_64 (A)]));

   function Make_M128i_Repeat_U16 (A : Unsigned_16) return M128I
   is (From_U64x2
         ([16#0001_0001_0001_0001# * Unsigned_64 (A), 16#0001_0001_0001_0001# * Unsigned_64 (A)]));

   function Make_M128i_Single_U32 (A : Unsigned_32) return M128I is (From_U32x4 ([A, 0, 0, 0]));

   function Make_M128i_Single_U64 (A : Unsigned_64) return M128I is (From_U64x2 ([A, 0]));

   function Make_M128i_Slice128 (A : Wuffs.Bytes) return M128I
   is (From_V16QI (B_Lddqu (A (A'First)'Address)));

   function Make_M128i_Slice_U16lex8 (A : Wuffs.U16_Array) return M128I
   is (From_V16QI (B_Lddqu (A (A'First)'Address)));

   function Make_M128i_Zeroes return M128I is (Zero_M128I);

   function Make_U64_Slice_U16lex4 (A : Wuffs.U16_Array) return Unsigned_64
   is (Unsigned_64 (A (A'First))
       or Shift_Left (Unsigned_64 (A (A'First + 1)), 16)
       or Shift_Left (Unsigned_64 (A (A'First + 2)), 32)
       or Shift_Left (Unsigned_64 (A (A'First + 3)), 48));

   function Truncate_U32 (X : M128I) return Unsigned_32
   is (To_U32 (B_Vec_Ext_V4SI (To_V4SI (X), 0)));

   function Truncate_U64 (X : M128I) return Unsigned_64 is (To_U64 (X (0)));

   function Mm_Abs_Epi16 (X : M128I) return M128I is (From_V8HI (B_Pabsw128 (To_V8HI (X))));

   function Mm_Add_Epi8 (X, B : M128I) return M128I
   is (From_V16QI (B_Paddb128 (To_V16QI (X), To_V16QI (B))));

   function Mm_Add_Epi16 (X, B : M128I) return M128I
   is (From_V8HI (B_Paddw128 (To_V8HI (X), To_V8HI (B))));

   function Mm_Add_Epi32 (X, B : M128I) return M128I
   is (From_V4SI (B_Paddd128 (To_V4SI (X), To_V4SI (B))));

   function Mm_And_Si128 (X, B : M128I) return M128I is (B_Pand128 (X, B));

   function Mm_Avg_Epu8 (X, B : M128I) return M128I
   is (From_V16QI (B_Pavgb128 (To_V16QI (X), To_V16QI (B))));

   function Mm_Blendv_Epi8 (X, B, Mask : M128I) return M128I
   is (From_V16QI (B_Pblendvb128 (To_V16QI (X), To_V16QI (B), To_V16QI (Mask))));

   function Mm_Clmulepi64_Si128 (X, B : M128I; Imm8 : Integer) return M128I
   is (B_Pclmulqdq128 (X, B, Imm8));

   function Mm_Cmpeq_Epi16 (X, B : M128I) return M128I
   is (From_V8HI (B_Pcmpeqw128 (To_V8HI (X), To_V8HI (B))));

   function Mm_Extract_Epi32 (X : M128I; Imm8 : Integer) return Unsigned_32
   is (To_U32 (B_Vec_Ext_V4SI (To_V4SI (X), Imm8)));

   function Mm_Extract_Epi64 (X : M128I; Imm8 : Integer) return Unsigned_64
   is (To_U64 (B_Vec_Ext_V2DI (X, Imm8)));

   function Mm_Madd_Epi16 (X, B : M128I) return M128I
   is (From_V4SI (B_Pmaddwd128 (To_V8HI (X), To_V8HI (B))));

   function Mm_Maddubs_Epi16 (X, B : M128I) return M128I
   is (From_V8HI (B_Pmaddubsw128 (To_V16QI (X), To_V16QI (B))));

   function Mm_Min_Epi16 (X, B : M128I) return M128I
   is (From_V8HI (B_Pminsw128 (To_V8HI (X), To_V8HI (B))));

   function Mm_Or_Si128 (X, B : M128I) return M128I is (B_Por128 (X, B));

   function Mm_Packs_Epi16 (X, B : M128I) return M128I
   is (From_V16QI (B_Packsswb128 (To_V8HI (X), To_V8HI (B))));

   function Mm_Packus_Epi16 (X, B : M128I) return M128I
   is (From_V16QI (B_Packuswb128 (To_V8HI (X), To_V8HI (B))));

   function Mm_Sad_Epu8 (X, B : M128I) return M128I is (B_Psadbw128 (To_V16QI (X), To_V16QI (B)));

   function Mm_Shuffle_Epi32 (X : M128I; Imm8 : Integer) return M128I
   is (From_V4SI (B_Pshufd (To_V4SI (X), Imm8)));

   function Mm_Slli_Epi32 (X : M128I; Imm8 : Integer) return M128I
   is (From_V4SI (B_Pslldi128 (To_V4SI (X), Imm8)));

   --  emmintrin.h: __builtin_ia32_pslldqi128 (a, n * 8), a count in bits.
   function Mm_Slli_Si128 (X : M128I; Imm8 : Integer) return M128I is (B_Pslldqi128 (X, Imm8 * 8));

   function Mm_Sub_Epi8 (X, B : M128I) return M128I
   is (From_V16QI (B_Psubb128 (To_V16QI (X), To_V16QI (B))));

   function Mm_Sub_Epi16 (X, B : M128I) return M128I
   is (From_V8HI (B_Psubw128 (To_V8HI (X), To_V8HI (B))));

   function Mm_Unpacklo_Epi8 (X, B : M128I) return M128I
   is (From_V16QI (B_Punpcklbw128 (To_V16QI (X), To_V16QI (B))));

   function Mm_Xor_Si128 (X, B : M128I) return M128I is (B_Pxor128 (X, B));

end Wuffs.Runtime.X86.SSE42;
