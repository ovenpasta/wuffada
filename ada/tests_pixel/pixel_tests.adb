--  Runs every test of the pixel part of the SPARK base library
--  (Wuffs.Base.Colors, Pixel_Formats, Pixel_Buffers, Pixel_Rows,
--  Pixel_Swizzler).
--
--  Two kinds of check:
--    * sweeps, whose expected digests were computed by upstream Wuffs' own C
--      (oracle/oracle.c, results in pixel_oracle_data.ads);
--    * explicit cases with expected values written out by hand.
--
--  Prints a summary and exits with a failure status if any check failed.

with Ada.Command_Line;
with Ada.Text_IO;
with Pixel_Test_Support;
with Test_Colors;
with Test_Formats;
with Test_Pixel_Buffer_Edges;
with Test_Pixel_Buffers;
with Test_Swizzler;

procedure Pixel_Tests is
   package Natural_IO is new Ada.Text_IO.Integer_IO (Natural);
begin
   Test_Colors;
   Test_Formats;
   Test_Pixel_Buffers;
   Test_Pixel_Buffer_Edges;
   Test_Swizzler.Run;

   Ada.Text_IO.Put ("pixel_tests: ");
   Natural_IO.Put (Pixel_Test_Support.Passed, Width => 1);
   Ada.Text_IO.Put (" passed, ");
   Natural_IO.Put (Pixel_Test_Support.Failed, Width => 1);
   Ada.Text_IO.Put_Line (" failed");
   if Pixel_Test_Support.Failed /= 0 or else Pixel_Test_Support.Passed = 0 then
      Ada.Command_Line.Set_Exit_Status (Ada.Command_Line.Failure);
   end if;
end Pixel_Tests;
