--  The pixel swizzler: converts rows of pixels from one pixel format to
--  another.
--
--  C: wuffs_base__pixel_swizzler and its functions in
--  wuffs/internal/cgen/base/pixconv-submodule-regular.c.  Scalar code
--  only: the x86 SIMD row functions and the YCCK functions
--  (pixconv-submodule-ycck.c) are not ported.
--
--  A C swizzler holds two function pointers chosen by prepare.  Here a
--  Swizzler is a small plain record that holds the choice as enumeration
--  values (Wuffs.Base.Pixel_Rows.Row_Function), and the swizzle
--  operations dispatch on it.  It can be a component of a decoder record.
--
--  Wuffs method                                   Ada
--  ---------------------------------------------  ----------------------
--  s.prepare!(dst_pixfmt, dst_palette,            Prepare
--             src_pixfmt, src_palette, blend)
--  s.swizzle_interleaved_from_slice!(...)         Swizzle_Interleaved_From_Slice
--  s.swizzle_interleaved_from_reader!(...)        Swizzle_Interleaved_From_Reader
--  s.limited_swizzle_u32_interleaved_from_reader! Limited_Swizzle_U32_Interleaved_From_Reader
--  s.swizzle_interleaved_transparent_black!(...)  Swizzle_Interleaved_Transparent_Black
--
--  Index convention: the operations take whole arrays (the caller passes
--  the slice it means) and return counts of pixels.  The reader forms
--  take a Wuffs.Base.IO.Reader, whose fields are offsets from the start of
--  Src_Data, as everywhere in Wuffs.Base.IO.
--
--  As in C, nothing here has a precondition on lengths: a swizzle converts
--  as many whole pixels as both the destination and the source hold, and a
--  conversion that needs a palette does nothing unless Dst_Palette is
--  exactly 1024 bytes long.
--
--  Aliasing.  In every operation the one array that is WRITTEN (Dst in
--  the swizzles; Dst_Palette in Prepare) must not share any element with
--  any array that is read (Dst_Palette, Src, Src_Data in the swizzles;
--  Src_Palette in Prepare).  Arrays that are only read may overlap each
--  other in any way, and in Wuffs' std they do: std/bmp passes parts of
--  one decoder array, `scratch`, as both the destination palette and the
--  source of a swizzle.  (This is also all that the proof assumes: SPARK's
--  rule against aliasing concerns writable parameters only.)
--
--  There are no _Within forms for a written array that overlaps a read
--  one.  In std no call does that: the destination is a row of the
--  caller's pixel buffer, and what is read is decoder state or the
--  caller's input or work buffer.  Only a caller who hands a decoder
--  overlapping memory blocks could make them overlap.  What the shell
--  does then is an open decision of the project lead.
--
--  Initialisation.  A Swizzler must be default-initialised before its
--  first use: a generated decoder's Initialize must assign its embedded
--  Swizzler component its default value (as Ada does for a declared
--  object), not leave it as whatever bytes the caller's memory held.
--  The default is an un-prepared swizzler, which is safe to call: every
--  swizzle converts nothing and returns 0.  The operations dispatch on
--  the Func component with a case statement, so a record holding an
--  invalid enumeration value would be an unchecked jump in the release
--  profile; values produced by default initialisation and by Prepare are
--  always valid.
--
--  Upstream's WUFFS_CONFIG__DST_PIXEL_FORMAT__ENABLE_ALLOWLIST build
--  option is not modelled: all destination formats are enabled.

with Wuffs.Base.IO;
with Wuffs.Base.Pixel_Formats;
with Wuffs.Base.Pixel_Rows;

package Wuffs.Base.Pixel_Swizzler with Pure, SPARK_Mode is

   pragma Assertion_Policy (Post => Ignore);

   use Interfaces;
   use Wuffs.Base.Pixel_Formats;
   use type Wuffs.Base.IO.Reader;

   --  What swizzle_interleaved_transparent_black does: nothing is
   --  prepared, write zeroes (blend SRC), or leave the destination alone
   --  (blend SRC_OVER).
   type Transparent_Black_Kind is (TB_None, TB_Src, TB_Src_Over);

   type Swizzler is record
      Has_Func          : Boolean                  := False;
      Func              : Pixel_Rows.Row_Function  := Pixel_Rows.Row_Function'First;
      Transparent_Black : Transparent_Black_Kind   := TB_None;
      Dst_BPP           : U32                      := 0;  --  bytes per pixel
      Src_BPP           : U32                      := 0;
   end record
   with
     Predicate =>
       Dst_BPP <= 32
       and then Src_BPP <= 32
       and then (if Transparent_Black /= TB_None then Dst_BPP >= 1)
       and then (if Has_Func
                 then Dst_BPP = U32 (Pixel_Rows.Dst_BPP (Func))
                   and then Src_BPP = U32 (Pixel_Rows.Src_BPP (Func)));

   --  C: wuffs_base__pixel_swizzler__prepare.  Chooses the conversion from
   --  Src_Pixfmt to Dst_Pixfmt for Blend.  For an indexed source it also
   --  fills Dst_Palette from Src_Palette, converted so that the row
   --  functions can copy palette entries as destination pixels.
   --
   --  Result is Ok_Status, or Error_Unsupported_Pixel_Swizzler_Option if
   --  there is no such conversion (or, for an indexed source, if the
   --  palettes are too short: both must have 1024 bytes).  As in C:
   --    * after an error S converts nothing, but may still do transparent
   --      black, if both formats have whole bytes per pixel and Blend is
   --      valid;
   --    * Dst_Palette may have been (partly) written even when the result
   --      is an error;
   --    * a Blend other than Blend_Src and Blend_Src_Over is accepted for the
   --      conversions that do not depend on the blend.
   procedure Prepare
     (S           : out Swizzler;
      Dst_Pixfmt  : Pixel_Format;
      Dst_Palette : in out Bytes;
      Src_Pixfmt  : Pixel_Format;
      Src_Palette : Bytes;
      Blend       : Pixel_Blend;
      Result      : out Status)
   with
     Post => (Is_Ok (Result) = S.Has_Func)
       and then (Is_Ok (Result)
                 or else Result = Error_Unsupported_Pixel_Swizzler_Option);

   --  C: wuffs_base__pixel_swizzler__swizzle_interleaved_from_slice.
   --  Converts N pixels from the start of Src to the start of Dst; N is 0
   --  if S has no conversion.
   procedure Swizzle_Interleaved_From_Slice
     (S           : Swizzler;
      Dst         : in out Bytes;
      Dst_Palette : Bytes;
      Src         : Bytes;
      N           : out U64)
   with
     Inline_Always,
     Post => N <= U64 (Dst'Length)
       and then N <= U64 (Src'Length)
       and then (if S.Has_Func
                 then Pixel_Rows.Rest_Unchanged
                        (Dst'Old, Dst, Offset (N) * Pixel_Rows.Dst_BPP (S.Func))
                 else N = 0 and then Dst = Dst'Old);

   --  C: wuffs_base__pixel_swizzler__swizzle_interleaved_from_reader.  The
   --  same with the reader's unread bytes as the source; the reader
   --  advances by the bytes of the N pixels converted.
   procedure Swizzle_Interleaved_From_Reader
     (S           : Swizzler;
      Dst         : in out Bytes;
      Dst_Palette : Bytes;
      Src_Data    : Bytes;
      R           : in out IO.Reader;
      N           : out U64)
   with
     Pre  => IO.Valid (Src_Data, R),
     Post => N <= IO.Length (R'Old)
       and then Index (N) * Index (S.Src_BPP) <= R'Old.Io2 - R'Old.Iop
       and then R = (R'Old with delta Iop => R'Old.Iop + Index (N) * Index (S.Src_BPP))
       and then (if not S.Has_Func then N = 0);

   --  C: ..._limited_swizzle_u32_interleaved_from_reader.  The same, but
   --  at most Up_To_Num_Pixels pixels.
   procedure Limited_Swizzle_U32_Interleaved_From_Reader
     (S                : Swizzler;
      Up_To_Num_Pixels : U32;
      Dst              : in out Bytes;
      Dst_Palette      : Bytes;
      Src_Data         : Bytes;
      R                : in out IO.Reader;
      N                : out U64)
   with
     Pre  => IO.Valid (Src_Data, R),
     Post => N <= U64 (Up_To_Num_Pixels)
       and then N <= IO.Length (R'Old)
       and then Index (N) * Index (S.Src_BPP) <= R'Old.Io2 - R'Old.Iop
       and then R = (R'Old with delta Iop => R'Old.Iop + Index (N) * Index (S.Src_BPP))
       and then (if not S.Has_Func then N = 0);

   --  C: ..._swizzle_interleaved_transparent_black.  Treats Num_Pixels
   --  transparent black source pixels: N is Num_Pixels or the number of
   --  whole pixels Dst holds, if that is less; for blend SRC the N pixels
   --  are set to zero bytes, for SRC_OVER nothing is written.  N is 0 if
   --  nothing was prepared.  Dst_Palette is not used (it is a parameter of
   --  the Wuffs method).
   procedure Swizzle_Interleaved_Transparent_Black
     (S           : Swizzler;
      Dst         : in out Bytes;
      Dst_Palette : Bytes;
      Num_Pixels  : U64;
      N           : out U64)
   with
     Post => (if S.Transparent_Black = TB_None then N = 0
              elsif U64 (Dst'Length / Index (S.Dst_BPP)) > Num_Pixels then N = Num_Pixels
              else N = U64 (Dst'Length / Index (S.Dst_BPP)))
       and then N <= U64 (Dst'Length)
       and then (for all J in Dst'Range =>
                   (if S.Transparent_Black = TB_Src
                      and then J - Dst'First < Offset (N) * Index (S.Dst_BPP)
                    then Dst (J) = 0
                    else Dst (J) = Dst'Old (J)));

end Wuffs.Base.Pixel_Swizzler;
