--  Integer helpers: the numeric methods of Wuffs' base package that are not
--  plain Ada operators.
--
--  Wuffs method / operator            Ada
--  ---------------------------------  ------------------------------------
--  uN.min, uN.max                     Min_UN, Max_UN
--  uN.low_bits, uN.high_bits          Low_Bits_UN, High_Bits_UN
--  x ~sat+ y, x ~sat- y               Sat_Add_UN, Sat_Sub_UN
--  utility.sign_extend_convert_uA_uB  Sign_Extend_Convert_UA_UB
--  utility.sign_extend_rshift_uN      Sign_Extend_Rshift_UN
--  utility.i64_divide                 I64_Divide
--  utility.make_bitvec256, .get_u64   Make_Bitvec256, Get_U64
--  utility.make_optional_u63          Make_Optional_U63 (+ C API accessors)
--
--  Everything here is an expression function: the body is the contract.
--  The C counterparts are in wuffs/internal/cgen/base/fundamental-public.h
--  and fundamental-private.h.

package Wuffs.Base.Ints with Pure, SPARK_Mode is

   pragma Assertion_Policy (Post => Ignore);

   use type Interfaces.Unsigned_8;
   use type Interfaces.Unsigned_16;
   use type Interfaces.Unsigned_32;
   use type Interfaces.Unsigned_64;

   ---------------
   -- Min / Max --
   ---------------

   function Min_U8 (X, Y : U8) return U8 is (if X < Y then X else Y);
   function Max_U8 (X, Y : U8) return U8 is (if X > Y then X else Y);
   function Min_U16 (X, Y : U16) return U16 is (if X < Y then X else Y);
   function Max_U16 (X, Y : U16) return U16 is (if X > Y then X else Y);
   function Min_U32 (X, Y : U32) return U32 is (if X < Y then X else Y);
   function Max_U32 (X, Y : U32) return U32 is (if X > Y then X else Y);
   function Min_U64 (X, Y : U64) return U64 is (if X < Y then X else Y);
   function Max_U64 (X, Y : U64) return U64 is (if X > Y then X else Y);

   ---------------------------
   -- Saturating arithmetic --
   ---------------------------

   --  Sat_Add: X + Y, or the type's maximum if that overflows.
   --  Sat_Sub: X - Y, or zero if that underflows.

   function Sat_Add_U8 (X, Y : U8) return U8 is
     (if Y > U8'Last - X then U8'Last else X + Y);
   function Sat_Sub_U8 (X, Y : U8) return U8 is
     (if Y > X then 0 else X - Y);

   function Sat_Add_U16 (X, Y : U16) return U16 is
     (if Y > U16'Last - X then U16'Last else X + Y);
   function Sat_Sub_U16 (X, Y : U16) return U16 is
     (if Y > X then 0 else X - Y);

   function Sat_Add_U32 (X, Y : U32) return U32 is
     (if Y > U32'Last - X then U32'Last else X + Y);
   function Sat_Sub_U32 (X, Y : U32) return U32 is
     (if Y > X then 0 else X - Y);

   function Sat_Add_U64 (X, Y : U64) return U64 is
     (if Y > U64'Last - X then U64'Last else X + Y);
   function Sat_Sub_U64 (X, Y : U64) return U64 is
     (if Y > X then 0 else X - Y);

   --------------------------
   -- Low_Bits / High_Bits --
   --------------------------

   --  Low_Bits (X, N) is the low N bits of X.  High_Bits (X, N) is the high
   --  N bits of X, shifted down to the low end.  N is strictly less than the
   --  bit width, as in the Wuffs signatures.
   --
   --  High_Bits (X, 0) is 0.  (The C expression `x >> (width - n)` is a
   --  shift by the full width for n = 0, which C leaves undefined for u32
   --  and u64; 0 is the mathematically consistent value and what C yields
   --  for u8 and u16.)

   function Low_Bits_U8 (X : U8; N : U32) return U8 is
     (X and (Interfaces.Shift_Left (U8'(1), Natural (N)) - 1))
   with Pre => N <= 7;
   function High_Bits_U8 (X : U8; N : U32) return U8 is
     (Interfaces.Shift_Right (X, 8 - Natural (N)))
   with Pre => N <= 7;

   function Low_Bits_U16 (X : U16; N : U32) return U16 is
     (X and (Interfaces.Shift_Left (U16'(1), Natural (N)) - 1))
   with Pre => N <= 15;
   function High_Bits_U16 (X : U16; N : U32) return U16 is
     (Interfaces.Shift_Right (X, 16 - Natural (N)))
   with Pre => N <= 15;

   function Low_Bits_U32 (X : U32; N : U32) return U32 is
     (X and (Interfaces.Shift_Left (U32'(1), Natural (N)) - 1))
   with Pre => N <= 31;
   function High_Bits_U32 (X : U32; N : U32) return U32 is
     (Interfaces.Shift_Right (X, 32 - Natural (N)))
   with Pre => N <= 31;

   function Low_Bits_U64 (X : U64; N : U32) return U64 is
     (X and (Interfaces.Shift_Left (U64'(1), Natural (N)) - 1))
   with Pre => N <= 63;
   function High_Bits_U64 (X : U64; N : U32) return U64 is
     (Interfaces.Shift_Right (X, 64 - Natural (N)))
   with Pre => N <= 63;

   --------------------
   -- Sign extension --
   --------------------

   --  Sign_Extend_Convert_UA_UB (A): reinterpret A as a two's complement
   --  signed integer, widen it, reinterpret the result as unsigned.

   function Sign_Extend_Convert_U8_U32 (A : U8) return U32 is
     (if A >= 16#80# then U32 (A) or 16#FFFF_FF00# else U32 (A));
   function Sign_Extend_Convert_U8_U64 (A : U8) return U64 is
     (if A >= 16#80# then U64 (A) or 16#FFFF_FFFF_FFFF_FF00# else U64 (A));
   function Sign_Extend_Convert_U16_U32 (A : U16) return U32 is
     (if A >= 16#8000# then U32 (A) or 16#FFFF_0000# else U32 (A));
   function Sign_Extend_Convert_U16_U64 (A : U16) return U64 is
     (if A >= 16#8000# then U64 (A) or 16#FFFF_FFFF_FFFF_0000# else U64 (A));
   function Sign_Extend_Convert_U32_U64 (A : U32) return U64 is
     (if A >= 16#8000_0000# then U64 (A) or 16#FFFF_FFFF_0000_0000# else U64 (A));

   --  Sign_Extend_Rshift_UN (A, N): arithmetic (sign-propagating) right
   --  shift of A by N bits.

   function Sign_Extend_Rshift_U16 (A : U16; N : U16) return U16 is
     (Interfaces.Shift_Right_Arithmetic (A, Natural (N)))
   with Pre => N <= 15;
   function Sign_Extend_Rshift_U32 (A : U32; N : U32) return U32 is
     (Interfaces.Shift_Right_Arithmetic (A, Natural (N)))
   with Pre => N <= 31;
   function Sign_Extend_Rshift_U64 (A : U64; N : U32) return U64 is
     (Interfaces.Shift_Right_Arithmetic (A, Natural (N)))
   with Pre => N <= 63;

   ---------------------
   -- Signed division --
   ---------------------

   --  I64_Divide (A, B): reinterpret A and B as two's complement signed
   --  64-bit integers, divide truncating towards zero, reinterpret the
   --  quotient as unsigned.
   --
   --  The one case where the mathematical quotient does not fit, -2**63 /
   --  -1 (A = 16#8000_0000_0000_0000#, B = U64'Last), is undefined behaviour
   --  in the C macro.  Here it wraps and yields 16#8000_0000_0000_0000#.

   function Is_Negative_I64 (A : U64) return Boolean is
     (A >= 16#8000_0000_0000_0000#);

   --  Magnitude of A read as a signed integer (2**63 for the minimum).
   function Magnitude_I64 (A : U64) return U64 is
     (if Is_Negative_I64 (A) then 0 - A else A);

   function I64_Divide (A, B : U64) return U64 is
     (if Is_Negative_I64 (A) = Is_Negative_I64 (B)
      then Magnitude_I64 (A) / Magnitude_I64 (B)
      else 0 - (Magnitude_I64 (A) / Magnitude_I64 (B)))
   with Pre => B /= 0;

   ---------------
   -- Bitvec256 --
   ---------------

   --  Element 0 holds the least significant 64 bits.
   type Bitvec256 is array (U32 range 0 .. 3) of U64;

   function Make_Bitvec256 (E00, E01, E02, E03 : U64) return Bitvec256 is
     [E00, E01, E02, E03];

   --  As in C, only the low two bits of I are used.
   function Get_U64 (B : Bitvec256; I : U32) return U64 is (B (I and 3));

   ------------------
   -- Optional_U63 --
   ------------------

   --  Like C's wuffs_base__optional_u63: a 63-bit value or nothing, held in
   --  one U64.  Do not use Repr directly.
   type Optional_U63 is record
      Repr : U64 := 0;
   end record;

   subtype U63 is U64 range 0 .. 16#7FFF_FFFF_FFFF_FFFF#;

   --  Value is ignored when Has_Value is False.
   function Make_Optional_U63 (Has_Value : Boolean; Value : U63) return Optional_U63 is
     (Repr => (if Has_Value then Interfaces.Shift_Left (Value, 1) or 1 else 0));

   function Has_Value (O : Optional_U63) return Boolean is (O.Repr /= 0);

   --  Zero when O has no value.
   function Value (O : Optional_U63) return U63 is (Interfaces.Shift_Right (O.Repr, 1));

   function Value_Or (O : Optional_U63; Default : U64) return U64 is
     (if O.Repr /= 0 then Interfaces.Shift_Right (O.Repr, 1) else Default);

end Wuffs.Base.Ints;
