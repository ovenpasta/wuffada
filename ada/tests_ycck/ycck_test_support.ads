--  Shared by the YCCK tests: pass/fail accounting, and the digest and
--  random number generator that the sweeps have in common with
--  oracle/oracle.c (mix, rnd, pick, fill there).

with Wuffs;
with YCCK_Oracle_Data;

package YCCK_Test_Support is

   use Wuffs;

   Passed : Natural := 0;
   Failed : Natural := 0;

   --  Counts one check; prints Name if it failed.
   procedure Check (Condition : Boolean; Name : String);

   --  Starts a sweep: resets the digest and seeds the generator.
   procedure Start (Seed : U64);

   procedure Mix (V : U64);
   procedure Mix_Bytes (Data : Bytes);

   function Rnd return U64;

   --  A random number in 0 .. N - 1.
   function Pick (N : U32) return U32;

   --  Sample data.  Mode 0: random; 1: all 0; 2: all 255; 3: all 128; 4:
   --  each 0 or 255.
   procedure Fill (Data : out Bytes; Mode : U32);

   --  A checkpoint of the current sweep (the oracle's mark): one check that
   --  the digest so far equals the next element of Marks.  The first
   --  checkpoint of a sweep that differs is reported with Label and the
   --  numbers A, B, which say which combination the sweep had just
   --  finished.
   procedure Mark
     (Marks : YCCK_Oracle_Data.Mark_Array;
      Label : String;
      A, B  : Integer := -1);

   --  Ends a sweep: one check that the digest equals Expected.
   procedure Finish (Name : String; Expected : U64);

   --  One check that a count (What, of the sweep Name) equals the oracle's.
   procedure Check_Count (Name, What : String; Got, Expected : Long_Long_Integer);

end YCCK_Test_Support;
