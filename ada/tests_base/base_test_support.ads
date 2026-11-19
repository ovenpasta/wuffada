--  Shared by the base library tests: pass/fail accounting, and the digest
--  and random number generator that the sweeps have in common with
--  oracle/oracle.c (mix, rnd, fill there).

with Wuffs;

package Base_Test_Support is

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

   --  Ends a sweep: one check that the digest equals Expected.
   procedure Finish (Name : String; Expected : U64);

end Base_Test_Support;
