--  Part of wuffada (wuffs-ada: Wuffs to Ada).
--  SPDX-License-Identifier: Apache-2.0 OR MIT

--  Tests every wrapper of Wuffs.Runtime.X86.SSE42 and AVX2 (one per Wuffs
--  x86 cpu_arch method that the generator can emit; the list is
--  x86_methods.list) against a C oracle: oracle/x86_oracle.c computes the
--  same thing with the _mm_* / _mm256_* intrinsic that upstream's C back-end
--  calls for each method, over the same inputs, and oracle/regen.sh checks
--  its digests in as X86_Oracle_Data (gcc and clang agreeing).  Needs a CPU
--  with SSE4.2, PCLMUL, POPCNT and AVX2.
--
--  The inputs (Input below, input() in the oracle): 96 vectors, 26 of them
--  of repeated edge-case lanes (0, -1, the saturation bounds 7FFF/8000 and
--  7F/80, sign bits) and the rest pseudo-random; each method with every
--  immediate in X86_Methods.Imms (shift counts at and beyond the lane width,
--  shuffle and permutation masks with the high bits set, every carry-less
--  multiply selector, every extract and insert index, and every value that
--  Wuffs' standard library uses); the loads and the store at every offset
--  0 .. 63 of a 64-aligned buffer (the store's whole buffer is digested, so
--  a write outside its 16 bytes shows).  A digest is taken after every 16
--  inputs; a mismatch names the method and the inputs.
--
--  In the checked profile, it also checks that a load from a slice shorter
--  than the method's length raises Assertion_Error (the precondition that
--  stands in for the Wuffs checker's proof).

with Ada.Assertions;
with Ada.Command_Line;
with Ada.Text_IO;
with Interfaces;
with Wuffs.Runtime.X86.SSE42;
with X86_Methods;
with X86_Oracle_Data;
with X86_Test_Cases;

procedure Test_X86 is

   use Interfaces;
   use X86_Methods;
   use X86_Test_Cases;
   use type Wuffs.Index;

   package Method_IO is new Ada.Text_IO.Enumeration_IO (Method);

   Checks, Failures : Natural := 0;

   Patterns : constant array (0 .. 12) of Unsigned_16 :=
     [16#0000#, 16#FFFF#, 16#7FFF#, 16#8000#, 16#7F7F#, 16#8080#, 16#0001#,
      16#00FF#, 16#FF00#, 16#8001#, 16#7FFE#, 16#FF7F#, 16#80FF#];

   function Input (N : Natural) return Bytes32;
   procedure Eat (Digest : in out Unsigned_64; B : Unsigned_8);
   procedure Test_Methods;
   procedure Test_Preconditions;

   --  The inputs, as input() in oracle/x86_oracle.c.
   function Input (N : Natural) return Bytes32 is
      R : Bytes32;
      S : Unsigned_64;
   begin
      if N < 26 then
         for J in 0 .. 15 loop
            declare
               P : constant Unsigned_16 := Patterns (if N < 13 then N else (N + J) mod 13);
            begin
               R (2 * J) := Unsigned_8 (P and 16#FF#);
               R (2 * J + 1) := Unsigned_8 (Shift_Right (P, 8));
            end;
         end loop;
         return R;
      end if;
      S := 16#9E37_79B9_7F4A_7C15# * Unsigned_64 (N + 1);
      for J in R'Range loop
         S := S xor Shift_Left (S, 13);
         S := S xor Shift_Right (S, 7);
         S := S xor Shift_Left (S, 17);
         R (J) := Unsigned_8 (Shift_Right (S, 24) and 16#FF#);
      end loop;
      return R;
   end Input;

   --  FNV-1a, as eat() in the oracle.
   procedure Eat (Digest : in out Unsigned_64; B : Unsigned_8) is
   begin
      Digest := (Digest xor Unsigned_64 (B)) * 16#0100_0000_01B3#;
   end Eat;

   procedure Test_Methods is
   begin
      for I in Byte_Buf'Range loop
         Byte_Buf (I) := Unsigned_8 ((I * 37 + 11) mod 256);
      end loop;
      for I in U16_Buf'Range loop
         U16_Buf (I) := Unsigned_16 ((I * 4099 + 7) mod 65536);
      end loop;
      for M in Method loop
         declare
            Digest : Unsigned_64 := 16#CBF2_9CE4_8422_2325#;
         begin
            for N in 0 .. Number_Of_Inputs - 1 loop
               declare
                  A : constant Bytes32 := Input (N);
                  B : constant Bytes32 := Input ((N * 7 + 3) mod Number_Of_Inputs);
                  C : constant Bytes32 := Input ((N * 5 + 11) mod Number_Of_Inputs);
               begin
                  for K in 1 .. Natural'Max (1, Imms (M).N) loop
                     declare
                        Imm : constant Integer := (if Imms (M).N = 0 then 0 else Imms (M).V (K));
                        R   : Bytes32;
                     begin
                        if M = Store_Slice128 then
                           Store_Buf := [others => 16#A5#];
                           R := Apply (M, Imm, N, A, B, C);
                           for X of Store_Buf loop
                              Eat (Digest, X);
                           end loop;
                        else
                           R := Apply (M, Imm, N, A, B, C);
                           for X of R loop
                              Eat (Digest, X);
                           end loop;
                        end if;
                     end;
                  end loop;
               end;
               if (N + 1) mod Checkpoint_Every = 0 then
                  Checks := Checks + 1;
                  if Digest /= X86_Oracle_Data.Expected (M) ((N + 1) / Checkpoint_Every) then
                     Failures := Failures + 1;
                     Ada.Text_IO.Put (Ada.Text_IO.Standard_Error, "FAIL: ");
                     Method_IO.Put (Ada.Text_IO.Standard_Error, M);
                     Ada.Text_IO.Put
                       (Ada.Text_IO.Standard_Error, " differs from the C oracle at inputs");
                     Ada.Text_IO.Put
                       (Ada.Text_IO.Standard_Error, Integer'Image (N + 1 - Checkpoint_Every));
                     Ada.Text_IO.Put (Ada.Text_IO.Standard_Error, " ..");
                     Ada.Text_IO.Put_Line (Ada.Text_IO.Standard_Error, Integer'Image (N));
                     exit;
                  end if;
               end if;
            end loop;
         end;
      end loop;
   end Test_Methods;

   procedure Test_Preconditions is
      Assertions_On : Boolean := False;
      Buf : constant Wuffs.Bytes (0 .. 31) := [others => 1];
      V   : Wuffs.Runtime.X86.M128I;
   begin
      begin
         pragma Assert (False);
      exception
         when Ada.Assertions.Assertion_Error =>
            Assertions_On := True;
      end;
      if not Assertions_On then
         Ada.Text_IO.Put_Line
           (Ada.Text_IO.Standard_Error, "test_x86: release profile: preconditions not tested");
         return;
      end if;
      Checks := Checks + 1;
      begin
         V := Wuffs.Runtime.X86.SSE42.Make_M128i_Slice128 (Buf (3 .. 17));
         Failures := Failures + 1;
         Ada.Text_IO.Put_Line
           (Ada.Text_IO.Standard_Error,
            "FAIL: make_m128i_slice128 of 15 bytes did not raise" & Integer_64'Image (V (0)));
      exception
         when Ada.Assertions.Assertion_Error =>
            null;
      end;
   end Test_Preconditions;

begin
   Test_Methods;
   Test_Preconditions;
   Ada.Text_IO.Put ("test_x86: methods:");
   Ada.Text_IO.Put (Integer'Image (Method'Pos (Method'Last) + 1));
   Ada.Text_IO.Put (", digests compared:");
   Ada.Text_IO.Put (Checks'Image);
   Ada.Text_IO.Put (", failures:");
   Ada.Text_IO.Put_Line (Failures'Image);
   if Failures /= 0 then
      Ada.Text_IO.Put_Line ("test_x86: FAIL");
      Ada.Command_Line.Set_Exit_Status (Ada.Command_Line.Failure);
   else
      Ada.Text_IO.Put_Line ("test_x86: PASS");
   end if;
end Test_X86;
