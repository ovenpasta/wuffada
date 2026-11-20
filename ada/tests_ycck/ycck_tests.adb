--  Runs every test of the YCbCr / YCCK part of the SPARK base library
--  (Wuffs.Base.Color_YCC, Wuffs.Base.Pixel_Swizzler_YCCK).
--
--  Two kinds of check:
--    * sweeps, whose expected digests were computed by upstream Wuffs' own C
--      (oracle/oracle.c, results in ycck_oracle_data.ads);
--    * explicit cases with expected values written out by hand.
--
--  Prints a summary and exits with a failure status if any check failed.

with Ada.Command_Line;
with Ada.Text_IO;
with Test_YCCK;
with Test_YCCK_Cases;
with YCCK_Test_Support;

procedure YCCK_Tests is
begin
   Test_YCCK_Cases;
   Test_YCCK.Run;

   Ada.Text_IO.Put_Line
     ("ycck_tests:" & YCCK_Test_Support.Passed'Image & " passed,"
      & YCCK_Test_Support.Failed'Image & " failed");
   if YCCK_Test_Support.Failed /= 0 or else YCCK_Test_Support.Passed = 0 then
      Ada.Command_Line.Set_Exit_Status (Ada.Command_Line.Failure);
   end if;
end YCCK_Tests;
