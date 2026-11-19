--  Tests the hand-written glue that generated code relies on: the handles
--  of Wuffs.Runtime.
--
--  In the "checked" profile it also checks that misuse of a slice handle is
--  caught: indexing is checked against the slice's own range, not just
--  against the array that it points into.  (In the "release" profile such
--  misuse is, by design, not detected, so those checks are skipped.)
--
--  Exits with a failure status if any check fails.

with Ada.Text_IO;
with Test_Support;
with Wuffs.Base.IO;
with Wuffs.Runtime;

procedure Test_Runtime is

   use type Wuffs.U8;
   use type Wuffs.U32;
   use type Wuffs.U64;
   use type Wuffs.Bytes;
   use type Wuffs.Offset;

   package RT renames Wuffs.Runtime;

   Storage : Wuffs.Bytes (10 .. 29);

   procedure Check_Slices (Data : Wuffs.Bytes);

   procedure Check_Misuse (Data : Wuffs.Bytes);

   procedure Check_Aliasing;

   function Index (X : Integer) return Wuffs.Index
   is (Wuffs.Index (Test_Support.Opaque (X)));

   --  Data (Data'First + I) = 100 + I, and Data has 20 elements.
   procedure Check_Slices (Data : Wuffs.Bytes) is
      --  This is how generated code makes a handle from a parameter.
      S : constant RT.RO_Slice_U8 :=
        (Base => Data'Unrestricted_Access, First => Data'First, Length => Data'Length);
      E : RT.RO_Slice_U8;
      T : RT.RO_Slice_U8;
   begin
      Test_Support.Check (E.Length = 0, "default slice is empty");
      Test_Support.Check (RT.Last (E) = E.First - 1, "Last of the default slice");
      Test_Support.Check (E.Base (E.First .. RT.Last (E))'Length = 0, "view of the default slice");

      Test_Support.Check (S.Length = 20, "whole slice length");
      for I in 0 .. 19 loop
         Test_Support.Check (RT.Get (S, Index (I)) = Wuffs.U8 (100 + I), "Get (whole)", I);
      end loop;

      T := RT.Subslice_IJ (S, Index (3), Index (8));
      Test_Support.Check (T.Length = 5, "Subslice_IJ length");
      for I in 0 .. 4 loop
         Test_Support.Check (RT.Get (T, Index (I)) = Wuffs.U8 (103 + I), "Get (Subslice_IJ)", I);
      end loop;
      Test_Support.Check
        (T.Base (T.First .. RT.Last (T))'Length = 5
         and then T.Base (T.First .. RT.Last (T)) (T.First) = 103,
         "view of Subslice_IJ");

      --  Re-slicing a re-sliced handle (Wuffs: t = t[1 ..], t = t[.. 2]).
      T := RT.Subslice_I (T, Index (1));
      Test_Support.Check
        (T.Length = 4 and then RT.Get (T, Index (0)) = 104 and then RT.Get (T, Index (3)) = 107,
         "Subslice_I");
      T := RT.Subslice_J (T, Index (2));
      Test_Support.Check
        (T.Length = 2 and then RT.Get (T, Index (0)) = 104 and then RT.Get (T, Index (1)) = 105,
         "Subslice_J");

      --  Empty slices at either end, and of an empty slice.
      T := RT.Subslice_J (S, Index (0));
      Test_Support.Check (T.Length = 0, "Subslice_J (0)");
      T := RT.Subslice_I (S, Index (20));
      Test_Support.Check (T.Length = 0, "Subslice_I (length)");
      T := RT.Subslice_IJ (T, Index (0), Index (0));
      Test_Support.Check (T.Length = 0, "Subslice_IJ of an empty slice");
      T := RT.Subslice_IJ (S, Index (0), Index (20));
      Test_Support.Check (T.Length = 20 and then RT.Get (T, Index (19)) = 119, "whole Subslice_IJ");
   end Check_Slices;

   procedure Check_Misuse (Data : Wuffs.Bytes) is
      S : constant RT.RO_Slice_U8 :=
        (Base => Data'Unrestricted_Access, First => Data'First, Length => Data'Length);
      --  Elements 3 .. 7 of S.  The array extends beyond it on both sides.
      T : constant RT.RO_Slice_U8 := RT.Subslice_IJ (S, 3, 8);
      U : RT.RO_Slice_U8;
      X : Wuffs.U8 := 0;

      type Case_Number is range 1 .. 6;
      Caught : Boolean;
   begin
      for C in Case_Number loop
         Caught := False;
         begin
            case C is
               when 1 =>
                  --  One past the end of the slice, but inside the array.
                  X := RT.Get (T, Index (5));
               when 2 =>
                  X := RT.Get (T, Index (17));
               when 3 =>
                  U := RT.Subslice_IJ (T, Index (3), Index (2));
               when 4 =>
                  U := RT.Subslice_IJ (T, Index (0), Index (6));
               when 5 =>
                  U := RT.Subslice_I (T, Index (6));
               when 6 =>
                  U := RT.Subslice_J (T, Index (6));
            end case;
         exception
            when others =>
               Caught := True;
         end;
         Test_Support.Check (Caught, "misuse is caught, case", Integer (C));
      end loop;
      --  Use X and U, so that nothing above is dead code.
      Test_Support.Check (X = 0 and then U.Length = 0, "misuse left no result");
   end Check_Misuse;

   --  The two-array operations, for every way that the two operands can
   --  lie: apart, adjacent, identical, one inside the other, and partially
   --  overlapping in either direction.  The expected result is computed
   --  here with an explicit copy of the source (memmove semantics), not
   --  with the code under test.
   procedure Check_Aliasing is
      package IO renames Wuffs.Base.IO;

      Size : constant := 64;
      Buf  : Wuffs.Bytes (100 .. 100 + Size - 1);
      Want : Wuffs.Bytes (100 .. 100 + Size - 1);
      Temp : Wuffs.Bytes (0 .. Size - 1);

      type Layout is record
         Dst_First, Dst_Length, Src_First, Src_Length : Wuffs.Index;
      end record;

      Layouts : constant array (Positive range <>) of Layout :=
        [(0, 16, 32, 16),    --  apart
         (32, 16, 0, 16),
         (0, 16, 16, 16),    --  adjacent
         (16, 16, 0, 16),
         (8, 16, 8, 16),     --  identical
         (0, 32, 8, 8),      --  source inside destination
         (8, 8, 0, 32),      --  destination inside source
         (8, 16, 16, 16),    --  overlapping, destination first
         (16, 16, 8, 16),    --  overlapping, source first
         (10, 20, 11, 20),   --  shifted by one, both ways
         (11, 20, 10, 20),
         (0, 64, 0, 64),     --  everything
         (5, 0, 5, 10),      --  an empty destination
         (5, 10, 7, 0),      --  an empty source
         (0, 10, 60, 4),     --  a short source
         (60, 4, 0, 10)];    --  a short destination

      N64         : Wuffs.U64;
      N32         : Wuffs.U32;
      Count       : Wuffs.Index;
      W           : IO.Writer;
      R           : IO.Reader;

      procedure Reset;

      --  Sets Want to what moving Count bytes from offset Src_At to offset
      --  Dst_At of the initial contents gives.
      procedure Expect (Dst_At, Src_At, Count : Wuffs.Index);

      --  A view of Buf that the compiler cannot see to be one: generated
      --  code gets its sources through slice handles too.
      function Handle (First, Length : Wuffs.Index) return RT.RO_Slice_U8
      is (RT.Subslice_IJ
            (S => (Base => Buf'Unrestricted_Access, First => Buf'First, Length => Buf'Length),
             I => First,
             J => First + Length));

      procedure Reset is
      begin
         for I in Buf'Range loop
            Buf (I) := Wuffs.U8 (I - Buf'First + 1);
         end loop;
      end Reset;

      procedure Expect (Dst_At, Src_At, Count : Wuffs.Index) is
      begin
         for I in Want'Range loop
            Want (I) := Wuffs.U8 (I - Want'First + 1);
         end loop;
         for I in 0 .. Count - 1 loop
            Temp (I) := Want (Want'First + Src_At + I);
         end loop;
         for I in 0 .. Count - 1 loop
            Want (Want'First + Dst_At + I) := Temp (I);
         end loop;
      end Expect;
   begin
      for K in Layouts'Range loop
         declare
            L   : Layout renames Layouts (K);
            Src : constant RT.RO_Slice_U8 := Handle (L.Src_First, L.Src_Length);
            Dst_Lo : constant Wuffs.Index := Buf'First + L.Dst_First;
            Dst_Hi : constant Wuffs.Offset := Dst_Lo + L.Dst_Length - 1;
            Shares : constant Boolean :=
              L.Dst_Length > 0 and then L.Src_Length > 0
              and then L.Dst_First < L.Src_First + L.Src_Length
              and then L.Src_First < L.Dst_First + L.Dst_Length;
         begin
            Test_Support.Check
              (RT.Share_An_Element (Buf (Dst_Lo .. Dst_Hi), Src.Base (Src.First .. RT.Last (Src)))
               = Shares,
               "Share_An_Element, layout",
               K);

            --  Slice to slice.
            Reset;
            Count := Wuffs.Index'Min (L.Dst_Length, L.Src_Length);
            Expect (L.Dst_First, L.Src_First, Count);
            RT.Copy_From_Slice
              (Dst => Buf (Dst_Lo .. Dst_Hi),
               Src => Src.Base (Src.First .. RT.Last (Src)),
               N   => N64);
            Test_Support.Check
              (Buf = Want and then N64 = Wuffs.U64 (Count), "Copy_From_Slice, layout", K);

            --  Slice to writer, with the writer's cursor at each offset of
            --  three that fit.
            for At_W in Wuffs.Index range 0 .. 2 loop
               if At_W <= L.Dst_Length then
                  Reset;
                  Count := Wuffs.Index'Min (L.Dst_Length - At_W, L.Src_Length);
                  Expect (L.Dst_First + At_W, L.Src_First, Count);
                  W := IO.To_Writer (M => (Wi => At_W, Ri => 0, Pos => 0, Closed => False),
                                     Data_Length => L.Dst_Length);
                  RT.Writer_Copy_From_Slice
                    (Data => Buf (Dst_Lo .. Dst_Hi),
                     W    => W,
                     Src  => Src.Base (Src.First .. RT.Last (Src)),
                     N    => N64);
                  Test_Support.Check
                    (Buf = Want and then N64 = Wuffs.U64 (Count) and then W.Iop = At_W + Count,
                     "Writer_Copy_From_Slice, layout",
                     K);

                  for Up_To in Wuffs.U32 range 0 .. 3 loop
                     Reset;
                     Count :=
                       Wuffs.Index'Min
                         (Wuffs.Index'Min (L.Dst_Length - At_W, L.Src_Length),
                          Wuffs.Index (Up_To) * 7);
                     Expect (L.Dst_First + At_W, L.Src_First, Count);
                     W := IO.To_Writer (M => (Wi => At_W, Ri => 0, Pos => 0, Closed => False),
                                        Data_Length => L.Dst_Length);
                     RT.Writer_Limited_Copy_U32_From_Slice
                       (Data  => Buf (Dst_Lo .. Dst_Hi),
                        W     => W,
                        Up_To => Up_To * 7,
                        Src   => Src.Base (Src.First .. RT.Last (Src)),
                        N     => N32);
                     Test_Support.Check
                       (Buf = Want and then Wuffs.Index (N32) = Count and then W.Iop = At_W + Count,
                        "Writer_Limited_Copy_U32_From_Slice, layout",
                        K);

                     --  Reader to writer: the reader's unread bytes start
                     --  one byte into its array (if it has one).
                     declare
                        At_R : constant Wuffs.Index := Wuffs.Index'Min (1, L.Src_Length);
                     begin
                        Reset;
                        Count :=
                          Wuffs.Index'Min
                            (Wuffs.Index'Min (L.Dst_Length - At_W, L.Src_Length - At_R),
                             Wuffs.Index (Up_To) * 7);
                        Expect (L.Dst_First + At_W, L.Src_First + At_R, Count);
                        W := IO.To_Writer (M => (Wi => At_W, Ri => 0, Pos => 0, Closed => False),
                                           Data_Length => L.Dst_Length);
                        R := IO.To_Reader
                               ((Wi => L.Src_Length, Ri => At_R, Pos => 0, Closed => False));
                        RT.Writer_Limited_Copy_U32_From_Reader
                          (Data     => Buf (Dst_Lo .. Dst_Hi),
                           W        => W,
                           Up_To    => Up_To * 7,
                           Src_Data => Src.Base (Src.First .. RT.Last (Src)),
                           R        => R,
                           N        => N32);
                        Test_Support.Check
                          (Buf = Want
                           and then Wuffs.Index (N32) = Count
                           and then W.Iop = At_W + Count
                           and then R.Iop = At_R + Count,
                           "Writer_Limited_Copy_U32_From_Reader, layout",
                           K);
                     end;
                  end loop;
               end if;
            end loop;
         end;
      end loop;
   end Check_Aliasing;

begin
   for I in Storage'Range loop
      Storage (I) := Wuffs.U8 (100 + (I - Storage'First));
   end loop;

   Check_Slices (Storage);
   --  A parameter that is itself a slice with other bounds.
   Check_Slices (Storage (Storage'First .. Storage'Last));
   Check_Aliasing;

   if Test_Support.Checks_Enabled then
      Check_Misuse (Storage);
      Ada.Text_IO.Put_Line ("test_runtime: checked profile: misuse checks ran");
   else
      Ada.Text_IO.Put_Line ("test_runtime: release profile: misuse checks skipped");
   end if;

   Test_Support.Finish ("test_runtime");
end Test_Runtime;
