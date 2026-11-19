--  Wuffs.Base.Slices.  The sweeps mirror the sweep_slices_* functions in
--  oracle/oracle.c.

with Base_Oracle_Data;
with Ada.Unchecked_Conversion;
with Base_Test_Support; use Base_Test_Support;
with Interfaces;
with Wuffs.Base.Endian;
with Wuffs.Base.Slices;

procedure Test_Slices is

   use Wuffs;
   use Wuffs.Base.Slices;
   use type Interfaces.Unsigned_8;
   use type Interfaces.Unsigned_16;
   use type Interfaces.Unsigned_32;
   use type Interfaces.Unsigned_64;

   Up_Tos : constant array (0 .. 7) of U64 :=
     [0, 1, 3, 6, 7, 100, 16#8000_0000_0000_0000#, U64'Last];

   Memset_Values : constant array (0 .. 3) of U8 := [16#00#, 16#80#, 16#FF#, 16#5A#];

   --  The element arrays of the memset and bulk sweeps, and their fixed
   --  initial contents.
   A8  : Bytes (0 .. 4);
   A16 : U16_Array (0 .. 4);
   A32 : U32_Array (0 .. 4);
   A64 : U64_Array (0 .. 4);

   procedure Reset_Arrays;

   procedure Reset_Arrays is
   begin
      for I in Index range 0 .. 4 loop
         declare
            X : constant U64 := 16#0123_4567_89AB_CDEF# * U64 (I + 1);
         begin
            A8 (I) := U8 (X and 16#FF#);
            A16 (I) := U16 (X and 16#FFFF#);
            A32 (I) := U32 (X and 16#FFFF_FFFF#);
            A64 (I) := X;
         end;
      end loop;
   end Reset_Arrays;

   N : U64;

   --  The byte order of this machine, found without the library: the
   --  first byte in memory of a known 32 bit value.
   type Four_Bytes is array (0 .. 3) of U8 with Pack, Size => 32;
   function To_Bytes is new Ada.Unchecked_Conversion (U32, Four_Bytes);
   Machine_Is_Little_Endian : constant Boolean := To_Bytes (16#0102_0304#) (0) = 16#04#;

begin
   Check
     (To_Bytes (16#0102_0304#) in [4, 3, 2, 1] | [1, 2, 3, 4],
      "slices: machine is little or big endian");
   Check
     (Host_Is_Little_Endian = Machine_Is_Little_Endian,
      "slices: Host_Is_Little_Endian is the byte order of this machine");

   --------------------------
   -- Slices_Prefix_Suffix --
   --------------------------

   Start (12);
   for Len in Index range 0 .. 6 loop
      for U of Up_Tos loop
         Mix (U64 (Prefix_Length (Len, U)));
         Mix (U64 (Len - Suffix_Offset (Len, U)));
         Mix (U64 (Suffix_Offset (Len, U)));
      end loop;
   end loop;
   Finish ("slices: sweep Slices_Prefix_Suffix", Base_Oracle_Data.Slices_Prefix_Suffix);

   --------------------
   -- Slices_Iterate --
   --------------------

   Start (31);
   for Total in Index range 0 .. 20 loop
      for Len in Index range 1 .. 6 loop
         for Adv in Index range 1 .. Len loop
            Mix (U64 (Iterate_Total_Advance (Total, Len, Adv)));
         end loop;
      end loop;
   end loop;
   Finish ("slices: sweep Slices_Iterate", Base_Oracle_Data.Slices_Iterate);

   -----------------
   -- Slices_Copy --
   -----------------

   declare
      Src : Bytes (50 .. 59);
      Dst : Bytes (7 .. 16);
      D   : Bytes (7 .. 16);
   begin
      Start (13);
      Fill (Src);
      Fill (Dst);
      for DL in Index range 0 .. 10 loop
         for SL in Index range 0 .. 10 loop
            D := Dst;
            Copy_From_Slice
              (D (D'First .. D'First + DL - 1), Src (Src'First .. Src'First + SL - 1), N);
            Mix (N);
            Mix_Bytes (D);
         end loop;
      end loop;
      Finish ("slices: sweep Slices_Copy", Base_Oracle_Data.Slices_Copy);
   end;

   ------------------------
   -- Slices_Copy_Within --
   ------------------------

   declare
      Base : Bytes (30 .. 41);
      D    : Bytes (30 .. 41);
   begin
      Start (14);
      Fill (Base);
      for DF in Index range 0 .. 12 loop
         for DL in Index range 0 .. 12 - DF loop
            for SF in Index range 0 .. 12 loop
               for SL in Index range 0 .. 12 - SF loop
                  D := Base;
                  Copy_Within (D, D'First + DF, DL, D'First + SF, SL, N);
                  Mix (N);
                  Mix_Bytes (D);
               end loop;
            end loop;
         end loop;
      end loop;
      Finish ("slices: sweep Slices_Copy_Within", Base_Oracle_Data.Slices_Copy_Within);
   end;

   -------------------
   -- Slices_Memset --
   -------------------

   Start (15);
   for Count in Index range 0 .. 5 loop
      for V of Memset_Values loop
         Reset_Arrays;
         Bulk_Memset_U8 (A8 (0 .. Count - 1), V);
         Bulk_Memset_U16 (A16 (0 .. Count - 1), V);
         Bulk_Memset_U32 (A32 (0 .. Count - 1), V);
         Bulk_Memset_U64 (A64 (0 .. Count - 1), V);
         for I in Index range 0 .. 4 loop
            Mix (U64 (A8 (I)));
            Mix (U64 (A16 (I)));
            Mix (U64 (A32 (I)));
            Mix (A64 (I));
         end loop;
      end loop;
   end loop;
   Finish ("slices: sweep Slices_Memset", Base_Oracle_Data.Slices_Memset);

   -----------------
   -- Slices_Bulk --
   -----------------

   declare
      Raw : Bytes (9 .. 48);
      D   : Bytes (9 .. 48);
      Size : Index := 1;
   begin
      Start (16);
      Fill (Raw);
      while Size <= 8 loop
         for Count in Index range 0 .. 5 loop
            declare
               Total : constant Index := Count * Size;
               Lens  : constant array (0 .. 3) of Index :=
                 [0, (if Total > 0 then Total - 1 else 0), Total, 40];
            begin
               for Len of Lens loop
                  Reset_Arrays;
                  D := Raw;
                  case Size is
                     when 1 =>
                        Bulk_Save_Host_Endian_U8
                          (D (D'First .. D'First + Len - 1), A8 (0 .. Count - 1));
                     when 2 =>
                        Bulk_Save_Host_Endian_U16
                          (D (D'First .. D'First + Len - 1), A16 (0 .. Count - 1));
                     when 4 =>
                        Bulk_Save_Host_Endian_U32
                          (D (D'First .. D'First + Len - 1), A32 (0 .. Count - 1));
                     when others =>
                        Bulk_Save_Host_Endian_U64
                          (D (D'First .. D'First + Len - 1), A64 (0 .. Count - 1));
                  end case;
                  Mix_Bytes (D);
                  case Size is
                     when 1 =>
                        Bulk_Load_Host_Endian_U8
                          (A8 (0 .. Count - 1), Raw (Raw'First .. Raw'First + Len - 1));
                     when 2 =>
                        Bulk_Load_Host_Endian_U16
                          (A16 (0 .. Count - 1), Raw (Raw'First .. Raw'First + Len - 1));
                     when 4 =>
                        Bulk_Load_Host_Endian_U32
                          (A32 (0 .. Count - 1), Raw (Raw'First .. Raw'First + Len - 1));
                     when others =>
                        Bulk_Load_Host_Endian_U64
                          (A64 (0 .. Count - 1), Raw (Raw'First .. Raw'First + Len - 1));
                  end case;
                  for I in Index range 0 .. 4 loop
                     Mix (case Size is
                             when 1      => U64 (A8 (I)),
                             when 2      => U64 (A16 (I)),
                             when 4      => U64 (A32 (I)),
                             when others => A64 (I));
                  end loop;
               end loop;
            end;
         end loop;
         Size := Size * 2;
      end loop;
      --  The digest depends on the byte order of the machine.  If the
      --  oracle ran on a machine of the other order, the bulk operations
      --  are untested here: that is a failure, not a pass.  (Regenerate
      --  base_oracle_data.ads with oracle/regen.sh on this machine.)
      if Base_Oracle_Data.Oracle_Is_Little_Endian = Machine_Is_Little_Endian then
         Finish ("slices: sweep Slices_Bulk", Base_Oracle_Data.Slices_Bulk);
      else
         Check (False, "slices: sweep Slices_Bulk cannot be compared (oracle byte order)");
      end if;
   end;

   ---------------------------
   -- Slices_Bulk_U8_Within --
   ---------------------------

   declare
      Base : Bytes (70 .. 85);
      D    : Bytes (70 .. 85);
      EF   : Index := 0;
      EL   : Index;
      BF   : Index;
      BL   : Index;
   begin
      Start (33);
      Fill (Base);
      while EF <= 12 loop
         EL := 0;
         while EL <= 16 - EF loop
            BF := 0;
            while BF <= 12 loop
               BL := 0;
               while BL <= 16 - BF loop
                  --  Load: the element slice is the destination.
                  D := Base;
                  Bulk_Load_Host_Endian_U8_Within
                    (D, Dst_First => 70 + EF, Dst_Length => EL,
                     Src_First => 70 + BF, Src_Length => BL);
                  Mix_Bytes (D);
                  --  Save: the element slice is the source.
                  D := Base;
                  Bulk_Save_Host_Endian_U8_Within
                    (D, Dst_First => 70 + BF, Dst_Length => BL,
                     Src_First => 70 + EF, Src_Length => EL);
                  Mix_Bytes (D);
                  BL := BL + 3;
               end loop;
               BF := BF + 2;
            end loop;
            EL := EL + 2;
         end loop;
         EF := EF + 3;
      end loop;
      Finish ("slices: sweep Slices_Bulk_U8_Within", Base_Oracle_Data.Slices_Bulk_U8_Within);

      --  By hand: overlapping, and the all-or-nothing rule.
      D := [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15];
      Bulk_Load_Host_Endian_U8_Within (D, 72, 4, 70, 6);
      Check (D (70 .. 77) = [0, 1, 0, 1, 2, 3, 6, 7], "slices: bulk load u8 within");
      D := [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15];
      Bulk_Load_Host_Endian_U8_Within (D, 72, 4, 70, 3);
      Check (D (70 .. 77) = [0, 1, 2, 3, 4, 5, 6, 7], "slices: bulk load u8 within, short");
      Bulk_Save_Host_Endian_U8_Within (D, 70, 6, 71, 4);
      Check (D (70 .. 77) = [1, 2, 3, 4, 4, 5, 6, 7], "slices: bulk save u8 within");
      D := [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15];
      Bulk_Save_Host_Endian_U8_Within (D, 70, 3, 71, 4);
      Check (D (70 .. 77) = [0, 1, 2, 3, 4, 5, 6, 7], "slices: bulk save u8 within, short");
   end;

   --------------------
   -- Explicit cases --
   --------------------

   --  Prefix and suffix.
   Check (Prefix_Length (0, 0) = 0 and then Suffix_Offset (0, 0) = 0, "slices: prefix of empty");
   Check (Prefix_Length (0, U64'Last) = 0, "slices: prefix of empty, huge up_to");
   Check (Prefix_Length (10, 3) = 3, "slices: prefix shorter");
   Check (Prefix_Length (10, 10) = 10, "slices: prefix exact");
   Check (Prefix_Length (10, 11) = 10, "slices: prefix longer");
   Check (Suffix_Offset (10, 3) = 7, "slices: suffix shorter");
   Check (Suffix_Offset (10, 10) = 0, "slices: suffix exact");
   Check (Suffix_Offset (10, U64'Last) = 0, "slices: suffix huge up_to");
   Check (Suffix_Offset (10, 0) = 10, "slices: suffix of nothing");
   Check (Prefix_Length (Index'Last, U64'Last) = Index'Last, "slices: prefix max length");

   --  The two examples in the C comment, and the extremes.
   Check (Iterate_Total_Advance (15, 5, 3) = 12, "slices: iterate 15, 5, 3");
   Check (Iterate_Total_Advance (15, 5, 5) = 15, "slices: iterate 15, 5, 5");
   Check (Iterate_Total_Advance (4, 5, 5) = 0, "slices: iterate too short");
   Check (Iterate_Total_Advance (0, 1, 1) = 0, "slices: iterate empty");
   Check (Iterate_Total_Advance (5, 5, 1) = 1, "slices: iterate exactly one");
   Check (Iterate_Total_Advance (Index'Last, 1, 1) = Index'Last, "slices: iterate max");
   Check (Iterate_Total_Advance (Index'Last, Index'Last, Index'Last) = Index'Last,
          "slices: iterate max, one step");

   --  Copies with empty and one-element arrays.
   declare
      Empty : Bytes (1 .. 0);
      None  : constant Bytes (8 .. 7) := [];
      One   : Bytes (4 .. 4) := [16#11#];
      Src   : constant Bytes (0 .. 2) := [16#A1#, 16#A2#, 16#A3#];
      Three : Bytes (10 .. 12) := [1, 2, 3];
   begin
      Copy_From_Slice (Empty, Src, N);
      Check (N = 0, "slices: copy into empty");
      Copy_From_Slice (One, Empty, N);
      Check (N = 0 and then One (4) = 16#11#, "slices: copy from empty");
      Copy_From_Slice (Empty, None, N);
      Check (N = 0, "slices: copy empty to empty");
      Copy_From_Slice (One, Src, N);
      Check (N = 1 and then One (4) = 16#A1#, "slices: copy into length 1");
      Copy_From_Slice (Three, Src (1 .. 1), N);
      Check (N = 1 and then Three = [16#A2#, 2, 3], "slices: copy from length 1");
      Copy_From_Slice (Three, Src, N);
      Check (N = 3 and then Three = Src, "slices: copy equal lengths");
   end;

   --  Copy_Within: the overlapping moves that Wuffs code performs.
   declare
      D : Bytes (100 .. 107) := [0, 1, 2, 3, 4, 5, 6, 7];
   begin
      --  Move down (compaction): destination before source.
      Copy_Within (D, 100, 8, 103, 5, N);
      Check (N = 5 and then D = [3, 4, 5, 6, 7, 5, 6, 7], "slices: copy_within down");
      --  Move up: destination after source, overlapping.
      D := [0, 1, 2, 3, 4, 5, 6, 7];
      Copy_Within (D, 102, 6, 100, 8, N);
      Check (N = 6 and then D = [0, 1, 0, 1, 2, 3, 4, 5], "slices: copy_within up");
      --  Onto itself.
      D := [0, 1, 2, 3, 4, 5, 6, 7];
      Copy_Within (D, 101, 4, 101, 4, N);
      Check (N = 4 and then D = [0, 1, 2, 3, 4, 5, 6, 7], "slices: copy_within same");
      --  Disjoint halves.
      Copy_Within (D, 104, 4, 100, 4, N);
      Check (N = 4 and then D = [0, 1, 2, 3, 0, 1, 2, 3], "slices: copy_within disjoint");
      --  Empty parts, including one past the end.
      D := [0, 1, 2, 3, 4, 5, 6, 7];
      Copy_Within (D, 108, 0, 100, 8, N);
      Check (N = 0 and then D = [0, 1, 2, 3, 4, 5, 6, 7], "slices: copy_within empty dst");
      Copy_Within (D, 100, 8, 108, 0, N);
      Check (N = 0 and then D = [0, 1, 2, 3, 4, 5, 6, 7], "slices: copy_within empty src");
   end;

   --  Bulk memset values and empty arrays.
   Check (Repeat_U16 (16#AB#) = 16#ABAB#, "slices: repeat u16");
   Check (Repeat_U32 (16#AB#) = 16#ABAB_ABAB#, "slices: repeat u32");
   Check (Repeat_U64 (16#FF#) = U64'Last, "slices: repeat u64 max");
   Check (Repeat_U64 (16#01#) = 16#0101_0101_0101_0101#, "slices: repeat u64");
   declare
      E8  : Bytes (1 .. 0);
      E64 : U64_Array (5 .. 4);
      B   : Bytes (3 .. 5) := [1, 2, 3];
      W   : U32_Array (0 .. 1) := [1, 2];
   begin
      Bulk_Memset_U8 (E8, 16#FF#);
      Bulk_Memset_U64 (E64, 16#FF#);
      Bulk_Memset_U8 (B, 16#FF#);
      Check (B = [16#FF#, 16#FF#, 16#FF#], "slices: memset u8");
      Bulk_Memset_U8 (B (4 .. 4), 0);
      Check (B = [16#FF#, 0, 16#FF#], "slices: memset u8 length 1");
      Bulk_Memset_U32 (W, 16#80#);
      Check (W = [16#8080_8080#, 16#8080_8080#], "slices: memset u32");
   end;

   --  Bulk load and save: the all-or-nothing rule, and agreement with the
   --  fixed-endian peeks for the byte order of this machine.
   declare
      Raw  : constant Bytes (20 .. 27) := [1, 2, 3, 4, 5, 6, 7, 8];
      D    : Bytes (0 .. 8) := [others => 16#EE#];
      W    : U16_Array (0 .. 2) := [16#1111#, 16#2222#, 16#3333#];
      Q    : U64_Array (7 .. 7) := [0];
      E16  : U16_Array (1 .. 0);
      Old  : constant U16_Array (0 .. 2) := W;
   begin
      --  6 bytes needed, 5 given: nothing is loaded.
      Bulk_Load_Host_Endian_U16 (W, Raw (20 .. 24));
      Check (W = Old, "slices: bulk load too short");
      Bulk_Load_Host_Endian_U16 (W, Raw (20 .. 25));
      Check
        (W (0) = Host_U16 (Raw, 20) and then W (1) = Host_U16 (Raw, 22)
         and then W (2) = Host_U16 (Raw, 24),
         "slices: bulk load u16");
      Check
        (W (0) = (if Machine_Is_Little_Endian then 16#0201# else 16#0102#),
         "slices: bulk load u16 value");
      Bulk_Load_Host_Endian_U64 (Q, Raw);
      Check
        (Q (7) = (if Machine_Is_Little_Endian
                  then Wuffs.Base.Endian.Peek_U64LE (Raw, 20)
                  else Wuffs.Base.Endian.Peek_U64BE (Raw, 20)),
         "slices: bulk load u64");
      Bulk_Load_Host_Endian_U16 (E16, Raw);
      Bulk_Save_Host_Endian_U16 (D, E16);
      Check ((for all B of D => B = 16#EE#), "slices: bulk save of nothing");

      --  8 bytes needed, 7 given: nothing is saved.
      Bulk_Save_Host_Endian_U64 (D (0 .. 6), Q);
      Check ((for all B of D => B = 16#EE#), "slices: bulk save too short");
      Bulk_Save_Host_Endian_U64 (D, Q);
      Check (D (0 .. 7) = Raw and then D (8) = 16#EE#, "slices: bulk save u64 round trip");
      D := [others => 16#EE#];
      Bulk_Save_Host_Endian_U16 (D (1 .. 8), W);
      Check (D (1 .. 6) = Raw (20 .. 25) and then D (0) = 16#EE# and then D (7) = 16#EE#,
             "slices: bulk save u16 round trip");
   end;
end Test_Slices;
