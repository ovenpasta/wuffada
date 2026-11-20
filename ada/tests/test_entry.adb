--  Part of wuffada (wuffs-ada: Wuffs to Ada).
--  SPDX-License-Identifier: Apache-2.0 OR MIT

--  The argument checks at the public entries of every generated package
--  (see "Arguments" in wuffs-runtime.ads), in both profiles:
--
--  * an array argument that lies in the receiver object itself is rejected,
--    and the object is not changed (other than being disabled);
--  * the same checks are made again when a suspended coroutine is resumed:
--    with other arrays, another pixel buffer, an overlap or a corrupt meta,
--    the call is rejected or fails cleanly;
--  * an object passed for a null pointer is neither read nor written;
--  * a Boolean argument that holds neither False nor True is rejected (in
--    the release profile only: with validity checks on, this program could
--    not even make the call).

with Decode_Support;
with Image_Support;
with Test_Support;
with Wuffs.Base.IO;
with Wuffs.Base.Pixel_Buffers;
with Wuffs.Base.Pixel_Formats;
with Wuffs.Runtime;
with Wuffs.Std.Adler32;
with Wuffs.Std.Bmp;
with Wuffs.Std.Crc32;
with Wuffs.Std.Deflate;
with Wuffs.Std.Gif;
with Wuffs.Std.Gzip;
with Wuffs.Std.Lzw;
with Wuffs.Std.Netpbm;
with Wuffs.Std.Nie;
with Wuffs.Std.Png;
with Wuffs.Std.Targa;
with Wuffs.Std.Wbmp;
with Wuffs.Std.Zlib;

procedure Test_Entry is

   package DS renames Decode_Support;
   package IMS renames Image_Support;
   package IO renames Wuffs.Base.IO;
   package PB renames Wuffs.Base.Pixel_Buffers;
   package PF renames Wuffs.Base.Pixel_Formats;

   use type Wuffs.U8;
   use type Wuffs.U32;
   use type Wuffs.U64;
   use type Wuffs.Index;
   use type Wuffs.Status;
   use type Wuffs.Status_Category;

   use Test_Support;

   Bad_Argument : Wuffs.Status renames Wuffs.Base.Error_Bad_Argument;
   Disabled     : Wuffs.Status renames Wuffs.Base.Error_Disabled_By_Previous_Error;

   Fill : constant Wuffs.U8 := 16#5A#;

   Arena : Wuffs.Bytes renames IMS.Arena;

   --  Where in Arena the arrays of a call are, when they are in Arena.
   P : constant := 1000;  --  Pixels, up to 256 bytes.
   L : constant := 2000;  --  Palette, 1024 bytes.
   S : constant := 4000;  --  Source, up to 256 bytes.
   W : constant := 5000;  --  Work buffer, 1024 bytes.
   D : constant := 6500;  --  Destination, 256 bytes.
   Copy : constant := 7000;  --  A copy of the start of the object.

   type Kind is
     (Adler32, Crc32, Lzw, Deflate, Zlib, Gzip, Netpbm, Bmp, Gif, Png, Wbmp, Nie, Targa);

   subtype Decoder_Kind is Kind range Netpbm .. Targa;

   subtype Hasher is Wuffs.Runtime.Hasher_U32'Class;
   subtype Transformer is Wuffs.Runtime.IO_Transformer'Class;
   subtype Decoder is Wuffs.Runtime.Image_Decoder'Class;

   Adler32_Hasher : Wuffs.Std.Adler32.Hasher;
   Crc32_Hasher   : Wuffs.Std.Crc32.Ieee_Hasher;

   --  A valid 4 by 4 BGRA pixel buffer for 64 bytes, and a 2 by 2 one.
   PB_4x4 : PB.Pixel_Buffer;
   PB_2x2 : PB.Pixel_Buffer;

   --  A Boolean that is neither False nor True.
   Two        : aliased Wuffs.U8 := 2;
   Bad_Boolean : Boolean
   with Import, Address => Two'Address;

   --  A Buffer_Meta that says more is written than its array holds.
   Too_Long : constant IO.Buffer_Meta := (Wi => 100_000, Ri => 0, Pos => 0, Closed => False);

   procedure Initialize (K : Kind);

   --  The object's storage, as bytes, is Size bytes at Address.  Snapshot
   --  copies its first bytes (up to 1024) to Arena; Unchanged compares:
   --  everything but the Magic component (after the tag) must be the same.
   procedure Snapshot (Object : Wuffs.Bytes);

   function Unchanged (Object : Wuffs.Bytes) return Boolean;

   function Arena_Is_Intact return Boolean;

   --  The last call returned St and should have rejected its arguments.
   procedure Rejected (K : Kind; St : Wuffs.Status; Object : Wuffs.Bytes; What : String);

   procedure Check_Hasher (H : in out Hasher; K : Kind; Size : Long_Long_Integer);

   function Transform
     (T        : in out Transformer;
      Dst      : in out Wuffs.Bytes;
      Src      : Wuffs.Bytes;
      Work     : in out Wuffs.Bytes;
      Dst_Meta : IO.Buffer_Meta;
      Src_Meta : IO.Buffer_Meta)
      return Wuffs.Status;

   procedure Check_Transformer (T : in out Transformer; K : Kind; Size : Long_Long_Integer);

   function Frame
     (Dec      : in out Decoder;
      Buf      : PB.Pixel_Buffer;
      Pixels   : in out Wuffs.Bytes;
      Palette  : in out Wuffs.Bytes;
      Src      : Wuffs.Bytes;
      Src_Meta : in out IO.Buffer_Meta;
      Work     : in out Wuffs.Bytes;
      Null_Opts : Boolean := True) return Wuffs.Status;

   procedure Check_Decoder (Dec : in out Decoder; K : Kind; Size : Long_Long_Integer);

   --  Puts a small image at Arena (S ..) and returns its length: a 2 by 2
   --  PPM, a 2 by 2 24-bit BMP or a 2 by 2 GIF.
   procedure Make_Image (K : Decoder_Kind; Length : out Wuffs.Index);

   --  Suspends decode_frame of the small image and resumes it with
   --  arguments other than those of the first call.
   procedure Check_Resume (Dec : in out Decoder; K : Decoder_Kind; Size : Long_Long_Integer);

   procedure Check_Null_Pointers (Dec : in out Decoder; K : Decoder_Kind);

   --  Suspends tell_me_more (of the GIF decoder, in the middle of an ICC
   --  profile) and resumes it with other arguments.
   procedure Check_Tell_Me_More;

   procedure Initialize (K : Kind) is
   begin
      case K is
         when Adler32 => Wuffs.Std.Adler32.Initialize (Adler32_Hasher);
         when Crc32 => Wuffs.Std.Crc32.Initialize (Crc32_Hasher);
         when Lzw => Wuffs.Std.Lzw.Initialize (DS.Lzw_Decoder);
         when Deflate => Wuffs.Std.Deflate.Initialize (DS.Deflate_Decoder);
         when Zlib => Wuffs.Std.Zlib.Initialize (DS.Zlib_Decoder);
         when Gzip => Wuffs.Std.Gzip.Initialize (DS.Gzip_Decoder);
         when Netpbm => Wuffs.Std.Netpbm.Initialize (IMS.Netpbm_Decoder);
         when Bmp => Wuffs.Std.Bmp.Initialize (IMS.Bmp_Decoder);
         when Gif => Wuffs.Std.Gif.Initialize (IMS.Gif_Decoder);
         when Png => Wuffs.Std.Png.Initialize (IMS.Png_Decoder);
         when Wbmp => Wuffs.Std.Wbmp.Initialize (IMS.Wbmp_Decoder);
         when Nie => Wuffs.Std.Nie.Initialize (IMS.Nie_Decoder);
         when Targa => Wuffs.Std.Targa.Initialize (IMS.Targa_Decoder);
      end case;
   end Initialize;

   procedure Snapshot (Object : Wuffs.Bytes) is
      N : constant Wuffs.Index := Wuffs.Index'Min (Object'Length, 1024);
   begin
      Arena := [others => Fill];
      Arena (Copy .. Copy + N - 1) := Object (Object'First .. Object'First + N - 1);
   end Snapshot;

   function Unchanged (Object : Wuffs.Bytes) return Boolean is
      N : constant Wuffs.Index := Wuffs.Index'Min (Object'Length, 1024);
   begin
      for I in 0 .. N - 1 loop
         --  Bytes 8 .. 11 are Magic (the first component, after the tag).
         if I not in 8 .. 11 and then Arena (Copy + I) /= Object (Object'First + I) then
            return False;
         end if;
      end loop;
      return True;
   end Unchanged;

   function Arena_Is_Intact return Boolean is
   begin
      for I in Arena'First .. Copy - 1 loop
         if Arena (I) /= Fill then
            return False;
         end if;
      end loop;
      return True;
   end Arena_Is_Intact;

   procedure Rejected (K : Kind; St : Wuffs.Status; Object : Wuffs.Bytes; What : String) is
   begin
      Check (St = Bad_Argument, What, Kind'Pos (K), ": not rejected");
      Check (Unchanged (Object), What, Kind'Pos (K), ": the object was changed");
      Check (Arena_Is_Intact, What, Kind'Pos (K), ": memory was written");
   end Rejected;

   procedure Check_Hasher (H : in out Hasher; K : Kind; Size : Long_Long_Integer) is
      Object : Wuffs.Bytes (0 .. Wuffs.Index (Size / 8) - 1)
      with Import, Address => H'Address;
      V : Wuffs.U32;
   begin
      Initialize (K);
      H.Update (Arena (S .. S + 9));
      Snapshot (Object);
      H.Update (Object (Object'Last - 3 .. Object'Last));
      Check (Unchanged (Object), "update with a part of the hasher: changed", Kind'Pos (K));
      Check
        (H.Set_Quirk (A_Key => 1, A_Value => 1) = Disabled,
         "update with a part of the hasher: not disabled", Kind'Pos (K));

      Initialize (K);
      Snapshot (Object);
      V := H.Update_U32 (Object (Object'Last .. Object'Last));
      Check (V = 0 and then Unchanged (Object), "update_u32 with a part of the hasher",
        Kind'Pos (K));
      Check
        (H.Set_Quirk (A_Key => 1, A_Value => 1) = Disabled,
         "update_u32 with a part of the hasher: not disabled", Kind'Pos (K));
      --  All of the object, and an array that only starts in it.
      Initialize (K);
      V := H.Update_U32 (Object);
      Check (V = 0, "update_u32 with the hasher itself", Kind'Pos (K));
      Initialize (K);
      --  An array next to the object is fine.
      Arena := [others => Fill];
      V := H.Update_U32 (Arena (S .. S + 9));
      Check
        (V /= 0 and then H.Set_Quirk (A_Key => 1, A_Value => 1) /= Disabled,
         "update_u32 with an array of its own", Kind'Pos (K));
   end Check_Hasher;

   function Transform
     (T        : in out Transformer;
      Dst      : in out Wuffs.Bytes;
      Src      : Wuffs.Bytes;
      Work     : in out Wuffs.Bytes;
      Dst_Meta : IO.Buffer_Meta;
      Src_Meta : IO.Buffer_Meta)
      return Wuffs.Status
   is
      DM : IO.Buffer_Meta := Dst_Meta;
      SM : IO.Buffer_Meta := Src_Meta;
   begin
      return
        T.Transform_Io
          (A_Dst => Dst, A_Dst_Meta => DM, A_Src => Src, A_Src_Meta => SM, A_Workbuf => Work);
   end Transform;

   procedure Check_Transformer (T : in out Transformer; K : Kind; Size : Long_Long_Integer) is
      Object : Wuffs.Bytes (0 .. Wuffs.Index (Size / 8) - 1)
      with Import, Address => T'Address;
      Last : constant Wuffs.Index := Object'Last;

      Empty : constant IO.Buffer_Meta := IO.Empty_Meta;
      Full  : constant IO.Buffer_Meta := (Wi => 8, Ri => 0, Pos => 0, Closed => True);
      St    : Wuffs.Status;

      --  Leaves the coroutine suspended: it has asked for input.
      procedure Suspend;

      procedure Suspend is
      begin
         Initialize (K);
         St :=
           Transform
             (T, Arena (D .. D + 255), Arena (S .. S + 7), Arena (W .. W + 15), Empty, Empty);
         Check (St = Wuffs.Base.Suspension_Short_Read, "transform_io did not suspend",
           Kind'Pos (K));
         Snapshot (Object);
      end Suspend;
   begin
      for Resumed in Boolean loop
         --  Each array argument in the object, at its end, at its start
         --  (after the tag and Magic) and as the whole object.
         for Where in 1 .. 3 loop
            declare
               First : constant Wuffs.Index := (case Where is when 1 => Last - 7, when 2 => 12,
                 when others => 0);
               Stop  : constant Wuffs.Index := (case Where is when 1 => Last, when 2 => 19,
                 when others => Last);
            begin
               if Resumed then
                  Suspend;
               else
                  Initialize (K);
                  Snapshot (Object);
               end if;
               Rejected
                 (K,
                  Transform (T, Object (First .. Stop), Arena (S .. S + 7), Arena (W .. W + 15),
                    Empty, Full),
                  Object, "transform_io, dst in the object");
               Check
                 (T.Set_Quirk (A_Key => 1, A_Value => 1) = Disabled,
                  "transform_io, dst in the object: not disabled", Kind'Pos (K));
               if Resumed then
                  Suspend;
               else
                  Initialize (K);
                  Snapshot (Object);
               end if;
               Rejected
                 (K,
                  Transform (T, Arena (D .. D + 255), Object (First .. Stop), Arena (W .. W + 15),
                    Empty, Full),
                  Object, "transform_io, src in the object");
               if Resumed then
                  Suspend;
               else
                  Initialize (K);
                  Snapshot (Object);
               end if;
               Rejected
                 (K,
                  Transform (T, Arena (D .. D + 255), Arena (S .. S + 7), Object (First .. Stop),
                    Empty, Full),
                  Object, "transform_io, workbuf in the object");
            end;
         end loop;

         --  Metas that do not describe their arrays.
         if Resumed then
            Suspend;
         else
            Initialize (K);
            Snapshot (Object);
         end if;
         Rejected
           (K, Transform (T, Arena (D .. D + 255), Arena (S .. S + 7), Arena (W .. W + 15), Empty,
             Too_Long),
            Object, "transform_io, src meta too long");
         if Resumed then
            Suspend;
         else
            Initialize (K);
            Snapshot (Object);
         end if;
         Rejected
           (K, Transform (T, Arena (D .. D + 255), Arena (S .. S + 7), Arena (W .. W + 15),
             Too_Long, Full),
            Object, "transform_io, dst meta too long");
      end loop;

      --  A resumption with other (valid) arrays than before is not an
      --  argument error: the decoder goes on, here to the end of no input.
      Suspend;
      St :=
        Transform
          (T, Arena (D + 300 .. D + 307), Arena (S + 100 .. S + 99), Arena (W + 100 .. W + 99),
           Empty, (Wi => 0, Ri => 0, Pos => 0, Closed => True));
      Check
        (St /= Bad_Argument and then St.Category = Wuffs.Error and then Arena_Is_Intact,
         "transform_io resumed with other arrays", Kind'Pos (K));
      Initialize (K);
   end Check_Transformer;

   function Frame
     (Dec      : in out Decoder;
      Buf      : PB.Pixel_Buffer;
      Pixels   : in out Wuffs.Bytes;
      Palette  : in out Wuffs.Bytes;
      Src      : Wuffs.Bytes;
      Src_Meta : in out IO.Buffer_Meta;
      Work     : in out Wuffs.Bytes;
      Null_Opts : Boolean := True) return Wuffs.Status
   is
      Opts : Wuffs.Runtime.Decode_Frame_Options;
   begin
      return
        Dec.Decode_Frame
          (A_Dst         => Buf,
           A_Dst_Pixels  => Pixels,
           A_Dst_Palette => Palette,
           A_Src         => Src,
           A_Src_Meta    => Src_Meta,
           A_Blend       => PF.Blend_Src,
           A_Workbuf     => Work,
           A_Opts        => Opts,
           A_Opts_Null   => Null_Opts);
   end Frame;

   procedure Check_Decoder (Dec : in out Decoder; K : Kind; Size : Long_Long_Integer) is
      Object : Wuffs.Bytes (0 .. Wuffs.Index (Size / 8) - 1)
      with Import, Address => Dec'Address;
      Last : constant Wuffs.Index := Object'Last;

      Empty : constant IO.Buffer_Meta := IO.Empty_Meta;
      Full  : constant IO.Buffer_Meta := (Wi => 8, Ri => 0, Pos => 0, Closed => True);

      IC   : PF.Image_Config;
      FC   : PF.Frame_Config;
      MI   : Wuffs.Runtime.More_Information;
      Opts : Wuffs.Runtime.Decode_Frame_Options;
      SM   : IO.Buffer_Meta;
      DM   : IO.Buffer_Meta;
      St   : Wuffs.Status;

      procedure Start (Resumed : Boolean);

      --  A new decoder or, if Resumed, one whose decode_image_config is
      --  suspended: it has asked for input.
      procedure Start (Resumed : Boolean) is
      begin
         Initialize (K);
         if Resumed then
            SM := Empty;
            St :=
              Dec.Decode_Image_Config
                (A_Dst => IC, A_Dst_Null => False, A_Src => Arena (S .. S + 7), A_Src_Meta => SM);
            Check
              (St = Wuffs.Base.Suspension_Short_Read, "decode_image_config did not suspend",
               Kind'Pos (K));
         end if;
         Snapshot (Object);
         SM := Full;
         DM := Empty;
      end Start;
   begin
      for Resumed in Boolean loop
         for Where in 1 .. 3 loop
            declare
               First : constant Wuffs.Index := (case Where is when 1 => Last - 7, when 2 => 12,
                 when others => 0);
               Stop  : constant Wuffs.Index := (case Where is when 1 => Last, when 2 => 19,
                 when others => Last);
               In_Object : Wuffs.Bytes renames Object (First .. Stop);
            begin
               Start (Resumed);
               Rejected
                 (K,
                  Dec.Decode_Image_Config
                    (A_Dst => IC, A_Dst_Null => False, A_Src => In_Object, A_Src_Meta => SM),
                  Object, "decode_image_config, src in the object");
               Check
                 (Dec.Set_Quirk (A_Key => 1, A_Value => 1) = Disabled,
                  "decode_image_config, src in the object: not disabled", Kind'Pos (K));
            end;
         end loop;
         Start (Resumed);
         SM := Too_Long;
         Rejected
           (K,
            Dec.Decode_Image_Config
              (A_Dst => IC, A_Dst_Null => False, A_Src => Arena (S .. S + 7), A_Src_Meta => SM),
            Object, "decode_image_config, src meta too long");
      end loop;

      for Where in 1 .. 3 loop
         declare
            First : constant Wuffs.Index := (case Where is when 1 => Last - 7, when 2 => 12,
              when others => 0);
            Stop  : constant Wuffs.Index := (case Where is when 1 => Last, when 2 => 19,
              when others => Last);
            In_Object : Wuffs.Bytes renames Object (First .. Stop);
         begin
            Start (False);
            Rejected
              (K,
               Dec.Decode_Frame_Config
                 (A_Dst => FC, A_Dst_Null => False, A_Src => In_Object, A_Src_Meta => SM),
               Object, "decode_frame_config, src in the object");

            Start (False);
            Rejected
              (K,
               Frame
                 (Dec, PB_4x4, Arena (P .. P + 63), Arena (L .. L + 1023), In_Object, SM,
                  Arena (W .. W + 15)),
               Object, "decode_frame, src in the object");
            Start (False);
            Rejected
              (K,
               Frame
                 (Dec, PB_4x4, Arena (P .. P + 63), Arena (L .. L + 1023), Arena (S .. S + 7), SM,
                  In_Object),
               Object, "decode_frame, workbuf in the object");
            Check
              (Dec.Set_Quirk (A_Key => 1, A_Value => 1) = Disabled,
               "decode_frame, workbuf in the object: not disabled", Kind'Pos (K));
            Start (False);
            Rejected
              (K,
               Frame
                 (Dec, PB_4x4, Arena (P .. P + 63), In_Object, Arena (S .. S + 7), SM,
                  Arena (W .. W + 15)),
               Object, "decode_frame, palette in the object");

            Start (False);
            Rejected
              (K,
               Dec.Tell_Me_More
                 (A_Dst        => In_Object,
                  A_Dst_Meta   => DM,
                  A_Minfo      => MI,
                  A_Minfo_Null => False,
                  A_Src        => Arena (S .. S + 7),
                  A_Src_Meta   => SM),
               Object, "tell_me_more, dst in the object");
            Check
              (Dec.Set_Quirk (A_Key => 1, A_Value => 1) = Disabled,
               "tell_me_more, dst in the object: not disabled", Kind'Pos (K));
            Start (False);
            Rejected
              (K,
               Dec.Tell_Me_More
                 (A_Dst        => Arena (D .. D + 255),
                  A_Dst_Meta   => DM,
                  A_Minfo      => MI,
                  A_Minfo_Null => False,
                  A_Src        => In_Object,
                  A_Src_Meta   => SM),
               Object, "tell_me_more, src in the object");
         end;
      end loop;
      --  Pixels in the object (64 bytes: every decoder is larger).
      Start (False);
      Rejected
        (K,
         Frame
           (Dec, PB_4x4, Object (Last - 63 .. Last), Arena (L .. L + 1023), Arena (S .. S + 7),
             SM,
            Arena (W .. W + 15)),
         Object, "decode_frame, pixels in the object");

      --  Booleans that are neither False nor True.
      if not Checks_Enabled then
         Start (False);
         Rejected
           (K,
            Dec.Decode_Image_Config
              (A_Dst => IC, A_Dst_Null => Bad_Boolean, A_Src => Arena (S .. S + 7),
                A_Src_Meta => SM),
            Object, "decode_image_config, invalid Boolean");
         Start (False);
         Rejected
           (K,
            Dec.Decode_Frame_Config
              (A_Dst => FC, A_Dst_Null => Bad_Boolean, A_Src => Arena (S .. S + 7),
                A_Src_Meta => SM),
            Object, "decode_frame_config, invalid Boolean");
         Start (False);
         Rejected
           (K,
            Dec.Decode_Frame
              (A_Dst         => PB_4x4,
               A_Dst_Pixels  => Arena (P .. P + 63),
               A_Dst_Palette => Arena (L .. L + 1023),
               A_Src         => Arena (S .. S + 7),
               A_Src_Meta    => SM,
               A_Blend       => PF.Blend_Src,
               A_Workbuf     => Arena (W .. W + 15),
               A_Opts        => Opts,
               A_Opts_Null   => Bad_Boolean),
            Object, "decode_frame, invalid Boolean");
         Start (False);
         Rejected
           (K,
            Dec.Tell_Me_More
              (A_Dst        => Arena (D .. D + 255),
               A_Dst_Meta   => DM,
               A_Minfo      => MI,
               A_Minfo_Null => Bad_Boolean,
               A_Src        => Arena (S .. S + 7),
               A_Src_Meta   => SM),
            Object, "tell_me_more, invalid Boolean");
         Start (False);
         Dec.Set_Report_Metadata (A_Fourcc => 16#4943_4350#, A_Report => Bad_Boolean);
         Check
           (Unchanged (Object) and then Dec.Set_Quirk (A_Key => 1, A_Value => 1) = Disabled,
            "set_report_metadata, invalid Boolean", Kind'Pos (K));
      end if;
      Initialize (K);
   end Check_Decoder;

   procedure Make_Image (K : Decoder_Kind; Length : out Wuffs.Index) is
      PPM_Header : constant String := "P6" & ASCII.LF & "2 2" & ASCII.LF & "255" & ASCII.LF;
      GIF_File : constant Wuffs.Bytes :=
        [16#47#, 16#49#, 16#46#, 16#38#, 16#39#, 16#61#, 2, 0, 2, 0, 16#80#, 0, 0,
         16#10#, 16#20#, 16#30#, 16#40#, 16#50#, 16#60#,
         16#2C#, 0, 0, 0, 0, 2, 0, 2, 0, 0,
         2, 3, 16#44#, 16#34#, 16#05#, 0, 16#3B#];
      N : Wuffs.Index := 0;

      procedure Put (B : Wuffs.U8);

      procedure Put (B : Wuffs.U8) is
      begin
         Arena (S + N) := B;
         N := N + 1;
      end Put;
   begin
      case K is
         when Bmp =>
            --  The file header and a BITMAPINFOHEADER; two rows of two
            --  pixels, each row padded to 8 bytes.
            for B of Wuffs.Bytes'
              [16#42#, 16#4D#, 70, 0, 0, 0, 0, 0, 0, 0, 54, 0, 0, 0,
               40, 0, 0, 0, 2, 0, 0, 0, 2, 0, 0, 0, 1, 0, 24, 0, 0, 0, 0, 0, 16, 0, 0, 0,
               0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]
            loop
               Put (B);
            end loop;
            for I in Wuffs.U8 range 1 .. 16 loop
               Put (10 * I);
            end loop;
         when Gif =>
            for B of GIF_File loop
               Put (B);
            end loop;
         when others =>
            for C of PPM_Header loop
               Put (Character'Pos (C));
            end loop;
            for I in Wuffs.U8 range 1 .. 12 loop
               Put (10 * I);
            end loop;
      end case;
      Length := N;
   end Make_Image;

   procedure Check_Resume (Dec : in out Decoder; K : Decoder_Kind; Size : Long_Long_Integer) is
      Object : Wuffs.Bytes (0 .. Wuffs.Index (Size / 8) - 1)
      with Import, Address => Dec'Address;

      Length : Wuffs.Index;
      Short  : Wuffs.Index;
      IC     : PF.Image_Config;
      SM     : IO.Buffer_Meta;
      St     : Wuffs.Status;
      Bad    : PB.Pixel_Buffer;

      procedure Suspend;

      --  Decodes the image configuration and starts decode_frame with all
      --  but the last 3 bytes of the file: it asks for more.
      procedure Suspend is
      begin
         Arena := [others => Fill];
         Make_Image (K, Length);
         Short := Length - 3;
         Initialize (K);
         SM := (Wi => Short, Ri => 0, Pos => 0, Closed => False);
         St :=
           Dec.Decode_Image_Config
             (A_Dst => IC, A_Dst_Null => False, A_Src => Arena (S .. S + Short - 1),
               A_Src_Meta => SM);
         Check
           (Wuffs.Is_Ok (St) and then IC.Pixcfg.Width = 2 and then IC.Pixcfg.Height = 2,
            "the small image's configuration", Kind'Pos (K));
         St :=
           Frame
             (Dec, PB_2x2, Arena (P .. P + 15), Arena (L .. L + 1023), Arena (S .. S + Short - 1),
               SM,
              Arena (W .. W + 1023));
         Check
           (St = Wuffs.Base.Suspension_Short_Read,
             "decode_frame of the small image did not suspend",
            Kind'Pos (K));
         --  What the frame has written so far does not matter below.
         Arena (P .. P + 15) := [others => Fill];
         Arena (L .. L + 1023) := [others => Fill];
         Arena (W .. W + 1023) := [others => Fill];
         --  The file's bytes are in Arena too: keep them out of the check.
         Arena (Copy .. Copy + Wuffs.Index'Min (Object'Length, 1024) - 1) :=
           Object (0 .. Wuffs.Index'Min (Object'Length, 1024) - 1);
         Arena (S .. S + Length - 1) := [others => Fill];
         SM := (Wi => Length, Ri => SM.Ri, Pos => 0, Closed => True);
      end Suspend;

      procedure Resume_Rejected (Status : Wuffs.Status; What : String);

      procedure Resume_Rejected (Status : Wuffs.Status; What : String) is
      begin
         Rejected (K, Status, Object, What);
         Check
           (Dec.Set_Quirk (A_Key => 1, A_Value => 1) = Disabled, What, Kind'Pos (K),
             ": not disabled");
      end Resume_Rejected;

      Src : Wuffs.Bytes renames Arena (S .. S + 35);
   begin
      --  The control: resumed with the rest of the input, it finishes.
      Suspend;
      Make_Image (K, Length);
      St :=
        Frame
          (Dec, PB_2x2, Arena (P .. P + 15), Arena (L .. L + 1023), Arena (S .. S + Length - 1), SM,
           Arena (W .. W + 1023));
      Check (Wuffs.Is_Ok (St), "decode_frame of the small image, resumed", Kind'Pos (K));
      Check
        (Arena (P + 3) = 16#FF# or else Arena (P + 7) = 16#FF# or else Arena (P + 11) = 16#FF#
         or else Arena (P + 15) = 16#FF#
         --  (All of the GIF's pixels were written before the suspension.)
         or else K = Gif,
         "the small image's pixels", Kind'Pos (K));

      --  Overlaps that the first call did not have.
      Suspend;
      Resume_Rejected
        (Frame (Dec, PB_2x2, Arena (S + 20 .. S + 35), Arena (L .. L + 1023), Src, SM,
          Arena (W .. W + 1023)),
         "resumed: pixels inside src");
      Suspend;
      Resume_Rejected
        (Frame (Dec, PB_2x2, Arena (L .. L + 15), Arena (L .. L + 1023), Src, SM,
          Arena (W .. W + 1023)),
         "resumed: pixels inside palette");
      Suspend;
      Resume_Rejected
        (Frame (Dec, PB_2x2, Arena (P .. P + 15), Arena (L .. L + 1023), Src, SM,
          Arena (P + 15 .. P + 30)),
         "resumed: workbuf overlaps pixels");
      Suspend;
      Resume_Rejected
        (Frame (Dec, PB_2x2, Arena (P .. P + 15), Arena (S + 30 .. S + 1053), Src, SM,
          Arena (W .. W + 1023)),
         "resumed: palette overlaps src");
      Suspend;
      Resume_Rejected
        (Frame
           (Dec, PB_2x2, Arena (P .. P + 15), Arena (L .. L + 1023), Src, SM,
            Object (Object'Last - 15 .. Object'Last)),
         "resumed: workbuf in the object");
      Suspend;
      Resume_Rejected
        (Frame
           (Dec, PB_2x2, Object (Object'Last - 15 .. Object'Last), Arena (L .. L + 1023), Src, SM,
            Arena (W .. W + 1023)),
         "resumed: pixels in the object");

      --  Another descriptor, or other arrays, that do not fit together.
      Suspend;
      Resume_Rejected
        (Frame (Dec, PB_4x4, Arena (P .. P + 15), Arena (L .. L + 1023), Src, SM,
          Arena (W .. W + 1023)),
         "resumed: a larger pixel buffer for the same array");
      Suspend;
      Resume_Rejected
        (Frame (Dec, PB_2x2, Arena (P .. P + 14), Arena (L .. L + 1023), Src, SM,
          Arena (W .. W + 1023)),
         "resumed: a shorter pixel array");
      Suspend;
      Bad := PB_2x2;
      Bad.Planes (0).Offset := 1;
      Resume_Rejected
        (Frame (Dec, Bad, Arena (P .. P + 15), Arena (L .. L + 1023), Src, SM,
          Arena (W .. W + 1023)),
         "resumed: another offset");
      Suspend;
      Bad := PB_2x2;
      Bad.Planes (0).Stride := 9;
      Resume_Rejected
        (Frame (Dec, Bad, Arena (P .. P + 15), Arena (L .. L + 1023), Src, SM,
          Arena (W .. W + 1023)),
         "resumed: another stride");
      Suspend;
      Bad := PB_2x2;
      Bad.Pixcfg.Pixfmt.Repr := 16#8100_BBBB#;
      Resume_Rejected
        (Frame (Dec, Bad, Arena (P .. P + 15), Arena (L .. L + 1023), Src, SM,
          Arena (W .. W + 1023)),
         "resumed: a format with wider pixels");
      Suspend;
      Bad := PB_2x2;
      Bad.Pixcfg.Pixfmt.Repr := 16#8104_0008#;
      Resume_Rejected
        (Frame (Dec, Bad, Arena (P .. P + 15), Arena (L .. L + 1022), Src, SM,
          Arena (W .. W + 1023)),
         "resumed: an indexed format without a palette");
      Suspend;
      SM := Too_Long;
      Resume_Rejected
        (Frame (Dec, PB_2x2, Arena (P .. P + 15), Arena (L .. L + 1023), Src, SM,
          Arena (W .. W + 1023)),
         "resumed: a meta that is too long");

      --  Valid arguments that differ from the first call's: another, smaller
      --  pixel buffer elsewhere, no palette and no work buffer.  Not an
      --  argument error, and nothing is written outside of the new pixels.
      Suspend;
      Make_Image (K, Length);
      Bad := PB_2x2;
      Bad.Pixcfg.Height := 1;
      Bad.Planes (0).Height := 1;
      St :=
        Frame
          (Dec, Bad, Arena (D .. D + 7), Arena (L .. L - 1), Arena (S .. S + Length - 1), SM,
           Arena (W .. W - 1));
      Check (St /= Bad_Argument, "resumed with a smaller pixel buffer: rejected", Kind'Pos (K));
      Arena (S .. S + Length - 1) := [others => Fill];
      Arena (D .. D + 7) := [others => Fill];
      Check (Arena_Is_Intact, "resumed with a smaller pixel buffer: memory was written",
        Kind'Pos (K));
      Initialize (K);
   end Check_Resume;

   procedure Check_Null_Pointers (Dec : in out Decoder; K : Decoder_Kind) is
      Length : Wuffs.Index;
      IC     : PF.Image_Config;
      FC     : PF.Frame_Config;
      MI     : Wuffs.Runtime.More_Information;
      Opts   : Wuffs.Runtime.Decode_Frame_Options;
      SM, DM : IO.Buffer_Meta;
      St     : Wuffs.Status;

      --  The objects as bytes: they are filled with a pattern that is not
      --  even a value of their types, and must come back as they were.
      IC_Bytes : Wuffs.Bytes (1 .. PF.Image_Config'Size / 8)
      with Import, Address => IC'Address;
      FC_Bytes : Wuffs.Bytes (1 .. PF.Frame_Config'Size / 8)
      with Import, Address => FC'Address;
      MI_Bytes : Wuffs.Bytes (1 .. Wuffs.Runtime.More_Information'Size / 8)
      with Import, Address => MI'Address;
   begin
      Arena := [others => Fill];
      Make_Image (K, Length);
      Initialize (K);
      IC_Bytes := [others => 16#EE#];
      FC_Bytes := [others => 16#EE#];
      MI_Bytes := [others => 16#EE#];
      SM := (Wi => Length, Ri => 0, Pos => 0, Closed => True);
      St :=
        Dec.Decode_Image_Config
          (A_Dst => IC, A_Dst_Null => True, A_Src => Arena (S .. S + Length - 1), A_Src_Meta => SM);
      Check (Wuffs.Is_Ok (St), "decode_image_config with a null dst", Kind'Pos (K));
      Check
        ((for all B of IC_Bytes => B = 16#EE#), "decode_image_config wrote to a null dst",
         Kind'Pos (K));
      St :=
        Dec.Decode_Frame_Config
          (A_Dst => FC, A_Dst_Null => True, A_Src => Arena (S .. S + Length - 1), A_Src_Meta => SM);
      Check (Wuffs.Is_Ok (St), "decode_frame_config with a null dst", Kind'Pos (K));
      Check
        ((for all B of FC_Bytes => B = 16#EE#), "decode_frame_config wrote to a null dst",
         Kind'Pos (K));
      St :=
        Dec.Decode_Frame
          (A_Dst         => PB_2x2,
           A_Dst_Pixels  => Arena (P .. P + 15),
           A_Dst_Palette => Arena (L .. L + 1023),
           A_Src         => Arena (S .. S + Length - 1),
           A_Src_Meta    => SM,
           A_Blend       => PF.Blend_Src,
           A_Workbuf     => Arena (W .. W + 1023),
           A_Opts        => Opts,
           A_Opts_Null   => True);
      Check (Wuffs.Is_Ok (St), "decode_frame with null options", Kind'Pos (K));
      DM := IO.Empty_Meta;
      St :=
        Dec.Tell_Me_More
          (A_Dst        => Arena (D .. D + 255),
           A_Dst_Meta   => DM,
           A_Minfo      => MI,
           A_Minfo_Null => True,
           A_Src        => Arena (S .. S + Length - 1),
           A_Src_Meta   => SM);
      Check (Wuffs.Is_Error (St), "tell_me_more without metadata", Kind'Pos (K));
      Check ((for all B of MI_Bytes => B = 16#EE#), "tell_me_more wrote to a null minfo",
        Kind'Pos (K));

      --  The control: with a pointer that is not null, the same calls write.
      Initialize (K);
      SM := (Wi => Length, Ri => 0, Pos => 0, Closed => True);
      St :=
        Dec.Decode_Image_Config
          (A_Dst => IC, A_Dst_Null => False, A_Src => Arena (S .. S + Length - 1),
            A_Src_Meta => SM);
      Check
        (Wuffs.Is_Ok (St) and then IC.Pixcfg.Width = 2, "decode_image_config with a dst",
          Kind'Pos (K));
      St :=
        Dec.Decode_Frame_Config
          (A_Dst => FC, A_Dst_Null => False, A_Src => Arena (S .. S + Length - 1),
            A_Src_Meta => SM);
      Check
        (Wuffs.Is_Ok (St) and then FC.Bounds.Max_Excl_X = 2, "decode_frame_config with a dst",
         Kind'Pos (K));
      Initialize (K);
   end Check_Null_Pointers;

   procedure Check_Tell_Me_More is
      --  A GIF header (1 by 1, no colour table) and the start of an
      --  application extension, "ICCRGBG1012", with a 3 byte sub-block.
      File : constant Wuffs.Bytes :=
        [16#47#, 16#49#, 16#46#, 16#38#, 16#39#, 16#61#, 1, 0, 1, 0, 0, 0, 0,
         16#21#, 16#FF#, 16#0B#,
         16#49#, 16#43#, 16#43#, 16#52#, 16#47#, 16#42#, 16#47#, 16#31#, 16#30#, 16#31#, 16#32#,
         3, 16#61#, 16#62#, 16#63#, 0, 16#3B#];
      Header : constant Wuffs.Index := 27;  --  Up to and including "ICCRGBG1012".

      Dec    : Wuffs.Std.Gif.Decoder renames IMS.Gif_Decoder;
      Object : Wuffs.Bytes (0 .. IMS.Gif_Decoder'Size / 8 - 1)
      with Import, Address => IMS.Gif_Decoder'Address;

      IC     : PF.Image_Config;
      MI     : Wuffs.Runtime.More_Information;
      SM, DM : IO.Buffer_Meta;
      St     : Wuffs.Status;

      procedure Suspend;

      --  Leaves tell_me_more suspended: it has asked for the profile's data.
      procedure Suspend is
      begin
         Arena := [others => Fill];
         Arena (S .. S + File'Length - 1) := File;
         Initialize (Gif);
         Dec.Set_Report_Metadata (A_Fourcc => 16#4943_4350#, A_Report => True);
         SM := (Wi => Header, Ri => 0, Pos => 0, Closed => False);
         St :=
           Dec.Decode_Image_Config
             (A_Dst      => IC,
              A_Dst_Null => False,
              A_Src      => Arena (S .. S + Header - 1),
              A_Src_Meta => SM);
         Check (St = Wuffs.Base.Note_Metadata_Reported, "the GIF's metadata was not reported");
         DM := IO.Empty_Meta;
         St :=
           Dec.Tell_Me_More
             (A_Dst        => Arena (D .. D + 255),
              A_Dst_Meta   => DM,
              A_Minfo      => MI,
              A_Minfo_Null => False,
              A_Src        => Arena (S .. S + Header - 1),
              A_Src_Meta   => SM);
         Check (St = Wuffs.Base.Suspension_Short_Read, "tell_me_more did not suspend");
         Arena (S .. S + File'Length - 1) := [others => Fill];
         Arena (Copy .. Copy + 1023) := Object (0 .. 1023);
         SM := (Wi => File'Length, Ri => SM.Ri, Pos => 0, Closed => True);
      end Suspend;

      function Tell (Dst : in out Wuffs.Bytes; Src : Wuffs.Bytes) return Wuffs.Status
      is (Dec.Tell_Me_More
            (A_Dst        => Dst,
             A_Dst_Meta   => DM,
             A_Minfo      => MI,
             A_Minfo_Null => False,
             A_Src        => Src,
             A_Src_Meta   => SM));

      Src : Wuffs.Bytes renames Arena (S .. S + File'Length - 1);
   begin
      --  The control: resumed with the rest of the file, it goes on and
      --  says where the profile's bytes are.
      Suspend;
      Arena (S .. S + File'Length - 1) := File;
      St := Tell (Arena (D .. D + 255), Src);
      Check
        (St = Wuffs.Base.Suspension_Even_More_Information and then MI.Flavor = 3
         and then MI.W = 16#4943_4350# and then MI.Y = 28 and then MI.Z = 31,
         "tell_me_more, resumed");

      Suspend;
      Rejected (Gif, Tell (Object (Object'Last - 255 .. Object'Last), Src), Object,
                "tell_me_more resumed: dst in the object");
      Check
        (Dec.Set_Quirk (A_Key => 1, A_Value => 1) = Disabled,
         "tell_me_more resumed: dst in the object: not disabled");
      Suspend;
      Rejected (Gif, Tell (Arena (D .. D + 255), Object (12 .. 44)), Object,
                "tell_me_more resumed: src in the object");
      Suspend;
      SM := Too_Long;
      Rejected (Gif, Tell (Arena (D .. D + 255), Src), Object,
                "tell_me_more resumed: a src meta that is too long");
      Suspend;
      DM := Too_Long;
      Rejected (Gif, Tell (Arena (D .. D + 255), Src), Object,
                "tell_me_more resumed: a dst meta that is too long");
      if not Checks_Enabled then
         Suspend;
         Rejected
           (Gif,
            Dec.Tell_Me_More
              (A_Dst        => Arena (D .. D + 255),
               A_Dst_Meta   => DM,
               A_Minfo      => MI,
               A_Minfo_Null => Bad_Boolean,
               A_Src        => Src,
               A_Src_Meta   => SM),
            Object, "tell_me_more resumed: an invalid Boolean");
      end if;
      --  Another destination and source, both valid: not an argument error.
      Suspend;
      Arena (S + 100 .. S + 100 + File'Length - 1) := File;
      St := Tell (Arena (D + 300 .. D + 303), Arena (S + 100 .. S + 100 + File'Length - 1));
      Check (St /= Bad_Argument, "tell_me_more resumed with other arrays");
      Initialize (Gif);
   end Check_Tell_Me_More;

   Cfg : PF.Pixel_Config;
   St  : Wuffs.Status;

begin
   PF.Set (C => Cfg, Pixfmt_Repr => 16#8100_8888#, Pixsub_Repr => 0, Width => 4, Height => 4);
   PB.Set_Interleaved
     (PB             => PB_4x4,
      Pixcfg         => Cfg,
      Primary        => (Offset => 0, Width => 16, Height => 4, Stride => 16),
      Pixels_Length  => 64,
      Palette_Length => 1024,
      Result         => St);
   Check (Wuffs.Is_Ok (St), "Set_Interleaved, 4 by 4");
   PF.Set (C => Cfg, Pixfmt_Repr => 16#8100_8888#, Pixsub_Repr => 0, Width => 2, Height => 2);
   PB.Set_Interleaved
     (PB             => PB_2x2,
      Pixcfg         => Cfg,
      Primary        => (Offset => 0, Width => 8, Height => 2, Stride => 8),
      Pixels_Length  => 16,
      Palette_Length => 1024,
      Result         => St);
   Check (Wuffs.Is_Ok (St), "Set_Interleaved, 2 by 2");

   Check_Hasher (Adler32_Hasher, Adler32, Adler32_Hasher'Size);
   Check_Hasher (Crc32_Hasher, Crc32, Crc32_Hasher'Size);

   Check_Transformer (DS.Lzw_Decoder, Lzw, DS.Lzw_Decoder'Size);
   Check_Transformer (DS.Deflate_Decoder, Deflate, DS.Deflate_Decoder'Size);
   Check_Transformer (DS.Zlib_Decoder, Zlib, DS.Zlib_Decoder'Size);
   Check_Transformer (DS.Gzip_Decoder, Gzip, DS.Gzip_Decoder'Size);

   --  The two other entries that take a slice.
   declare
      Flate : Wuffs.Bytes (0 .. DS.Deflate_Decoder'Size / 8 - 1)
      with Import, Address => DS.Deflate_Decoder'Address;
      Z     : Wuffs.Bytes (0 .. DS.Zlib_Decoder'Size / 8 - 1)
      with Import, Address => DS.Zlib_Decoder'Address;
   begin
      Initialize (Deflate);
      Snapshot (Flate);
      Wuffs.Std.Deflate.Add_History (DS.Deflate_Decoder, Flate (Flate'Last - 99 .. Flate'Last));
      Check (Unchanged (Flate), "add_history with a part of the decoder: changed");
      Check
        (DS.Deflate_Decoder.Set_Quirk (A_Key => 1, A_Value => 1) = Disabled,
         "add_history with a part of the decoder: not disabled");
      Initialize (Deflate);
      Initialize (Zlib);
      Snapshot (Z);
      Wuffs.Std.Zlib.Add_Dictionary (DS.Zlib_Decoder, Z (Z'Last - 99 .. Z'Last));
      Check (Unchanged (Z), "add_dictionary with a part of the decoder: changed");
      Check
        (DS.Zlib_Decoder.Set_Quirk (A_Key => 1, A_Value => 1) = Disabled,
         "add_dictionary with a part of the decoder: not disabled");
      Initialize (Zlib);
   end;

   Check_Decoder (IMS.Netpbm_Decoder, Netpbm, IMS.Netpbm_Decoder'Size);
   Check_Decoder (IMS.Bmp_Decoder, Bmp, IMS.Bmp_Decoder'Size);
   Check_Decoder (IMS.Gif_Decoder, Gif, IMS.Gif_Decoder'Size);
   Check_Decoder (IMS.Png_Decoder, Png, IMS.Png_Decoder'Size);
   Check_Decoder (IMS.Wbmp_Decoder, Wbmp, IMS.Wbmp_Decoder'Size);
   Check_Decoder (IMS.Nie_Decoder, Nie, IMS.Nie_Decoder'Size);
   Check_Decoder (IMS.Targa_Decoder, Targa, IMS.Targa_Decoder'Size);

   Check_Resume (IMS.Netpbm_Decoder, Netpbm, IMS.Netpbm_Decoder'Size);
   Check_Resume (IMS.Bmp_Decoder, Bmp, IMS.Bmp_Decoder'Size);
   Check_Resume (IMS.Gif_Decoder, Gif, IMS.Gif_Decoder'Size);

   Check_Null_Pointers (IMS.Netpbm_Decoder, Netpbm);
   Check_Null_Pointers (IMS.Bmp_Decoder, Bmp);
   Check_Null_Pointers (IMS.Gif_Decoder, Gif);

   Check_Tell_Me_More;

   Test_Support.Finish ("test_entry");
end Test_Entry;
