--  Shared by the pixel tests: pass/fail accounting, and the digest
--  and random number generator that the sweeps have in common with
--  oracle/oracle.c (mix, rnd, fill there).

with Pixel_Oracle_Data;
with Wuffs;

package Pixel_Test_Support is

   use Wuffs;

   Passed : Natural := 0;
   Failed : Natural := 0;

   --  Counts one check; prints Name if it failed.
   procedure Check (Condition : Boolean; Name : String);

   --  Starts a sweep: resets the digest and seeds the generator.
   procedure Start (Seed : U64);

   procedure Mix (V : U64);
   procedure Mix (B : Boolean);
   procedure Mix_Bytes (Data : Bytes);

   function Rnd return U64;
   procedure Fill (Data : out Bytes);

   --  The 34 named pixel formats in the order of the oracle's FORMATS; the
   --  first Num_Whole have a whole number of bytes per pixel and one plane.
   Num_Formats : constant := 34;
   Num_Whole   : constant := 25;
   Formats : constant array (0 .. Num_Formats - 1) of U32 :=
     [16#0200_0008#, 16#2000_0008#, 16#2000_000B#, 16#2010_000B#, 16#2100_0088#,
      16#2200_0088#, 16#3000_8888#, 16#8104_0008#, 16#8204_0008#, 16#8304_0008#,
      16#8000_0565#, 16#8000_0888#, 16#8100_8888#, 16#8100_BBBB#, 16#8200_8888#,
      16#8200_BBBB#, 16#8300_8888#, 16#9000_8888#, 16#A000_0888#, 16#A100_8888#,
      16#A100_BBBB#, 16#A200_8888#, 16#A200_BBBB#, 16#A300_8888#, 16#B000_8888#,
      16#4002_0888#, 16#4103_8888#, 16#5003_8888#, 16#6002_0888#, 16#6103_8888#,
      16#7003_8888#, 16#C002_0888#, 16#D003_8888#, 16#0000_0000#];

   --  The oracle's status_code.
   function Code (S : Status) return U64;

   --  A checkpoint of the current sweep (the oracle's mark): compares the
   --  digest so far with the next element of Marks.  The first checkpoint
   --  of a sweep that differs is reported with Label and the numbers A, B,
   --  C, which say which combination the sweep had just finished.
   procedure Mark
     (Marks   : Pixel_Oracle_Data.Mark_Array;
      Label   : String;
      A, B, C : Integer := -1);

   --  Ends a sweep: one check that the digest equals Expected.
   procedure Finish (Name : String; Expected : U64);

end Pixel_Test_Support;
