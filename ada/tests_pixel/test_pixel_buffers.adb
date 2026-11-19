--  Wuffs.Base.Pixel_Buffers.  The sweeps mirror sweep_tables,
--  sweep_pixel_buffer_set and sweep_pixel_buffer_colors in oracle/oracle.c.

with Interfaces;
with Pixel_Oracle_Data;
with Pixel_Test_Support; use Pixel_Test_Support;
with Wuffs.Base.Pixel_Buffers;
with Wuffs.Base.Pixel_Formats;

procedure Test_Pixel_Buffers is

   use Wuffs;
   use Wuffs.Base.Pixel_Buffers;
   use Wuffs.Base.Pixel_Formats;
   use type Interfaces.Unsigned_8;
   use type Interfaces.Unsigned_32;
   use type Interfaces.Unsigned_64;

   PB_Dims : constant array (0 .. 5) of U32 := [0, 1, 3, 5, 16#1_0000#, 16#FFFF_FFFF#];

   PB_Colors : constant array (0 .. 11) of U32 :=
     [16#0000_0000#, 16#FF00_0000#, 16#FFFF_FFFF#, 16#FF12_3456#, 16#8040_2010#,
      16#80FF_8040#, 16#0101_0101#, 16#7F7F_7F7F#, 16#FE00_00FE#, 16#00FF_FFFF#,
      16#FF00_FF00#, 16#C0C0_8040#];

   --  As the oracle's mix_table: the offset only where there are elements.
   procedure Mix_Table (T : Table);

   procedure Mix_Table (T : Table) is
   begin
      Mix (U64 (T.Width));
      Mix (U64 (T.Height));
      Mix (U64 (T.Stride));
      if T.Width > 0 and then T.Height > 0 then
         Mix (U64 (T.Offset));
      end if;
   end Mix_Table;

begin
   ------------
   -- Tables --
   ------------

   declare
      T : constant Table := (Offset => 3, Width => 5, Height => 4, Stride => 7);
      U : Table;
   begin
      Start (121);
      Check (Fits (T, 64), "pixel buffers: test table fits");
      for IX in U64 range 0 .. 6 loop
         for IY in U64 range 0 .. 5 loop
            for JX in U64 range 0 .. 6 loop
               for JY in U64 range 0 .. 5 loop
                  Subtable (T, IX, IY, JX, JY, 64, U);
                  Mix_Table (U);
               end loop;
            end loop;
         end loop;
      end loop;
      for Y in U32 range 0 .. 5 loop
         declare
            First : Offset;
            Count : Index;
         begin
            Row_U32 (T, Y, 64, First, Count);
            Mix (U64 (Count));
            if Count > 0 then
               Mix (U64 (First));
            end if;
         end;
      end loop;
      for W in Index range 0 .. 3 loop
         for H in Index range 0 .. 3 loop
            for S in Index range 0 .. 4 loop
               Mix (U64 (Flattened_Length (W, H, S)));
            end loop;
         end loop;
      end loop;
      Finish ("pixel buffers: sweep Tables", Pixel_Oracle_Data.Tables);

      --  By hand: rows 1 .. 2, columns 2 .. 4 of T.
      Subtable (T, 2, 1, 5, 3, 64, U);
      Check (U = (Offset => 3 + 7 + 2, Width => 3, Height => 2, Stride => 7),
             "pixel buffers: subtable");
      Check (Row_Start (U, 1, 64) = 19, "pixel buffers: subtable row");
      Subtable (T, 0, 0, 6, 4, 64, U);
      Check (U = Empty_Table, "pixel buffers: subtable too wide");
      Subtable (T, 3, 0, 2, 4, 64, U);
      Check (U = Empty_Table, "pixel buffers: subtable out of order");
      Check (Row_Start (T, 3, 64) = 24 and then not Has_Row (T, 4), "pixel buffers: last row");
      Check (not Fits (T, 28) and then Fits (T, 29), "pixel buffers: fits exactly");
      --  Operations on a table that does not fit its array give nothing.
      declare
         First : Offset;
         Count : Index;
      begin
         Row_U32 (T, 0, 28, First, Count);
         Check (First = 0 and then Count = 0, "pixel buffers: no row of a table that does not fit");
         Row_U32 (T, 3, 29, First, Count);
         Check (First = 24 and then Count = 5, "pixel buffers: last row, exact fit");
         Row_U32 (T, 4, 64, First, Count);
         Check (Count = 0, "pixel buffers: row past the end");
         Subtable (T, 0, 0, 1, 1, 28, U);
         Check (U = Empty_Table, "pixel buffers: no subtable of a table that does not fit");
         --  A table without elements fits anywhere, whatever it says.
         Check (Fits ((Offset => 900, Width => 0, Height => 5, Stride => 100), 0)
                and then Fits ((Offset => 900, Width => 7, Height => 0, Stride => 100), 0),
                "pixel buffers: element-less tables fit");
         Row_U32 ((Offset => 900, Width => 0, Height => 5, Stride => 100), 4, 0, First, Count);
         Check (First = 0 and then Count = 0, "pixel buffers: row of a table with no columns");
         Subtable (T, 1, 1, 1, 3, 64, U);
         Check (U = (Offset => 0, Width => 0, Height => 2, Stride => 7),
                "pixel buffers: subtable with no columns");
         Check (Flattened_Length (Index'Last, Index'Last, Index'Last) = Offset'Last,
                "pixel buffers: flattened length saturates");
      end;
      Check (Fits (Empty_Table, 0), "pixel buffers: empty table fits");
      Check (Flattened_Length (6, 3, 10) = 26, "pixel buffers: flattened length");
   end;

   ----------------------
   -- Pixel_Buffer_Set --
   ----------------------

   declare
      Pal_Lens : constant array (0 .. 2) of Index := [0, 1023, 1024];
      TW       : constant array (0 .. 2) of Index := [0, 12, 40];
      TH       : constant array (0 .. 2) of Index := [0, 3, 5];
      C        : Pixel_Config;
      PB       : Pixel_Buffer;
      St       : Status;
      Need     : U64;
      Repr     : U32;
   begin
      Start (122);
      for FI in Formats'Range loop
         Repr := Formats (FI);
         for W of PB_Dims loop
            for H of PB_Dims loop
               Set (C, Repr, 0, W, H);
               Need := Pixbuf_Len (C);
               declare
                  Lens : constant array (0 .. 5) of Index :=
                    [0, 1023, 1024, 2048,
                     (if Need > 0 and then Need <= 2048 then Index (Need) - 1 else 7),
                     (if Need <= 2048 then Index (Need) else 9)];
               begin
                  for Len of Lens loop
                     Set_From_Slice (PB, C, Len, St);
                     Mix (Code (St));
                     Mix (U64 (PB.Pixcfg.Pixfmt.Repr));
                     Mix (U64 (PB.Pixcfg.Width));
                     Mix (U64 (PB.Pixcfg.Height));
                     Mix_Table (PB.Planes (0));
                     Mix_Table (PB.Planes (3));
                     Mix (U64'(if Has_Palette (PB) then 1024 else 0));
                     Mix (U64 (Get_Pixel_Format (PB).Repr));
                     Mix (U64 (Plane (PB, 3).Width));
                     Mix (U64 (Plane (PB, 4).Width));
                     if Is_Ok (St) then
                        Check
                          (Len >= Pixel_Memory_Offset (C)
                           and then Is_Valid
                                      (PB, Len - Pixel_Memory_Offset (C),
                                       Pixel_Memory_Offset (C)),
                           "pixel buffers: set_from_slice result is valid");
                     else
                        Check (PB.Pixcfg = Null_Pixel_Config
                               and then PB.Planes (0) = Empty_Table
                               and then Is_Valid (PB, 0, 0),
                               "pixel buffers: null config after an error");
                     end if;
                  end loop;
               end;
               for P of Pal_Lens loop
                  for A of TW loop
                     for B of TH loop
                        Set_Interleaved
                          (PB, C,
                           Primary        => (Offset => 5, Width => A, Height => B, Stride => 50),
                           Pixels_Length  => 2048,
                           Palette_Length => P,
                           Result         => St);
                        Mix (Code (St));
                        Mix (U64 (PB.Pixcfg.Pixfmt.Repr));
                        Mix_Table (PB.Planes (0));
                        Mix_Table (PB.Planes (3));
                        Mix (U64'(if Has_Palette (PB) then 1024 else 0));
                        Check (Is_Valid (PB, 2048, P),
                               "pixel buffers: set_interleaved result is valid");
                     end loop;
                  end loop;
               end loop;
            end loop;
         end loop;
         Mark (Pixel_Oracle_Data.Pixel_Buffer_Set_Marks, "after format number", FI);
      end loop;
      Finish ("pixel buffers: sweep Pixel_Buffer_Set", Pixel_Oracle_Data.Pixel_Buffer_Set);
   end;

   -------------------------
   -- Pixel_Buffer_Colors --
   -------------------------

   declare
      type Rect_Numbers is array (0 .. 3) of U32;
      Rects : constant array (0 .. 6) of Rect_Numbers :=
        [[0, 0, 5, 3], [1, 1, 4, 2], [0, 2, 5, 3], [4, 0, 5, 3],
         [2, 2, 2, 3], [0, 0, 6, 3], [3, 1, 5, 4]];
      W     : constant := 5;
      H     : constant := 3;
      Size  : constant := 1024 + 240;
      Base  : Bytes (0 .. Size - 1);
      Mem   : Bytes (0 .. Size - 1);
      C     : Pixel_Config;
      PB    : Pixel_Buffer;
      St    : Status;
      Split : Index;
      Color : U32;
      X, Y  : U32;
      BPP   : Index;
   begin
      Start (123);
      for I in 0 .. Num_Whole - 1 loop
         Fill (Base);
         for E in Index range 0 .. 255 loop
            if E mod 4 = 0 then
               Base (4 * E + 3) := 16#00#;
            elsif E mod 4 = 1 then
               Base (4 * E + 3) := 16#FF#;
            end if;
         end loop;
         Set (C, Formats (I), 0, W, H);
         Mem := Base;
         Set_From_Slice (PB, C, Size, St);
         Mix (Code (St));
         if Is_Ok (St) then
            Split := Pixel_Memory_Offset (C);
            for YY in U32 range 0 .. H loop
               for XX in U32 range 0 .. W loop
                  Mix (U64 (Color_U32_At
                              (PB, Mem (Split .. Size - 1), Mem (0 .. Split - 1), XX, YY)));
               end loop;
            end loop;
            Mix (Is_Opaque (PB, Mem (Split .. Size - 1), Mem (0 .. Split - 1)));
            for K in 0 .. 23 loop
               Color := (if K < 12 then PB_Colors (K)
                         else U32 (Interfaces.Shift_Right (Rnd, 32)));
               X := U32 (K mod (W + 1));
               Y := U32 (K mod (H + 1));
               Mem := Base;
               Set_Color_U32_At
                 (PB, Mem (Split .. Size - 1), Mem (0 .. Split - 1), X, Y, Color, St);
               Mix (Code (St));
               Mix_Bytes (Mem);
               Mix (U64 (Color_U32_At
                           (PB, Mem (Split .. Size - 1), Mem (0 .. Split - 1), X, Y)));
               Mem := Base;
               Set_Color_U32_ARGB_Nonpremul_At
                 (PB, Mem (Split .. Size - 1), Mem (0 .. Split - 1), X, Y, Color, St);
               Mix (Code (St));
               Mix_Bytes (Mem);
            end loop;
            for R in Rects'Range loop
               Mem := Base;
               Set_Color_U32_Fill_Rect
                 (PB, Mem (Split .. Size - 1), Mem (0 .. Split - 1),
                  (Min_Incl_X => Rects (R) (0), Min_Incl_Y => Rects (R) (1),
                   Max_Excl_X => Rects (R) (2), Max_Excl_Y => Rects (R) (3)),
                  PB_Colors ((R + 3) mod 12), St);
               Mix (Code (St));
               Mix_Bytes (Mem);
            end loop;
            Mem := [others => 16#FF#];
            Mix (Is_Opaque (PB, Mem (Split .. Size - 1), Mem (0 .. Split - 1)));
            BPP := Index (Bits_Per_Pixel (C.Pixfmt) / 8);
            Mem (Split + BPP * 7 .. Split + BPP * 7 + BPP - 1) := [others => 0];
            Mix (Is_Opaque (PB, Mem (Split .. Size - 1), Mem (0 .. Split - 1)));
            Mem (0 .. 3) := [others => 0];
            Mix (Is_Opaque (PB, Mem (Split .. Size - 1), Mem (0 .. Split - 1)));
         end if;
         Mark (Pixel_Oracle_Data.Pixel_Buffer_Colors_Marks, "after format number", I);
      end loop;
      Finish
        ("pixel buffers: sweep Pixel_Buffer_Colors", Pixel_Oracle_Data.Pixel_Buffer_Colors);
   end;

   -----------------------
   -- Pixel_Buffer_Gaps --
   -----------------------

   declare
      Pixels  : Bytes (40 .. 239);
      Palette : Bytes (7 .. 1030);
      C       : Pixel_Config;
      PB      : Pixel_Buffer;
      St      : Status;
   begin
      Start (124);
      for I in 0 .. Num_Whole - 1 loop
         Fill (Pixels);
         Fill (Palette);
         Set (C, Formats (I), 0, 3, 4);
         Set_Interleaved
           (PB, C,
            Primary        => (Offset => 6, Width => 26, Height => 4, Stride => 29),
            Pixels_Length  => Pixels'Length,
            Palette_Length => Palette'Length,
            Result         => St);
         Mix (Code (St));
         if Is_Ok (St) then
            for YY in U32 range 0 .. 3 loop
               for XX in U32 range 0 .. 2 loop
                  Mix (U64 (Color_U32_At (PB, Pixels, Palette, XX, YY)));
                  Set_Color_U32_At
                    (PB, Pixels, Palette, XX, YY,
                     PB_Colors (Natural (XX + 3 * YY) mod 12), St);
                  Mix (Code (St));
               end loop;
            end loop;
            Set_Color_U32_Fill_Rect
              (PB, Pixels, Palette,
               (Min_Incl_X => 1, Min_Incl_Y => 1, Max_Excl_X => 3, Max_Excl_Y => 4),
               16#FF33_6699#, St);
            Mix (Code (St));
            Mix_Bytes (Pixels);
            Mix (Is_Opaque (PB, Pixels, Palette));
         end if;
         Mark (Pixel_Oracle_Data.Pixel_Buffer_Gaps_Marks, "after format number", I);
      end loop;
      Finish ("pixel buffers: sweep Pixel_Buffer_Gaps", Pixel_Oracle_Data.Pixel_Buffer_Gaps);
   end;

   ---------------------
   -- Closest_Element --
   ---------------------

   declare
      Palette : Bytes (100 .. 1127);
      Lens    : constant array (0 .. 6) of Index := [0, 3, 4, 8, 1023, 1024, 1028];
      Fmts    : constant array (0 .. 3) of Pixel_Format :=
        [Indexed_BGRA_Nonpremul, Indexed_BGRA_Premul, Indexed_BGRA_Binary, BGRA_Premul];
      Color   : U32;
   begin
      Start (125);
      Fill (Palette);
      for F of Fmts loop
         for L of Lens loop
            for K in 0 .. 111 loop
               Color := (if K < 12 then PB_Colors (K)
                         else U32 (Interfaces.Shift_Right (Rnd, 32)));
               Mix (U64 (Closest_Element (Palette (100 .. 100 + L - 1), F, Color)));
            end loop;
         end loop;
      end loop;
      Finish ("pixel buffers: sweep Closest_Element", Pixel_Oracle_Data.Closest_Element);

      --  By hand: a three entry BGRA palette: black, opaque red, clear.
      declare
         P : constant Bytes (0 .. 11) :=
           [0, 0, 0, 255, 0, 0, 255, 255, 0, 0, 0, 0];
      begin
         Check (Closest_Element (P, Indexed_BGRA_Premul, 16#FFFF_0000#) = 1,
                "pixel buffers: closest is red");
         Check (Closest_Element (P, Indexed_BGRA_Premul, 16#FF10_1010#) = 0,
                "pixel buffers: closest is black");
         Check (Closest_Element (P, Indexed_BGRA_Premul, 16#0000_0000#) = 2,
                "pixel buffers: closest is clear");
         Check (Closest_Element (P, BGRA_Premul, 16#FFFF_0000#) = 0,
                "pixel buffers: closest, not a palette format");
      end;
   end;

   --------------------
   -- Explicit cases --
   --------------------

   --  A 2 by 2 BGRA_Premul buffer, by hand.
   declare
      Mem     : Bytes (10 .. 25) := [others => 0];
      No_Pal  : constant Bytes (1 .. 0) := [];
      C       : Pixel_Config;
      PB      : Pixel_Buffer;
      St      : Status;
   begin
      Set (C, Repr_BGRA_Premul, 0, 2, 2);
      Set_From_Slice (PB, C, 15, St);
      Check (St = Wuffs.Base.Error_Bad_Argument_Length_Too_Short and then PB = Null_Pixel_Buffer,
             "pixel buffers: one byte short");
      Set_From_Slice (PB, C, 16, St);
      Check (Is_Ok (St)
             and then PB.Planes (0) = (Offset => 0, Width => 8, Height => 2, Stride => 8),
             "pixel buffers: exact fit");
      Set_Color_U32_At (PB, Mem, No_Pal, 1, 1, 16#8040_2010#, St);
      Check (Is_Ok (St) and then Mem (22 .. 25) = [16#10#, 16#20#, 16#40#, 16#80#]
             and then (for all J in Index range 10 .. 21 => Mem (J) = 0),
             "pixel buffers: set last pixel");
      Check (Color_U32_At (PB, Mem, No_Pal, 1, 1) = 16#8040_2010#, "pixel buffers: get last pixel");
      Check (Color_U32_At (PB, Mem, No_Pal, 2, 1) = 0
             and then Color_U32_At (PB, Mem, No_Pal, 1, 2) = 0,
             "pixel buffers: get outside");
      Set_Color_U32_At (PB, Mem, No_Pal, 2, 0, 16#FFFF_FFFF#, St);
      Check (St = Wuffs.Base.Error_Bad_Argument, "pixel buffers: set outside");
      Check (not Is_Opaque (PB, Mem, No_Pal), "pixel buffers: not opaque");
      Set_Color_U32_Fill_Rect (PB, Mem, No_Pal, (0, 0, 2, 2), 16#FF01_0203#, St);
      Check (Is_Ok (St) and then (for all K in Index range 0 .. 3 =>
                                    Mem (10 + 4 * K .. 13 + 4 * K) = [3, 2, 1, 255]),
             "pixel buffers: fill");
      Check (Is_Opaque (PB, Mem, No_Pal), "pixel buffers: opaque after fill");
      Set_Color_U32_Fill_Rect (PB, Mem, No_Pal, (0, 0, 3, 2), 0, St);
      Check (St = Wuffs.Base.Error_Bad_Argument, "pixel buffers: fill outside");
      Set_Color_U32_Fill_Rect (PB, Mem, No_Pal, (5, 5, 5, 9), 0, St);
      Check (Is_Ok (St), "pixel buffers: fill empty rect anywhere");
      --  A table that does not fit the memory it is said to be in is an
      --  error (C cannot check this), and a buffer that is not valid for
      --  the arrays an accessor is given has no pixels.
      Set_Interleaved
        (PB, C, (Offset => 0, Width => 8, Height => 2, Stride => 9), 16, 0, St);
      Check (St = Wuffs.Base.Error_Bad_Argument and then PB = Null_Pixel_Buffer,
             "pixel buffers: set_interleaved, table larger than the memory");
      Set_Interleaved
        (PB, C, (Offset => 0, Width => 8, Height => 2, Stride => 8), 16, 0, St);
      Check (Is_Ok (St), "pixel buffers: set_interleaved, table fits exactly");
      Check (Color_U32_At (PB, Mem (10 .. 24), No_Pal, 0, 0) = 0,
             "pixel buffers: read through a buffer that is not valid for the array");
      Set_Color_U32_At (PB, Mem (10 .. 24), No_Pal, 0, 0, 16#FFFF_FFFF#, St);
      Check (St = Wuffs.Base.Error_Bad_Argument and then Mem (10) = 3,
             "pixel buffers: write through a buffer that is not valid for the array");
      Set_Color_U32_Fill_Rect (PB, Mem (10 .. 24), No_Pal, (0, 0, 1, 1), 0, St);
      Check (St = Wuffs.Base.Error_Bad_Argument,
             "pixel buffers: fill through a buffer that is not valid for the array");
      Check (not Is_Opaque (PB, Mem (10 .. 24), No_Pal),
             "pixel buffers: is_opaque of a buffer that is not valid for the array");
      --  Buffers that no setter makes, built by hand.  A planar format:
      --  the colour setters report it as unsupported.
      PB := (Pixcfg => (Pixfmt => YCbCr, Pixsub => Subsampling_None, Width => 0, Height => 2),
             Planes => [0 => (Offset => 0, Width => 0, Height => 2, Stride => 0),
                        others => Empty_Table]);
      Check (Is_Valid (PB, 16, 0), "pixel buffers: hand-made planar buffer is valid");
      PB.Pixcfg.Width := 0;
      Set_Color_U32_Fill_Rect (PB, Mem, No_Pal, (0, 0, 0, 0), 0, St);
      Check (Is_Ok (St), "pixel buffers: planar, empty rect");
      PB.Planes (0) := (Offset => 0, Width => 8, Height => 2, Stride => 8);
      PB.Pixcfg.Width := 2;
      Set_Color_U32_Fill_Rect (PB, Mem, No_Pal, (0, 0, 1, 1), 0, St);
      Check (St = Wuffs.Base.Error_Unsupported_Option, "pixel buffers: planar, fill rect");
      Set_Color_U32_At (PB, Mem, No_Pal, 0, 0, 0, St);
      Check (St = Wuffs.Base.Error_Unsupported_Option, "pixel buffers: planar, set colour");
      Set_Color_U32_ARGB_Nonpremul_At (PB, Mem, No_Pal, 0, 0, 0, St);
      Check (St = Wuffs.Base.Error_Unsupported_Option,
             "pixel buffers: planar, set nonpremul colour");
      --  An indexed format whose plane 3 is not the 1024 by 1 palette
      --  table: no palette.
      PB := (Pixcfg => (Pixfmt => Indexed_BGRA_Binary, Pixsub => Subsampling_None,
                        Width => 2, Height => 2),
             Planes => [0 => (Offset => 0, Width => 8, Height => 2, Stride => 8),
                        3 => (Offset => 0, Width => 1024, Height => 2, Stride => 1024),
                        others => Empty_Table]);
      Check (not Has_Palette (PB), "pixel buffers: plane 3 of height 2 is not a palette");
      PB.Planes (3).Height := 1;
      Check (Has_Palette (PB), "pixel buffers: plane 3 of 1024 by 1 is a palette");
      PB.Planes (3).Width := 1023;
      Check (not Has_Palette (PB), "pixel buffers: plane 3 of width 1023 is not a palette");
      --  A null pixel buffer.
      PB := Null_Pixel_Buffer;
      Check (Is_Valid (PB, 0, 0) and then Color_U32_At (PB, No_Pal, No_Pal, 0, 0) = 0,
             "pixel buffers: null buffer");
      Check (not Has_Palette (PB) and then Plane (PB, 0) = Empty_Table,
             "pixel buffers: null planes");
   end;
end Test_Pixel_Buffers;
