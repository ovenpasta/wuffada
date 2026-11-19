--  Wuffs.Runtime: hand-written, non-SPARK glue that generated code
--  (Wuffs.Std.*) needs and that SPARK cannot express: slice handles (GNAT fat
--  pointers into caller memory) and the base interfaces.  See docs/DESIGN.md,
--  "The SPARK boundary".  There are no loops here, and the only arithmetic is
--  the index offsetting that a slice handle inherently is.
--
--  Slice handle model.  A Wuffs `roslice base.u8` value that generated code
--  must be able to re-assign is an RO_Slice_U8: a fat pointer to the *whole*
--  underlying array object plus the sub-range that the slice covers.  The fat
--  pointer is only ever made (by generated code, with 'Unrestricted_Access)
--  from a whole object whose bounds outlive the handle: an unconstrained
--  formal parameter of the subprogram that holds the handle (its bounds are
--  the caller's) or a library-level object.  Re-slicing never makes a new fat
--  pointer; it only narrows First/Length.  This avoids pointing at the
--  compiler's temporary bounds of a slice expression.

package Wuffs.Runtime with Preelaborate, SPARK_Mode => Off is


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

end Wuffs.Runtime;
