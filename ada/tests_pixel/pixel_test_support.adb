with Ada.Text_IO;
with Interfaces;
with Wuffs.Base;

package body Pixel_Test_Support is

   use type Interfaces.Unsigned_64;

   Digest : U64 := 0;
   State  : U64 := 0;

   --  Checkpoints of the current sweep.
   Next_Mark     : Natural := 0;
   Mark_Mismatch : Boolean := False;

   --  Prints " V" (V >= 0) in decimal.
   procedure Put_Number (V : Natural);

   procedure Put_Number (V : Natural) is
      Text : String (1 .. 12) := [others => ' '];
      Pos  : Natural := Text'Last;
      Rest : Natural := V;
   begin
      loop
         Text (Pos) := Character'Val (Character'Pos ('0') + Rest mod 10);
         Rest := Rest / 10;
         exit when Rest = 0;
         Pos := Pos - 1;
      end loop;
      Ada.Text_IO.Put (Text (Pos - 1 .. Text'Last));
   end Put_Number;

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
      Next_Mark := 0;
      Mark_Mismatch := False;
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

   ----------
   -- Mark --
   ----------

   procedure Mark
     (Marks   : Pixel_Oracle_Data.Mark_Array;
      Label   : String;
      A, B, C : Integer := -1)
   is
   begin
      if not Mark_Mismatch
        and then (Next_Mark not in Marks'Range or else Marks (Next_Mark) /= Digest)
      then
         Mark_Mismatch := True;
         Ada.Text_IO.Put ("  first difference from the oracle: ");
         Ada.Text_IO.Put (Label);
         declare
            Values : constant array (1 .. 3) of Integer := [A, B, C];
         begin
            for V of Values loop
               if V >= 0 then
                  Put_Number (V);
               end if;
            end loop;
         end;
         Ada.Text_IO.New_Line;
      end if;
      Next_Mark := Next_Mark + 1;
   end Mark;

   ----------
   -- Code --
   ----------

   function Code (S : Status) return U64 is
     (if S = Ok_Status then 0
      elsif S = Wuffs.Base.Error_Bad_Argument then 1
      elsif S = Wuffs.Base.Error_Bad_Argument_Length_Too_Short then 2
      elsif S = Wuffs.Base.Error_Unsupported_Option then 3
      elsif S = Wuffs.Base.Error_Unsupported_Pixel_Swizzler_Option then 4
      else 99);

   ------------
   -- Finish --
   ------------

   procedure Finish (Name : String; Expected : U64) is
   begin
      Check (Digest = Expected, Name);
   end Finish;

end Pixel_Test_Support;
