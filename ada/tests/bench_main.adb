--  Part of wuffada (wuffs-ada: Wuffs to Ada).
--  SPDX-License-Identifier: Apache-2.0 OR MIT

--  A benchmark of generated decoders, for ada/tests/bench/run.sh (it is not
--  a test and not part of test.sh).  Standard input has one line per
--  measurement, "KIND REPETITIONS PATH", with KIND one of crc32, adler32
--  (hash the file), gzip (decompress it), png, gif (decode every frame to
--  BGRA_PREMUL).  For each it prints
--
--    KIND PATH BYTES NANOSECONDS RESULT
--
--  where BYTES is the size of the file, NANOSECONDS the fastest of the
--  repetitions and RESULT a checksum of what was computed, to compare with
--  ada/tests/bench/bench.c's.

with Ada.Real_Time;
with Ada.Streams.Stream_IO;
with Ada.Text_IO;
with Decode_Support;
with Image_Support;
with Wuffs.Base.IO;
with Wuffs.Base.Pixel_Buffers;
with Wuffs.Base.Pixel_Formats;
with Wuffs.Runtime;
with Wuffs.Std.Adler32;
with Wuffs.Std.Crc32;
with Wuffs.Std.Gif;
with Wuffs.Std.Gzip;
with Wuffs.Std.Png;
with Wuffs.Std.Jpeg;

procedure Bench_Main is

   package IMS renames Image_Support;
   package IO renames Wuffs.Base.IO;
   package PB renames Wuffs.Base.Pixel_Buffers;
   package PF renames Wuffs.Base.Pixel_Formats;

   use type Wuffs.U64;
   use type Wuffs.Index;
   use type Wuffs.Status;
   use type Ada.Real_Time.Time;
   use type Ada.Real_Time.Time_Span;

   Adler : Wuffs.Std.Adler32.Hasher;
   Crc   : Wuffs.Std.Crc32.Ieee_Hasher;
   Gzip  : Wuffs.Std.Gzip.Decoder renames Decode_Support.Gzip_Decoder;

   Len    : Wuffs.Index := 0;
   Result : Wuffs.U64 := 0;
   Failed : Boolean := False;

   procedure Load (Name : String; OK : out Boolean);

   procedure Fnv (H : in out Wuffs.U64; Data : Wuffs.Bytes);

   procedure Put_Number (X : Wuffs.U64);

   --  One repetition of each kind: sets Result.
   procedure Hash_Crc32;

   procedure Hash_Adler32;

   procedure Decode_Gzip;

   procedure Decode_Image (D : in out Wuffs.Runtime.Image_Decoder'Class);

   procedure Measure (Line : String);

   procedure Load (Name : String; OK : out Boolean) is
      package SIO renames Ada.Streams.Stream_IO;
      File : SIO.File_Type;
      Size : SIO.Count;
   begin
      OK := False;
      SIO.Open (File, SIO.In_File, Name);
      Size := SIO.Size (File);
      if Size in 1 .. IMS.Cap_File then
         declare
            use type Ada.Streams.Stream_Element_Offset;
            Item : Ada.Streams.Stream_Element_Array (1 .. Ada.Streams.Stream_Element_Offset (Size))
            with Import, Address => IMS.File'Address;
            Last : Ada.Streams.Stream_Element_Offset;
         begin
            SIO.Read (File, Item, Last);
            OK := Last = Item'Last;
         end;
         Len := Wuffs.Index (Size);
      end if;
      SIO.Close (File);
   exception
      when others =>
         OK := False;
   end Load;

   procedure Fnv (H : in out Wuffs.U64; Data : Wuffs.Bytes) is
   begin
      for B of Data loop
         H := (H xor Wuffs.U64 (B)) * 16#100_0000_01B3#;
      end loop;
   end Fnv;

   procedure Put_Number (X : Wuffs.U64) is
      Text  : String (1 .. 20);
      First : Natural := Text'Last + 1;
      Rest  : Wuffs.U64 := X;
   begin
      loop
         First := First - 1;
         Text (First) := Character'Val (Character'Pos ('0') + Natural (Rest mod 10));
         Rest := Rest / 10;
         exit when Rest = 0;
      end loop;
      Ada.Text_IO.Put (Text (First .. Text'Last));
   end Put_Number;

   procedure Hash_Crc32 is
   begin
      Wuffs.Std.Crc32.Initialize (Crc);
      Result := Wuffs.U64 (Crc.Update_U32 (IMS.File (0 .. Len - 1)));
   end Hash_Crc32;

   procedure Hash_Adler32 is
   begin
      Wuffs.Std.Adler32.Initialize (Adler);
      Result := Wuffs.U64 (Adler.Update_U32 (IMS.File (0 .. Len - 1)));
   end Hash_Adler32;

   procedure Decode_Gzip is
      Src_Meta : IO.Buffer_Meta := (Wi => Len, Ri => 0, Pos => 0, Closed => True);
      Dst_Meta : IO.Buffer_Meta := IO.Empty_Meta;
      Work     : Wuffs.Bytes (1 .. 1) := [others => 0];
      St       : Wuffs.Status;
   begin
      Wuffs.Std.Gzip.Initialize (Gzip);
      St :=
        Gzip.Transform_Io
          (A_Dst      => IMS.Pix,
           A_Dst_Meta => Dst_Meta,
           A_Src      => IMS.File (0 .. Len - 1),
           A_Src_Meta => Src_Meta,
           A_Workbuf  => Work);
      Failed := Failed or else St /= Wuffs.Ok_Status;
      Result := Wuffs.U64 (Dst_Meta.Wi);
   end Decode_Gzip;

   procedure Decode_Image (D : in out Wuffs.Runtime.Image_Decoder'Class) is
      Src_Meta : IO.Buffer_Meta := (Wi => Len, Ri => 0, Pos => 0, Closed => True);
      IC       : PF.Image_Config;
      FC       : PF.Frame_Config;
      Cfg      : PF.Pixel_Config;
      Buf      : PB.Pixel_Buffer;
      Opts     : Wuffs.Runtime.Decode_Frame_Options;
      St       : Wuffs.Status;
      Row, N   : Wuffs.Index;
      Work     : Wuffs.U64;
      No_Pal   : Wuffs.Bytes (1 .. 0);
      Frames   : Wuffs.U64 := 0;
   begin
      St :=
        D.Decode_Image_Config
          (A_Dst      => IC,
           A_Dst_Null => False,
           A_Src      => IMS.File (0 .. Len - 1),
           A_Src_Meta => Src_Meta);
      if St /= Wuffs.Ok_Status then
         Failed := True;
         return;
      end if;
      PF.Set
        (C           => Cfg,
         Pixfmt_Repr => 16#8200_8888#,
         Pixsub_Repr => 0,
         Width       => IC.Pixcfg.Width,
         Height      => IC.Pixcfg.Height);
      Row := Wuffs.Index (IC.Pixcfg.Width) * 4;
      N := Row * Wuffs.Index (IC.Pixcfg.Height);
      Work := D.Workbuf_Len.Max_Incl;
      if N > IMS.Cap_Pix or else Work > IMS.Cap_Work then
         Failed := True;
         return;
      end if;
      PB.Set_Interleaved
        (PB             => Buf,
         Pixcfg         => Cfg,
         Primary        =>
           (Offset => 0, Width => Row, Height => Wuffs.Index (IC.Pixcfg.Height), Stride => Row),
         Pixels_Length  => N,
         Palette_Length => 0,
         Result         => St);
      loop
         St :=
           D.Decode_Frame_Config
             (A_Dst      => FC,
              A_Dst_Null => False,
              A_Src      => IMS.File (0 .. Len - 1),
              A_Src_Meta => Src_Meta);
         exit when St /= Wuffs.Ok_Status;
         St :=
           D.Decode_Frame
             (A_Dst         => Buf,
              A_Dst_Pixels  => IMS.Pix (IMS.Pix_First .. IMS.Pix_First + N - 1),
              A_Dst_Palette => No_Pal,
              A_Src         => IMS.File (0 .. Len - 1),
              A_Src_Meta    => Src_Meta,
              A_Blend       => PF.Blend_Src,
              A_Workbuf     => IMS.Work (1 .. Wuffs.Index (Work)),
              A_Opts        => Opts,
              A_Opts_Null   => True);
         exit when St /= Wuffs.Ok_Status;
         Frames := Frames + 1;
      end loop;
      Failed := Failed or else St /= Wuffs.Base.Note_End_Of_Data;
      Result := Wuffs.U64 (N) * 1000 + Frames;
   end Decode_Image;

   procedure Measure (Line : String) is
      Sp1, Sp2 : Natural := 0;
      Reps     : Natural := 0;
      OK       : Boolean;
      Best     : Ada.Real_Time.Time_Span := Ada.Real_Time.Time_Span_Last;
      Start    : Ada.Real_Time.Time;
      Elapsed  : Ada.Real_Time.Time_Span;
      Check    : Wuffs.U64 := 16#CBF2_9CE4_8422_2325#;
   begin
      for I in Line'Range loop
         if Line (I) = ' ' then
            if Sp1 = 0 then
               Sp1 := I;
            elsif Sp2 = 0 then
               Sp2 := I;
            end if;
         end if;
      end loop;
      if Sp2 = 0 then
         return;
      end if;
      for C of Line (Sp1 + 1 .. Sp2 - 1) loop
         Reps := Reps * 10 + (Character'Pos (C) - Character'Pos ('0'));
      end loop;
      Load (Line (Sp2 + 1 .. Line'Last), OK);
      if not OK then
         Ada.Text_IO.Put_Line (Ada.Text_IO.Standard_Error, "bench_main: cannot read a file");
         Failed := True;
         return;
      end if;
      declare
         Kind : String renames Line (Line'First .. Sp1 - 1);
      begin
         for R in 1 .. Reps loop
            Start := Ada.Real_Time.Clock;
            if Kind = "crc32" then
               Hash_Crc32;
            elsif Kind = "adler32" then
               Hash_Adler32;
            elsif Kind = "gzip" then
               Decode_Gzip;
            elsif Kind = "png" then
               Wuffs.Std.Png.Initialize (IMS.Png_Decoder);
               Decode_Image (IMS.Png_Decoder);
            elsif Kind = "gif" then
               Wuffs.Std.Gif.Initialize (IMS.Gif_Decoder);
               Decode_Image (IMS.Gif_Decoder);
            elsif Kind = "jpeg" then
               Wuffs.Std.Jpeg.Initialize (IMS.Jpeg_Decoder);
               Decode_Image (IMS.Jpeg_Decoder);
            end if;
            Elapsed := Ada.Real_Time.Clock - Start;
            if Elapsed < Best then
               Best := Elapsed;
            end if;
         end loop;
         --  What was computed: the checksum, or the bytes produced.
         if Kind = "gzip" then
            Fnv (Check, IMS.Pix (IMS.Pix_First .. IMS.Pix_First + Wuffs.Index (Result) - 1));
         elsif Kind = "png" or else Kind = "gif" or else Kind = "jpeg" then
            Fnv (Check, IMS.Pix (IMS.Pix_First .. IMS.Pix_First + Wuffs.Index (Result / 1000) - 1));
            Check := Check + Result mod 1000;
         else
            Check := Result;
         end if;
         Ada.Text_IO.Put (Kind);
      end;
      Ada.Text_IO.Put (Line (Sp2 .. Line'Last));
      Ada.Text_IO.Put (" ");
      Put_Number (Wuffs.U64 (Len));
      Ada.Text_IO.Put (" ");
      Put_Number (Wuffs.U64 (Best / Ada.Real_Time.Nanoseconds (1)));
      Ada.Text_IO.Put (" ");
      Put_Number (Check);
      Ada.Text_IO.New_Line;
   end Measure;

   Line : String (1 .. 4096);
   Last : Natural;

begin
   while not Ada.Text_IO.End_Of_File loop
      Ada.Text_IO.Get_Line (Line, Last);
      if Last > 0 then
         Measure (Line (1 .. Last));
      end if;
   end loop;
   if Failed then
      Ada.Text_IO.Put_Line (Ada.Text_IO.Standard_Error, "bench_main: a decoder failed");
   end if;
end Bench_Main;
