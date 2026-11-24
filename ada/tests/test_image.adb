--  Part of wuffada (wuffs-ada: Wuffs to Ada).
--  SPDX-License-Identifier: Apache-2.0 OR MIT

--  Runs the generated image decoders (netpbm, bmp, gif, png, wbmp, nie, targa,
--  jpeg, vp8, webp, ...) over a
--  manifest of test cases (from ada/tests/imgcorpus) and prints a trace of
--  what they did, which test.sh compares, line for line, with the trace of
--  upstream's C decoders (ada/tests/crosscheck/image.c: keep the two in
--  step).  Where the manifest names a file of expected pixels (from an
--  independent decoder), it also compares the first frame with those.
--
--  usage: test_image < MANIFEST
--
--  A manifest line is
--
--    FORMAT PIXFMT BLEND SCHEDULE FLAGS SCRIPT EXPECTED PATH
--
--  PIXFMT (hexadecimal) and BLEND are the destination pixel format and the
--  blend.  SCHEDULE says how the source arrives: W (all at once), Cn (n more
--  bytes whenever the decoder asks) or Kn (the same through a 4096 byte
--  window that is compacted, so that buffer positions and stream positions
--  differ).  FLAGS is "-" or a comma-separated list of: m (report
--  metadata), p (a pixel buffer for half the width and height), w (a work
--  buffer that is too short), l (pixel rows at an offset and with a gap
--  between them: Ada only), qN (set quirk N to 1), QN (set quirk N to
--  16#8000_0000_0000_0000#: for base.QUIRK_QUALITY, lower quality), vK:V
--  (set quirk K to V, both decimal: for vp8's QUIRK_SOURCE_LENGTH and the
--  like), tN and
--  kNAME (compare with the reference pixels with a tolerance of N per
--  channel, not exactly, and count the comparison in category NAME: for
--  JPEG, whose decoders legitimately differ in rounding and upsampling), aN
--  (also require the mean of the per-channel differences to be at most N
--  hundredths), A (an animation: EXPECTED is libwebp's WebPAnimDecoder
--  output, the canvas after each frame; the run composites the frames as
--  a caller would, from the frame configs, the way WebPAnimDecoder does,
--  and compares after each frame: Ada only, for a BGRA_NONPREMUL run with
--  blend SRC and the script I*).
--  SCRIPT is the calls to make: I and C (decode_image_config and
--  decode_frame_config; i and c: with a null destination), F (decode_frame),
--  * (C and F until one fails), R and r (restart_frame, with good and with
--  bad arguments), L (restart_frame at the last frame config's frame), B
--  (restart_frame at a bogus position: index 2, inside the first frame's
--  header), T (tell_me_more).
--
--  One more flag, xN, makes a "chaos" run with seed N: whenever a call is
--  suspended, the next call may get other arguments than the first: another
--  pixel buffer (format, size, offset, stride) in another place, a shorter,
--  longer or misplaced work buffer or palette, a work buffer that overlaps
--  the pixels, another blend, a corrupt source meta.  Such a run has no
--  counterpart in C and its trace means nothing; what is checked is that
--  nothing raises an exception and that no byte next to the arrays that the
--  decoder was given is written.  test.sh runs these from a manifest of
--  their own.

with Ada.Streams.Stream_IO;
with Ada.Text_IO;
with Image_Support;
with Interfaces;
with Test_Support;
with Wuffs.Base.IO;
with Wuffs.Base.Pixel_Buffers;
with Wuffs.Base.Pixel_Formats;
with Wuffs.Base.Ranges;
with Wuffs.Runtime;
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

procedure Test_Image is

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
   use type Ada.Streams.Stream_IO.Count;

   Fnv_Start : constant Wuffs.U64 := 16#CBF2_9CE4_8422_2325#;
   Fnv_Prime : constant Wuffs.U64 := 16#100_0000_01B3#;

   Max_Frames : constant := 400;
   Max_Quirks : constant := 8;

   type Quirk_List is array (1 .. Max_Quirks) of Wuffs.U32;
   type Quirk_Values is array (1 .. Max_Quirks) of Wuffs.U64;

   type Run_Case is record
      Id         : Natural := 0;
      Pixfmt     : Wuffs.U32 := 0;
      Blend      : PF.Pixel_Blend := 0;
      Sched      : Character := 'W';
      Chunk      : Wuffs.Index := 0;
      Meta       : Boolean := False;
      Small_Pix  : Boolean := False;
      Small_Work : Boolean := False;
      Layout     : Boolean := False;
      Quirks     : Quirk_List := [others => 0];
      Values     : Quirk_Values := [others => 1];
      Num_Quirks : Natural := 0;
      Chaos      : Boolean := False;
      Anim       : Boolean := False;
      Has_Expect : Boolean := False;
      Exp_Length : Wuffs.Index := 0;
      Tolerance  : Natural := 0;
      Mean_Limit : Natural := Natural'Last;  --  In hundredths.
      Category   : Natural := 0;  --  In Categories; 0 for none.
   end record;

   --  The comparisons with a tolerance, by category (in Image_Support).
   Max_Categories : constant := IMS.Max_Categories;
   subtype Category_Stats is IMS.Category_Stats;
   Categories     : IMS.Category_Table renames IMS.Categories;
   Num_Categories : Natural := 0;

   Fourccs : constant array (1 .. 7) of Wuffs.U32 :=
     [16#4348_524D#, 16#4558_4946#, 16#4741_4D41#, 16#4943_4350#, 16#4B56_5020#,
      16#5352_4742#, 16#584D_5020#];

   --  The state of a run.
   Run      : Run_Case;
   Len      : Wuffs.Index := 0;    --  Of the file.
   Fed      : Wuffs.Index := 0;
   Src_Len  : Wuffs.Index := 0;    --  Of the source buffer's data.
   Src_Meta : IO.Buffer_Meta := IO.Empty_Meta;
   Buf      : PB.Pixel_Buffer := PB.Null_Pixel_Buffer;
   Have_PB  : Boolean := False;
   Pix_Len  : Wuffs.Index := 0;    --  Of the pixel array given to the decoder.
   Ffio     : Wuffs.U64 := 0;
   --  The index and I/O position of the last frame config (script op L).
   Last_Index : Wuffs.U64 := 0;
   Last_IO    : Wuffs.U64 := 0;
   Compared : Boolean := False;

   --  For an animation run (flag A): the last frame config, and what the
   --  compositing needs to know of the previous frame.
   Last_FC      : PF.Frame_Config;
   Anim_Frame   : Natural := 0;
   Prev_Key     : Boolean := False;
   Prev_Dispose : Boolean := False;
   Prev_Rect    : Wuffs.Base.Ranges.Rect_IE_U32;
   Anim_Differed : Boolean := False;

   --  For a chaos run: its random numbers, the image's size, and where the
   --  arrays of the next decode_frame call are (in IMS.Pix, IMS.Chaos_Pal
   --  and IMS.Work, or the work buffer in IMS.Pix too, overlapping the
   --  pixels).
   Seed            : Wuffs.U32 := 1;
   Orig_W, Orig_H  : Wuffs.U32 := 16;
   --  Whether the image's size is known (decode_image_config succeeded),
   --  and whether the decoder is std/webp's or std/vp8's: then every frame
   --  dirty rectangle must lie within the image, even after an error.
   Image_Known     : Boolean := False;
   Check_Dirty     : Boolean := False;
   Pix_Lo          : Wuffs.Index := IMS.Pix_First;
   Pal_Lo          : Wuffs.Index := 0;
   Pal_Len         : Wuffs.Index := 0;
   Work_Lo         : Wuffs.Index := 1;
   Chaos_Work_Len  : Wuffs.Index := 0;
   Chaos_Work_Set  : Boolean := False;
   Work_In_Pixels  : Boolean := False;
   Chaos_Out_Len   : Wuffs.Index := 4096;
   Chaos_Steps     : Natural := 0;

   Guard : constant := 64;

   Cases      : Natural := 0;
   References : Natural := 0;

   procedure Put (S : String) renames Ada.Text_IO.Put;

   procedure Put_Number (X : Wuffs.U64);

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
      Put (Text (First .. Text'Last));
   end Put_Number;

   procedure KV (Key : String; Value : Wuffs.U64);

   procedure KV (Key : String; Value : Wuffs.U64) is
   begin
      Put (" ");
      Put (Key);
      Put ("=");
      Put_Number (Value);
   end KV;

   procedure Put_Status (S : Wuffs.Status);

   procedure Put_Status (S : Wuffs.Status) is
   begin
      Put (" st=");
      Put_Number (Wuffs.Status_Category'Pos (S.Category));
      Put (":");
      Put_Number (Wuffs.U64 (S.Code));
   end Put_Status;

   procedure Begin_Line (What : String);

   procedure Begin_Line (What : String) is
   begin
      Put ("= ");
      Put_Number (Wuffs.U64 (Run.Id));
      Put (" ");
      Put (What);
   end Begin_Line;

   procedure Fnv (H : in out Wuffs.U64; Data : Wuffs.Bytes);

   procedure Fnv (H : in out Wuffs.U64; Data : Wuffs.Bytes) is
   begin
      for B of Data loop
         H := (H xor Wuffs.U64 (B)) * Fnv_Prime;
      end loop;
   end Fnv;

   procedure Fnv_U64 (H : in out Wuffs.U64; X : Wuffs.U64);

   procedure Fnv_U64 (H : in out Wuffs.U64; X : Wuffs.U64) is
      V : Wuffs.U64 := X;
   begin
      for I in 1 .. 8 loop
         H := (H xor (V and 16#FF#)) * Fnv_Prime;
         V := Interfaces.Shift_Right (V, 8);
      end loop;
   end Fnv_U64;

   procedure Load
     (Name : String; Into : out Wuffs.Bytes; Length : out Wuffs.Index; OK : out Boolean);

   procedure Load
     (Name : String; Into : out Wuffs.Bytes; Length : out Wuffs.Index; OK : out Boolean)
   is
      package SIO renames Ada.Streams.Stream_IO;
      File : SIO.File_Type;
      Size : SIO.Count;
   begin
      Length := 0;
      OK := False;
      SIO.Open (File, SIO.In_File, Name);
      Size := SIO.Size (File);
      if Size <= SIO.Count (Into'Length) then
         if Size > 0 then
            declare
               subtype SEO is Ada.Streams.Stream_Element_Offset;
               use type Ada.Streams.Stream_Element_Offset;
               Item : Ada.Streams.Stream_Element_Array (1 .. SEO (Size))
               with Import, Address => Into'Address;
               Last : Ada.Streams.Stream_Element_Offset;
            begin
               SIO.Read (File, Item, Last);
               OK := Last = Item'Last;
            end;
         else
            OK := True;
         end if;
         Length := Wuffs.Index (Size);
      end if;
      SIO.Close (File);
   exception
      when others =>
         OK := False;
   end Load;

   ---------------------------------------------------------------------------
   --  The source.
   ---------------------------------------------------------------------------

   function Position return Wuffs.U64 is (Src_Meta.Pos + Wuffs.U64 (Src_Meta.Ri));

   procedure Src_Begin;

   procedure Src_Begin is
   begin
      Fed := 0;
      if Run.Sched = 'K' then
         Src_Len := IMS.Window;
         Src_Meta := (Wi => 0, Ri => 0, Pos => 0, Closed => Len = 0);
         return;
      end if;
      IMS.Src (IMS.Src_First .. IMS.Src_First + Len - 1) := IMS.File (0 .. Len - 1);
      Src_Len := Len;
      Src_Meta := (Wi => Len, Ri => 0, Pos => 0, Closed => True);
      if Run.Sched = 'C' and then Run.Chunk < Len then
         Src_Meta.Wi := Run.Chunk;
      end if;
      Src_Meta.Closed := Src_Meta.Wi = Len;
   end Src_Begin;

   procedure Src_Seek (To : Wuffs.U64);

   procedure Src_Seek (To : Wuffs.U64) is
      At_Pos : constant Wuffs.Index :=
        (if To > Wuffs.U64 (Len) then Len else Wuffs.Index (To));
   begin
      if Run.Sched = 'K' then
         Fed := At_Pos;
         Src_Meta := (Wi => 0, Ri => 0, Pos => Wuffs.U64 (At_Pos), Closed => Fed = Len);
         return;
      end if;
      Src_Meta :=
        (Wi     => Wuffs.Index'Max (Src_Meta.Wi, At_Pos),
         Ri     => At_Pos,
         Pos    => Src_Meta.Pos,
         Closed => Wuffs.Index'Max (Src_Meta.Wi, At_Pos) = Len);
   end Src_Seek;

   function Src_Feed return Boolean;

   function Src_Feed return Boolean is
      N, Add : Wuffs.Index;
   begin
      if Src_Meta.Closed then
         return False;
      end if;
      if Run.Sched = 'C' then
         Add := Wuffs.Index'Min (Len - Src_Meta.Wi, Run.Chunk);
         Src_Meta.Wi := Src_Meta.Wi + Add;
         Src_Meta.Closed := Src_Meta.Wi = Len;
         return True;
      elsif Run.Sched = 'K' then
         N := Src_Meta.Wi - Src_Meta.Ri;
         for I in 0 .. N - 1 loop
            IMS.Src (IMS.Src_First + I) := IMS.Src (IMS.Src_First + Src_Meta.Ri + I);
         end loop;
         Src_Meta :=
           (Wi     => N,
            Ri     => 0,
            Pos    => Src_Meta.Pos + Wuffs.U64 (Src_Meta.Ri),
            Closed => False);
         Add := Wuffs.Index'Min (Wuffs.Index'Min (Run.Chunk, IMS.Window - N), Len - Fed);
         if Add = 0 then
            return False;
         end if;
         IMS.Src (IMS.Src_First + N .. IMS.Src_First + N + Add - 1) :=
           IMS.File (Fed .. Fed + Add - 1);
         Src_Meta.Wi := Src_Meta.Wi + Add;
         Fed := Fed + Add;
         Src_Meta.Closed := Fed = Len;
         return True;
      end if;
      return False;
   end Src_Feed;

   ---------------------------------------------------------------------------
   --  The pixel buffer.
   ---------------------------------------------------------------------------

   Offset_In_Layout : constant := 7;
   Gap_In_Layout    : constant := 5;
   Canary           : constant Wuffs.U8 := 16#A5#;

   function Plane_0 return PB.Table is (PB.Plane (Buf, 0));

   procedure Setup_PB (Width, Height : Wuffs.U32);

   procedure Setup_PB (Width, Height : Wuffs.U32) is
      W      : Wuffs.U32 := Width;
      H      : Wuffs.U32 := Height;
      Cfg    : PF.Pixel_Config;
      N      : Wuffs.U64;
      St     : Wuffs.Status;
      Row    : Wuffs.Index;
      Offset : Wuffs.Index := 0;
      Gap    : Wuffs.Index := 0;
      T      : PB.Table;
   begin
      if Run.Small_Pix then
         W := (W + 1) / 2;
         H := (H + 1) / 2;
      end if;
      PF.Set (C => Cfg, Pixfmt_Repr => Run.Pixfmt, Pixsub_Repr => 0, Width => W, Height => H);
      N := PF.Pixbuf_Len (Cfg);
      Have_PB := False;
      Begin_Line ("pb");
      if N > IMS.Cap_Pix then
         Put (" toobig");
         Ada.Text_IO.New_Line;
         return;
      end if;
      Row := Wuffs.Index (PB.Row_Bytes (Cfg));
      if Run.Layout and then Wuffs.Index (H) * Gap_In_Layout + Offset_In_Layout < IMS.Slack then
         Offset := Offset_In_Layout;
         Gap := Gap_In_Layout;
      end if;
      Pix_Len := Offset + Wuffs.Index (H) * (Row + Gap);
      PB.Set_Interleaved
        (PB             => Buf,
         Pixcfg         => Cfg,
         Primary        =>
           (Offset => Offset, Width => Row, Height => Wuffs.Index (H), Stride => Row + Gap),
         Pixels_Length  => Pix_Len,
         Palette_Length => IMS.Pal'Length,
         Result         => St);
      Put_Status (St);
      KV ("w", Wuffs.U64 (W));
      KV ("h", Wuffs.U64 (H));
      Ada.Text_IO.New_Line;
      if not Wuffs.Is_Ok (St) then
         return;
      end if;
      Have_PB := True;
      for I in IMS.Pal'Range loop
         IMS.Pal (I) := Wuffs.U8 ((Wuffs.U64 (I - IMS.Pal'First) * 5 + 1) mod 256);
      end loop;
      if Pix_Len > 0 then
         IMS.Pix (IMS.Pix_First .. IMS.Pix_First + Pix_Len - 1) := [others => Canary];
      end if;
      T := Plane_0;
      for Y in 0 .. T.Height - 1 loop
         for X in 0 .. T.Width - 1 loop
            IMS.Pix (IMS.Pix_First + T.Offset + Y * T.Stride + X) :=
              Wuffs.U8 ((Wuffs.U64 (X) * 7 + Wuffs.U64 (Y) * 13 + 3) mod 256);
         end loop;
      end loop;
   end Setup_PB;

   procedure Put_Pixels;

   procedure Put_Pixels is
      Pix_Hash : Wuffs.U64 := Fnv_Start;
      Pal_Hash : Wuffs.U64 := Fnv_Start;
      T        : PB.Table;
      First    : Wuffs.Index;
      Intact   : Boolean := True;
   begin
      if Have_PB and then not Run.Chaos then
         if PB.Has_Palette (Buf) then
            Fnv (Pal_Hash, IMS.Pal);
         end if;
         T := Plane_0;
         for Y in 0 .. T.Height - 1 loop
            First := IMS.Pix_First + T.Offset + Y * T.Stride;
            Fnv (Pix_Hash, IMS.Pix (First .. First + T.Width - 1));
            --  The gap after the row.
            for I in First + T.Width .. First + T.Stride - 1 loop
               Intact := Intact and then IMS.Pix (I) = Canary;
            end loop;
         end loop;
         for I in IMS.Pix_First .. IMS.Pix_First + T.Offset - 1 loop
            Intact := Intact and then IMS.Pix (I) = Canary;
         end loop;
         Test_Support.Check (Intact, "bytes outside of the pixel rows were written, case", Run.Id);
      end if;
      KV ("pix", Pix_Hash);
      KV ("pal", Pal_Hash);
   end Put_Pixels;

   --  Compares the frame with the reference decoder's pixels: a file of
   --  four 32-bit little-endian numbers, the frame's bounds, and then its
   --  pixels as BGRA.
   procedure Compare_With_Expected;

   procedure Compare_With_Expected is
      function U32_At (I : Wuffs.Index) return Wuffs.U32;

      function U32_At (I : Wuffs.Index) return Wuffs.U32 is
        (Wuffs.U32 (IMS.Expected (I))
         + Wuffs.U32 (IMS.Expected (I + 1)) * 2**8
         + Wuffs.U32 (IMS.Expected (I + 2)) * 2**16
         + Wuffs.U32 (IMS.Expected (I + 3)) * 2**24);
      T              : constant PB.Table := Plane_0;
      X0, Y0, X1, Y1 : Wuffs.Index;
      E, P           : Wuffs.Index;
      Bad            : Natural := 0;
      Diff, Largest  : Natural := 0;
      Total          : Long_Long_Integer := 0;
      Channels       : Long_Long_Integer := 0;
      Mean           : Natural := 0;
   begin
      if Run.Exp_Length < 16 then
         Test_Support.Check (False, "short reference file, case", Run.Id);
         return;
      end if;
      X0 := Wuffs.Index (U32_At (0));
      Y0 := Wuffs.Index (U32_At (4));
      X1 := Wuffs.Index (U32_At (8));
      Y1 := Wuffs.Index (U32_At (12));
      if X0 > X1 or else Y0 > Y1 or else X1 * 4 > T.Width or else Y1 > T.Height
        or else Run.Exp_Length /= 16 + (X1 - X0) * (Y1 - Y0) * 4
      then
         Test_Support.Check (False, "reference file does not fit the image, case", Run.Id);
         return;
      end if;
      E := 16;
      for Y in Y0 .. Y1 - 1 loop
         P := IMS.Pix_First + T.Offset + Y * T.Stride + X0 * 4;
         for X in 0 .. X1 - X0 - 1 loop
            --  A fully transparent pixel's colour means nothing: Wuffs (in
            --  C too) makes the pixels that a PNG's tRNS colour key selects
            --  transparent black, and Go's decoder keeps their colour.
            if IMS.Pix (P + X * 4 + 3) /= 0 or else IMS.Expected (E + X * 4 + 3) /= 0 then
               for I in X * 4 .. X * 4 + 3 loop
                  Diff :=
                    abs (Natural (IMS.Pix (P + I)) - Natural (IMS.Expected (E + I)));
                  Largest := Natural'Max (Largest, Diff);
                  Total := Total + Long_Long_Integer (Diff);
                  Channels := Channels + 1;
                  if Diff > Run.Tolerance then
                     Bad := Bad + 1;
                  end if;
               end loop;
            end if;
         end loop;
         E := E + (X1 - X0) * 4;
      end loop;
      References := References + 1;
      if Channels > 0 then
         Mean := Natural ((100 * Total + Channels - 1) / Channels);
      end if;
      if Run.Category /= 0 then
         declare
            C : Category_Stats renames Categories (Run.Category);
         begin
            C.Runs := C.Runs + 1;
            C.Tolerance := Natural'Max (C.Tolerance, Run.Tolerance);
            C.Largest := Natural'Max (C.Largest, Largest);
            if Largest > 0 then
               C.Differing := C.Differing + 1;
            end if;
            C.Mean := Natural'Max (C.Mean, Mean);
         end;
      end if;
      Test_Support.Check
        (Mean <= Run.Mean_Limit, "the mean difference from the reference is too large, case",
         Run.Id);
      Test_Support.Check (Bad = 0, "pixels differ from the reference decoder's, case", Run.Id);
   end Compare_With_Expected;

   --  For an animation run: composites the frame just decoded (from the
   --  pixel buffer, in Last_FC's bounds) onto IMS.Canvas the way libwebp's
   --  WebPAnimDecoder does (src/demux/anim_decode.c: its key frames, its
   --  non-premultiplied blending, disposal to transparent black), then
   --  compares the canvas with the reference's canvas after that frame.
   procedure Composite_And_Compare;

   procedure Composite_And_Compare is
      use type Wuffs.Base.Ranges.Rect_IE_U32;
      use type PF.Animation_Disposal;
      subtype U32 is Wuffs.U32;

      function U32_At (I : Wuffs.Index) return U32 is
        (U32 (IMS.Expected (I))
         + U32 (IMS.Expected (I + 1)) * 2**8
         + U32 (IMS.Expected (I + 2)) * 2**16
         + U32 (IMS.Expected (I + 3)) * 2**24);

      --  libwebp's BlendPixelNonPremult, one channel at a time.
      function Blend (Src, Dst : U32) return U32;

      function Blend (Src, Dst : U32) return U32 is
         Src_A, Dst_A, Dst_F, Blend_A, Scale, Result, Sc, Dc : U32;
      begin
         Src_A := Interfaces.Shift_Right (Src, 24);
         if Src_A = 0 then
            return Dst;
         end if;
         Dst_A := Interfaces.Shift_Right (Dst, 24);
         Dst_F := Interfaces.Shift_Right (Dst_A * (256 - Src_A), 8) and 16#FF#;
         Blend_A := (Src_A + Dst_F) and 16#FF#;
         Scale := 2**24 / Blend_A;
         Result := Interfaces.Shift_Left (Blend_A, 24);
         for Shift in 0 .. 2 loop
            Sc := Interfaces.Shift_Right (Src, 8 * Shift) and 16#FF#;
            Dc := Interfaces.Shift_Right (Dst, 8 * Shift) and 16#FF#;
            Result :=
              Result
              or Interfaces.Shift_Left
                   (Interfaces.Shift_Right ((Sc * Src_A + Dc * Dst_F) * Scale, 24) and 16#FF#,
                    8 * Shift);
         end loop;
         return Result;
      end Blend;

      function Get (A : Wuffs.Bytes; I : Wuffs.Index) return U32 is
        (U32 (A (I)) + U32 (A (I + 1)) * 2**8 + U32 (A (I + 2)) * 2**16 + U32 (A (I + 3)) * 2**24);

      procedure Put (A : in out Wuffs.Bytes; I : Wuffs.Index; V : U32);

      procedure Put (A : in out Wuffs.Bytes; I : Wuffs.Index; V : U32) is
      begin
         for K in 0 .. 3 loop
            A (I + Wuffs.Index (K)) := Wuffs.U8 (Interfaces.Shift_Right (V, 8 * K) and 16#FF#);
         end loop;
      end Put;

      T          : constant PB.Table := Plane_0;
      W, H, N    : Wuffs.Index;
      Size       : Wuffs.Index;
      B          : constant Wuffs.Base.Ranges.Rect_IE_U32 := Last_FC.Bounds;
      Whole      : Wuffs.Base.Ranges.Rect_IE_U32;
      Do_Blend   : constant Boolean := not PF.Overwrite_Instead_Of_Blend (Last_FC);
      Key        : Boolean;
      S          : U32;
      In_Prev    : Boolean;
      E, I       : Wuffs.Index;
      Bad        : Natural := 0;
      Diff       : Natural;
      Largest    : Natural := 0;
      Total      : Long_Long_Integer := 0;
      Channels   : Long_Long_Integer := 0;
      Mean       : Natural := 0;
   begin
      if Run.Exp_Length < 12 then
         Test_Support.Check (False, "short animation reference file, case", Run.Id);
         return;
      end if;
      W := Wuffs.Index (U32_At (0));
      H := Wuffs.Index (U32_At (4));
      N := Wuffs.Index (U32_At (8));
      Size := W * H * 4;
      if W * 4 > T.Width or else H > T.Height or else Size > IMS.Cap_Canvas
        or else Run.Exp_Length /= 12 + N * Size
        or else Wuffs.Index (B.Max_Excl_X) > W or else Wuffs.Index (B.Max_Excl_Y) > H
      then
         Test_Support.Check
           (False, "animation reference file does not fit the image, case", Run.Id);
         return;
      end if;
      if Wuffs.Index (Anim_Frame) >= N then
         Test_Support.Check (False, "more frames than the animation reference's, case", Run.Id);
         return;
      end if;
      Whole := (Min_Incl_X => 0, Min_Incl_Y => 0, Max_Excl_X => U32 (W), Max_Excl_Y => U32 (H));

      --  A caller does not know whether a frame has alpha (std/webp reports
      --  no frame as opaque within its bounds) and so takes it to have.
      Key :=
        Anim_Frame = 0
        or else (B = Whole and then not (Do_Blend and then not PF.Opaque_Within_Bounds (Last_FC)))
        or else (Prev_Dispose and then (Prev_Rect = Whole or else Prev_Key));
      if Key then
         IMS.Canvas (0 .. Size - 1) := [others => 0];
      else
         IMS.Canvas (0 .. Size - 1) := IMS.Prev_Canvas (0 .. Size - 1);
      end if;
      for Y in Wuffs.Index (B.Min_Incl_Y) .. Wuffs.Index (B.Max_Excl_Y) - 1 loop
         for X in Wuffs.Index (B.Min_Incl_X) .. Wuffs.Index (B.Max_Excl_X) - 1 loop
            S := Get (IMS.Pix, IMS.Pix_First + T.Offset + Y * T.Stride + X * 4);
            I := (Y * W + X) * 4;
            if Anim_Frame > 0 and then Do_Blend and then not Key then
               In_Prev :=
                 Prev_Dispose
                 and then X >= Wuffs.Index (Prev_Rect.Min_Incl_X)
                 and then X < Wuffs.Index (Prev_Rect.Max_Excl_X)
                 and then Y >= Wuffs.Index (Prev_Rect.Min_Incl_Y)
                 and then Y < Wuffs.Index (Prev_Rect.Max_Excl_Y);
               if not In_Prev and then Interfaces.Shift_Right (S, 24) /= 16#FF# then
                  S := Blend (S, Get (IMS.Prev_Canvas, I));
               end if;
            end if;
            Put (IMS.Canvas, I, S);
         end loop;
      end loop;

      E := 12 + Wuffs.Index (Anim_Frame) * Size;
      for K in 0 .. Size - 1 loop
         Diff := abs (Natural (IMS.Canvas (K)) - Natural (IMS.Expected (E + K)));
         Largest := Natural'Max (Largest, Diff);
         Total := Total + Long_Long_Integer (Diff);
         Channels := Channels + 1;
         if Diff > Run.Tolerance then
            Bad := Bad + 1;
         end if;
      end loop;
      --  A run counts once, as a run with one reference, whatever its
      --  number of frames; and as differing if any frame does.
      if Anim_Frame = 0 then
         References := References + 1;
      end if;
      if Channels > 0 then
         Mean := Natural ((100 * Total + Channels - 1) / Channels);
      end if;
      if Run.Category /= 0 then
         declare
            C : Category_Stats renames Categories (Run.Category);
         begin
            if Anim_Frame = 0 then
               C.Runs := C.Runs + 1;
            end if;
            C.Tolerance := Natural'Max (C.Tolerance, Run.Tolerance);
            C.Largest := Natural'Max (C.Largest, Largest);
            if Largest > 0 and then not Anim_Differed then
               C.Differing := C.Differing + 1;
               Anim_Differed := True;
            end if;
            C.Mean := Natural'Max (C.Mean, Mean);
         end;
      end if;
      Test_Support.Check
        (Mean <= Run.Mean_Limit,
         "the mean difference from the animation reference is too large, case", Run.Id);
      Test_Support.Check
        (Bad = 0, "a canvas differs from libwebp's WebPAnimDecoder's, case", Run.Id);

      --  Dispose of the frame: a caller fills the frame's rectangle with
      --  the frame config's background colour, which std/webp reports as
      --  transparent black (the ANIM chunk's colour is only a hint), as
      --  WebPAnimDecoder does.
      Test_Support.Check
        (PF.Background_Color (Last_FC) = 0,
         "an animation frame's background colour is not transparent black, case", Run.Id);
      IMS.Prev_Canvas (0 .. Size - 1) := IMS.Canvas (0 .. Size - 1);
      Prev_Dispose := PF.Disposal (Last_FC) = PF.Disposal_Restore_Background;
      if Prev_Dispose then
         for Y in Wuffs.Index (B.Min_Incl_Y) .. Wuffs.Index (B.Max_Excl_Y) - 1 loop
            IMS.Prev_Canvas
              ((Y * W + Wuffs.Index (B.Min_Incl_X)) * 4
               .. (Y * W + Wuffs.Index (B.Max_Excl_X)) * 4 - 1) := [others => 0];
         end loop;
      end if;
      Prev_Rect := B;
      Prev_Key := Key;
      Anim_Frame := Anim_Frame + 1;
   end Composite_And_Compare;

   ---------------------------------------------------------------------------
   --  The calls.
   ---------------------------------------------------------------------------

   subtype Decoder is Wuffs.Runtime.Image_Decoder'Class;

   procedure Put_Counts (D : Decoder);

   procedure Put_Counts (D : Decoder) is
      R : constant Wuffs.Base.Ranges.Rect_IE_U32 := D.Frame_Dirty_Rect;
   begin
      if Check_Dirty and then Image_Known then
         Test_Support.Check
           (R.Min_Incl_X <= R.Max_Excl_X and then R.Min_Incl_Y <= R.Max_Excl_Y
            and then R.Max_Excl_X <= Orig_W and then R.Max_Excl_Y <= Orig_H,
            "frame_dirty_rect is not within the image, case", Run.Id);
      end if;
      KV ("nfc", D.Num_Decoded_Frame_Configs);
      KV ("nf", D.Num_Decoded_Frames);
      KV ("loops", Wuffs.U64 (D.Num_Animation_Loops));
      KV ("dx0", Wuffs.U64 (R.Min_Incl_X));
      KV ("dy0", Wuffs.U64 (R.Min_Incl_Y));
      KV ("dx1", Wuffs.U64 (R.Max_Excl_X));
      KV ("dy1", Wuffs.U64 (R.Max_Excl_Y));
   end Put_Counts;

   --  The random numbers of a chaos run.
   function Rnd return Wuffs.U32;

   function Rnd return Wuffs.U32 is
   begin
      Seed := Seed * 1664525 + 1013904223;
      return Interfaces.Shift_Right (Seed, 8);
   end Rnd;

   procedure Tell_More (D : in out Decoder);

   procedure Tell_More (D : in out Decoder) is
      MI       : Wuffs.Runtime.More_Information;
      Out_Meta : IO.Buffer_Meta;
      St       : Wuffs.Status;
      H        : Wuffs.U64;
   begin
      for I in 1 .. 100_000 loop
         MI := (others => <>);
         Out_Meta := IO.Empty_Meta;
         St :=
           D.Tell_Me_More
             (A_Dst        =>
                IMS.Out_Data (IMS.Out_Data'First .. IMS.Out_Data'First + Chaos_Out_Len - 1),
              A_Dst_Meta   => Out_Meta,
              A_Minfo      => MI,
              A_Minfo_Null => False,
              A_Src        => IMS.Src (IMS.Src_First .. IMS.Src_First + Src_Len - 1),
              A_Src_Meta   => Src_Meta);
         Begin_Line ("T");
         Put_Status (St);
         KV ("ri", Position);
         KV ("wi", Wuffs.U64 (Out_Meta.Wi));
         KV ("fl", Wuffs.U64 (MI.Flavor));
         KV ("w", Wuffs.U64 (MI.W));
         KV ("x", MI.X);
         KV ("y", MI.Y);
         KV ("z", MI.Z);
         H := Fnv_Start;
         Fnv (H, IMS.Out_Data (IMS.Out_Data'First .. IMS.Out_Data'First + Out_Meta.Wi - 1));
         KV ("out", H);
         Ada.Text_IO.New_Line;
         if St.Category /= Wuffs.Suspension then
            exit;
         elsif MI.Flavor = 2 then
            Src_Seek (MI.X);
         elsif St = Wuffs.Base.Suspension_Short_Read then
            exit when not Src_Feed;
         end if;
         if Run.Chaos then
            --  Another destination, perhaps none at all, for the next call.
            Chaos_Out_Len :=
              (case Rnd mod 5 is when 0 => 0, when 1 => 1, when 2 => 7, when others => 4096);
            Test_Support.Check
              ((for all I in IMS.Out_Data'First + 4096 .. IMS.Out_Data'Last =>
                  IMS.Out_Data (I) = Canary),
               "tell_me_more wrote past its destination, case", Run.Id);
         end if;
      end loop;
   end Tell_More;

   ---------------------------------------------------------------------------
   --  Chaos.
   ---------------------------------------------------------------------------

   --  Changes the arguments of the next call: for decode_frame (In_Frame)
   --  any of them, for another function only the source meta.
   procedure Chaos_Step (In_Frame : Boolean);

   --  Calls decode_frame with the arguments as Chaos_Step left them, and
   --  checks the bytes around the arrays.
   procedure Chaos_Frame (D : in out Decoder; St : out Wuffs.Status);

   procedure Chaos_Step (In_Frame : Boolean) is
      Formats : constant array (Wuffs.U32 range 0 .. 9) of Wuffs.U32 :=
        [16#8100_8888#, 16#8200_8888#, 16#A000_0888#, 16#8000_0565#, 16#2000_0008#,
         16#8100_BBBB#, 16#8104_0008#, 16#8304_0008#, 16#9000_8888#, 16#A100_8888#];

      function Size (Original : Wuffs.U32) return Wuffs.U32
      is (case Rnd mod 4 is
            when 0 => Original,
            when 1 => Rnd mod (2 * Wuffs.U32'Min (Original, 2000) + 2),
            when 2 => Original / 2,
            when others => Wuffs.U32'Min (Original, 4000) + 1);

      Step : constant Wuffs.U32 := Rnd mod 16;
   begin
      if not In_Frame and then Step /= 10 then
         return;
      end if;
      Chaos_Steps := Chaos_Steps + 1;
      case Step is
         when 0 | 1 | 2 =>
            --  Another pixel buffer, somewhere else.
            declare
               Format : constant Wuffs.U32 := Formats (Rnd mod 10);
               W      : constant Wuffs.U32 := Size (Orig_W);
               H      : constant Wuffs.U32 := Size (Orig_H);
               Gap    : constant Wuffs.Index := Wuffs.Index (Rnd mod 4);
               Offset : constant Wuffs.Index := Wuffs.Index (Rnd mod 9);
               Shift  : constant Wuffs.Index := Guard + Wuffs.Index (Rnd mod 50);
               Cfg    : PF.Pixel_Config;
               Row    : Wuffs.Index;
               St     : Wuffs.Status;
               Length : Wuffs.Index;
            begin
               PF.Set (C => Cfg, Pixfmt_Repr => Format, Pixsub_Repr => 0, Width => W, Height => H);
               Row := Wuffs.Index (PB.Row_Bytes (Cfg));
               Length := Offset + Wuffs.Index (H) * (Row + Gap);
               if Length <= 4 * 1024 * 1024 then
                  --  Erase the old one and its surroundings.
                  IMS.Pix
                    (IMS.Pix_First .. Pix_Lo + Wuffs.Index'Max (Pix_Len, Chaos_Work_Len) + Guard) :=
                    [others => Canary];
                  Pix_Lo := IMS.Pix_First + Shift;
                  Pix_Len := Length;
                  IMS.Pix (IMS.Pix_First .. Pix_Lo + Pix_Len + Guard) := [others => Canary];
                  PB.Set_Interleaved
                    (PB             => Buf,
                     Pixcfg         => Cfg,
                     Primary        =>
                       (Offset => Offset,
                        Width  => Row,
                        Height => Wuffs.Index (H),
                        Stride => Row + Gap),
                     Pixels_Length  => Pix_Len,
                     Palette_Length => Pal_Len,
                     Result         => St);
                  if not Wuffs.Is_Ok (St) then
                     Buf := PB.Null_Pixel_Buffer;
                  end if;
                  --  Sometimes, a descriptor that does not fit the array.
                  if Rnd mod 8 = 0 then
                     Buf.Planes (0).Stride := Buf.Planes (0).Stride + 1;
                  elsif Rnd mod 8 = 0 and then Pix_Len > 0 then
                     Pix_Len := Pix_Len - 1;
                  end if;
               end if;
            end;
         when 3 | 4 | 5 =>
            --  Another work buffer: none, shorter, longer, elsewhere.
            declare
               N : constant Wuffs.Index := Chaos_Work_Len;
            begin
               Chaos_Work_Len :=
                 (case Rnd mod 6 is
                    when 0 => 0,
                    when 1 => (if N > 0 then N - 1 else 0),
                    when 2 => N / 2,
                    when 3 => N + 5,
                    when 4 => Wuffs.Index (Rnd mod 70_000),
                    when others => N);
               Chaos_Work_Len := Wuffs.Index'Min (Chaos_Work_Len, IMS.Cap_Work - 4 * Guard);
               Work_Lo := IMS.Work'First + Guard + Wuffs.Index (Rnd mod 30);
               IMS.Work (IMS.Work'First .. Work_Lo + Chaos_Work_Len + Guard) :=
                 [others => Canary];
               Work_In_Pixels := False;
            end;
         when 6 =>
            --  A work buffer that shares the pixels' last byte, or all.
            Work_In_Pixels := True;
         when 7 | 8 =>
            --  Another palette: too short, long enough, elsewhere.
            Pal_Len :=
              (case Rnd mod 5 is
                 when 0 => 0,
                 when 1 => 100,
                 when 2 => 1023,
                 when 3 => 1024,
                 when others => 3000);
            Pal_Lo := Guard + Wuffs.Index (Rnd mod 50);
            IMS.Chaos_Pal := [others => Canary];
         when 9 =>
            Run.Blend := PF.Pixel_Blend (Rnd mod 3);
         when 10 =>
            --  A meta that says more was written than the array holds.
            if Rnd mod 4 = 0 then
               Src_Meta :=
                 (Wi     => Src_Len + 1 + Wuffs.Index (Rnd mod 5),
                  Ri     => Src_Meta.Ri,
                  Pos    => Src_Meta.Pos,
                  Closed => Src_Meta.Closed);
            end if;
         when others =>
            null;
      end case;
   end Chaos_Step;

   procedure Chaos_Frame (D : in out Decoder; St : out Wuffs.Status) is
      Opts    : Wuffs.Runtime.Decode_Frame_Options;
      Src     : Wuffs.Bytes renames IMS.Src (IMS.Src_First .. IMS.Src_First + Src_Len - 1);
      Pix_Hi  : constant Wuffs.Offset := Pix_Lo + Pix_Len - 1;
      Pal_Hi  : constant Wuffs.Offset := Pal_Lo + Pal_Len - 1;
      Work_Hi : constant Wuffs.Offset := Work_Lo + Chaos_Work_Len - 1;
      Intact  : Boolean := True;
   begin
      if Work_In_Pixels then
         --  The work buffer is the pixels' last byte and what follows it (or
         --  nothing, if there are no pixels): the call must be rejected.
         St :=
           D.Decode_Frame
             (A_Dst         => Buf,
              A_Dst_Pixels  => IMS.Pix (Pix_Lo .. Pix_Hi),
              A_Dst_Palette => IMS.Chaos_Pal (Pal_Lo .. Pal_Hi),
              A_Src         => Src,
              A_Src_Meta    => Src_Meta,
              A_Blend       => Run.Blend,
              A_Workbuf     =>
                IMS.Pix
                  (Wuffs.Index'Max (Pix_Hi, Pix_Lo) .. Pix_Hi + (if Pix_Len = 0 then 0 else 8)),
              A_Opts        => Opts,
              A_Opts_Null   => True);
         Test_Support.Check
           (Pix_Len = 0 or else St = Wuffs.Base.Error_Bad_Argument
            or else St = Wuffs.Base.Error_Disabled_By_Previous_Error,
            "a work buffer that overlaps the pixels was accepted, case", Run.Id);
      else
         St :=
           D.Decode_Frame
             (A_Dst         => Buf,
              A_Dst_Pixels  => IMS.Pix (Pix_Lo .. Pix_Hi),
              A_Dst_Palette => IMS.Chaos_Pal (Pal_Lo .. Pal_Hi),
              A_Src         => Src,
              A_Src_Meta    => Src_Meta,
              A_Blend       => Run.Blend,
              A_Workbuf     => IMS.Work (Work_Lo .. Work_Hi),
              A_Opts        => Opts,
              A_Opts_Null   => True);
      end if;
      --  The bytes on either side of each array.  (Before the first
      --  Chaos_Step of a run the arrays are test_image's usual ones, with
      --  nothing known about their surroundings.)
      if Chaos_Steps > 0 and then Pix_Lo >= IMS.Pix_First + Guard then
         for I in Pix_Lo - Guard .. Pix_Lo - 1 loop
            Intact := Intact and then IMS.Pix (I) = Canary;
         end loop;
         if not Work_In_Pixels then
            for I in Pix_Hi + 1 .. Pix_Hi + Guard loop
               Intact := Intact and then IMS.Pix (I) = Canary;
            end loop;
         end if;
      end if;
      Test_Support.Check (Intact, "bytes next to the pixels were written, case", Run.Id);
      Intact := True;
      if Work_Lo >= IMS.Work'First + Guard and then not Work_In_Pixels then
         for I in Work_Lo - Guard .. Work_Lo - 1 loop
            Intact := Intact and then IMS.Work (I) = Canary;
         end loop;
         for I in Work_Hi + 1 .. Work_Hi + Guard loop
            Intact := Intact and then IMS.Work (I) = Canary;
         end loop;
      end if;
      Test_Support.Check (Intact, "bytes next to the work buffer were written, case", Run.Id);
      Intact := True;
      if Pal_Lo >= Guard then
         for I in Pal_Lo - Guard .. Pal_Lo - 1 loop
            Intact := Intact and then IMS.Chaos_Pal (I) = Canary;
         end loop;
         for I in Pal_Hi + 1 .. Pal_Hi + Guard loop
            Intact := Intact and then IMS.Chaos_Pal (I) = Canary;
         end loop;
      end if;
      Test_Support.Check (Intact, "bytes next to the palette were written, case", Run.Id);
   end Chaos_Frame;

   procedure Run_Op (D : in out Decoder; Op : Character; St : out Wuffs.Status);

   procedure Run_Op (D : in out Decoder; Op : Character; St : out Wuffs.Status) is
      IC       : PF.Image_Config := PF.Null_Image_Config;
      FC       : PF.Frame_Config;
      Opts     : Wuffs.Runtime.Decode_Frame_Options;
      Calls    : Wuffs.U64 := 0;
      H        : Wuffs.U64 := Fnv_Start;
      Limit    : constant Wuffs.U64 := 4 * Wuffs.U64 (Len) + 1000;
      Work_Len : Wuffs.Index := 0;
      WL       : Wuffs.Base.Ranges.Range_II_U64;
      N        : Wuffs.U64;
      Dirty    : Wuffs.Base.Ranges.Rect_IE_U32;
   begin
      St := Wuffs.Ok_Status;
      if Op = 'F' then
         if not Have_PB then
            Setup_PB (16, 16);
         end if;
         WL := D.Workbuf_Len;
         N := WL.Max_Incl;
         if Run.Small_Work then
            N := (if WL.Min_Incl /= 0 then WL.Min_Incl - 1 else 0);
         end if;
         if not Have_PB or else N > IMS.Cap_Work then
            Begin_Line ("F toobig");
            Ada.Text_IO.New_Line;
            St := Wuffs.Base.Error_Bad_Argument;
            return;
         end if;
         Work_Len := Wuffs.Index (N);
      end if;

      loop
         declare
            Src : Wuffs.Bytes renames IMS.Src (IMS.Src_First .. IMS.Src_First + Src_Len - 1);
         begin
            case Op is
               when 'I' | 'i' =>
                  St :=
                    D.Decode_Image_Config
                      (A_Dst => IC, A_Dst_Null => Op = 'i', A_Src => Src, A_Src_Meta => Src_Meta);
               when 'C' | 'c' =>
                  St :=
                    D.Decode_Frame_Config
                      (A_Dst => FC, A_Dst_Null => Op = 'c', A_Src => Src, A_Src_Meta => Src_Meta);
               when others =>
                  if not Run.Chaos then
                     St :=
                       D.Decode_Frame
                         (A_Dst         => Buf,
                          A_Dst_Pixels  => IMS.Pix (IMS.Pix_First .. IMS.Pix_First + Pix_Len - 1),
                          A_Dst_Palette => IMS.Pal,
                          A_Src         => Src,
                          A_Src_Meta    => Src_Meta,
                          A_Blend       => Run.Blend,
                          A_Workbuf     =>
                            IMS.Work (IMS.Work'First .. IMS.Work'First + Work_Len - 1),
                          A_Opts        => Opts,
                          A_Opts_Null   => True);
                  else
                     if not Chaos_Work_Set then
                        Chaos_Work_Len := Work_Len;
                        Chaos_Work_Set := True;
                     end if;
                     Chaos_Frame (D, St);
                  end if;
            end case;
         end;
         Calls := Calls + 1;
         Fnv_U64
           (H,
            (if St.Category = Wuffs.Ok then 0 elsif St.Category = Wuffs.Suspension then 1 else 2));
         Fnv_U64 (H, Position);
         --  Also what a caller can see of a frame while it is suspended.
         Dirty := D.Frame_Dirty_Rect;
         Fnv_U64 (H, Wuffs.U64 (Dirty.Min_Incl_X));
         Fnv_U64 (H, Wuffs.U64 (Dirty.Min_Incl_Y));
         Fnv_U64 (H, Wuffs.U64 (Dirty.Max_Excl_X));
         Fnv_U64 (H, Wuffs.U64 (Dirty.Max_Excl_Y));
         if Calls >= Limit then
            exit;
         elsif St = Wuffs.Base.Suspension_Short_Read then
            exit when not Src_Feed;
            if Run.Chaos then
               Chaos_Step (In_Frame => Op = 'F');
            end if;
         elsif Run.Meta and then St = Wuffs.Base.Note_Metadata_Reported then
            Tell_More (D);
         else
            exit;
         end if;
      end loop;

      Begin_Line ([1 => Op]);
      Put_Status (St);
      KV ("n", Calls);
      KV ("h", H);
      KV ("ri", Position);
      if Op = 'I' and then Wuffs.Is_Ok (St) then
         KV ("fmt", Wuffs.U64 (IC.Pixcfg.Pixfmt.Repr));
         KV ("sub", Wuffs.U64 (IC.Pixcfg.Pixsub.Repr));
         KV ("w", Wuffs.U64 (IC.Pixcfg.Width));
         KV ("h", Wuffs.U64 (IC.Pixcfg.Height));
         KV ("ffio", PF.First_Frame_IO_Position (IC));
         KV ("opq", Boolean'Pos (PF.First_Frame_Is_Opaque (IC)));
         WL := D.Workbuf_Len;
         KV ("wlmin", WL.Min_Incl);
         KV ("wlmax", WL.Max_Incl);
      elsif Op = 'C' and then Wuffs.Is_Ok (St) then
         Last_FC := FC;
         Last_Index := PF.Get_Index (FC);
         Last_IO := PF.IO_Position (FC);
         KV ("x0", Wuffs.U64 (FC.Bounds.Min_Incl_X));
         KV ("y0", Wuffs.U64 (FC.Bounds.Min_Incl_Y));
         KV ("x1", Wuffs.U64 (FC.Bounds.Max_Excl_X));
         KV ("y1", Wuffs.U64 (FC.Bounds.Max_Excl_Y));
         KV ("dur", PF.Get_Duration (FC));
         KV ("idx", PF.Get_Index (FC));
         KV ("io", PF.IO_Position (FC));
         KV ("disp", Wuffs.U64 (PF.Disposal (FC)));
         KV ("opq", Boolean'Pos (PF.Opaque_Within_Bounds (FC)));
         KV ("ovr", Boolean'Pos (PF.Overwrite_Instead_Of_Blend (FC)));
         KV ("bg", Wuffs.U64 (PF.Background_Color (FC)));
      elsif Op = 'F' then
         Put_Pixels;
      end if;
      Put_Counts (D);
      Ada.Text_IO.New_Line;

      if Op = 'I' and then Wuffs.Is_Ok (St) then
         Ffio := PF.First_Frame_IO_Position (IC);
         Orig_W := IC.Pixcfg.Width;
         Orig_H := IC.Pixcfg.Height;
         Image_Known := True;
         if not Have_PB then
            Setup_PB (IC.Pixcfg.Width, IC.Pixcfg.Height);
         end if;
      end if;
      if Op = 'F' and then Wuffs.Is_Ok (St) and then Run.Has_Expect and then Run.Anim
        and then not Run.Chaos
      then
         Compared := True;
         Composite_And_Compare;
      elsif Op = 'F' and then Wuffs.Is_Ok (St) and then Run.Has_Expect and then not Compared
        and then not Run.Chaos
      then
         Compared := True;
         Compare_With_Expected;
      end if;
   end Run_Op;

   procedure Run_Script (D : in out Decoder; Script : String);

   procedure Run_Script (D : in out Decoder; Script : String) is
      St : Wuffs.Status;
   begin
      for Op of Script loop
         case Op is
            when '*' =>
               for I in 1 .. Max_Frames loop
                  Run_Op (D, 'C', St);
                  exit when not Wuffs.Is_Ok (St);
                  Run_Op (D, 'F', St);
                  exit when not Wuffs.Is_Ok (St);
               end loop;
            when 'R' | 'r' =>
               if Op = 'R' then
                  St := D.Restart_Frame (A_Index => 0, A_Io_Position => Ffio);
               else
                  St := D.Restart_Frame (A_Index => 1, A_Io_Position => 0);
               end if;
               Begin_Line ([1 => Op]);
               Put_Status (St);
               Put_Counts (D);
               Ada.Text_IO.New_Line;
               if Op = 'R' and then Wuffs.Is_Ok (St) then
                  Src_Seek (Ffio);
               end if;
            when 'L' | 'B' =>
               declare
                  Index : constant Wuffs.U64 := (if Op = 'L' then Last_Index else 2);
                  IO    : constant Wuffs.U64 := (if Op = 'L' then Last_IO else Ffio + 7);
               begin
                  St := D.Restart_Frame (A_Index => Index, A_Io_Position => IO);
                  Begin_Line ([1 => Op]);
                  Put_Status (St);
                  Put_Counts (D);
                  Ada.Text_IO.New_Line;
                  if Wuffs.Is_Ok (St) then
                     Src_Seek (IO);
                  end if;
               end;
            when 'T' =>
               Tell_More (D);
            when others =>
               Run_Op (D, Op, St);
         end case;
      end loop;
   end Run_Script;

   procedure Run_Decoder (D : in out Decoder; Script : String);

   procedure Run_Decoder (D : in out Decoder; Script : String) is
      St : Wuffs.Status;
   begin
      Have_PB := False;
      Ffio := 0;
      Last_Index := 0;
      Last_IO := 0;
      Compared := False;
      Anim_Frame := 0;
      Prev_Key := False;
      Prev_Dispose := False;
      Anim_Differed := False;
      Orig_W := 16;
      Orig_H := 16;
      Image_Known := False;
      Pix_Lo := IMS.Pix_First;
      Pal_Lo := 0;
      Pal_Len := 1024;
      Work_Lo := IMS.Work'First;
      Chaos_Work_Set := False;
      Work_In_Pixels := False;
      Chaos_Out_Len := 4096;
      if Run.Chaos then
         IMS.Out_Data (IMS.Out_Data'First + 4096 .. IMS.Out_Data'Last) := [others => Canary];
         IMS.Chaos_Pal := [others => Canary];
      end if;
      for I in 1 .. Run.Num_Quirks loop
         St := D.Set_Quirk (A_Key => Run.Quirks (I), A_Value => Run.Values (I));
         Begin_Line ("q");
         Put_Status (St);
         KV ("key", Wuffs.U64 (Run.Quirks (I)));
         KV ("get", D.Get_Quirk (Run.Quirks (I)));
         Ada.Text_IO.New_Line;
      end loop;
      if Run.Meta then
         for F of Fourccs loop
            D.Set_Report_Metadata (A_Fourcc => F, A_Report => True);
         end loop;
      end if;
      Src_Begin;
      Run_Script (D, Script);
      Begin_Line ("end");
      Put_Counts (D);
      Ada.Text_IO.New_Line;
      if Run.Has_Expect and then not Compared then
         Test_Support.Check (False, "no frame to compare with the reference, case", Run.Id);
      end if;
   end Run_Decoder;

   --  The fields of a manifest line.
   procedure Do_Case (Line : String);

   procedure Do_Case (Line : String) is
      Pos : Natural := Line'First;

      procedure Field (First : out Natural; Last : out Natural);

      procedure Field (First : out Natural; Last : out Natural) is
      begin
         while Pos <= Line'Last and then Line (Pos) = ' ' loop
            Pos := Pos + 1;
         end loop;
         First := Pos;
         while Pos <= Line'Last and then Line (Pos) /= ' ' loop
            Pos := Pos + 1;
         end loop;
         Last := Pos - 1;
      end Field;

      function Number (S : String; Base : Wuffs.U64) return Wuffs.U64;

      function Number (S : String; Base : Wuffs.U64) return Wuffs.U64 is
         V : Wuffs.U64 := 0;
      begin
         for C of S loop
            V :=
              V * Base
              + (case C is
                   when '0' .. '9' => Character'Pos (C) - Character'Pos ('0'),
                   when 'a' .. 'f' => Character'Pos (C) - Character'Pos ('a') + 10,
                   when 'A' .. 'F' => Character'Pos (C) - Character'Pos ('A') + 10,
                   when others => 0);
         end loop;
         return V;
      end Number;

      F1, L1, F2, L2, F3, L3, F4, L4, F5, L5, F6, L6, F7, L7, F8, L8 : Natural;
      OK                                                             : Boolean;
      I, J                                                           : Natural;
   begin
      Field (F1, L1);
      Field (F2, L2);
      Field (F3, L3);
      Field (F4, L4);
      Field (F5, L5);
      Field (F6, L6);
      Field (F7, L7);
      Field (F8, L8);
      if L8 < F8 then
         Test_Support.Check (False, "bad manifest line");
         return;
      end if;
      Cases := Cases + 1;
      Run := (others => <>);
      Run.Id := Cases;
      Run.Pixfmt := Wuffs.U32 (Number (Line (F2 .. L2), 16));
      Run.Blend := PF.Pixel_Blend (Number (Line (F3 .. L3), 10));
      Run.Sched := Line (F4);
      Run.Chunk := Wuffs.Index (Number (Line (F4 + 1 .. L4), 10));
      I := F5;
      while I <= L5 loop
         J := I;
         while J <= L5 and then Line (J) /= ',' loop
            J := J + 1;
         end loop;
         case Line (I) is
            when 'm' => Run.Meta := True;
            when 'A' => Run.Anim := True;
            when 'p' => Run.Small_Pix := True;
            when 'w' => Run.Small_Work := True;
            when 'l' => Run.Layout := True;
            when 'x' =>
               Run.Chaos := True;
               Seed := Wuffs.U32 (Number (Line (I + 1 .. J - 1), 10));
            when 't' =>
               Run.Tolerance := Natural (Number (Line (I + 1 .. J - 1), 10));
            when 'a' =>
               Run.Mean_Limit := Natural (Number (Line (I + 1 .. J - 1), 10));
            when 'k' =>
               --  The category: an existing one, or a new one.
               declare
                  Name : String renames Line (I + 1 .. J - 1);
               begin
                  for K in 1 .. Num_Categories loop
                     if Categories (K).Name (1 .. Categories (K).Name_Last) = Name then
                        Run.Category := K;
                     end if;
                  end loop;
                  if Run.Category = 0 and then Num_Categories < Max_Categories
                    and then Name'Length <= 40
                  then
                     Num_Categories := Num_Categories + 1;
                     Categories (Num_Categories).Name (1 .. Name'Length) := Name;
                     Categories (Num_Categories).Name_Last := Name'Length;
                     Run.Category := Num_Categories;
                  end if;
                  --  A category that does not fit would have its statistics
                  --  silently dropped: a test failure instead.
                  Test_Support.Check
                    (Run.Category /= 0,
                     "too many tolerance categories (or a name over 40 characters), case",
                     Run.Id, Name);
               end;
            when 'v' =>
               --  vK:V sets quirk K to V (both decimal).
               declare
                  Colon : Natural := I + 1;
               begin
                  while Colon < J and then Line (Colon) /= ':' loop
                     Colon := Colon + 1;
                  end loop;
                  if Run.Num_Quirks < Max_Quirks and then Colon < J then
                     Run.Num_Quirks := Run.Num_Quirks + 1;
                     Run.Quirks (Run.Num_Quirks) :=
                       Wuffs.U32 (Number (Line (I + 1 .. Colon - 1), 10));
                     Run.Values (Run.Num_Quirks) := Number (Line (Colon + 1 .. J - 1), 10);
                  end if;
               end;
            when 'q' | 'Q' =>
               if Run.Num_Quirks < Max_Quirks then
                  Run.Num_Quirks := Run.Num_Quirks + 1;
                  Run.Quirks (Run.Num_Quirks) := Wuffs.U32 (Number (Line (I + 1 .. J - 1), 10));
                  if Line (I) = 'Q' then
                     Run.Values (Run.Num_Quirks) := 16#8000_0000_0000_0000#;
                  end if;
               end if;
            when others => null;
         end case;
         I := J + 1;
      end loop;

      Load (Line (F8 .. L8), IMS.File, Len, OK);
      if not OK then
         Test_Support.Check (False, "cannot read ", -1, Line (F8 .. L8));
         return;
      end if;
      if Line (F7 .. L7) /= "-" then
         Load (Line (F7 .. L7), IMS.Expected, Run.Exp_Length, OK);
         if not OK then
            Test_Support.Check (False, "cannot read ", -1, Line (F7 .. L7));
            return;
         end if;
         Run.Has_Expect := True;
      end if;

      Check_Dirty := False;
      if Line (F1 .. L1) = "netpbm" then
         Wuffs.Std.Netpbm.Initialize (IMS.Netpbm_Decoder);
         Run_Decoder (IMS.Netpbm_Decoder, Line (F6 .. L6));
      elsif Line (F1 .. L1) = "bmp" then
         Wuffs.Std.Bmp.Initialize (IMS.Bmp_Decoder);
         Run_Decoder (IMS.Bmp_Decoder, Line (F6 .. L6));
      elsif Line (F1 .. L1) = "gif" then
         Wuffs.Std.Gif.Initialize (IMS.Gif_Decoder);
         Run_Decoder (IMS.Gif_Decoder, Line (F6 .. L6));
      elsif Line (F1 .. L1) = "png" then
         Wuffs.Std.Png.Initialize (IMS.Png_Decoder);
         Run_Decoder (IMS.Png_Decoder, Line (F6 .. L6));
      elsif Line (F1 .. L1) = "wbmp" then
         Wuffs.Std.Wbmp.Initialize (IMS.Wbmp_Decoder);
         Run_Decoder (IMS.Wbmp_Decoder, Line (F6 .. L6));
      elsif Line (F1 .. L1) = "nie" then
         Wuffs.Std.Nie.Initialize (IMS.Nie_Decoder);
         Run_Decoder (IMS.Nie_Decoder, Line (F6 .. L6));
      elsif Line (F1 .. L1) = "targa" then
         Wuffs.Std.Targa.Initialize (IMS.Targa_Decoder);
         Run_Decoder (IMS.Targa_Decoder, Line (F6 .. L6));
      elsif Line (F1 .. L1) = "qoi" then
         Wuffs.Std.Qoi.Initialize (IMS.Qoi_Decoder);
         Run_Decoder (IMS.Qoi_Decoder, Line (F6 .. L6));
      elsif Line (F1 .. L1) = "etc2" then
         Wuffs.Std.Etc2.Initialize (IMS.Etc2_Decoder);
         Run_Decoder (IMS.Etc2_Decoder, Line (F6 .. L6));
      elsif Line (F1 .. L1) = "thumbhash" then
         Wuffs.Std.Thumbhash.Initialize (IMS.Thumbhash_Decoder);
         Run_Decoder (IMS.Thumbhash_Decoder, Line (F6 .. L6));
      elsif Line (F1 .. L1) = "handsum" then
         Wuffs.Std.Handsum.Initialize (IMS.Handsum_Decoder);
         Run_Decoder (IMS.Handsum_Decoder, Line (F6 .. L6));
      elsif Line (F1 .. L1) = "jpeg" then
         Wuffs.Std.Jpeg.Initialize (IMS.Jpeg_Decoder);
         Run_Decoder (IMS.Jpeg_Decoder, Line (F6 .. L6));
      elsif Line (F1 .. L1) = "vp8" then
         Check_Dirty := True;
         Wuffs.Std.Vp8.Initialize (IMS.Vp8_Decoder);
         Run_Decoder (IMS.Vp8_Decoder, Line (F6 .. L6));
      elsif Line (F1 .. L1) = "webp" then
         Check_Dirty := True;
         Wuffs.Std.Webp.Initialize (IMS.Webp_Decoder);
         Run_Decoder (IMS.Webp_Decoder, Line (F6 .. L6));
      else
         Test_Support.Check (False, "unknown format ", -1, Line (F1 .. L1));
      end if;
   end Do_Case;

   Line : String (1 .. 4096);
   Last : Natural;

begin
   while not Ada.Text_IO.End_Of_File loop
      Ada.Text_IO.Get_Line (Line, Last);
      if Last > 0 then
         Do_Case (Line (1 .. Last));
      end if;
   end loop;
   for C of Categories (1 .. Num_Categories) loop
      Ada.Text_IO.Put ("test_image: compared with the reference with a tolerance: ");
      Ada.Text_IO.Put (C.Name (1 .. C.Name_Last));
      Ada.Text_IO.Put (": runs");
      Ada.Text_IO.Put (C.Runs'Image);
      Ada.Text_IO.Put (", with a difference");
      Ada.Text_IO.Put (C.Differing'Image);
      Ada.Text_IO.Put (", largest channel difference");
      Ada.Text_IO.Put (C.Largest'Image);
      Ada.Text_IO.Put (", largest mean difference (hundredths)");
      Ada.Text_IO.Put (C.Mean'Image);
      Ada.Text_IO.Put (" (tolerance");
      Ada.Text_IO.Put (C.Tolerance'Image);
      Ada.Text_IO.Put_Line (")");
   end loop;
   Ada.Text_IO.Put ("test_image: cases:");
   Ada.Text_IO.Put (Cases'Image);
   Ada.Text_IO.Put (", compared with the reference decoder:");
   Ada.Text_IO.Put_Line (References'Image);
   Test_Support.Finish ("test_image");
end Test_Image;
