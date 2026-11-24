--  Peek and poke: fixed-width unsigned integers read from, or written to,
--  consecutive elements of a Bytes array, little or big endian.
--
--  C: wuffs_base__peek_uNNxe__no_bounds_check and
--  wuffs_base__poke_uNNxe__no_bounds_check in fundamental-public.h.  The C
--  functions take a bare pointer and trust the caller; here "no bounds
--  check" becomes the precondition Has (Data, Pos, N), which the Wuffs
--  compiler has already established for generated code.
--
--  Addressing convention of this package: every Pos is an Array_Index, an
--  Ada index into Data (the first byte used is Data (Pos)), not an offset
--  from Data'First.  Wuffs.Base.IO is the package that works in offsets.
--
--  The Wuffs methods `slice u8.peek_uNNxe()` and `slice u8.poke_uNNxe!(a)`
--  act on the start of the slice: call these with Pos => S'First.
--
--  The 24, 40, 48 and 56 bit peeks return the next wider type with the high
--  bits zero.  The matching pokes take the wider type and write its low
--  bits only, ignoring the rest, as in C.

package Wuffs.Base.Endian with Pure, SPARK_Mode is

   pragma Assertion_Policy (Post => Ignore);

   use type Interfaces.Unsigned_8;
   use type Interfaces.Unsigned_16;
   use type Interfaces.Unsigned_32;
   use type Interfaces.Unsigned_64;

   --  True if Data (Pos .. Pos + N - 1) exists.
   function Has (Data : Bytes; Pos : Array_Index; N : Element_Count) return Boolean is
     (Pos >= Data'First and then Pos <= Data'Last and then Data'Last - Pos >= N - 1)
   with Pre => N >= 1;

   --  True if Old_Data and New_Data have the same bounds and agree
   --  everywhere outside Pos .. Pos + N - 1.  Frame condition of the pokes.
   function Same_Outside
     (Old_Data, New_Data : Bytes; Pos : Array_Index; N : Element_Count) return Boolean
   is
     (Old_Data'First = New_Data'First
      and then Old_Data'Last = New_Data'Last
      and then (for all J in New_Data'Range =>
                  (if J < Pos or else J - Pos >= N then New_Data (J) = Old_Data (J))))
   with Ghost, Pre => N >= 1;

   ----------
   -- Peek --
   ----------

   --  Each peek is Combine_UNNxE of a fixed-length slice: GCC turns that
   --  into one load (plus a byte swap for big endian), which it does not do
   --  when the bytes are Data (Pos + K) of an array with a variable
   --  Data'First.  The Combine functions are the byte orders.
   subtype Bytes_2 is Bytes (0 .. 1);
   subtype Bytes_3 is Bytes (0 .. 2);
   subtype Bytes_4 is Bytes (0 .. 3);
   subtype Bytes_5 is Bytes (0 .. 4);
   subtype Bytes_6 is Bytes (0 .. 5);
   subtype Bytes_7 is Bytes (0 .. 6);
   subtype Bytes_8 is Bytes (0 .. 7);

   function Combine_U16BE (B : Bytes_2) return U16 is
     (Interfaces.Shift_Left (U16 (B (0)), 8)
      or U16 (B (1)));

   function Combine_U16LE (B : Bytes_2) return U16 is
     (U16 (B (0))
      or Interfaces.Shift_Left (U16 (B (1)), 8));

   function Combine_U24BE (B : Bytes_3) return U32 is
     (Interfaces.Shift_Left (U32 (B (0)), 16)
      or Interfaces.Shift_Left (U32 (B (1)), 8)
      or U32 (B (2)));

   function Combine_U24LE (B : Bytes_3) return U32 is
     (U32 (B (0))
      or Interfaces.Shift_Left (U32 (B (1)), 8)
      or Interfaces.Shift_Left (U32 (B (2)), 16));

   function Combine_U32BE (B : Bytes_4) return U32 is
     (Interfaces.Shift_Left (U32 (B (0)), 24)
      or Interfaces.Shift_Left (U32 (B (1)), 16)
      or Interfaces.Shift_Left (U32 (B (2)), 8)
      or U32 (B (3)));

   function Combine_U32LE (B : Bytes_4) return U32 is
     (U32 (B (0))
      or Interfaces.Shift_Left (U32 (B (1)), 8)
      or Interfaces.Shift_Left (U32 (B (2)), 16)
      or Interfaces.Shift_Left (U32 (B (3)), 24));

   function Combine_U40BE (B : Bytes_5) return U64 is
     (Interfaces.Shift_Left (U64 (B (0)), 32)
      or Interfaces.Shift_Left (U64 (B (1)), 24)
      or Interfaces.Shift_Left (U64 (B (2)), 16)
      or Interfaces.Shift_Left (U64 (B (3)), 8)
      or U64 (B (4)));

   function Combine_U40LE (B : Bytes_5) return U64 is
     (U64 (B (0))
      or Interfaces.Shift_Left (U64 (B (1)), 8)
      or Interfaces.Shift_Left (U64 (B (2)), 16)
      or Interfaces.Shift_Left (U64 (B (3)), 24)
      or Interfaces.Shift_Left (U64 (B (4)), 32));

   function Combine_U48BE (B : Bytes_6) return U64 is
     (Interfaces.Shift_Left (U64 (B (0)), 40)
      or Interfaces.Shift_Left (U64 (B (1)), 32)
      or Interfaces.Shift_Left (U64 (B (2)), 24)
      or Interfaces.Shift_Left (U64 (B (3)), 16)
      or Interfaces.Shift_Left (U64 (B (4)), 8)
      or U64 (B (5)));

   function Combine_U48LE (B : Bytes_6) return U64 is
     (U64 (B (0))
      or Interfaces.Shift_Left (U64 (B (1)), 8)
      or Interfaces.Shift_Left (U64 (B (2)), 16)
      or Interfaces.Shift_Left (U64 (B (3)), 24)
      or Interfaces.Shift_Left (U64 (B (4)), 32)
      or Interfaces.Shift_Left (U64 (B (5)), 40));

   function Combine_U56BE (B : Bytes_7) return U64 is
     (Interfaces.Shift_Left (U64 (B (0)), 48)
      or Interfaces.Shift_Left (U64 (B (1)), 40)
      or Interfaces.Shift_Left (U64 (B (2)), 32)
      or Interfaces.Shift_Left (U64 (B (3)), 24)
      or Interfaces.Shift_Left (U64 (B (4)), 16)
      or Interfaces.Shift_Left (U64 (B (5)), 8)
      or U64 (B (6)));

   function Combine_U56LE (B : Bytes_7) return U64 is
     (U64 (B (0))
      or Interfaces.Shift_Left (U64 (B (1)), 8)
      or Interfaces.Shift_Left (U64 (B (2)), 16)
      or Interfaces.Shift_Left (U64 (B (3)), 24)
      or Interfaces.Shift_Left (U64 (B (4)), 32)
      or Interfaces.Shift_Left (U64 (B (5)), 40)
      or Interfaces.Shift_Left (U64 (B (6)), 48));

   function Combine_U64BE (B : Bytes_8) return U64 is
     (Interfaces.Shift_Left (U64 (B (0)), 56)
      or Interfaces.Shift_Left (U64 (B (1)), 48)
      or Interfaces.Shift_Left (U64 (B (2)), 40)
      or Interfaces.Shift_Left (U64 (B (3)), 32)
      or Interfaces.Shift_Left (U64 (B (4)), 24)
      or Interfaces.Shift_Left (U64 (B (5)), 16)
      or Interfaces.Shift_Left (U64 (B (6)), 8)
      or U64 (B (7)));

   function Combine_U64LE (B : Bytes_8) return U64 is
     (U64 (B (0))
      or Interfaces.Shift_Left (U64 (B (1)), 8)
      or Interfaces.Shift_Left (U64 (B (2)), 16)
      or Interfaces.Shift_Left (U64 (B (3)), 24)
      or Interfaces.Shift_Left (U64 (B (4)), 32)
      or Interfaces.Shift_Left (U64 (B (5)), 40)
      or Interfaces.Shift_Left (U64 (B (6)), 48)
      or Interfaces.Shift_Left (U64 (B (7)), 56));


   function Peek_U8 (Data : Bytes; Pos : Array_Index) return U8 is (Data (Pos))
   with Pre => Has (Data, Pos, 1);

   function Peek_U16BE (Data : Bytes; Pos : Array_Index) return U16 is
     (Combine_U16BE (Data (Pos .. Pos + 1)))
   with Pre => Has (Data, Pos, 2);

   function Peek_U16LE (Data : Bytes; Pos : Array_Index) return U16 is
     (Combine_U16LE (Data (Pos .. Pos + 1)))
   with Pre => Has (Data, Pos, 2);

   function Peek_U24BE (Data : Bytes; Pos : Array_Index) return U32 is
     (Combine_U24BE (Data (Pos .. Pos + 2)))
   with
     Pre  => Has (Data, Pos, 3),
     Post => Peek_U24BE'Result <= 16#FF_FFFF#;

   function Peek_U24LE (Data : Bytes; Pos : Array_Index) return U32 is
     (Combine_U24LE (Data (Pos .. Pos + 2)))
   with
     Pre  => Has (Data, Pos, 3),
     Post => Peek_U24LE'Result <= 16#FF_FFFF#;

   function Peek_U32BE (Data : Bytes; Pos : Array_Index) return U32 is
     (Combine_U32BE (Data (Pos .. Pos + 3)))
   with Pre => Has (Data, Pos, 4);

   function Peek_U32LE (Data : Bytes; Pos : Array_Index) return U32 is
     (Combine_U32LE (Data (Pos .. Pos + 3)))
   with Pre => Has (Data, Pos, 4);

   function Peek_U40BE (Data : Bytes; Pos : Array_Index) return U64 is
     (Combine_U40BE (Data (Pos .. Pos + 4)))
   with
     Pre  => Has (Data, Pos, 5),
     Post => Peek_U40BE'Result <= 16#FF_FFFF_FFFF#;

   function Peek_U40LE (Data : Bytes; Pos : Array_Index) return U64 is
     (Combine_U40LE (Data (Pos .. Pos + 4)))
   with
     Pre  => Has (Data, Pos, 5),
     Post => Peek_U40LE'Result <= 16#FF_FFFF_FFFF#;

   function Peek_U48BE (Data : Bytes; Pos : Array_Index) return U64 is
     (Combine_U48BE (Data (Pos .. Pos + 5)))
   with
     Pre  => Has (Data, Pos, 6),
     Post => Peek_U48BE'Result <= 16#FFFF_FFFF_FFFF#;

   function Peek_U48LE (Data : Bytes; Pos : Array_Index) return U64 is
     (Combine_U48LE (Data (Pos .. Pos + 5)))
   with
     Pre  => Has (Data, Pos, 6),
     Post => Peek_U48LE'Result <= 16#FFFF_FFFF_FFFF#;

   function Peek_U56BE (Data : Bytes; Pos : Array_Index) return U64 is
     (Combine_U56BE (Data (Pos .. Pos + 6)))
   with
     Pre  => Has (Data, Pos, 7),
     Post => Peek_U56BE'Result <= 16#FF_FFFF_FFFF_FFFF#;

   function Peek_U56LE (Data : Bytes; Pos : Array_Index) return U64 is
     (Combine_U56LE (Data (Pos .. Pos + 6)))
   with
     Pre  => Has (Data, Pos, 7),
     Post => Peek_U56LE'Result <= 16#FF_FFFF_FFFF_FFFF#;

   function Peek_U64BE (Data : Bytes; Pos : Array_Index) return U64 is
     (Combine_U64BE (Data (Pos .. Pos + 7)))
   with Pre => Has (Data, Pos, 8);

   function Peek_U64LE (Data : Bytes; Pos : Array_Index) return U64 is
     (Combine_U64LE (Data (Pos .. Pos + 7)))
   with Pre => Has (Data, Pos, 8);

   ----------
   -- Poke --
   ----------

   --  Each poke changes exactly the N elements starting at Pos, and a peek
   --  of the same width and endianness at Pos then returns V (masked to the
   --  width for the 24, 40, 48 and 56 bit forms).

   procedure Poke_U8 (Data : in out Bytes; Pos : Array_Index; V : U8) with
     Inline_Always,
     Pre  => Has (Data, Pos, 1),
     Post => Peek_U8 (Data, Pos) = V and then Same_Outside (Data'Old, Data, Pos, 1);

   procedure Poke_U16BE (Data : in out Bytes; Pos : Array_Index; V : U16) with
     Inline_Always,
     Pre  => Has (Data, Pos, 2),
     Post => Peek_U16BE (Data, Pos) = V
       and then Same_Outside (Data'Old, Data, Pos, 2);

   procedure Poke_U16LE (Data : in out Bytes; Pos : Array_Index; V : U16) with
     Inline_Always,
     Pre  => Has (Data, Pos, 2),
     Post => Peek_U16LE (Data, Pos) = V
       and then Same_Outside (Data'Old, Data, Pos, 2);

   procedure Poke_U24BE (Data : in out Bytes; Pos : Array_Index; V : U32) with
     Inline_Always,
     Pre  => Has (Data, Pos, 3),
     Post => Peek_U24BE (Data, Pos) = (V and 16#FF_FFFF#)
       and then Same_Outside (Data'Old, Data, Pos, 3);

   procedure Poke_U24LE (Data : in out Bytes; Pos : Array_Index; V : U32) with
     Inline_Always,
     Pre  => Has (Data, Pos, 3),
     Post => Peek_U24LE (Data, Pos) = (V and 16#FF_FFFF#)
       and then Same_Outside (Data'Old, Data, Pos, 3);

   procedure Poke_U32BE (Data : in out Bytes; Pos : Array_Index; V : U32) with
     Inline_Always,
     Pre  => Has (Data, Pos, 4),
     Post => Peek_U32BE (Data, Pos) = V
       and then Same_Outside (Data'Old, Data, Pos, 4);

   procedure Poke_U32LE (Data : in out Bytes; Pos : Array_Index; V : U32) with
     Inline_Always,
     Pre  => Has (Data, Pos, 4),
     Post => Peek_U32LE (Data, Pos) = V
       and then Same_Outside (Data'Old, Data, Pos, 4);

   procedure Poke_U40BE (Data : in out Bytes; Pos : Array_Index; V : U64) with
     Inline_Always,
     Pre  => Has (Data, Pos, 5),
     Post => Peek_U40BE (Data, Pos) = (V and 16#FF_FFFF_FFFF#)
       and then Same_Outside (Data'Old, Data, Pos, 5);

   procedure Poke_U40LE (Data : in out Bytes; Pos : Array_Index; V : U64) with
     Inline_Always,
     Pre  => Has (Data, Pos, 5),
     Post => Peek_U40LE (Data, Pos) = (V and 16#FF_FFFF_FFFF#)
       and then Same_Outside (Data'Old, Data, Pos, 5);

   procedure Poke_U48BE (Data : in out Bytes; Pos : Array_Index; V : U64) with
     Inline_Always,
     Pre  => Has (Data, Pos, 6),
     Post => Peek_U48BE (Data, Pos) = (V and 16#FFFF_FFFF_FFFF#)
       and then Same_Outside (Data'Old, Data, Pos, 6);

   procedure Poke_U48LE (Data : in out Bytes; Pos : Array_Index; V : U64) with
     Inline_Always,
     Pre  => Has (Data, Pos, 6),
     Post => Peek_U48LE (Data, Pos) = (V and 16#FFFF_FFFF_FFFF#)
       and then Same_Outside (Data'Old, Data, Pos, 6);

   procedure Poke_U56BE (Data : in out Bytes; Pos : Array_Index; V : U64) with
     Inline_Always,
     Pre  => Has (Data, Pos, 7),
     Post => Peek_U56BE (Data, Pos) = (V and 16#FF_FFFF_FFFF_FFFF#)
       and then Same_Outside (Data'Old, Data, Pos, 7);

   procedure Poke_U56LE (Data : in out Bytes; Pos : Array_Index; V : U64) with
     Inline_Always,
     Pre  => Has (Data, Pos, 7),
     Post => Peek_U56LE (Data, Pos) = (V and 16#FF_FFFF_FFFF_FFFF#)
       and then Same_Outside (Data'Old, Data, Pos, 7);

   procedure Poke_U64BE (Data : in out Bytes; Pos : Array_Index; V : U64) with
     Inline_Always,
     Pre  => Has (Data, Pos, 8),
     Post => Peek_U64BE (Data, Pos) = V
       and then Same_Outside (Data'Old, Data, Pos, 8);

   procedure Poke_U64LE (Data : in out Bytes; Pos : Array_Index; V : U64) with
     Inline_Always,
     Pre  => Has (Data, Pos, 8),
     Post => Peek_U64LE (Data, Pos) = V
       and then Same_Outside (Data'Old, Data, Pos, 8);

end Wuffs.Base.Endian;
