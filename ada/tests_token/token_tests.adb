--  Runs every test of the SPARK token library (Wuffs.Base.Tokens and
--  Wuffs.Base.UTF8, ada/src/token).
--
--  Two kinds of check:
--    * sweeps, whose expected digests were computed by upstream Wuffs' own C
--      (oracle/oracle.c, results in token_oracle_data.ads);
--    * explicit cases with expected values worked out by hand.
--
--  Prints a summary and exits with a failure status if any check failed.

with Ada.Command_Line;
with Ada.Text_IO;
with Test_Token_Cases;
with Test_Token_Sweeps;
with Test_UTF8_Sweeps;
with Token_Test_Support;

procedure Token_Tests is
   package Natural_IO is new Ada.Text_IO.Integer_IO (Natural);
begin
   Test_Token_Cases;
   Test_Token_Sweeps;
   Test_UTF8_Sweeps;

   Ada.Text_IO.Put ("token_tests: ");
   Natural_IO.Put (Token_Test_Support.Passed, Width => 1);
   Ada.Text_IO.Put (" passed, ");
   Natural_IO.Put (Token_Test_Support.Failed, Width => 1);
   Ada.Text_IO.Put_Line (" failed");
   if Token_Test_Support.Failed /= 0 or else Token_Test_Support.Passed = 0 then
      Ada.Command_Line.Set_Exit_Status (Ada.Command_Line.Failure);
   end if;
end Token_Tests;
