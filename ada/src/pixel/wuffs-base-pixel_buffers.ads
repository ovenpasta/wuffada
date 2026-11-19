--  Tables and pixel buffers.
--
--  C: wuffs_base__table_u8 (fundamental-public.h, fundamental-private.h),
--  wuffs_base__pixel_buffer (image-public.h) and its colour accessors
--  (pixconv-submodule-regular.c).
--
--  Model
--  -----
--  A C table is a pointer plus width, height and stride.  Here a Table is
--  the same three numbers plus Offset, and the memory is a Bytes array
--  that the caller passes to each operation that touches elements.
--
--  Addressing convention of this package: Table.Offset, and every offset
--  this package returns, is a count of elements from the start of the
--  array the table lives in: element (X, Y) of table T in array Data is
--  Data (Data'First + T.Offset + Y * T.Stride + X).  No Ada indices.
--
--  A C pixel buffer holds four tables whose pointers may lead into
--  different memory blocks.  Here a Pixel_Buffer holds four Tables, and:
--
--    plane 0 (the pixels) is relative to an array called Pixels,
--    plane 3 (the palette of an indexed format) to an array called Palette.
--
--  The non-SPARK shell owns the references to those two arrays and passes
--  them to every accessor.  They must be two different arrays or two
--  non-overlapping slices: for a buffer made by Set_From_Slice from one
--  block Mem of an indexed format, Palette is the first 1024 bytes of Mem
--  and Pixels is the rest (see Pixel_Memory_Offset).  For a buffer made by
--  Set_Interleaved they are the caller's two memory blocks.  Planes 1 and
--  2 are always empty: planar formats are not supported by any setter, as
--  in C.
--
--  What C assumes of a pixel buffer (that it was filled in by one of the
--  set functions and that the memory is still there) is the predicate
--  Is_Valid (PB, Pixels'Length, Palette'Length).  The setters establish
--  it.  No operation here takes it on trust: the accessors test it (a few
--  comparisons and one division) and treat a buffer that is not valid for
--  the arrays they are given as having no pixels.  Nothing in this
--  package has a precondition except Row_Start.
--
--  Wuffs method                       Ada
--  ---------------------------------  ----------------------------------
--  pb.pixel_format()                  Get_Pixel_Format (PB)
--  pb.plane(p)                        Plane (PB, P)
--  pb.palette()                       if Has_Palette (PB) then the first
--                                     1024 bytes of Palette, else empty
--  pb.palette_or_else(fallback)       if Has_Palette (PB) then the same,
--                                     else fallback
--  t.width(), t.height(), t.stride()  T.Width, T.Height, T.Stride
--  t.row_u32(y)                       Row_U32 (T, Y, Data'Length, First,
--                                     Count): Count elements at First
--  t.subtable(ix, iy, jx, jy)         Subtable (T, IX, IY, JX, JY, ..)
--
--  The rest (Color_U32_At, Set_Color_U32_At, ...) is the C API.
--
--  Not ported: wuffs_base__pixel_buffer__set_from_table (it is not in the
--  pinned upstream; Set_Interleaved takes a table),
--  wuffs_private_impl__pixel_buffer__composite_color_u32_nonpremul_at (a
--  static function that nothing in the base library calls).
--
--  Aliasing: in the operations that write pixels (the Set_Color
--  procedures), Pixels, the array written, must not share any element
--  with Palette.  Arrays that are only read may overlap each other in any
--  way.  No operation here copies between two arrays, so there are no
--  _Within forms.

with Wuffs.Base.Colors;
with Wuffs.Base.Pixel_Formats;
with Wuffs.Base.Ranges;

package Wuffs.Base.Pixel_Buffers with Pure, SPARK_Mode is

   pragma Assertion_Policy (Post => Ignore);

   use Interfaces;
   use Wuffs.Base.Pixel_Formats;

   -----------
   -- Table --
   -----------

   --  The length of an array indexed by Wuffs.Index.
   subtype Array_Length is Offset range 0 .. Index'Last + 1;

   type Table is record
      Offset : First_Offset  := 0;  --  of element (0, 0), from Data'First
      Width  : Element_Count := 0;
      Height : Element_Count := 0;
      Stride : Element_Count := 0;  --  from one row's start to the next
   end record;

   Empty_Table : constant Table := (Offset => 0, Width => 0, Height => 0, Stride => 0);

   function Has_Elements (T : Table) return Boolean is
     (T.Width > 0 and then T.Height > 0);

   --  True if every element of T lies within an array of Length elements:
   --  T.Offset + (T.Height - 1) * T.Stride + T.Width <= Length, written
   --  without a multiplication that could overflow.  A table without
   --  elements (no rows, or rows of no columns) fits anywhere, whatever its
   --  offset and stride say.
   function Fits (T : Table; Length : Array_Length) return Boolean is
     (not Has_Elements (T)
      or else (T.Width <= Length
               and then T.Offset <= Length - T.Width
               and then (T.Height = 1
                         or else T.Stride = 0
                         or else T.Height - 1 <=
                                   (Length - T.Width - T.Offset) / T.Stride)));

   function Has_Row (T : Table; Y : U32) return Boolean is (Index (Y) < T.Height);

   --  Offset from the array's start of the first element of row Y of a
   --  table that has elements and fits.  For proved callers; code that
   --  cannot show the precondition uses Row_U32.
   function Row_Start (T : Table; Y : Index; Length : Array_Length) return Offset with
     Pre  => Has_Elements (T) and then Fits (T, Length) and then Y < T.Height,
     Post => Row_Start'Result = T.Offset + Y * T.Stride
       and then Row_Start'Result >= T.Offset
       and then Row_Start'Result <= Length - T.Width;

   --  C: wuffs_private_impl__table_u8__row_u32.  Row Y of T, in an array of
   --  Length elements, is the Count elements from offset First.  Count is
   --  T.Width if T has a row Y, else 0.  No precondition: the result always
   --  lies within the array (First + Count <= Length), and if T does not
   --  fit the array there is no row (Count = 0).
   procedure Row_U32
     (T      : Table;
      Y      : U32;
      Length : Array_Length;
      First  : out Offset;
      Count  : out Element_Count)
   with
     Post => First >= 0
       and then Count <= Length
       and then First <= Length - Count
       and then (if Fits (T, Length) and then Has_Row (T, Y)
                 then Count = T.Width
                   and then (if T.Width > 0
                             then First = Row_Start (T, Index (Y), Length))
                 else Count = 0);

   --  C: wuffs_base__table_u8__subtable_ij.  The part of T from column IX
   --  to JX - 1 and row IY to JY - 1; Empty_Table if the bounds are out of
   --  order or out of T (or if T does not fit the array, which C does not
   --  check).  (In C the result's pointer is ptr + ix + iy * stride even
   --  when the result has no elements; here a result without elements has
   --  Offset 0.)
   procedure Subtable
     (T              : Table;
      IX, IY, JX, JY : U64;
      Length         : Array_Length;
      Result         : out Table)
   with
     Post => Fits (Result, Length)
       and then (if Fits (T, Length)
                   and then IX <= JX and then JX <= U64 (T.Width)
                   and then IY <= JY and then JY <= U64 (T.Height)
                 then Result.Width = Index (JX - IX)
                   and then Result.Height = Index (JY - IY)
                   and then Result.Stride = T.Stride
                   and then Result.Offset =
                              (if Has_Elements (Result)
                               then Row_Start (T, Index (IY), Length) + Index (IX)
                               else 0)
                 else Result = Empty_Table);

   --  C: wuffs_base__table__flattened_length: the number of elements from
   --  the first to the last element of a table.  C does not handle
   --  overflow; here a result that does not fit saturates at Offset'Last.
   function Flattened_Length (Width, Height, Stride : Element_Count) return Offset is
     (if Height = 0 then 0
      elsif Stride = 0 or else Height - 1 <= (Offset'Last - Width) / Stride
      then (Height - 1) * Stride + Width
      else Offset'Last);

   ------------------
   -- Pixel_Buffer --
   ------------------

   type Plane_Array is array (U32 range 0 .. 3) of Table;

   type Pixel_Buffer is record
      Pixcfg : Pixel_Config;
      Planes : Plane_Array;
   end record;

   Null_Pixel_Buffer : constant Pixel_Buffer :=
     (Pixcfg => (Pixfmt => (Repr => 0), Pixsub => (Repr => 0), Width => 0, Height => 0),
      Planes => [others => (Offset => 0, Width => 0, Height => 0, Stride => 0)]);

   --  Bytes in a row of pixels: width times bytes per pixel.
   function Row_Bytes (C : Pixel_Config) return U64 is
     (U64 (C.Width) * U64 (Bytes_Per_Pixel (C.Pixfmt)));

   --  See "Model" above.  A null (all zero) pixel buffer is valid for any
   --  arrays.
   function Is_Valid
     (PB : Pixel_Buffer; Pixels_Length, Palette_Length : Array_Length) return Boolean
   is
     (Fits (PB.Planes (0), Pixels_Length)
      and then Row_Bytes (PB.Pixcfg) <= U64 (PB.Planes (0).Width)
      and then Index (PB.Pixcfg.Height) <= PB.Planes (0).Height
      and then (if Is_Indexed (PB.Pixcfg.Pixfmt)
                then Palette_Length >= Palette_Byte_Length));

   --  For a buffer made by Set_From_Slice from one memory block: where
   --  the block is split.  Palette is its first Pixel_Memory_Offset bytes
   --  (1024 for an indexed format, else 0) and Pixels is the rest.
   function Pixel_Memory_Offset (C : Pixel_Config) return Element_Count is
     (if Is_Indexed (C.Pixfmt) then Palette_Byte_Length else 0);

   --  C: wuffs_base__pixel_buffer__set_interleaved.  Primary describes the
   --  pixel memory, as a table in an array of Pixels_Length elements;
   --  Palette_Length is the length of the palette memory.  On any error PB
   --  is the null pixel buffer.
   --
   --  The statuses are C's, in C's order.  One check is added after them,
   --  because here (unlike in C, where a table is a bare pointer) it can be
   --  made: Error_Bad_Argument if Primary does not fit in Pixels_Length
   --  elements.  So an Ok result is always a valid buffer.
   procedure Set_Interleaved
     (PB             : out Pixel_Buffer;
      Pixcfg         : Pixel_Config;
      Primary        : Table;
      Pixels_Length  : Array_Length;
      Palette_Length : Array_Length;
      Result         : out Status)
   with
     Post => Is_Valid (PB, Pixels_Length, Palette_Length)
       and then (if Is_Ok (Result)
                 then PB.Pixcfg = Pixcfg and then PB.Planes (0) = Primary
                 else Is_Error (Result) and then PB = Null_Pixel_Buffer);

   --  C: wuffs_base__pixel_buffer__set_from_slice.  Pixbuf_Length is the
   --  length of the one memory block.  On success plane 0 is a table with
   --  no gaps between rows at offset 0 of Pixels, the block without its
   --  first Pixel_Memory_Offset (Pixcfg) bytes.  On an error PB has the
   --  null config and an empty plane 0; as in C, plane 3 may already
   --  describe the palette (which nothing uses while the config is null).
   procedure Set_From_Slice
     (PB            : out Pixel_Buffer;
      Pixcfg        : Pixel_Config;
      Pixbuf_Length : Array_Length;
      Result        : out Status)
   with
     Post => (if Is_Ok (Result)
              then PB.Pixcfg = Pixcfg
                and then Pixbuf_Length >= Pixel_Memory_Offset (Pixcfg)
                and then Is_Valid
                           (PB,
                            Pixbuf_Length - Pixel_Memory_Offset (Pixcfg),
                            Pixel_Memory_Offset (Pixcfg))
              else Is_Error (Result)
                and then PB.Pixcfg = Null_Pixel_Config
                and then PB.Planes (0) = Empty_Table);

   function Get_Pixel_Format (PB : Pixel_Buffer) return Pixel_Format is
     (PB.Pixcfg.Pixfmt);

   --  As in C, the empty table for P > 3.
   function Plane (PB : Pixel_Buffer; P : U32) return Table is
     (if P <= 3 then PB.Planes (P) else Empty_Table);

   --  True if PB has a palette: the format is indexed and plane 3 is the
   --  1024 by 1 table that the setters make.
   function Has_Palette (PB : Pixel_Buffer) return Boolean is
     (Is_Indexed (PB.Pixcfg.Pixfmt)
      and then PB.Planes (Indexed_Color_Plane).Width = Palette_Byte_Length
      and then PB.Planes (Indexed_Color_Plane).Height = 1);

   -------------
   -- Colours --
   -------------

   --  C: wuffs_base__pixel_palette__closest_element.  The index of the
   --  entry of a BGRA palette that is nearest to the colour C (sum of
   --  squared 16 bit channel differences, lowest index on ties).  At most
   --  the first 256 whole entries of Palette_Slice count; 0 if there are
   --  none or Palette_Format is not one of the three indexed formats.
   function Closest_Element
     (Palette_Slice  : Bytes;
      Palette_Format : Pixel_Format;
      C              : Colors.Color_U32_ARGB_Premul) return U8;

   --  For all the accessors below: if PB is not valid for the two arrays
   --  (not Is_Valid (PB, Pixels'Length, Palette'Length)) nothing is read
   --  or written; the functions return 0 / False and the procedures
   --  Error_Bad_Argument.

   --  C: wuffs_base__pixel_buffer__color_u32_at.  The colour of pixel
   --  (X, Y) as premultiplied ARGB; 0 if (X, Y) is outside the buffer or
   --  the format is not supported.
   function Color_U32_At
     (PB      : Pixel_Buffer;
      Pixels  : Bytes;
      Palette : Bytes;
      X, Y    : U32) return Colors.Color_U32_ARGB_Premul;

   --  C: wuffs_base__pixel_buffer__set_color_u32_at (alias of
   --  ..._set_color_u32_argb_premul_at).  Sets pixel (X, Y) to the
   --  premultiplied ARGB colour Color, converted to the buffer's format.
   --  Error_Bad_Argument if (X, Y) is outside the buffer,
   --  Error_Unsupported_Option for a format that is not supported.
   procedure Set_Color_U32_At
     (PB      : Pixel_Buffer;
      Pixels  : in out Bytes;
      Palette : Bytes;
      X, Y    : U32;
      Color   : Colors.Color_U32_ARGB_Premul;
      Result  : out Status)
   with
     Post => (Is_Ok (Result) or else Is_Error (Result))
       and then (if not Is_Ok (Result) then Pixels = Pixels'Old);

   --  C: wuffs_base__pixel_buffer__set_color_u32_argb_nonpremul_at.  The
   --  same for a non-premultiplied ARGB colour.
   procedure Set_Color_U32_ARGB_Nonpremul_At
     (PB      : Pixel_Buffer;
      Pixels  : in out Bytes;
      Palette : Bytes;
      X, Y    : U32;
      Color   : Colors.Color_U32_ARGB_Nonpremul;
      Result  : out Status)
   with
     Post => (Is_Ok (Result) or else Is_Error (Result))
       and then (if not Is_Ok (Result) then Pixels = Pixels'Old);

   --  C: wuffs_base__pixel_buffer__set_color_u32_fill_rect.  Sets every
   --  pixel of Rect to Color.  An empty Rect is fine and does nothing;
   --  Error_Bad_Argument if Rect is not within the buffer's bounds.  As in
   --  C, a format that Set_Color_U32_At does not support is not an error
   --  here (unless it is planar): nothing is written.
   procedure Set_Color_U32_Fill_Rect
     (PB      : Pixel_Buffer;
      Pixels  : in out Bytes;
      Palette : Bytes;
      Rect    : Ranges.Rect_IE_U32;
      Color   : Colors.Color_U32_ARGB_Premul;
      Result  : out Status)
   with
     Post => (Is_Ok (Result) or else Is_Error (Result))
       and then (if not Is_Ok (Result) then Pixels = Pixels'Old);

   --  C: wuffs_base__pixel_buffer__is_opaque.  True if the format has no
   --  alpha channel, or the buffer has no pixels, or every pixel has full
   --  alpha.  False for formats with alpha that are not supported.
   function Is_Opaque
     (PB : Pixel_Buffer; Pixels : Bytes; Palette : Bytes) return Boolean;

end Wuffs.Base.Pixel_Buffers;
