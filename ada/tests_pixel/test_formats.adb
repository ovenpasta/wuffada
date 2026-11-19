--  Wuffs.Base.Pixel_Formats.  The sweeps mirror sweep_formats in
--  oracle/oracle.c.

with Interfaces;
with Pixel_Oracle_Data;
with Pixel_Test_Support; use Pixel_Test_Support;
with Wuffs.Base.Pixel_Formats;
with Wuffs.Base.Ranges;

procedure Test_Formats is

   use Wuffs;
   use Wuffs.Base.Pixel_Formats;
   use type Interfaces.Unsigned_8;
   use type Interfaces.Unsigned_32;
   use type Interfaces.Unsigned_64;
   use type Wuffs.Base.Ranges.Rect_IE_U32;

   Subsamplings : constant array (0 .. 5) of U32 :=
     [16#00_0000#, 16#01_0100#, 16#10_1000#, 16#11_1100#, 16#30_3000#, 16#31_3100#];
   Dims : constant array (0 .. 7) of U32 :=
     [0, 1, 2, 3, 16#FFFF#, 16#1_0000#, 16#FF_FFFF#, 16#FFFF_FFFF#];

   procedure Mix_Format (Repr : U32);

   procedure Mix_Format (Repr : U32) is
      F : constant Pixel_Format := Make_Pixel_Format (Repr);
   begin
      Mix (Is_Valid (F));
      Mix (U64 (Bits_Per_Pixel (F)));
      Mix (U64 (Default_Background_Color (F)));
      Mix (Is_Direct (F));
      Mix (Is_Indexed (F));
      Mix (Is_Interleaved (F));
      Mix (Is_Planar (F));
      Mix (U64 (Coloration (F)));
      Mix (U64 (Num_Planes (F)));
      Mix (U64 (Transparency (F)));
   end Mix_Format;

begin
   -------------
   -- Formats --
   -------------

   Start (111);
   for Repr of Formats loop
      Mix_Format (Repr);
   end loop;
   for I in 1 .. 2000 loop
      Mix_Format (U32 (Interfaces.Shift_Right (Rnd, 32)));
   end loop;
   for I in 0 .. 205 loop
      declare
         S : constant Pixel_Subsampling :=
           Make_Pixel_Subsampling
             (if I < 6 then Subsamplings (I) else U32 (Interfaces.Shift_Right (Rnd, 32)));
      begin
         for Plane in U32 range 0 .. 5 loop
            Mix (U64 (Bias_X (S, Plane)));
            Mix (U64 (Denominator_X (S, Plane)));
            Mix (U64 (Bias_Y (S, Plane)));
            Mix (U64 (Denominator_Y (S, Plane)));
         end loop;
      end;
   end loop;
   Finish ("formats: sweep Formats", Pixel_Oracle_Data.Formats);

   -------------
   -- Configs --
   -------------

   Start (112);
   for Repr of Formats loop
      for W in Dims'Range loop
         for H in Dims'Range loop
            declare
               C  : Pixel_Config;
               IC : Image_Config;
               B  : Wuffs.Base.Ranges.Rect_IE_U32;
               P  : U64;
            begin
               Set (C, Repr, Subsamplings (W mod 6), Dims (W), Dims (H));
               Mix (Is_Valid (C));
               Mix (U64 (Get_Pixel_Format (C).Repr));
               Mix (U64 (Get_Pixel_Subsampling (C).Repr));
               Mix (U64 (Width (C)));
               Mix (U64 (Height (C)));
               B := Bounds (C);
               Mix (U64 (B.Min_Incl_X));
               Mix (U64 (B.Min_Incl_Y));
               Mix (U64 (B.Max_Excl_X));
               Mix (U64 (B.Max_Excl_Y));
               Mix (Pixbuf_Len (C));

               P := Rnd;
               Set (IC, Repr, Subsamplings (H mod 6), Dims (W), Dims (H), P, W mod 2 = 1);
               Mix (Is_Valid (IC));
               Mix (First_Frame_IO_Position (IC));
               Mix (First_Frame_Is_Opaque (IC));
               Mix (Pixbuf_Len (IC.Pixcfg));
               Mix (U64 (Width (IC.Pixcfg)));
            end;
         end loop;
      end loop;
   end loop;
   Finish ("formats: sweep Configs", Pixel_Oracle_Data.Configs);

   ----------------------
   -- Pixbuf_Len_Edges --
   ----------------------

   declare
      Reprs : constant array (0 .. 4) of U32 :=
        [16#8104_0088#, 16#8104_8888#, 16#8104_0008#, 16#8104_BBBB#, 16#8104_0888#];
      type Pair is array (0 .. 1) of U32;
      Sizes : constant array (0 .. 10) of Pair :=
        [[4294967264, 2147483664], [4294967265, 2147483664], [4294967263, 2147483664],
         [2147483647, 2147483649], [2147483647, 2147483648], [4294967295, 4294967295],
         [65536, 65536], [3, 5], [4294967295, 2863311530], [4294967295, 1431655765],
         [4294967294, 1431655766]];
      C : Pixel_Config;
   begin
      Start (114);
      for R of Reprs loop
         for D of Sizes loop
            Set (C, R, 0, D (0), D (1));
            Mix (Pixbuf_Len (C));
         end loop;
      end loop;
      Finish ("formats: sweep Pixbuf_Len_Edges", Pixel_Oracle_Data.Pixbuf_Len_Edges);
      --  The palette's 1024 bytes are what does not fit (2 bytes per pixel).
      Set (C, 16#8104_0088#, 0, 4294967264, 2147483664);
      Check (Pixbuf_Len (C) = 0, "formats: pixbuf_len, palette overflows");
   end;

   -------------------
   -- Frame_Configs --
   -------------------

   Start (113);
   for I in 0 .. 49 loop
      declare
         A  : constant U64 := Rnd;
         B  : constant U64 := Rnd;
         C  : constant U64 := Rnd;
         D  : constant U64 := Rnd;
         E  : constant U64 := Rnd;
         FC : Frame_Config;
         R  : Wuffs.Base.Ranges.Rect_IE_U32;
      begin
         Set
           (FC,
            Bounds                     =>
              (Min_Incl_X => U32 (A and 16#FFFF_FFFF#),
               Min_Incl_Y => U32 (Interfaces.Shift_Right (A, 32)),
               Max_Excl_X => U32 (B and 16#FFFF_FFFF#),
               Max_Excl_Y => U32 (Interfaces.Shift_Right (B, 32))),
            Duration                   => Interfaces.Shift_Right (C, 1),
            Index                      => D,
            IO_Position                => E,
            Disposal                   => Animation_Disposal (I mod 3),
            Opaque_Within_Bounds       => I mod 2 = 1,
            Overwrite_Instead_Of_Blend => (I / 2) mod 2 = 1,
            Background_Color           =>
              U32 (Interfaces.Shift_Right (E, 7) and 16#FFFF_FFFF#));
         R := Bounds (FC);
         Mix (U64 (R.Min_Incl_X));
         Mix (U64 (R.Min_Incl_Y));
         Mix (U64 (R.Max_Excl_X));
         Mix (U64 (R.Max_Excl_Y));
         Mix (U64 (Width (FC)));
         Mix (U64 (Height (FC)));
         Mix (Get_Duration (FC));
         Mix (Get_Index (FC));
         Mix (IO_Position (FC));
         Mix (U64 (Disposal (FC)));
         Mix (Opaque_Within_Bounds (FC));
         Mix (Overwrite_Instead_Of_Blend (FC));
         Mix (U64 (Background_Color (FC)));
      end;
   end loop;
   Finish ("formats: sweep Frame_Configs", Pixel_Oracle_Data.Frame_Configs);

   --------------------
   -- Explicit cases --
   --------------------

   Check (Bits_Per_Pixel (Y) = 8 and then Bits_Per_Pixel (Y_16LE) = 16, "formats: bpp y");
   Check (Bits_Per_Pixel (BGR_565) = 16 and then Bits_Per_Pixel (BGR) = 24, "formats: bpp bgr");
   Check (Bits_Per_Pixel (BGRA_Premul) = 32, "formats: bpp bgra");
   Check (Bits_Per_Pixel (RGBA_Nonpremul_4x16LE) = 64, "formats: bpp 4x16");
   Check (Bits_Per_Pixel (Indexed_BGRA_Binary) = 8, "formats: bpp indexed");
   Check (Bits_Per_Pixel (YCbCr) = 0 and then Is_Planar (YCbCr), "formats: planar bpp");
   Check (Bits_Per_Pixel (Make_Pixel_Format (16#0000_FFFF#)) = 256, "formats: bpp max");
   Check (Bytes_Per_Pixel (BGR_565) = 2 and then Bytes_Per_Pixel (YCbCr) = 0,
          "formats: bytes per pixel");
   Check (Bytes_Per_Pixel (Make_Pixel_Format (16#0000_0001#)) = 0,
          "formats: bytes per pixel of a 1 bit format");
   Check (Is_Indexed (Indexed_BGRA_Nonpremul) and then Is_Direct (BGR), "formats: indexed");
   Check (Num_Planes (YCbCrK) = 4 and then Num_Planes (BGR) = 1, "formats: planes");
   Check (Transparency (BGRX) = Opaque
          and then Transparency (BGRA_Nonpremul) = Nonpremultiplied_Alpha
          and then Transparency (BGRA_Premul) = Premultiplied_Alpha
          and then Transparency (BGRA_Binary) = Binary_Alpha, "formats: transparency");
   Check (Coloration (A) = Coloration_None and then Coloration (Y) = Coloration_Gray
          and then Coloration (RGB) = Coloration_Rich, "formats: coloration");
   Check (Default_Background_Color (BGR) = 16#FF00_0000#
          and then Default_Background_Color (BGRA_Premul) = 0, "formats: background");
   Check (not Is_Valid (Invalid) and then Is_Valid (Y), "formats: validity");
   Check (Denominator_X (Subsampling_420, 1) = 2 and then Denominator_Y (Subsampling_420, 1) = 2
          and then Denominator_X (Subsampling_420, 0) = 1, "formats: 420 subsampling");
   Check (Demake_Pixel_Blend (Make_Pixel_Blend (1)) = 1
          and then Make_Pixel_Blend (1) = Blend_Src_Over,
          "formats: blend");

   declare
      C  : Pixel_Config;
      IC : Image_Config;
   begin
      Check (not Is_Valid (C) and then C = Null_Pixel_Config, "formats: default config");
      Set (C, Repr_BGRA_Premul, 0, 3, 5);
      Check (Is_Valid (C) and then Pixbuf_Len (C) = 60, "formats: pixbuf_len");
      Check (Bounds (C) = (0, 0, 3, 5), "formats: bounds");
      Set (C, Repr_Indexed_BGRA_Binary, 0, 3, 5);
      Check (Pixbuf_Len (C) = 15 + 1024, "formats: pixbuf_len indexed");
      Set (C, Repr_BGRA_Premul_4x16LE, 0, 16#FFFF_FFFF#, 16#FFFF_FFFF#);
      Check (Pixbuf_Len (C) = 0, "formats: pixbuf_len overflow");
      Set (C, Repr_BGRA_Premul, 0, 16#FFFF_FFFF#, 16#FFFF_FFFF#);
      Check (Pixbuf_Len (C) = 0, "formats: pixbuf_len overflow by 4");
      Set (C, Repr_Y, 0, 16#FFFF_FFFF#, 16#FFFF_FFFF#);
      Check (Pixbuf_Len (C) = 16#FFFF_FFFE_0000_0001#, "formats: pixbuf_len largest");
      Set (C, Repr_Indexed_BGRA_Binary, 0, 16#FFFF_FFFF#, 16#FFFF_FFFF#);
      Check (Pixbuf_Len (C) = 16#FFFF_FFFE_0000_0401#, "formats: pixbuf_len largest indexed");
      Set (C, Repr_YCbCr, 0, 3, 5);
      Check (Is_Valid (C) and then Pixbuf_Len (C) = 0, "formats: pixbuf_len planar");
      Set (C, 0, 7, 3, 5);
      Check (C = Null_Pixel_Config, "formats: set with invalid format");
      Set (C, Repr_Y, 0, 3, 5);
      Invalidate (C);
      Check (C = Null_Pixel_Config, "formats: invalidate");
      Set (IC, 0, 0, 1, 1, 99, True);
      Check (IC = Null_Image_Config and then not Is_Valid (IC), "formats: image config invalid");
      Set (IC, Repr_Y, 0, 1, 1, 99, True);
      Check (Is_Valid (IC) and then First_Frame_IO_Position (IC) = 99
             and then First_Frame_Is_Opaque (IC), "formats: image config");
      Invalidate (IC);
      Check (IC = Null_Image_Config, "formats: image config invalidate");
   end;
end Test_Formats;
