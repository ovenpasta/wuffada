--  Tests Wuffs.Std.M1test, which wuffs-ada generates from
--  internal/adagen/testdata/m1test.wuffs: the milestone 1 constructs that the
--  adler32 and crc32 packages do not use.
--
--  Every value that the package computes is checked against an expected
--  value here and is also printed as a trace line, "= LABEL N HEX".
--  ada/tests/crosscheck/m1test.c makes the same calls, in the same order, on
--  the C code that upstream's wuffs-c generates from the same Wuffs file and
--  prints the same trace; ada/tests/crosscheck/run.sh builds and runs it, and
--  test.sh requires the two traces to be identical.  That C trace is where
--  the expected values below come from.  Keep the two files in step.
--
--  Exits with a failure status if any check fails.

with Test_Support;
with Wuffs.Runtime.Temp_Base;
with Wuffs.Std.M1test;

procedure Test_M1 is

   use type Wuffs.Status;
   use type Wuffs.U32;
   use type Wuffs.Offset;

   package M renames Wuffs.Std.M1test;
   package Base renames Wuffs.Runtime.Temp_Base;

   W : M.Widget;

   --  Data (I) = (37 * I + 11) mod 256, placed at a non-zero offset.
   Data : Wuffs.Bytes (100 .. 110);

   type U64_List is array (Natural range <>) of Wuffs.U64;

   Want_Windows : constant U64_List (0 .. 11) :=
     [0, 0, 0, 0, 32863, 32863, 133143, 133143, 140871, 140871, 186151, 186151];

   Want_Names : constant U64_List (0 .. 3) := [32208, 32482, 32793, 33141];

   Want_Find : constant U64_List (0 .. 5) := [0, 1, 2, 2, 2, 3];

   --  The numbering of statuses that m1test.c uses too.
   Want_Status : constant U64_List (0 .. 7) := [5 => 3, 6 => 2, 7 => 1, others => 0];

   Total : Wuffs.U32 := 0;

   procedure V (What : String; N : Integer; Got, Want : Wuffs.U64);

   function Status_Number (S : Wuffs.Status) return Wuffs.U64;

   --  Traces and checks one value.
   procedure V (What : String; N : Integer; Got, Want : Wuffs.U64) is
   begin
      Test_Support.Trace (What, N, Got);
      Test_Support.Check_U64 (Got, Want, What, N);
   end V;

   function Status_Number (S : Wuffs.Status) return Wuffs.U64 is
   begin
      if S = Wuffs.Ok_Status then
         return 0;
      elsif S = M.Error_Widget_Error then
         return 1;
      elsif S = (Wuffs.Note, 16#FFFF_0002#) then
         --  The private status "@widget note".
         return 2;
      elsif S = Base.Error_Bad_Argument then
         return 3;
      elsif S = Base.Error_Initialize_Not_Called then
         return 4;
      elsif S = Base.Error_Disabled_By_Previous_Error then
         return 5;
      else
         return 99;
      end if;
   end Status_Number;

begin
   for I in Data'Range loop
      Data (I) := Wuffs.U8 ((37 * (I - Data'First) + 11) mod 256);
   end loop;

   --  Constants and statuses.
   V ("LIMIT", 0, Wuffs.U64 (M.LIMIT), 1000);
   for I in M.WEIGHTS'Range loop
      Total := Total + Wuffs.U32 (M.WEIGHTS (I));
   end loop;
   V ("sum of WEIGHTS", 0, Wuffs.U64 (Total), 250);
   Total := 0;
   Test_Support.Check
     (M.Error_Widget_Error = (Wuffs.Error, 16#FFFF_0001#), "status ""#widget error""");

   --  Before Initialize, everything is a no-op.
   V ("loops before initialize", 0, Wuffs.U64 (M.Loops (W, 5)), 0);
   V ("use_small before initialize", 0, Status_Number (M.Use_Small (W, 0)), 4);
   V ("toggle_u32 before initialize", 0, Wuffs.U64 (M.Toggle_U32 (W)), 0);

   M.Initialize (W);

   --  Labeled loops, break, continue, loop assertions.
   V ("loops", 0, Wuffs.U64 (M.Loops (W, 0)), 0);
   V ("loops", 1, Wuffs.U64 (M.Loops (W, 1)), 136);
   V ("loops", 2, Wuffs.U64 (M.Loops (W, 2)), 136);
   V ("loops", 5, Wuffs.U64 (M.Loops (W, 5)), 408);
   V ("loops", 999, Wuffs.U64 (M.Loops (W, 999)), 20002);
   V ("loops", 1000, Wuffs.U64 (M.Loops (W, 1000)), 20002);
   V ("loops", 5000, Wuffs.U64 (M.Loops (W, 5000)), 20002);
   V ("loops", -1, Wuffs.U64 (M.Loops (W, 16#FFFF_FFFF#)), 20002);

   --  Modular and saturating arithmetic, shifts, conversions, if-else chains.
   --  The flag field is False here.
   V ("arith", 1, M.Arith (W, 0, 0, 0), 16#5555_AE14#);
   V ("arith", 2, M.Arith (W, 1, 2, 3), 16#3_0000_58C2#);
   V ("arith", 3, M.Arith (W, 6, 2, 0), 16#D555_ADD2#);
   V ("toggle_u32", 1, Wuffs.U64 (M.Toggle_U32 (W)), 1);
   V ("arith", 4, M.Arith (W, 1, 2, 3), 16#3_0000_58C2#);
   V ("arith", 5, M.Arith (W, 16#FFFF_FFFF#, 16#FFFF_FFFF#, 7), 16#1555_5555_AAAA_FF58#);
   V ("arith", 6, M.Arith (W, 100, 7, 9), 16#8_5555_AD12#);
   V ("arith", 7, M.Arith (W, 12, 0, 0), 16#1_0000_5706#);
   V ("arith", 8, M.Arith (W, 4, 0, 0), 16#5555_AE12#);
   V ("arith", 9, M.Arith (W, 3, 1, 0), 16#5555_AC92#);
   V ("arith", 10, M.Arith (W, 6, 2, 0), 9);
   V ("toggle_u32", 2, Wuffs.U64 (M.Toggle_U32 (W)), 0);

   --  Private functions with refined parameters and results, a discarded
   --  result, array fields, statuses.
   for I in 0 .. 7 loop
      V ("use_small", I, Status_Number (M.Use_Small (W, Wuffs.U32 (I) + 8)), Want_Status (I));
      Total := Total + Wuffs.U32 (I);
      V ("get_total", I, Wuffs.U64 (M.Get_Total (W)), Wuffs.U64 (Total));
   end loop;
   --  hist[d] = 1 for each d in 0 .. 7, and hist[d & 3] ~sat+= 200 twice.
   for I in 0 .. 7 loop
      V ("get_hist", I, Wuffs.U64 (M.Get_Hist (W, Wuffs.U32 (I))), (if I < 4 then 255 else 1));
   end loop;

   --  Slices: parameters, handles, sub-slices passed down, iterate loops with
   --  overlapping windows, constant tables.
   for L in Want_Windows'Range loop
      V ("windows",
         L,
         Wuffs.U64 (M.Windows (W, Data (Data'First .. Data'First + Wuffs.Index (L) - 1))),
         Want_Windows (L));
   end loop;

   --  Assigning to an argument; narrowed local variables.
   V ("countdown", 10, Wuffs.U64 (M.Countdown (W, 10)), 10);
   V ("countdown", 0, Wuffs.U64 (M.Countdown (W, 0)), 0);
   V ("narrow", 0, Wuffs.U64 (M.Narrow (W, 0)), 200);
   V ("narrow", 100, Wuffs.U64 (M.Narrow (W, 100)), 300);
   V ("narrow", 101, Wuffs.U64 (M.Narrow (W, 101)), 202);
   V ("narrow", 255, Wuffs.U64 (M.Narrow (W, 255)), 510);
   V ("narrow", 256, Wuffs.U64 (M.Narrow (W, 256)), 200);
   V ("narrow", 511, Wuffs.U64 (M.Narrow (W, 511)), 510);

   --  Wuffs names that are spelled like generator-made Ada names.  (The
   --  total field is 28 and hist is 255 x 4, 1 x 4 at this point.)
   for L in Want_Names'Range loop
      V ("names",
         L,
         M.Names (W, Data (Data'First .. Data'First + Wuffs.Index (L) - 1)),
         Want_Names (L));
   end loop;
   V ("call_loops", 0, Wuffs.U64 (M.Call_Loops (W, 0)), 60);
   V ("call_loops", 500, Wuffs.U64 (M.Call_Loops (W, 500)), 588);
   V ("get_total", 99, Wuffs.U64 (M.Get_Total (W)), 52);

   --  Functions whose bodies do not end with a return statement.
   for I in Want_Find'Range loop
      V ("find", I, Wuffs.U64 (M.Find (W, Wuffs.U32 (I))), Want_Find (I));
   end loop;
   V ("find", 1000, Wuffs.U64 (M.Find (W, 1000)), 32);
   V ("pick", 11, Wuffs.U64 (M.Pick (W, 11)), 1);
   V ("pick", 10, Wuffs.U64 (M.Pick (W, 10)), 2);
   V ("pick", 6, Wuffs.U64 (M.Pick (W, 6)), 2);
   V ("pick", 5, Wuffs.U64 (M.Pick (W, 5)), 3);
   V ("pick", 0, Wuffs.U64 (M.Pick (W, 0)), 3);

   --  A public function's refined argument is checked at run time: a bad one
   --  disables the object, as in C.
   M.Set_Count (W, 500);
   V ("get_count", 500, Wuffs.U64 (M.Get_Count (W)), 500);
   M.Set_Count (W, 1000);
   V ("get_count", 1000, Wuffs.U64 (M.Get_Count (W)), 1000);
   M.Set_Count (W, 1001);
   V ("get_count", 1001, Wuffs.U64 (M.Get_Count (W)), 1000);
   M.Set_Count (W, 1);
   V ("get_count", 1, Wuffs.U64 (M.Get_Count (W)), 1000);
   V ("loops when disabled", 0, Wuffs.U64 (M.Loops (W, 5)), 0);
   V ("use_small when disabled", 0, Status_Number (M.Use_Small (W, 0)), 5);

   --  Initialize recovers, and zeroes every field.
   M.Initialize (W);
   V ("get_count after initialize", 0, Wuffs.U64 (M.Get_Count (W)), 0);
   V ("get_total after initialize", 0, Wuffs.U64 (M.Get_Total (W)), 0);
   for I in 0 .. 7 loop
      V ("get_hist after initialize", I, Wuffs.U64 (M.Get_Hist (W, Wuffs.U32 (I))), 0);
   end loop;
   V ("loops after initialize", 0, Wuffs.U64 (M.Loops (W, 5)), 408);

   Test_Support.Finish ("test_m1");
end Test_M1;
