--  Runs every test of the SPARK base library (Wuffs.Base and children).
--
--  Two kinds of check:
--    * sweeps, whose expected digests were computed by upstream Wuffs' own C
--      base library (oracle/oracle.c, results in base_oracle_data.ads);
--    * explicit cases with expected values written out by hand: edge cases
--      and the places where the C behaviour is undefined.
--
--  Prints a summary and exits with a failure status if any check failed.

with Ada.Command_Line;
with Ada.Text_IO;
with Base_Test_Support;
with Test_Endian;
with Test_IO;
with Test_Ints;
with Test_Ranges;
with Test_Slices;
with Test_Status;

procedure Base_Tests is
   package Natural_IO is new Ada.Text_IO.Integer_IO (Natural);
begin
   Test_Status;
   Test_Ints;
   Test_Endian;
   Test_Ranges;
   Test_Slices;
   Test_IO;

   Ada.Text_IO.Put ("base_tests: ");
   Natural_IO.Put (Base_Test_Support.Passed, Width => 1);
   Ada.Text_IO.Put (" passed, ");
   Natural_IO.Put (Base_Test_Support.Failed, Width => 1);
   Ada.Text_IO.Put_Line (" failed");
   if Base_Test_Support.Failed /= 0 or else Base_Test_Support.Passed = 0 then
      Ada.Command_Line.Set_Exit_Status (Ada.Command_Line.Failure);
   end if;
end Base_Tests;
