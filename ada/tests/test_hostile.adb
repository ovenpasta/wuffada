--  Part of wuffada (wuffs-ada: Wuffs to Ada).
--  SPDX-License-Identifier: Apache-2.0 OR MIT

--  What the generated image decoders and the runtime shell do for a caller
--  that breaks the rules: arrays that overlap, pixel buffer descriptors and
--  buffer metas that do not describe their arrays (or hold bit patterns
--  that are no values of their types at all).  The same results are
--  required in the "checked" and in the "release" profile: a bad-argument
--  status and a disabled decoder, and never an exception or a write out of
--  bounds.  Also here: the decoders' pixel swizzlers after Initialize, the
--  packages' status messages, and the sizes of the decoder objects.  The
--  same for the token decoders: see token_hostile.adb.

with Ada.Text_IO;
with Image_Support;
with Interfaces;
with System;
with System.Storage_Elements;
with Test_Support;
with Token_Hostile;
with Wuffs.Base.IO;
with Wuffs.Base.Pixel_Buffers;
with Wuffs.Base.Pixel_Formats;
with Wuffs.Base.Pixel_Swizzler;
with Wuffs.Base.Slices;
with Wuffs.Runtime;
with Wuffs.Std.Bmp.Probe;
with Wuffs.Std.Gif.Probe;
with Wuffs.Std.Jpeg.Probe;
with Wuffs.Std.Netpbm.Probe;
with Wuffs.Std.Png.Probe;
with Wuffs.Std.Wbmp.Probe;
with Wuffs.Std.Nie.Probe;
with Wuffs.Std.Targa.Probe;
with Wuffs.Std.Qoi.Probe;
with Wuffs.Std.Vp8.Probe;
with Wuffs.Std.Webp.Probe;

procedure Test_Hostile is

   package IMS renames Image_Support;
   package IO renames Wuffs.Base.IO;
   package PB renames Wuffs.Base.Pixel_Buffers;
   package PF renames Wuffs.Base.Pixel_Formats;

   use type Wuffs.U8;
   use type Wuffs.U32;
   use type Wuffs.U64;
   use type Wuffs.Index;
   use type Wuffs.Status;
   use type Interfaces.Integer_64;
   use type PB.Pixel_Buffer;

   use Test_Support;

   BGRA : constant := 16#8100_8888#;
   BGR  : constant := 16#8000_0888#;
   RGB  : constant := 16#A000_0888#;

   type Kind is (Netpbm, Bmp, Gif, Png, Jpeg, Vp8, Webp, Wbmp, Nie, Targa, Qoi);

   --  The decoders whose status messages Check_Messages looks at.
   subtype Message_Kind is Kind range Netpbm .. Webp;

   subtype Decoder is Wuffs.Runtime.Image_Decoder'Class;

   --  One arena for every array that a test passes, so that they can be
   --  made to overlap.  It does not start at index 0.
   Arena : Wuffs.Bytes renames IMS.Arena;

   --  A valid 4 by 4 BGRA pixel buffer for a 64 byte pixel array.
   Good_PB : PB.Pixel_Buffer;

   procedure Initialize (K : Kind);

   function Swizzler_Is_Default (K : Kind) return Boolean;

   procedure Put_Size (Name : String; Bits : Long_Long_Integer);

   --  Calls Decode_Frame with parts of Arena: Count elements from each
   --  First.
   function Frame
     (D           : in out Decoder;
      Buf         : PB.Pixel_Buffer;
      Pix_First   : Wuffs.Index;
      Pix_Count   : Wuffs.Index;
      Pal_First   : Wuffs.Index;
      Pal_Count   : Wuffs.Index;
      Src_First   : Wuffs.Index;
      Src_Count   : Wuffs.Index;
      Work_First  : Wuffs.Index;
      Work_Count  : Wuffs.Index) return Wuffs.Status;

   --  Checks that the last call (which returned St) rejected its arguments
   --  and disabled the decoder, and that Arena was not written.
   procedure Check_Rejected (D : in out Decoder; K : Kind; St : Wuffs.Status; What : String);

   procedure Check_Overlaps (D : in out Decoder; K : Kind; Size : Long_Long_Integer);

   procedure Check_Descriptors (D : in out Decoder; K : Kind);

   procedure Check_Metas (D : in out Decoder; K : Kind);

   procedure Check_Shell;

   procedure Check_Shell_YCCK;

   procedure Check_Shell_Bulk;

   procedure Check_Messages;

   procedure Check_Tiny_Image;

   procedure Initialize (K : Kind) is
   begin
      case K is
         when Netpbm => Wuffs.Std.Netpbm.Initialize (IMS.Netpbm_Decoder);
         when Bmp => Wuffs.Std.Bmp.Initialize (IMS.Bmp_Decoder);
         when Gif => Wuffs.Std.Gif.Initialize (IMS.Gif_Decoder);
         when Png => Wuffs.Std.Png.Initialize (IMS.Png_Decoder);
         when Jpeg => Wuffs.Std.Jpeg.Initialize (IMS.Jpeg_Decoder);
         when Vp8 => Wuffs.Std.Vp8.Initialize (IMS.Vp8_Decoder);
         when Webp => Wuffs.Std.Webp.Initialize (IMS.Webp_Decoder);
         when Wbmp => Wuffs.Std.Wbmp.Initialize (IMS.Wbmp_Decoder);
         when Nie => Wuffs.Std.Nie.Initialize (IMS.Nie_Decoder);
         when Targa => Wuffs.Std.Targa.Initialize (IMS.Targa_Decoder);
         when Qoi => Wuffs.Std.Qoi.Initialize (IMS.Qoi_Decoder);
      end case;
   end Initialize;

   function Swizzler_Is_Default (K : Kind) return Boolean
   is (case K is
         when Netpbm => Wuffs.Std.Netpbm.Probe.Swizzler_Is_Default (IMS.Netpbm_Decoder),
         when Bmp => Wuffs.Std.Bmp.Probe.Swizzler_Is_Default (IMS.Bmp_Decoder),
         when Gif => Wuffs.Std.Gif.Probe.Swizzler_Is_Default (IMS.Gif_Decoder),
         when Png => Wuffs.Std.Png.Probe.Swizzler_Is_Default (IMS.Png_Decoder),
         when Jpeg => Wuffs.Std.Jpeg.Probe.Swizzler_Is_Default (IMS.Jpeg_Decoder),
         when Vp8 => Wuffs.Std.Vp8.Probe.Swizzler_Is_Default (IMS.Vp8_Decoder),
         when Webp => Wuffs.Std.Webp.Probe.Swizzler_Is_Default (IMS.Webp_Decoder),
         when Wbmp => Wuffs.Std.Wbmp.Probe.Swizzler_Is_Default (IMS.Wbmp_Decoder),
         when Nie => Wuffs.Std.Nie.Probe.Swizzler_Is_Default (IMS.Nie_Decoder),
         when Targa => Wuffs.Std.Targa.Probe.Swizzler_Is_Default (IMS.Targa_Decoder),
         when Qoi => Wuffs.Std.Qoi.Probe.Swizzler_Is_Default (IMS.Qoi_Decoder));

   procedure Put_Size (Name : String; Bits : Long_Long_Integer) is
   begin
      Ada.Text_IO.Put ("size of ");
      Ada.Text_IO.Put (Name);
      Ada.Text_IO.Put (" in bytes:");
      Ada.Text_IO.Put_Line (Long_Long_Integer'Image (Bits / 8));
   end Put_Size;

   function Frame
     (D           : in out Decoder;
      Buf         : PB.Pixel_Buffer;
      Pix_First   : Wuffs.Index;
      Pix_Count   : Wuffs.Index;
      Pal_First   : Wuffs.Index;
      Pal_Count   : Wuffs.Index;
      Src_First   : Wuffs.Index;
      Src_Count   : Wuffs.Index;
      Work_First  : Wuffs.Index;
      Work_Count  : Wuffs.Index) return Wuffs.Status
   is
      Meta : IO.Buffer_Meta := (Wi => Src_Count, Ri => 0, Pos => 0, Closed => True);
      Opts : Wuffs.Runtime.Decode_Frame_Options;
   begin
      return
        D.Decode_Frame
          (A_Dst         => Buf,
           A_Dst_Pixels  => Arena (Pix_First .. Pix_First + Pix_Count - 1),
           A_Dst_Palette => Arena (Pal_First .. Pal_First + Pal_Count - 1),
           A_Src         => Arena (Src_First .. Src_First + Src_Count - 1),
           A_Src_Meta    => Meta,
           A_Blend       => PF.Blend_Src,
           A_Workbuf     => Arena (Work_First .. Work_First + Work_Count - 1),
           A_Opts        => Opts,
           A_Opts_Null   => True);
   end Frame;

   procedure Check_Rejected (D : in out Decoder; K : Kind; St : Wuffs.Status; What : String) is
      Intact : Boolean := True;
      Again  : Wuffs.Status;
   begin
      Check (St = Wuffs.Base.Error_Bad_Argument, What, Kind'Pos (K), ": not rejected");
      for B of Arena loop
         Intact := Intact and then B = 16#5A#;
      end loop;
      Check (Intact, What, Kind'Pos (K), ": memory was written");
      --  The decoder is disabled until it is initialized again.
      Again := D.Restart_Frame (A_Index => 0, A_Io_Position => 0);
      Check
        (Again = Wuffs.Base.Error_Disabled_By_Previous_Error, What, Kind'Pos (K), ": not disabled");
      Arena := [others => 16#5A#];
      Initialize (K);
   end Check_Rejected;

   procedure Check_Overlaps (D : in out Decoder; K : Kind; Size : Long_Long_Integer) is
      --  Where the arrays are when they are apart: Pixels (64 bytes) at
      --  P, Palette (1024) at L, Src (16) at S, Workbuf (16) at W.
      P : constant := 1000;
      L : constant := 2000;
      S : constant := 4000;
      W : constant := 5000;

      --  The decoder object as bytes.
      Self_Bytes : Wuffs.Bytes (0 .. Wuffs.Index (Size / 8) - 1)
      with Import, Address => D'Address;

      St : Wuffs.Status;
      Opts : Wuffs.Runtime.Decode_Frame_Options;
      Meta : IO.Buffer_Meta := (Wi => 16, Ri => 0, Pos => 0, Closed => True);
   begin
      Arena := [others => 16#5A#];
      Initialize (K);

      --  Apart, and adjacent without a gap: accepted (the source is not an
      --  image, so the result is some other status).
      St := Frame (D, Good_PB, P, 64, L, 1024, S, 16, W, 16);
      Check (St /= Wuffs.Base.Error_Bad_Argument, "disjoint arrays were rejected", Kind'Pos (K));
      Arena := [others => 16#5A#];
      Initialize (K);
      St := Frame (D, Good_PB, P, 64, P + 64, 1024, P - 16, 16, P + 64 + 1024, 16);
      Check (St /= Wuffs.Base.Error_Bad_Argument, "adjacent arrays were rejected", Kind'Pos (K));
      Arena := [others => 16#5A#];
      Initialize (K);
      --  The two arrays that are only read may overlap.
      St := Frame (D, Good_PB, P, 64, L, 1024, S, 16, S + 8, 16);
      Check
        (St /= Wuffs.Base.Error_Bad_Argument, "overlapping read-only arrays were rejected",
         Kind'Pos (K));
      Arena := [others => 16#5A#];
      Initialize (K);

      --  Pixels and Palette: one shared element at either end, the same
      --  start, and one inside the other.
      Check_Rejected
        (D, K, Frame (D, Good_PB, P, 64, P + 63, 1024, S, 16, W, 16), "pixels/palette, last");
      Check_Rejected
        (D, K, Frame (D, Good_PB, L + 1023, 64, L, 1024, S, 16, W, 16),
         "pixels/palette, first element");
      Check_Rejected
        (D, K, Frame (D, Good_PB, P, 64, P, 1024, S, 16, W, 16), "pixels/palette, same start");
      Check_Rejected
        (D, K, Frame (D, Good_PB, L + 100, 64, L, 1024, S, 16, W, 16), "pixels inside palette");
      --  Pixels and Src.
      Check_Rejected
        (D, K, Frame (D, Good_PB, P, 64, L, 1024, P + 63, 16, W, 16), "pixels/src, last element");
      Check_Rejected
        (D, K, Frame (D, Good_PB, P, 64, L, 1024, P - 15, 16, W, 16), "pixels/src, first element");
      Check_Rejected
        (D, K, Frame (D, Good_PB, P, 64, L, 1024, P, 64, W, 16), "pixels/src, the same array");
      Check_Rejected
        (D, K, Frame (D, Good_PB, P, 64, L, 1024, P + 20, 16, W, 16), "src inside pixels");
      --  Pixels and Workbuf.
      Check_Rejected
        (D, K, Frame (D, Good_PB, P, 64, L, 1024, S, 16, P + 63, 16), "pixels/workbuf, last");
      Check_Rejected
        (D, K, Frame (D, Good_PB, P, 64, L, 1024, S, 16, P - 15, 16),
         "pixels/workbuf, first element");
      Check_Rejected
        (D, K, Frame (D, Good_PB, P, 64, L, 1024, S, 16, P, 64), "pixels/workbuf, the same array");
      --  Palette and Src.
      Check_Rejected
        (D, K, Frame (D, Good_PB, P, 64, L, 1024, L + 1023, 16, W, 16), "palette/src, last");
      Check_Rejected
        (D, K, Frame (D, Good_PB, P, 64, L, 1024, L - 15, 16, W, 16), "palette/src, first element");
      Check_Rejected
        (D, K, Frame (D, Good_PB, P, 64, L, 1024, L, 1024, W, 16), "palette/src, the same array");
      --  Palette and Workbuf.
      Check_Rejected
        (D, K, Frame (D, Good_PB, P, 64, L, 1024, S, 16, L + 1023, 16),
         "palette/workbuf, last element");
      Check_Rejected
        (D, K, Frame (D, Good_PB, P, 64, L, 1024, S, 16, L - 15, 16),
         "palette/workbuf, first element");
      Check_Rejected
        (D, K, Frame (D, Good_PB, P, 64, L, 1024, S, 16, L + 500, 16), "workbuf inside palette");

      --  Pixels, and then Palette, inside the decoder object itself (past
      --  its tag).  The object is not written: the status says so, and the
      --  decoder still works afterwards (Check_Tiny_Image).
      St :=
        D.Decode_Frame
          (A_Dst         => Good_PB,
           A_Dst_Pixels  => Self_Bytes (Self_Bytes'Last - 63 .. Self_Bytes'Last),
           A_Dst_Palette => Arena (L .. L + 1023),
           A_Src         => Arena (S .. S + 15),
           A_Src_Meta    => Meta,
           A_Blend       => PF.Blend_Src,
           A_Workbuf     => Arena (W .. W + 15),
           A_Opts        => Opts,
           A_Opts_Null   => True);
      Check_Rejected (D, K, St, "pixels inside the decoder");
      St :=
        D.Decode_Frame
          (A_Dst         => Good_PB,
           A_Dst_Pixels  => Arena (P .. P + 63),
           A_Dst_Palette => Self_Bytes (Self_Bytes'Last - 31 .. Self_Bytes'Last),
           A_Src         => Arena (S .. S + 15),
           A_Src_Meta    => Meta,
           A_Blend       => PF.Blend_Src,
           A_Workbuf     => Arena (W .. W + 15),
           A_Opts        => Opts,
           A_Opts_Null   => True);
      Check_Rejected (D, K, St, "palette inside the decoder");
      St :=
        D.Decode_Frame
          (A_Dst         => Good_PB,
           A_Dst_Pixels  => Arena (P .. P + 63),
           A_Dst_Palette => Self_Bytes (8 .. 8),
           A_Src         => Arena (S .. S + 15),
           A_Src_Meta    => Meta,
           A_Blend       => PF.Blend_Src,
           A_Workbuf     => Arena (W .. W + 15),
           A_Opts        => Opts,
           A_Opts_Null   => True);
      Check_Rejected (D, K, St, "one byte of the decoder as palette");
   end Check_Overlaps;

   procedure Check_Descriptors (D : in out Decoder; K : Kind) is
      P : constant := 1000;
      L : constant := 2000;
      S : constant := 4000;
      W : constant := 5000;

      Bad : PB.Pixel_Buffer;

      --  The four numbers of plane 0's table, to give them bit patterns
      --  that are not values of their subtypes.
      type Raw_Table is record
         Offset, Width, Height, Stride : Interfaces.Integer_64;
      end record
      with Convention => C;

      Raw : Raw_Table
      with Import, Address => Bad.Planes (0)'Address;

      procedure Try (What : String);

      procedure Try (What : String) is
      begin
         Check_Rejected (D, K, Frame (D, Bad, P, 64, L, 1024, S, 16, W, 16), What);
         Bad := Good_PB;
      end Try;

      Cfg : PF.Pixel_Config;
      St  : Wuffs.Status;
   begin
      Check (Raw_Table'Size = PB.Table'Size, "the layout of Table is not as this test assumes");
      Arena := [others => 16#5A#];
      Initialize (K);
      Bad := Good_PB;

      --  Tables that do not fit the 64 byte array.
      Bad.Planes (0).Offset := 1;
      Try ("table: offset 1");
      Bad.Planes (0).Height := 5;
      Try ("table: one row too many");
      Bad.Planes (0).Stride := 17;
      Try ("table: stride too long");
      Bad.Planes (0).Width := 17;
      Try ("table: width above stride");
      Bad.Planes (0).Offset := Wuffs.Index'Last;
      Try ("table: largest offset");
      Bad.Planes (0).Height := Wuffs.Index'Last;
      Bad.Planes (0).Stride := Wuffs.Index'Last;
      Try ("table: largest height and stride");
      Bad.Planes (0).Width := 15;
      Try ("table: narrower than a row of pixels");
      Bad.Planes (0).Height := 3;
      Try ("table: fewer rows than the image");

      --  Bit patterns that are not values.
      Raw.Offset := -1;
      Try ("table: offset -1");
      Raw.Width := -16;
      Try ("table: negative width");
      Raw.Height := Interfaces.Integer_64'First;
      Try ("table: most negative height");
      Raw.Stride := Interfaces.Integer_64'Last;
      Try ("table: stride 2**63 - 1");
      Raw.Offset := 2**62;
      Try ("table: offset 2**62");
      Raw.Stride := -16;
      Raw.Offset := 48;
      Try ("table: negative stride");

      --  Configurations that the table does not hold.
      Bad.Pixcfg.Width := 5;
      Try ("config: wider than the table");
      Bad.Pixcfg.Height := 5;
      Try ("config: taller than the table");
      Bad.Pixcfg.Width := 16#FFFF_FFFF#;
      Bad.Pixcfg.Height := 16#FFFF_FFFF#;
      Try ("config: largest width and height");

      --  A buffer with no pixel format, and the null pixel buffer, describe
      --  no pixels: they are valid arguments (as in C), there is just
      --  nothing that a decoder can do with them.
      for Null_Buffer in Boolean loop
         Bad := (if Null_Buffer then PB.Null_Pixel_Buffer else Good_PB);
         Bad.Pixcfg.Pixfmt.Repr := 0;
         St := Frame (D, Bad, P, 64, L, 1024, S, 16, W, 16);
         Check
           (Wuffs.Is_Error (St) and then St /= Wuffs.Base.Error_Bad_Argument
            and then (for all B of Arena => B = 16#5A#),
            "a pixel buffer without a pixel format", Kind'Pos (K));
         Initialize (K);
      end loop;
      Bad := Good_PB;

      --  An indexed format with a palette array that is too short.
      PF.Set (C => Cfg, Pixfmt_Repr => 16#8104_0008#, Pixsub_Repr => 0, Width => 4, Height => 4);
      PB.Set_Interleaved
        (PB             => Bad,
         Pixcfg         => Cfg,
         Primary        => (Offset => 0, Width => 4, Height => 4, Stride => 4),
         Pixels_Length  => 16,
         Palette_Length => 1024,
         Result         => St);
      Check (Wuffs.Is_Ok (St), "Set_Interleaved for an indexed format");
      Check_Rejected (D, K, Frame (D, Bad, P, 16, L, 1023, S, 16, W, 16), "palette of 1023 bytes");
      Check_Rejected (D, K, Frame (D, Bad, P, 16, L, 0, S, 16, W, 16), "no palette");
      Check_Rejected (D, K, Frame (D, Bad, P, 15, L, 1024, S, 16, W, 16), "pixels of 15 bytes");
      St := Frame (D, Bad, P, 16, L, 1024, S, 16, W, 16);
      Check
        (St /= Wuffs.Base.Error_Bad_Argument, "a valid indexed buffer was rejected", Kind'Pos (K));
      Arena := [others => 16#5A#];
      Initialize (K);
   end Check_Descriptors;

   procedure Check_Metas (D : in out Decoder; K : Kind) is
      type Raw_Meta is record
         Wi     : Interfaces.Integer_64;
         Ri     : Interfaces.Integer_64;
         Pos    : Wuffs.U64;
         Closed : Wuffs.U8;
      end record
      with Convention => C;

      Raw     : aliased Raw_Meta := (Wi => 0, Ri => 0, Pos => 0, Closed => 0);
      Invalid : IO.Buffer_Meta
      with Import, Address => Raw'Address;

      Raw_Metas : constant array (1 .. 6) of Raw_Meta :=
        [(Wi => 17, Ri => 0, Pos => 0, Closed => 0),
         (Wi => 0, Ri => -1, Pos => 0, Closed => 0),
         (Wi => -5, Ri => -5, Pos => 0, Closed => 0),
         (Wi => 2, Ri => -(2 ** 62), Pos => 0, Closed => 0),
         (Wi => Interfaces.Integer_64'Last, Ri => 0, Pos => 0, Closed => 0),
         (Wi => 0, Ri => 0, Pos => 0, Closed => 2)];

      P : constant := 1000;
      L : constant := 2000;
      S : constant := 4000;
      W : constant := 5000;

      IC   : PF.Image_Config;
      FC   : PF.Frame_Config;
      MI   : Wuffs.Runtime.More_Information;
      Opts : Wuffs.Runtime.Decode_Frame_Options;
      Good : IO.Buffer_Meta;
   begin
      Arena := [others => 16#5A#];
      Initialize (K);
      for I in Raw_Metas'Range loop
         Raw := Raw_Metas (I);
         Check_Rejected
           (D, K,
            D.Decode_Image_Config
              (A_Dst      => IC,
               A_Dst_Null => False,
               A_Src      => Arena (S .. S + 15),
               A_Src_Meta => Invalid),
            "decode_image_config with an invalid meta");
         Raw := Raw_Metas (I);
         Check_Rejected
           (D, K,
            D.Decode_Frame_Config
              (A_Dst      => FC,
               A_Dst_Null => True,
               A_Src      => Arena (S .. S + 15),
               A_Src_Meta => Invalid),
            "decode_frame_config with an invalid meta");
         Raw := Raw_Metas (I);
         Check_Rejected
           (D, K,
            D.Decode_Frame
              (A_Dst         => Good_PB,
               A_Dst_Pixels  => Arena (P .. P + 63),
               A_Dst_Palette => Arena (L .. L + 1023),
               A_Src         => Arena (S .. S + 15),
               A_Src_Meta    => Invalid,
               A_Blend       => PF.Blend_Src,
               A_Workbuf     => Arena (W .. W + 15),
               A_Opts        => Opts,
               A_Opts_Null   => False),
            "decode_frame with an invalid meta");
         Raw := Raw_Metas (I);
         Good := IO.Empty_Meta;
         Check_Rejected
           (D, K,
            D.Tell_Me_More
              (A_Dst        => Arena (P .. P + 63),
               A_Dst_Meta   => Good,
               A_Minfo      => MI,
               A_Minfo_Null => False,
               A_Src        => Arena (S .. S + 15),
               A_Src_Meta   => Invalid),
            "tell_me_more with an invalid src meta");
         Raw := Raw_Metas (I);
         Good := IO.Empty_Meta;
         Check_Rejected
           (D, K,
            D.Tell_Me_More
              (A_Dst        => Arena (P .. P + 15),
               A_Dst_Meta   => Invalid,
               A_Minfo      => MI,
               A_Minfo_Null => True,
               A_Src        => Arena (S .. S + 15),
               A_Src_Meta   => Good),
            "tell_me_more with an invalid dst meta");
      end loop;
   end Check_Metas;

   --  The operations of the shell, called as no generated decoder calls
   --  them: with a written array that overlaps one that is read.
   procedure Check_Shell is
      --  Overlapping actuals are the point of this test.
      pragma Warnings (Off, "writable actual for * overlaps with actual for *");

      package SW renames Wuffs.Base.Pixel_Swizzler;
      use type SW.Swizzler;

      S       : SW.Swizzler;
      Default : constant SW.Swizzler := (others => <>);
      St      : Wuffs.Status;
      N       : Wuffs.U64;
      R       : IO.Reader;
      Intact  : Boolean;

      procedure Fill;

      function Is_Filled return Boolean;

      procedure Fill is
      begin
         for I in Arena'Range loop
            Arena (I) := Wuffs.U8 (I mod 251);
         end loop;
      end Fill;

      function Is_Filled return Boolean is
      begin
         for I in Arena'Range loop
            if Arena (I) /= Wuffs.U8 (I mod 251) then
               return False;
            end if;
         end loop;
         return True;
      end Is_Filled;
   begin
      Fill;
      --  Prepare writes Dst_Palette and reads Src_Palette.
      Wuffs.Runtime.Swizzler_Prepare
        (S           => S,
         Dst_Pixfmt  => PF.Make_Pixel_Format (BGRA),
         Dst_Palette => Arena (1000 .. 2023),
         Src_Pixfmt  => PF.Make_Pixel_Format (16#8104_0008#),
         Src_Palette => Arena (2023 .. 3046),
         Blend       => PF.Blend_Src,
         Result      => St);
      Check (St = Wuffs.Base.Error_Bad_Argument, "prepare with overlapping palettes: status");
      Check (S = Default, "prepare with overlapping palettes: the swizzler");
      Check (Is_Filled, "prepare with overlapping palettes: memory was written");
      Wuffs.Runtime.Swizzler_Prepare
        (S           => S,
         Dst_Pixfmt  => PF.Make_Pixel_Format (BGRA),
         Dst_Palette => Arena (1000 .. 2023),
         Src_Pixfmt  => PF.Make_Pixel_Format (16#8104_0008#),
         Src_Palette => Arena (1000 .. 2023),
         Blend       => PF.Blend_Src,
         Result      => St);
      Check (St = Wuffs.Base.Error_Bad_Argument, "prepare with one palette twice: status");
      Check (S = Default and then Is_Filled, "prepare with one palette twice");

      --  A swizzler from BGR to RGB.
      Wuffs.Runtime.Swizzler_Prepare
        (S           => S,
         Dst_Pixfmt  => PF.Make_Pixel_Format (RGB),
         Dst_Palette => Arena (1000 .. 2023),
         Src_Pixfmt  => PF.Make_Pixel_Format (BGR),
         Src_Palette => Arena (3000 .. 4023),
         Blend       => PF.Blend_Src,
         Result      => St);
      Check (Wuffs.Is_Ok (St) and then S /= Default, "prepare BGR to RGB");
      Fill;

      --  From a slice: disjoint and adjacent, it converts.
      Wuffs.Runtime.Swizzle_Interleaved_From_Slice
        (S => S, Dst => Arena (5000 .. 5011), Dst_Palette => Arena (1000 .. 2023),
         Src => Arena (5012 .. 5023), N => N);
      Check_U64 (N, 4, "swizzle from an adjacent slice: N");
      Intact := True;
      for I in Wuffs.Index range 0 .. 3 loop
         Intact := Intact
           and then Arena (5000 + 3 * I) = Wuffs.U8 ((5012 + 3 * I + 2) mod 251)
           and then Arena (5000 + 3 * I + 1) = Wuffs.U8 ((5012 + 3 * I + 1) mod 251)
           and then Arena (5000 + 3 * I + 2) = Wuffs.U8 ((5012 + 3 * I) mod 251);
      end loop;
      Check (Intact, "swizzle from an adjacent slice: the pixels");
      Fill;
      --  The palette and the source may overlap (std/bmp does that).
      Wuffs.Runtime.Swizzle_Interleaved_From_Slice
        (S => S, Dst => Arena (5000 .. 5011), Dst_Palette => Arena (6000 .. 7023),
         Src => Arena (6500 .. 6511), N => N);
      Check_U64 (N, 4, "swizzle with source inside the palette: N");
      Fill;

      --  Dst and Src overlap: nothing happens.
      Wuffs.Runtime.Swizzle_Interleaved_From_Slice
        (S => S, Dst => Arena (5000 .. 5011), Dst_Palette => Arena (1000 .. 2023),
         Src => Arena (5011 .. 5022), N => N);
      Check_U64 (N, 0, "swizzle, dst/src share the last element: N");
      Check (Is_Filled, "swizzle, dst/src share the last element: memory was written");
      Wuffs.Runtime.Swizzle_Interleaved_From_Slice
        (S => S, Dst => Arena (5000 .. 5011), Dst_Palette => Arena (1000 .. 2023),
         Src => Arena (4989 .. 5000), N => N);
      Check_U64 (N, 0, "swizzle, dst/src share the first element: N");
      Wuffs.Runtime.Swizzle_Interleaved_From_Slice
        (S => S, Dst => Arena (5000 .. 5011), Dst_Palette => Arena (1000 .. 2023),
         Src => Arena (5000 .. 5011), N => N);
      Check_U64 (N, 0, "swizzle in place: N");
      Wuffs.Runtime.Swizzle_Interleaved_From_Slice
        (S => S, Dst => Arena (5000 .. 5011), Dst_Palette => Arena (4000 .. 5023),
         Src => Arena (6000 .. 6011), N => N);
      Check_U64 (N, 0, "swizzle, dst inside the palette: N");
      Check (Is_Filled, "swizzle with overlaps: memory was written");

      --  From a reader.
      R := IO.To_Reader ((Wi => 12, Ri => 0, Pos => 0, Closed => True));
      Wuffs.Runtime.Swizzle_Interleaved_From_Reader
        (S => S, Dst => Arena (5000 .. 5011), Dst_Palette => Arena (1000 .. 2023),
         Src_Data => Arena (5011 .. 5022), R => R, N => N);
      Check_U64 (N, 0, "swizzle from a reader, dst/src overlap: N");
      Check_U64 (IO.Length (R), 12, "swizzle from a reader, dst/src overlap: the reader moved");
      Wuffs.Runtime.Swizzle_Interleaved_From_Reader
        (S => S, Dst => Arena (5000 .. 5011), Dst_Palette => Arena (5005 .. 6028),
         Src_Data => Arena (7000 .. 7011), R => R, N => N);
      Check_U64 (N, 0, "swizzle from a reader, dst/palette overlap: N");
      Wuffs.Runtime.Limited_Swizzle_U32_Interleaved_From_Reader
        (S => S, Up_To_Num_Pixels => 2, Dst => Arena (5000 .. 5011),
         Dst_Palette => Arena (1000 .. 2023), Src_Data => Arena (5000 .. 5011), R => R, N => N);
      Check_U64 (N, 0, "limited swizzle from a reader, in place: N");
      Wuffs.Runtime.Limited_Swizzle_U32_Interleaved_From_Reader
        (S => S, Up_To_Num_Pixels => 2, Dst => Arena (5000 .. 5011),
         Dst_Palette => Arena (5011 .. 6034), Src_Data => Arena (7000 .. 7011), R => R, N => N);
      Check_U64 (N, 0, "limited swizzle from a reader, dst/palette overlap: N");
      Check (Is_Filled, "swizzles from a reader with overlaps: memory was written");
      Wuffs.Runtime.Limited_Swizzle_U32_Interleaved_From_Reader
        (S => S, Up_To_Num_Pixels => 2, Dst => Arena (5000 .. 5011),
         Dst_Palette => Arena (1000 .. 2023), Src_Data => Arena (7000 .. 7011), R => R, N => N);
      Check_U64 (N, 2, "limited swizzle from a reader: N");
      Check_U64 (IO.Length (R), 6, "limited swizzle from a reader: the reader");
      Fill;

      --  Transparent black: a swizzler from an indexed source.
      Wuffs.Runtime.Swizzler_Prepare
        (S           => S,
         Dst_Pixfmt  => PF.Make_Pixel_Format (BGRA),
         Dst_Palette => Arena (1000 .. 2023),
         Src_Pixfmt  => PF.Make_Pixel_Format (16#8304_0008#),
         Src_Palette => Arena (3000 .. 4023),
         Blend       => PF.Blend_Src,
         Result      => St);
      Check (Wuffs.Is_Ok (St), "prepare indexed to BGRA");
      Fill;
      Wuffs.Runtime.Swizzle_Interleaved_Transparent_Black
        (S => S, Dst => Arena (5000 .. 5011), Dst_Palette => Arena (5011 .. 6034),
         Num_Pixels => 3, N => N);
      Check_U64 (N, 0, "transparent black, dst/palette overlap: N");
      Check (Is_Filled, "transparent black, dst/palette overlap: memory was written");
      Wuffs.Runtime.Swizzle_Interleaved_Transparent_Black
        (S => S, Dst => Arena (5000 .. 5011), Dst_Palette => Arena (5012 .. 6035),
         Num_Pixels => 3, N => N);
      Check_U64 (N, 3, "transparent black: N");
      Intact := True;
      for I in Wuffs.Index range 5000 .. 5011 loop
         Intact := Intact and then Arena (I) = 0;
      end loop;
      Check
        (Intact and then Arena (5012) = Wuffs.U8 (5012 mod 251), "transparent black: the pixels");

      --  An array as part of an object (what Shares_Storage answers).
      Check
        (Wuffs.Runtime.Shares_Storage (Arena (200 .. 209), Arena (209)'Address, 8)
         and then Wuffs.Runtime.Shares_Storage (Arena (200 .. 209), Arena (190)'Address, 88)
         and then Wuffs.Runtime.Shares_Storage (Arena (200 .. 209), Arena (100)'Address, 8192 * 8)
         and then not Wuffs.Runtime.Shares_Storage (Arena (200 .. 209), Arena (210)'Address, 800)
         and then not Wuffs.Runtime.Shares_Storage (Arena (200 .. 209), Arena (190)'Address, 80)
         and then not Wuffs.Runtime.Shares_Storage (Arena (200 .. 199), Arena (200)'Address, 80)
         and then not Wuffs.Runtime.Shares_Storage (Arena (200 .. 209), Arena (205)'Address, 0),
         "Shares_Storage");
   end Check_Shell;

   --  Wuffs.Runtime.Swizzle_YCCK, called directly: 4 by 4 BGRA pixels from
   --  three 4 by 4 planes (YCbCr 4:4:4).  Two arrays are written, the
   --  pixels and the scratch buffer; each must be apart from every other
   --  array, and the arrays that are only read may overlap each other.
   procedure Check_Shell_YCCK is
      --  Overlapping actuals are the point of this test.
      pragma Warnings (Off, "writable actual for * overlaps with actual for *");

      --  Where the arrays are when they are apart.
      Pix  : constant := 1000;  --  64 bytes.
      Pal  : constant := 1100;  --  1024 bytes.
      DPal : constant := 2200;  --  1024 bytes.
      Src  : constant := 3300;  --  Three planes of 16 bytes, 32 apart.
      Scr  : constant := 3500;  --  2048 bytes.

      function Swizzle
        (Pix_At, Pal_At, DPal_At, S0, S1, S2, Scr_At : Wuffs.Index;
         Scr_Length : Wuffs.Index := 2048;
         Buf        : PB.Pixel_Buffer := Good_PB;
         S3         : Wuffs.Index := 0;
         S3_Length  : Wuffs.Index := 0) return Wuffs.Status;

      function Swizzle
        (Pix_At, Pal_At, DPal_At, S0, S1, S2, Scr_At : Wuffs.Index;
         Scr_Length : Wuffs.Index := 2048;
         Buf        : PB.Pixel_Buffer := Good_PB;
         S3         : Wuffs.Index := 0;
         S3_Length  : Wuffs.Index := 0) return Wuffs.Status
      is
         St : Wuffs.Status;
      begin
         Wuffs.Runtime.Swizzle_YCCK
           (PB                => Buf,
            Pixels            => Arena (Pix_At .. Pix_At + 63),
            Palette           => Arena (Pal_At .. Pal_At + 1023),
            Dst_Palette       => Arena (DPal_At .. DPal_At + 1023),
            X_Min_Incl        => 0,
            X_Max_Excl        => 4,
            Y_Min_Incl        => 0,
            Y_Max_Excl        => 4,
            Src0              => Arena (S0 .. S0 + 15),
            Src1              => Arena (S1 .. S1 + 15),
            Src2              => Arena (S2 .. S2 + 15),
            Src3              =>
              (if S3_Length = 0 then Arena (S2 .. S2 - 1) else Arena (S3 .. S3 + S3_Length - 1)),
            Width0            => 4,
            Width1            => 4,
            Width2            => 4,
            Width3            => 0,
            Height0           => 4,
            Height1           => 4,
            Height2           => 4,
            Height3           => 0,
            Stride0           => 4,
            Stride1           => 4,
            Stride2           => 4,
            Stride3           => 0,
            H0                => 1,
            H1                => 1,
            H2                => 1,
            H3                => 0,
            V0                => 1,
            V1                => 1,
            V2                => 1,
            V3                => 0,
            YCC_Model         => 0,
            YCC_Upsampling    => 0,
            Scratch_Buffer_2K => Arena (Scr_At .. Scr_At + Scr_Length - 1),
            Result            => St);
         return St;
      end Swizzle;

      procedure Fill;

      procedure Fill is
      begin
         for I in Arena'Range loop
            Arena (I) := Wuffs.U8 (I mod 251);
         end loop;
      end Fill;

      function Is_Filled return Boolean
      is (for all I in Arena'Range => Arena (I) = Wuffs.U8 (I mod 251));

      procedure Rejected (St : Wuffs.Status; What : String);

      procedure Rejected (St : Wuffs.Status; What : String) is
      begin
         Check (St = Wuffs.Base.Error_Bad_Argument, What, -1, ": swizzle_ycck did not reject it");
         Check (Is_Filled, What, -1, ": swizzle_ycck wrote to memory");
         Fill;
      end Rejected;

      procedure Accepted (St : Wuffs.Status; What : String);

      procedure Accepted (St : Wuffs.Status; What : String) is
         Converted : Boolean := False;
      begin
         Check (Wuffs.Is_Ok (St), What, -1, ": swizzle_ycck failed");
         for I in Wuffs.Index range Pix .. Pix + 63 loop
            Converted := Converted or else Arena (I) /= Wuffs.U8 (I mod 251);
         end loop;
         Check (Converted, What, -1, ": swizzle_ycck did not write the pixels");
         Fill;
      end Accepted;

      Bad : PB.Pixel_Buffer;
      type Raw_Table is record
         Offset, Width, Height, Stride : Interfaces.Integer_64;
      end record
      with Convention => C;
      Raw : Raw_Table
      with Import, Address => Bad.Planes (0)'Address;
   begin
      Fill;
      --  Apart: it converts (and only the pixels and the scratch buffer
      --  change).
      Accepted (Swizzle (Pix, Pal, DPal, Src, Src + 32, Src + 64, Scr), "apart");
      --  Arrays that are only read may overlap one another: the three
      --  planes the same array, the destination palette over the palette,
      --  the planes inside the palettes.
      Accepted (Swizzle (Pix, Pal, DPal, Src, Src, Src, Scr), "one plane three times");
      Accepted
        (Swizzle (Pix, Pal, Pal + 7, Src, Src + 8, Src + 4, Scr), "overlapping read-only arrays");
      Accepted
        (Swizzle (Pix, Pal, Pal, Pal + 10, DPal + 20, Pal + 1000, Scr), "planes in the palettes");
      --  Adjacent: no shared element.
      Accepted (Swizzle (Pix, Pix + 64, Pix + 64, Pix - 16, Pix - 32, Pix - 48, Pix + 1088),
                "adjacent arrays");

      --  Plane 3 (std/vp8's alpha plane: the work buffer's first bytes,
      --  right before plane 0): read only, like the others.  (Its width and
      --  height are 0 here, so the proved code does not read it; the
      --  aliasing checks are made on the whole array.)
      Accepted
        (Swizzle (Pix, Pal, DPal, Src, Src + 32, Src + 64, Scr, S3 => Src - 16, S3_Length => 16),
         "plane 3 before plane 0");
      Accepted
        (Swizzle (Pix, Pal, DPal, Src, Src + 32, Src + 64, Scr, S3 => Src + 8, S3_Length => 16),
         "plane 3 over plane 0");
      Rejected
        (Swizzle (Pix, Pal, DPal, Src, Src + 32, Src + 64, Scr, S3 => Pix + 63, S3_Length => 16),
         "pixels/plane 3");
      Rejected
        (Swizzle (Pix, Pal, DPal, Src, Src + 32, Src + 64, Scr, S3 => Scr - 15, S3_Length => 16),
         "scratch/plane 3");

      --  The pixels and each array that is read, and the scratch buffer.
      Rejected (Swizzle (Pix, Pix + 63, DPal, Src, Src + 32, Src + 64, Scr), "pixels/palette");
      Rejected (Swizzle (Pix, Pal, Pix + 60, Src, Src + 32, Src + 64, Scr), "pixels/dst palette");
      Rejected (Swizzle (Pix, Pal, DPal, Pix + 10, Src + 32, Src + 64, Scr), "pixels/plane 0");
      Rejected (Swizzle (Pix, Pal, DPal, Src, Pix + 48, Src + 64, Scr), "pixels/plane 1");
      Rejected (Swizzle (Pix, Pal, DPal, Src, Src + 32, Pix - 15, Scr), "pixels/plane 2");
      Rejected
        (Swizzle (Pix, Pal, DPal, Src, Src + 32, Src + 64, Pix + 63), "pixels/scratch");
      Rejected
        (Swizzle (Scr + 100, Pal, DPal, Src, Src + 32, Src + 64, Scr), "pixels inside scratch");
      --  The scratch buffer and each array that is read.
      Rejected
        (Swizzle (Pix, Scr + 2047, DPal, Src, Src + 32, Src + 64, Scr), "scratch/palette");
      Rejected
        (Swizzle (Pix, Pal, Scr - 1023, Src, Src + 32, Src + 64, Scr), "scratch/dst palette");
      Rejected (Swizzle (Pix, Pal, DPal, Scr + 5, Src + 32, Src + 64, Scr), "scratch/plane 0");
      Rejected (Swizzle (Pix, Pal, DPal, Src, Scr + 2032, Src + 64, Scr), "scratch/plane 1");
      Rejected (Swizzle (Pix, Pal, DPal, Src, Src + 32, Scr - 15, Scr), "scratch/plane 2");
      --  A scratch buffer that is too short: the proved code's own check.
      Rejected
        (Swizzle (Pix, Pal, DPal, Src, Src + 32, Src + 64, Scr, Scr_Length => 2047),
         "short scratch");

      --  Pixel buffers that do not describe the pixels, or hold bit
      --  patterns that are no values of their types.
      Bad := Good_PB;
      Bad.Planes (0).Height := 5;
      Rejected
        (Swizzle (Pix, Pal, DPal, Src, Src + 32, Src + 64, Scr, Buf => Bad), "pb: 5 rows");
      Bad := Good_PB;
      Raw.Offset := -1;
      Rejected
        (Swizzle (Pix, Pal, DPal, Src, Src + 32, Src + 64, Scr, Buf => Bad), "pb: offset -1");
      Bad := Good_PB;
      Raw.Width := -16;
      Rejected
        (Swizzle (Pix, Pal, DPal, Src, Src + 32, Src + 64, Scr, Buf => Bad), "pb: width -16");
      Bad := Good_PB;
      Raw.Stride := Interfaces.Integer_64'Last;
      Rejected
        (Swizzle (Pix, Pal, DPal, Src, Src + 32, Src + 64, Scr, Buf => Bad),
         "pb: stride 2**63 - 1");
      Arena := [others => 16#5A#];
   end Check_Shell_YCCK;

   --  The bulk loads and saves of the shell, called directly, also with
   --  arrays that overlap (which no generated code can make for the U16,
   --  U32 and U64 forms).
   procedure Check_Shell_Bulk is
      pragma Warnings (Off, "writable actual for * overlaps with actual for *");
      use System.Storage_Elements;
      use type Wuffs.Bytes;
      use type Wuffs.U16;

      procedure Fill;

      procedure Fill is
      begin
         for I in Arena'Range loop
            Arena (I) := Wuffs.U8 (I mod 251);
         end loop;
      end Fill;

      function Is_Filled return Boolean
      is (for all I in Arena'Range => Arena (I) = Wuffs.U8 (I mod 251));

      --  An index of Arena whose address is a multiple of 8, for overlays.
      function Aligned (From : Wuffs.Index) return Wuffs.Index is
        (From + Wuffs.Index ((8 - To_Integer (Arena (From)'Address) mod 8) mod 8));

      A : constant Wuffs.Index := Aligned (3000);
      U16s : Wuffs.U16_Array (0 .. 7)
      with Import, Address => Arena (A)'Address;
      U32s : Wuffs.U32_Array (0 .. 3)
      with Import, Address => Arena (A)'Address;
      U64s : Wuffs.U64_Array (0 .. 1)
      with Import, Address => Arena (A)'Address;
      Before : Wuffs.Bytes (0 .. 31);
      OK     : Boolean;
      Little : constant Boolean := Wuffs.Base.Slices.Host_Is_Little_Endian;
   begin
      --  Bytes: the source and the destination overlap, both ways round:
      --  the result is a memmove's.
      Fill;
      Before := Arena (1000 .. 1031);
      Wuffs.Runtime.Bulk_Load_Host_Endian_U8
        (Dst => Arena (1004 .. 1013), Src => Arena (1000 .. 1031));
      Check
        (Arena (1004 .. 1013) = Before (0 .. 9) and then Arena (1000 .. 1003) = Before (0 .. 3)
         and then Arena (1014 .. 1031) = Before (14 .. 31), "bulk load, U8, overlapping forwards");
      Fill;
      Wuffs.Runtime.Bulk_Load_Host_Endian_U8
        (Dst => Arena (1000 .. 1009), Src => Arena (1003 .. 1031));
      Check
        (Arena (1000 .. 1009) = Before (3 .. 12) and then Arena (1010 .. 1031) = Before (10 .. 31),
         "bulk load, U8, overlapping backwards");
      Fill;
      Wuffs.Runtime.Bulk_Save_Host_Endian_U8
        (Dst => Arena (1002 .. 1031), Src => Arena (1000 .. 1009));
      Check
        (Arena (1002 .. 1011) = Before (0 .. 9) and then Arena (1012 .. 1031) = Before (12 .. 31),
         "bulk save, U8, overlapping");
      Fill;
      --  All or nothing: a source shorter than the destination.
      Wuffs.Runtime.Bulk_Load_Host_Endian_U8
        (Dst => Arena (1000 .. 1009), Src => Arena (1005 .. 1013));
      Check (Is_Filled, "bulk load, U8, short source: memory was written");
      Wuffs.Runtime.Bulk_Save_Host_Endian_U8
        (Dst => Arena (1000 .. 1008), Src => Arena (1004 .. 1013));
      Check (Is_Filled, "bulk save, U8, short destination: memory was written");

      --  Wider numbers from and to bytes that are apart: host byte order;
      --  a byte array of an odd length; all or nothing.
      Fill;
      Before := Arena (1000 .. 1031);
      Wuffs.Runtime.Bulk_Load_Host_Endian_U16
        (Dst => U16s (1 .. 3), Src => Arena (1000 .. 1006));
      OK := True;
      for I in Wuffs.Index range 0 .. 2 loop
         OK := OK and then U16s (1 + I) =
           (if Little
            then Wuffs.U16 (Before (2 * I)) + 256 * Wuffs.U16 (Before (2 * I + 1))
            else Wuffs.U16 (Before (2 * I + 1)) + 256 * Wuffs.U16 (Before (2 * I)));
      end loop;
      Check (OK and then Arena (1000 .. 1031) = Before, "bulk load, U16, from 7 bytes");
      Fill;
      Wuffs.Runtime.Bulk_Load_Host_Endian_U16
        (Dst => U16s (1 .. 3), Src => Arena (1000 .. 1004));
      Check (Is_Filled, "bulk load, U16, from 5 bytes: memory was written");
      Wuffs.Runtime.Bulk_Save_Host_Endian_U32
        (Dst => Arena (1000 .. 1006), Src => U32s (0 .. 1));
      Check (Is_Filled, "bulk save, U32, to 7 bytes: memory was written");
      Wuffs.Runtime.Bulk_Save_Host_Endian_U64
        (Dst => Arena (1000 .. 1008), Src => U64s (0 .. 0));
      Check
        (Arena (1000 .. 1007) = Arena (A .. A + 7) and then Arena (1008) = Wuffs.U8 (1008 mod 251),
         "bulk save, U64, to 9 bytes");
      Fill;

      --  Overlapping: nothing at all is copied.
      Wuffs.Runtime.Bulk_Load_Host_Endian_U16 (Dst => U16s, Src => Arena (A + 3 .. A + 40));
      Check (Is_Filled, "bulk load, U16, from an overlapping source: memory was written");
      Wuffs.Runtime.Bulk_Save_Host_Endian_U16
        (Dst => Arena (A - 1 .. A + 30), Src => U16s (0 .. 1));
      Check (Is_Filled, "bulk save, U16, to an overlapping destination: memory was written");
      Wuffs.Runtime.Bulk_Load_Host_Endian_U32
        (Dst => U32s (1 .. 2), Src => Arena (A + 4 .. A + 11));
      Check (Is_Filled, "bulk load, U32, from itself: memory was written");
      Wuffs.Runtime.Bulk_Save_Host_Endian_U32 (Dst => Arena (A + 15 .. A + 30), Src => U32s);
      Check (Is_Filled, "bulk save, U32, to an overlapping destination: memory was written");
      Wuffs.Runtime.Bulk_Load_Host_Endian_U64 (Dst => U64s, Src => Arena (A - 8 .. A + 7));
      Check (Is_Filled, "bulk load, U64, from an overlapping source: memory was written");
      Wuffs.Runtime.Bulk_Save_Host_Endian_U64 (Dst => Arena (A .. A + 15), Src => U64s);
      Check (Is_Filled, "bulk save, U64, to itself: memory was written");
      Arena := [others => 16#5A#];
   end Check_Shell_Bulk;

   procedure Check_Messages is
      Buffer : String (1 .. 80);
      Short  : String (5 .. 9);
      Length : Natural;

      procedure Expect (S : Wuffs.Status; K : Message_Kind; Text : String);

      procedure Expect (S : Wuffs.Status; K : Message_Kind; Text : String) is
         L : Natural;
      begin
         for Other in Message_Kind loop
            case Other is
               when Netpbm =>
                  L := Wuffs.Std.Netpbm.Message_Length (S);
                  Wuffs.Std.Netpbm.Get_Message (S, Buffer, Length);
               when Bmp =>
                  L := Wuffs.Std.Bmp.Message_Length (S);
                  Wuffs.Std.Bmp.Get_Message (S, Buffer, Length);
               when Gif =>
                  L := Wuffs.Std.Gif.Message_Length (S);
                  Wuffs.Std.Gif.Get_Message (S, Buffer, Length);
               when Png =>
                  L := Wuffs.Std.Png.Message_Length (S);
                  Wuffs.Std.Png.Get_Message (S, Buffer, Length);
               when Jpeg =>
                  L := Wuffs.Std.Jpeg.Message_Length (S);
                  Wuffs.Std.Jpeg.Get_Message (S, Buffer, Length);
               when Vp8 =>
                  L := Wuffs.Std.Vp8.Message_Length (S);
                  Wuffs.Std.Vp8.Get_Message (S, Buffer, Length);
               when Webp =>
                  L := Wuffs.Std.Webp.Message_Length (S);
                  Wuffs.Std.Webp.Get_Message (S, Buffer, Length);
            end case;
            if Other = K then
               Check
                 (L = Text'Length and then Length = Text'Length
                  and then Buffer (1 .. Length) = Text
                  and then (for all I in Length + 1 .. Buffer'Last => Buffer (I) = ' '),
                  "message: ", -1, Text);
            else
               --  Another package's status has no message here.
               Check
                 (L = 0 and then Length = 0 and then (for all C of Buffer => C = ' '),
                  "message of another package: ", -1, Text);
            end if;
         end loop;
         Check (Wuffs.Base.Message_Length (S) = 0, "a base message for: ", -1, Text);
      end Expect;
   begin
      Expect (Wuffs.Std.Netpbm.Error_Bad_Header, Netpbm, "netpbm: bad header");
      Expect (Wuffs.Std.Netpbm.Error_Truncated_Input, Netpbm, "netpbm: truncated input");
      Expect (Wuffs.Std.Bmp.Error_Bad_Header, Bmp, "bmp: bad header");
      Expect (Wuffs.Std.Bmp.Error_Unsupported_BMP_File, Bmp, "bmp: unsupported BMP file");
      Expect (Wuffs.Std.Gif.Error_Bad_LZW_Code, Gif, "gif: bad LZW code");
      Expect (Wuffs.Std.Gif.Error_Truncated_Input, Gif, "gif: truncated input");
      Expect (Wuffs.Std.Png.Error_Bad_Checksum, Png, "png: bad checksum");
      Expect
        (Wuffs.Std.Png.Error_Bad_Text_Chunk_Not_Latin_1, Png,
         "png: bad text chunk (not Latin-1)");
      Expect (Wuffs.Std.Jpeg.Error_Bad_DHT_Marker, Jpeg, "jpeg: bad DHT marker");
      Expect
        (Wuffs.Std.Jpeg.Error_Unsupported_Precision_12_Bits, Jpeg,
         "jpeg: unsupported precision (12 bits)");
      Expect (Wuffs.Std.Vp8.Error_Bad_QUIRK_SOURCE_LENGTH, Vp8, "vp8: bad QUIRK_SOURCE_LENGTH");
      Expect (Wuffs.Std.Vp8.Error_Unsupported_VP8_File, Vp8, "vp8: unsupported VP8 file");
      Expect
        (Wuffs.Std.Webp.Error_Bad_ALPH_VP8L_Combination, Webp, "webp: bad ALPH+VP8L combination");
      Expect
        (Wuffs.Std.Webp.Error_Bad_Huffman_Code_Over_Subscribed, Webp,
         "webp: bad Huffman code (over-subscribed)");
      Expect (Wuffs.Std.Webp.Error_Truncated_Input, Webp, "webp: truncated input");
      Expect
        (Wuffs.Std.Webp.Error_Unsupported_Number_Of_Huffman_Groups, Webp,
         "webp: unsupported number of Huffman groups");
      --  A buffer that is too short gets the start of the message.
      Wuffs.Std.Png.Get_Message (Wuffs.Std.Png.Error_Bad_Checksum, Short, Length);
      Check (Length = 5 and then Short = "png: ", "message in a short buffer");
      Wuffs.Std.Png.Get_Message (Wuffs.Std.Png.Error_Bad_Checksum, Short (5 .. 4), Length);
      Check (Length = 0, "message in an empty buffer");
      --  Ok and the base package's statuses have no message in a package.
      Wuffs.Std.Gif.Get_Message (Wuffs.Ok_Status, Buffer, Length);
      Check
        (Length = 0 and then Wuffs.Std.Gif.Message_Length (Wuffs.Ok_Status) = 0, "message of ok");
      Wuffs.Std.Gif.Get_Message (Wuffs.Base.Error_Bad_Argument, Buffer, Length);
      Check (Length = 0, "message of a base status in a package");
      Wuffs.Base.Get_Message (Wuffs.Base.Error_Bad_Argument, Buffer, Length);
      Check (Buffer (1 .. Length) = "base: bad argument", "the base package's own message");
   end Check_Messages;

   --  After everything above, the decoders still decode: a 2 by 2 PPM.
   procedure Check_Tiny_Image is
      Text : constant String := "P6" & ASCII.LF & "2 2" & ASCII.LF & "255" & ASCII.LF;
      Src  : Wuffs.Bytes (7 .. 7 + Text'Length + 11);
      Meta : IO.Buffer_Meta := (Wi => Src'Length, Ri => 0, Pos => 0, Closed => True);
      IC   : PF.Image_Config;
      Opts : Wuffs.Runtime.Decode_Frame_Options;
      St   : Wuffs.Status;
      OK   : Boolean := True;
   begin
      for I in Text'Range loop
         Src (Src'First + Wuffs.Index (I - Text'First)) := Character'Pos (Text (I));
      end loop;
      for I in Wuffs.Index range 0 .. 11 loop
         Src (Src'First + Text'Length + I) := Wuffs.U8 (10 * I + 1);
      end loop;
      Arena := [others => 16#5A#];
      Wuffs.Std.Netpbm.Initialize (IMS.Netpbm_Decoder);
      St :=
        IMS.Netpbm_Decoder.Decode_Image_Config
          (A_Dst => IC, A_Dst_Null => False, A_Src => Src, A_Src_Meta => Meta);
      Check
        (Wuffs.Is_Ok (St) and then IC.Pixcfg.Width = 2 and then IC.Pixcfg.Height = 2, "tiny PPM");
      St :=
        IMS.Netpbm_Decoder.Decode_Frame
          (A_Dst         => Good_PB,
           A_Dst_Pixels  => Arena (1000 .. 1063),
           A_Dst_Palette => Arena (1064 .. 1063),
           A_Src         => Src,
           A_Src_Meta    => Meta,
           A_Blend       => PF.Blend_Src,
           A_Workbuf     => Arena (1070 .. 1069),
           A_Opts        => Opts,
           A_Opts_Null   => True);
      Check (Wuffs.Is_Ok (St), "tiny PPM: decode_frame");
      --  Pixel (X, Y) is at 1000 + 16 * Y + 4 * X, as B, G, R, A.
      for Y in Wuffs.Index range 0 .. 1 loop
         for X in Wuffs.Index range 0 .. 1 loop
            declare
               P : constant Wuffs.Index := 1000 + 16 * Y + 4 * X;
               V : constant Wuffs.Index := 10 * (3 * (2 * Y + X)) + 1;
            begin
               OK := OK and then Arena (P) = Wuffs.U8 (V + 20)
                 and then Arena (P + 1) = Wuffs.U8 (V + 10)
                 and then Arena (P + 2) = Wuffs.U8 (V) and then Arena (P + 3) = 16#FF#;
            end;
         end loop;
      end loop;
      Check (OK, "tiny PPM: the pixels");
      Check (Arena (999) = 16#5A# and then Arena (1008) = 16#5A# and then Arena (1024) = 16#5A#,
             "tiny PPM: bytes outside of the image");
   end Check_Tiny_Image;

   Cfg : PF.Pixel_Config;
   St  : Wuffs.Status;

begin
   PF.Set (C => Cfg, Pixfmt_Repr => BGRA, Pixsub_Repr => 0, Width => 4, Height => 4);
   PB.Set_Interleaved
     (PB             => Good_PB,
      Pixcfg         => Cfg,
      Primary        => (Offset => 0, Width => 16, Height => 4, Stride => 16),
      Pixels_Length  => 64,
      Palette_Length => 1024,
      Result         => St);
   Check (Wuffs.Is_Ok (St) and then Good_PB /= PB.Null_Pixel_Buffer, "Set_Interleaved");

   --  Initialize leaves every decoder's swizzler as the default one, also
   --  when the object held something else before.
   for K in Kind loop
      declare
         Address : constant System.Address :=
           (case K is
              when Netpbm => IMS.Netpbm_Decoder'Address,
              when Bmp => IMS.Bmp_Decoder'Address,
              when Gif => IMS.Gif_Decoder'Address,
              when Png => IMS.Png_Decoder'Address,
              when Jpeg => IMS.Jpeg_Decoder'Address,
              when Vp8 => IMS.Vp8_Decoder'Address,
              when Webp => IMS.Webp_Decoder'Address,
              when Wbmp => IMS.Wbmp_Decoder'Address,
              when Nie => IMS.Nie_Decoder'Address,
              when Targa => IMS.Targa_Decoder'Address,
              when Qoi => IMS.Qoi_Decoder'Address);
         Size    : constant Long_Long_Integer :=
           (case K is
              when Netpbm => IMS.Netpbm_Decoder'Size,
              when Bmp => IMS.Bmp_Decoder'Size,
              when Gif => IMS.Gif_Decoder'Size,
              when Png => IMS.Png_Decoder'Size,
              when Jpeg => IMS.Jpeg_Decoder'Size,
              when Vp8 => IMS.Vp8_Decoder'Size,
              when Webp => IMS.Webp_Decoder'Size,
              when Wbmp => IMS.Wbmp_Decoder'Size,
              when Nie => IMS.Nie_Decoder'Size,
              when Targa => IMS.Targa_Decoder'Size,
              when Qoi => IMS.Qoi_Decoder'Size);
         --  The object without its tag.
         Raw     : Wuffs.Bytes (0 .. Wuffs.Index (Size / 8) - 1)
         with Import, Address => Address;
      begin
         Raw (16 .. Raw'Last) := [others => 16#01#];
         Initialize (K);
         Check (Swizzler_Is_Default (K), "the swizzler after Initialize", Kind'Pos (K));
      end;
   end loop;

   Check_Shell;
   Check_Shell_YCCK;
   Check_Shell_Bulk;
   Check_Overlaps (IMS.Netpbm_Decoder, Netpbm, IMS.Netpbm_Decoder'Size);
   Check_Overlaps (IMS.Jpeg_Decoder, Jpeg, IMS.Jpeg_Decoder'Size);
   Check_Overlaps (IMS.Bmp_Decoder, Bmp, IMS.Bmp_Decoder'Size);
   Check_Overlaps (IMS.Gif_Decoder, Gif, IMS.Gif_Decoder'Size);
   Check_Overlaps (IMS.Png_Decoder, Png, IMS.Png_Decoder'Size);
   Check_Overlaps (IMS.Wbmp_Decoder, Wbmp, IMS.Wbmp_Decoder'Size);
   Check_Overlaps (IMS.Nie_Decoder, Nie, IMS.Nie_Decoder'Size);
   Check_Overlaps (IMS.Targa_Decoder, Targa, IMS.Targa_Decoder'Size);
   Check_Overlaps (IMS.Qoi_Decoder, Qoi, IMS.Qoi_Decoder'Size);
   Check_Overlaps (IMS.Vp8_Decoder, Vp8, IMS.Vp8_Decoder'Size);
   Check_Overlaps (IMS.Webp_Decoder, Webp, IMS.Webp_Decoder'Size);
   Check_Descriptors (IMS.Netpbm_Decoder, Netpbm);
   Check_Descriptors (IMS.Bmp_Decoder, Bmp);
   Check_Descriptors (IMS.Gif_Decoder, Gif);
   Check_Descriptors (IMS.Png_Decoder, Png);
   Check_Descriptors (IMS.Jpeg_Decoder, Jpeg);
   Check_Descriptors (IMS.Wbmp_Decoder, Wbmp);
   Check_Descriptors (IMS.Nie_Decoder, Nie);
   Check_Descriptors (IMS.Targa_Decoder, Targa);
   Check_Descriptors (IMS.Qoi_Decoder, Qoi);
   Check_Descriptors (IMS.Vp8_Decoder, Vp8);
   Check_Descriptors (IMS.Webp_Decoder, Webp);
   Check_Metas (IMS.Netpbm_Decoder, Netpbm);
   Check_Metas (IMS.Bmp_Decoder, Bmp);
   Check_Metas (IMS.Gif_Decoder, Gif);
   Check_Metas (IMS.Png_Decoder, Png);
   Check_Metas (IMS.Jpeg_Decoder, Jpeg);
   Check_Metas (IMS.Wbmp_Decoder, Wbmp);
   Check_Metas (IMS.Nie_Decoder, Nie);
   Check_Metas (IMS.Targa_Decoder, Targa);
   Check_Metas (IMS.Qoi_Decoder, Qoi);
   Check_Metas (IMS.Vp8_Decoder, Vp8);
   Check_Metas (IMS.Webp_Decoder, Webp);
   Check_Messages;
   Check_Tiny_Image;

   Put_Size ("Wuffs.Std.Netpbm.Decoder", IMS.Netpbm_Decoder'Size);
   Put_Size ("Wuffs.Std.Bmp.Decoder", IMS.Bmp_Decoder'Size);
   Put_Size ("Wuffs.Std.Gif.Decoder", IMS.Gif_Decoder'Size);
   Put_Size ("Wuffs.Std.Png.Decoder", IMS.Png_Decoder'Size);
   Put_Size ("Wuffs.Std.Jpeg.Decoder", IMS.Jpeg_Decoder'Size);
   Put_Size ("Wuffs.Std.Wbmp.Decoder", IMS.Wbmp_Decoder'Size);
   Put_Size ("Wuffs.Std.Nie.Decoder", IMS.Nie_Decoder'Size);
   Put_Size ("Wuffs.Std.Targa.Decoder", IMS.Targa_Decoder'Size);
   Put_Size ("Wuffs.Std.Qoi.Decoder", IMS.Qoi_Decoder'Size);
   Put_Size ("Wuffs.Std.Etc2.Decoder", IMS.Etc2_Decoder'Size);
   Put_Size ("Wuffs.Std.Thumbhash.Decoder", IMS.Thumbhash_Decoder'Size);
   Put_Size ("Wuffs.Std.Handsum.Decoder", IMS.Handsum_Decoder'Size);
   Put_Size ("Wuffs.Std.Vp8.Decoder", IMS.Vp8_Decoder'Size);
   Put_Size ("Wuffs.Std.Webp.Decoder", IMS.Webp_Decoder'Size);
   --  The token decoders (json, cbor): see token_hostile.adb.
   Token_Hostile;

   Test_Support.Finish ("test_hostile");
end Test_Hostile;
