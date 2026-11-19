with Ada.Assertions;
with Ada.Command_Line;
with Ada.Text_IO;
with Interfaces;

package body Test_Support is

   use type Wuffs.U32;
   use type Wuffs.U64;

   Hidden_Zero : Integer := 0
   with Volatile, Export, Convention => C, External_Name => "wuffada_test_hidden_zero";

   procedure Put_Failure (What : String; N : Integer; Detail : String);

   procedure Put_Failure (What : String; N : Integer; Detail : String) is
   begin
      Failures := Failures + 1;
      Ada.Text_IO.Put ("FAIL: ");
      Ada.Text_IO.Put (What);
      if N >= 0 then
         Ada.Text_IO.Put (Integer'Image (N));
      end if;
      if Detail /= "" then
         Ada.Text_IO.Put (", ");
         Ada.Text_IO.Put (Detail);
      end if;
   end Put_Failure;

   procedure Check (OK : Boolean; What : String; N : Integer := -1; Detail : String := "") is
   begin
      Checks := Checks + 1;
      if not OK then
         Put_Failure (What, N, Detail);
         Ada.Text_IO.New_Line;
      end if;
   end Check;

   procedure Check_U32
     (Got, Want : Wuffs.U32; What : String; N : Integer := -1; Detail : String := "") is
   begin
      Checks := Checks + 1;
      if Got /= Want then
         Put_Failure (What, N, Detail);
         Ada.Text_IO.Put (": got 0x");
         Put_Hex (Got);
         Ada.Text_IO.Put (", want 0x");
         Put_Hex (Want);
         Ada.Text_IO.New_Line;
      end if;
   end Check_U32;

   procedure Check_U64
     (Got, Want : Wuffs.U64; What : String; N : Integer := -1; Detail : String := "") is
   begin
      Checks := Checks + 1;
      if Got /= Want then
         Put_Failure (What, N, Detail);
         Ada.Text_IO.Put (": got 0x");
         Put_Hex (Wuffs.U32 (Interfaces.Shift_Right (Got, 32)));
         Put_Hex (Wuffs.U32 (Got and 16#FFFF_FFFF#));
         Ada.Text_IO.Put (", want 0x");
         Put_Hex (Wuffs.U32 (Interfaces.Shift_Right (Want, 32)));
         Put_Hex (Wuffs.U32 (Want and 16#FFFF_FFFF#));
         Ada.Text_IO.New_Line;
      end if;
   end Check_U64;

   function Checks_Enabled return Boolean is
   begin
      pragma Assert (Opaque (0) /= 0);
      return False;
   exception
      when Ada.Assertions.Assertion_Error =>
         return True;
   end Checks_Enabled;

   function Opaque (X : Integer) return Integer is
   begin
      return X + Hidden_Zero;
   end Opaque;

   procedure Trace (What : String; N : Integer; Value : Wuffs.U64) is
   begin
      Ada.Text_IO.Put ("= ");
      Ada.Text_IO.Put (What);
      if N < 0 then
         Ada.Text_IO.Put (" -");
      else
         Ada.Text_IO.Put (" ");
      end if;
      declare
         Text  : String (1 .. 12);
         First : Natural := Text'Last + 1;
         Rest  : Natural := abs N;
      begin
         loop
            First := First - 1;
            Text (First) := Character'Val (Character'Pos ('0') + Rest mod 10);
            Rest := Rest / 10;
            exit when Rest = 0;
         end loop;
         Ada.Text_IO.Put (Text (First .. Text'Last));
      end;
      Ada.Text_IO.Put (" ");
      Put_Hex (Wuffs.U32 (Interfaces.Shift_Right (Value, 32)));
      Put_Hex (Wuffs.U32 (Value and 16#FFFF_FFFF#));
      Ada.Text_IO.New_Line;
   end Trace;

   procedure Put_Hex (X : Wuffs.U32) is
      Digit : constant String := "0123456789ABCDEF";
      Text  : String (1 .. 8);
      V     : Wuffs.U32 := X;
   begin
      for I in reverse Text'Range loop
         Text (I) := Digit (Natural (V and 15) + 1);
         V := Interfaces.Shift_Right (V, 4);
      end loop;
      Ada.Text_IO.Put (Text);
   end Put_Hex;

   procedure Finish (Name : String) is
   begin
      Ada.Text_IO.Put (Name);
      Ada.Text_IO.Put (":");
      Ada.Text_IO.Put (Natural'Image (Checks));
      Ada.Text_IO.Put (" checks,");
      Ada.Text_IO.Put (Natural'Image (Failures));
      Ada.Text_IO.Put_Line (" failures");
      Ada.Text_IO.Put (Name);
      if Failures /= 0 or else Checks = 0 then
         Ada.Text_IO.Put_Line (": FAIL");
         Ada.Command_Line.Set_Exit_Status (Ada.Command_Line.Failure);
      else
         Ada.Text_IO.Put_Line (": PASS");
      end if;
   end Finish;

end Test_Support;
