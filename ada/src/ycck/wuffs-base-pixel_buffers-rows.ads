--  Access to the pixels of a pixel buffer by position, for code that has
--  validated the buffer once and then writes many pixels of a row: no
--  per-pixel validation, preconditions instead.
--
--  For proved callers only.  The public, total operations are in the
--  parent package; a caller of this one establishes Is_Valid once (as a
--  checked error path if the buffer comes from an end user) and from then
--  on proves each position.
--
--  The three setters are C's wuffs_base__pixel_buffer__set_color_u32_at,
--  ..._set_color_u32_argb_nonpremul_at and wuffs_private_impl__pixel_
--  buffer__composite_color_u32_nonpremul_at, with the pixel given by the
--  position of its first byte instead of by (x, y), and for the formats
--  of Is_Supported only: no status is returned because, given the
--  precondition, there is nothing that can fail.
--
--  Aliasing: Pixels is written and must not share any element with
--  Palette.
--
--  TO RELOCATE: this is a child package in ada/src/ycck only because
--  ada/src/pixel is frozen; it belongs in (or next to) the parent, which
--  has the same per-format code behind its checked setters.

with Wuffs.Base.Colors;
with Wuffs.Base.Endian;

package Wuffs.Base.Pixel_Buffers.Rows with Pure, SPARK_Mode is

   pragma Assertion_Policy (Post => Ignore);

   subtype Pixel_Size is Index range 1 .. 8;

   --  The buffer's format has BPP whole bytes per pixel.
   function Has_Pixel_Size (PB : Pixel_Buffer; BPP : Pixel_Size) return Boolean is
     (U32 (BPP) = Bytes_Per_Pixel (PB.Pixcfg.Pixfmt));

   --  The position (Ada index) in Pixels of the first byte of row Y.  The
   --  whole row, Width * BPP bytes from there, lies within Pixels.
   function Row_Position
     (PB : Pixel_Buffer; Pixels : Bytes; Y : U32; BPP : Pixel_Size) return Index
   with
     Pre  => Fits (PB.Planes (0), Pixels'Length)
       and then Row_Bytes (PB.Pixcfg) <= U64 (PB.Planes (0).Width)
       and then Index (PB.Pixcfg.Height) <= PB.Planes (0).Height
       and then PB.Pixcfg.Width > 0
       and then Y < PB.Pixcfg.Height
       and then Has_Pixel_Size (PB, BPP),
     Post => Row_Position'Result >= Pixels'First
       and then Row_Position'Result - Pixels'First + Index (PB.Pixcfg.Width) * BPP
                <= Pixels'Length;

   --  The formats that the three setters below write: the seventeen that
   --  swizzle_ycck accepts.  (The C functions handle a few more.)
   function Is_Supported (F : Pixel_Format) return Boolean is
     (F.Repr in Repr_Y | Repr_Y_16LE | Repr_Y_16BE | Repr_YA_Nonpremul
        | Repr_Indexed_BGRA_Nonpremul | Repr_Indexed_BGRA_Premul
        | Repr_Indexed_BGRA_Binary | Repr_BGR_565 | Repr_BGR
        | Repr_BGRA_Nonpremul | Repr_BGRA_Nonpremul_4x16LE
        | Repr_BGRA_Premul | Repr_BGRX | Repr_RGB
        | Repr_RGBA_Nonpremul | Repr_RGBA_Premul | Repr_RGBX);

   --  A pixel of PB's format can be written at Pos: the format is
   --  supported, the pixel's bytes exist, and an indexed format has its
   --  palette.
   function Writable
     (PB : Pixel_Buffer; Pixels : Bytes; Pos : Index; Palette_Length : Array_Length)
      return Boolean
   is
     (Is_Supported (PB.Pixcfg.Pixfmt)
      and then Bytes_Per_Pixel (PB.Pixcfg.Pixfmt) in 1 .. 8
      and then Endian.Has (Pixels, Pos, Index (Bytes_Per_Pixel (PB.Pixcfg.Pixfmt)))
      and then (if Is_Indexed (PB.Pixcfg.Pixfmt)
                then Palette_Length >= Palette_Byte_Length));

   --  C: wuffs_base__pixel_buffer__set_color_u32_at, for the pixel at Pos.
   procedure Set_Color_U32_At_Position
     (PB      : Pixel_Buffer;
      Pixels  : in out Bytes;
      Palette : Bytes;
      Pos     : Index;
      Color   : Colors.Color_U32_ARGB_Premul)
   with Pre => Writable (PB, Pixels, Pos, Palette'Length);

   --  C: wuffs_base__pixel_buffer__set_color_u32_argb_nonpremul_at, for the
   --  pixel at Pos.
   procedure Set_Color_U32_ARGB_Nonpremul_At_Position
     (PB      : Pixel_Buffer;
      Pixels  : in out Bytes;
      Palette : Bytes;
      Pos     : Index;
      Color   : Colors.Color_U32_ARGB_Nonpremul)
   with Pre => Writable (PB, Pixels, Pos, Palette'Length);

   --  C: wuffs_private_impl__pixel_buffer__composite_color_u32_nonpremul_at
   --  (pixconv-submodule-regular.c), for the pixel at Pos: composites the
   --  non-premultiplied Color over it (the SRC_OVER blend).
   procedure Composite_Color_U32_Nonpremul_At_Position
     (PB      : Pixel_Buffer;
      Pixels  : in out Bytes;
      Palette : Bytes;
      Pos     : Index;
      Color   : Colors.Color_U32_ARGB_Nonpremul)
   with Pre => Writable (PB, Pixels, Pos, Palette'Length);

end Wuffs.Base.Pixel_Buffers.Rows;
