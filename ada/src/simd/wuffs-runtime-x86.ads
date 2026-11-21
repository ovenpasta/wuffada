--  Part of wuffada (wuffs-ada: Wuffs to Ada).
--  SPDX-License-Identifier: Apache-2.0 OR MIT

--  Wuffs.Runtime.X86: the x86 vector types of generated SIMD code.  Not
--  SPARK, and only in a SIMD build (ada/wuffs_gen.gpr, WUFFS_SIMD=on).
--
--  Wuffs `base.x86_m128i` is M128I and `base.x86_m256i` is M256I.  Each is
--  an Ada array type that GCC treats as a vector register type (Machine_
--  Attribute "vector_type"), exactly like C's __m128i and __m256i: a vector
--  of 64-bit integers.  The intrinsics that act on them are GCC builtins
--  (__builtin_ia32_*), bound in the child packages SSE42 and AVX2, which
--  also hold one Ada subprogram per Wuffs cpu_arch method; see the table in
--  ada/src/simd/METHODS.md.
--
--  A builtin's prototype fixes the element type of each vector argument
--  (signed char, short, int or long long lanes: v16qi, v8hi, v4si, v2di),
--  and GNAT insists on an exact match.  So each width has one vector type
--  per lane width (the "views" below), and a value is reinterpreted between
--  views of the same 16 or 32 bytes by Ada.Unchecked_Conversion, which
--  compiles to nothing (the value stays in its register).  The unsigned
--  views are for building vectors from Wuffs' unsigned lanes; no builtin
--  takes them.
--
--  Lane i is at byte offset i * (lane width) of the 16 or 32 bytes, as in a
--  GCC vector on a little-endian machine: lane 0 is the "lowest" one, the
--  one that _mm_cvtsi128_si32 returns.
--
--  This package holds no instruction beyond the x86-64 baseline (SSE2) and
--  is compiled with the default switches.

with Ada.Unchecked_Conversion;
with Interfaces;

package Wuffs.Runtime.X86 with Preelaborate, SPARK_Mode => Off is

   use Interfaces;

   ---------------------------------------------------------------------------
   --  The two Wuffs types.  M128I is also the v2di view and M256I the v4di
   --  view (as in GCC, where __m128i is a vector of two long long).
   ---------------------------------------------------------------------------

   type M128I is array (0 .. 1) of Integer_64 with Alignment => 16;
   pragma Machine_Attribute (M128I, "vector_type");
   pragma Machine_Attribute (M128I, "may_alias");

   type M256I is array (0 .. 3) of Integer_64 with Alignment => 32;
   pragma Machine_Attribute (M256I, "vector_type");
   pragma Machine_Attribute (M256I, "may_alias");

   --  Wuffs' zero value of each type (a Wuffs variable starts at zero).
   Zero_M128I : constant M128I := [others => 0];
   Zero_M256I : constant M256I := [others => 0];

   ---------------------------------------------------------------------------
   --  Signed views, for the builtins' prototypes.
   ---------------------------------------------------------------------------

   type V16QI is array (0 .. 15) of Integer_8 with Alignment => 16;
   pragma Machine_Attribute (V16QI, "vector_type");
   pragma Machine_Attribute (V16QI, "may_alias");

   type V8HI is array (0 .. 7) of Integer_16 with Alignment => 16;
   pragma Machine_Attribute (V8HI, "vector_type");
   pragma Machine_Attribute (V8HI, "may_alias");

   type V4SI is array (0 .. 3) of Integer_32 with Alignment => 16;
   pragma Machine_Attribute (V4SI, "vector_type");
   pragma Machine_Attribute (V4SI, "may_alias");

   type V32QI is array (0 .. 31) of Integer_8 with Alignment => 32;
   pragma Machine_Attribute (V32QI, "vector_type");
   pragma Machine_Attribute (V32QI, "may_alias");

   type V16HI is array (0 .. 15) of Integer_16 with Alignment => 32;
   pragma Machine_Attribute (V16HI, "vector_type");
   pragma Machine_Attribute (V16HI, "may_alias");

   type V8SI is array (0 .. 7) of Integer_32 with Alignment => 32;
   pragma Machine_Attribute (V8SI, "vector_type");
   pragma Machine_Attribute (V8SI, "may_alias");

   ---------------------------------------------------------------------------
   --  Unsigned views.
   ---------------------------------------------------------------------------

   type U8x16 is array (0 .. 15) of Unsigned_8 with Alignment => 16;
   pragma Machine_Attribute (U8x16, "vector_type");
   pragma Machine_Attribute (U8x16, "may_alias");

   type U16x8 is array (0 .. 7) of Unsigned_16 with Alignment => 16;
   pragma Machine_Attribute (U16x8, "vector_type");
   pragma Machine_Attribute (U16x8, "may_alias");

   type U32x4 is array (0 .. 3) of Unsigned_32 with Alignment => 16;
   pragma Machine_Attribute (U32x4, "vector_type");
   pragma Machine_Attribute (U32x4, "may_alias");

   type U64x2 is array (0 .. 1) of Unsigned_64 with Alignment => 16;
   pragma Machine_Attribute (U64x2, "vector_type");
   pragma Machine_Attribute (U64x2, "may_alias");

   type U8x32 is array (0 .. 31) of Unsigned_8 with Alignment => 32;
   pragma Machine_Attribute (U8x32, "vector_type");
   pragma Machine_Attribute (U8x32, "may_alias");

   type U16x16 is array (0 .. 15) of Unsigned_16 with Alignment => 32;
   pragma Machine_Attribute (U16x16, "vector_type");
   pragma Machine_Attribute (U16x16, "may_alias");

   type U32x8 is array (0 .. 7) of Unsigned_32 with Alignment => 32;
   pragma Machine_Attribute (U32x8, "vector_type");
   pragma Machine_Attribute (U32x8, "may_alias");

   type U64x4 is array (0 .. 3) of Unsigned_64 with Alignment => 32;
   pragma Machine_Attribute (U64x4, "vector_type");
   pragma Machine_Attribute (U64x4, "may_alias");

   ---------------------------------------------------------------------------
   --  Reinterpretations: same bytes, another view.
   ---------------------------------------------------------------------------

   function To_V16QI is new Ada.Unchecked_Conversion (M128I, V16QI);
   function To_V8HI is new Ada.Unchecked_Conversion (M128I, V8HI);
   function To_V4SI is new Ada.Unchecked_Conversion (M128I, V4SI);
   function From_V16QI is new Ada.Unchecked_Conversion (V16QI, M128I);
   function From_V8HI is new Ada.Unchecked_Conversion (V8HI, M128I);
   function From_V4SI is new Ada.Unchecked_Conversion (V4SI, M128I);

   function To_U8x16 is new Ada.Unchecked_Conversion (M128I, U8x16);
   function To_U16x8 is new Ada.Unchecked_Conversion (M128I, U16x8);
   function To_U32x4 is new Ada.Unchecked_Conversion (M128I, U32x4);
   function To_U64x2 is new Ada.Unchecked_Conversion (M128I, U64x2);
   function From_U8x16 is new Ada.Unchecked_Conversion (U8x16, M128I);
   function From_U16x8 is new Ada.Unchecked_Conversion (U16x8, M128I);
   function From_U32x4 is new Ada.Unchecked_Conversion (U32x4, M128I);
   function From_U64x2 is new Ada.Unchecked_Conversion (U64x2, M128I);

   function To_V32QI is new Ada.Unchecked_Conversion (M256I, V32QI);
   function To_V16HI is new Ada.Unchecked_Conversion (M256I, V16HI);
   function To_V8SI is new Ada.Unchecked_Conversion (M256I, V8SI);
   function From_V32QI is new Ada.Unchecked_Conversion (V32QI, M256I);
   function From_V16HI is new Ada.Unchecked_Conversion (V16HI, M256I);
   function From_V8SI is new Ada.Unchecked_Conversion (V8SI, M256I);

   function To_U8x32 is new Ada.Unchecked_Conversion (M256I, U8x32);
   function To_U16x16 is new Ada.Unchecked_Conversion (M256I, U16x16);
   function To_U32x8 is new Ada.Unchecked_Conversion (M256I, U32x8);
   function To_U64x4 is new Ada.Unchecked_Conversion (M256I, U64x4);
   function From_U8x32 is new Ada.Unchecked_Conversion (U8x32, M256I);
   function From_U16x16 is new Ada.Unchecked_Conversion (U16x16, M256I);
   function From_U32x8 is new Ada.Unchecked_Conversion (U32x8, M256I);
   function From_U64x4 is new Ada.Unchecked_Conversion (U64x4, M256I);

   --  C's (int32_t) and (uint32_t) casts between the lane types, which
   --  Ada's checked conversions are not.
   function To_I32 is new Ada.Unchecked_Conversion (Unsigned_32, Integer_32);
   function To_U32 is new Ada.Unchecked_Conversion (Integer_32, Unsigned_32);
   function To_I64 is new Ada.Unchecked_Conversion (Unsigned_64, Integer_64);
   function To_U64 is new Ada.Unchecked_Conversion (Integer_64, Unsigned_64);

end Wuffs.Runtime.X86;
