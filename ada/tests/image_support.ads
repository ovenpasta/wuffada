--  Part of wuffada (wuffs-ada: Wuffs to Ada).
--  SPDX-License-Identifier: Apache-2.0 OR MIT

--  The large objects of test_image.adb: at library level, not on the stack.

with Wuffs.Std.Bmp;
with Wuffs.Std.Gif;
with Wuffs.Std.Netpbm;
with Wuffs.Std.Nie;
with Wuffs.Std.Png;
with Wuffs.Std.Targa;
with Wuffs.Std.Wbmp;
with Wuffs.Std.Qoi;
with Wuffs.Std.Etc2;
with Wuffs.Std.Thumbhash;
with Wuffs.Std.Handsum;
with Wuffs.Std.Jpeg;
with Wuffs.Std.Vp8;
with Wuffs.Std.Webp;

package Image_Support is

   Cap_File : constant := 4 * 1024 * 1024;
   Cap_Pix  : constant := 40 * 1024 * 1024;
   Cap_Work : constant := 40 * 1024 * 1024;
   Window   : constant := 4096;
   Slack    : constant := 1024 * 1024;

   --  None of the arrays starts at index 0.
   Src_First : constant := 5;
   Pix_First : constant := 11;
   Pal_First : constant := 3;

   File_Last : constant := Cap_File - 1;
   Src_Last  : constant := Src_First + Cap_File + Window - 1;
   Pix_Last  : constant := Pix_First + Cap_Pix + Slack - 1;
   Pal_Last  : constant := Pal_First + 1023;

   File     : Wuffs.Bytes (0 .. File_Last);
   Src      : Wuffs.Bytes (Src_First .. Src_Last);
   Pix      : Wuffs.Bytes (Pix_First .. Pix_Last);
   Pal      : Wuffs.Bytes (Pal_First .. Pal_Last);
   Work     : Wuffs.Bytes (1 .. Cap_Work);
   --  (The destination of tell_me_more is the first 4096 bytes or less.)
   Out_Data : Wuffs.Bytes (2 .. 4161);

   --  For a chaos run of test_image.adb.
   Chaos_Pal : Wuffs.Bytes (0 .. 4095);
   Expected : Wuffs.Bytes (0 .. File_Last);

   --  The comparisons of test_image.adb with a tolerance, by category: how
   --  many, and the largest per-channel and mean differences seen.
   Max_Categories : constant := 16;
   type Category_Stats is record
      Name      : String (1 .. 40) := [others => ' '];
      Name_Last : Natural := 0;
      Tolerance : Natural := 0;
      Runs      : Natural := 0;
      Largest   : Natural := 0;
      Differing : Natural := 0;  --  Runs with any difference at all.
      Mean      : Natural := 0;  --  The largest mean difference of a run, in hundredths.
   end record;
   type Category_Table is array (1 .. Max_Categories) of Category_Stats;
   Categories : Category_Table;

   --  For test_hostile.adb.
   Arena : Wuffs.Bytes (100 .. 8291);

   --  For test_entry.adb: a copy of the std/vp8 decoder inside the std/webp
   --  decoder.
   Sub_Copy : Wuffs.Bytes (0 .. 16383);

   Netpbm_Decoder : Wuffs.Std.Netpbm.Decoder;
   Bmp_Decoder    : Wuffs.Std.Bmp.Decoder;
   Gif_Decoder    : Wuffs.Std.Gif.Decoder;
   Png_Decoder    : Wuffs.Std.Png.Decoder;
   Wbmp_Decoder   : Wuffs.Std.Wbmp.Decoder;
   Nie_Decoder    : Wuffs.Std.Nie.Decoder;
   Targa_Decoder  : Wuffs.Std.Targa.Decoder;
   Qoi_Decoder : Wuffs.Std.Qoi.Decoder;
   Etc2_Decoder : Wuffs.Std.Etc2.Decoder;
   Thumbhash_Decoder : Wuffs.Std.Thumbhash.Decoder;
   Handsum_Decoder : Wuffs.Std.Handsum.Decoder;
   Jpeg_Decoder : Wuffs.Std.Jpeg.Decoder;
   Vp8_Decoder : Wuffs.Std.Vp8.Decoder;
   Webp_Decoder : Wuffs.Std.Webp.Decoder;

end Image_Support;
