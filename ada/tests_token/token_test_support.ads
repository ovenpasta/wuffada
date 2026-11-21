--  Shared by the token library tests: pass/fail accounting, and the digest
--  and random number generator that the sweeps have in common with
--  oracle/oracle.c (begin, mix, rnd there).

with Interfaces;
with Wuffs;

package Token_Test_Support is

   use Wuffs;

   Passed : Natural := 0;
   Failed : Natural := 0;

   --  Counts one check; prints Name if it failed.
   procedure Check (Condition : Boolean; Name : String);

   --  Starts a sweep: resets the digest and seeds the generator.
   procedure Start (Seed : U64);

   procedure Mix (V : U64);
   procedure Mix (B : Boolean);

   --  C's (uint64_t) of an int64_t.
   procedure Mix_Signed (V : Interfaces.Integer_64);

   function Rnd return U64;

   --  Ends a sweep: one check that the digest equals Expected.
   procedure Finish (Name : String; Expected : U64);

end Token_Test_Support;
