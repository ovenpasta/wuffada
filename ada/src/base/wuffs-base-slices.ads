--  Slice helpers: the methods Wuffs code may call on a `slice T`.
--
--  Wuffs method                        Ada
--  ----------------------------------  ----------------------------------
--  s.length()                          S'Length
--  s.prefix(up_to), s.suffix(up_to)    Prefix_Length, Suffix_Offset
--  (iterate statement)                 Iterate_Total_Advance
--  dst.copy_from_slice!(s: src)        Copy_From_Slice or Copy_Within
--  s.bulk_memset!(byte_value: b)       Bulk_Memset_UN (S, B)
--  s.bulk_load_host_endian!(src: b)    Bulk_Load_Host_Endian_UN (S, B)
--  s.bulk_save_host_endian!(dst: b)    Bulk_Save_Host_Endian_UN (B, S)
--  s.peek_uNNxe(), s.poke_uNNxe!(a)    Wuffs.Base.Endian, Pos => S'First
--
--  C: wuffs_private_impl__slice_u8__*, wuffs_private_impl__bulk_* in
--  wuffs/internal/cgen/base/fundamental-private.h.
--
--  Parameter order: the destination always comes before the source, in
--  every copy, load and save.
--
--  Addressing convention of this package: positions are Array_Index values,
--  Ada indices into the array they come with (not offsets from 'First).
--
--  Overlap.  The C copies are memmoves: destination and source may be
--  overlapping parts of one array, and Wuffs code relies on that (for
--  example std/deflate's history).  Ada passes arrays by reference and
--  SPARK assumes that an `in out` and an `in` array parameter do not
--  overlap.  So every operation that takes two arrays of the same type
--  comes in two forms:
--
--    disjoint arrays                 two parts of one array (memmove)
--    ------------------------------  -----------------------------------
--    Copy_From_Slice                 Copy_Within
--    Bulk_Load_Host_Endian_U8        Bulk_Load_Host_Endian_U8_Within
--    Bulk_Save_Host_Endian_U8        Bulk_Save_Host_Endian_U8_Within
--
--  The left column REQUIRES that its two array actuals share no element;
--  its proof says nothing about a call where they do.  A caller that
--  cannot rule overlap out must use the right column.  The U16, U32 and
--  U64 bulk forms have no second column: their two arrays have different
--  element types and so are never parts of one Ada array.

with Wuffs.Base.Endian;

package Wuffs.Base.Slices with Pure, SPARK_Mode is

   pragma Assertion_Policy (Post => Ignore);

   use type Interfaces.Unsigned_8;
   use type Interfaces.Unsigned_16;
   use type Interfaces.Unsigned_32;
   use type Interfaces.Unsigned_64;

   ---------------------
   -- Prefix / Suffix --
   ---------------------

   --  s.prefix(up_to) is the first Prefix_Length (S'Length, Up_To) elements
   --  of S: all of S if Up_To is at least S'Length, else the first Up_To.
   function Prefix_Length (Length : Index; Up_To : U64) return Index is
     (if U64 (Length) > Up_To then Index (Up_To) else Length);

   --  s.suffix(up_to) is S without its first Suffix_Offset (S'Length,
   --  Up_To) elements: all of S if Up_To is at least S'Length, else the
   --  last Up_To.
   function Suffix_Offset (Length : Index; Up_To : U64) return Index is
     (Length - Prefix_Length (Length, Up_To));

   -------------
   -- Iterate --
   -------------

   --  C: wuffs_private_impl__iterate_total_advance, for the Wuffs `iterate`
   --  statement.  A slice of Total_Length elements is visited in sub-slices
   --  of Iter_Length elements placed Iter_Advance apart (they overlap if
   --  Iter_Advance < Iter_Length).  The result is the offset at which
   --  iteration stops: the first multiple of Iter_Advance whose sub-slice
   --  would not fit.  For example (15, 5, 3) gives 12 and (15, 5, 5) gives
   --  15.
   function Iterate_Total_Advance
     (Total_Length, Iter_Length, Iter_Advance : Index) return Index
   is
     (if Total_Length >= Iter_Length
      then (Total_Length - Iter_Length)
           - (Total_Length - Iter_Length) mod Iter_Advance + Iter_Advance
      else 0)
   with
     Pre  => Iter_Advance >= 1 and then Iter_Advance <= Iter_Length,
     Post => Iterate_Total_Advance'Result <= Total_Length
       and then Iterate_Total_Advance'Result mod Iter_Advance = 0;

   ----------
   -- Copy --
   ----------

   --  Copies the first N elements of Src to the start of Dst, where N is
   --  the smaller of the two lengths.
   --
   --  DISJOINT ONLY: Dst and Src must not share any element.  For two
   --  parts of one array use Copy_Within.
   procedure Copy_From_Slice (Dst : in out Bytes; Src : Bytes; N : out U64) with
     Post => N = U64 (Offset'Min (Dst'Length, Src'Length))
       and then (for all J in Dst'Range =>
                   (if U64 (J - Dst'First) < N
                    then Dst (J) = Src (Src'First + (J - Dst'First))
                    else Dst (J) = Dst'Old (J)));

   --  True if Data (First .. First + Length - 1) exists or is empty.  First
   --  is an Ada index into Data.
   function In_Data
     (Data : Bytes; First : Array_Index; Length : Element_Count) return Boolean
   is (Length = 0 or else Endian.Has (Data, First, Length));

   --  Copy_From_Slice where destination and source are both parts of Data:
   --  Dst is Data (Dst_First .. Dst_First + Dst_Length - 1) and Src is
   --  Data (Src_First .. Src_First + Src_Length - 1).  They may overlap in
   --  any way; the N elements copied are the source values from before the
   --  call (memmove).
   --
   --  Dst_First and Src_First are Ada indices into Data, not offsets from
   --  Data'First.  Destination first, then source; each as (first, length).
   --  Named association is recommended at call sites.
   procedure Copy_Within
     (Data       : in out Bytes;
      Dst_First  : Array_Index;
      Dst_Length : Element_Count;
      Src_First  : Array_Index;
      Src_Length : Element_Count;
      N          : out U64)
   with
     Pre  => In_Data (Data, Dst_First, Dst_Length)
       and then In_Data (Data, Src_First, Src_Length),
     Post => N = U64 (Index'Min (Dst_Length, Src_Length))
       and then (for all J in Data'Range =>
                   (if J >= Dst_First and then U64 (J - Dst_First) < N
                    then Data (J) = Data'Old (Src_First + (J - Dst_First))
                    else Data (J) = Data'Old (J)));

   -----------------
   -- Bulk_Memset --
   -----------------

   --  Sets every byte of every element of Dst to Byte_Value.

   function Repeat_U16 (B : U8) return U16 is (U16 (B) * 16#0101#);
   function Repeat_U32 (B : U8) return U32 is (U32 (B) * 16#0101_0101#);
   function Repeat_U64 (B : U8) return U64 is (U64 (B) * 16#0101_0101_0101_0101#);

   procedure Bulk_Memset_U8 (Dst : in out Bytes; Byte_Value : U8) with
     Post => (for all J in Dst'Range => Dst (J) = Byte_Value);

   procedure Bulk_Memset_U16 (Dst : in out U16_Array; Byte_Value : U8) with
     Post => (for all J in Dst'Range => Dst (J) = Repeat_U16 (Byte_Value));

   procedure Bulk_Memset_U32 (Dst : in out U32_Array; Byte_Value : U8) with
     Post => (for all J in Dst'Range => Dst (J) = Repeat_U32 (Byte_Value));

   procedure Bulk_Memset_U64 (Dst : in out U64_Array; Byte_Value : U8) with
     Post => (for all J in Dst'Range => Dst (J) = Repeat_U64 (Byte_Value));

   -------------------------------------
   -- Bulk load / save, host endian   --
   -------------------------------------

   --  Bulk_Load_Host_Endian_UN (Dst, Src) fills all of the element array
   --  Dst from the first Dst'Length * (N / 8) bytes of Src, each element
   --  read in the byte order of the machine.  Bulk_Save_Host_Endian_UN
   --  (Dst, Src) is the reverse: all of the element array Src written to
   --  the start of the byte array Dst.  In both, as everywhere in this
   --  package, the destination is the first parameter.  (In Wuffs the
   --  element slice is the receiver of both methods, so for a save the
   --  receiver is the second argument here.)
   --
   --  As in C, if the element array is empty, or the byte array is too
   --  short for all of it, nothing is copied at all.

   --  True if the machine stores the least significant byte first.  This
   --  is a function with a hidden body, not a constant, so that GNATprove
   --  proves the code below for both byte orders rather than only for the
   --  one of the machine that happens to run the proof.
   function Host_Is_Little_Endian return Boolean with Inline;

   function Host_U16 (Data : Bytes; Pos : Index) return U16 is
     (if Host_Is_Little_Endian
      then Endian.Peek_U16LE (Data, Pos) else Endian.Peek_U16BE (Data, Pos))
   with Pre => Endian.Has (Data, Pos, 2);

   function Host_U32 (Data : Bytes; Pos : Index) return U32 is
     (if Host_Is_Little_Endian
      then Endian.Peek_U32LE (Data, Pos) else Endian.Peek_U32BE (Data, Pos))
   with Pre => Endian.Has (Data, Pos, 4);

   function Host_U64 (Data : Bytes; Pos : Index) return U64 is
     (if Host_Is_Little_Endian
      then Endian.Peek_U64LE (Data, Pos) else Endian.Peek_U64BE (Data, Pos))
   with Pre => Endian.Has (Data, Pos, 8);

   --  True if Count elements of Size bytes each are at least one element
   --  and fit in Bytes_Length bytes: the C test `len && (len <= s.len)`.
   function Bulk_Fits (Count : Offset; Size : Index; Bytes_Length : Offset) return Boolean is
     (Count > 0 and then Count <= Bytes_Length / Size)
   with Pre => Count >= 0 and then Bytes_Length >= 0 and then Size in 1 .. 8;

   --  DISJOINT ONLY: Dst and Src must not share any element.  For two
   --  parts of one array use Bulk_Load_Host_Endian_U8_Within.
   procedure Bulk_Load_Host_Endian_U8 (Dst : in out Bytes; Src : Bytes) with
     Post => (for all J in Dst'Range =>
                (if Bulk_Fits (Dst'Length, 1, Src'Length)
                 then Dst (J) = Src (Src'First + (J - Dst'First))
                 else Dst (J) = Dst'Old (J)));

   --  DISJOINT ONLY: Dst and Src must not share any element.  For two
   --  parts of one array use Bulk_Save_Host_Endian_U8_Within.
   procedure Bulk_Save_Host_Endian_U8 (Dst : in out Bytes; Src : Bytes) with
     Post => (for all J in Dst'Range =>
                (if Bulk_Fits (Src'Length, 1, Dst'Length)
                   and then J - Dst'First < Src'Length
                 then Dst (J) = Src (Src'First + (J - Dst'First))
                 else Dst (J) = Dst'Old (J)));

   --  The two U8 forms for an element slice and a byte slice that are both
   --  parts of Data (memmove semantics for any overlap).  Positions are Ada
   --  indices into Data; destination first, each as (first, length).
   --
   --  Load: the receiver (element slice) is the destination.  All
   --  Dst_Length bytes are copied if Dst_Length is not zero and at most
   --  Src_Length; otherwise nothing is.
   procedure Bulk_Load_Host_Endian_U8_Within
     (Data       : in out Bytes;
      Dst_First  : Array_Index;
      Dst_Length : Element_Count;
      Src_First  : Array_Index;
      Src_Length : Element_Count)
   with
     Pre  => In_Data (Data, Dst_First, Dst_Length)
       and then In_Data (Data, Src_First, Src_Length),
     Post => (for all J in Data'Range =>
                (if Bulk_Fits (Dst_Length, 1, Src_Length)
                   and then J >= Dst_First and then J - Dst_First < Dst_Length
                 then Data (J) = Data'Old (Src_First + (J - Dst_First))
                 else Data (J) = Data'Old (J)));

   --  Save: the receiver (element slice) is the source.  All Src_Length
   --  bytes are copied if Src_Length is not zero and at most Dst_Length;
   --  otherwise nothing is.
   procedure Bulk_Save_Host_Endian_U8_Within
     (Data       : in out Bytes;
      Dst_First  : Array_Index;
      Dst_Length : Element_Count;
      Src_First  : Array_Index;
      Src_Length : Element_Count)
   with
     Pre  => In_Data (Data, Dst_First, Dst_Length)
       and then In_Data (Data, Src_First, Src_Length),
     Post => (for all J in Data'Range =>
                (if Bulk_Fits (Src_Length, 1, Dst_Length)
                   and then J >= Dst_First and then J - Dst_First < Src_Length
                 then Data (J) = Data'Old (Src_First + (J - Dst_First))
                 else Data (J) = Data'Old (J)));

   procedure Bulk_Load_Host_Endian_U16 (Dst : in out U16_Array; Src : Bytes) with
     Post => (for all J in Dst'Range =>
                (if Bulk_Fits (Dst'Length, 2, Src'Length)
                 then Dst (J) = Host_U16 (Src, Src'First + 2 * (J - Dst'First))
                 else Dst (J) = Dst'Old (J)));

   procedure Bulk_Save_Host_Endian_U16 (Dst : in out Bytes; Src : U16_Array) with
     Post => (if Bulk_Fits (Src'Length, 2, Dst'Length)
              then (for all J in Src'Range =>
                      Host_U16 (Dst, Dst'First + 2 * (J - Src'First)) = Src (J))
                and then (for all J in Dst'Range =>
                            (if J - Dst'First >= 2 * Src'Length then Dst (J) = Dst'Old (J)))
              else (for all J in Dst'Range => Dst (J) = Dst'Old (J)));

   procedure Bulk_Load_Host_Endian_U32 (Dst : in out U32_Array; Src : Bytes) with
     Post => (for all J in Dst'Range =>
                (if Bulk_Fits (Dst'Length, 4, Src'Length)
                 then Dst (J) = Host_U32 (Src, Src'First + 4 * (J - Dst'First))
                 else Dst (J) = Dst'Old (J)));

   procedure Bulk_Save_Host_Endian_U32 (Dst : in out Bytes; Src : U32_Array) with
     Post => (if Bulk_Fits (Src'Length, 4, Dst'Length)
              then (for all J in Src'Range =>
                      Host_U32 (Dst, Dst'First + 4 * (J - Src'First)) = Src (J))
                and then (for all J in Dst'Range =>
                            (if J - Dst'First >= 4 * Src'Length then Dst (J) = Dst'Old (J)))
              else (for all J in Dst'Range => Dst (J) = Dst'Old (J)));

   procedure Bulk_Load_Host_Endian_U64 (Dst : in out U64_Array; Src : Bytes) with
     Post => (for all J in Dst'Range =>
                (if Bulk_Fits (Dst'Length, 8, Src'Length)
                 then Dst (J) = Host_U64 (Src, Src'First + 8 * (J - Dst'First))
                 else Dst (J) = Dst'Old (J)));

   procedure Bulk_Save_Host_Endian_U64 (Dst : in out Bytes; Src : U64_Array) with
     Post => (if Bulk_Fits (Src'Length, 8, Dst'Length)
              then (for all J in Src'Range =>
                      Host_U64 (Dst, Dst'First + 8 * (J - Src'First)) = Src (J))
                and then (for all J in Dst'Range =>
                            (if J - Dst'First >= 8 * Src'Length then Dst (J) = Dst'Old (J)))
              else (for all J in Dst'Range => Dst (J) = Dst'Old (J)));

end Wuffs.Base.Slices;
