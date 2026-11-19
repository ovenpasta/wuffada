--  Wuffs.Base.Ints.  Sweeps Ints_Arith, Ints_Bits and Ints_Sign mirror the
--  functions of the same names in oracle/oracle.c.

with Base_Oracle_Data;
with Base_Test_Support; use Base_Test_Support;
with Interfaces;
with Wuffs.Base.Ints;

procedure Test_Ints is

   use Wuffs;
   use Wuffs.Base.Ints;
   use type Interfaces.Unsigned_8;
   use type Interfaces.Unsigned_16;
   use type Interfaces.Unsigned_32;
   use type Interfaces.Unsigned_64;

   type Val_Array is array (0 .. 15) of U64;

   --  8 edge values and 8 random values of the given bit width.
   procedure Vals (V : out Val_Array; Width : Positive);

   procedure Vals (V : out Val_Array; Width : Positive) is
      All_Ones : constant U64 :=
        (if Width = 64 then U64'Last else Interfaces.Shift_Left (U64'(1), Width) - 1);
      Top      : constant U64 := Interfaces.Shift_Left (U64'(1), Width - 1);
   begin
      V (0) := 0;
      V (1) := 1;
      V (2) := 2;
      V (3) := Top - 1;
      V (4) := Top;
      V (5) := All_Ones - 1;
      V (6) := All_Ones;
      V (7) := 16#5555_5555_5555_5555# and All_Ones;
      for I in 8 .. 15 loop
         V (I) := Rnd and All_Ones;
      end loop;
   end Vals;

   V : Val_Array;

begin
   ----------------
   -- Ints_Arith --
   ----------------

   Start (1);
   Vals (V, 8);
   for I in V'Range loop
      for J in V'Range loop
         declare
            X : constant U8 := U8 (V (I));
            Y : constant U8 := U8 (V (J));
         begin
            Mix (U64 (Min_U8 (X, Y)));
            Mix (U64 (Max_U8 (X, Y)));
            Mix (U64 (Sat_Add_U8 (X, Y)));
            Mix (U64 (Sat_Sub_U8 (X, Y)));
         end;
      end loop;
   end loop;
   Vals (V, 16);
   for I in V'Range loop
      for J in V'Range loop
         declare
            X : constant U16 := U16 (V (I));
            Y : constant U16 := U16 (V (J));
         begin
            Mix (U64 (Min_U16 (X, Y)));
            Mix (U64 (Max_U16 (X, Y)));
            Mix (U64 (Sat_Add_U16 (X, Y)));
            Mix (U64 (Sat_Sub_U16 (X, Y)));
         end;
      end loop;
   end loop;
   Vals (V, 32);
   for I in V'Range loop
      for J in V'Range loop
         declare
            X : constant U32 := U32 (V (I));
            Y : constant U32 := U32 (V (J));
         begin
            Mix (U64 (Min_U32 (X, Y)));
            Mix (U64 (Max_U32 (X, Y)));
            Mix (U64 (Sat_Add_U32 (X, Y)));
            Mix (U64 (Sat_Sub_U32 (X, Y)));
         end;
      end loop;
   end loop;
   Vals (V, 64);
   for I in V'Range loop
      for J in V'Range loop
         Mix (Min_U64 (V (I), V (J)));
         Mix (Max_U64 (V (I), V (J)));
         Mix (Sat_Add_U64 (V (I), V (J)));
         Mix (Sat_Sub_U64 (V (I), V (J)));
      end loop;
   end loop;
   Finish ("ints: sweep Ints_Arith", Base_Oracle_Data.Ints_Arith);

   ---------------
   -- Ints_Bits --
   ---------------

   Start (2);
   Vals (V, 8);
   for I in V'Range loop
      for N in U32 range 0 .. 7 loop
         Mix (U64 (Low_Bits_U8 (U8 (V (I)), N)));
      end loop;
      for N in U32 range 1 .. 7 loop
         Mix (U64 (High_Bits_U8 (U8 (V (I)), N)));
      end loop;
   end loop;
   Vals (V, 16);
   for I in V'Range loop
      for N in U32 range 0 .. 15 loop
         Mix (U64 (Low_Bits_U16 (U16 (V (I)), N)));
      end loop;
      for N in U32 range 1 .. 15 loop
         Mix (U64 (High_Bits_U16 (U16 (V (I)), N)));
      end loop;
   end loop;
   Vals (V, 32);
   for I in V'Range loop
      for N in U32 range 0 .. 31 loop
         Mix (U64 (Low_Bits_U32 (U32 (V (I)), N)));
      end loop;
      for N in U32 range 1 .. 31 loop
         Mix (U64 (High_Bits_U32 (U32 (V (I)), N)));
      end loop;
   end loop;
   Vals (V, 64);
   for I in V'Range loop
      for N in U32 range 0 .. 63 loop
         Mix (Low_Bits_U64 (V (I), N));
      end loop;
      for N in U32 range 1 .. 63 loop
         Mix (High_Bits_U64 (V (I), N));
      end loop;
   end loop;
   Finish ("ints: sweep Ints_Bits", Base_Oracle_Data.Ints_Bits);

   ---------------
   -- Ints_Sign --
   ---------------

   Start (3);
   Vals (V, 8);
   for I in V'Range loop
      Mix (U64 (Sign_Extend_Convert_U8_U32 (U8 (V (I)))));
      Mix (Sign_Extend_Convert_U8_U64 (U8 (V (I))));
   end loop;
   Vals (V, 16);
   for I in V'Range loop
      Mix (U64 (Sign_Extend_Convert_U16_U32 (U16 (V (I)))));
      Mix (Sign_Extend_Convert_U16_U64 (U16 (V (I))));
      for N in U16 range 0 .. 15 loop
         Mix (U64 (Sign_Extend_Rshift_U16 (U16 (V (I)), N)));
      end loop;
   end loop;
   Vals (V, 32);
   for I in V'Range loop
      Mix (Sign_Extend_Convert_U32_U64 (U32 (V (I))));
      for N in U32 range 0 .. 31 loop
         Mix (U64 (Sign_Extend_Rshift_U32 (U32 (V (I)), N)));
      end loop;
   end loop;
   Vals (V, 64);
   for I in V'Range loop
      for N in U32 range 0 .. 63 loop
         Mix (Sign_Extend_Rshift_U64 (V (I), N));
      end loop;
   end loop;
   for I in V'Range loop
      for J in V'Range loop
         if V (J) /= 0
           and then not (V (I) = 16#8000_0000_0000_0000# and then V (J) = U64'Last)
         then
            Mix (I64_Divide (V (I), V (J)));
         end if;
      end loop;
   end loop;
   declare
      BV : constant Bitvec256 := Make_Bitvec256 (V (8), V (9), V (10), V (11));
   begin
      for I in U32 range 0 .. 7 loop
         Mix (Get_U64 (BV, I));
      end loop;
   end;
   for I in V'Range loop
      for H in Boolean loop
         declare
            O : constant Optional_U63 :=
              Make_Optional_U63 (H, Interfaces.Shift_Right (V (I), 1));
         begin
            Mix (Has_Value (O));
            Mix (Value (O));
            Mix (Value_Or (O, 123));
         end;
      end loop;
   end loop;
   Finish ("ints: sweep Ints_Sign", Base_Oracle_Data.Ints_Sign);

   --------------------
   -- Explicit cases --
   --------------------

   --  Saturation at both ends, every width.
   Check (Sat_Add_U8 (255, 1) = 255, "ints: sat_add u8 max+1");
   Check (Sat_Add_U8 (200, 100) = 255, "ints: sat_add u8 200+100");
   Check (Sat_Add_U8 (200, 55) = 255, "ints: sat_add u8 exact");
   Check (Sat_Add_U8 (200, 54) = 254, "ints: sat_add u8 just below");
   Check (Sat_Add_U8 (0, 0) = 0, "ints: sat_add u8 zero");
   Check (Sat_Sub_U8 (0, 1) = 0, "ints: sat_sub u8 0-1");
   Check (Sat_Sub_U8 (5, 5) = 0, "ints: sat_sub u8 equal");
   Check (Sat_Sub_U8 (5, 4) = 1, "ints: sat_sub u8 5-4");
   Check (Sat_Add_U16 (16#FFFF#, 16#FFFF#) = 16#FFFF#, "ints: sat_add u16 max+max");
   Check (Sat_Add_U16 (16#FF00#, 16#FF#) = 16#FFFF#, "ints: sat_add u16 exact");
   Check (Sat_Sub_U16 (1, 16#FFFF#) = 0, "ints: sat_sub u16 1-max");
   Check (Sat_Add_U32 (16#FFFF_FFFF#, 1) = 16#FFFF_FFFF#, "ints: sat_add u32 max+1");
   Check (Sat_Add_U32 (16#8000_0000#, 16#8000_0000#) = 16#FFFF_FFFF#, "ints: sat_add u32 half");
   Check (Sat_Add_U32 (16#7FFF_FFFF#, 16#8000_0000#) = 16#FFFF_FFFF#, "ints: sat_add u32 exact");
   Check (Sat_Sub_U32 (0, 16#FFFF_FFFF#) = 0, "ints: sat_sub u32 0-max");
   Check (Sat_Sub_U32 (16#FFFF_FFFF#, 16#FFFF_FFFF#) = 0, "ints: sat_sub u32 max-max");
   Check (Sat_Add_U64 (U64'Last, 1) = U64'Last, "ints: sat_add u64 max+1");
   Check (Sat_Add_U64 (U64'Last, U64'Last) = U64'Last, "ints: sat_add u64 max+max");
   Check (Sat_Add_U64 (U64'Last - 1, 1) = U64'Last, "ints: sat_add u64 exact");
   Check (Sat_Add_U64 (1, 2) = 3, "ints: sat_add u64 1+2");
   Check (Sat_Sub_U64 (0, U64'Last) = 0, "ints: sat_sub u64 0-max");
   Check (Sat_Sub_U64 (U64'Last, 1) = U64'Last - 1, "ints: sat_sub u64 max-1");

   Check (Min_U8 (3, 3) = 3 and then Max_U8 (3, 3) = 3, "ints: min/max equal");
   Check (Min_U64 (0, U64'Last) = 0, "ints: min u64");
   Check (Max_U64 (0, U64'Last) = U64'Last, "ints: max u64");

   --  Bit fields, including n = 0, which the oracle cannot cover for
   --  high_bits (undefined shift in C for u32 and u64).
   Check (Low_Bits_U8 (16#FF#, 0) = 0, "ints: low_bits u8 n=0");
   Check (Low_Bits_U8 (16#FF#, 7) = 16#7F#, "ints: low_bits u8 n=7");
   Check (Low_Bits_U16 (16#ABCD#, 4) = 16#D#, "ints: low_bits u16 n=4");
   Check (Low_Bits_U32 (16#FFFF_FFFF#, 31) = 16#7FFF_FFFF#, "ints: low_bits u32 n=31");
   Check (Low_Bits_U64 (U64'Last, 63) = 16#7FFF_FFFF_FFFF_FFFF#, "ints: low_bits u64 n=63");
   Check (Low_Bits_U64 (U64'Last, 0) = 0, "ints: low_bits u64 n=0");
   Check (High_Bits_U8 (16#FF#, 0) = 0, "ints: high_bits u8 n=0");
   Check (High_Bits_U16 (16#FFFF#, 0) = 0, "ints: high_bits u16 n=0");
   Check (High_Bits_U32 (16#FFFF_FFFF#, 0) = 0, "ints: high_bits u32 n=0");
   Check (High_Bits_U64 (U64'Last, 0) = 0, "ints: high_bits u64 n=0");
   Check (High_Bits_U8 (16#A5#, 4) = 16#A#, "ints: high_bits u8 n=4");
   Check (High_Bits_U16 (16#ABCD#, 4) = 16#A#, "ints: high_bits u16 n=4");
   Check (High_Bits_U32 (16#8000_0000#, 1) = 1, "ints: high_bits u32 n=1");
   Check (High_Bits_U32 (16#1234_5678#, 31) = 16#091A_2B3C#, "ints: high_bits u32 n=31");
   Check (High_Bits_U64 (16#8000_0000_0000_0000#, 63) = 16#4000_0000_0000_0000#,
          "ints: high_bits u64 n=63");

   --  Sign extension.
   Check (Sign_Extend_Convert_U8_U32 (16#7F#) = 16#7F#, "ints: sext u8 u32 positive");
   Check (Sign_Extend_Convert_U8_U32 (16#80#) = 16#FFFF_FF80#, "ints: sext u8 u32 negative");
   Check (Sign_Extend_Convert_U8_U64 (16#FF#) = U64'Last, "ints: sext u8 u64 -1");
   Check (Sign_Extend_Convert_U16_U32 (16#8000#) = 16#FFFF_8000#, "ints: sext u16 u32");
   Check (Sign_Extend_Convert_U16_U64 (16#7FFF#) = 16#7FFF#, "ints: sext u16 u64");
   Check (Sign_Extend_Convert_U32_U64 (16#8000_0000#) = 16#FFFF_FFFF_8000_0000#,
          "ints: sext u32 u64");
   Check (Sign_Extend_Rshift_U16 (16#8000#, 15) = 16#FFFF#, "ints: rshift u16");
   Check (Sign_Extend_Rshift_U16 (16#4000#, 14) = 1, "ints: rshift u16 positive");
   Check (Sign_Extend_Rshift_U32 (16#8000_0000#, 31) = 16#FFFF_FFFF#, "ints: rshift u32");
   Check (Sign_Extend_Rshift_U32 (16#8000_0000#, 0) = 16#8000_0000#, "ints: rshift u32 n=0");
   Check (Sign_Extend_Rshift_U64 (16#8000_0000_0000_0000#, 63) = U64'Last, "ints: rshift u64");
   Check (Sign_Extend_Rshift_U64 (16#7000_0000_0000_0000#, 60) = 7, "ints: rshift u64 +");

   --  Signed division: truncation towards zero for every sign combination
   --  (operands written as two's complement of the signed value).
   Check (I64_Divide (7, 2) = 3, "ints: i64_divide 7/2");
   Check (I64_Divide (0 - 7, 2) = 0 - 3, "ints: i64_divide -7/2");
   Check (I64_Divide (7, 0 - 2) = 0 - 3, "ints: i64_divide 7/-2");
   Check (I64_Divide (0 - 7, 0 - 2) = 3, "ints: i64_divide -7/-2");
   Check (I64_Divide (0, 0 - 5) = 0, "ints: i64_divide 0/-5");
   Check (I64_Divide (1, 0 - 5) = 0, "ints: i64_divide 1/-5");
   Check (I64_Divide (16#8000_0000_0000_0000#, 1) = 16#8000_0000_0000_0000#,
          "ints: i64_divide min/1");
   Check (I64_Divide (16#8000_0000_0000_0000#, 2) = 16#C000_0000_0000_0000#,
          "ints: i64_divide min/2");
   Check (I64_Divide (16#7FFF_FFFF_FFFF_FFFF#, U64'Last) = 16#8000_0000_0000_0001#,
          "ints: i64_divide max/-1");
   Check (I64_Divide (5, 16#8000_0000_0000_0000#) = 0, "ints: i64_divide 5/min");
   Check (I64_Divide (16#8000_0000_0000_0000#, 16#8000_0000_0000_0000#) = 1,
          "ints: i64_divide min/min");
   --  Undefined in C; defined here as the wrapped quotient.
   Check (I64_Divide (16#8000_0000_0000_0000#, U64'Last) = 16#8000_0000_0000_0000#,
          "ints: i64_divide min/-1");

   --  Bitvec256 and Optional_U63.
   declare
      BV : constant Bitvec256 := Make_Bitvec256 (10, 11, 12, 13);
      O  : Optional_U63;
   begin
      Check (Get_U64 (BV, 0) = 10 and then Get_U64 (BV, 3) = 13, "ints: bitvec256 get");
      Check (Get_U64 (BV, 6) = 12, "ints: bitvec256 get wraps");
      Check (not Has_Value (O), "ints: optional default is none");
      Check (Value (O) = 0 and then Value_Or (O, 9) = 9, "ints: optional none value");
      O := Make_Optional_U63 (True, 0);
      Check (Has_Value (O) and then Value (O) = 0 and then Value_Or (O, 9) = 0,
             "ints: optional zero");
      O := Make_Optional_U63 (True, U63'Last);
      Check (Has_Value (O) and then Value (O) = U63'Last, "ints: optional max");
      O := Make_Optional_U63 (False, U63'Last);
      Check (not Has_Value (O) and then Value (O) = 0, "ints: optional ignores value");
   end;
end Test_Ints;
