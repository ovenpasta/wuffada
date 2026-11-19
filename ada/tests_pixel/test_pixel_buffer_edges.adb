--  More of Wuffs.Base.Pixel_Buffers: the sweeps that mirror
--  sweep_pixel_buffer_elementless, sweep_pixel_buffer_strides and
--  sweep_pixel_buffer_opaque in oracle/oracle.c.  (A second procedure only
--  to keep each test's stack frame small.)

with Interfaces;
with Pixel_Oracle_Data;
with Pixel_Test_Support; use Pixel_Test_Support;
with Wuffs.Base.Pixel_Buffers;
with Wuffs.Base.Pixel_Formats;

procedure Test_Pixel_Buffer_Edges is

   use Wuffs;
   use Wuffs.Base.Pixel_Buffers;
   use Wuffs.Base.Pixel_Formats;
   use type Interfaces.Unsigned_32;

begin
   ------------------------------
   -- Pixel_Buffer_Elementless --
   ------------------------------

   declare
      type Pair is array (0 .. 1) of U32;
      type Triple is array (0 .. 2) of Index;
      Cfg     : constant array (0 .. 2) of Pair := [[0, 5], [5, 0], [0, 0]];
      Tab     : constant array (0 .. 3) of Triple :=
        [[0, 5, 100], [7, 0, 100], [0, 0, 0], [0, 5, 0]];
      Nothing : Bytes (1 .. 0);
      Palette : constant Bytes (0 .. 1023) := [others => 0];
      C       : Pixel_Config;
      PB      : Pixel_Buffer;
      St      : Status;
      First   : Offset;
      Count   : Index;
   begin
      Start (126);
      for I in Formats'Range loop
         for CI of Cfg loop
            for T of Tab loop
               Set (C, Formats (I), 0, CI (0), CI (1));
               Set_Interleaved
                 (PB, C,
                  Primary        => (Offset => 0, Width => T (0), Height => T (1), Stride => T (2)),
                  Pixels_Length  => 0,
                  Palette_Length => 1024,
                  Result         => St);
               Mix (Code (St));
               if Is_Ok (St) then
                  Mix (U64 (Color_U32_At (PB, Nothing, Palette, 0, 0)));
                  Mix (Is_Opaque (PB, Nothing, Palette));
                  Set_Color_U32_At (PB, Nothing, Palette, 0, 0, 16#FF01_0203#, St);
                  Mix (Code (St));
                  Set_Color_U32_Fill_Rect (PB, Nothing, Palette, (0, 0, 0, 0), 16#FF01_0203#, St);
                  Mix (Code (St));
                  for Y in U32 range 0 .. 5 loop
                     Row_U32 (Plane (PB, 0), Y, 0, First, Count);
                     Mix (U64 (Count));
                     Check (First = 0, "pixel buffers: element-less row offset");
                  end loop;
               end if;
            end loop;
         end loop;
         Mark (Pixel_Oracle_Data.Pixel_Buffer_Elementless_Marks, "after format number", I);
      end loop;
      Finish ("pixel buffers: sweep Pixel_Buffer_Elementless",
              Pixel_Oracle_Data.Pixel_Buffer_Elementless);
   end;

   --------------------------
   -- Pixel_Buffer_Strides --
   --------------------------

   declare
      PX  : Bytes (11 .. 210);
      Pal : Bytes (0 .. 1023);
      C   : Pixel_Config;
      PB  : Pixel_Buffer;
      St  : Status;
      BPP : Index;
   begin
      Start (127);
      for I in 0 .. Num_Whole - 1 loop
         BPP := Index (Bits_Per_Pixel (Make_Pixel_Format (Formats (I))) / 8);
         declare
            Strides : constant array (0 .. 4) of Index :=
              [0, 1, BPP, 3 * BPP - 1, 3 * BPP + 2];
         begin
            for SI in Strides'Range loop
               for WI in Index range 0 .. 1 loop
                  for Op in Boolean loop
                     if Op then
                        PX := [others => 16#FF#];
                     else
                        Fill (PX);
                     end if;
                     if Op and then SI < 2 then
                        Pal := [others => 16#FF#];
                     else
                        Fill (Pal);
                     end if;
                     Set (C, Formats (I), 0, 3, 4);
                     Set_Interleaved
                       (PB, C,
                        Primary        =>
                          (Offset => 6, Width => 3 * BPP + WI * 2, Height => 4,
                           Stride => Strides (SI)),
                        Pixels_Length  => PX'Length,
                        Palette_Length => Pal'Length,
                        Result         => St);
                     Mix (Code (St));
                     if Is_Ok (St) then
                        Mix (Is_Opaque (PB, PX, Pal));
                        for Y in U32 range 0 .. 3 loop
                           for X in U32 range 0 .. 2 loop
                              Mix (U64 (Color_U32_At (PB, PX, Pal, X, Y)));
                              Set_Color_U32_At
                                (PB, PX, Pal, X, Y,
                                 16#8040_2010# + X * 16#0101_0101# + Y * 16#1000_0000#, St);
                              Mix (Code (St));
                              Set_Color_U32_ARGB_Nonpremul_At
                                (PB, PX, Pal, (X + 1) mod 3, Y,
                                 16#90FF_2010# + X * 16#0101_0101#, St);
                              Mix (Code (St));
                           end loop;
                        end loop;
                        Set_Color_U32_Fill_Rect (PB, PX, Pal, (1, 1, 3, 3), 16#FF33_6699#, St);
                        Mix (Code (St));
                        Mix (Is_Opaque (PB, PX, Pal));
                        Mix_Bytes (PX);
                     end if;
                  end loop;
               end loop;
            end loop;
         end;
         Mark (Pixel_Oracle_Data.Pixel_Buffer_Strides_Marks, "after format number", I);
      end loop;
      Finish ("pixel buffers: sweep Pixel_Buffer_Strides",
              Pixel_Oracle_Data.Pixel_Buffer_Strides);
   end;

   -------------------------
   -- Pixel_Buffer_Opaque --
   -------------------------

   declare
      Size  : constant := 1024 + 240;
      Mem   : Bytes (0 .. Size - 1) := [others => 0];
      C     : Pixel_Config;
      PB    : Pixel_Buffer;
      St    : Status;
      Split : Index;
      BPP   : Index;
   begin
      Start (128);
      for I in 0 .. Num_Whole - 1 loop
         Set (C, Formats (I), 0, 5, 3);
         Set_From_Slice (PB, C, Size, St);
         Mix (Code (St));
         if Is_Ok (St) then
            Split := Pixel_Memory_Offset (C);
            BPP := Index (Bits_Per_Pixel (C.Pixfmt) / 8);
            for B in 0 .. BPP - 1 loop
               Mem := [others => 16#FF#];
               Mem (Split + BPP * 7 + B) := 16#FE#;
               Mix (Is_Opaque (PB, Mem (Split .. Size - 1), Mem (0 .. Split - 1)));
            end loop;
            Mem := [others => 16#FF#];
            Mem (4 * 255 + 3) := 16#FE#;
            Mix (Is_Opaque (PB, Mem (Split .. Size - 1), Mem (0 .. Split - 1)));
         end if;
         Mark (Pixel_Oracle_Data.Pixel_Buffer_Opaque_Marks, "after format number", I);
      end loop;
      Finish ("pixel buffers: sweep Pixel_Buffer_Opaque",
              Pixel_Oracle_Data.Pixel_Buffer_Opaque);
   end;
end Test_Pixel_Buffer_Edges;
