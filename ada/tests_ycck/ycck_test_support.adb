with Ada.Text_IO;
with Interfaces;

package body YCCK_Test_Support is

   use type Interfaces.Unsigned_8;
   use type Interfaces.Unsigned_64;

   Digest : U64 := 0;
   State  : U64 := 0;

   --  Checkpoints of the current sweep.
   Next_Mark     : Natural := 0;
   Mark_Mismatch : Boolean := False;

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
   -- Pick --
   ----------

   function Pick (N : U32) return U32 is
     (U32 (Interfaces.Shift_Right (Rnd, 33) mod U64 (N)));

   ----------
   -- Fill --
   ----------

   procedure Fill (Data : out Bytes; Mode : U32) is
      R : U8;
   begin
      for B of Data loop
         R := U8 (Interfaces.Shift_Right (Rnd, 56));
         B := (case Mode is
                 when 0      => R,
                 when 1      => 0,
                 when 2      => 255,
                 when 3      => 128,
                 when others => (if (R and 1) /= 0 then 255 else 0));
      end loop;
   end Fill;

   ----------
   -- Mark --
   ----------

   procedure Mark
     (Marks : YCCK_Oracle_Data.Mark_Array;
      Label : String;
      A, B  : Integer := -1)
   is
      Same : constant Boolean :=
        Next_Mark in Marks'Range and then Marks (Next_Mark) = Digest;
   begin
      --  After the first difference the digest stays different; only the
      --  first is a failure worth a line.
      if Same or else Mark_Mismatch then
         Passed := Passed + 1;
      else
         Mark_Mismatch := True;
         Failed := Failed + 1;
         Ada.Text_IO.Put ("FAIL: ");
         Ada.Text_IO.Put (Label);
         Ada.Text_IO.Put (" (first difference from the oracle:");
         if A >= 0 then
            Ada.Text_IO.Put (A'Image);
         end if;
         if B >= 0 then
            Ada.Text_IO.Put (B'Image);
         end if;
         Ada.Text_IO.Put (", checkpoint");
         Ada.Text_IO.Put (Next_Mark'Image);
         Ada.Text_IO.Put_Line (")");
      end if;
      Next_Mark := Next_Mark + 1;
   end Mark;

   ------------
   -- Finish --
   ------------

   procedure Finish (Name : String; Expected : U64) is
   begin
      Check (Digest = Expected, Name);
   end Finish;

   -----------------
   -- Check_Count --
   -----------------

   procedure Check_Count (Name, What : String; Got, Expected : Long_Long_Integer) is
   begin
      if Got = Expected then
         Passed := Passed + 1;
      else
         Failed := Failed + 1;
         Ada.Text_IO.Put ("FAIL: ");
         Ada.Text_IO.Put (Name);
         Ada.Text_IO.Put (" ");
         Ada.Text_IO.Put (What);
         Ada.Text_IO.Put (": got");
         Ada.Text_IO.Put (Got'Image);
         Ada.Text_IO.Put (", oracle");
         Ada.Text_IO.Put_Line (Expected'Image);
      end if;
   end Check_Count;

end YCCK_Test_Support;
