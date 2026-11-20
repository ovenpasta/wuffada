--  The YCbCr / YCCK swizzle: converts up to four planes of 8 bit samples
--  (Y, Cb, Cr and optionally K or alpha; or R, G, B; or C, M, Y, K), each
--  possibly subsampled, into a rectangle of a pixel buffer.  This is what
--  the JPEG and lossy WebP decoders end with.
--
--  C: wuffs_base__pixel_swizzler__swizzle_ycck and everything it calls, in
--  wuffs/internal/cgen/base/pixconv-submodule-ycck.c (scalar code; the
--  x86 AVX2 variants are not ported).
--
--  Wuffs method                      Ada
--  --------------------------------  -----------------------------------
--  swizzler.swizzle_ycck!(dst, dst_palette, x_min_incl, ..., src0 .. src3,
--      width0 .. v3, ycc_model, ycc_upsampling, scratch_buffer_2k)
--                                    Swizzle_YCCK
--
--  The 20 per-plane numbers of the Wuffs call (widthK, heightK, strideK,
--  hK, vK) are the components of Planes (K).  The pixel buffer is passed
--  as in Wuffs.Base.Pixel_Buffers: the descriptor PB and the two arrays
--  its planes 0 and 3 refer to (Pixels, and Palette for an indexed
--  destination).  The C function also takes the swizzler, which it does
--  not use, and dst_palette, which it does not use either (an indexed
--  destination is written through the pixel buffer's own palette); the
--  Dst_Palette parameter is kept only so that the call has the Wuffs
--  method's shape.
--
--  Index convention: none of the parameters is an index.  Source plane K
--  is the whole array SrcK, row R of it starting at element number
--  R * Planes (K).Stride (counted from SrcK'First).
--
--  Structure: as the C.  For each destination row, and within it for each
--  chunk of up to 672 pixels (480 with four planes), every plane's part
--  of the row is upsampled into its section of the scratch buffer (plane K
--  at offset K * 672 or K * 480), unless its samples are used as they are
--  (full horizontal resolution, box filter), in which case they are read
--  from the source plane; then the chunk is
--  converted and written to the pixel buffer.  The body names the C
--  function that each subprogram corresponds to.
--
--  Arrays and aliasing.  Two arrays are written: Pixels and
--  Scratch_Buffer_2K.  Each of them must not share any element with any
--  other array parameter, nor with the other.  Palette, Dst_Palette and
--  Src0 .. Src3 are only read and may overlap one another in any way.
--  That is how the Wuffs decoders call it: in std/jpeg and std/vp8 the
--  scratch buffer is a field of the decoder (array[2048] base.u8), the
--  source planes are consecutive parts of the caller's one work buffer,
--  and Pixels is the caller's pixel buffer.
--
--  Scratch_Buffer_2K must hold at least 2048 bytes; only the first 2016
--  (three planes) or 1920 (four planes) are ever written.  After an Ok
--  call that converted something it holds, as in C, the upsampled samples
--  of the last chunks; nothing should rely on that.
--
--  Preconditions: none, for arguments that are valid values of their types
--  (every component within its subtype: for example a pixel buffer whose
--  Planes (0).Offset is negative is not one, and with checks suppressed
--  would not be caught by Is_Valid; code that takes such records from
--  outside validates them with 'Valid first, see docs/DESIGN.md).
--  Everything the C function checks is checked here
--  and reported with the same status, in the same order.  One check is
--  added in front, which C cannot make: Error_Bad_Argument if PB is not a
--  valid pixel buffer for Pixels and Palette (Pixel_Buffers.Is_Valid).
--  All checks are made once, before anything is written; the row loops
--  that follow are proved not to need any.

with Wuffs.Base.Pixel_Buffers;

package Wuffs.Base.Pixel_Swizzler_YCCK with Pure, SPARK_Mode is

   pragma Assertion_Policy (Post => Ignore);

   --  C: WUFFS_BASE__YCC_MODEL__*.
   YCC_Model_BT_601_Full_Range                : constant U8 := 16#00#;
   YCC_Model_BT_601_Studio_Range              : constant U8 := 16#04#;
   YCC_Model_BT_601_Studio_Range_Alpha_Src    : constant U8 := 16#06#;
   YCC_Model_BT_601_Studio_Range_Alpha_Src_Over : constant U8 := 16#07#;
   YCC_Model_RGB                              : constant U8 := 16#40#;
   YCC_Model_CMY                              : constant U8 := 16#80#;

   --  C: WUFFS_BASE__YCC_UPSAMPLING__*.  Basic repeats samples (a box
   --  filter); the fancy ones interpolate (a triangle filter) where a plane
   --  is subsampled by exactly 2 in one or both directions.
   YCC_Upsampling_Basic              : constant U8 := 0;
   YCC_Upsampling_Fancy_Like_Libjpeg : constant U8 := 1;
   YCC_Upsampling_Fancy_Like_Libwebp : constant U8 := 2;

   --  The smallest scratch buffer that is accepted.
   Scratch_Buffer_Length : constant := 2048;

   --  One source plane: its size in samples, the distance between the
   --  starts of consecutive rows, and its JPEG-style sampling factors (1 ..
   --  4; the plane with the largest factor is at full resolution).  For
   --  plane 3, H = V = 0 means that there is no fourth plane.
   type Source_Plane is record
      Width  : U32 := 0;
      Height : U32 := 0;
      Stride : U32 := 0;
      H      : U8  := 0;
      V      : U8  := 0;
   end record;

   type Source_Planes is array (0 .. 3) of Source_Plane;

   --  Converts the rectangle X_Min_Incl .. X_Max_Excl - 1 by Y_Min_Incl ..
   --  Y_Max_Excl - 1 (clipped to the pixel buffer) from the source planes,
   --  whose top left sample corresponds to pixel (X_Min_Incl, Y_Min_Incl).
   --
   --  Result is Ok_Status; or Error_Bad_Argument for arguments that are
   --  out of range or inconsistent (see the C function for the list);
   --  or Error_Unsupported_Pixel_Swizzler_Option for a destination format
   --  or, with four planes, a YCC model that is not supported.  On any
   --  error Pixels and Scratch_Buffer_2K are unchanged.
   procedure Swizzle_YCCK
     (PB                : Pixel_Buffers.Pixel_Buffer;
      Pixels            : in out Bytes;
      Palette           : Bytes;
      Dst_Palette       : Bytes;
      X_Min_Incl        : U32;
      X_Max_Excl        : U32;
      Y_Min_Incl        : U32;
      Y_Max_Excl        : U32;
      Src0              : Bytes;
      Src1              : Bytes;
      Src2              : Bytes;
      Src3              : Bytes;
      Planes            : Source_Planes;
      YCC_Model         : U8;
      YCC_Upsampling    : U8;
      Scratch_Buffer_2K : in out Bytes;
      Result            : out Status)
   with
     Post => (Is_Ok (Result)
              or else Result = Error_Bad_Argument
              or else Result = Error_Unsupported_Pixel_Swizzler_Option)
       and then (if not Is_Ok (Result)
                 then Pixels = Pixels'Old
                   and then Scratch_Buffer_2K = Scratch_Buffer_2K'Old);

end Wuffs.Base.Pixel_Swizzler_YCCK;
