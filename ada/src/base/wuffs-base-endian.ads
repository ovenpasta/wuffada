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

   function Peek_U8 (Data : Bytes; Pos : Array_Index) return U8 is (Data (Pos))
   with Pre => Has (Data, Pos, 1);

   function Peek_U16BE (Data : Bytes; Pos : Array_Index) return U16 is
     (Interfaces.Shift_Left (U16 (Data (Pos)), 8)
      or U16 (Data (Pos + 1)))
   with Pre => Has (Data, Pos, 2);

   function Peek_U16LE (Data : Bytes; Pos : Array_Index) return U16 is
     (U16 (Data (Pos))
      or Interfaces.Shift_Left (U16 (Data (Pos + 1)), 8))
   with Pre => Has (Data, Pos, 2);

   function Peek_U24BE (Data : Bytes; Pos : Array_Index) return U32 is
     (Interfaces.Shift_Left (U32 (Data (Pos)), 16)
      or Interfaces.Shift_Left (U32 (Data (Pos + 1)), 8)
      or U32 (Data (Pos + 2)))
   with
     Pre  => Has (Data, Pos, 3),
     Post => Peek_U24BE'Result <= 16#FF_FFFF#;

   function Peek_U24LE (Data : Bytes; Pos : Array_Index) return U32 is
     (U32 (Data (Pos))
      or Interfaces.Shift_Left (U32 (Data (Pos + 1)), 8)
      or Interfaces.Shift_Left (U32 (Data (Pos + 2)), 16))
   with
     Pre  => Has (Data, Pos, 3),
     Post => Peek_U24LE'Result <= 16#FF_FFFF#;

   function Peek_U32BE (Data : Bytes; Pos : Array_Index) return U32 is
     (Interfaces.Shift_Left (U32 (Data (Pos)), 24)
      or Interfaces.Shift_Left (U32 (Data (Pos + 1)), 16)
      or Interfaces.Shift_Left (U32 (Data (Pos + 2)), 8)
      or U32 (Data (Pos + 3)))
   with Pre => Has (Data, Pos, 4);

   function Peek_U32LE (Data : Bytes; Pos : Array_Index) return U32 is
     (U32 (Data (Pos))
      or Interfaces.Shift_Left (U32 (Data (Pos + 1)), 8)
      or Interfaces.Shift_Left (U32 (Data (Pos + 2)), 16)
      or Interfaces.Shift_Left (U32 (Data (Pos + 3)), 24))
   with Pre => Has (Data, Pos, 4);

   function Peek_U40BE (Data : Bytes; Pos : Array_Index) return U64 is
     (Interfaces.Shift_Left (U64 (Data (Pos)), 32)
      or Interfaces.Shift_Left (U64 (Data (Pos + 1)), 24)
      or Interfaces.Shift_Left (U64 (Data (Pos + 2)), 16)
      or Interfaces.Shift_Left (U64 (Data (Pos + 3)), 8)
      or U64 (Data (Pos + 4)))
   with
     Pre  => Has (Data, Pos, 5),
     Post => Peek_U40BE'Result <= 16#FF_FFFF_FFFF#;

   function Peek_U40LE (Data : Bytes; Pos : Array_Index) return U64 is
     (U64 (Data (Pos))
      or Interfaces.Shift_Left (U64 (Data (Pos + 1)), 8)
      or Interfaces.Shift_Left (U64 (Data (Pos + 2)), 16)
      or Interfaces.Shift_Left (U64 (Data (Pos + 3)), 24)
      or Interfaces.Shift_Left (U64 (Data (Pos + 4)), 32))
   with
     Pre  => Has (Data, Pos, 5),
     Post => Peek_U40LE'Result <= 16#FF_FFFF_FFFF#;

   function Peek_U48BE (Data : Bytes; Pos : Array_Index) return U64 is
     (Interfaces.Shift_Left (U64 (Data (Pos)), 40)
      or Interfaces.Shift_Left (U64 (Data (Pos + 1)), 32)
      or Interfaces.Shift_Left (U64 (Data (Pos + 2)), 24)
      or Interfaces.Shift_Left (U64 (Data (Pos + 3)), 16)
      or Interfaces.Shift_Left (U64 (Data (Pos + 4)), 8)
      or U64 (Data (Pos + 5)))
   with
     Pre  => Has (Data, Pos, 6),
     Post => Peek_U48BE'Result <= 16#FFFF_FFFF_FFFF#;

   function Peek_U48LE (Data : Bytes; Pos : Array_Index) return U64 is
     (U64 (Data (Pos))
      or Interfaces.Shift_Left (U64 (Data (Pos + 1)), 8)
      or Interfaces.Shift_Left (U64 (Data (Pos + 2)), 16)
      or Interfaces.Shift_Left (U64 (Data (Pos + 3)), 24)
      or Interfaces.Shift_Left (U64 (Data (Pos + 4)), 32)
      or Interfaces.Shift_Left (U64 (Data (Pos + 5)), 40))
   with
     Pre  => Has (Data, Pos, 6),
     Post => Peek_U48LE'Result <= 16#FFFF_FFFF_FFFF#;

   function Peek_U56BE (Data : Bytes; Pos : Array_Index) return U64 is
     (Interfaces.Shift_Left (U64 (Data (Pos)), 48)
      or Interfaces.Shift_Left (U64 (Data (Pos + 1)), 40)
      or Interfaces.Shift_Left (U64 (Data (Pos + 2)), 32)
      or Interfaces.Shift_Left (U64 (Data (Pos + 3)), 24)
      or Interfaces.Shift_Left (U64 (Data (Pos + 4)), 16)
      or Interfaces.Shift_Left (U64 (Data (Pos + 5)), 8)
      or U64 (Data (Pos + 6)))
   with
     Pre  => Has (Data, Pos, 7),
     Post => Peek_U56BE'Result <= 16#FF_FFFF_FFFF_FFFF#;

   function Peek_U56LE (Data : Bytes; Pos : Array_Index) return U64 is
     (U64 (Data (Pos))
      or Interfaces.Shift_Left (U64 (Data (Pos + 1)), 8)
      or Interfaces.Shift_Left (U64 (Data (Pos + 2)), 16)
      or Interfaces.Shift_Left (U64 (Data (Pos + 3)), 24)
      or Interfaces.Shift_Left (U64 (Data (Pos + 4)), 32)
      or Interfaces.Shift_Left (U64 (Data (Pos + 5)), 40)
      or Interfaces.Shift_Left (U64 (Data (Pos + 6)), 48))
   with
     Pre  => Has (Data, Pos, 7),
     Post => Peek_U56LE'Result <= 16#FF_FFFF_FFFF_FFFF#;

   function Peek_U64BE (Data : Bytes; Pos : Array_Index) return U64 is
     (Interfaces.Shift_Left (U64 (Data (Pos)), 56)
      or Interfaces.Shift_Left (U64 (Data (Pos + 1)), 48)
      or Interfaces.Shift_Left (U64 (Data (Pos + 2)), 40)
      or Interfaces.Shift_Left (U64 (Data (Pos + 3)), 32)
      or Interfaces.Shift_Left (U64 (Data (Pos + 4)), 24)
      or Interfaces.Shift_Left (U64 (Data (Pos + 5)), 16)
      or Interfaces.Shift_Left (U64 (Data (Pos + 6)), 8)
      or U64 (Data (Pos + 7)))
   with Pre => Has (Data, Pos, 8);

   function Peek_U64LE (Data : Bytes; Pos : Array_Index) return U64 is
     (U64 (Data (Pos))
      or Interfaces.Shift_Left (U64 (Data (Pos + 1)), 8)
      or Interfaces.Shift_Left (U64 (Data (Pos + 2)), 16)
      or Interfaces.Shift_Left (U64 (Data (Pos + 3)), 24)
      or Interfaces.Shift_Left (U64 (Data (Pos + 4)), 32)
      or Interfaces.Shift_Left (U64 (Data (Pos + 5)), 40)
      or Interfaces.Shift_Left (U64 (Data (Pos + 6)), 48)
      or Interfaces.Shift_Left (U64 (Data (Pos + 7)), 56))
   with Pre => Has (Data, Pos, 8);

   ----------
   -- Poke --
   ----------

   --  Each poke changes exactly the N elements starting at Pos, and a peek
   --  of the same width and endianness at Pos then returns V (masked to the
   --  width for the 24, 40, 48 and 56 bit forms).

   procedure Poke_U8 (Data : in out Bytes; Pos : Array_Index; V : U8) with
     Inline,
     Pre  => Has (Data, Pos, 1),
     Post => Peek_U8 (Data, Pos) = V and then Same_Outside (Data'Old, Data, Pos, 1);

   procedure Poke_U16BE (Data : in out Bytes; Pos : Array_Index; V : U16) with
     Inline,
     Pre  => Has (Data, Pos, 2),
     Post => Peek_U16BE (Data, Pos) = V
       and then Same_Outside (Data'Old, Data, Pos, 2);

   procedure Poke_U16LE (Data : in out Bytes; Pos : Array_Index; V : U16) with
     Inline,
     Pre  => Has (Data, Pos, 2),
     Post => Peek_U16LE (Data, Pos) = V
       and then Same_Outside (Data'Old, Data, Pos, 2);

   procedure Poke_U24BE (Data : in out Bytes; Pos : Array_Index; V : U32) with
     Inline,
     Pre  => Has (Data, Pos, 3),
     Post => Peek_U24BE (Data, Pos) = (V and 16#FF_FFFF#)
       and then Same_Outside (Data'Old, Data, Pos, 3);

   procedure Poke_U24LE (Data : in out Bytes; Pos : Array_Index; V : U32) with
     Inline,
     Pre  => Has (Data, Pos, 3),
     Post => Peek_U24LE (Data, Pos) = (V and 16#FF_FFFF#)
       and then Same_Outside (Data'Old, Data, Pos, 3);

   procedure Poke_U32BE (Data : in out Bytes; Pos : Array_Index; V : U32) with
     Inline,
     Pre  => Has (Data, Pos, 4),
     Post => Peek_U32BE (Data, Pos) = V
       and then Same_Outside (Data'Old, Data, Pos, 4);

   procedure Poke_U32LE (Data : in out Bytes; Pos : Array_Index; V : U32) with
     Inline,
     Pre  => Has (Data, Pos, 4),
     Post => Peek_U32LE (Data, Pos) = V
       and then Same_Outside (Data'Old, Data, Pos, 4);

   procedure Poke_U40BE (Data : in out Bytes; Pos : Array_Index; V : U64) with
     Inline,
     Pre  => Has (Data, Pos, 5),
     Post => Peek_U40BE (Data, Pos) = (V and 16#FF_FFFF_FFFF#)
       and then Same_Outside (Data'Old, Data, Pos, 5);

   procedure Poke_U40LE (Data : in out Bytes; Pos : Array_Index; V : U64) with
     Inline,
     Pre  => Has (Data, Pos, 5),
     Post => Peek_U40LE (Data, Pos) = (V and 16#FF_FFFF_FFFF#)
       and then Same_Outside (Data'Old, Data, Pos, 5);

   procedure Poke_U48BE (Data : in out Bytes; Pos : Array_Index; V : U64) with
     Inline,
     Pre  => Has (Data, Pos, 6),
     Post => Peek_U48BE (Data, Pos) = (V and 16#FFFF_FFFF_FFFF#)
       and then Same_Outside (Data'Old, Data, Pos, 6);

   procedure Poke_U48LE (Data : in out Bytes; Pos : Array_Index; V : U64) with
     Inline,
     Pre  => Has (Data, Pos, 6),
     Post => Peek_U48LE (Data, Pos) = (V and 16#FFFF_FFFF_FFFF#)
       and then Same_Outside (Data'Old, Data, Pos, 6);

   procedure Poke_U56BE (Data : in out Bytes; Pos : Array_Index; V : U64) with
     Inline,
     Pre  => Has (Data, Pos, 7),
     Post => Peek_U56BE (Data, Pos) = (V and 16#FF_FFFF_FFFF_FFFF#)
       and then Same_Outside (Data'Old, Data, Pos, 7);

   procedure Poke_U56LE (Data : in out Bytes; Pos : Array_Index; V : U64) with
     Inline,
     Pre  => Has (Data, Pos, 7),
     Post => Peek_U56LE (Data, Pos) = (V and 16#FF_FFFF_FFFF_FFFF#)
       and then Same_Outside (Data'Old, Data, Pos, 7);

   procedure Poke_U64BE (Data : in out Bytes; Pos : Array_Index; V : U64) with
     Inline,
     Pre  => Has (Data, Pos, 8),
     Post => Peek_U64BE (Data, Pos) = V
       and then Same_Outside (Data'Old, Data, Pos, 8);

   procedure Poke_U64LE (Data : in out Bytes; Pos : Array_Index; V : U64) with
     Inline,
     Pre  => Has (Data, Pos, 8),
     Post => Peek_U64LE (Data, Pos) = V
       and then Same_Outside (Data'Old, Data, Pos, 8);

end Wuffs.Base.Endian;
