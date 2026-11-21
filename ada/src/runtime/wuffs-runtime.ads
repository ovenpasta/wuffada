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
with Wuffs.Base.Pixel_Buffers;
with Wuffs.Base.Pixel_Formats;
with Wuffs.Base.Pixel_Swizzler;
with Wuffs.Base.Ranges;
with Wuffs.Base.Slices;
with Wuffs.Base.Tokens;

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

   --  Wuffs `s.uintptr_low_12_bits()`: the low 12 bits of the address of
   --  S's first element (of where it would be, if S is empty).  C:
   --  0xFFF & (uintptr_t)(s.ptr).  Only an alignment decision depends on it
   --  (std/crc32 and std/crc64's SIMD implementations), never a result.
   function Uintptr_Low_12_Bits (S : Wuffs.Bytes) return Wuffs.U32;

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
   --  Token buffers.
   --
   --  A token_writer argument of a Wuffs function is two Ada parameters, as
   --  an io_writer is: the caller's array of tokens (a Wuffs.U64_Array; a
   --  token is a U64, see wuffs-base-tokens.ads) and its
   --  Wuffs.Base.Tokens.Token_Buffer_Meta.  Nothing is held across calls.
   --
   --  At every public entry (also when a suspended coroutine is resumed,
   --  whose arguments may differ from the suspended call's), before
   --  anything else reads or writes an argument, in every profile:
   --
   --    * the meta describes the array: Valid_Token_Buffer below;
   --    * the token array shares no storage with the object that the
   --      function is called on (Shares_Storage, the U64_Array form);
   --    * the token array shares no storage with any byte array argument
   --      (the source buffer, the work buffer, a slice):
   --      Tokens_Share_Storage.
   --
   --  The last is stricter than C, which leaves overlapping buffers to the
   --  caller.  Between two byte arrays an overlap is dealt with at each
   --  two-array operation (the aliasing decision above), but an array of
   --  tokens and an array of bytes are never parts of one Ada array, so
   --  there is no same-array form to call, and the Ada compiler may assume
   --  that objects of the two element types do not overlap (as it may for
   --  the bulk loads and saves below).  No proved operation is given a
   --  token array and a byte array in one call, so this is not needed for
   --  the proofs; it makes the decoders' results well defined, the same in
   --  both profiles and the same as C's for every caller that is accepted.
   --
   --  Whatever fails, the function returns Wuffs.Base.Error_Bad_Argument
   --  and disables the object, as for the other arguments (see "Arguments"
   --  below).
   ---------------------------------------------------------------------------

   --  The token counterpart of Valid_Buffer: every field of M has a value
   --  of its subtype ('Valid), the indexes are ordered and they lie within
   --  the array.  After it, the cursor that Wuffs.Base.Tokens.To_Writer
   --  makes from M satisfies Wuffs.Base.Tokens.Valid for Data.
   function Valid_Token_Buffer
     (Data : Wuffs.U64_Array; M : Wuffs.Base.Tokens.Token_Buffer_Meta) return Boolean
   is (M.Ri'Valid
       and then M.Wi'Valid
       and then M.Closed'Valid
       and then M.Ri <= M.Wi
       and then M.Wi <= Data'Length)
   with Inline;

   --  True if the array of tokens Tokens and the byte array B have a
   --  storage element in common: both are non-empty and their address
   --  ranges intersect, each range being [address of the first element,
   --  that plus the array's length times its elements' size in storage
   --  elements).  That is decided by address, whatever the element types.
   function Tokens_Share_Storage (Tokens : Wuffs.U64_Array; B : Wuffs.Bytes) return Boolean;

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
   --  Pixel buffers and the pixel swizzler.
   --
   --  A `ptr base.pixel_buffer` argument of a Wuffs function is three Ada
   --  parameters: the Wuffs.Base.Pixel_Buffers.Pixel_Buffer descriptor and
   --  the two arrays that it describes, Pixels (plane 0) and Palette (plane
   --  3; see the model in wuffs-base-pixel_buffers.ads).
   --
   --  Arguments: what every public function of a generated package checks
   --  first (after looking at Magic, to see that the object is initialized
   --  and not disabled), before it reads or writes anything else, at every
   --  call (also
   --  when the call resumes a suspended coroutine, whose arguments may
   --  differ from those of the call that was suspended).  Whatever fails,
   --  the function returns Wuffs.Base.Error_Bad_Argument (or, if it does not
   --  return a status, zero or nothing) and disables the object: its Magic
   --  component, and nothing else in it, is written, and every later call
   --  returns "disabled by previous error" until Initialize.  (A function
   --  that cannot change its object returns zero and leaves it as it is.)
   --  The same in every profile.
   --
   --  a. Every Boolean argument holds False or True ('Valid): the "null"
   --     flags of the nullable pointers, and Wuffs bool arguments.
   --  b. NO array argument, written or only read (a source or destination
   --     buffer, a work buffer, a slice, pixels, a palette) shares storage
   --     with the object that the function is called on (Shares_Storage,
   --     with the object's 'Address and 'Size).  Otherwise the function
   --     would overwrite its own state through the array, or the caller's
   --     data through its state.
   --  c. Every I/O buffer's meta describes its array (Valid_Buffer).
   --  d. A pixel buffer is valid for its two arrays (Valid_Pixel_Buffer),
   --     and Pixels and Palette, the two arrays that pixel operations
   --     write, are each apart from each other and from every other array
   --     argument (the source buffer, the work buffer, another pixel
   --     buffer's arrays).
   --  e. Every argument of a refined type (base.u32[..= 9]) is in range.
   --
   --  A nullable pixel buffer (`nptr base.pixel_buffer`) is four Ada
   --  parameters: the descriptor, a Boolean that says that the Wuffs pointer
   --  is null, then the two arrays.  The Boolean is checked under (a).  If
   --  it is False, the descriptor and arrays are checked as under (b) and
   --  (d); if it is True, they are not looked at, here or later (generated
   --  code reaches them only through method calls, which the Wuffs compiler
   --  proves are made on a pointer that is not null, and which assert it),
   --  as C does not dereference a NULL pointer.  Generated code passes a
   --  literal nullptr as Null_Pixel_Buffer, True and two empty arrays of its
   --  own.
   --
   --  f. A token array (a token_writer argument) shares no storage with any
   --     byte array argument, and its meta describes it: see "Token
   --     buffers" above.
   --
   --  Overlap between array arguments other than under (d) and (f) is NOT
   --  an error at entry: a destination buffer, a source buffer and a work
   --  buffer may share elements with each other (as upstream's C allows).
   --  It is dealt with at each operation that takes two arrays, in this
   --  package:
   --
   --     Copy_From_Slice, Writer_Copy_From_Slice,
   --     Writer_Limited_Copy_U32_From_Slice,
   --     Writer_Limited_Copy_U32_From_Reader,
   --     Reader_Limited_Copy_U32_To_Slice,
   --     Bulk_Load_Host_Endian_U8, Bulk_Save_Host_Endian_U8
   --        look at the addresses and call the proved operation's form for
   --        disjoint arrays or its _Within form (memmove semantics);
   --     Bulk_Load_Host_Endian_U16/U32/U64, Bulk_Save_Host_Endian_U16/U32/U64
   --        have no _Within form (an array of wider numbers and an array of
   --        bytes are never parts of one Ada array): they do nothing if the
   --        two arrays share storage, which Wuffs code cannot bring about
   --        (see there);
   --     Swizzler_Prepare, Swizzle_Interleaved_From_Slice,
   --     Swizzle_Interleaved_From_Reader,
   --     Limited_Swizzle_U32_Interleaved_From_Reader,
   --     Swizzle_Interleaved_Transparent_Black, Swizzle_YCCK
   --        have no _Within form: they do nothing if an array that they
   --        write shares an element with one that they read, or (for
   --        Swizzle_YCCK, which writes two) with the other (see below).
   --
   --  Generated code calls no other operation of the proved libraries with
   --  two arrays (copies within one array use Wuffs.Base.Slices.Copy_Within
   --  or the writer's history copies), and reads and writes of single
   --  elements are in program order whatever overlaps.
   --
   --  Aliasing of pixel operations (docs/DESIGN.md).  The proved pixel
   --  operations have no same-array forms: the array that an operation
   --  WRITES must not share an element with any array that it reads.  That
   --  is enforced in two places:
   --
   --  1. At every public entry that takes a pixel buffer: (d) above, and
   --     (b) for the decoder object itself.
   --
   --  2. In each operation below, again, for its own operands: this is what
   --     makes the proved code's requirement hold whatever generated code
   --     passes.  An operation whose written array shares an element with
   --     one that it reads does nothing: Prepare returns
   --     Wuffs.Base.Error_Bad_Argument, and a swizzle converts no pixels
   --     (N = 0).  With the entry check in place this cannot happen for the
   --     decoders of Wuffs' standard library, whose swizzles write the
   --     caller's pixel memory and read decoder state, the source buffer or
   --     the work buffer.
   --
   --  Arrays that are only read may overlap each other (std/bmp passes
   --  parts of one array as destination palette and as source of a
   --  swizzle), and nothing here forbids that.
   ---------------------------------------------------------------------------

   --  True if A has an element in the Size_In_Bits bits of storage that
   --  start at Address (a decoder object: Self'Address and Self'Size).
   function Shares_Storage
     (A : Wuffs.Bytes; Address : System.Address; Size_In_Bits : Long_Long_Integer)
      return Boolean;

   --  The same for an array of tokens (see "Token buffers" above): A's
   --  storage is its Length * 8 storage elements from A'Address.
   function Shares_Storage
     (A : Wuffs.U64_Array; Address : System.Address; Size_In_Bits : Long_Long_Integer)
      return Boolean;

   --  The total validation of a caller's pixel buffer: every field of every
   --  plane's table has a value of its subtype (see Valid_Buffer about
   --  'Valid) and the buffer is valid for the two arrays.
   function Valid_Pixel_Buffer
     (PB      : Wuffs.Base.Pixel_Buffers.Pixel_Buffer;
      Pixels  : Wuffs.Bytes;
      Palette : Wuffs.Bytes) return Boolean;

   --  Wuffs `pb.palette()`: the first Palette_Length (PB, Palette) elements
   --  of Palette, which is 1024 or (if PB has no palette, or Palette is too
   --  short for one) none.
   function Palette_Length
     (PB : Wuffs.Base.Pixel_Buffers.Pixel_Buffer; Palette : Wuffs.Bytes) return Wuffs.Index
   is (if Wuffs.Base.Pixel_Buffers.Has_Palette (PB)
         and then Palette'Length >= Wuffs.Base.Pixel_Formats.Palette_Byte_Length
       then Wuffs.Base.Pixel_Formats.Palette_Byte_Length
       else 0)
   with Inline;

   --  Wuffs `swizzler.prepare!(etc)`.  Proved: Pixel_Swizzler.Prepare.
   procedure Swizzler_Prepare
     (S           : out Wuffs.Base.Pixel_Swizzler.Swizzler;
      Dst_Pixfmt  : Wuffs.Base.Pixel_Formats.Pixel_Format;
      Dst_Palette : in out Wuffs.Bytes;
      Src_Pixfmt  : Wuffs.Base.Pixel_Formats.Pixel_Format;
      Src_Palette : Wuffs.Bytes;
      Blend       : Wuffs.Base.Pixel_Formats.Pixel_Blend;
      Result      : out Wuffs.Status);

   --  Wuffs `swizzler.swizzle_interleaved_from_slice!(etc)`.
   procedure Swizzle_Interleaved_From_Slice
     (S           : Wuffs.Base.Pixel_Swizzler.Swizzler;
      Dst         : in out Wuffs.Bytes;
      Dst_Palette : Wuffs.Bytes;
      Src         : Wuffs.Bytes;
      N           : out Wuffs.U64);

   --  Wuffs `swizzler.swizzle_interleaved_from_reader!(etc)`.
   procedure Swizzle_Interleaved_From_Reader
     (S           : Wuffs.Base.Pixel_Swizzler.Swizzler;
      Dst         : in out Wuffs.Bytes;
      Dst_Palette : Wuffs.Bytes;
      Src_Data    : Wuffs.Bytes;
      R           : in out Wuffs.Base.IO.Reader;
      N           : out Wuffs.U64)
   with Pre => Wuffs.Base.IO.Valid (Src_Data, R);

   --  Wuffs `swizzler.limited_swizzle_u32_interleaved_from_reader!(etc)`.
   procedure Limited_Swizzle_U32_Interleaved_From_Reader
     (S                : Wuffs.Base.Pixel_Swizzler.Swizzler;
      Up_To_Num_Pixels : Wuffs.U32;
      Dst              : in out Wuffs.Bytes;
      Dst_Palette      : Wuffs.Bytes;
      Src_Data         : Wuffs.Bytes;
      R                : in out Wuffs.Base.IO.Reader;
      N                : out Wuffs.U64)
   with Pre => Wuffs.Base.IO.Valid (Src_Data, R);

   --  Wuffs `swizzler.swizzle_interleaved_transparent_black!(etc)`.
   procedure Swizzle_Interleaved_Transparent_Black
     (S           : Wuffs.Base.Pixel_Swizzler.Swizzler;
      Dst         : in out Wuffs.Bytes;
      Dst_Palette : Wuffs.Bytes;
      Num_Pixels  : Wuffs.U64;
      N           : out Wuffs.U64);

   --  Wuffs `swizzler.swizzle_ycck!(etc)`.  Proved:
   --  Pixel_Swizzler_YCCK.Swizzle_YCCK, whose Planes are made from the 20
   --  per-plane numbers (WidthK, HeightK, StrideK, HK, VK for plane K).  The
   --  pixel buffer is PB with its two arrays Pixels and Palette, as for any
   --  other pixel buffer argument.  Swizzle_YCCK writes two arrays, Pixels
   --  and Scratch_Buffer_2K; the others (Palette, Dst_Palette, Src0 .. Src3)
   --  are only read and may overlap one another in any way.  Before the
   --  proved code is called, in every profile:
   --
   --    * PB must be valid for Pixels and Palette, its fields checked with
   --      'Valid (Valid_Pixel_Buffer);
   --    * Pixels must share no element with Palette, Dst_Palette, Src0 ..
   --      Src3 or Scratch_Buffer_2K;
   --    * Scratch_Buffer_2K must share no element with Palette, Dst_Palette
   --      or Src0 .. Src3.
   --
   --  If any of that fails, Result is Wuffs.Base.Error_Bad_Argument and
   --  nothing is written.  Otherwise Result is the proved operation's (Ok,
   --  Error_Bad_Argument or Error_Unsupported_Pixel_Swizzler_Option, C's
   --  statuses for C's reasons).  In std/jpeg Pixels is the caller's pixel
   --  memory, the scratch buffer is a field of the decoder and the sources
   --  are parts of the caller's work buffer or of another field of the
   --  decoder, so after the checks at entry (see "Arguments" above) none of
   --  this can fail there.  In std/vp8 likewise: Src0 .. Src2 (the Y, U and
   --  V planes) are parts of the caller's work buffer and Src3 (the alpha
   --  plane, when std/webp has put one there) is the work buffer's first
   --  Width * Height bytes, before them; they may overlap one another (they
   --  do not), but not Pixels (checked at entry) or the scratch buffer (a
   --  field of the decoder).
   procedure Swizzle_YCCK
     (PB                : Wuffs.Base.Pixel_Buffers.Pixel_Buffer;
      Pixels            : in out Wuffs.Bytes;
      Palette           : Wuffs.Bytes;
      Dst_Palette       : Wuffs.Bytes;
      X_Min_Incl        : Wuffs.U32;
      X_Max_Excl        : Wuffs.U32;
      Y_Min_Incl        : Wuffs.U32;
      Y_Max_Excl        : Wuffs.U32;
      Src0              : Wuffs.Bytes;
      Src1              : Wuffs.Bytes;
      Src2              : Wuffs.Bytes;
      Src3              : Wuffs.Bytes;
      Width0            : Wuffs.U32;
      Width1            : Wuffs.U32;
      Width2            : Wuffs.U32;
      Width3            : Wuffs.U32;
      Height0           : Wuffs.U32;
      Height1           : Wuffs.U32;
      Height2           : Wuffs.U32;
      Height3           : Wuffs.U32;
      Stride0           : Wuffs.U32;
      Stride1           : Wuffs.U32;
      Stride2           : Wuffs.U32;
      Stride3           : Wuffs.U32;
      H0                : Wuffs.U8;
      H1                : Wuffs.U8;
      H2                : Wuffs.U8;
      H3                : Wuffs.U8;
      V0                : Wuffs.U8;
      V1                : Wuffs.U8;
      V2                : Wuffs.U8;
      V3                : Wuffs.U8;
      YCC_Model         : Wuffs.U8;
      YCC_Upsampling    : Wuffs.U8;
      Scratch_Buffer_2K : in out Wuffs.Bytes;
      Result            : out Wuffs.Status);

   ---------------------------------------------------------------------------
   --  Bulk loads and saves (Wuffs `s.bulk_load_host_endian!(src: b)` and
   --  `s.bulk_save_host_endian!(dst: b)`; see Wuffs.Base.Slices).  As there,
   --  the destination comes first: for a load the element array, for a
   --  save the byte array.
   --
   --  The U8 forms dispatch on the addresses, as Copy_From_Slice does, to
   --  the proved form for disjoint arrays or to its _Within form.
   --
   --  The U16, U32 and U64 forms have no _Within form.  Wuffs code cannot
   --  make a byte slice and an array of wider numbers share storage: the
   --  element array is a field or a local variable of generated code, the
   --  byte slice is a part of a field, of a local or of a caller's array
   --  argument, and an argument never shares storage with the object that
   --  the function is called on (see "Arguments" above).  These procedures
   --  check it anyway, by address, and copy nothing if the two arrays
   --  share a storage element (the proved code would not apply).
   ---------------------------------------------------------------------------

   procedure Bulk_Load_Host_Endian_U8 (Dst : in out Wuffs.Bytes; Src : Wuffs.Bytes);
   procedure Bulk_Save_Host_Endian_U8 (Dst : in out Wuffs.Bytes; Src : Wuffs.Bytes);
   procedure Bulk_Load_Host_Endian_U16 (Dst : in out Wuffs.U16_Array; Src : Wuffs.Bytes);
   procedure Bulk_Save_Host_Endian_U16 (Dst : in out Wuffs.Bytes; Src : Wuffs.U16_Array);
   procedure Bulk_Load_Host_Endian_U32 (Dst : in out Wuffs.U32_Array; Src : Wuffs.Bytes);
   procedure Bulk_Save_Host_Endian_U32 (Dst : in out Wuffs.Bytes; Src : Wuffs.U32_Array);
   procedure Bulk_Load_Host_Endian_U64 (Dst : in out Wuffs.U64_Array; Src : Wuffs.Bytes);
   procedure Bulk_Save_Host_Endian_U64 (Dst : in out Wuffs.Bytes; Src : Wuffs.U64_Array);

   --  Wuffs `r.limited_copy_u32_to_slice!(etc)`, for a reader of Data: the
   --  two arrays may overlap (C: memmove).
   procedure Reader_Limited_Copy_U32_To_Slice
     (Data  : Wuffs.Bytes;
      R     : in out Wuffs.Base.IO.Reader;
      Up_To : Wuffs.U32;
      Dst   : in out Wuffs.Bytes;
      N     : out Wuffs.U32)
   with Pre => Wuffs.Base.IO.Valid (Data, R);

   ---------------------------------------------------------------------------
   --  TEMPORARY: types of Wuffs' base package that the proved library does
   --  not have yet.  They hold no proved computation.
   ---------------------------------------------------------------------------

   --  C: wuffs_base__more_information (image-public.h).
   type More_Information is record
      Flavor : Wuffs.U32 := 0;
      W      : Wuffs.U32 := 0;
      X      : Wuffs.U64 := 0;
      Y      : Wuffs.U64 := 0;
      Z      : Wuffs.U64 := 0;
   end record;

   --  C: wuffs_base__more_information__set.
   procedure Set
     (M      : out More_Information;
      Flavor : Wuffs.U32;
      W      : Wuffs.U32;
      X      : Wuffs.U64;
      Y      : Wuffs.U64;
      Z      : Wuffs.U64)
   with Inline;

   --  C: wuffs_base__decode_frame_options (it has no fields yet).
   type Decode_Frame_Options is null record;

   ---------------------------------------------------------------------------
   --  Status messages.
   ---------------------------------------------------------------------------

   --  What a generated package's Get_Message does once it has found the
   --  text: copies the first Length characters of Text to the start of
   --  Buffer, where Length is Text'Length or Buffer'Length if that is
   --  smaller, and sets the rest of Buffer to spaces (as
   --  Wuffs.Base.Get_Message does).
   procedure Copy_Message (Text : String; Buffer : out String; Length : out Natural);

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
   --  Wuffs `base.hasher_u64`.
   ---------------------------------------------------------------------------

   type Hasher_U64 is limited interface;

   function Checksum_U64 (Self : Hasher_U64) return Wuffs.U64 is abstract;

   function Get_Quirk (Self : Hasher_U64; A_Key : Wuffs.U32) return Wuffs.U64 is abstract;

   function Set_Quirk
     (Self : in out Hasher_U64; A_Key : Wuffs.U32; A_Value : Wuffs.U64) return Wuffs.Status
   is abstract;

   procedure Update (Self : in out Hasher_U64; A_X : Wuffs.Bytes) is abstract;

   function Update_U64 (Self : in out Hasher_U64; A_X : Wuffs.Bytes) return Wuffs.U64
   is abstract;

   ---------------------------------------------------------------------------
   --  Wuffs `base.hasher_bitvec256`.
   ---------------------------------------------------------------------------

   type Hasher_Bitvec256 is limited interface;

   function Checksum_Bitvec256 (Self : Hasher_Bitvec256) return Wuffs.Base.Ints.Bitvec256
   is abstract;

   function Get_Quirk (Self : Hasher_Bitvec256; A_Key : Wuffs.U32) return Wuffs.U64 is abstract;

   function Set_Quirk
     (Self : in out Hasher_Bitvec256; A_Key : Wuffs.U32; A_Value : Wuffs.U64) return Wuffs.Status
   is abstract;

   procedure Update (Self : in out Hasher_Bitvec256; A_X : Wuffs.Bytes) is abstract;

   function Update_Bitvec256
     (Self : in out Hasher_Bitvec256; A_X : Wuffs.Bytes) return Wuffs.Base.Ints.Bitvec256
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

   ---------------------------------------------------------------------------
   --  Wuffs `base.image_decoder`.
   --
   --  A nullable pointer argument (`nptr base.image_config` and the like) is
   --  two Ada parameters: an object, which always exists, and a Boolean
   --  that says that the Wuffs pointer is null, in which case the object is
   --  neither read nor written.  There is no pointer to dereference.
   ---------------------------------------------------------------------------

   type Image_Decoder is limited interface;

   function Decode_Frame
     (Self          : in out Image_Decoder;
      A_Dst         : Wuffs.Base.Pixel_Buffers.Pixel_Buffer;
      A_Dst_Pixels  : in out Wuffs.Bytes;
      A_Dst_Palette : in out Wuffs.Bytes;
      A_Src         : Wuffs.Bytes;
      A_Src_Meta    : in out Wuffs.Base.IO.Buffer_Meta;
      A_Blend       : Wuffs.Base.Pixel_Formats.Pixel_Blend;
      A_Workbuf     : in out Wuffs.Bytes;
      A_Opts        : in out Decode_Frame_Options;
      A_Opts_Null   : Boolean) return Wuffs.Status
   is abstract;

   function Decode_Frame_Config
     (Self       : in out Image_Decoder;
      A_Dst      : in out Wuffs.Base.Pixel_Formats.Frame_Config;
      A_Dst_Null : Boolean;
      A_Src      : Wuffs.Bytes;
      A_Src_Meta : in out Wuffs.Base.IO.Buffer_Meta) return Wuffs.Status
   is abstract;

   function Decode_Image_Config
     (Self       : in out Image_Decoder;
      A_Dst      : in out Wuffs.Base.Pixel_Formats.Image_Config;
      A_Dst_Null : Boolean;
      A_Src      : Wuffs.Bytes;
      A_Src_Meta : in out Wuffs.Base.IO.Buffer_Meta) return Wuffs.Status
   is abstract;

   function Frame_Dirty_Rect (Self : Image_Decoder) return Wuffs.Base.Ranges.Rect_IE_U32
   is abstract;

   function Get_Quirk (Self : Image_Decoder; A_Key : Wuffs.U32) return Wuffs.U64 is abstract;

   function Num_Animation_Loops (Self : Image_Decoder) return Wuffs.U32 is abstract;

   function Num_Decoded_Frame_Configs (Self : Image_Decoder) return Wuffs.U64 is abstract;

   function Num_Decoded_Frames (Self : Image_Decoder) return Wuffs.U64 is abstract;

   function Restart_Frame
     (Self : in out Image_Decoder; A_Index : Wuffs.U64; A_Io_Position : Wuffs.U64)
      return Wuffs.Status
   is abstract;

   function Set_Quirk
     (Self : in out Image_Decoder; A_Key : Wuffs.U32; A_Value : Wuffs.U64) return Wuffs.Status
   is abstract;

   procedure Set_Report_Metadata
     (Self : in out Image_Decoder; A_Fourcc : Wuffs.U32; A_Report : Boolean)
   is abstract;

   function Tell_Me_More
     (Self         : in out Image_Decoder;
      A_Dst        : in out Wuffs.Bytes;
      A_Dst_Meta   : in out Wuffs.Base.IO.Buffer_Meta;
      A_Minfo      : in out More_Information;
      A_Minfo_Null : Boolean;
      A_Src        : Wuffs.Bytes;
      A_Src_Meta   : in out Wuffs.Base.IO.Buffer_Meta) return Wuffs.Status
   is abstract;

   function Workbuf_Len (Self : Image_Decoder) return Wuffs.Base.Ranges.Range_II_U64
   is abstract;

   ---------------------------------------------------------------------------
   --  Wuffs `base.token_decoder`.
   ---------------------------------------------------------------------------

   type Token_Decoder is limited interface;

   --  A_Dst (A_Dst'First .. A_Dst'First + A_Dst_Meta.Wi - 1) holds the
   --  tokens written so far and A_Src (A_Src'First + A_Src_Meta.Ri ..
   --  A_Src'First + A_Src_Meta.Wi - 1) what is still to be read, as in C's
   --  wuffs_base__token_buffer and wuffs_base__io_buffer.  Returns a
   --  suspension ("short read", "short write") to be called again with
   --  more input or more room.  See "Token buffers" above for what is
   --  checked about the arguments.
   function Decode_Tokens
     (Self       : in out Token_Decoder;
      A_Dst      : in out Wuffs.U64_Array;
      A_Dst_Meta : in out Wuffs.Base.Tokens.Token_Buffer_Meta;
      A_Src      : Wuffs.Bytes;
      A_Src_Meta : in out Wuffs.Base.IO.Buffer_Meta;
      A_Workbuf  : in out Wuffs.Bytes) return Wuffs.Status
   is abstract;

   function Get_Quirk (Self : Token_Decoder; A_Key : Wuffs.U32) return Wuffs.U64 is abstract;

   function Set_Quirk
     (Self : in out Token_Decoder; A_Key : Wuffs.U32; A_Value : Wuffs.U64) return Wuffs.Status
   is abstract;

   function Workbuf_Len (Self : Token_Decoder) return Wuffs.Base.Ranges.Range_II_U64
   is abstract;

private

   --  The address of the first element of a non-empty A.
   function First_Address (A : Wuffs.Bytes) return System.Address is (A (A'First)'Address)
   with Pre => A'Length > 0;

end Wuffs.Runtime;
