--  Explicit cases for Wuffs.Base.Color_YCC and Pixel_Swizzler_YCCK, with
--  expected values worked out by hand from the definitions (not from the
--  code under test and not from the oracle).

with Interfaces;
with Wuffs.Base.Color_YCC;
with Wuffs.Base.Pixel_Buffers.Rows;
with Wuffs.Base.Pixel_Swizzler_YCCK;
with Wuffs;
with YCCK_Test_Support;

procedure Test_YCCK_Cases is

   use Interfaces;
   use Wuffs;
   use Wuffs.Base.Color_YCC;
   use Wuffs.Base.Pixel_Swizzler_YCCK;
   use YCCK_Test_Support;

   package PBs renames Wuffs.Base.Pixel_Buffers;

   BGRA_Nonpremul : constant := 16#8100_8888#;
   BGRA_Premul    : constant := 16#8200_8888#;

   Scratch : Bytes (0 .. 2047) := [others => 0];
   Empty   : constant Bytes (1 .. 0) := [];

   --  A W by H buffer of a four byte format (BGRA_NONPREMUL unless given)
   --  over an array of W * H * 4 bytes.
   function Buffer
     (W, H : U32; Format : U32 := BGRA_Nonpremul) return PBs.Pixel_Buffer
   is
     (Pixcfg => (Pixfmt => (Repr => Format), Pixsub => (Repr => 0),
                 Width => W, Height => H),
      Planes => [0      => (Offset => 0, Width => Index (W) * 4,
                            Height => Index (H), Stride => Index (W) * 4),
                 others => PBs.Empty_Table]);

   Full : constant Source_Plane := (Width => 4, Height => 1, Stride => 4, H => 2, V => 1);

   Result : Status;
   Grey   : Boolean;
begin
   --  Neutral chroma: grey in, the same grey out (full range).
   Grey := True;
   for Y in U8 loop
      Grey := Grey
        and then YCC_BT601FR_As_Color_U32 (Y, 128, 128)
                 = 16#FF00_0000# + 16#01_0101# * U32 (Y)
        and then YCC_BT601FR_As_Color_U32_ABGR (Y, 128, 128)
                 = 16#FF00_0000# + 16#01_0101# * U32 (Y);
   end loop;
   Check (Grey, "full range grey (all 256 levels, both channel orders)");
   --  Studio range: 16 is black, 235 is white, beyond them it saturates.
   Check (YCC_BT601SR_As_Color_U32 (16, 128, 128) = 16#FF00_0000#, "studio black");
   Check (YCC_BT601SR_As_Color_U32 (0, 128, 128) = 16#FF00_0000#, "studio below black");
   Check (YCC_BT601SR_As_Color_U32 (235, 128, 128) = 16#FFFF_FFFF#, "studio white");
   Check (YCC_BT601SR_As_Color_U32 (255, 128, 128) = 16#FFFF_FFFF#, "studio above white");
   --  Saturated red and blue (JPEG: R = Y + 1.402 (Cr - 128), B = Y + 1.772
   --  (Cb - 128)), and the channel order of the ABGR form.
   Check (YCC_BT601FR_As_Color_U32 (128, 128, 255) = 16#FFFF_2580#, "full range red");
   Check (YCC_BT601FR_As_Color_U32_ABGR (128, 128, 255) = 16#FF80_25FF#,
          "full range red, ABGR");
   Check (YCC_BT601FR_As_Color_U32 (128, 255, 128) = 16#FF80_54FF#, "full range blue");
   Check (YCC_BT601FR_As_Color_U32 (0, 128, 0) = 16#FF00_5B00#, "full range clamp low");

   --  Horizontal triangle filter (h2v1), observed through the RGB model:
   --  the red plane has 2 samples (0, 100) for 4 pixels; green and blue are
   --  at full resolution.  Fancy upsampling gives 0, (3*0+100+2)/4 = 25,
   --  (3*100+0+1)/4 = 75, 100; basic gives 0, 0, 100, 100.
   declare
      R      : constant Bytes (0 .. 1) := [0, 100];
      G      : constant Bytes (0 .. 3) := [1, 2, 3, 4];
      B      : constant Bytes (0 .. 3) := [5, 6, 7, 8];
      Pixels : Bytes (0 .. 15) := [others => 16#EE#];
      Planes : constant Source_Planes :=
        [0 => (Width => 2, Height => 1, Stride => 2, H => 1, V => 1),
         1 => Full, 2 => Full, 3 => <>];
   begin
      Swizzle_YCCK (Buffer (4, 1), Pixels, Empty, Empty, 0, 4, 0, 1, R, G, B, Empty,
                    Planes, YCC_Model_RGB, YCC_Upsampling_Fancy_Like_Libjpeg, Scratch,
                    Result);
      Check (Is_Ok (Result), "h2v1 fancy: status");
      Check (Pixels = [5, 1, 0, 255, 6, 2, 25, 255, 7, 3, 75, 255, 8, 4, 100, 255],
             "h2v1 fancy: pixels");
      Swizzle_YCCK (Buffer (4, 1), Pixels, Empty, Empty, 0, 4, 0, 1, R, G, B, Empty,
                    Planes, YCC_Model_RGB, YCC_Upsampling_Basic, Scratch, Result);
      Check (Is_Ok (Result), "h2v1 basic: status");
      Check (Pixels = [5, 1, 0, 255, 6, 2, 0, 255, 7, 3, 100, 255, 8, 4, 100, 255],
             "h2v1 basic: pixels");

      --  A scratch buffer one byte short: bad argument, nothing written.
      Pixels := [others => 16#EE#];
      Swizzle_YCCK (Buffer (4, 1), Pixels, Empty, Empty, 0, 4, 0, 1, R, G, B, Empty,
                    Planes, YCC_Model_RGB, YCC_Upsampling_Basic, Scratch (0 .. 2046),
                    Result);
      Check (Result = Wuffs.Base.Error_Bad_Argument, "short scratch: status");
      Check (Pixels = [0 .. 15 => 16#EE#], "short scratch: pixels untouched");

      --  A pixel buffer that does not fit its array: bad argument.
      Swizzle_YCCK (Buffer (4, 1), Pixels (0 .. 14), Empty, Empty, 0, 4, 0, 1, R, G, B,
                    Empty, Planes, YCC_Model_RGB, YCC_Upsampling_Basic, Scratch, Result);
      Check (Result = Wuffs.Base.Error_Bad_Argument, "invalid pixel buffer: status");
      Check (Pixels = [0 .. 15 => 16#EE#], "invalid pixel buffer: pixels untouched");

      --  A source plane one byte short: bad argument.
      Swizzle_YCCK (Buffer (4, 1), Pixels, Empty, Empty, 0, 4, 0, 1, R, G (0 .. 2), B,
                    Empty, Planes, YCC_Model_RGB, YCC_Upsampling_Basic, Scratch, Result);
      Check (Result = Wuffs.Base.Error_Bad_Argument, "short plane: status");
      Check (Pixels = [0 .. 15 => 16#EE#], "short plane: pixels untouched");
   end;

   --  Vertical triangle filter (h1v2): the red plane has rows 0 and 100
   --  for 4 pixel rows.  Rows: (3*0+0+1)/4 = 0, (3*0+100+2)/4 = 25,
   --  (3*100+0+1)/4 = 75, and the last row, an edge, (3*100+100+2)/4 = 100.
   declare
      R      : constant Bytes (0 .. 1) := [0, 100];
      G      : constant Bytes (0 .. 3) := [1, 2, 3, 4];
      B      : constant Bytes (0 .. 3) := [5, 6, 7, 8];
      Pixels : Bytes (0 .. 15) := [others => 16#EE#];
      Tall   : constant Source_Plane :=
        (Width => 1, Height => 4, Stride => 1, H => 1, V => 2);
      Planes : constant Source_Planes :=
        [0 => (Width => 1, Height => 2, Stride => 1, H => 1, V => 1),
         1 => Tall, 2 => Tall, 3 => <>];
   begin
      Swizzle_YCCK (Buffer (1, 4), Pixels, Empty, Empty, 0, 1, 0, 4, R, G, B, Empty,
                    Planes, YCC_Model_RGB, YCC_Upsampling_Fancy_Like_Libwebp, Scratch,
                    Result);
      Check (Is_Ok (Result), "h1v2 fancy: status");
      Check (Pixels = [5, 1, 0, 255, 6, 2, 25, 255, 7, 3, 75, 255, 8, 4, 100, 255],
             "h1v2 fancy: pixels");
   end;

   --  CMYK (model CMY, four planes): each of the three channels is scaled
   --  by K / 255, rounded: (200 * 128 + 127) / 255 = 100, and K = 255
   --  leaves a channel as it is, K = 0 gives black.
   declare
      C      : constant Bytes (0 .. 2) := [200, 200, 200];
      M      : constant Bytes (0 .. 2) := [100, 100, 100];
      Y      : constant Bytes (0 .. 2) := [50, 50, 50];
      K      : constant Bytes (0 .. 2) := [128, 255, 0];
      Pixels : Bytes (0 .. 11) := [others => 16#EE#];
      One    : constant Source_Plane :=
        (Width => 3, Height => 1, Stride => 3, H => 1, V => 1);
   begin
      Swizzle_YCCK (Buffer (3, 1), Pixels, Empty, Empty, 0, 3, 0, 1, C, M, Y, K,
                    [others => One], YCC_Model_CMY, YCC_Upsampling_Basic, Scratch,
                    Result);
      Check (Is_Ok (Result), "cmyk: status");
      Check (Pixels = [25, 50, 100, 255, 50, 100, 200, 255, 0, 0, 0, 255],
             "cmyk: pixels");
      --  Three planes' worth of model with four planes: not supported.
      Pixels := [others => 16#EE#];
      Swizzle_YCCK (Buffer (3, 1), Pixels, Empty, Empty, 0, 3, 0, 1, C, M, Y, K,
                    [others => One], YCC_Model_RGB, YCC_Upsampling_Basic, Scratch,
                    Result);
      Check (Result = Wuffs.Base.Error_Unsupported_Pixel_Swizzler_Option,
             "four planes, RGB model: status");
      Check (Pixels = [0 .. 11 => 16#EE#], "four planes, RGB model: pixels untouched");
   end;

   --  The positional composite setter for BGRA_PREMUL, which Swizzle_YCCK
   --  does not reach (it has its own loop for that format).  A transparent
   --  colour leaves the pixel alone, an opaque one replaces it, and half
   --  transparent white (alpha 0x80) over opaque black gives 0x80 in every
   --  channel and full alpha (0xFF * 0x80 / 0xFF = 0x80; 0x80 + 0xFF * 0x7F / 0xFF = 0xFF).
   declare
      package Rows renames Wuffs.Base.Pixel_Buffers.Rows;
      PB     : constant PBs.Pixel_Buffer := Buffer (2, 1, BGRA_Premul);
      Pixels : Bytes (40 .. 47) := [10, 20, 30, 255, 0, 0, 0, 255];
   begin
      Rows.Composite_Color_U32_Nonpremul_At_Position
        (PB, Pixels, Empty, 40, 16#0011_2233#);
      Check (Pixels = [10, 20, 30, 255, 0, 0, 0, 255], "composite at: transparent");
      Rows.Composite_Color_U32_Nonpremul_At_Position
        (PB, Pixels, Empty, 40, 16#FF11_2233#);
      Check (Pixels = [16#33#, 16#22#, 16#11#, 255, 0, 0, 0, 255],
             "composite at: opaque");
      Rows.Composite_Color_U32_Nonpremul_At_Position
        (PB, Pixels, Empty, 44, 16#80FF_FFFF#);
      Check (Pixels = [16#33#, 16#22#, 16#11#, 255, 16#80#, 16#80#, 16#80#, 255],
             "composite at: half transparent white over black");
   end;
end Test_YCCK_Cases;
