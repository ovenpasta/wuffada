--  Part of wuffada (wuffs-ada: Wuffs to Ada).
--  SPDX-License-Identifier: Apache-2.0 OR MIT

--  Part of test_entry: the argument checks at the public entry of the
--  generated token decoders (json, cbor), in both profiles.
--
--    * The token array, the source array or the work buffer in the decoder
--      object itself (at its end, at its start after the tag and Magic, and
--      the whole object), at the first call and when a suspended call is
--      resumed: rejected, and the object is not changed (other than being
--      disabled).
--    * A suspended decode_tokens resumed with other arguments: the token
--      array moved to another place, shrunk to no room at all or of length
--      zero, the source moved to another array (with the same bytes still
--      to read), the work buffer changed or empty.  None of that is an
--      argument error.  The decoder goes on, and the tokens it writes, put
--      together, are those of one call with all of the input.

with Test_Support;
with Token_Support;
with Wuffs.Base.IO;
with Wuffs.Base.Tokens;
with Wuffs.Runtime;
with Wuffs.Std.Cbor;
with Wuffs.Std.Json;

procedure Token_Entry is

   package TS renames Token_Support;
   package IO renames Wuffs.Base.IO;
   package Tok renames Wuffs.Base.Tokens;

   use type Wuffs.Index;
   use type Wuffs.Status;
   use type Wuffs.Status_Category;
   use type Wuffs.U64_Array;
   use type Wuffs.Bytes;

   use Test_Support;

   type Kind is (Json, Cbor);

   subtype Token_Decoder is Wuffs.Runtime.Token_Decoder'Class;

   Bad_Argument : Wuffs.Status renames Wuffs.Base.Error_Bad_Argument;
   Disabled     : Wuffs.Status renames Wuffs.Base.Error_Disabled_By_Previous_Error;

   --  A JSON document and a CBOR one, each of a few dozen tokens.
   Json_Doc : constant String :=
     "{""a"": [1, -2.5e3, true, false, null, ""sé😀t""], ""b"": {}, ""c"": []}";
   Cbor_Doc : constant Wuffs.Bytes :=
     [16#BF#, 16#61#, 16#61#, 16#1A#, 16#00#, 16#0F#, 16#42#, 16#40#,
      16#61#, 16#62#, 16#9F#, 16#F4#, 16#F5#, 16#F6#, 16#F7#, 16#FF#,
      16#61#, 16#63#, 16#5F#, 16#42#, 16#01#, 16#02#, 16#41#, 16#03#, 16#FF#,
      16#61#, 16#64#, 16#C1#, 16#3B#, 16#80#, 0, 0, 0, 0, 0, 0, 1,
      16#61#, 16#65#, 16#F9#, 16#3C#, 16#00#, 16#FF#];

   Doc        : Wuffs.Bytes (0 .. 255);
   Doc_Length : Wuffs.Index;

   --  The tokens of one call with all of the input.
   Want        : Wuffs.U64_Array (0 .. 255);
   Want_Length : Wuffs.Index;

   procedure Initialize (K : Kind);

   function Decode
     (K        : Kind;
      Dst      : in out Wuffs.U64_Array;
      Dst_Meta : in out Tok.Token_Buffer_Meta;
      Src      : Wuffs.Bytes;
      Src_Meta : in out IO.Buffer_Meta;
      Work     : in out Wuffs.Bytes) return Wuffs.Status;

   procedure Load (K : Kind);

   procedure Check_In_Object (K : Kind; Object : in out Wuffs.Bytes);

   procedure Check_Resume (K : Kind);

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
      Work     : in out Wuffs.Bytes) return Wuffs.Status
   is
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

   --  Puts K's document in Doc and the tokens of one call in Want.
   procedure Load (K : Kind) is
      Dst_Meta : Tok.Token_Buffer_Meta := Tok.Empty_Meta;
      Src_Meta : IO.Buffer_Meta;
      Work     : Wuffs.Bytes (1 .. 4);
      St       : Wuffs.Status;
   begin
      case K is
         when Json =>
            Doc_Length := Json_Doc'Length;
            for I in Json_Doc'Range loop
               Doc (Wuffs.Index (I - Json_Doc'First)) := Character'Pos (Json_Doc (I));
            end loop;
         when Cbor =>
            Doc_Length := Cbor_Doc'Length;
            Doc (0 .. Doc_Length - 1) := Cbor_Doc;
      end case;
      Initialize (K);
      Src_Meta := IO.Reader_Meta (Data_Length => Doc_Length, Closed => True);
      St := Decode (K, Want, Dst_Meta, Doc (0 .. Doc_Length - 1), Src_Meta, Work);
      Want_Length := Dst_Meta.Wi;
      Check (St = Wuffs.Ok_Status and then Src_Meta.Ri = Doc_Length and then Want_Length > 20,
        "token_entry: the whole document in one call", Kind'Pos (K));
   end Load;

   procedure Check_In_Object (K : Kind; Object : in out Wuffs.Bytes) is
      --  The object seen as tokens: whole tokens only, from its start.
      Object_Tokens : Wuffs.U64_Array (0 .. Object'Length / 8 - 1)
      with Import, Address => Object'Address;
      Copy : Wuffs.Bytes renames TS.Src_Work;  --  (Free here.)
      Work : Wuffs.Bytes (1 .. 4) := [others => 0];
      Dst  : Wuffs.U64_Array (1 .. 64) := [others => 0];

      procedure Prepare (Resumed : Boolean);

      procedure Rejected (St : Wuffs.Status; What : String; N : Integer);

      procedure Prepare (Resumed : Boolean) is
         Dst_Meta : Tok.Token_Buffer_Meta := Tok.Empty_Meta;
         Src_Meta : IO.Buffer_Meta := IO.Reader_Meta (Data_Length => 1, Closed => False);
         St       : Wuffs.Status;
      begin
         Initialize (K);
         if Resumed then
            St := Decode (K, Dst, Dst_Meta, Doc (0 .. 0), Src_Meta, Work);
            Check (St = Wuffs.Base.Suspension_Short_Read, "token_entry: did not suspend",
              Kind'Pos (K));
         end if;
         Copy (0 .. Object'Length - 1) := Object;
      end Prepare;

      procedure Rejected (St : Wuffs.Status; What : String; N : Integer) is
         Dst_Meta : Tok.Token_Buffer_Meta := Tok.Empty_Meta;
         Src_Meta : IO.Buffer_Meta := IO.Reader_Meta (Data_Length => Doc_Length, Closed => True);
      begin
         Check (St = Bad_Argument, What, N, ": not rejected");
         --  Bytes 8 .. 11 are Magic (the first component, after the tag).
         Check
           (Copy (0 .. 7) = Object (Object'First .. Object'First + 7)
            and then Copy (12 .. Object'Length - 1) = Object (Object'First + 12 .. Object'Last),
            What, N, ": the object was changed");
         Check
           (Decode (K, Dst, Dst_Meta, Doc (0 .. Doc_Length - 1), Src_Meta, Work) = Disabled,
            What, N, ": not disabled");
      end Rejected;

      Last  : constant Wuffs.Index := Object_Tokens'Last;
      LastB : constant Wuffs.Index := Object'Length - 1;
   begin
      for Resumed in Boolean loop
         for Where in 1 .. 3 loop
            declare
               --  Tokens: the last two, two after the tag and Magic, all.
               TF : constant Wuffs.Index := (case Where is when 1 => Last - 1, when 2 => 2,
                                             when others => 0);
               TL : constant Wuffs.Index := (case Where is when 1 => Last, when 2 => 3,
                                             when others => Last);
               --  Bytes, likewise.
               BF : constant Wuffs.Index := (case Where is when 1 => LastB - 7, when 2 => 12,
                                             when others => 0);
               BL : constant Wuffs.Index := (case Where is when 1 => LastB, when 2 => 19,
                                             when others => LastB);
               N  : constant Integer := 100 * Kind'Pos (K) + 10 * Boolean'Pos (Resumed) + Where;
               Dst_Meta : Tok.Token_Buffer_Meta;
               Src_Meta : IO.Buffer_Meta;
            begin
               Prepare (Resumed);
               Dst_Meta := Tok.Empty_Meta;
               Src_Meta := IO.Reader_Meta (Data_Length => Doc_Length, Closed => True);
               Rejected
                 (Decode (K, Object_Tokens (TF .. TL), Dst_Meta, Doc (0 .. Doc_Length - 1),
                          Src_Meta, Work),
                  "decode_tokens, the tokens in the object", N);
               Prepare (Resumed);
               Dst_Meta := Tok.Empty_Meta;
               Src_Meta := IO.Reader_Meta (Data_Length => 0, Closed => True);
               Rejected
                 (Decode (K, Dst, Dst_Meta, Object (Object'First + BF .. Object'First + BL),
                          Src_Meta, Work),
                  "decode_tokens, the source in the object", N);
               Prepare (Resumed);
               Dst_Meta := Tok.Empty_Meta;
               Src_Meta := IO.Reader_Meta (Data_Length => Doc_Length, Closed => True);
               Rejected
                 (Decode (K, Dst, Dst_Meta, Doc (0 .. Doc_Length - 1), Src_Meta,
                          Object (Object'First + BF .. Object'First + BL)),
                  "decode_tokens, the work buffer in the object", N);
            end;
         end loop;
      end loop;
      Initialize (K);
   end Check_In_Object;

   --  Decodes the document a few bytes at a time, with other arrays at
   --  every call (and some calls with no room for tokens at all), and puts
   --  the tokens together.
   procedure Check_Resume (K : Kind) is
      Got      : Wuffs.U64_Array (0 .. 255) := [others => 0];
      Got_Len  : Wuffs.Index := 0;
      Fed      : Wuffs.Index := 0;  --  Bytes of Doc given to the decoder.
      Hold     : Wuffs.Bytes (0 .. 511);  --  What it has not read yet.
      Hold_Len : Wuffs.Index := 0;
      Calls    : Natural := 0;
      St       : Wuffs.Status := Wuffs.Base.Suspension_Short_Read;
      Dst_Meta : Tok.Token_Buffer_Meta;
      Src_Meta : IO.Buffer_Meta;
      Work     : Wuffs.Bytes (1 .. 32) := [others => 0];
      Room     : Wuffs.Index;
      Feed     : Wuffs.Index;
      Src_At   : Wuffs.Index;
      Tok_At   : Wuffs.Index;
      Work_Len : Wuffs.Index;
   begin
      Initialize (K);
      while St.Category = Wuffs.Suspension and then Calls < 1000 loop
         Calls := Calls + 1;
         --  The source: what is still unread and a few more bytes (std/json
         --  needs 100 at once), at another place in Src_Work each time.
         Feed := Wuffs.Index'Min
           (Doc_Length - Fed, (if K = Json then 100 else 9) + Wuffs.Index (Calls mod 3));
         Hold (Hold_Len .. Hold_Len + Feed - 1) := Doc (Fed .. Fed + Feed - 1);
         Hold_Len := Hold_Len + Feed;
         Fed := Fed + Feed;
         Src_At := Wuffs.Index ((Calls * 53) mod 3000);
         TS.Src_Work (Src_At .. Src_At + Hold_Len - 1) := Hold (0 .. Hold_Len - 1);
         Src_Meta := IO.Reader_Meta (Data_Length => Hold_Len, Closed => Fed = Doc_Length);
         --  The tokens: room for 0 .. 3 of them (every fifth call none,
         --  every seventh an array of length zero), elsewhere each time.
         Room := (if Calls mod 5 = 0 then 0 else Wuffs.Index (Calls mod 3) + 1);
         Tok_At := 2000 + Wuffs.Index ((Calls * 37) mod 500);
         Dst_Meta := Tok.Empty_Meta;
         --  The work buffer: of length 0 .. 31, at either end of Work.
         Work_Len := Wuffs.Index (Calls mod 32);
         if Calls mod 7 = 0 then
            St := Decode (K, TS.Tok_Work (Tok_At .. Tok_At - 1), Dst_Meta,
                          TS.Src_Work (Src_At .. Src_At + Hold_Len - 1), Src_Meta,
                          Work (Work'Last - Work_Len + 1 .. Work'Last));
         else
            St := Decode (K, TS.Tok_Work (Tok_At .. Tok_At + Room - 1), Dst_Meta,
                          TS.Src_Work (Src_At .. Src_At + Hold_Len - 1), Src_Meta,
                          Work (1 .. Work_Len));
         end if;
         Check (St /= Bad_Argument and then St /= Disabled,
           "token_entry: a resumption with other arrays was rejected", Calls);
         exit when St = Bad_Argument or else St = Disabled;
         for I in 0 .. Dst_Meta.Wi - 1 loop
            if Got_Len <= Got'Last then
               Got (Got_Len) := TS.Tok_Work (Tok_At + I);
            end if;
            Got_Len := Got_Len + 1;
         end loop;
         --  What has been read is dropped.
         Hold (0 .. Hold_Len - Src_Meta.Ri - 1) :=
           TS.Src_Work (Src_At + Src_Meta.Ri .. Src_At + Hold_Len - 1);
         Hold_Len := Hold_Len - Src_Meta.Ri;
      end loop;
      Check (St = Wuffs.Ok_Status and then Fed = Doc_Length and then Hold_Len = 0,
        "token_entry: resumed with other arrays: not to the end", Kind'Pos (K));
      Check (Got_Len = Want_Length and then Got (0 .. Got_Len - 1) = Want (0 .. Want_Length - 1),
        "token_entry: resumed with other arrays: other tokens", Kind'Pos (K));
      Initialize (K);
   end Check_Resume;

   Json_Object : Wuffs.Bytes (0 .. Wuffs.Index (TS.Json_Decoder'Size / 8) - 1)
   with Import, Address => TS.Json_Decoder'Address;
   Cbor_Object : Wuffs.Bytes (0 .. Wuffs.Index (TS.Cbor_Decoder'Size / 8) - 1)
   with Import, Address => TS.Cbor_Decoder'Address;

begin
   for K in Kind loop
      Load (K);
      case K is
         when Json => Check_In_Object (K, Json_Object);
         when Cbor => Check_In_Object (K, Cbor_Object);
      end case;
      Check_Resume (K);
   end loop;
end Token_Entry;
