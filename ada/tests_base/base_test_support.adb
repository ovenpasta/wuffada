with Ada.Text_IO;
with Interfaces;

package body Base_Test_Support is

   use type Interfaces.Unsigned_64;

   Digest : U64 := 0;
   State  : U64 := 0;

   -----------
   -- Check --
   -----------

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

   -----------
   -- Start --
   -----------

   procedure Start (Seed : U64) is
   begin
      Digest := 16#CBF2_9CE4_8422_2325#;
      State := Seed;
   end Start;

   ---------
   -- Mix --
   ---------

   procedure Mix (V : U64) is
   begin
      Digest := (Digest xor V) * 16#100_0000_01B3#;
   end Mix;

   procedure Mix (B : Boolean) is
   begin
      Mix (U64'(if B then 1 else 0));
   end Mix;

   ---------------
   -- Mix_Bytes --
   ---------------

   procedure Mix_Bytes (Data : Bytes) is
   begin
      for B of Data loop
         Mix (U64 (B));
      end loop;
   end Mix_Bytes;

   ---------
   -- Rnd --
   ---------

   function Rnd return U64 is
   begin
      State := State * 6364136223846793005 + 1442695040888963407;
      return State xor Interfaces.Shift_Right (State, 31);
   end Rnd;

   ----------
   -- Fill --
   ----------

   procedure Fill (Data : out Bytes) is
   begin
      for B of Data loop
         B := U8 (Interfaces.Shift_Right (Rnd, 56));
      end loop;
   end Fill;

   ------------
   -- Finish --
   ------------

   procedure Finish (Name : String; Expected : U64) is
   begin
      Check (Digest = Expected, Name);
   end Finish;

end Base_Test_Support;
