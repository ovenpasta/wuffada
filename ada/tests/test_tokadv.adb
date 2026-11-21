--  Part of wuffada (wuffs-ada: Wuffs to Ada).
--  SPDX-License-Identifier: Apache-2.0 OR MIT

--  Runs the test-only package tokadv (internal/adagen/testdata/tokadv.wuffs:
--  adversarial token-writer coroutines) over pseudo-random input, under
--  several schedules (source buffers as short as one byte, token buffers as
--  short as one token, compacted between calls), and prints a trace line
--  per run.  ada/tests/crosscheck/tokadv.c makes the same calls on the C
--  that upstream's wuffs-c generates from the same file; test.sh requires
--  the two traces to be identical.  Keep the two files in step.

with Ada.Text_IO;
with Interfaces;
with Test_Support;
with Tokadv_Support;
with Wuffs.Base.IO;
with Wuffs.Base.Tokens;
with Wuffs.Std.Tokadv;

procedure Test_Tokadv is

   use type Wuffs.U8;
   use type Wuffs.U32;
   use type Wuffs.U64;
   use type Wuffs.Index;
   use type Wuffs.Status;

   package IO renames Wuffs.Base.IO;
   package Tok renames Wuffs.Base.Tokens;
   package T renames Wuffs.Std.Tokadv;

   Len       : constant := 64;
   Tok_Cap   : constant := 4096;
   Num_Seeds : constant := 64;
   Max_Calls : constant := 3000;

   type Schedule is record
      Src : Wuffs.Index;
      Dst : Wuffs.Index;
   end record;

   Schedules : constant array (1 .. 9) of Schedule :=
     [(0, 0), (1, 0), (0, 1), (1, 1), (2, 3), (3, 2), (12, 1), (13, 2), (5, 7)];

   Input   : Wuffs.Bytes (0 .. Len - 1);
   Src     : Wuffs.Bytes (10 .. 10 + Len - 1);
   Tokens  : Wuffs.U64_Array renames Tokadv_Support.Tokens;
   Workbuf : Wuffs.Bytes (1 .. 8) := [others => 0];
   Thing   : T.Thing renames Tokadv_Support.Thing;

   Runs : Natural := 0;

   function Status_Number (S : Wuffs.Status) return Wuffs.U64 is
     (if S = Wuffs.Ok_Status then 0
      elsif S = Wuffs.Base.Suspension_Short_Read then 1
      elsif S = Wuffs.Base.Suspension_Short_Write then 2
      elsif S = T.Error_Bad_Thing then 3
      elsif S = Wuffs.Base.Error_Interleaved_Coroutine_Calls then 5
      elsif S = Wuffs.Base.Error_Disabled_By_Previous_Error then 6
      else 9);

   procedure Fill (Seed : Wuffs.U32);

   procedure Hash_64 (H : in out Wuffs.U64; X : Wuffs.U64);

   procedure Put_Number (X : Wuffs.U64);

   procedure Put_Hex_64 (X : Wuffs.U64);

   procedure Run (F : Positive; Seed : Wuffs.U32; S : Schedule);

   procedure Fill (Seed : Wuffs.U32) is
      X : Wuffs.U32 := Seed * 2_654_435_761 + 12_345;
      B : Wuffs.U8;
   begin
      for I in Input'Range loop
         X := X * 1_103_515_245 + 12_345;
         B := Wuffs.U8 (Interfaces.Shift_Right (X, 16) and 16#FF#);
         if Seed mod 4 = 1 then
            B := B and 7;
         elsif Seed mod 4 = 2 then
            B := B and 15;
         elsif Seed mod 4 = 3 and then I mod 3 /= 0 then
            B := B and 3;
         end if;
         if Seed mod 8 = 5 and then I mod 5 = 1 then
            B := 16#61# + (B and 1);
         end if;
         Input (I) := B;
      end loop;
   end Fill;

   procedure Hash_64 (H : in out Wuffs.U64; X : Wuffs.U64) is
      V : Wuffs.U64 := X;
   begin
      for I in 1 .. 8 loop
         H := (H xor (V and 16#FF#)) * 16#100_0000_01B3#;
         V := Interfaces.Shift_Right (V, 8);
      end loop;
   end Hash_64;

   procedure Put_Number (X : Wuffs.U64) is
      Text  : String (1 .. 20);
      First : Natural := Text'Last + 1;
      Rest  : Wuffs.U64 := X;
   begin
      loop
         First := First - 1;
         Text (First) := Character'Val (Character'Pos ('0') + Natural (Rest mod 10));
         Rest := Rest / 10;
         exit when Rest = 0;
      end loop;
      Ada.Text_IO.Put (Text (First .. Text'Last));
   end Put_Number;

   procedure Put_Hex_64 (X : Wuffs.U64) is
   begin
      Test_Support.Put_Hex (Wuffs.U32 (Interfaces.Shift_Right (X, 32)));
      Test_Support.Put_Hex (Wuffs.U32 (X and 16#FFFF_FFFF#));
   end Put_Hex_64;

   --  F 1 .. 5: through Decode_Tokens (the Token_Decoder interface), with
   --  Set_Quirk selecting K1 .. K5; F 6 .. 10: K1 .. K5 called directly.
   procedure Run (F : Positive; Seed : Wuffs.U32; S : Schedule) is
      Src_Cap   : constant Wuffs.Index := (if S.Src = 0 then Len else S.Src);
      Tok_Len   : constant Wuffs.Index := (if S.Dst = 0 then Tok_Cap else S.Dst);
      Src_Meta  : IO.Buffer_Meta := IO.Empty_Meta;
      Dst_Meta  : Tok.Token_Buffer_Meta := Tok.Empty_Meta;
      In_Pos    : Wuffs.Index := 0;
      N         : Wuffs.Index;
      Old_Ri    : Wuffs.Index;
      Written   : Wuffs.Index;
      Calls     : Wuffs.U64 := 0;
      Count     : Wuffs.U64 := 0;
      Tok_Hash  : Wuffs.U64 := 16#CBF2_9CE4_8422_2325#;
      Call_Hash : Wuffs.U64 := 16#CBF2_9CE4_8422_2325#;
      St        : Wuffs.U64 := 0;
      Status    : Wuffs.Status;
      Stalled   : Natural := 0;
      Src_View  : Wuffs.Bytes renames Src (Src'First .. Src'First + Src_Cap - 1);
      Tok_View  : Wuffs.U64_Array renames Tokens (Tokens'First .. Tokens'First + Tok_Len - 1);
   begin
      Runs := Runs + 1;
      Fill (Seed);
      Tokens := [others => 0];
      T.Initialize (Thing);
      if F <= 5 then
         Test_Support.Check
           (Thing.Set_Quirk (A_Key => 1, A_Value => Wuffs.U64 (F)) = Wuffs.Ok_Status,
            "set_quirk", F);
      end if;
      loop
         IO.Compact (Src_View, Src_Meta, N);
         N := Wuffs.Index'Min (Src_Cap - Src_Meta.Wi, Len - In_Pos);
         Src_View (Src_View'First + Src_Meta.Wi .. Src_View'First + Src_Meta.Wi + N - 1) :=
           Input (In_Pos .. In_Pos + N - 1);
         Src_Meta.Wi := Src_Meta.Wi + N;
         In_Pos := In_Pos + N;
         Src_Meta.Closed := In_Pos = Len;
         Old_Ri := Src_Meta.Ri;
         case F is
            when 1 .. 5 =>
               Status := Thing.Decode_Tokens
                 (A_Dst => Tok_View, A_Dst_Meta => Dst_Meta, A_Src => Src_View,
                  A_Src_Meta => Src_Meta, A_Workbuf => Workbuf);
            when 6 =>
               Status := T.K1 (Thing, A_Dst => Tok_View, A_Dst_Meta => Dst_Meta, A_Src => Src_View,
                               A_Src_Meta => Src_Meta, A_Workbuf => Workbuf);
            when 7 =>
               Status := T.K2 (Thing, A_Dst => Tok_View, A_Dst_Meta => Dst_Meta, A_Src => Src_View,
                               A_Src_Meta => Src_Meta, A_Workbuf => Workbuf);
            when 8 =>
               Status := T.K3 (Thing, A_Dst => Tok_View, A_Dst_Meta => Dst_Meta, A_Src => Src_View,
                               A_Src_Meta => Src_Meta, A_Workbuf => Workbuf);
            when 9 =>
               Status := T.K4 (Thing, A_Dst => Tok_View, A_Dst_Meta => Dst_Meta, A_Src => Src_View,
                               A_Src_Meta => Src_Meta, A_Workbuf => Workbuf);
            when others =>
               Status := T.K5 (Thing, A_Dst => Tok_View, A_Dst_Meta => Dst_Meta, A_Src => Src_View,
                               A_Src_Meta => Src_Meta, A_Workbuf => Workbuf);
         end case;
         Calls := Calls + 1;
         St := Status_Number (Status);
         Hash_64 (Call_Hash, St);
         Hash_64 (Call_Hash, Wuffs.U64 (Src_Meta.Ri));
         Hash_64 (Call_Hash, Wuffs.U64 (Dst_Meta.Wi));
         Written := Dst_Meta.Wi - Dst_Meta.Ri;
         for I in Dst_Meta.Ri .. Dst_Meta.Wi - 1 loop
            Hash_64 (Tok_Hash, Tok_View (Tok_View'First + I));
            Count := Count + 1;
         end loop;
         Dst_Meta.Ri := Dst_Meta.Wi;
         Tok.Compact (Tok_View, Dst_Meta, N);
         exit when St /= 1 and then St /= 2;
         if Src_Meta.Ri = Old_Ri and then Written = 0
           and then (In_Pos = Len or else Src_Meta.Wi = Src_Cap)
         then
            Stalled := Stalled + 1;
            exit when Stalled >= 3;
         else
            Stalled := 0;
         end if;
         exit when Calls >= Max_Calls;
      end loop;
      Ada.Text_IO.Put ("= f");
      Put_Number (Wuffs.U64 (F));
      Ada.Text_IO.Put (" seed");
      Put_Number (Wuffs.U64 (Seed));
      Ada.Text_IO.Put (" s");
      Put_Number (Wuffs.U64 (S.Src));
      Ada.Text_IO.Put (" d");
      Put_Number (Wuffs.U64 (S.Dst));
      Ada.Text_IO.Put (" calls=");
      Put_Number (Calls);
      Ada.Text_IO.Put (" status=");
      Put_Number (St);
      Ada.Text_IO.Put (" in=");
      Put_Number (Wuffs.U64 (In_Pos - (Src_Meta.Wi - Src_Meta.Ri)));
      Ada.Text_IO.Put (" tokens=");
      Put_Number (Count);
      Ada.Text_IO.Put (" tokhash=");
      Put_Hex_64 (Tok_Hash);
      Ada.Text_IO.Put (" callhash=");
      Put_Hex_64 (Call_Hash);
      Ada.Text_IO.Put (" sum=");
      Test_Support.Put_Hex (T.Get_Sum (Thing));
      Ada.Text_IO.New_Line;
      Test_Support.Check (True, "ran");
   end Run;

begin
   for F in 1 .. 10 loop
      for Seed in Wuffs.U32 range 0 .. Num_Seeds - 1 loop
         for S of Schedules loop
            Run (F, Seed, S);
         end loop;
      end loop;
   end loop;
   Ada.Text_IO.Put ("test_tokadv: runs:");
   Ada.Text_IO.Put_Line (Runs'Image);
   Test_Support.Finish ("test_tokadv");
end Test_Tokadv;
