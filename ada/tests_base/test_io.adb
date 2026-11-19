--  Wuffs.Base.IO.  The sweeps mirror the sweep_io_* functions in
--  oracle/oracle.c.  The explicit cases cover what the oracle cannot (the
--  cursor bookkeeping that C code generation emits inline) and check the
--  history copies against a second, independent statement of what an LZ77
--  copy is.

with Base_Oracle_Data;
with Base_Test_Support; use Base_Test_Support;
with Interfaces;
with Wuffs.Base.Endian;
with Wuffs.Base.IO;

procedure Test_IO is

   use Wuffs;
   use Wuffs.Base.IO;
   use type Interfaces.Unsigned_8;
   use type Interfaces.Unsigned_16;
   use type Interfaces.Unsigned_32;
   use type Interfaces.Unsigned_64;

   package Endian renames Wuffs.Base.Endian;

   function Make_Reader (Iop, Io2 : Index; Closed : Boolean := False) return Reader is
     (Io0 => 0, Io1 => Iop, Iop => Iop, Io2 => Io2, Pos => 0, Closed => Closed);

   function Make_Writer (Iop, Io2 : Index) return Writer is
     (Io0 => 0, Io1 => Iop, Iop => Iop, Io2 => Io2, Pos => 0);

   Copy_Up_Tos : constant array (0 .. 3) of U32 := [0, 1, 5, 100];
   Copy_Lens   : constant array (0 .. 3) of Index := [0, 1, 4, 12];

   ---------------------
   -- History sweeps --
   ---------------------

   type History_Proc is access procedure
     (Data     : in out Bytes;
      W        : in out Writer;
      Up_To    : U32;
      Distance : U32;
      Result   : out U32);

   type History_Kind is (Any, Fast, Chunks, Chunks_D1);

   Hist  : constant array (0 .. 7) of Index := [0, 1, 2, 3, 7, 8, 9, 20];
   Dist  : constant array (0 .. 8) of U32 := [0, 1, 2, 3, 7, 8, 9, 21, 1000];
   H_Len : constant array (0 .. 11) of U32 :=
     [0, 1, 2, 3, 7, 8, 9, 16, 17, 30, 100, 16#FFFF_FFFF#];

   procedure Sweep_History
     (Name     : String;
      Seed     : U64;
      F        : History_Proc;
      Kind     : History_Kind;
      Expected : U64);

   procedure Sweep_History
     (Name     : String;
      Seed     : U64;
      F        : History_Proc;
      Kind     : History_Kind;
      Expected : U64)
   is
      Base   : Bytes (3 .. 66);
      D      : Bytes (3 .. 66);
      W      : Writer;
      Result : U32;
   begin
      Start (Seed);
      Fill (Base);
      for Iop of Hist loop
         declare
            Io2s : constant array (0 .. 2) of Index := [Iop, Iop + 5, 64];
         begin
            for Io2 of Io2s loop
               for Distance of Dist loop
                  for Len of H_Len loop
                     if Kind = Any
                       or else
                         (Len >= 1
                          and then Distance >= 1
                          and then Index (Distance) <= Iop
                          and then (Kind /= Fast or else Index (Len) <= Io2 - Iop)
                          and then (Kind = Fast or else Index (Len) + 8 <= Io2 - Iop)
                          and then (Kind /= Chunks or else Distance >= 8)
                          and then (Kind /= Chunks_D1 or else Distance = 1))
                     then
                        D := Base;
                        W := Make_Writer (Iop, Io2);
                        F (D, W, Len, Distance, Result);
                        Mix (U64 (Result));
                        Mix (U64 (W.Iop));
                        Mix_Bytes (D);
                     end if;
                  end loop;
               end loop;
            end loop;
         end;
      end loop;
      Finish (Name, Expected);
   end Sweep_History;

   -----------------------------------
   -- History copies, independently --
   -----------------------------------

   --  What an LZ77 copy of Count bytes at offset Start with distance D must
   --  produce, stated without reference to copying order: output byte K is
   --  the original byte at Start - D + (K mod D).
   function Is_LZ77_Copy
     (Before, After : Bytes; Start, Count, D : Index) return Boolean
   is
     (for all J in After'Range =>
        (if J - After'First >= Start and then J - After'First < Start + Count
         then After (J) = Before (J - D - (J - After'First - Start) / D * D)
         else After (J) = Before (J)));

   procedure Check_History_Semantics;

   procedure Check_History_Semantics is
      Base      : Bytes (11 .. 74);
      D         : Bytes (11 .. 74);
      W         : Writer;
      N, C      : U32;
      Distances : constant array (0 .. 7) of U32 := [1, 2, 3, 7, 8, 9, 20, 21];
      Lengths   : constant array (0 .. 9) of U32 := [1, 2, 3, 7, 8, 9, 15, 16, 17, 30];
      Start     : constant Index := 21;
   begin
      for I in Base'Range loop
         Base (I) := U8 ((I * 7 + 3) mod 251);
      end loop;

      for Distance of Distances loop
         for Len of Lengths loop
            declare
               Count   : constant Index := Index (Len);
               Chunked : constant Index := (Count + 7) / 8 * 8;
               Cusp_0  : constant Index := D'First + Start - Index (Distance) + Count - 1;
            begin
               --  No preconditions: the history is exactly 21 bytes, so
               --  distance 21 works and anything above copies nothing.
               D := Base;
               W := Make_Writer (Start, 64);
               Limited_Copy_U32_From_History (D, W, Len, Distance, N);
               Check (N = Len and then W.Iop = Start + Count, "io: history count");
               Check (Is_LZ77_Copy (Base, D, Start, Count, Index (Distance)),
                      "io: history is an LZ77 copy");

               D := Base;
               W := Make_Writer (Start, 64);
               Limited_Copy_U32_From_History_Fast (D, W, Len, Distance, N);
               Check (N = Len and then W.Iop = Start + Count, "io: history fast count");
               Check (Is_LZ77_Copy (Base, D, Start, Count, Index (Distance)),
                      "io: history fast is an LZ77 copy");

               D := Base;
               W := Make_Writer (Start, 64);
               Limited_Copy_U32_From_History_Fast_Return_Cusp (D, W, Len, Distance, C);
               Check (W.Iop = Start + Count, "io: history fast cusp count");
               Check (Is_LZ77_Copy (Base, D, Start, Count, Index (Distance)),
                      "io: history fast cusp is an LZ77 copy");
               Check (C = U32 (D (Cusp_0)) + 256 * U32 (D (Cusp_0 + 1)),
                      "io: history fast cusp value");

               if Distance >= 8 then
                  D := Base;
                  W := Make_Writer (Start, 64);
                  Limited_Copy_U32_From_History_8_Byte_Chunks_Fast (D, W, Len, Distance, N);
                  Check (N = Len and then W.Iop = Start + Count, "io: history chunks count");
                  Check (Is_LZ77_Copy (Base, D, Start, Chunked, Index (Distance)),
                         "io: history chunks is an LZ77 copy, rounded up to 8");

                  D := Base;
                  W := Make_Writer (Start, 64);
                  Limited_Copy_U32_From_History_8_Byte_Chunks_Fast_Return_Cusp
                    (D, W, Len, Distance, C);
                  Check (W.Iop = Start + Count, "io: history chunks cusp count");
                  Check (Is_LZ77_Copy (Base, D, Start, Chunked, Index (Distance)),
                         "io: history chunks cusp is an LZ77 copy, rounded up to 8");
                  Check (C = U32 (D (Cusp_0)) + 256 * U32 (D (Cusp_0 + 1)),
                         "io: history chunks cusp value");
               end if;

               if Distance = 1 then
                  D := Base;
                  W := Make_Writer (Start, 64);
                  Limited_Copy_U32_From_History_8_Byte_Chunks_Distance_1_Fast
                    (D, W, Len, Distance, N);
                  Check (N = Len and then W.Iop = Start + Count, "io: history d1 count");
                  Check (Is_LZ77_Copy (Base, D, Start, Chunked, 1),
                         "io: history d1 is an LZ77 copy, rounded up to 8");

                  D := Base;
                  W := Make_Writer (Start, 64);
                  Limited_Copy_U32_From_History_8_Byte_Chunks_Distance_1_Fast_Return_Cusp
                    (D, W, Len, Distance, C);
                  Check (W.Iop = Start + Count, "io: history d1 cusp count");
                  Check (Is_LZ77_Copy (Base, D, Start, Chunked, 1),
                         "io: history d1 cusp is an LZ77 copy, rounded up to 8");
                  Check (C = U32 (D (Cusp_0)) * 257, "io: history d1 cusp value");
               end if;
            end;
         end loop;
      end loop;

      --  Distance beyond the history: nothing happens.
      for Distance in U32 range 22 .. 23 loop
         D := Base;
         W := Make_Writer (Start, 64);
         Limited_Copy_U32_From_History (D, W, 5, Distance, N);
         Check (N = 0 and then W.Iop = Start and then D = Base, "io: history too far back");
      end loop;
      D := Base;
      W := Make_Writer (Start, 64);
      Limited_Copy_U32_From_History (D, W, 5, U32'Last, N);
      Check (N = 0 and then D = Base, "io: history distance max");
      Limited_Copy_U32_From_History (D, W, 5, 0, N);
      Check (N = 0 and then D = Base, "io: history distance zero");

      --  A forgotten history (Io0 moved up to the cursor's neighbourhood)
      --  limits the distance, although earlier bytes exist in the array.
      W := (Io0 => Start - 2, Io1 => Start, Iop => Start, Io2 => 64, Pos => 0);
      Limited_Copy_U32_From_History (D, W, 5, 3, N);
      Check (N = 0 and then D = Base, "io: history beyond Io0");
      Limited_Copy_U32_From_History (D, W, 5, 2, N);
      Check (N = 5 and then Is_LZ77_Copy (Base, D, Start, 5, 2), "io: history up to Io0");

      --  Length clipped by the writable limit; exactly filling the buffer.
      D := Base;
      W := Make_Writer (Start, Start + 4);
      Limited_Copy_U32_From_History (D, W, 100, 3, N);
      Check (N = 4 and then W.Iop = Start + 4 and then Is_LZ77_Copy (Base, D, Start, 4, 3),
             "io: history clipped");
      Limited_Copy_U32_From_History (D, W, 100, 3, N);
      Check (N = 0 and then W.Iop = Start + 4, "io: history no room");
      D := Base;
      W := Make_Writer (Start, 64);
      Limited_Copy_U32_From_History (D, W, U32'Last, 1, N);
      Check (N = 43 and then W.Iop = 64 and then Is_LZ77_Copy (Base, D, Start, 43, 1),
             "io: history fills to the end");
   end Check_History_Semantics;

   N   : U32;
   N64 : U64;

begin
   --------------------
   -- IO_Count_Limit --
   --------------------

   declare
      CS     : constant array (0 .. 3) of U64 := [0, 1, 5, U64'Last];
      Limits : constant array (0 .. 7) of U64 := [0, 1, 4, 5, 6, 20, 21, U64'Last];
      Iop    : Index := 0;
      Io2    : Index;
      R      : Reader;
      W      : Writer;
      M      : Buffer_Meta;
      RS     : Reader_Limit_State;
      WS     : Index;
   begin
      Start (17);
      for I of CS loop
         for J of CS loop
            Mix (Count_Since (I, J));
         end loop;
      end loop;
      while Iop <= 20 loop
         Io2 := Iop;
         while Io2 <= 20 loop
            for L of Limits loop
               M := (Wi => Io2, Ri => Iop, Pos => 0, Closed => False);
               R := To_Reader (M);
               Begin_Limit (M, R, L, RS);
               Mix (U64 (R.Io2));
               Check (M.Wi = R.Io2 and then RS.Io2 = Io2, "io: begin_limit meta follows");
               End_Limit (M, R, RS);
               Check (R = Make_Reader (Iop, Io2) and then M.Wi = Io2, "io: end_limit restores");
               W := Make_Writer (Iop, Io2);
               Begin_Limit (W, L, WS);
               Mix (U64 (W.Io2));
               End_Limit (W, WS);
               Check (W = Make_Writer (Iop, Io2), "io: writer end_limit restores");
            end loop;
            Io2 := Io2 + 5;
         end loop;
         Iop := Iop + 5;
      end loop;
      Finish ("io: sweep IO_Count_Limit", Base_Oracle_Data.IO_Count_Limit);
   end;

   ---------------
   -- IO_Match7 --
   ---------------

   declare
      Buf : Bytes (7 .. 18);
      A   : U64;
      B   : U8;
   begin
      Start (18);
      Fill (Buf);
      for Iop in Index range 0 .. 2 loop
         if Iop /= 1 then
            for Avail in Index range 0 .. 10 loop
               for Closed in Boolean loop
                  for Len in Natural range 0 .. 7 loop
                     for Variant in Natural range 0 .. Len loop
                        if not (Len = 0 and then Avail >= 8) then
                           A := U64 (Len);
                           for J in Natural range 0 .. 6 loop
                              B := (if J < Len then Buf (Buf'First + Iop + Index (J))
                                    else 16#A5#);
                              if J = Variant then
                                 B := B xor 16#01#;
                              end if;
                              A := A or Interfaces.Shift_Left (U64 (B), 8 * (J + 1));
                           end loop;
                           Mix (U64 (Match7 (Buf, Make_Reader (Iop, Iop + Avail, Closed), A)));
                        end if;
                     end loop;
                  end loop;
               end loop;
            end loop;
         end if;
      end loop;
      Finish ("io: sweep IO_Match7", Base_Oracle_Data.IO_Match7);

      --  The empty prefix with 8 or more bytes available (a shift by 64 in
      --  C) matches, as it does with fewer bytes.
      Check (Match7 (Buf, Make_Reader (0, 12), 0) = 0, "io: match7 empty prefix, 12 bytes");
      Check (Match7 (Buf, Make_Reader (0, 8), 16#FFFF_FF00#) = 0,
             "io: match7 empty prefix, 8 bytes");
      Check (Match7 (Buf, Make_Reader (0, 7), 0) = 0, "io: match7 empty prefix, 7 bytes");
      Check (Match7 (Buf, Make_Reader (5, 5), 0) = 0, "io: match7 empty prefix, no bytes");
   end;

   ----------------------
   -- IO_Copy_To_Slice --
   ----------------------

   declare
      Src : Bytes (40 .. 51);
      Dst : Bytes (2 .. 13);
      D   : Bytes (2 .. 13);
      R   : Reader;
      W   : Writer;
      Iop : Index;
   begin
      Start (19);
      Fill (Src);
      Fill (Dst);
      Iop := 0;
      while Iop <= 3 loop
         declare
            Io2s : constant array (0 .. 2) of Index := [Iop, Iop + 1, 12];
         begin
            for Io2 of Io2s loop
               for U of Copy_Up_Tos loop
                  for L of Copy_Lens loop
                     D := Dst;
                     R := Make_Reader (Iop, Io2);
                     Limited_Copy_U32_To_Slice (Src, R, U, D (D'First .. D'First + L - 1), N);
                     Mix (U64 (N));
                     Mix (U64 (R.Iop));
                     Mix_Bytes (D);
                  end loop;
               end loop;
            end loop;
         end;
         Iop := Iop + 3;
      end loop;
      Finish ("io: sweep IO_Copy_To_Slice", Base_Oracle_Data.IO_Copy_To_Slice);

      ------------------------
      -- IO_Copy_From_Slice --
      ------------------------

      Start (20);
      Fill (Src);
      Fill (Dst);
      Iop := 0;
      while Iop <= 3 loop
         declare
            Io2s : constant array (0 .. 2) of Index := [Iop, Iop + 1, 12];
         begin
            for Io2 of Io2s loop
               for L of Copy_Lens loop
                  D := Dst;
                  W := Make_Writer (Iop, Io2);
                  Copy_From_Slice (D, W, Src (Src'First .. Src'First + L - 1), N64);
                  Mix (N64);
                  Mix (U64 (W.Iop));
                  Mix_Bytes (D);
                  for U of Copy_Up_Tos loop
                     D := Dst;
                     W := Make_Writer (Iop, Io2);
                     Limited_Copy_U32_From_Slice
                       (D, W, U, Src (Src'First .. Src'First + L - 1), N);
                     Mix (U64 (N));
                     Mix (U64 (W.Iop));
                     Mix_Bytes (D);
                  end loop;
               end loop;
            end loop;
         end;
         Iop := Iop + 3;
      end loop;
      Finish ("io: sweep IO_Copy_From_Slice", Base_Oracle_Data.IO_Copy_From_Slice);

      -------------------------
      -- IO_Copy_From_Reader --
      -------------------------

      Start (21);
      Fill (Src);
      Fill (Dst);
      Iop := 0;
      while Iop <= 3 loop
         declare
            W2s : constant array (0 .. 2) of Index := [Iop, Iop + 2, 12];
            RP  : Index;
         begin
            for W2 of W2s loop
               RP := 0;
               while RP <= 5 loop
                  declare
                     R2s : constant array (0 .. 2) of Index := [RP, RP + 3, 12];
                  begin
                     for R2 of R2s loop
                        for U of Copy_Up_Tos loop
                           D := Dst;
                           W := Make_Writer (Iop, W2);
                           R := Make_Reader (RP, R2);
                           Limited_Copy_U32_From_Reader (D, W, U, Src, R, N);
                           Mix (U64 (N));
                           Mix (U64 (W.Iop));
                           Mix (U64 (R.Iop));
                           Mix_Bytes (D);
                        end loop;
                     end loop;
                  end;
                  RP := RP + 5;
               end loop;
            end loop;
         end;
         Iop := Iop + 3;
      end loop;
      Finish ("io: sweep IO_Copy_From_Reader", Base_Oracle_Data.IO_Copy_From_Reader);
   end;

   ---------------
   -- IO_Within --
   ---------------

   declare
      Base   : Bytes (25 .. 40);
      D      : Bytes (25 .. 40);
      Up_Tos : constant array (0 .. 2) of U32 := [0, 2, 100];
      R      : Reader;
      W      : Writer;
      Iop    : Index := 0;
      Off    : Index;
      WP     : Index;
      RP     : Index;
   begin
      Start (32);
      Fill (Base);
      while Iop <= 8 loop
         declare
            Io2s : constant array (0 .. 1) of Index := [Iop + 6, 16];
         begin
            for Io2 of Io2s loop
               Off := 0;
               while Off <= 12 loop
                  declare
                     Lens : constant array (0 .. 2) of Index :=
                       [0, 3, Index'Min (16 - Off, 8)];
                  begin
                     for L of Lens loop
                        D := Base;
                        W := Make_Writer (Iop, Io2);
                        Copy_From_Slice_Within (D, 0, W, Off, L, N64);
                        Mix (N64);
                        Mix (U64 (W.Iop));
                        Mix_Bytes (D);
                        for U of Up_Tos loop
                           D := Base;
                           R := Make_Reader (Iop, Io2);
                           Limited_Copy_U32_To_Slice_Within (D, 0, R, U, Off, L, N);
                           Mix (U64 (N));
                           Mix (U64 (R.Iop));
                           Mix_Bytes (D);

                           D := Base;
                           W := Make_Writer (Iop, Io2);
                           Limited_Copy_U32_From_Slice_Within (D, 0, W, U, Off, L, N);
                           Mix (U64 (N));
                           Mix (U64 (W.Iop));
                           Mix_Bytes (D);
                        end loop;
                     end loop;
                  end;
                  Off := Off + 2;
               end loop;
            end loop;
         end;
         Iop := Iop + 4;
      end loop;

      WP := 0;
      while WP <= 9 loop
         declare
            W2s : constant array (0 .. 1) of Index := [WP + 5, 16];
         begin
            for W2 of W2s loop
               RP := 0;
               while RP <= 10 loop
                  declare
                     R2s : constant array (0 .. 1) of Index := [RP + 4, 16];
                  begin
                     for R2 of R2s loop
                        for U of Up_Tos loop
                           D := Base;
                           W := Make_Writer (WP, W2);
                           R := Make_Reader (RP, R2);
                           Limited_Copy_U32_From_Reader_Within (D, 0, W, U, 0, R, N);
                           Mix (U64 (N));
                           Mix (U64 (W.Iop));
                           Mix (U64 (R.Iop));
                           Mix_Bytes (D);
                        end loop;
                     end loop;
                  end;
                  RP := RP + 2;
               end loop;
            end loop;
         end;
         WP := WP + 3;
      end loop;
      Finish ("io: sweep IO_Within", Base_Oracle_Data.IO_Within);

      --  By hand, with cursors whose own arrays start inside Data (bases
      --  not zero).  Data is 0 .. 15 at offsets 0 .. 15.
      Base := [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15];

      --  Writer over offsets 4 .. 15 (base 4), cursor 2 => offset 6; reader
      --  over offsets 2 .. 11 (base 2), cursor 1 => offset 3.  Overlapping
      --  move of 5 bytes up by 3.
      D := Base;
      W := Make_Writer (2, 12);
      R := Make_Reader (1, 10);
      Limited_Copy_U32_From_Reader_Within (D, 4, W, 5, 2, R, N);
      Check (N = 5 and then W.Iop = 7 and then R.Iop = 6, "io: reader within, counts");
      Check (D = [0, 1, 2, 3, 4, 5, 3, 4, 5, 6, 7, 11, 12, 13, 14, 15],
             "io: reader within, overlapping up");
      --  The other direction: writer below the reader.
      D := Base;
      W := Make_Writer (0, 3);
      R := Make_Reader (0, 10);
      Limited_Copy_U32_From_Reader_Within (D, 1, W, 100, 2, R, N);
      Check (N = 3 and then W.Iop = 3 and then R.Iop = 3, "io: reader within, writer short");
      Check (D = [0, 2, 3, 4, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15],
             "io: reader within, overlapping down");

      --  Reader (base 3) to a slice at offset 5 that overlaps it.
      D := Base;
      R := Make_Reader (1, 8);
      Limited_Copy_U32_To_Slice_Within (D, 3, R, 100, 5, 4, N);
      Check (N = 4 and then R.Iop = 5, "io: to slice within, counts");
      Check (D = [0, 1, 2, 3, 4, 4, 5, 6, 7, 9, 10, 11, 12, 13, 14, 15],
             "io: to slice within, bytes");

      --  A slice at offset 0 into a writer (base 2) whose cursor is at 1.
      D := Base;
      W := Make_Writer (1, 14);
      Copy_From_Slice_Within (D, 2, W, 0, 6, N64);
      Check (N64 = 6 and then W.Iop = 7, "io: from slice within, counts");
      Check (D = [0, 1, 2, 0, 1, 2, 3, 4, 5, 9, 10, 11, 12, 13, 14, 15],
             "io: from slice within, bytes");
      D := Base;
      W := Make_Writer (1, 14);
      Limited_Copy_U32_From_Slice_Within (D, 2, W, 2, 0, 6, N);
      Check (N = 2 and then W.Iop = 3, "io: limited from slice within, counts");
      Check (D = [0, 1, 2, 0, 1, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15],
             "io: limited from slice within, bytes");

      --  Empty operands at the very end of the array.
      D := Base;
      W := Make_Writer (0, 0);
      Copy_From_Slice_Within (D, 16, W, 16, 0, N64);
      Check (N64 = 0 and then D = Base, "io: within, empty at the end");
   end;

   ----------------
   -- IO_History --
   ----------------

   Sweep_History
     ("io: sweep IO_History", 22, Limited_Copy_U32_From_History'Access, Any,
      Base_Oracle_Data.IO_History);
   Sweep_History
     ("io: sweep IO_History_Fast", 23, Limited_Copy_U32_From_History_Fast'Access, Fast,
      Base_Oracle_Data.IO_History_Fast);
   Sweep_History
     ("io: sweep IO_History_Fast_Cusp", 24,
      Limited_Copy_U32_From_History_Fast_Return_Cusp'Access, Fast,
      Base_Oracle_Data.IO_History_Fast_Cusp);
   Sweep_History
     ("io: sweep IO_History_Chunks", 25,
      Limited_Copy_U32_From_History_8_Byte_Chunks_Fast'Access, Chunks,
      Base_Oracle_Data.IO_History_Chunks);
   Sweep_History
     ("io: sweep IO_History_Chunks_Cusp", 26,
      Limited_Copy_U32_From_History_8_Byte_Chunks_Fast_Return_Cusp'Access, Chunks,
      Base_Oracle_Data.IO_History_Chunks_Cusp);
   Sweep_History
     ("io: sweep IO_History_Chunks_D1", 27,
      Limited_Copy_U32_From_History_8_Byte_Chunks_Distance_1_Fast'Access, Chunks_D1,
      Base_Oracle_Data.IO_History_Chunks_D1);
   Sweep_History
     ("io: sweep IO_History_Chunks_D1_Cusp", 28,
      Limited_Copy_U32_From_History_8_Byte_Chunks_Distance_1_Fast_Return_Cusp'Access,
      Chunks_D1, Base_Oracle_Data.IO_History_Chunks_D1_Cusp);

   Check_History_Semantics;

   --  The two examples in the comment of
   --  wuffs_private_impl__io_writer__limited_copy_u32_from_history_fast_return_cusp:
   --  history [10 .. 18]; l=3, d=8 gives [11, 12, 13], cusp (13, 14);
   --  l=3, d=2 gives [17, 18, 17], cusp (17, 18).
   declare
      D : Bytes (0 .. 15) := [10, 11, 12, 13, 14, 15, 16, 17, 18, others => 0];
      W : Writer := Make_Writer (9, 16);
      C : U32;
   begin
      Limited_Copy_U32_From_History_Fast_Return_Cusp (D, W, 3, 8, C);
      Check (D (9 .. 11) = [11, 12, 13] and then W.Iop = 12, "io: cusp example 1 bytes");
      Check (C = 13 + 256 * 14, "io: cusp example 1 cusp");
      D := [10, 11, 12, 13, 14, 15, 16, 17, 18, others => 0];
      W := Make_Writer (9, 16);
      Limited_Copy_U32_From_History_Fast_Return_Cusp (D, W, 3, 2, C);
      Check (D (9 .. 11) = [17, 18, 17] and then W.Iop = 12, "io: cusp example 2 bytes");
      Check (C = 17 + 256 * 18, "io: cusp example 2 cusp");
   end;

   ----------------
   -- IO_Compact --
   ----------------

   declare
      Base    : Bytes (5 .. 20);
      D       : Bytes (5 .. 20);
      Poss    : constant array (0 .. 2) of U64 := [0, 5, 16#FFFF_FFFF_FFFF_FFFE#];
      Retains : constant array (0 .. 3) of U64 := [0, 1, 3, 100];
      Wi      : Index := 0;
      M       : Buffer_Meta;
      Moved   : Index;
   begin
      Start (29);
      Fill (Base);
      while Wi <= 16 loop
         declare
            Ris : constant array (0 .. 3) of Index :=
              [0, (if Wi > 0 then 1 else 0), Wi / 2, Wi];
         begin
            for Ri of Ris loop
               for Pos of Poss loop
                  for Closed in Boolean loop
                     for K in 0 .. 4 loop
                        D := Base;
                        M := (Wi => Wi, Ri => Ri, Pos => Pos, Closed => Closed);
                        if K < 4 then
                           Compact_Retaining (D, M, Retains (K), Moved);
                        else
                           Compact (D, M, Moved);
                        end if;
                        Mix (U64 (Moved));
                        Mix (U64 (M.Wi));
                        Mix (U64 (M.Ri));
                        Mix (M.Pos);
                        Mix (M.Closed);
                        Mix (U64 (Reader_Length (M)));
                        Mix (Reader_Position (M));
                        Mix (Writer_Length (D, M));
                        Mix (Writer_Position (M));
                        Mix_Bytes (D);
                     end loop;
                  end loop;
               end loop;
            end loop;
         end;
         Wi := Wi + 2;
      end loop;
      Finish ("io: sweep IO_Compact", Base_Oracle_Data.IO_Compact);

      --  By hand: 16 byte buffer, ri = 6, wi = 10.
      Base := [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15];
      D := Base;
      M := (Wi => 10, Ri => 6, Pos => 100, Closed => True);
      Compact (D, M, Moved);
      Check (Moved = 6 and then M = (Wi => 4, Ri => 0, Pos => 106, Closed => True),
             "io: compact meta");
      Check (D (5 .. 8) = [6, 7, 8, 9] and then D (9 .. 20) = Base (9 .. 20),
             "io: compact bytes");
      D := Base;
      M := (Wi => 10, Ri => 6, Pos => 100, Closed => False);
      Compact_Retaining (D, M, 2, Moved);
      Check (Moved = 4 and then M = (Wi => 6, Ri => 2, Pos => 104, Closed => False),
             "io: compact_retaining meta");
      Check (D (5 .. 10) = [4, 5, 6, 7, 8, 9] and then D (11 .. 20) = Base (11 .. 20),
             "io: compact_retaining bytes");
      --  Nothing read yet: nothing moves.
      M := (Wi => 10, Ri => 0, Pos => 7, Closed => False);
      D := Base;
      Compact (D, M, Moved);
      Check (Moved = 0 and then M = (Wi => 10, Ri => 0, Pos => 7, Closed => False)
             and then D = Base, "io: compact with ri = 0");
      --  An empty buffer.
      declare
         E : Bytes (1 .. 0);
      begin
         M := Empty_Meta;
         Check (Is_Valid (E, M), "io: empty buffer is valid");
         Compact (E, M, Moved);
         Check (Moved = 0 and then M = Empty_Meta, "io: compact empty buffer");
         Check (Writer_Length (E, M) = 0 and then Reader_Length (M) = 0,
                "io: empty buffer lengths");
      end;
      Check (not Is_Valid (Base, (Wi => 17, Ri => 0, Pos => 0, Closed => False)),
             "io: wi beyond the data is not valid");
      Check (Reader_Meta (16, True) = (Wi => 16, Ri => 0, Pos => 0, Closed => True),
             "io: reader_meta");
      Check (Writer_Meta (9) = (Wi => 0, Ri => 0, Pos => 9, Closed => False), "io: writer_meta");
   end;

   -------------------
   -- IO_Read_Steps --
   -------------------

   declare
      Buf     : Bytes (60 .. 67);
      R       : Reader;
      Scratch : U64;
      Value   : U64;
      Done    : Boolean;
      Bits    : U32 := 16;
      Whole   : U64;
   begin
      Start (30);
      while Bits <= 64 loop
         for LE in Boolean loop
            Fill (Buf);
            R := Make_Reader (0, 8);
            Scratch := 0;
            loop
               if LE then
                  Read_Step_LE (Buf, R, Scratch, Bits - 8, Done, Value);
               else
                  Read_Step_BE (Buf, R, Scratch, Bits - 8, Done, Value);
               end if;
               exit when Done;
               Mix (Scratch);
               Check (Value = 0, "io: read step value before done");
            end loop;
            Mix (Scratch);
            Mix (Value);
            Mix (U64 (R.Iop));

            --  Assembling byte by byte equals peeking the whole value.
            Whole :=
              (case Bits is
                 when 16 => U64 (if LE then Endian.Peek_U16LE (Buf, 60)
                                 else Endian.Peek_U16BE (Buf, 60)),
                 when 24 => U64 (if LE then Endian.Peek_U24LE (Buf, 60)
                                 else Endian.Peek_U24BE (Buf, 60)),
                 when 32 => U64 (if LE then Endian.Peek_U32LE (Buf, 60)
                                 else Endian.Peek_U32BE (Buf, 60)),
                 when 40 => (if LE then Endian.Peek_U40LE (Buf, 60)
                             else Endian.Peek_U40BE (Buf, 60)),
                 when 48 => (if LE then Endian.Peek_U48LE (Buf, 60)
                             else Endian.Peek_U48BE (Buf, 60)),
                 when 56 => (if LE then Endian.Peek_U56LE (Buf, 60)
                             else Endian.Peek_U56BE (Buf, 60)),
                 when others => (if LE then Endian.Peek_U64LE (Buf, 60)
                                 else Endian.Peek_U64BE (Buf, 60)));
            Check (Value = Whole, "io: read steps equal a peek");
            Check (R.Iop = Index (Bits / 8), "io: read steps consume the width");
         end loop;
         Bits := Bits + 8;
      end loop;
      Finish ("io: sweep IO_Read_Steps", Base_Oracle_Data.IO_Read_Steps);
   end;

   ---------------------------
   -- Reader, explicit cases --
   ---------------------------

   declare
      Buf : constant Bytes (10 .. 25) :=
        [16#10#, 16#11#, 16#12#, 16#13#, 16#14#, 16#15#, 16#16#, 16#17#,
         16#18#, 16#19#, 16#1A#, 16#1B#, 16#1C#, 16#1D#, 16#1E#, 16#1F#];
      M   : Buffer_Meta := (Wi => 14, Ri => 3, Pos => 1000, Closed => True);
      R   : Reader := To_Reader (M);
      V   : U8;
      S   : U64;
      Done : Boolean;
   begin
      Check (R = (Io0 => 0, Io1 => 3, Iop => 3, Io2 => 14, Pos => 1000, Closed => True),
             "io: to_reader");
      Check (Valid (Buf, R), "io: reader valid");
      Check (Length (R) = 11 and then Is_Closed (R), "io: reader length");
      Check (Mark (R) = 3 and then Position (R) = 1003, "io: reader mark and position");
      Check (not Can_Undo_Byte (R), "io: reader cannot undo at entry");

      --  Peeks at the cursor agree with Endian at the absolute index.
      Check (Peek_U8 (Buf, R) = 16#13#, "io: reader peek_u8");
      Check (Peek_U16BE (Buf, R) = 16#1314#, "io: reader peek_u16be");
      Check (Peek_U16LE (Buf, R) = 16#1413#, "io: reader peek_u16le");
      Check (Peek_U24BE (Buf, R) = 16#13_1415#, "io: reader peek_u24be");
      Check (Peek_U24LE (Buf, R) = 16#15_1413#, "io: reader peek_u24le");
      Check (Peek_U32BE (Buf, R) = 16#1314_1516#, "io: reader peek_u32be");
      Check (Peek_U32LE (Buf, R) = 16#1615_1413#, "io: reader peek_u32le");
      Check (Peek_U40BE (Buf, R) = Endian.Peek_U40BE (Buf, 13), "io: reader peek_u40be");
      Check (Peek_U40LE (Buf, R) = Endian.Peek_U40LE (Buf, 13), "io: reader peek_u40le");
      Check (Peek_U48BE (Buf, R) = Endian.Peek_U48BE (Buf, 13), "io: reader peek_u48be");
      Check (Peek_U48LE (Buf, R) = Endian.Peek_U48LE (Buf, 13), "io: reader peek_u48le");
      Check (Peek_U56BE (Buf, R) = Endian.Peek_U56BE (Buf, 13), "io: reader peek_u56be");
      Check (Peek_U56LE (Buf, R) = Endian.Peek_U56LE (Buf, 13), "io: reader peek_u56le");
      Check (Peek_U64BE (Buf, R) = 16#1314_1516_1718_191A#, "io: reader peek_u64be");
      Check (Peek_U64LE (Buf, R) = 16#1A19_1817_1615_1413#, "io: reader peek_u64le");
      Check (Peek_U8_At (Buf, R, 0) = 16#13#, "io: reader peek_u8_at 0");
      Check (Peek_U8_At (Buf, R, 10) = 16#1D#, "io: reader peek_u8_at last");
      Check (Peek_U64LE_At (Buf, R, 3) = 16#1D1C_1B1A_1918_1716#, "io: reader peek_u64le_at");

      Read_U8 (Buf, R, V);
      Check (V = 16#13# and then R.Iop = 4, "io: read_u8");
      Check (Can_Undo_Byte (R) and then Peek_Undo_Byte (Buf, R) = 16#13#, "io: reader undo peek");
      Skip_U32_Fast (R, 2);
      Check (R.Iop = 6 and then Mark (R) = 6 and then Position (R) = 1006, "io: skip_u32_fast");
      Skip_U32_Fast (R, 0);
      Check (R.Iop = 6, "io: skip_u32_fast zero");
      Check (Count_Since (R, 3) = 3 and then Count_Since (R, 6) = 0
             and then Count_Since (R, 7) = 0 and then Count_Since (R, U64'Last) = 0,
             "io: reader count_since");
      Check (Since_Offset (R, 3) = 3 and then Since_Length (R, 3) = 3, "io: reader since");
      Check (Since_Length (R, 6) = 0 and then Since_Length (R, 9) = 0, "io: reader since empty");
      Check (Since_Offset (R, 0) = 0 and then Since_Length (R, 0) = 6, "io: reader since 0");
      Undo_Byte (R);
      Check (R.Iop = 5 and then Peek_U8 (Buf, R) = 16#15#, "io: reader undo_byte");

      Save (M, R);
      Check (M = (Wi => 14, Ri => 5, Pos => 1000, Closed => True), "io: reader save");

      --  Skip protocol: 12 to skip, 9 available, then 5 more.
      S := 12;
      Skip (R, S, Done);
      Check (not Done and then S = 3 and then R.Iop = 14 and then Length (R) = 0,
             "io: skip, short");
      Skip (R, S, Done);
      Check (not Done and then S = 3 and then R.Iop = 14, "io: skip, nothing available");
      R := Make_Reader (0, 5);
      Skip (R, S, Done);
      Check (Done and then R.Iop = 3, "io: skip, resumed");
      S := 0;
      Skip (R, S, Done);
      Check (Done and then R.Iop = 3, "io: skip zero");
      S := U64'Last;
      Skip (R, S, Done);
      Check (not Done and then S = U64'Last - 2 and then R.Iop = 5, "io: skip huge");

      --  io_limit on a reader, following the C that statement.go emits:
      --  cutting readable bytes off clears closed in cursor and meta and
      --  moves meta.wi; a callee then sees the limited buffer; the end
      --  restores io2, wi and closed but keeps the cursor.
      declare
         LM   : Buffer_Meta := (Wi => 14, Ri => 4, Pos => 50, Closed => True);
         LS   : Reader_Limit_State;
         LS2  : Reader_Limit_State;
         Sub  : Reader;
         Seen : U8;
      begin
         R := To_Reader (LM);
         Begin_Limit (LM, R, 10, LS);
         Check (R = (Io0 => 0, Io1 => 4, Iop => 4, Io2 => 14, Pos => 50, Closed => True)
                and then LM = (Wi => 14, Ri => 4, Pos => 50, Closed => True),
                "io: reader limit that cuts nothing");
         End_Limit (LM, R, LS);
         Check (R.Io2 = 14 and then R.Closed and then LM.Wi = 14 and then LM.Closed,
                "io: reader limit that cuts nothing, end");

         Begin_Limit (LM, R, 9, LS);
         Check (LS = (Io2 => 14, Closed => True), "io: reader limit saved state");
         Check (R.Io2 = 13 and then not R.Closed and then R.Iop = 4 and then Length (R) = 9,
                "io: reader limit cuts, cursor");
         Check (LM = (Wi => 13, Ri => 4, Pos => 50, Closed => False),
                "io: reader limit cuts, meta");

         --  A callee inside the limit: it sees 9 bytes and not closed.
         Save (LM, R);
         Sub := To_Reader (LM);
         Check (Length (Sub) = 9 and then not Is_Closed (Sub), "io: callee sees the limit");
         Read_U8 (Buf, Sub, Seen);
         Read_U8 (Buf, Sub, Seen);
         Save (LM, Sub);
         Reload (R, LM);
         Check (R.Iop = 6 and then Seen = 16#15# and then Length (R) = 7, "io: reload");

         --  A nested, tighter limit, then a looser one that changes nothing.
         Begin_Limit (LM, R, 3, LS2);
         Check (R.Io2 = 9 and then LM.Wi = 9 and then LS2 = (Io2 => 13, Closed => False),
                "io: nested reader limit");
         End_Limit (LM, R, LS2);
         Check (R.Io2 = 13 and then LM.Wi = 13 and then not R.Closed and then not LM.Closed,
                "io: nested reader limit, end");
         Begin_Limit (LM, R, 0, LS2);
         Check (R.Io2 = 6 and then Length (R) = 0 and then LM.Wi = 6, "io: reader limit zero");
         End_Limit (LM, R, LS2);

         End_Limit (LM, R, LS);
         Check (R = (Io0 => 0, Io1 => 4, Iop => 6, Io2 => 14, Pos => 50, Closed => True),
                "io: reader limit end, cursor");
         Check (LM = (Wi => 14, Ri => 6, Pos => 50, Closed => True),
                "io: reader limit end, meta");
      end;

      --  A reader whose history base is not the start of the array: marks,
      --  position, count_since and since all count from Io0.
      R := (Io0 => 2, Io1 => 3, Iop => 7, Io2 => 12, Pos => 100, Closed => False);
      Check (Mark (R) = 5, "io: reader mark with Io0 > 0");
      Check (Position (R) = 105, "io: reader position with Io0 > 0");
      Check (Count_Since (R, 1) = 4 and then Count_Since (R, 5) = 0
             and then Count_Since (R, 6) = 0, "io: reader count_since with Io0 > 0");
      Check (Since_Offset (R, 1) = 3 and then Since_Length (R, 1) = 4,
             "io: reader since with Io0 > 0");
      Check (Since_Offset (R, 0) = 2 and then Since_Length (R, 0) = 5,
             "io: reader since mark 0 with Io0 > 0");
      Check (Since_Length (R, 6) = 0, "io: reader since, mark ahead, with Io0 > 0");

      --  Position saturates.
      R := (Io0 => 0, Io1 => 0, Iop => 5, Io2 => 5, Pos => U64'Last - 2, Closed => False);
      Check (Position (R) = U64'Last, "io: reader position saturates");

      R := Reader_Set (16, 77);
      Check (R = (Io0 => 0, Io1 => 0, Iop => 0, Io2 => 16, Pos => 77, Closed => False),
             "io: reader_set");

      --  Match7, by hand: prefix 16#13#, 16#14# at the cursor of Buf (3).
      R := Make_Reader (3, 5);
      Check (Match7 (Buf, R, 16#14_13_02#) = 0, "io: match7 match, slow path");
      Check (Match7 (Buf, R, 16#15_13_02#) = 2, "io: match7 mismatch, slow path");
      Check (Match7 (Buf, R, 16#15_14_13_03#) = 1, "io: match7 short, open");
      R := Make_Reader (3, 5, Closed => True);
      Check (Match7 (Buf, R, 16#15_14_13_03#) = 2, "io: match7 short, closed");
      Check (Match7 (Buf, R, 16#99_14_13_03#) = 2, "io: match7 short, closed, mismatch");
      R := Make_Reader (3, 14);
      Check (Match7 (Buf, R, 16#14_13_02#) = 0, "io: match7 match, fast path");
      Check (Match7 (Buf, R, 16#19_18_17_16_15_14_13_07#) = 0, "io: match7 7 bytes");
      Check (Match7 (Buf, R, 16#18_18_17_16_15_14_13_07#) = 2, "io: match7 7 bytes, last differs");
      Check (Match7 (Buf, R, 16#FF_FF_FF_FF_FF_14_13_02#) = 0, "io: match7 ignores high bytes");
   end;

   --  Operations on an empty array.
   declare
      E   : Bytes (1 .. 0);
      E2  : constant Bytes (6 .. 5) := [];
      Src : constant Bytes (0 .. 3) := [1, 2, 3, 4];
      Dst : Bytes (0 .. 3) := [9, 9, 9, 9];
      R   : Reader;
      W   : Writer;
   begin
      Check (Valid (E, R) and then Valid (E, W), "io: default cursors valid on empty data");
      Check (Length (R) = 0 and then Length (W) = 0, "io: empty lengths");
      Check (Match7 (E, R, 0) = 0, "io: match7 on empty, empty prefix");
      Check (Match7 (E, R, 16#41_01#) = 1, "io: match7 on empty, open");
      R.Closed := True;
      Check (Match7 (E, R, 16#41_01#) = 2, "io: match7 on empty, closed");
      Limited_Copy_U32_To_Slice (E, R, 10, Dst, N);
      Check (N = 0 and then Dst = [9, 9, 9, 9], "io: copy to slice from empty");
      Copy_From_Slice (E, W, Src, N64);
      Check (N64 = 0 and then W.Iop = 0, "io: copy_from_slice into empty");
      Limited_Copy_U32_From_Slice (E, W, 10, Src, N);
      Check (N = 0, "io: limited copy from slice into empty");
      Limited_Copy_U32_From_Reader (E, W, 10, E2, R, N);
      Check (N = 0, "io: copy from reader, both empty");
      Limited_Copy_U32_From_History (E, W, 10, 1, N);
      Check (N = 0, "io: history on empty");
      Limited_Copy_U32_From_History (E, W, 0, 0, N);
      Check (N = 0, "io: history on empty, zero distance");
   end;

   ---------------------------
   -- Writer, explicit cases --
   ---------------------------

   declare
      D   : Bytes (30 .. 45) := [others => 16#EE#];
      M   : Buffer_Meta := (Wi => 2, Ri => 1, Pos => 500, Closed => False);
      W   : Writer := To_Writer (M, D'Length);
      Old : Bytes (30 .. 45);
   begin
      Check (W = (Io0 => 0, Io1 => 2, Iop => 2, Io2 => 16, Pos => 500), "io: to_writer");
      Check (Valid (D, W) and then Length (W) = 14, "io: writer length");
      Check (Mark (W) = 2 and then History_Length (W) = 2, "io: writer mark");
      Check (History_Position (W) = 500 and then Position (W) = 502, "io: writer position");
      Check (not Can_Undo_Byte (W), "io: writer cannot undo at entry");

      Write_U8_Fast (D, W, 16#01#);
      Check (W.Iop = 3 and then D (32) = 16#01#, "io: write_u8_fast");
      Check (Can_Undo_Byte (W) and then Peek_Undo_Byte (D, W) = 16#01#, "io: writer undo peek");
      Undo_Byte (W);
      Check (W.Iop = 2 and then not Can_Undo_Byte (W), "io: writer undo_byte");

      Write_U16BE_Fast (D, W, 16#0102#);
      Write_U16LE_Fast (D, W, 16#0102#);
      Check (D (32 .. 35) = [1, 2, 2, 1] and then W.Iop = 6, "io: write_u16 be, le");
      Write_U24BE_Fast (D, W, 16#FF01_0203#);
      Write_U24LE_Fast (D, W, 16#FF01_0203#);
      Check (D (36 .. 41) = [1, 2, 3, 3, 2, 1] and then W.Iop = 12, "io: write_u24 be, le");
      Write_U32BE_Fast (D, W, 16#0A0B_0C0D#);
      Check (D (42 .. 45) = [16#0A#, 16#0B#, 16#0C#, 16#0D#] and then W.Iop = 16,
             "io: write_u32be to the very end");
      Check (Length (W) = 0, "io: writer full");
      Check (D (30) = 16#EE# and then D (31) = 16#EE#, "io: writes leave earlier bytes");
      Check (Count_Since (W, 2) = 14 and then Count_Since (W, 17) = 0, "io: writer count_since");
      Check (Since_Offset (W, 2) = 2 and then Since_Length (W, 2) = 14, "io: writer since");
      Check (Since_Length (W, 17) = 0, "io: writer since, mark ahead");

      Save (M, W);
      Check (M = (Wi => 16, Ri => 1, Pos => 500, Closed => False), "io: writer save");

      --  Each remaining width: the bytes at the cursor read back as the
      --  value (masked to the width) and nothing else changes.
      for Kind in 0 .. 9 loop
         D := [others => 16#EE#];
         Old := D;
         W := Make_Writer (4, 16);
         declare
            V    : constant U64 := 16#F1E2_D3C4_B5A6_9788#;
            Size : Index;
            Good : Boolean;
         begin
            case Kind is
               when 0 =>
                  Write_U32LE_Fast (D, W, U32 (V and 16#FFFF_FFFF#));
                  Size := 4;
                  Good := U64 (Endian.Peek_U32LE (D, 34)) = (V and 16#FFFF_FFFF#);
               when 1 =>
                  Write_U40BE_Fast (D, W, V);
                  Size := 5;
                  Good := Endian.Peek_U40BE (D, 34) = (V and 16#FF_FFFF_FFFF#);
               when 2 =>
                  Write_U40LE_Fast (D, W, V);
                  Size := 5;
                  Good := Endian.Peek_U40LE (D, 34) = (V and 16#FF_FFFF_FFFF#);
               when 3 =>
                  Write_U48BE_Fast (D, W, V);
                  Size := 6;
                  Good := Endian.Peek_U48BE (D, 34) = (V and 16#FFFF_FFFF_FFFF#);
               when 4 =>
                  Write_U48LE_Fast (D, W, V);
                  Size := 6;
                  Good := Endian.Peek_U48LE (D, 34) = (V and 16#FFFF_FFFF_FFFF#);
               when 5 =>
                  Write_U56BE_Fast (D, W, V);
                  Size := 7;
                  Good := Endian.Peek_U56BE (D, 34) = (V and 16#FF_FFFF_FFFF_FFFF#);
               when 6 =>
                  Write_U56LE_Fast (D, W, V);
                  Size := 7;
                  Good := Endian.Peek_U56LE (D, 34) = (V and 16#FF_FFFF_FFFF_FFFF#);
               when 7 =>
                  Write_U64BE_Fast (D, W, V);
                  Size := 8;
                  Good := Endian.Peek_U64BE (D, 34) = V
                    and then D (34) = 16#F1# and then D (41) = 16#88#;
               when 8 =>
                  Write_U64LE_Fast (D, W, V);
                  Size := 8;
                  Good := Endian.Peek_U64LE (D, 34) = V
                    and then D (34) = 16#88# and then D (41) = 16#F1#;
               when others =>
                  Write_U8_Fast (D, W, 16#88#);
                  Size := 1;
                  Good := D (34) = 16#88#;
            end case;
            Check (Good, "io: write fast value");
            Check (W.Iop = 4 + Size, "io: write fast advance");
            Check (D (30 .. 33) = Old (30 .. 33)
                   and then D (34 + Size .. 45) = Old (34 + Size .. 45),
                   "io: write fast frame");
         end;
      end loop;

      --  A closed buffer accepts nothing.
      W := To_Writer ((Wi => 2, Ri => 0, Pos => 0, Closed => True), 16);
      Check (Length (W) = 0 and then W.Iop = 2, "io: closed writer has no room");

      declare
         Saved_Io2 : Index;
      begin
         W := Make_Writer (4, 16);
         Begin_Limit (W, 12, Saved_Io2);
         Check (W.Io2 = 16 and then Saved_Io2 = 16, "io: writer limit exact");
         End_Limit (W, Saved_Io2);
         Begin_Limit (W, 5, Saved_Io2);
         Check (W.Io2 = 9 and then Length (W) = 5 and then Saved_Io2 = 16,
                "io: writer limit cuts");
         Write_U8_Fast (D, W, 1);
         End_Limit (W, Saved_Io2);
         Check (W = (Io0 => 0, Io1 => 4, Iop => 5, Io2 => 16, Pos => 0),
                "io: writer limit end");
      end;

      --  A writer whose history base is not the start of the array.
      W := (Io0 => 3, Io1 => 5, Iop => 9, Io2 => 16, Pos => 1000);
      Check (Mark (W) = 6 and then History_Length (W) = 6, "io: writer mark with Io0 > 0");
      Check (Position (W) = 1006, "io: writer position with Io0 > 0");
      Check (History_Position (W) = 1000, "io: writer history_position with Io0 > 0");
      Check (Count_Since (W, 2) = 4 and then Count_Since (W, 7) = 0,
             "io: writer count_since with Io0 > 0");
      Check (Since_Offset (W, 2) = 5 and then Since_Length (W, 2) = 4,
             "io: writer since with Io0 > 0");

      --  io_forget_history, following the C that statement.go emits.
      --  Buffer of 16 with wi = 6 (and pos 500): the function has written
      --  3 more bytes (cursor 9) and saved, so meta.wi = 9.
      declare
         FM    : Buffer_Meta := (Wi => 6, Ri => 2, Pos => 500, Closed => False);
         FS    : Forget_State;
         Sub   : Writer;
         N_Hist : U32;
      begin
         D := [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15];
         W := To_Writer (FM, 16);
         for I in 1 .. 3 loop
            Write_U8_Fast (D, W, 16#A0# + U8 (I));
         end loop;
         Save (FM, W);
         Check (History_Length (W) = 9 and then Position (W) = 509, "io: before forget");

         Begin_Forget_History (FM, W, FS);
         Check (FS = (Meta => (Wi => 9, Ri => 2, Pos => 500, Closed => False),
                      Io0 => 0, Io1 => 6), "io: forget saved state");
         Check (Forgotten_Base (FS) = 9, "io: forgotten base");
         Check (FM = (Wi => 0, Ri => 0, Pos => 509, Closed => False), "io: forget meta");
         Check (W = (Io0 => 9, Io1 => 9, Iop => 9, Io2 => 16, Pos => 509), "io: forget cursor");
         Check (History_Length (W) = 0 and then Mark (W) = 0, "io: forget history is empty");
         Check (Position (W) = 509 and then History_Position (W) = 509, "io: forget position");
         Check (not Can_Undo_Byte (W), "io: forget, no undo into the old data");

         --  The old bytes are out of reach of history copies.
         Limited_Copy_U32_From_History (D, W, 4, 1, N_Hist);
         Check (N_Hist = 0 and then W.Iop = 9, "io: forget, history copy refused");
         Write_U8_Fast (D, W, 16#B1#);
         Write_U8_Fast (D, W, 16#B2#);
         Check (History_Length (W) = 2 and then Position (W) = 511 and then Mark (W) = 2,
                "io: forget, after two writes");
         Check (Since_Offset (W, 0) = 9 and then Since_Length (W, 0) = 2,
                "io: forget, since counts from the new base");
         Limited_Copy_U32_From_History (D, W, 2, 2, N_Hist);
         Check (N_Hist = 2 and then D (41 .. 42) = [16#B1#, 16#B2#], "io: forget, new history");
         Limited_Copy_U32_From_History (D, W, 2, 5, N_Hist);
         Check (N_Hist = 0, "io: forget, distance beyond new history");

         --  A callee inside the body gets the re-based array and meta.
         Save_Forgotten (FM, W, FS);
         Check (FM = (Wi => 4, Ri => 0, Pos => 509, Closed => False), "io: save_forgotten");
         Sub := To_Writer (FM, 16 - Forgotten_Base (FS));
         Check (Position (Sub) = 513 and then Length (Sub) = 3, "io: forget, callee view");
         Write_U8_Fast (D (30 + Forgotten_Base (FS) .. 45), Sub, 16#C1#);
         Save (FM, Sub);
         Reload_Forgotten (W, FM, FS);
         Check (W.Iop = 14 and then D (43) = 16#C1# and then Position (W) = 514,
                "io: reload_forgotten");

         End_Forget_History (FM, W, FS);
         Check (FM = (Wi => 14, Ri => 2, Pos => 500, Closed => False), "io: forget end, meta");
         Check (W = (Io0 => 0, Io1 => 6, Iop => 14, Io2 => 16, Pos => 500),
                "io: forget end, cursor");
         Check (History_Length (W) = 14 and then Position (W) = 514,
                "io: forget end, history is back");

         --  The meta's write index is what C re-bases at, even when the
         --  cursor is ahead of it (no Save before the statement).
         FM := (Wi => 6, Ri => 0, Pos => U64'Last - 2, Closed => True);
         W := (Io0 => 0, Io1 => 6, Iop => 8, Io2 => 16, Pos => U64'Last - 2);
         Begin_Forget_History (FM, W, FS);
         Check (Forgotten_Base (FS) = 6 and then FM.Pos = U64'Last and then FM.Closed,
                "io: forget with stale meta, saturating position");
         Check (W.Io0 = 8 and then Position (W) = U64'Last, "io: forget with stale meta, cursor");
         Save_Forgotten (FM, W, FS);
         Check (FM.Wi = 2, "io: save_forgotten with stale meta");
         End_Forget_History (FM, W, FS);
         Check (FM = (Wi => 8, Ri => 0, Pos => U64'Last - 2, Closed => True)
                and then W = (Io0 => 0, Io1 => 6, Iop => 8, Io2 => 16, Pos => U64'Last - 2),
                "io: forget with stale meta, end");
      end;

      W := Writer_Set (16, 3);
      Check (W = (Io0 => 0, Io1 => 0, Iop => 0, Io2 => 16, Pos => 3), "io: writer_set");
      W := (Io0 => 0, Io1 => 0, Iop => 9, Io2 => 9, Pos => U64'Last - 1);
      Check (Position (W) = U64'Last, "io: writer position saturates");
   end;

   --  Copies between cursors, by hand.
   declare
      Src : constant Bytes (100 .. 105) := [1, 2, 3, 4, 5, 6];
      D   : Bytes (0 .. 7) := [others => 16#EE#];
      W   : Writer := Make_Writer (2, 8);
      R   : Reader := Make_Reader (1, 6);
   begin
      Limited_Copy_U32_From_Reader (D, W, 3, Src, R, N);
      Check (N = 3 and then W.Iop = 5 and then R.Iop = 4, "io: copy from reader counts");
      Check (D = [16#EE#, 16#EE#, 2, 3, 4, 16#EE#, 16#EE#, 16#EE#], "io: copy from reader bytes");
      Limited_Copy_U32_From_Reader (D, W, 100, Src, R, N);
      Check (N = 2 and then W.Iop = 7 and then R.Iop = 6, "io: copy from reader, reader short");
      Check (D = [16#EE#, 16#EE#, 2, 3, 4, 5, 6, 16#EE#], "io: copy from reader bytes 2");
      Copy_From_Slice (D, W, Src, N64);
      Check (N64 = 1 and then W.Iop = 8 and then D (7) = 1, "io: copy_from_slice, writer short");
      Copy_From_Slice (D, W, Src, N64);
      Check (N64 = 0, "io: copy_from_slice, writer full");
      W := Make_Writer (0, 8);
      Limited_Copy_U32_From_Slice (D, W, 2, Src, N);
      Check (N = 2 and then D (0 .. 2) = [1, 2, 2], "io: limited copy from slice");
      R := Make_Reader (0, 6);
      Limited_Copy_U32_To_Slice (Src, R, 4, D (5 .. 7), N);
      Check (N = 3 and then R.Iop = 3 and then D (5 .. 7) = [1, 2, 3],
             "io: copy to slice, slice short");
   end;
end Test_IO;
