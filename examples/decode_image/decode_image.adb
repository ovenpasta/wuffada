--  Part of wuffada (wuffs-ada: Wuffs to Ada).
--  SPDX-License-Identifier: Apache-2.0 OR MIT

--  decode_image INPUT OUTPUT
--
--  Decodes the image file INPUT (PNG, GIF, JPEG, WebP, BMP, Netpbm, NIE, QOI,
--  ETC2/PKM or WBMP: the format is
--  recognised from the file's first bytes, not from its name) with the
--  decoders that wuffs-ada generated from Wuffs' standard library, and
--  writes it to OUTPUT: as a PPM file (P6) if the image is opaque, else as a
--  PAM file (P7, RGB_ALPHA, not premultiplied).  Of an animation it writes
--  the first frame, over transparent black.
--
--  The exit status is 0 on success; otherwise it prints the decoder's
--  status message and exits with 1.

with Ada.Command_Line;
with Ada.Streams.Stream_IO;
with Ada.Text_IO;
with Decode_Image_Buffers;
with System;
with Wuffs.Base.IO;
with Wuffs.Base.Pixel_Buffers;
with Wuffs.Base.Pixel_Formats;
with Wuffs.Base.Ranges;
with Wuffs.Runtime;
with Wuffs.Std.Bmp;
with Wuffs.Std.Deflate;
with Wuffs.Std.Etc2;
with Wuffs.Std.Gif;
with Wuffs.Std.Jpeg;
with Wuffs.Std.Netpbm;
with Wuffs.Std.Nie;
with Wuffs.Std.Png;
with Wuffs.Std.Qoi;
with Wuffs.Std.Vp8;
with Wuffs.Std.Wbmp;
with Wuffs.Std.Webp;
with Wuffs.Std.Zlib;

procedure Decode_Image is

   package Buffers renames Decode_Image_Buffers;
   package IO renames Wuffs.Base.IO;
   package PB renames Wuffs.Base.Pixel_Buffers;
   package PF renames Wuffs.Base.Pixel_Formats;
   package SIO renames Ada.Streams.Stream_IO;

   use type Wuffs.U8;
   use type Wuffs.U32;
   use type Wuffs.U64;
   use type Wuffs.Index;
   use type SIO.Count;
   use type Ada.Streams.Stream_Element_Offset;

   RGB            : constant := 16#A000_0888#;
   RGBA_Nonpremul : constant := 16#A100_8888#;

   type Format is (Unknown, Netpbm, Bmp, Gif, Png, Jpeg, Webp, Nie, Qoi, Etc2, Wbmp);

   subtype Decoder is Wuffs.Runtime.Image_Decoder'Class;

   Failed : exception;

   procedure Fail (Message : String)
   with No_Return;

   --  Prints What and the message of S, which the package that S comes
   --  from knows (none of them needs more than the 80 characters here).
   procedure Fail_With_Status (What : String; S : Wuffs.Status)
   with No_Return;

   procedure Read_File (Name : String; Length : out Wuffs.Index);

   function Sniff (Length : Wuffs.Index) return Format;

   procedure Write (File : SIO.File_Type; Text : String);

   procedure Write_Number (File : SIO.File_Type; N : Wuffs.U32);

   --  Decodes the first frame of the Length bytes in Buffers.Source and
   --  writes it to the file called Name.
   procedure Convert (D : in out Decoder; Length : Wuffs.Index; Name : String);

   procedure Fail (Message : String) is
   begin
      Ada.Text_IO.Put_Line (Ada.Text_IO.Standard_Error, Message);
      raise Failed;
   end Fail;

   procedure Fail_With_Status (What : String; S : Wuffs.Status) is
      Text   : String (1 .. 80);
      Length : Natural;
   begin
      Wuffs.Base.Get_Message (S, Text, Length);
      if Length = 0 then
         Wuffs.Std.Netpbm.Get_Message (S, Text, Length);
      end if;
      if Length = 0 then
         Wuffs.Std.Bmp.Get_Message (S, Text, Length);
      end if;
      if Length = 0 then
         Wuffs.Std.Gif.Get_Message (S, Text, Length);
      end if;
      if Length = 0 then
         Wuffs.Std.Png.Get_Message (S, Text, Length);
      end if;
      if Length = 0 then
         Wuffs.Std.Jpeg.Get_Message (S, Text, Length);
      end if;
      if Length = 0 then
         Wuffs.Std.Webp.Get_Message (S, Text, Length);
      end if;
      --  The packages that the PNG, GIF and WebP decoders use, whose statuses
      --  they pass on.
      if Length = 0 then
         Wuffs.Std.Zlib.Get_Message (S, Text, Length);
      end if;
      if Length = 0 then
         Wuffs.Std.Vp8.Get_Message (S, Text, Length);
      end if;
      if Length = 0 then
         Wuffs.Std.Nie.Get_Message (S, Text, Length);
      end if;
      if Length = 0 then
         Wuffs.Std.Qoi.Get_Message (S, Text, Length);
      end if;
      if Length = 0 then
         Wuffs.Std.Etc2.Get_Message (S, Text, Length);
      end if;
      if Length = 0 then
         Wuffs.Std.Wbmp.Get_Message (S, Text, Length);
      end if;
      if Length = 0 then
         Wuffs.Std.Deflate.Get_Message (S, Text, Length);
      end if;
      Ada.Text_IO.Put (Ada.Text_IO.Standard_Error, What);
      Ada.Text_IO.Put (Ada.Text_IO.Standard_Error, ": ");
      if Length = 0 then
         Ada.Text_IO.Put_Line (Ada.Text_IO.Standard_Error, "(a status without a message)");
      else
         Ada.Text_IO.Put_Line (Ada.Text_IO.Standard_Error, Text (1 .. Length));
      end if;
      raise Failed;
   end Fail_With_Status;

   procedure Read_File (Name : String; Length : out Wuffs.Index) is
      File : SIO.File_Type;
      Size : SIO.Count;
   begin
      Length := 0;
      begin
         SIO.Open (File, SIO.In_File, Name);
      exception
         when others =>
            Fail ("cannot open the input file");
      end;
      Size := SIO.Size (File);
      if Size > Buffers.Source_Capacity then
         SIO.Close (File);
         Fail ("the input file is too large");
      end if;
      if Size > 0 then
         declare
            Item : Ada.Streams.Stream_Element_Array (1 .. Ada.Streams.Stream_Element_Offset (Size))
            with Import, Address => Buffers.Source'Address;
            Last : Ada.Streams.Stream_Element_Offset;
         begin
            SIO.Read (File, Item, Last);
            if Last /= Item'Last then
               SIO.Close (File);
               Fail ("cannot read the input file");
            end if;
         end;
      end if;
      Length := Wuffs.Index (Size);
      SIO.Close (File);
   end Read_File;

   function Sniff (Length : Wuffs.Index) return Format is
      S : Wuffs.Bytes renames Buffers.Source;
   begin
      if Length >= 4 and then S (1) = 16#89# and then S (2) = Character'Pos ('P')
        and then S (3) = Character'Pos ('N') and then S (4) = Character'Pos ('G')
      then
         return Png;
      elsif Length >= 3 and then S (1) = 16#FF# and then S (2) = 16#D8# and then S (3) = 16#FF# then
         --  SOI and the start of the next marker.
         return Jpeg;
      elsif Length >= 12 and then S (1) = Character'Pos ('R') and then S (2) = Character'Pos ('I')
        and then S (3) = Character'Pos ('F') and then S (4) = Character'Pos ('F')
        and then S (9) = Character'Pos ('W') and then S (10) = Character'Pos ('E')
        and then S (11) = Character'Pos ('B') and then S (12) = Character'Pos ('P')
      then
         --  "RIFF", the length, "WEBP".
         return Webp;
      elsif Length >= 3 and then S (1) = Character'Pos ('G') and then S (2) = Character'Pos ('I')
        and then S (3) = Character'Pos ('F')
      then
         return Gif;
      elsif Length >= 2 and then S (1) = Character'Pos ('B') and then S (2) = Character'Pos ('M')
      then
         return Bmp;
      elsif Length >= 2 and then S (1) = Character'Pos ('P')
        and then S (2) in Character'Pos ('1') .. Character'Pos ('7')
      then
         return Netpbm;
      elsif Length >= 4 and then S (1) = 16#6E# and then S (2) = 16#C3# and then S (3) = 16#AF#
        and then S (4) = Character'Pos ('E')
      then
         --  "nïE", in UTF-8.
         return Nie;
      elsif Length >= 4 and then S (1) = Character'Pos ('q') and then S (2) = Character'Pos ('o')
        and then S (3) = Character'Pos ('i') and then S (4) = Character'Pos ('f')
      then
         return Qoi;
      elsif Length >= 4 and then S (1) = Character'Pos ('P') and then S (2) = Character'Pos ('K')
        and then S (3) = Character'Pos ('M') and then S (4) = Character'Pos (' ')
      then
         return Etc2;
      elsif Length >= 2 and then S (1) = 0 and then S (2) = 0 then
         --  A WBMP file has no signature: type 0 and a zero header byte.
         return Wbmp;
      end if;
      return Unknown;
   end Sniff;

   procedure Write (File : SIO.File_Type; Text : String) is
      --  Every text that this program writes is shorter than this.
      Item : Ada.Streams.Stream_Element_Array (1 .. 128);
      Last : Ada.Streams.Stream_Element_Offset := 0;
   begin
      for C of Text loop
         exit when Last = Item'Last;
         Last := Last + 1;
         Item (Last) := Character'Pos (C);
      end loop;
      SIO.Write (File, Item (1 .. Last));
   end Write;

   procedure Write_Number (File : SIO.File_Type; N : Wuffs.U32) is
      Text  : String (1 .. 10);
      First : Natural := Text'Last + 1;
      Rest  : Wuffs.U32 := N;
   begin
      loop
         First := First - 1;
         Text (First) := Character'Val (Character'Pos ('0') + Natural (Rest mod 10));
         Rest := Rest / 10;
         exit when Rest = 0;
      end loop;
      Write (File, Text (First .. Text'Last));
   end Write_Number;

   procedure Convert (D : in out Decoder; Length : Wuffs.Index; Name : String) is
      Src      : Wuffs.Bytes renames Buffers.Source (1 .. Length);
      Src_Meta : IO.Buffer_Meta := (Wi => Length, Ri => 0, Pos => 0, Closed => True);

      Image   : PF.Image_Config;
      Frame   : PF.Frame_Config;
      Config  : PF.Pixel_Config;
      Buffer  : PB.Pixel_Buffer;
      Options : Wuffs.Runtime.Decode_Frame_Options;
      Status  : Wuffs.Status;

      Width, Height : Wuffs.U32;
      Opaque        : Boolean;
      Channels      : Wuffs.Index;
      Row_Length    : Wuffs.Index;
      Pixels_Length : Wuffs.Index;
      Work_Length   : Wuffs.U64;
      Output        : SIO.File_Type;
   begin
      Status :=
        D.Decode_Image_Config
          (A_Dst => Image, A_Dst_Null => False, A_Src => Src, A_Src_Meta => Src_Meta);
      if not Wuffs.Is_Ok (Status) then
         Fail_With_Status ("decode_image_config", Status);
      end if;
      Width := PF.Width (Image.Pixcfg);
      Height := PF.Height (Image.Pixcfg);

      --  The first frame, to learn whether an alpha channel is needed.
      Status :=
        D.Decode_Frame_Config
          (A_Dst => Frame, A_Dst_Null => False, A_Src => Src, A_Src_Meta => Src_Meta);
      if not Wuffs.Is_Ok (Status) then
         Fail_With_Status ("decode_frame_config", Status);
      end if;
      Opaque :=
        PF.Opaque_Within_Bounds (Frame)
        and then Wuffs.Base.Ranges.Equals (PF.Bounds (Frame), PF.Bounds (Image.Pixcfg));
      Channels := (if Opaque then 3 else 4);

      --  (Width and Height are below 2**32 and Channels is 3 or 4: the
      --  product fits in 64 bits.)
      if Wuffs.U64 (Width) * Wuffs.U64 (Height) > Buffers.Pixels_Capacity / Wuffs.U64 (Channels)
      then
         Fail ("the image is too large for this program's pixel memory");
      end if;
      Row_Length := Wuffs.Index (Width) * Channels;
      Pixels_Length := Row_Length * Wuffs.Index (Height);
      Work_Length := D.Workbuf_Len.Max_Incl;
      if Work_Length > Buffers.Workbuf_Capacity then
         Fail ("the image is too large for this program's work memory");
      end if;

      PF.Set
        (C           => Config,
         Pixfmt_Repr => (if Opaque then RGB else RGBA_Nonpremul),
         Pixsub_Repr => 0,
         Width       => Width,
         Height      => Height);
      PB.Set_Interleaved
        (PB             => Buffer,
         Pixcfg         => Config,
         Primary        =>
           (Offset => 0, Width => Row_Length, Height => Wuffs.Index (Height), Stride => Row_Length),
         Pixels_Length  => Pixels_Length,
         Palette_Length => 0,
         Result         => Status);
      if not Wuffs.Is_Ok (Status) then
         Fail_With_Status ("the pixel buffer", Status);
      end if;
      --  Transparent black, where the first frame does not cover the image.
      Buffers.Pixels (1 .. Pixels_Length) := [others => 0];

      Status :=
        D.Decode_Frame
          (A_Dst         => Buffer,
           A_Dst_Pixels  => Buffers.Pixels (1 .. Pixels_Length),
           A_Dst_Palette => Buffers.No_Palette,
           A_Src         => Src,
           A_Src_Meta    => Src_Meta,
           A_Blend       => PF.Blend_Src,
           A_Workbuf     => Buffers.Workbuf (1 .. Wuffs.Index (Work_Length)),
           A_Opts        => Options,
           A_Opts_Null   => True);
      if not Wuffs.Is_Ok (Status) then
         Fail_With_Status ("decode_frame", Status);
      end if;

      begin
         SIO.Create (Output, SIO.Out_File, Name);
      exception
         when others =>
            Fail ("cannot create the output file");
      end;
      if Opaque then
         Write (Output, "P6" & ASCII.LF);
         Write_Number (Output, Width);
         Write (Output, " ");
         Write_Number (Output, Height);
         Write (Output, ASCII.LF & "255" & ASCII.LF);
      else
         Write (Output, "P7" & ASCII.LF & "WIDTH ");
         Write_Number (Output, Width);
         Write (Output, ASCII.LF & "HEIGHT ");
         Write_Number (Output, Height);
         Write
           (Output,
            ASCII.LF & "DEPTH 4" & ASCII.LF & "MAXVAL 255" & ASCII.LF & "TUPLTYPE RGB_ALPHA"
            & ASCII.LF & "ENDHDR" & ASCII.LF);
      end if;
      if Pixels_Length > 0 then
         declare
            Item :
              Ada.Streams.Stream_Element_Array
                (1 .. Ada.Streams.Stream_Element_Offset (Pixels_Length))
            with Import, Address => Buffers.Pixels'Address;
         begin
            SIO.Write (Output, Item);
         end;
      end if;
      SIO.Close (Output);
   end Convert;

   --  The command line's arguments, copied to fixed buffers: this program
   --  is built, like the library, without a secondary stack, which
   --  Ada.Command_Line.Argument needs for its result.  These two are what
   --  GNAT's Ada.Command_Line itself calls.
   function Argument_Length (Number : Integer) return Integer
   with Import, Convention => C, External_Name => "__gnat_len_arg";

   procedure Fill_Argument (Buffer : System.Address; Number : Integer)
   with Import, Convention => C, External_Name => "__gnat_fill_arg";

   Max_Name : constant := 1024;

   Input_Name  : String renames Buffers.Input_Name;
   Input_Last  : Natural := 0;
   Output_Name : String renames Buffers.Output_Name;
   Output_Last : Natural := 0;

   Length : Wuffs.Index;

begin
   if Ada.Command_Line.Argument_Count /= 2 then
      Fail ("usage: decode_image INPUT OUTPUT");
   end if;
   Input_Last := Argument_Length (1);
   Output_Last := Argument_Length (2);
   --  (Far below what the buffers hold: the run-time library that opens the
   --  files has limits of its own on the length of a path, and misbehaves
   --  near them.)
   if Input_Last not in 1 .. Max_Name or else Output_Last not in 1 .. Max_Name then
      Fail ("a file name is empty or longer than 1024 characters");
   end if;
   Fill_Argument (Input_Name'Address, 1);
   Fill_Argument (Output_Name'Address, 2);
   Read_File (Input_Name (1 .. Input_Last), Length);
   case Sniff (Length) is
      when Netpbm =>
         Wuffs.Std.Netpbm.Initialize (Buffers.Netpbm_Decoder);
         Convert (Buffers.Netpbm_Decoder, Length, Output_Name (1 .. Output_Last));
      when Bmp =>
         Wuffs.Std.Bmp.Initialize (Buffers.Bmp_Decoder);
         Convert (Buffers.Bmp_Decoder, Length, Output_Name (1 .. Output_Last));
      when Gif =>
         Wuffs.Std.Gif.Initialize (Buffers.Gif_Decoder);
         Convert (Buffers.Gif_Decoder, Length, Output_Name (1 .. Output_Last));
      when Png =>
         Wuffs.Std.Png.Initialize (Buffers.Png_Decoder);
         Convert (Buffers.Png_Decoder, Length, Output_Name (1 .. Output_Last));
      when Jpeg =>
         Wuffs.Std.Jpeg.Initialize (Buffers.Jpeg_Decoder);
         Convert (Buffers.Jpeg_Decoder, Length, Output_Name (1 .. Output_Last));
      when Webp =>
         Wuffs.Std.Webp.Initialize (Buffers.Webp_Decoder);
         Convert (Buffers.Webp_Decoder, Length, Output_Name (1 .. Output_Last));
      when Nie =>
         Wuffs.Std.Nie.Initialize (Buffers.Nie_Decoder);
         Convert (Buffers.Nie_Decoder, Length, Output_Name (1 .. Output_Last));
      when Qoi =>
         Wuffs.Std.Qoi.Initialize (Buffers.Qoi_Decoder);
         Convert (Buffers.Qoi_Decoder, Length, Output_Name (1 .. Output_Last));
      when Etc2 =>
         Wuffs.Std.Etc2.Initialize (Buffers.Etc2_Decoder);
         Convert (Buffers.Etc2_Decoder, Length, Output_Name (1 .. Output_Last));
      when Wbmp =>
         Wuffs.Std.Wbmp.Initialize (Buffers.Wbmp_Decoder);
         Convert (Buffers.Wbmp_Decoder, Length, Output_Name (1 .. Output_Last));
      when Unknown =>
         Fail
           ("the input is not a PNG, GIF, JPEG, WebP, BMP, Netpbm, NIE, QOI, ETC2 (PKM) or WBMP"
            & " file");
   end case;
exception
   when Failed =>
      Ada.Command_Line.Set_Exit_Status (1);
end Decode_Image;
