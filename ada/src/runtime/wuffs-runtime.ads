--  Wuffs.Runtime: hand-written, non-SPARK glue that generated code
--  (Wuffs.Std.*) needs and that SPARK cannot express.  See docs/DESIGN.md,
--  "The SPARK boundary".  It computes nothing itself: every operation here
--  either hands out a view of caller memory or decides which proved
--  Wuffs.Base subprogram to call.  The only arithmetic is index offsetting
--  (what a slice handle inherently is) and the address comparison of the
--  aliasing decision below.
--
--  1. Slice handles
--  ----------------
--  A Wuffs `slice base.u8` / `roslice base.u8` value that generated code
--  must be able to re-assign is a Slice_U8 / RO_Slice_U8: a fat pointer to
--  the *whole* underlying array object plus the sub-range that the slice
--  covers.  Generated code makes the fat pointer, with 'Unrestricted_Access,
--  only from a whole object whose bounds outlive the handle:
--
--    * an unconstrained formal parameter of the subprogram that holds the
--      handle (its bounds are the caller's, alive for the whole call), or
--    * a constrained array (a record component, a constant, a local
--      variable), whose bounds are static, so GNAT points the fat pointer
--      at a bounds template in read-only data.
--
--  Re-slicing never makes a new fat pointer; it only narrows First/Length.
--  That avoids pointing at the compiler's temporary bounds of an Ada slice
--  expression.  Handles are never stored in a decoder record: like the C
--  back-end (which does not save pointer-typed locals), a slice variable is
--  empty again when a coroutine resumes.
--
--  2. The aliasing decision
--  ------------------------
--  The proved base library has two forms of every operation on two byte
--  arrays (docs/DESIGN.md; wuffs-base-slices.ads, wuffs-base-io.ads):
--  a "DISJOINT ONLY" form whose two array parameters must not share any
--  element, and a `_Within` form (memmove semantics) for two parts of one
--  array.  Wuffs code may pass either, and only the run-time values tell
--  which.  The four procedures in "Two-array operations" below make that
--  decision, in exactly one way:
--
--    The two operands share an element if and only if both are non-empty
--    and their address ranges [address of first element, that plus length)
--    intersect.  (Wuffs.Bytes elements are one storage unit each.)
--
--    * No shared element: call the disjoint form.  Its requirement is
--      precisely "no shared element", so this is right whether or not the
--      two views belong to one larger object.
--    * A shared element: the two views necessarily lie in one object and
--      their union is one contiguous run of that object.  Overlay a
--      Wuffs.Bytes on that union (lowest first address to highest end
--      address) and call the `_Within` form with each operand's offset in
--      it.  This covers identical views, nested views and views that only
--      partially overlap.
--
--  The decision is made on the whole arrays passed, not on the part that
--  the operation ends up touching: whenever the disjoint form is called
--  its precondition holds as stated.

with System;
with Wuffs.Base.Ints;
with Wuffs.Base.IO;
with Wuffs.Base.Ranges;
with Wuffs.Base.Slices;

package Wuffs.Runtime with Preelaborate, SPARK_Mode => Off is

   --  (Wuffs `base.utility.cpu_arch_is_32_bit()` is in Wuffs.Runtime.Target.)

   ---------------------------------------------------------------------------
   --  Initialization state of generated structs (C: WUFFS_BASE__MAGIC and
   --  WUFFS_BASE__DISABLED in fundamental-private.h).
   ---------------------------------------------------------------------------

   Magic_Uninitialized : constant Wuffs.U32 := 0;
   Magic_Initialized   : constant Wuffs.U32 := 16#3CCB_6C71#;
   Magic_Disabled      : constant Wuffs.U32 := 16#075A_E3D2#;

   ---------------------------------------------------------------------------
   --  Read-only byte slices.
   ---------------------------------------------------------------------------

   type Bytes_Constant_Access is access constant Wuffs.Bytes;

   Empty_Bytes : aliased constant Wuffs.Bytes := [1 .. 0 => 0];

   type RO_Slice_U8 is record
      Base   : not null Bytes_Constant_Access := Empty_Bytes'Access;
      First  : Wuffs.Index := 1;  --  Index in Base.all of the slice's element 0.
      Length : Wuffs.Index := 0;
   end record;

   --  The index in S.Base.all of the last element; First - 1 if S is empty.
   function Last (S : RO_Slice_U8) return Wuffs.Offset is (S.First + S.Length - 1)
   with Inline;

   --  Wuffs `s[i]`.  Checked against the slice's own range, not merely
   --  against the underlying array.
   function Get (S : RO_Slice_U8; I : Wuffs.Index) return Wuffs.U8
   is (S.Base (S.First .. Last (S)) (S.First + I))
   with Inline;

   --  Wuffs `s[i .. j]`, `s[i ..]` and `s[.. j]`.
   function Subslice_IJ (S : RO_Slice_U8; I, J : Wuffs.Index) return RO_Slice_U8
   is (Base => S.Base, First => S.First + I, Length => J - I)
   with Inline, Pre => I <= J and then J <= S.Length;

   function Subslice_I (S : RO_Slice_U8; I : Wuffs.Index) return RO_Slice_U8
   is (Base => S.Base, First => S.First + I, Length => S.Length - I)
   with Inline, Pre => I <= S.Length;

   function Subslice_J (S : RO_Slice_U8; J : Wuffs.Index) return RO_Slice_U8
   is (Base => S.Base, First => S.First, Length => J)
   with Inline, Pre => J <= S.Length;

   --  Wuffs `s.suffix(up_to: n)`.
   function Suffix (S : RO_Slice_U8; Up_To : Wuffs.U64) return RO_Slice_U8
   is (Subslice_I (S, Wuffs.Base.Slices.Suffix_Offset (Length => S.Length, Up_To => Up_To)))
   with Inline;

   ---------------------------------------------------------------------------
   --  Writable byte slices.
   ---------------------------------------------------------------------------

   type Bytes_Access is access all Wuffs.Bytes;

   --  What an empty writable slice points at.  It has no elements, so
   --  nothing is ever read from or written to it.
   Empty_Bytes_Variable : aliased Wuffs.Bytes := [1 .. 0 => 0];

   type Slice_U8 is record
      Base   : not null Bytes_Access := Empty_Bytes_Variable'Access;
      First  : Wuffs.Index := 1;
      Length : Wuffs.Index := 0;
   end record;

   function Last (S : Slice_U8) return Wuffs.Offset is (S.First + S.Length - 1)
   with Inline;

   function Get (S : Slice_U8; I : Wuffs.Index) return Wuffs.U8
   is (S.Base (S.First .. Last (S)) (S.First + I))
   with Inline;

   --  Wuffs `s[i] = v`.
   procedure Set (S : Slice_U8; I : Wuffs.Index; V : Wuffs.U8)
   with Inline, Pre => I < S.Length;

   function Subslice_IJ (S : Slice_U8; I, J : Wuffs.Index) return Slice_U8
   is (Base => S.Base, First => S.First + I, Length => J - I)
   with Inline, Pre => I <= J and then J <= S.Length;

   function Subslice_I (S : Slice_U8; I : Wuffs.Index) return Slice_U8
   is (Base => S.Base, First => S.First + I, Length => S.Length - I)
   with Inline, Pre => I <= S.Length;

   function Subslice_J (S : Slice_U8; J : Wuffs.Index) return Slice_U8
   is (Base => S.Base, First => S.First, Length => J)
   with Inline, Pre => J <= S.Length;

   function Suffix (S : Slice_U8; Up_To : Wuffs.U64) return Slice_U8
   is (Subslice_I (S, Wuffs.Base.Slices.Suffix_Offset (Length => S.Length, Up_To => Up_To)))
   with Inline;

   --  A writable slice used where Wuffs wants a read-only one.
   function To_RO (S : Slice_U8) return RO_Slice_U8
   is (Base => Bytes_Constant_Access (S.Base), First => S.First, Length => S.Length)
   with Inline;

   ---------------------------------------------------------------------------
   --  I/O buffers.
   --
   --  An io_reader or io_writer argument of a Wuffs function is two Ada
   --  parameters: the caller's byte array and its Wuffs.Base.IO.Buffer_Meta.
   --  Nothing is held across calls.
   ---------------------------------------------------------------------------

   --  What a public function checks before it trusts a caller's buffer
   --  (where C checks only that the io_buffer pointer is not NULL).
   --
   --  The check is total: it holds only if every field of M has a value of
   --  its subtype ('Valid, which is evaluated in every profile, also under
   --  -gnatp, where nothing else enforces a subtype's range), the indexes
   --  are ordered and they lie within the array.  After it, the cursor that
   --  Wuffs.Base.IO.To_Reader or To_Writer makes from M satisfies
   --  Wuffs.Base.IO.Valid for Data.  A caller's M with, say, a negative read
   --  index is therefore refused (the function returns "bad argument"), in
   --  the release profile too.
   function Valid_Buffer (Data : Wuffs.Bytes; M : Wuffs.Base.IO.Buffer_Meta) return Boolean
   is (M.Ri'Valid
       and then M.Wi'Valid
       and then M.Closed'Valid
       and then M.Ri <= M.Wi
       and then M.Wi <= Data'Length)
   with Inline;

   --  Wuffs `r.since(mark: m)` and `w.since(mark: m)` are
   --  Data (Since_First (...) .. Since_Last (...)).
   function Since_First
     (Data : Wuffs.Bytes; R : Wuffs.Base.IO.Reader; Mark : Wuffs.U64) return Wuffs.Index
   is (Data'First + Wuffs.Base.IO.Since_Offset (R, Mark))
   with Inline;

   function Since_Last
     (Data : Wuffs.Bytes; R : Wuffs.Base.IO.Reader; Mark : Wuffs.U64) return Wuffs.Offset
   is (Since_First (Data, R, Mark) + Wuffs.Base.IO.Since_Length (R, Mark) - 1)
   with Inline;

   function Since_First
     (Data : Wuffs.Bytes; W : Wuffs.Base.IO.Writer; Mark : Wuffs.U64) return Wuffs.Index
   is (Data'First + Wuffs.Base.IO.Since_Offset (W, Mark))
   with Inline;

   function Since_Last
     (Data : Wuffs.Bytes; W : Wuffs.Base.IO.Writer; Mark : Wuffs.U64) return Wuffs.Offset
   is (Since_First (Data, W, Mark) + Wuffs.Base.IO.Since_Length (W, Mark) - 1)
   with Inline;

   ---------------------------------------------------------------------------
   --  Two-array operations.  See "The aliasing decision" above.
   ---------------------------------------------------------------------------

   --  True if A and B have an element in common.
   function Share_An_Element (A, B : Wuffs.Bytes) return Boolean;

   --  Wuffs `dst.copy_from_slice!(s: src)` on slices.
   --  Base: Slices.Copy_From_Slice or Slices.Copy_Within.
   procedure Copy_From_Slice (Dst : in out Wuffs.Bytes; Src : Wuffs.Bytes; N : out Wuffs.U64);

   --  Wuffs `w.copy_from_slice!(s: src)` on an io_writer.
   --  Base: IO.Copy_From_Slice or IO.Copy_From_Slice_Within.
   procedure Writer_Copy_From_Slice
     (Data : in out Wuffs.Bytes;
      W    : in out Wuffs.Base.IO.Writer;
      Src  : Wuffs.Bytes;
      N    : out Wuffs.U64)
   with Pre => Wuffs.Base.IO.Valid (Data, W);

   --  Wuffs `w.limited_copy_u32_from_slice!(up_to: n, s: src)`.
   --  Base: IO.Limited_Copy_U32_From_Slice or its _Within form.
   procedure Writer_Limited_Copy_U32_From_Slice
     (Data  : in out Wuffs.Bytes;
      W     : in out Wuffs.Base.IO.Writer;
      Up_To : Wuffs.U32;
      Src   : Wuffs.Bytes;
      N     : out Wuffs.U32)
   with Pre => Wuffs.Base.IO.Valid (Data, W);

   --  Wuffs `w.limited_copy_u32_from_reader!(up_to: n, r: r)`.
   --  Base: IO.Limited_Copy_U32_From_Reader or its _Within form.
   procedure Writer_Limited_Copy_U32_From_Reader
     (Data     : in out Wuffs.Bytes;
      W        : in out Wuffs.Base.IO.Writer;
      Up_To    : Wuffs.U32;
      Src_Data : Wuffs.Bytes;
      R        : in out Wuffs.Base.IO.Reader;
      N        : out Wuffs.U32)
   with Pre => Wuffs.Base.IO.Valid (Data, W) and then Wuffs.Base.IO.Valid (Src_Data, R);

   ---------------------------------------------------------------------------
   --  Wuffs `base.hasher_u32`.
   ---------------------------------------------------------------------------

   type Hasher_U32 is limited interface;

   function Checksum_U32 (Self : Hasher_U32) return Wuffs.U32 is abstract;

   function Get_Quirk (Self : Hasher_U32; A_Key : Wuffs.U32) return Wuffs.U64 is abstract;

   function Set_Quirk
     (Self : in out Hasher_U32; A_Key : Wuffs.U32; A_Value : Wuffs.U64) return Wuffs.Status
   is abstract;

   procedure Update (Self : in out Hasher_U32; A_X : Wuffs.Bytes) is abstract;

   function Update_U32 (Self : in out Hasher_U32; A_X : Wuffs.Bytes) return Wuffs.U32
   is abstract;

   ---------------------------------------------------------------------------
   --  Wuffs `base.io_transformer`.
   ---------------------------------------------------------------------------

   type IO_Transformer is limited interface;

   function Dst_History_Retain_Length
     (Self : IO_Transformer) return Wuffs.Base.Ints.Optional_U63
   is abstract;

   function Get_Quirk (Self : IO_Transformer; A_Key : Wuffs.U32) return Wuffs.U64 is abstract;

   function Set_Quirk
     (Self : in out IO_Transformer; A_Key : Wuffs.U32; A_Value : Wuffs.U64) return Wuffs.Status
   is abstract;

   --  A_Dst (A_Dst'First .. A_Dst'First + A_Dst_Meta.Wi - 1) holds what has
   --  been written and A_Src (A_Src'First + A_Src_Meta.Ri .. A_Src'First +
   --  A_Src_Meta.Wi - 1) what is still to be read, as in C's
   --  wuffs_base__io_buffer.  Returns a suspension ("short read", "short
   --  write") to be called again with more input or more room.
   function Transform_Io
     (Self        : in out IO_Transformer;
      A_Dst       : in out Wuffs.Bytes;
      A_Dst_Meta  : in out Wuffs.Base.IO.Buffer_Meta;
      A_Src       : Wuffs.Bytes;
      A_Src_Meta  : in out Wuffs.Base.IO.Buffer_Meta;
      A_Workbuf   : in out Wuffs.Bytes) return Wuffs.Status
   is abstract;

   function Workbuf_Len (Self : IO_Transformer) return Wuffs.Base.Ranges.Range_II_U64
   is abstract;

private

   --  The address of the first element of a non-empty A.
   function First_Address (A : Wuffs.Bytes) return System.Address is (A (A'First)'Address)
   with Pre => A'Length > 0;

end Wuffs.Runtime;
