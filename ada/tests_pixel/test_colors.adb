--  Wuffs.Base.Colors.  The sweeps mirror sweep_colors in oracle/oracle.c.

with Interfaces;
with Pixel_Oracle_Data;
with Pixel_Test_Support; use Pixel_Test_Support;
with Wuffs.Base.Colors;

procedure Test_Colors is

   use Wuffs;
   use Wuffs.Base.Colors;
   use type Interfaces.Unsigned_8;
   use type Interfaces.Unsigned_16;
   use type Interfaces.Unsigned_32;
   use type Interfaces.Unsigned_64;

   C8  : constant array (0 .. 6) of U32 := [0, 1, 2, 127, 128, 254, 255];
   C16 : constant array (0 .. 7) of U64 :=
     [0, 1, 16#FF#, 16#100#, 16#7FFF#, 16#8000#, 16#FFFE#, 16#FFFF#];

   procedure Mix_U32_Color (C : U32);
   procedure Mix_U64_Color (C : U64);

   procedure Mix_U32_Color (C : U32) is
   begin
      Mix (Premul_Is_Valid (C));
      Mix (U64 (Premul_U32_As_RGB_565 (C)));
      Mix (U64 (Premul_U32_As_Gray_U8 (C)));
      Mix (U64 (Premul_U32_As_Gray_U16 (C)));
      Mix (U64 (Premul_U32_As_Alpha_Gray_Nonpremul_U16 (C)));
      Mix (U64 (Nonpremul_U32_As_Premul_U32 (C)));
      Mix (U64 (Premul_U32_As_Nonpremul_U32 (C)));
      Mix (Premul_U32_As_Nonpremul_U64 (C));
      Mix (U32_As_U64 (C));
      Mix (U64 (Swap_U32_ARGB_ABGR (C)));
   end Mix_U32_Color;

   procedure Mix_U64_Color (C : U64) is
   begin
      Mix (U64 (Nonpremul_U64_As_Premul_U32 (C)));
      Mix (U64 (Premul_U64_As_Gray_U8 (C)));
      Mix (Premul_U64_As_Nonpremul_U64 (C));
      Mix (Nonpremul_U64_As_Premul_U64 (C));
      Mix (U64 (Nonpremul_U64_As_Gray_U8 (C)));
      Mix (U64 (U64_As_U32 (C)));
      Mix (Swap_U64_ARGB_ABGR (C));
   end Mix_U64_Color;

begin
   Start (101);
   for V in U32 range 0 .. 16#FFFF# loop
      Mix (U64 (RGB_565_As_Premul_U32 (U16 (V))));
   end loop;
   Finish ("colors: sweep Colors_565 (exhaustive)", Pixel_Oracle_Data.Colors_565);

   Start (102);
   for A in U32 range 0 .. 255 loop
      for Y in U32 range 0 .. 255 loop
         Mix_U32_Color (Interfaces.Shift_Left (A, 24) or (Y * 16#01_0101#));
      end loop;
   end loop;
   Finish ("colors: sweep Colors_Gray (exhaustive)", Pixel_Oracle_Data.Colors_Gray);

   Start (103);
   for A of C8 loop
      for R of C8 loop
         for G of C8 loop
            for B of C8 loop
               Mix_U32_Color
                 (Interfaces.Shift_Left (A, 24) or Interfaces.Shift_Left (R, 16)
                  or Interfaces.Shift_Left (G, 8) or B);
            end loop;
         end loop;
      end loop;
   end loop;
   for I in 1 .. 20_000 loop
      Mix_U32_Color (U32 (Interfaces.Shift_Right (Rnd, 32)));
   end loop;
   Finish ("colors: sweep Colors_U32", Pixel_Oracle_Data.Colors_U32);

   Start (104);
   for A of C16 loop
      for R of C16 loop
         for G of C16 loop
            for B of C16 loop
               Mix_U64_Color
                 (Interfaces.Shift_Left (A, 48) or Interfaces.Shift_Left (R, 32)
                  or Interfaces.Shift_Left (G, 16) or B);
            end loop;
         end loop;
      end loop;
   end loop;
   for I in 1 .. 20_000 loop
      Mix_U64_Color (Rnd);
   end loop;
   Finish ("colors: sweep Colors_U64", Pixel_Oracle_Data.Colors_U64);

   --  By hand.
   Check (RGB_565_As_Premul_U32 (16#FFFF#) = 16#FFFF_FFFF#, "colors: 565 white");
   Check (RGB_565_As_Premul_U32 (16#0000#) = 16#FF00_0000#, "colors: 565 black");
   Check (RGB_565_As_Premul_U32 (16#F800#) = 16#FFFF_0000#, "colors: 565 red");
   Check (RGB_565_As_Premul_U32 (16#07E0#) = 16#FF00_FF00#, "colors: 565 green");
   Check (RGB_565_As_Premul_U32 (16#001F#) = 16#FF00_00FF#, "colors: 565 blue");
   Check (Premul_U32_As_RGB_565 (16#FFFF_0000#) = 16#F800#, "colors: to 565 red");
   Check (Premul_U32_As_RGB_565 (16#FF00_FF00#) = 16#07E0#, "colors: to 565 green");
   Check (Premul_U32_As_RGB_565 (16#FF00_00FF#) = 16#001F#, "colors: to 565 blue");
   Check (Premul_U32_As_Gray_U8 (16#FFFF_FFFF#) = 16#FF#, "colors: gray of white");
   Check (Premul_U32_As_Gray_U8 (16#FF00_0000#) = 0, "colors: gray of black");
   Check (Premul_U32_As_Gray_U16 (16#FFFF_FFFF#) = 16#FFFF#, "colors: gray16 of white");
   Check (Nonpremul_U32_As_Premul_U32 (16#00FF_FFFF#) = 0, "colors: premul of clear");
   Check (Nonpremul_U32_As_Premul_U32 (16#FF12_3456#) = 16#FF12_3456#,
          "colors: premul of opaque");
   Check (Nonpremul_U32_As_Premul_U32 (16#80FF_FFFF#) = 16#8080_8080#,
          "colors: premul of half white");
   Check (Premul_U32_As_Nonpremul_U32 (16#8080_8080#) = 16#80FF_FFFF#,
          "colors: nonpremul of half white");
   Check (Premul_U32_As_Nonpremul_U32 (16#0012_3456#) = 0, "colors: nonpremul of alpha 0");
   Check (Premul_Is_Valid (16#8080_4000#) and then not Premul_Is_Valid (16#7F80_0000#),
          "colors: premul validity");
   Check (U32_As_U64 (16#1234_56AB#) = 16#1212_3434_5656_ABAB#, "colors: u32 as u64");
   Check (U64_As_U32 (16#12FF_34FF_56FF_ABFF#) = 16#1234_56AB#, "colors: u64 as u32");
   Check (Swap_U32_ARGB_ABGR (16#1122_3344#) = 16#1144_3322#, "colors: swap u32");
   Check (Swap_U64_ARGB_ABGR (16#1111_2222_3333_4444#) = 16#1111_4444_3333_2222#,
          "colors: swap u64");
   Check (Nonpremul_U64_As_Premul_U64 (16#8000_FFFF_FFFF_FFFF#) = 16#8000_8000_8000_8000#,
          "colors: premul u64 of half white");
   Check (Premul_U64_As_Nonpremul_U64 (16#8000_8000_8000_8000#) = 16#8000_FFFF_FFFF_FFFF#,
          "colors: nonpremul u64 of half white");
end Test_Colors;
