--  Part of wuffada (wuffs-ada: Wuffs to Ada).
--  SPDX-License-Identifier: Apache-2.0 OR MIT

--  Part of test_hostile: what the generated token decoders (json, cbor) and
--  the runtime shell do for a caller that breaks the rules (see "Token
--  buffers" in wuffs-runtime.ads).  The same results are required in the
--  "checked" and in the "release" profile: a bad-argument status and a
--  disabled decoder, and never an exception or a write out of bounds.
--
--    * token buffer metas and source metas that do not describe their
--      arrays, or that hold bit patterns that are no values of their types
--      (a write index beyond the array, a read index beyond the write index,
--      negative indexes, a Boolean that is neither False nor True), at the
--      first call and when a suspended call is resumed;
--    * a token array that shares storage with the source array or the work
--      buffer (by as little as one byte), and the cases next to those that
--      are fine: adjacent arrays and empty arrays;
--    * the packages' status messages.

with Interfaces;
with Test_Support;
with Token_Support;
with Wuffs.Base.IO;
with Wuffs.Base.Tokens;
with Wuffs.Runtime;
with Wuffs.Std.Cbor;
with Wuffs.Std.Json;

procedure Token_Hostile is

   package TS renames Token_Support;
   package IO renames Wuffs.Base.IO;
   package Tok renames Wuffs.Base.Tokens;

   use type Wuffs.U64;
   use type Wuffs.Index;
   use type Wuffs.Status;
   use type Interfaces.Integer_64;
   use type Wuffs.U64_Array;
   use type Tok.Token_Buffer_Meta;

   use Test_Support;

   type Kind is (Json, Cbor);

   subtype Token_Decoder is Wuffs.Runtime.Token_Decoder'Class;

   Bad_Argument : Wuffs.Status renames Wuffs.Base.Error_Bad_Argument;
   Disabled     : Wuffs.Status renames Wuffs.Base.Error_Disabled_By_Previous_Error;

   --  The representation of both kinds of meta, to make invalid ones from.
   type Raw_Meta is record
      Wi     : Interfaces.Integer_64;
      Ri     : Interfaces.Integer_64;
      Pos    : Wuffs.U64;
      Closed : Wuffs.U8;
   end record
   with Convention => C;

   Raw         : aliased Raw_Meta := (Wi => 0, Ri => 0, Pos => 0, Closed => 0);
   Invalid_Tok : Tok.Token_Buffer_Meta
   with Import, Address => Raw'Address;
   Invalid_Src : IO.Buffer_Meta
   with Import, Address => Raw'Address;

   --  For arrays of 16 tokens and 16 bytes.  (The last one only in the
   --  release profile: see Check_Metas.)
   Raw_Metas : constant array (1 .. 8) of Raw_Meta :=
     [(Wi => 17, Ri => 0, Pos => 0, Closed => 0),
      (Wi => 0, Ri => -1, Pos => 0, Closed => 0),
      (Wi => -5, Ri => -5, Pos => 0, Closed => 0),
      (Wi => 2, Ri => -(2 ** 62), Pos => 0, Closed => 0),
      (Wi => Interfaces.Integer_64'Last, Ri => 0, Pos => 0, Closed => 0),
      (Wi => 2 ** 62, Ri => 2 ** 62, Pos => 0, Closed => 0),
      (Wi => 0, Ri => 0, Pos => 0, Closed => 2),
      (Wi => 3, Ri => 5, Pos => 0, Closed => 0)];

   --  One piece of storage seen as tokens and as bytes, so that a token
   --  array and a byte array can share storage.
   Shared       : aliased Wuffs.U64_Array (0 .. 127) := [others => 0];
   Shared_Bytes : Wuffs.Bytes (0 .. 1023)
   with Import, Address => Shared'Address;

   Src_Data : constant Wuffs.Bytes (1 .. 16) := [16#5B#, others => 16#20#];

   procedure Initialize (K : Kind);

   function Decode
     (K        : Kind;
      Dst      : in out Wuffs.U64_Array;
      Dst_Meta : in out Tok.Token_Buffer_Meta;
      Src      : Wuffs.Bytes;
      Src_Meta : in out IO.Buffer_Meta;
      Work     : in out Wuffs.Bytes) return Wuffs.Status;

   --  The decoder has just rejected a call: it says so again (disabled)
   --  for a call with good arguments.
   procedure Check_Disabled (K : Kind; What : String);

   procedure Check_Metas (K : Kind);

   procedure Check_Overlaps (K : Kind);

   procedure Check_Messages;

   procedure Initialize (K : Kind) is
   begin
      case K is
         when Json => Wuffs.Std.Json.Initialize (TS.Json_Decoder);
         when Cbor => Wuffs.Std.Cbor.Initialize (TS.Cbor_Decoder);
      end case;
   end Initialize;

   function Decode
     (K        : Kind;
      Dst      : in out Wuffs.U64_Array;
      Dst_Meta : in out Tok.Token_Buffer_Meta;
      Src      : Wuffs.Bytes;
      Src_Meta : in out IO.Buffer_Meta;
      Work     : in out Wuffs.Bytes) return Wuffs.Status is
      function Call (D : in out Token_Decoder) return Wuffs.Status;

      function Call (D : in out Token_Decoder) return Wuffs.Status is
      begin
         return D.Decode_Tokens
           (A_Dst => Dst, A_Dst_Meta => Dst_Meta, A_Src => Src, A_Src_Meta => Src_Meta,
            A_Workbuf => Work);
      end Call;
   begin
      case K is
         when Json => return Call (TS.Json_Decoder);
         when Cbor => return Call (TS.Cbor_Decoder);
      end case;
   end Decode;

   procedure Check_Disabled (K : Kind; What : String) is
      Dst      : Wuffs.U64_Array (1 .. 16) := [others => 0];
      Dst_Meta : Tok.Token_Buffer_Meta := Tok.Empty_Meta;
      Src_Meta : IO.Buffer_Meta := IO.Reader_Meta (Data_Length => 16, Closed => False);
      Work     : Wuffs.Bytes (1 .. 4) := [others => 0];
   begin
      Check
        (Decode (K, Dst, Dst_Meta, Src_Data, Src_Meta, Work) = Disabled
         and then Dst_Meta = Tok.Empty_Meta and then Src_Meta.Ri = 0
         and then (for all T of Dst => T = 0),
         What, Kind'Pos (K), ": not disabled afterwards");
   end Check_Disabled;

   procedure Check_Metas (K : Kind) is
      Dst      : Wuffs.U64_Array (101 .. 116) := [others => 0];
      Good_Tok : Tok.Token_Buffer_Meta;
      Good_Src : IO.Buffer_Meta;
      Work     : Wuffs.Bytes (1 .. 4) := [others => 0];
      St       : Wuffs.Status;
   begin
      for Resumed in Boolean loop
         for I in Raw_Metas'Range loop
            --  A read index beyond the write index breaks the metas' type
            --  predicates: with checks on (the checked profile), this
            --  program cannot even make that call.
            exit when Test_Support.Checks_Enabled and then Raw_Metas (I).Ri > Raw_Metas (I).Wi;
            for Which in 1 .. 2 loop
               Initialize (K);
               if Resumed then
                  --  "[" and no more yet: the decoder suspends, asking for
                  --  more input.
                  Good_Tok := Tok.Empty_Meta;
                  Good_Src := IO.Reader_Meta (Data_Length => 1, Closed => False);
                  St := Decode (K, Dst, Good_Tok, Src_Data, Good_Src, Work);
                  Check (St = Wuffs.Base.Suspension_Short_Read, "token decoder did not suspend",
                    Kind'Pos (K));
               end if;
               Dst := [others => 0];
               Raw := Raw_Metas (I);
               Good_Tok := Tok.Empty_Meta;
               Good_Src := IO.Reader_Meta (Data_Length => 16, Closed => False);
               if Which = 1 then
                  St := Decode (K, Dst, Invalid_Tok, Src_Data, Good_Src, Work);
               else
                  St := Decode (K, Dst, Good_Tok, Src_Data, Invalid_Src, Work);
               end if;
               Check
                 (St = Bad_Argument and then (for all T of Dst => T = 0)
                  and then Good_Tok = Tok.Empty_Meta and then Good_Src.Ri = 0,
                  "decode_tokens with an invalid meta (1: token, 2: source; then the meta)",
                  10 * Which + I);
               Check_Disabled (K, "decode_tokens with an invalid meta");
            end loop;
         end loop;
      end loop;
   end Check_Metas;

   procedure Check_Overlaps (K : Kind) is

      --  Decodes with the tokens Shared (TF .. TL), the source
      --  Shared_Bytes (SF .. SL) and the work buffer Shared_Bytes (WF ..
      --  WL), after filling the source with "[" and spaces: Bad says
      --  whether that must be rejected.
      procedure Try
        (TF, TL, SF, SL, WF, WL : Wuffs.Index; Bad : Boolean; What : String; N : Integer);

      procedure Try
        (TF, TL, SF, SL, WF, WL : Wuffs.Index; Bad : Boolean; What : String; N : Integer)
      is
         Dst_Meta : Tok.Token_Buffer_Meta := Tok.Empty_Meta;
         Src_Meta : IO.Buffer_Meta;
         St       : Wuffs.Status;
      begin
         Initialize (K);
         Shared := [others => 0];
         for I in SF .. SL loop
            Shared_Bytes (I) := (if I = SF then 16#5B# else 16#20#);
         end loop;
         Src_Meta := IO.Reader_Meta (Data_Length => SL - SF + 1, Closed => False);
         declare
            Snapshot : constant Wuffs.U64_Array := Shared;
         begin
            St := Decode (K, Shared (TF .. TL), Dst_Meta, Shared_Bytes (SF .. SL), Src_Meta,
                          Shared_Bytes (WF .. WL));
            if Bad then
               Check
                 (St = Bad_Argument and then Shared = Snapshot and then Src_Meta.Ri = 0
                  and then Dst_Meta = Tok.Empty_Meta,
                  What, N, ": not rejected, or memory written");
               Check_Disabled (K, What);
            else
               Check (St /= Bad_Argument and then St /= Disabled, What, N, ": rejected");
            end if;
         end;
      end Try;

   begin
      --  Tokens 10 .. 13 are bytes 80 .. 111.  The work buffer is out of
      --  the way (bytes 900 .. 915) unless it is what is being tried.
      Try (10, 13, 100, 120, 900, 915, True, "tokens overlap the source", 1);
      Try (10, 13, 60, 80, 900, 915, True, "tokens overlap the source by their first byte", 2);
      Try (10, 13, 111, 130, 900, 915, True, "tokens overlap the source by their last byte", 3);
      Try (10, 13, 85, 90, 900, 915, True, "the source lies in the tokens", 4);
      Try (10, 13, 0, 1023, 900, 915, True, "the tokens lie in the source", 5);
      Try (10, 13, 112, 130, 900, 915, False, "the source just after the tokens", 6);
      Try (10, 13, 60, 79, 900, 915, False, "the source just before the tokens", 7);
      Try (10, 9, 70, 100, 900, 915, False, "an empty token array where the source is", 8);
      Try (10, 13, 300, 320, 100, 99, False, "an empty work buffer where the tokens are", 9);
      Try (10, 13, 300, 320, 81, 81, True, "tokens overlap the work buffer", 10);
      Try (10, 13, 300, 320, 70, 200, True, "tokens lie in the work buffer", 11);
      Try (10, 13, 300, 320, 112, 115, False, "the work buffer just after the tokens", 12);
   end Check_Overlaps;

   procedure Check_Messages is
      Buffer : String (1 .. 80);
      Length : Natural;

      procedure Expect (S : Wuffs.Status; K : Kind; Text : String);

      procedure Expect (S : Wuffs.Status; K : Kind; Text : String) is
         L : Natural;
      begin
         for Other in Kind loop
            case Other is
               when Json =>
                  L := Wuffs.Std.Json.Message_Length (S);
                  Wuffs.Std.Json.Get_Message (S, Buffer, Length);
               when Cbor =>
                  L := Wuffs.Std.Cbor.Message_Length (S);
                  Wuffs.Std.Cbor.Get_Message (S, Buffer, Length);
            end case;
            if Other = K then
               Check
                 (L = Text'Length and then Length = Text'Length
                  and then Buffer (1 .. Length) = Text
                  and then (for all I in Length + 1 .. Buffer'Last => Buffer (I) = ' '),
                  "message: ", -1, Text);
            else
               Check
                 (L = 0 and then Length = 0 and then (for all C of Buffer => C = ' '),
                  "message of another package: ", -1, Text);
            end if;
         end loop;
         Check (Wuffs.Base.Message_Length (S) = 0, "a base message for: ", -1, Text);
      end Expect;
   begin
      Expect (Wuffs.Std.Json.Error_Bad_C0_Control_Code, Json, "json: bad C0 control code");
      Expect (Wuffs.Std.Json.Error_Bad_UTF_8, Json, "json: bad UTF-8");
      Expect (Wuffs.Std.Json.Error_Bad_Backslash_Escape, Json, "json: bad backslash-escape");
      Expect (Wuffs.Std.Json.Error_Bad_Input, Json, "json: bad input");
      Expect
        (Wuffs.Std.Json.Error_Bad_New_Line_In_A_String, Json,
         "json: bad new-line in a string");
      Expect (Wuffs.Std.Json.Error_Bad_Quirk_Combination, Json, "json: bad quirk combination");
      Expect
        (Wuffs.Std.Json.Error_Unsupported_Number_Length, Json,
         "json: unsupported number length");
      Expect
        (Wuffs.Std.Json.Error_Unsupported_Recursion_Depth, Json,
         "json: unsupported recursion depth");
      Expect (Wuffs.Std.Cbor.Error_Bad_Input, Cbor, "cbor: bad input");
      Expect
        (Wuffs.Std.Cbor.Error_Unsupported_Recursion_Depth, Cbor,
         "cbor: unsupported recursion depth");
   end Check_Messages;

begin
   for K in Kind loop
      Check_Metas (K);
      Check_Overlaps (K);
      Initialize (K);
   end loop;
   Check_Messages;
end Token_Hostile;
