--  Tests the hand-written glue that generated code relies on: the slice
--  handles of Wuffs.Runtime and the stand-in helpers of
--  Wuffs.Runtime.Temp_Base.
--
--  In the "checked" profile it also checks that misuse of a slice handle is
--  caught: indexing is checked against the slice's own range, not just
--  against the array that it points into.  (In the "release" profile such
--  misuse is, by design, not detected, so those checks are skipped.)
--
--  Exits with a failure status if any check fails.

with Ada.Text_IO;
with Test_Support;
with Wuffs.Runtime.Temp_Base;

procedure Test_Runtime is

   use type Wuffs.U8;
   use type Wuffs.U16;
   use type Wuffs.U32;
   use type Wuffs.U64;
   use type Wuffs.Offset;

   package RT renames Wuffs.Runtime;
   package Base renames Wuffs.Runtime.Temp_Base;

   Storage : Wuffs.Bytes (10 .. 29);

   procedure Check_Slices (Data : Wuffs.Bytes);

   procedure Check_Misuse (Data : Wuffs.Bytes);

   procedure Check_Sat;

   procedure Check_Iterate;

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

   procedure Check_Sat is
      Max_32 : constant := 2 ** 32 - 1;
      Max_64 : constant := 2 ** 64 - 1;
      Sum, Diff : Integer;
   begin
      --  Exhaustively for 8 bits, against unbounded arithmetic.
      for X in Wuffs.U8 loop
         for Y in Wuffs.U8 loop
            Sum := Integer'Min (Integer (X) + Integer (Y), 255);
            Diff := Integer'Max (Integer (X) - Integer (Y), 0);
            if Base.Sat_Add_U8 (X, Y) /= Wuffs.U8 (Sum)
              or else Base.Sat_Sub_U8 (X, Y) /= Wuffs.U8 (Diff)
            then
               Test_Support.Check (False, "Sat_Add_U8 or Sat_Sub_U8", Integer (X));
            end if;
         end loop;
      end loop;
      Test_Support.Check (True, "Sat_Add_U8 and Sat_Sub_U8 ran");

      Test_Support.Check (Base.Sat_Add_U16 (16#FFF0#, 16#000F#) = 16#FFFF#, "Sat_Add_U16", 1);
      Test_Support.Check (Base.Sat_Add_U16 (16#FFF0#, 16#0010#) = 16#FFFF#, "Sat_Add_U16", 2);
      Test_Support.Check (Base.Sat_Add_U16 (16#1234#, 16#0101#) = 16#1335#, "Sat_Add_U16", 3);
      Test_Support.Check (Base.Sat_Sub_U16 (16#0010#, 16#0011#) = 0, "Sat_Sub_U16", 1);
      Test_Support.Check (Base.Sat_Sub_U16 (16#0010#, 16#0010#) = 0, "Sat_Sub_U16", 2);
      Test_Support.Check (Base.Sat_Sub_U16 (16#FFFF#, 16#0001#) = 16#FFFE#, "Sat_Sub_U16", 3);

      Test_Support.Check_U32 (Base.Sat_Add_U32 (Max_32 - 15, 15), Max_32, "Sat_Add_U32", 1);
      Test_Support.Check_U32 (Base.Sat_Add_U32 (Max_32 - 15, 16), Max_32, "Sat_Add_U32", 2);
      Test_Support.Check_U32 (Base.Sat_Add_U32 (2 ** 31, 2 ** 31), Max_32, "Sat_Add_U32", 3);
      Test_Support.Check_U32 (Base.Sat_Add_U32 (1, 2), 3, "Sat_Add_U32", 4);
      Test_Support.Check_U32 (Base.Sat_Sub_U32 (1, 2), 0, "Sat_Sub_U32", 1);
      Test_Support.Check_U32 (Base.Sat_Sub_U32 (0, Max_32), 0, "Sat_Sub_U32", 2);
      Test_Support.Check_U32 (Base.Sat_Sub_U32 (Max_32, 1), Max_32 - 1, "Sat_Sub_U32", 3);

      Test_Support.Check_U64 (Base.Sat_Add_U64 (Max_64 - 15, 15), Max_64, "Sat_Add_U64", 1);
      Test_Support.Check_U64 (Base.Sat_Add_U64 (Max_64 - 15, 16), Max_64, "Sat_Add_U64", 2);
      Test_Support.Check_U64 (Base.Sat_Add_U64 (2 ** 32, 5), 2 ** 32 + 5, "Sat_Add_U64", 3);
      Test_Support.Check_U64 (Base.Sat_Sub_U64 (5, 2 ** 32), 0, "Sat_Sub_U64", 1);
      Test_Support.Check_U64 (Base.Sat_Sub_U64 (2 ** 32, 5), 2 ** 32 - 5, "Sat_Sub_U64", 2);
   end Check_Sat;

   procedure Check_Iterate is
      Want : Wuffs.Index;
      Pos  : Wuffs.Index;
   begin
      --  The example in the C source: 15, 5, 3 gives 12.
      Test_Support.Check
        (Base.Iterate_Total_Advance (15, 5, 3) = 12, "Iterate_Total_Advance example");

      --  Against counting the iterations that fit.
      for Total in Wuffs.Index range 0 .. 40 loop
         for Len in Wuffs.Index range 1 .. 9 loop
            for Advance in Wuffs.Index range 1 .. Len loop
               Pos := 0;
               while Pos + Len <= Total loop
                  Pos := Pos + Advance;
               end loop;
               Want := Pos;
               if Base.Iterate_Total_Advance (Total, Len, Advance) /= Want then
                  Test_Support.Check (False, "Iterate_Total_Advance, total", Integer (Total));
               end if;
            end loop;
         end loop;
      end loop;
      Test_Support.Check (True, "Iterate_Total_Advance ran");
   end Check_Iterate;

begin
   for I in Storage'Range loop
      Storage (I) := Wuffs.U8 (100 + (I - Storage'First));
   end loop;

   Check_Slices (Storage);
   --  A parameter that is itself a slice with other bounds.
   Check_Slices (Storage (Storage'First .. Storage'Last));
   Check_Sat;
   Check_Iterate;

   if Test_Support.Checks_Enabled then
      Check_Misuse (Storage);
      Ada.Text_IO.Put_Line ("test_runtime: checked profile: misuse checks ran");
   else
      Ada.Text_IO.Put_Line ("test_runtime: release profile: misuse checks skipped");
   end if;

   Test_Support.Finish ("test_runtime");
end Test_Runtime;
