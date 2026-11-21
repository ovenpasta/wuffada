--  Part of wuffada (wuffs-ada: Wuffs to Ada).
--  SPDX-License-Identifier: Apache-2.0 OR MIT

--  Wuffs.Runtime.X86.AVX2: the methods of Wuffs `base.x86_avx2_utility` and
--  `base.x86_m256i`, one Ada subprogram per Wuffs method, named after it.
--  Everything said in wuffs-runtime-x86-sse42.ads applies, with GCC's
--  avxintrin.h and avx2intrin.h as the headers, and the options of
--  upstream's target attribute for "cpu_arch >= x86_avx2": -msse4.2 -mpclmul
--  -mpopcnt -mavx2.  The whole table is ada/src/simd/METHODS.md.

with System;

package Wuffs.Runtime.X86.AVX2 with Preelaborate, SPARK_Mode => Off is

   ---------------------------------------------------------------------------
   --  base.x86_avx2_utility
   ---------------------------------------------------------------------------

   --  _mm256_set_epi16 (a15, ..., a00): lane i is ai.
   function Make_M256i_Multiple_U16
     (A00, A01, A02, A03, A04, A05, A06, A07,
      A08, A09, A10, A11, A12, A13, A14, A15 : Unsigned_16)
      return M256I
   with Inline_Always;

   --  _mm256_lddqu_si256 (a.ptr): the 16 u16 values at A's first element.
   function Make_M256i_Slice_U16lex16 (A : Wuffs.U16_Array) return M256I
   with Inline_Always, Pre => A'Length >= 16;

   --  wuffs_base__peek_u64le__no_bounds_check (a.ptr), as SSE42's.
   function Make_U64_Slice_U16lex4 (A : Wuffs.U16_Array) return Unsigned_64
   with Inline_Always, Pre => A'Length >= 4;

   ---------------------------------------------------------------------------
   --  base.x86_m256i
   ---------------------------------------------------------------------------

   function Mm256_Add_Epi8 (X, B : M256I) return M256I with Inline_Always;
   function Mm256_Add_Epi16 (X, B : M256I) return M256I with Inline_Always;
   function Mm256_Add_Epi32 (X, B : M256I) return M256I with Inline_Always;
   function Mm256_Castsi256_Si128 (X : M256I) return M128I with Inline_Always;
   function Mm256_Extract_Epi64 (X : M256I; Index : Integer) return Unsigned_64
   with Inline_Always;
   function Mm256_Inserti128_Si256 (X : M256I; B : M128I; Imm8 : Integer) return M256I
   with Inline_Always;
   function Mm256_Madd_Epi16 (X, B : M256I) return M256I with Inline_Always;
   function Mm256_Mullo_Epi16 (X, B : M256I) return M256I with Inline_Always;
   function Mm256_Packs_Epi16 (X, B : M256I) return M256I with Inline_Always;
   function Mm256_Packs_Epi32 (X, B : M256I) return M256I with Inline_Always;
   function Mm256_Permute2x128_Si256 (X, B : M256I; Imm8 : Integer) return M256I
   with Inline_Always;
   function Mm256_Permute4x64_Epi64 (X : M256I; Imm8 : Integer) return M256I with Inline_Always;
   function Mm256_Shuffle_Epi32 (X : M256I; Imm8 : Integer) return M256I with Inline_Always;
   function Mm256_Sign_Epi16 (X, B : M256I) return M256I with Inline_Always;
   function Mm256_Slli_Epi16 (X : M256I; Imm8 : Integer) return M256I with Inline_Always;
   function Mm256_Srai_Epi32 (X : M256I; Imm8 : Integer) return M256I with Inline_Always;
   function Mm256_Sub_Epi32 (X, B : M256I) return M256I with Inline_Always;
   function Mm256_Unpackhi_Epi16 (X, B : M256I) return M256I with Inline_Always;
   function Mm256_Unpackhi_Epi64 (X, B : M256I) return M256I with Inline_Always;
   function Mm256_Unpacklo_Epi16 (X, B : M256I) return M256I with Inline_Always;
   function Mm256_Unpacklo_Epi64 (X, B : M256I) return M256I with Inline_Always;

private

   function B_Lddqu256 (P : System.Address) return V32QI
   with Import, Convention => Intrinsic, External_Name => "__builtin_ia32_lddqu256";
   function B_Vec_Ext_V2DI (A : M128I; N : Integer) return Integer_64
   with Import, Convention => Intrinsic, External_Name => "__builtin_ia32_vec_ext_v2di";
   function B_Vextractf128_Si256 (A : V8SI; N : Integer) return V4SI
   with Import, Convention => Intrinsic, External_Name => "__builtin_ia32_vextractf128_si256";
   function B_Si_Si256 (A : V8SI) return V4SI
   with Import, Convention => Intrinsic, External_Name => "__builtin_ia32_si_si256";
   function B_Insert128i256 (A : M256I; B : M128I; N : Integer) return M256I
   with Import, Convention => Intrinsic, External_Name => "__builtin_ia32_insert128i256";

   function B_Paddb256 (A, B : V32QI) return V32QI
   with Import, Convention => Intrinsic, External_Name => "__builtin_ia32_paddb256";
   function B_Paddw256 (A, B : V16HI) return V16HI
   with Import, Convention => Intrinsic, External_Name => "__builtin_ia32_paddw256";
   function B_Paddd256 (A, B : V8SI) return V8SI
   with Import, Convention => Intrinsic, External_Name => "__builtin_ia32_paddd256";
   function B_Pmaddwd256 (A, B : V16HI) return V8SI
   with Import, Convention => Intrinsic, External_Name => "__builtin_ia32_pmaddwd256";
   function B_Pmullw256 (A, B : V16HI) return V16HI
   with Import, Convention => Intrinsic, External_Name => "__builtin_ia32_pmullw256";
   function B_Packsswb256 (A, B : V16HI) return V32QI
   with Import, Convention => Intrinsic, External_Name => "__builtin_ia32_packsswb256";
   function B_Packssdw256 (A, B : V8SI) return V16HI
   with Import, Convention => Intrinsic, External_Name => "__builtin_ia32_packssdw256";
   function B_Permti256 (A, B : M256I; N : Integer) return M256I
   with Import, Convention => Intrinsic, External_Name => "__builtin_ia32_permti256";
   function B_Permdi256 (A : M256I; N : Integer) return M256I
   with Import, Convention => Intrinsic, External_Name => "__builtin_ia32_permdi256";
   function B_Pshufd256 (A : V8SI; N : Integer) return V8SI
   with Import, Convention => Intrinsic, External_Name => "__builtin_ia32_pshufd256";
   function B_Psignw256 (A, B : V16HI) return V16HI
   with Import, Convention => Intrinsic, External_Name => "__builtin_ia32_psignw256";
   function B_Psllwi256 (A : V16HI; N : Integer) return V16HI
   with Import, Convention => Intrinsic, External_Name => "__builtin_ia32_psllwi256";
   function B_Psradi256 (A : V8SI; N : Integer) return V8SI
   with Import, Convention => Intrinsic, External_Name => "__builtin_ia32_psradi256";
   function B_Psubd256 (A, B : V8SI) return V8SI
   with Import, Convention => Intrinsic, External_Name => "__builtin_ia32_psubd256";
   function B_Punpckhwd256 (A, B : V16HI) return V16HI
   with Import, Convention => Intrinsic, External_Name => "__builtin_ia32_punpckhwd256";
   function B_Punpckhqdq256 (A, B : M256I) return M256I
   with Import, Convention => Intrinsic, External_Name => "__builtin_ia32_punpckhqdq256";
   function B_Punpcklwd256 (A, B : V16HI) return V16HI
   with Import, Convention => Intrinsic, External_Name => "__builtin_ia32_punpcklwd256";
   function B_Punpcklqdq256 (A, B : M256I) return M256I
   with Import, Convention => Intrinsic, External_Name => "__builtin_ia32_punpcklqdq256";

   function Make_M256i_Multiple_U16
     (A00, A01, A02, A03, A04, A05, A06, A07,
      A08, A09, A10, A11, A12, A13, A14, A15 : Unsigned_16)
      return M256I
   is (From_U16x16
         ([A00, A01, A02, A03, A04, A05, A06, A07, A08, A09, A10, A11, A12, A13, A14, A15]));

   function Make_M256i_Slice_U16lex16 (A : Wuffs.U16_Array) return M256I
   is (From_V32QI (B_Lddqu256 (A (A'First)'Address)));

   function Make_U64_Slice_U16lex4 (A : Wuffs.U16_Array) return Unsigned_64
   is (Unsigned_64 (A (A'First))
       or Shift_Left (Unsigned_64 (A (A'First + 1)), 16)
       or Shift_Left (Unsigned_64 (A (A'First + 2)), 32)
       or Shift_Left (Unsigned_64 (A (A'First + 3)), 48));

   function Mm256_Add_Epi8 (X, B : M256I) return M256I
   is (From_V32QI (B_Paddb256 (To_V32QI (X), To_V32QI (B))));

   function Mm256_Add_Epi16 (X, B : M256I) return M256I
   is (From_V16HI (B_Paddw256 (To_V16HI (X), To_V16HI (B))));

   function Mm256_Add_Epi32 (X, B : M256I) return M256I
   is (From_V8SI (B_Paddd256 (To_V8SI (X), To_V8SI (B))));

   function Mm256_Castsi256_Si128 (X : M256I) return M128I
   is (From_V4SI (B_Si_Si256 (To_V8SI (X))));

   --  avxintrin.h: _mm_extract_epi64 (_mm256_extractf128_si256 (x, n >> 1),
   --  n % 2).
   function Mm256_Extract_Epi64 (X : M256I; Index : Integer) return Unsigned_64
   is (To_U64
         (B_Vec_Ext_V2DI
            (From_V4SI (B_Vextractf128_Si256 (To_V8SI (X), Index / 2)), Index mod 2)));

   function Mm256_Inserti128_Si256 (X : M256I; B : M128I; Imm8 : Integer) return M256I
   is (B_Insert128i256 (X, B, Imm8));

   function Mm256_Madd_Epi16 (X, B : M256I) return M256I
   is (From_V8SI (B_Pmaddwd256 (To_V16HI (X), To_V16HI (B))));

   function Mm256_Mullo_Epi16 (X, B : M256I) return M256I
   is (From_V16HI (B_Pmullw256 (To_V16HI (X), To_V16HI (B))));

   function Mm256_Packs_Epi16 (X, B : M256I) return M256I
   is (From_V32QI (B_Packsswb256 (To_V16HI (X), To_V16HI (B))));

   function Mm256_Packs_Epi32 (X, B : M256I) return M256I
   is (From_V16HI (B_Packssdw256 (To_V8SI (X), To_V8SI (B))));

   function Mm256_Permute2x128_Si256 (X, B : M256I; Imm8 : Integer) return M256I
   is (B_Permti256 (X, B, Imm8));

   function Mm256_Permute4x64_Epi64 (X : M256I; Imm8 : Integer) return M256I
   is (B_Permdi256 (X, Imm8));

   function Mm256_Shuffle_Epi32 (X : M256I; Imm8 : Integer) return M256I
   is (From_V8SI (B_Pshufd256 (To_V8SI (X), Imm8)));

   function Mm256_Sign_Epi16 (X, B : M256I) return M256I
   is (From_V16HI (B_Psignw256 (To_V16HI (X), To_V16HI (B))));

   function Mm256_Slli_Epi16 (X : M256I; Imm8 : Integer) return M256I
   is (From_V16HI (B_Psllwi256 (To_V16HI (X), Imm8)));

   function Mm256_Srai_Epi32 (X : M256I; Imm8 : Integer) return M256I
   is (From_V8SI (B_Psradi256 (To_V8SI (X), Imm8)));

   function Mm256_Sub_Epi32 (X, B : M256I) return M256I
   is (From_V8SI (B_Psubd256 (To_V8SI (X), To_V8SI (B))));

   function Mm256_Unpackhi_Epi16 (X, B : M256I) return M256I
   is (From_V16HI (B_Punpckhwd256 (To_V16HI (X), To_V16HI (B))));

   function Mm256_Unpackhi_Epi64 (X, B : M256I) return M256I is (B_Punpckhqdq256 (X, B));

   function Mm256_Unpacklo_Epi16 (X, B : M256I) return M256I
   is (From_V16HI (B_Punpcklwd256 (To_V16HI (X), To_V16HI (B))));

   function Mm256_Unpacklo_Epi64 (X, B : M256I) return M256I is (B_Punpcklqdq256 (X, B));

end Wuffs.Runtime.X86.AVX2;
