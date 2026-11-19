--  The sweeps mirror sweep_swizzler_prepare, sweep_swizzler_rows and
--  sweep_swizzler_reader in oracle/oracle.c.

with Interfaces;
with Pixel_Oracle_Data;
with Pixel_Test_Support; use Pixel_Test_Support;
with Wuffs.Base.IO;
with Wuffs.Base.Pixel_Formats;
with Wuffs.Base.Pixel_Rows;
with Wuffs.Base.Pixel_Swizzler;

package body Test_Swizzler is

   use Wuffs;
   use Wuffs.Base.Pixel_Formats;
   use Wuffs.Base.Pixel_Swizzler;
   use type Interfaces.Unsigned_8;
   use type Interfaces.Unsigned_32;
   use type Interfaces.Unsigned_64;

   package IO renames Wuffs.Base.IO;

   Row_Size : constant := 8 * 1002 + 8;

   SP   : Bytes (0 .. 1027);
   DP0  : Bytes (0 .. 1027);
   DP   : Bytes (0 .. 1027);
   Src  : Bytes (0 .. Row_Size - 1);
   Dst0 : Bytes (0 .. Row_Size - 1);
   Dst  : Bytes (0 .. Row_Size - 1);

   Row_Pixels : constant array (0 .. 14) of Index :=
     [0, 1, 2, 3, 4, 5, 7, 8, 9, 15, 16, 17, 31, 33, 1000];

   --  The oracle's make_src_palette, into SP.
   procedure Make_Src_Palette (Src_Format : U32);

   --  The oracle's fill_row, into Src (0 .. N - 1).
   procedure Fill_Row (N : Index; Kind : Natural);

   function TB_Kind (S : Swizzler) return U64 is
     (case S.Transparent_Black is
        when TB_None     => 0,
        when TB_Src      => 1,
        when TB_Src_Over => 2);

   procedure Sweep_Prepare;
   procedure Sweep_Rows;
   procedure Sweep_Reader;
   procedure Sweep_Row_Fuzz;
   procedure Explicit_Cases;

   ----------------------
   -- Make_Src_Palette --
   ----------------------

   procedure Make_Src_Palette (Src_Format : U32) is
   begin
      Fill (SP);
      for E in Index range 0 .. 255 loop
         if Src_Format = Repr_Indexed_BGRA_Binary then
            if E mod 3 = 0 then
               SP (4 * E .. 4 * E + 3) := [others => 0];
            else
               SP (4 * E + 3) := 16#FF#;
            end if;
         elsif E mod 4 = 0 then
            SP (4 * E + 3) := 16#00#;
         elsif E mod 4 = 1 then
            SP (4 * E + 3) := 16#FF#;
         end if;
      end loop;
   end Make_Src_Palette;

   --------------
   -- Fill_Row --
   --------------

   procedure Fill_Row (N : Index; Kind : Natural) is
      I : Index;
   begin
      case Kind is
         when 0 =>
            Fill (Src (0 .. N - 1));
         when 1 =>
            Src (0 .. N - 1) := [others => 16#00#];
         when 2 =>
            Src (0 .. N - 1) := [others => 16#FF#];
         when 3 =>
            for J in 0 .. N - 1 loop
               Src (J) := (if Interfaces.Shift_Right (Rnd, 63) /= 0 then 16#FF# else 16#00#);
            end loop;
         when others =>
            Fill (Src (0 .. N - 1));
            I := 3;
            while I < N loop
               Src (I) := (if I mod 8 = 7 then 16#00# else 16#FF#);
               I := I + 4;
            end loop;
      end case;
   end Fill_Row;

   -------------------
   -- Sweep_Prepare --
   -------------------

   procedure Sweep_Prepare is
      Blends   : constant array (0 .. 3) of U8 := [0, 1, 2, 255];
      type Pair is array (0 .. 1) of Index;
      Pal_Lens : constant array (0 .. 6) of Pair :=
        [[1024, 1024], [0, 0], [1024, 1020], [1020, 1024],
         [1023, 1024], [1028, 1024], [1024, 1028]];
      S        : Swizzler;
      St       : Status;
      Accepted : Natural := 0;
      Rejected : Natural := 0;
   begin
      Start (131);
      Fill (DP0);
      for SI in Formats'Range loop
         Make_Src_Palette (Formats (SI));
         for DI in Formats'Range loop
            for B of Blends loop
               for L of Pal_Lens loop
                  DP := DP0;
                  Prepare
                    (S,
                     Dst_Pixfmt  => Make_Pixel_Format (Formats (DI)),
                     Dst_Palette => DP (0 .. L (0) - 1),
                     Src_Pixfmt  => Make_Pixel_Format (Formats (SI)),
                     Src_Palette => SP (0 .. L (1) - 1),
                     Blend       => Make_Pixel_Blend (B),
                     Result      => St);
                  Mix (Code (St));
                  Mix (S.Has_Func);
                  Mix (TB_Kind (S));
                  Mix (U64 (S.Dst_BPP));
                  Mix (U64 (S.Src_BPP));
                  Mix_Bytes (DP);
                  if Is_Ok (St) then
                     Accepted := Accepted + 1;
                  else
                     Rejected := Rejected + 1;
                  end if;
               end loop;
            end loop;
            Mark (Pixel_Oracle_Data.Swizzler_Prepare_Marks,
                  "after (src format number, dst format number)", SI, DI);
         end loop;
      end loop;
      Finish ("swizzler: sweep Swizzler_Prepare", Pixel_Oracle_Data.Swizzler_Prepare);
      Check (Accepted = Pixel_Oracle_Data.Swizzler_Prepare_Accepted,
             "swizzler: prepare accepts as many combinations as C");
      Check (Rejected = Pixel_Oracle_Data.Swizzler_Prepare_Rejected,
             "swizzler: prepare rejects as many combinations as C");
   end Sweep_Prepare;

   ----------------
   -- Sweep_Rows --
   ----------------

   procedure Sweep_Rows is
      S        : Swizzler;
      St       : Status;
      Combos   : Natural := 0;
      Rows     : Natural := 0;
      DBPP     : Index;
      SBPP     : Index;
      N        : Index;
      DLen     : Index;
      SLen     : Index;
      Count    : U64;
   begin
      Start (132);
      Fill (Dst0);
      for SI in 0 .. Num_Whole - 1 loop
         for DI in 0 .. Num_Whole - 1 loop
            for Blend in U8 range 0 .. 1 loop
               Make_Src_Palette (Formats (SI));
               Fill (DP);
               Prepare
                 (S,
                  Dst_Pixfmt  => Make_Pixel_Format (Formats (DI)),
                  Dst_Palette => DP (0 .. 1023),
                  Src_Pixfmt  => Make_Pixel_Format (Formats (SI)),
                  Src_Palette => SP (0 .. 1023),
                  Blend       => Make_Pixel_Blend (Blend),
                  Result      => St);
               if Is_Ok (St) then
                  Combos := Combos + 1;
                  DBPP := Index (S.Dst_BPP);
                  SBPP := Index (S.Src_BPP);
                  for LI in Row_Pixels'Range loop
                     N := Row_Pixels (LI);
                     for Arr in 0 .. 3 loop
                        DLen := (N + (if Arr = 2 then 2 else 0)) * DBPP;
                        SLen := (N + (if Arr = 1 then 2 else 0)) * SBPP;
                        if Arr = 3 then
                           DLen := DLen + DBPP - 1;
                           SLen := SLen + SBPP - 1;
                        end if;
                        for Kind in 0 .. 4 loop
                           if not (N = 1000 and then Kind /= 0 and then Arr /= 0) then
                              Fill_Row (SLen, Kind);
                              Dst (0 .. DLen + 7) := Dst0 (0 .. DLen + 7);
                              Swizzle_Interleaved_From_Slice
                                (S,
                                 Dst         => Dst (0 .. DLen - 1),
                                 Dst_Palette => DP (0 .. 1023),
                                 Src         => Src (0 .. SLen - 1),
                                 N           => Count);
                              Mix (Count);
                              Mix_Bytes (Dst (0 .. DLen + 7));
                              Rows := Rows + 1;
                           end if;
                        end loop;
                     end loop;
                  end loop;
                  Fill_Row (9 * SBPP, 0);
                  Dst (0 .. 9 * DBPP + 7) := Dst0 (0 .. 9 * DBPP + 7);
                  Swizzle_Interleaved_From_Slice
                    (S,
                     Dst         => Dst (0 .. 9 * DBPP - 1),
                     Dst_Palette => DP (0 .. 1019),
                     Src         => Src (0 .. 9 * SBPP - 1),
                     N           => Count);
                  Mix (Count);
                  Mix_Bytes (Dst (0 .. 9 * DBPP + 7));
                  Mark (Pixel_Oracle_Data.Swizzler_Rows_Marks,
                        "after (src format number, dst format number, blend)",
                        SI, DI, Integer (Blend));
               end if;
            end loop;
         end loop;
      end loop;
      Finish ("swizzler: sweep Swizzler_Rows", Pixel_Oracle_Data.Swizzler_Rows);
      Check (Combos = Pixel_Oracle_Data.Swizzler_Rows_Combinations,
             "swizzler: rows sweep covers the combinations C accepts");
      Check (Rows = Pixel_Oracle_Data.Swizzler_Rows_Swizzles,
             "swizzler: rows sweep runs as many swizzles as C");
   end Sweep_Rows;

   ------------------
   -- Sweep_Reader --
   ------------------

   procedure Sweep_Reader is
      Up_Tos : constant array (0 .. 4) of U32 := [0, 1, 5, 40, 16#FFFF_FFFF#];
      Blacks : constant array (0 .. 4) of U64 := [0, 1, 7, 1000, U64'Last];
      S      : Swizzler;
      St     : Status;
      Count  : U64;
      R      : IO.Reader;
      DLen   : Index;
      Iop    : Index;
      Io2    : Index;
   begin
      Start (133);
      Fill (Dst0 (0 .. 399));
      for SI in 0 .. Num_Whole - 1 loop
         for DI in 0 .. Num_Whole - 1 loop
            for Blend in U8 range 0 .. 1 loop
               Make_Src_Palette (Formats (SI));
               Fill (DP);
               Prepare
                 (S,
                  Dst_Pixfmt  => Make_Pixel_Format (Formats (DI)),
                  Dst_Palette => DP (0 .. 1023),
                  Src_Pixfmt  => Make_Pixel_Format (Formats (SI)),
                  Src_Palette => SP (0 .. 1023),
                  Blend       => Make_Pixel_Blend (Blend),
                  Result      => St);
               for K in Blacks'Range loop
                  DLen := 0;
                  while DLen <= 33 loop
                     Dst (0 .. 399) := Dst0 (0 .. 399);
                     Swizzle_Interleaved_Transparent_Black
                       (S, Dst (0 .. DLen - 1), DP (0 .. 1023), Blacks (K), Count);
                     Mix (Count);
                     Mix_Bytes (Dst (0 .. 39));
                     DLen := DLen + 11;
                  end loop;
               end loop;
               Fill (Src (0 .. 399));
               Iop := 0;
               while Iop <= 3 loop
                  Io2 := Iop;
                  while Io2 <= Iop + 150 loop
                     DLen := 0;
                     while DLen <= 200 loop
                        Dst (0 .. 399) := Dst0 (0 .. 399);
                        R := (Io0 => 0, Io1 => Iop, Iop => Iop, Io2 => Io2,
                              Pos => 0, Closed => False);
                        Swizzle_Interleaved_From_Reader
                          (S, Dst (0 .. DLen - 1), DP (0 .. 1023), Src (0 .. 399), R, Count);
                        Mix (Count);
                        Mix (U64 (R.Iop));
                        Mix_Bytes (Dst (0 .. 207));
                        for U of Up_Tos loop
                           Dst (0 .. 399) := Dst0 (0 .. 399);
                           R := (Io0 => 0, Io1 => Iop, Iop => Iop, Io2 => Io2,
                                 Pos => 0, Closed => False);
                           Limited_Swizzle_U32_Interleaved_From_Reader
                             (S, U, Dst (0 .. DLen - 1), DP (0 .. 1023),
                              Src (0 .. 399), R, Count);
                           Mix (Count);
                           Mix (U64 (R.Iop));
                           Mix_Bytes (Dst (0 .. 207));
                        end loop;
                        DLen := DLen + 100;
                     end loop;
                     Io2 := Io2 + 75;
                  end loop;
                  Iop := Iop + 3;
               end loop;
               Mark (Pixel_Oracle_Data.Swizzler_Reader_Marks,
                     "after (src format number, dst format number, blend)",
                     SI, DI, Integer (Blend));
            end loop;
         end loop;
      end loop;
      Finish ("swizzler: sweep Swizzler_Reader", Pixel_Oracle_Data.Swizzler_Reader);
   end Sweep_Reader;

   --------------------
   -- Sweep_Row_Fuzz --
   --------------------

   procedure Sweep_Row_Fuzz is
      use Wuffs.Base.Pixel_Rows;
      Pal_Lens : constant array (0 .. 4) of Index := [1024, 1020, 0, 1028, 1023];
      Pal      : Bytes (0 .. 1027);
      S        : Bytes (0 .. 79);
      D        : Bytes (0 .. 79);
      DLen     : Index;
      SLen     : Index;
      N        : Pixel_Count;
      Calls    : Natural := 0;
   begin
      Start (134);
      for Fn in Row_Function loop
         for PL of Pal_Lens loop
            for K in 1 .. 12 loop
               Fill (Pal);
               DLen := Index (Rnd mod 71);
               SLen := Index (Rnd mod 71);
               Fill (S);
               Fill (D);
               Swizzle_Row
                 (Fn,
                  Dst         => D (0 .. DLen - 1),
                  Dst_Palette => Pal (0 .. PL - 1),
                  Src         => S (0 .. SLen - 1),
                  N           => N);
               Mix (U64 (N));
               Mix_Bytes (D);
               Calls := Calls + 1;
            end loop;
         end loop;
         Mark (Pixel_Oracle_Data.Row_Fuzz_Marks, "after row function number",
               Row_Function'Pos (Fn));
      end loop;
      for Q in 0 .. 1 loop
         for Nonpremul in Boolean loop
            for K in 1 .. 12 loop
               DLen := Index (Rnd mod 71);
               SLen := Index (Rnd mod 71);
               Fill (S);
               Fill (D);
               if Q = 0 then
                  Squash_Align4_Bgr_565_8888
                    (D (0 .. DLen - 1), S (0 .. SLen - 1), Nonpremul, N);
               else
                  Squash_Align4_Y_8888 (D (0 .. DLen - 1), S (0 .. SLen - 1), Nonpremul, N);
               end if;
               Mix (U64 (N));
               Mix_Bytes (D);
               Calls := Calls + 1;
            end loop;
         end loop;
         Mark (Pixel_Oracle_Data.Row_Fuzz_Marks, "after squash function number", Q);
      end loop;
      Finish ("swizzler: sweep Row_Fuzz", Pixel_Oracle_Data.Row_Fuzz);
      Check (Calls = Pixel_Oracle_Data.Row_Fuzz_Calls, "swizzler: row fuzz calls as many as C");
   end Sweep_Row_Fuzz;

   --------------------
   -- Explicit_Cases --
   --------------------

   procedure Explicit_Cases is
      No_Pal : Bytes (1 .. 0);
      No_Src : constant Bytes (3 .. 2) := [];
      S      : Swizzler;
      St     : Status;
      N      : U64;
      D      : Bytes (20 .. 31);
      R      : IO.Reader;
   begin
      --  A swizzler that was never prepared (a default-initialised record)
      --  is safe to call and does nothing, in every operation.
      D := [others => 16#EE#];
      Swizzle_Interleaved_From_Slice (S, D, No_Pal, [1, 2, 3, 4], N);
      Check (N = 0 and then (for all B of D => B = 16#EE#), "swizzler: unprepared");
      R := (Io0 => 0, Io1 => 0, Iop => 1, Io2 => 10, Pos => 0, Closed => False);
      Swizzle_Interleaved_From_Reader (S, D, No_Pal, Src (0 .. 9), R, N);
      Check (N = 0 and then R.Iop = 1 and then (for all B of D => B = 16#EE#),
             "swizzler: unprepared, from reader");
      Limited_Swizzle_U32_Interleaved_From_Reader (S, 5, D, No_Pal, Src (0 .. 9), R, N);
      Check (N = 0 and then R.Iop = 1 and then (for all B of D => B = 16#EE#),
             "swizzler: unprepared, limited from reader");
      Check (not S.Has_Func and then S.Transparent_Black = TB_None
             and then S.Dst_BPP = 0 and then S.Src_BPP = 0,
             "swizzler: default value");
      Swizzle_Interleaved_Transparent_Black (S, D, No_Pal, 5, N);
      Check (N = 0 and then (for all B of D => B = 16#EE#), "swizzler: unprepared black");

      --  Y to BGR: each gray byte three times; three whole pixels fit.
      Prepare (S, BGR, No_Pal, Y, No_Src, Blend_Src, St);
      Check (Is_Ok (St) and then S.Dst_BPP = 3 and then S.Src_BPP = 1, "swizzler: prepare y");
      D := [others => 16#EE#];
      Swizzle_Interleaved_From_Slice (S, D (20 .. 30), No_Pal, [10, 20, 30, 40, 50], N);
      Check (N = 3, "swizzler: y to bgr count");
      Check (D = [10, 10, 10, 20, 20, 20, 30, 30, 30, 16#EE#, 16#EE#, 16#EE#],
             "swizzler: y to bgr bytes");

      --  RGBA premul to BGRA premul, blend SRC: red and blue swap.
      Prepare (S, BGRA_Premul, No_Pal, RGBA_Premul, No_Src, Blend_Src, St);
      Check (Is_Ok (St), "swizzler: prepare rgba");
      D := [others => 16#EE#];
      Swizzle_Interleaved_From_Slice (S, D, No_Pal, [1, 2, 3, 4, 5, 6, 7, 8, 9], N);
      Check (N = 2 and then D (20 .. 27) = [3, 2, 1, 4, 7, 6, 5, 8]
             and then D (28) = 16#EE#, "swizzler: rgba to bgra");

      --  BGRA nonpremul over BGRA nonpremul: a transparent source pixel
      --  leaves the destination, an opaque one replaces it.
      Prepare (S, BGRA_Nonpremul, No_Pal, BGRA_Nonpremul, No_Src, Blend_Src_Over, St);
      Check (Is_Ok (St), "swizzler: prepare src_over");
      D := [others => 16#77#];
      Swizzle_Interleaved_From_Slice
        (S, D (20 .. 27), No_Pal, [1, 2, 3, 0, 9, 8, 7, 255], N);
      Check (N = 2 and then D (20 .. 23) = [16#77#, 16#77#, 16#77#, 16#77#]
             and then D (24 .. 27) = [9, 8, 7, 255], "swizzler: src_over extremes");

      --  Transparent black: SRC writes zeroes, SRC_OVER nothing.
      Prepare (S, BGRA_Nonpremul, No_Pal, BGRA_Nonpremul, No_Src, Blend_Src, St);
      D := [others => 16#77#];
      Swizzle_Interleaved_Transparent_Black (S, D (20 .. 30), No_Pal, 2, N);
      Check (N = 2 and then (for all J in Index range 20 .. 27 => D (J) = 0)
             and then D (28) = 16#77#,
             "swizzler: transparent black src");
      Swizzle_Interleaved_Transparent_Black (S, D (20 .. 30), No_Pal, 100, N);
      Check (N = 2 and then D (28) = 16#77#, "swizzler: transparent black clipped");
      Prepare (S, BGRA_Nonpremul, No_Pal, BGRA_Nonpremul, No_Src, Blend_Src_Over, St);
      D := [others => 16#77#];
      Swizzle_Interleaved_Transparent_Black (S, D, No_Pal, 2, N);
      Check (N = 2 and then (for all B of D => B = 16#77#),
             "swizzler: transparent black src_over");

      --  An indexed source: the destination palette is filled by Prepare
      --  and the row function copies entries.
      DP := [others => 0];
      SP := [others => 0];
      SP (4 .. 7) := [16#11#, 16#22#, 16#33#, 16#FF#];
      SP (8 .. 11) := [16#44#, 16#55#, 16#66#, 16#FF#];
      Prepare (S, BGR, DP (0 .. 1023), Indexed_BGRA_Binary, SP (0 .. 1023), Blend_Src, St);
      Check (Is_Ok (St) and then DP (4 .. 7) = SP (4 .. 7), "swizzler: prepare indexed");
      D := [others => 16#EE#];
      Swizzle_Interleaved_From_Slice (S, D, DP (0 .. 1023), [2, 1, 2], N);
      Check (N = 3 and then D (20 .. 28) = [16#44#, 16#55#, 16#66#, 16#11#, 16#22#, 16#33#,
                                              16#44#, 16#55#, 16#66#]
             and then D (29) = 16#EE#, "swizzler: indexed to bgr");
      Swizzle_Interleaved_From_Slice (S, D, DP (0 .. 1022), [1, 1, 1], N);
      Check (N = 0, "swizzler: palette of the wrong length");
      Prepare (S, BGR, DP (0 .. 1023), Indexed_BGRA_Binary, SP (0 .. 1022), Blend_Src, St);
      Check (St = Wuffs.Base.Error_Unsupported_Pixel_Swizzler_Option and then not S.Has_Func,
             "swizzler: prepare with a short source palette");

      --  Rejections, and the blend that is not a blend.
      Prepare (S, BGR, No_Pal, YA_Premul, No_Src, Blend_Src, St);
      Check (St = Wuffs.Base.Error_Unsupported_Pixel_Swizzler_Option
             and then S.Transparent_Black = TB_Src, "swizzler: unsupported source");
      Prepare (S, YCbCr, No_Pal, Y, No_Src, Blend_Src, St);
      Check (St = Wuffs.Base.Error_Unsupported_Pixel_Swizzler_Option
             and then S.Transparent_Black = TB_None and then S.Dst_BPP = 0,
             "swizzler: planar destination");
      Prepare (S, BGR, No_Pal, Y, No_Src, Make_Pixel_Blend (7), St);
      Check (Is_Ok (St) and then S.Transparent_Black = TB_None, "swizzler: blend 7, opaque source");
      Prepare (S, BGRA_Premul, No_Pal, BGRA_Nonpremul, No_Src, Make_Pixel_Blend (7), St);
      Check (not Is_Ok (St), "swizzler: blend 7, source with alpha");

      --  The reader forms advance the reader by whole source pixels.
      Prepare (S, Y, No_Pal, BGR, No_Src, Blend_Src, St);
      Check (Is_Ok (St), "swizzler: prepare bgr to y");
      Src (0 .. 9) := [0, 0, 0, 255, 255, 255, 0, 0, 0, 255];
      R := (Io0 => 0, Io1 => 0, Iop => 3, Io2 => 10, Pos => 0, Closed => False);
      D := [others => 16#EE#];
      Swizzle_Interleaved_From_Reader (S, D, No_Pal, Src (0 .. 9), R, N);
      Check (N = 2 and then R.Iop = 9 and then D (20 .. 22) = [255, 0, 16#EE#],
             "swizzler: from reader");
      R := (Io0 => 0, Io1 => 0, Iop => 0, Io2 => 10, Pos => 0, Closed => False);
      Limited_Swizzle_U32_Interleaved_From_Reader (S, 1, D, No_Pal, Src (0 .. 9), R, N);
      Check (N = 1 and then R.Iop = 3 and then D (20) = 0, "swizzler: limited from reader");
      Limited_Swizzle_U32_Interleaved_From_Reader (S, 0, D, No_Pal, Src (0 .. 9), R, N);
      Check (N = 0 and then R.Iop = 3, "swizzler: limited to zero");
   end Explicit_Cases;

   ---------
   -- Run --
   ---------

   procedure Run is
   begin
      Sweep_Prepare;
      Sweep_Rows;
      Sweep_Reader;
      Sweep_Row_Fuzz;
      Explicit_Cases;
   end Run;

end Test_Swizzler;
