--  Part of wuffada (wuffs-ada: Wuffs to Ada).
--  SPDX-License-Identifier: Apache-2.0 OR MIT

--  The memory of the example program decode_image: fixed in size and at
--  library level (nothing large is on the stack and nothing is allocated).

with Wuffs.Std.Bmp;
with Wuffs.Std.Gif;
with Wuffs.Std.Netpbm;
with Wuffs.Std.Png;

package Decode_Image_Buffers is

   Mebibyte : constant := 1024 * 1024;

   Source_Capacity  : constant := 64 * Mebibyte;
   Pixels_Capacity  : constant := 256 * Mebibyte;
   Workbuf_Capacity : constant := 256 * Mebibyte;

   Source  : Wuffs.Bytes (1 .. Source_Capacity);
   Pixels  : Wuffs.Bytes (1 .. Pixels_Capacity);
   Workbuf : Wuffs.Bytes (1 .. Workbuf_Capacity);

   --  No destination format of this program has a palette.
   No_Palette : Wuffs.Bytes (1 .. 0);

   --  decode_image accepts file names of up to 1024 characters.
   Input_Name  : String (1 .. 1024);
   Output_Name : String (1 .. 1024);

   Netpbm_Decoder : Wuffs.Std.Netpbm.Decoder;
   Bmp_Decoder    : Wuffs.Std.Bmp.Decoder;
   Gif_Decoder    : Wuffs.Std.Gif.Decoder;
   Png_Decoder    : Wuffs.Std.Png.Decoder;

end Decode_Image_Buffers;
