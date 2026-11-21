with Ada.Text_IO;

package body Token_Test_Support is

   use type Interfaces.Unsigned_64;
   use type Interfaces.Integer_64;

   H   : U64 := 0;
   Rng : U64 := 0;

   procedure Check (Condition : Boolean; Name : String) is
   begin
      if Condition then
         Passed := Passed + 1;
      else
         Failed := Failed + 1;
         Ada.Text_IO.Put ("FAIL: ");
         Ada.Text_IO.Put_Line (Name);
      end if;
   end Check;

   procedure Start (Seed : U64) is
   begin
      H := 16#CBF2_9CE4_8422_2325#;
      Rng := Seed;
   end Start;

   procedure Mix (V : U64) is
   begin
      H := (H xor V) * 16#0000_0100_0000_01B3#;
   end Mix;

   procedure Mix (B : Boolean) is
   begin
      Mix (if B then 1 else 0);
   end Mix;

   procedure Mix_Signed (V : Interfaces.Integer_64) is
   begin
      if V >= 0 then
         Mix (U64 (V));
      else
         Mix (U64 (V + Interfaces.Integer_64'Last + 1) + 2 ** 63);
      end if;
   end Mix_Signed;

   function Rnd return U64 is
   begin
      Rng := Rng * 6364136223846793005 + 1442695040888963407;
      return Rng xor Interfaces.Shift_Right (Rng, 31);
   end Rnd;

   procedure Finish (Name : String; Expected : U64) is
   begin
      --  (Name is the sweep's: a failed check here is a digest mismatch.)
      Check (H = Expected, Name);
   end Finish;

end Token_Test_Support;
