--  Tests the generated token decoders, json and cbor.
--
--  Standard input is a manifest (from ada/tests/tokcorpus): one test case
--  per line, "FORMAT QUIRKS INPUT CHECK", where QUIRKS is a hexadecimal mask
--  of the json quirks to enable (bit I: the quirk 16#4599_0800# + I) and
--  CHECK says what ada/tests/tokcheck compares the tokens with ("-" for
--  nothing).
--
--  Every input is decoded under several schedules.  A schedule is how much
--  source the decoder is given at a time and how much room for tokens: all
--  of it, or as little as one byte and one token, so that the decoder
--  suspends ("short read", "short write") at every one of its suspension
--  points and is resumed.  Between calls the buffers are compacted, as a
--  real caller does: the tokens written are taken out (hashed) and the
--  source bytes read are dropped.
--
--  For each run this program prints a trace line "= ..." with the final
--  status, the number of calls, the source position, the number of tokens,
--  a hash of every token (all 64 bits, in order) and a hash of every call's
--  status and buffer positions.  ada/tests/crosscheck/tokens.c runs the same
--  schedules on upstream's C decoders and prints the same trace; test.sh
--  requires the two traces to be identical.  Keep the two files in step.
--
--  After a manifest line "dump DIR", it also writes, for every later case
--  whose CHECK is not "-", the tokens of the run with the first schedule
--  (everything at once) to DIR/N.tok (8 bytes each, little-endian) and a
--  line "N FORMAT QUIRKS INPUT CHECK CATEGORY CODE CONSUMED" to
--  DIR/index.txt, for ada/tests/tokcheck.
--
--  After a manifest line "chaos", every third later case also gets a chaos
--  run: decode_tokens with other arguments at every call (a source array
--  elsewhere, holding the bytes not read yet, sometimes corrupted, with
--  read bytes before them; a token array elsewhere, of 0 to 5 tokens with
--  some already written; a work buffer of another length), and now and
--  then a call that must be rejected (an invalid token meta, or a token
--  array that overlaps the source), after which the decoder must say that
--  it is disabled.  No trace to compare with C: it checks that every call
--  stays within its buffers and that nothing raises, and prints a digest
--  of every call's status and buffer positions, which must be the same in
--  every build (test.sh compares the profiles).
--
--  Exits with a failure status if any check fails.

with Ada.Streams.Stream_IO;
with Ada.Text_IO;
with Interfaces;
with Test_Support;
with Token_Support;
with Wuffs.Base.IO;
with Wuffs.Base.Ranges;
with Wuffs.Base.Tokens;
with Wuffs.Std.Cbor;
with Wuffs.Std.Json;

procedure Test_Tokens is

   use type Wuffs.U32;
   use type Wuffs.U64;
   use type Wuffs.Offset;
   use type Wuffs.Status_Category;
   use type Wuffs.Base.Ranges.Range_II_U64;
   use type Ada.Streams.Stream_Element_Offset;
   use type Ada.Streams.Stream_IO.Count;

   package TS renames Token_Support;
   package IO renames Wuffs.Base.IO;
   package Tok renames Wuffs.Base.Tokens;
   package SIO renames Ada.Streams.Stream_IO;

   type Format is (Json, Cbor);

   type Schedule is record
      Src_Chunk : Wuffs.Index;  --  0 means everything at once.
      Dst_Chunk : Wuffs.Index;  --  In tokens; 0 means all the room there is.
   end record;

   type Schedule_List is array (Positive range <>) of Schedule;

   --  std/json needs 100 bytes of source at once
   --  (DECODER_SRC_IO_BUFFER_LENGTH_MIN_INCL) and std/cbor 9 and two tokens
   --  of room, or they make no progress (see Stalled in Run): the smaller
   --  sizes test the suspensions up to that point, the others every
   --  suspension point throughout.
   Full_Schedules : constant Schedule_List :=
     [(0, 0), (1, 0), (2, 0), (3, 0), (7, 0), (9, 0), (31, 0),
      (100, 0), (101, 0), (127, 0), (4097, 0), (0, 1), (0, 2), (0, 3),
      (0, 7), (1, 1), (1, 2), (3, 2), (9, 2), (10, 3), (100, 1),
      (100, 2), (101, 3), (128, 5), (300, 5), (1000, 1), (7, 4097)];

   --  For inputs of more than Reduced_Above bytes.
   Reduced_Schedules : constant Schedule_List :=
     [(0, 0), (4097, 0), (0, 4097), (1000, 300), (100, 0),
      (100, 1), (101, 2), (0, 2), (9, 2), (1, 0)];

   Reduced_Above : constant := 60_000;

   --  The buffers that the decoders see do not start at index 0 of their
   --  arrays (and not at the same index either).
   Src_First : constant := 5;
   Tok_First : constant := 1000;

   Json_Quirks_Base  : constant := 16#4599_0800#;
   Json_Quirks_Count : constant := 21;

   Cases : Natural := 0;
   Runs  : Natural := 0;

   Chaos_On       : Boolean := False;
   Chaos_Runs     : Natural := 0;
   Chaos_Calls    : Natural := 0;
   Chaos_Rejected : Natural := 0;
   Chaos_Hash     : Wuffs.U64 := 16#CBF2_9CE4_8422_2325#;
   Rng            : Wuffs.U64 := 0;

   Dumping    : Boolean := False;
   Dump_Dir   : String renames TS.Dump_Dir;
   Dump_Last  : Natural := 0;
   Index_File : Ada.Text_IO.File_Type;

   procedure Load (Name : String; Length : out Wuffs.Index; OK : out Boolean);

   procedure Initialize (F : Format; Quirks : Wuffs.U32);

   function Call
     (F        : Format;
      Dst      : in out Wuffs.U64_Array;
      Dst_Meta : in out Tok.Token_Buffer_Meta;
      Src      : Wuffs.Bytes;
      Src_Meta : in out IO.Buffer_Meta) return Wuffs.Status;

   procedure Hash_64 (H : in out Wuffs.U64; X : Wuffs.U64);

   procedure Put_Number (F : Ada.Text_IO.File_Type; X : Wuffs.U64);

   procedure Put_Hex_64 (X : Wuffs.U64);

   --  Appends the decimal digits of X to Buf (Buf'First .. Last).
   procedure Append_Number (Buf : in out String; Last : in out Natural; X : Natural);

   procedure Run
     (F         : Format;
      Quirks    : Wuffs.U32;
      Name      : String;
      In_Length : Wuffs.Index;
      S         : Schedule;
      Dump      : Natural);

   function Rnd (N : Wuffs.Index) return Wuffs.Index
   with Pre => N >= 1;

   procedure Chaos (F : Format; Quirks : Wuffs.U32; In_Length : Wuffs.Index; Seed : Natural);

   procedure Do_Case (Line : String);

   procedure Check_Lifecycle;

   procedure Load (Name : String; Length : out Wuffs.Index; OK : out Boolean) is
      File : SIO.File_Type;
      Size : SIO.Count;
   begin
      Length := 0;
      OK := False;
      SIO.Open (File, SIO.In_File, Name);
      Size := SIO.Size (File);
      if Size <= TS.Capacity then
         if Size > 0 then
            declare
               subtype SEO is Ada.Streams.Stream_Element_Offset;
               Item : Ada.Streams.Stream_Element_Array (1 .. SEO (Size))
               with Import, Address => TS.Input'Address;
               Last : Ada.Streams.Stream_Element_Offset;
            begin
               SIO.Read (File, Item, Last);
               OK := Last = Item'Last;
            end;
         else
            OK := True;
         end if;
         Length := Wuffs.Index (Size);
      end if;
      SIO.Close (File);
   exception
      when others =>
         OK := False;
   end Load;

   procedure Initialize (F : Format; Quirks : Wuffs.U32) is
      use type Wuffs.Status;
   begin
      case F is
         when Json =>
            Wuffs.Std.Json.Initialize (TS.Json_Decoder);
            for I in 0 .. Json_Quirks_Count - 1 loop
               if (Quirks and Interfaces.Shift_Left (1, I)) /= 0 then
                  Test_Support.Check
                    (TS.Json_Decoder.Set_Quirk (Json_Quirks_Base + Wuffs.U32 (I), 1)
                     = Wuffs.Ok_Status,
                     "json set_quirk", I);
                  Test_Support.Check_U64
                    (TS.Json_Decoder.Get_Quirk (Json_Quirks_Base + Wuffs.U32 (I)), 1,
                     "json get_quirk", I);
               end if;
            end loop;
         when Cbor =>
            Wuffs.Std.Cbor.Initialize (TS.Cbor_Decoder);
      end case;
   end Initialize;

   function Call
     (F        : Format;
      Dst      : in out Wuffs.U64_Array;
      Dst_Meta : in out Tok.Token_Buffer_Meta;
      Src      : Wuffs.Bytes;
      Src_Meta : in out IO.Buffer_Meta) return Wuffs.Status is
   begin
      case F is
         when Json =>
            return TS.Json_Decoder.Decode_Tokens
              (A_Dst      => Dst,
               A_Dst_Meta => Dst_Meta,
               A_Src      => Src,
               A_Src_Meta => Src_Meta,
               A_Workbuf  => TS.Workbuf);
         when Cbor =>
            return TS.Cbor_Decoder.Decode_Tokens
              (A_Dst      => Dst,
               A_Dst_Meta => Dst_Meta,
               A_Src      => Src,
               A_Src_Meta => Src_Meta,
               A_Workbuf  => TS.Workbuf);
      end case;
   end Call;

   procedure Hash_64 (H : in out Wuffs.U64; X : Wuffs.U64) is
      V : Wuffs.U64 := X;
   begin
      for I in 1 .. 8 loop
         H := (H xor (V and 16#FF#)) * 16#100_0000_01B3#;
         V := Interfaces.Shift_Right (V, 8);
      end loop;
   end Hash_64;

   procedure Put_Number (F : Ada.Text_IO.File_Type; X : Wuffs.U64) is
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
      Ada.Text_IO.Put (F, Text (First .. Text'Last));
   end Put_Number;

   procedure Put_Hex_64 (X : Wuffs.U64) is
   begin
      Test_Support.Put_Hex (Wuffs.U32 (Interfaces.Shift_Right (X, 32)));
      Test_Support.Put_Hex (Wuffs.U32 (X and 16#FFFF_FFFF#));
   end Put_Hex_64;

   procedure Append_Number (Buf : in out String; Last : in out Natural; X : Natural) is
      Digits_Of : String (1 .. 10);
      First     : Natural := Digits_Of'Last + 1;
      Rest      : Natural := X;
   begin
      loop
         First := First - 1;
         Digits_Of (First) := Character'Val (Character'Pos ('0') + Rest mod 10);
         Rest := Rest / 10;
         exit when Rest = 0;
      end loop;
      for C of Digits_Of (First .. Digits_Of'Last) loop
         Last := Last + 1;
         Buf (Last) := C;
      end loop;
   end Append_Number;

   procedure Run
     (F         : Format;
      Quirks    : Wuffs.U32;
      Name      : String;
      In_Length : Wuffs.Index;
      S         : Schedule;
      Dump      : Natural)
   is
      Src_Cap : constant Wuffs.Index :=
        (if S.Src_Chunk = 0 then Wuffs.Index'Max (In_Length, 1) else S.Src_Chunk);
      Dst_Cap : constant Wuffs.Index :=
        (if S.Dst_Chunk = 0 then TS.Token_Capacity - Tok_First else S.Dst_Chunk);

      Src_Last : constant Wuffs.Index := Src_First + Src_Cap - 1;
      Dst_Last : constant Wuffs.Index := Tok_First + Dst_Cap - 1;

      Src_Meta  : IO.Buffer_Meta := IO.Empty_Meta;
      Dst_Meta  : Tok.Token_Buffer_Meta := Tok.Empty_Meta;
      In_Pos    : Wuffs.Index := 0;
      N         : Wuffs.Index;
      Old_Ri    : Wuffs.Index;
      Written   : Wuffs.Index;
      Status    : Wuffs.Status := Wuffs.Ok_Status;
      Calls     : Wuffs.U64 := 0;
      Tokens    : Wuffs.U64 := 0;
      Tok_Hash  : Wuffs.U64 := 16#CBF2_9CE4_8422_2325#;
      Call_Hash : Wuffs.U64 := 16#CBF2_9CE4_8422_2325#;
      Max_Calls : constant Wuffs.U64 := 4 * Wuffs.U64 (In_Length) + 1000;
      Stalled   : Natural := 0;
      Dump_File : SIO.File_Type;
   begin
      Runs := Runs + 1;
      if Dump /= 0 then
         declare
            File_Name : String (1 .. Dump_Dir'Length + 20);
            Last      : Natural := Dump_Last + 1;
         begin
            File_Name (1 .. Dump_Last) := Dump_Dir (1 .. Dump_Last);
            File_Name (Last) := '/';
            Append_Number (File_Name, Last, Dump);
            File_Name (Last + 1 .. Last + 4) := ".tok";
            SIO.Create (Dump_File, SIO.Out_File, File_Name (1 .. Last + 4));
         end;
      end if;
      Initialize (F, Quirks);
      loop
         IO.Compact (TS.Src_Work (Src_First .. Src_Last), Src_Meta, N);
         N := Wuffs.Index'Min (Src_Cap - Src_Meta.Wi, In_Length - In_Pos);
         if N > 0 then
            TS.Src_Work (Src_First + Src_Meta.Wi .. Src_First + Src_Meta.Wi + N - 1) :=
              TS.Input (In_Pos .. In_Pos + N - 1);
            Src_Meta.Wi := Src_Meta.Wi + N;
            In_Pos := In_Pos + N;
         end if;
         Src_Meta.Closed := In_Pos = In_Length;

         Old_Ri := Src_Meta.Ri;
         Status :=
           Call
             (F,
              Dst      => TS.Tok_Work (Tok_First .. Dst_Last),
              Dst_Meta => Dst_Meta,
              Src      => TS.Src_Work (Src_First .. Src_Last),
              Src_Meta => Src_Meta);
         Calls := Calls + 1;

         Hash_64 (Call_Hash, Wuffs.Status_Category'Pos (Status.Category));
         Hash_64 (Call_Hash, Wuffs.U64 (Status.Code));
         Hash_64 (Call_Hash, Wuffs.U64 (Src_Meta.Ri));
         Hash_64 (Call_Hash, Wuffs.U64 (Src_Meta.Wi));
         Hash_64 (Call_Hash, Src_Meta.Pos);
         Hash_64 (Call_Hash, Wuffs.U64 (Dst_Meta.Wi));
         Hash_64 (Call_Hash, Dst_Meta.Pos);

         Written := Dst_Meta.Wi - Dst_Meta.Ri;
         for I in Dst_Meta.Ri .. Dst_Meta.Wi - 1 loop
            Hash_64 (Tok_Hash, TS.Tok_Work (Tok_First + I));
            Tokens := Tokens + 1;
            if Dump /= 0 then
               declare
                  Item : Ada.Streams.Stream_Element_Array (1 .. 8);
                  V    : Wuffs.U64 := TS.Tok_Work (Tok_First + I);
               begin
                  for K in Item'Range loop
                     Item (K) := Ada.Streams.Stream_Element (V and 16#FF#);
                     V := Interfaces.Shift_Right (V, 8);
                  end loop;
                  SIO.Write (Dump_File, Item);
               end;
            end if;
         end loop;
         Dst_Meta.Ri := Dst_Meta.Wi;
         Tok.Compact (TS.Tok_Work (Tok_First .. Dst_Last), Dst_Meta, N);

         exit when Status.Category /= Wuffs.Suspension;
         --  As in tokens.c: no progress three times in a row, with no more
         --  source to give, is the end of the run.
         if Src_Meta.Ri = Old_Ri
           and then Written = 0
           and then (In_Pos = In_Length or else Src_Meta.Wi = Src_Cap)
         then
            Stalled := Stalled + 1;
            exit when Stalled >= 3;
         else
            Stalled := 0;
         end if;
         exit when Calls > Max_Calls;
      end loop;
      if Dump /= 0 then
         SIO.Close (Dump_File);
      end if;

      Ada.Text_IO.Put ("= ");
      Ada.Text_IO.Put (Name);
      Ada.Text_IO.Put (" q");
      Test_Support.Put_Hex (Quirks);
      Ada.Text_IO.Put (" s");
      Put_Number (Ada.Text_IO.Standard_Output, Wuffs.U64 (S.Src_Chunk));
      Ada.Text_IO.Put (" d");
      Put_Number (Ada.Text_IO.Standard_Output, Wuffs.U64 (S.Dst_Chunk));
      Ada.Text_IO.Put (" calls=");
      Put_Number (Ada.Text_IO.Standard_Output, Calls);
      Ada.Text_IO.Put (" status=");
      Put_Number (Ada.Text_IO.Standard_Output, Wuffs.Status_Category'Pos (Status.Category));
      Ada.Text_IO.Put (":");
      Put_Number (Ada.Text_IO.Standard_Output, Wuffs.U64 (Status.Code));
      Ada.Text_IO.Put (" in=");
      Put_Number (Ada.Text_IO.Standard_Output, IO.Reader_Position (Src_Meta));
      Ada.Text_IO.Put (" tokens=");
      Put_Number (Ada.Text_IO.Standard_Output, Tokens);
      Ada.Text_IO.Put (" tokhash=");
      Put_Hex_64 (Tok_Hash);
      Ada.Text_IO.Put (" callhash=");
      Put_Hex_64 (Call_Hash);
      Ada.Text_IO.New_Line;

      if Dump /= 0 then
         Put_Number (Index_File, Wuffs.Status_Category'Pos (Status.Category));
         Ada.Text_IO.Put (Index_File, " ");
         Put_Number (Index_File, Wuffs.U64 (Status.Code));
         Ada.Text_IO.Put (Index_File, " ");
         Put_Number (Index_File, IO.Reader_Position (Src_Meta));
         Ada.Text_IO.New_Line (Index_File);
      end if;
      Test_Support.Check (True, "ran");
   end Run;

   function Rnd (N : Wuffs.Index) return Wuffs.Index is
   begin
      Rng := Rng * 6_364_136_223_846_793_005 + 1_442_695_040_888_963_407;
      return Wuffs.Index (Interfaces.Shift_Right (Rng, 33) mod Wuffs.U64 (N));
   end Rnd;

   procedure Chaos (F : Format; Quirks : Wuffs.U32; In_Length : Wuffs.Index; Seed : Natural) is
      use type Wuffs.Status;
      In_Pos   : Wuffs.Index := 0;
      Hold_Len : Wuffs.Index := 0;
      St       : Wuffs.Status := Wuffs.Base.Suspension_Short_Read;
      Calls    : Natural := 0;
      Planned  : Boolean;
      Src_At, Src_Ri, Src_Cap, Tok_At, Tok_Len, Old_Wi, Old_Ri, Feed, Work_Len : Wuffs.Index;
      Corrupt_At : Wuffs.Index;
      Pos        : Wuffs.U64;
      Closed     : Boolean;
      Src_Meta : IO.Buffer_Meta;
      Dst_Meta : Tok.Token_Buffer_Meta;
      Good     : Tok.Token_Buffer_Meta;
   begin
      Chaos_Runs := Chaos_Runs + 1;
      Rng := Wuffs.U64 (Seed) * 16#9E37_79B9_7F4A_7C15#;
      Initialize (F, Quirks);
      while Calls < 4 * Natural (In_Length) + 100 loop
         Calls := Calls + 1;
         --  More of the input, now and then one byte of it corrupted.
         Feed := Wuffs.Index'Min (In_Length - In_Pos, Rnd (150));
         Feed := Wuffs.Index'Min (Feed, TS.Chaos_Hold'Length - 1024 - Hold_Len);
         TS.Chaos_Hold (Hold_Len .. Hold_Len + Feed - 1) := TS.Input (In_Pos .. In_Pos + Feed - 1);
         Hold_Len := Hold_Len + Feed;
         In_Pos := In_Pos + Feed;
         --  (Every random draw is a statement of its own: Ada leaves the
         --  order of evaluation within an expression, or between the two
         --  sides of an assignment, to the compiler.)
         if Hold_Len > 0 and then Rnd (16) = 0 then
            Corrupt_At := Rnd (Hold_Len);
            TS.Chaos_Hold (Corrupt_At) := Wuffs.U8 (Rnd (256));
         end if;
         --  The source: read bytes, the unread ones, and room, somewhere in
         --  the arena's first half.
         Src_Ri := Rnd (8);
         Src_Cap := Src_Ri + Hold_Len + Rnd (20);
         Src_At := Rnd (32_768 - Src_Cap);
         for I in 0 .. Src_Ri - 1 loop
            TS.Chaos_Bytes (Src_At + I) := Wuffs.U8 (Rnd (256));
         end loop;
         TS.Chaos_Bytes (Src_At + Src_Ri .. Src_At + Src_Ri + Hold_Len - 1) :=
           TS.Chaos_Hold (0 .. Hold_Len - 1);
         Pos := Wuffs.U64 (Rnd (1000));
         Closed := In_Pos = In_Length and then Rnd (8) /= 0;
         Src_Meta := (Wi => Src_Ri + Hold_Len, Ri => Src_Ri, Pos => Pos, Closed => Closed);
         --  The tokens: 0 .. 5 of them, some already written and read.
         Tok_Len := Rnd (6);
         Tok_At := Rnd (1000);
         Old_Wi := Rnd (Tok_Len + 1);
         Old_Ri := Rnd (Old_Wi + 1);
         Pos := Wuffs.U64 (Rnd (1000));
         Closed := Rnd (16) = 0;
         Dst_Meta := (Wi => Old_Wi, Ri => Old_Ri, Pos => Pos, Closed => Closed);
         Work_Len := Rnd (TS.Chaos_Work'Length + 1);
         Planned := Rnd (40) = 0;
         if Planned then
            Chaos_Rejected := Chaos_Rejected + 1;
            Good := Dst_Meta;
            --  (An empty source overlaps nothing: then always the first.)
            if Rnd (2) = 0 or else Src_Cap = 0 then
               --  A write index beyond the token array.
               Dst_Meta.Wi := Tok_Len + 1 + Rnd (3);
               St := Call (F, TS.Tok_Work (Tok_At .. Tok_At + Tok_Len - 1), Dst_Meta,
                           TS.Chaos_Bytes (Src_At .. Src_At + Src_Cap - 1), Src_Meta);
            else
               --  Tokens that overlap the source (by its first byte).
               declare
                  T : constant Wuffs.Index := Src_At / 8;
               begin
                  Dst_Meta := Tok.Empty_Meta;
                  St := Call (F, TS.Chaos_Arena (T .. T + 1), Dst_Meta,
                              TS.Chaos_Bytes (Src_At .. Src_At + Src_Cap - 1), Src_Meta);
               end;
            end if;
            Test_Support.Check (St = Wuffs.Base.Error_Bad_Argument, "chaos: not rejected", Seed);
            Dst_Meta := Good;
            St := Call (F, TS.Tok_Work (Tok_At .. Tok_At + Tok_Len - 1), Dst_Meta,
                        TS.Chaos_Bytes (Src_At .. Src_At + Src_Cap - 1), Src_Meta);
            Test_Support.Check
              (St = Wuffs.Base.Error_Disabled_By_Previous_Error, "chaos: not disabled", Seed);
            --  From the start again.
            Initialize (F, Quirks);
            In_Pos := 0;
            Hold_Len := 0;
            St := Wuffs.Base.Suspension_Short_Read;
         else
            Chaos_Calls := Chaos_Calls + 1;
            case F is
               when Json =>
                  St := TS.Json_Decoder.Decode_Tokens
                    (A_Dst      => TS.Tok_Work (Tok_At .. Tok_At + Tok_Len - 1),
                     A_Dst_Meta => Dst_Meta,
                     A_Src      => TS.Chaos_Bytes (Src_At .. Src_At + Src_Cap - 1),
                     A_Src_Meta => Src_Meta,
                     A_Workbuf  => TS.Chaos_Work (0 .. Work_Len - 1));
               when Cbor =>
                  St := TS.Cbor_Decoder.Decode_Tokens
                    (A_Dst      => TS.Tok_Work (Tok_At .. Tok_At + Tok_Len - 1),
                     A_Dst_Meta => Dst_Meta,
                     A_Src      => TS.Chaos_Bytes (Src_At .. Src_At + Src_Cap - 1),
                     A_Src_Meta => Src_Meta,
                     A_Workbuf  =>
                       TS.Chaos_Work (TS.Chaos_Work'Last - Work_Len + 1 .. TS.Chaos_Work'Last));
            end case;
            Test_Support.Check
              (St /= Wuffs.Base.Error_Bad_Argument
               and then St /= Wuffs.Base.Error_Disabled_By_Previous_Error,
               "chaos: rejected", Seed);
            Test_Support.Check
              (Dst_Meta.Ri = Old_Ri and then Dst_Meta.Wi in Old_Wi .. Tok_Len
               and then Src_Meta.Wi = Src_Ri + Hold_Len
               and then Src_Meta.Ri in Src_Ri .. Src_Meta.Wi,
               "chaos: buffer positions", Seed);
            Hash_64 (Chaos_Hash, Wuffs.Status_Category'Pos (St.Category));
            Hash_64 (Chaos_Hash, Wuffs.U64 (St.Code));
            Hash_64 (Chaos_Hash, Wuffs.U64 (Dst_Meta.Wi));
            Hash_64 (Chaos_Hash, Wuffs.U64 (Src_Meta.Ri));
            exit when St.Category /= Wuffs.Suspension;
            --  What has been read is dropped.
            TS.Chaos_Hold (0 .. Src_Meta.Wi - Src_Meta.Ri - 1) :=
              TS.Chaos_Bytes (Src_At + Src_Meta.Ri .. Src_At + Src_Meta.Wi - 1);
            Hold_Len := Src_Meta.Wi - Src_Meta.Ri;
         end if;
      end loop;
   end Chaos;

   procedure Do_Case (Line : String) is
      Sp     : array (1 .. 3) of Natural := [others => 0];
      K      : Natural := 0;
      F      : Format;
      Quirks : Wuffs.U32 := 0;
      In_Length : Wuffs.Index;
      OK     : Boolean;
      Slash  : Natural;
      Dump   : Natural := 0;
   begin
      if Line = "chaos" then
         Chaos_On := True;
         return;
      end if;
      if Line'Length > 5 and then Line (Line'First .. Line'First + 4) = "dump " then
         if Dumping or else Line'Length - 5 > Dump_Dir'Length then
            Test_Support.Check (False, "a second or too long dump line", -1, Line);
            return;
         end if;
         Dumping := True;
         Dump_Last := Line'Length - 5;
         Dump_Dir (1 .. Dump_Last) := Line (Line'First + 5 .. Line'Last);
         declare
            File_Name : String (1 .. Dump_Dir'Length + 10);
         begin
            File_Name (1 .. Dump_Last) := Dump_Dir (1 .. Dump_Last);
            File_Name (Dump_Last + 1 .. Dump_Last + 10) := "/index.txt";
            Ada.Text_IO.Create (Index_File, Ada.Text_IO.Out_File, File_Name (1 .. Dump_Last + 10));
         end;
         return;
      end if;
      for I in Line'Range loop
         if Line (I) = ' ' and then K < Sp'Last then
            K := K + 1;
            Sp (K) := I;
         end if;
      end loop;
      if K < 3 or else Sp (3) = Line'Last then
         Test_Support.Check (False, "malformed manifest line", -1, Line);
         return;
      end if;
      declare
         Kind    : String renames Line (Line'First .. Sp (1) - 1);
         Q       : String renames Line (Sp (1) + 1 .. Sp (2) - 1);
         In_Name : String renames Line (Sp (2) + 1 .. Sp (3) - 1);
         Check   : String renames Line (Sp (3) + 1 .. Line'Last);
      begin
         if Kind = "json" then
            F := Json;
         elsif Kind = "cbor" then
            F := Cbor;
         else
            Test_Support.Check (False, "unknown format", -1, Line);
            return;
         end if;
         for C of Q loop
            Quirks := Quirks * 16
              + (case C is
                   when '0' .. '9' => Character'Pos (C) - Character'Pos ('0'),
                   when 'A' .. 'F' => Character'Pos (C) - Character'Pos ('A') + 10,
                   when 'a' .. 'f' => Character'Pos (C) - Character'Pos ('a') + 10,
                   when others => 0);
         end loop;
         Load (In_Name, In_Length, OK);
         Test_Support.Check (OK, "cannot load", -1, In_Name);
         if not OK then
            return;
         end if;

         Slash := In_Name'First - 1;
         for I in In_Name'Range loop
            if In_Name (I) = '/' then
               Slash := I;
            end if;
         end loop;

         Cases := Cases + 1;
         if Dumping and then Check /= "-" then
            Dump := Cases;
            Put_Number (Index_File, Wuffs.U64 (Dump));
            Ada.Text_IO.Put (Index_File, " ");
            Ada.Text_IO.Put (Index_File, Kind);
            Ada.Text_IO.Put (Index_File, " ");
            Ada.Text_IO.Put (Index_File, Q);
            Ada.Text_IO.Put (Index_File, " ");
            Ada.Text_IO.Put (Index_File, In_Name);
            Ada.Text_IO.Put (Index_File, " ");
            Ada.Text_IO.Put (Index_File, Check);
            Ada.Text_IO.Put (Index_File, " ");
         end if;
         if In_Length > Reduced_Above then
            for I in Reduced_Schedules'Range loop
               Run (F, Quirks, In_Name (Slash + 1 .. In_Name'Last), In_Length,
                    Reduced_Schedules (I),
                    (if I = 1 then Dump else 0));
            end loop;
         else
            for I in Full_Schedules'Range loop
               Run (F, Quirks, In_Name (Slash + 1 .. In_Name'Last), In_Length, Full_Schedules (I),
                    (if I = 1 then Dump else 0));
            end loop;
         end if;
         if Chaos_On and then Cases mod 3 = 0 then
            Chaos (F, Quirks, In_Length, Cases);
         end if;
      end;
   end Do_Case;

   --  What upstream's C does around the decoding itself (read off the Wuffs
   --  sources: the "@end of data" note, the quirk keys, workbuf_len).
   procedure Check_Lifecycle is
      use type Wuffs.Status;
      Src      : constant Wuffs.Bytes (10 .. 13) :=
        [Character'Pos ('['), Character'Pos (']'), 0, 0];
      Src_Meta : IO.Buffer_Meta;
      Dst_Meta : Tok.Token_Buffer_Meta := Tok.Empty_Meta;
      Status   : Wuffs.Status;
   begin
      for F in Format loop
         case F is
            when Json => Wuffs.Std.Json.Initialize (TS.Json_Decoder);
            when Cbor => Wuffs.Std.Cbor.Initialize (TS.Cbor_Decoder);
         end case;
         --  json: "[]" then two zero bytes; cbor: 0x5B (a byte string with
         --  an 8-byte length) that is cut short.
         Src_Meta := IO.Reader_Meta (Data_Length => 2, Closed => True);
         Dst_Meta := Tok.Empty_Meta;
         Status := Call (F, TS.Tok_Work (0 .. 99), Dst_Meta, Src, Src_Meta);
         if F = Json then
            Test_Support.Check (Status = Wuffs.Ok_Status, "json: [] is ok");
            Test_Support.Check (Dst_Meta.Wi = 2 and then Src_Meta.Ri = 2, "json: [] is two tokens");
            Status := Call (F, TS.Tok_Work (0 .. 99), Dst_Meta, Src, Src_Meta);
            Test_Support.Check (Status = Wuffs.Base.Note_End_Of_Data, "json: end of data");
         else
            Test_Support.Check (Status = Wuffs.Std.Cbor.Error_Bad_Input, "cbor: [ is bad input");
         end if;
      end loop;
      Wuffs.Std.Json.Initialize (TS.Json_Decoder);
      Test_Support.Check
        (TS.Json_Decoder.Workbuf_Len = Wuffs.Base.Ranges.Make_Range_II_U64 (0, 0),
         "json workbuf_len");
      Test_Support.Check
        (TS.Json_Decoder.Set_Quirk (Json_Quirks_Base + Json_Quirks_Count, 1)
         = Wuffs.Base.Error_Unsupported_Option, "json set_quirk beyond the last");
      Test_Support.Check
        (TS.Json_Decoder.Set_Quirk (Json_Quirks_Base - 1, 1) = Wuffs.Base.Error_Unsupported_Option,
         "json set_quirk before the first");
      Test_Support.Check_U64
        (TS.Json_Decoder.Get_Quirk (Json_Quirks_Base - 1), 0, "json get_quirk");
      Test_Support.Check
        (TS.Json_Decoder.Set_Quirk (Wuffs.Std.Json.QUIRK_REPLACE_INVALID_UNICODE, 7)
         = Wuffs.Ok_Status,
         "json set_quirk");
      Test_Support.Check_U64
        (TS.Json_Decoder.Get_Quirk (Wuffs.Std.Json.QUIRK_REPLACE_INVALID_UNICODE), 1,
         "json get_quirk 1");
      Test_Support.Check
        (TS.Json_Decoder.Set_Quirk (Wuffs.Std.Json.QUIRK_REPLACE_INVALID_UNICODE, 0)
         = Wuffs.Ok_Status,
         "json set_quirk 0");
      Test_Support.Check_U64
        (TS.Json_Decoder.Get_Quirk (Wuffs.Std.Json.QUIRK_REPLACE_INVALID_UNICODE), 0,
         "json get_quirk 0");
      Wuffs.Std.Cbor.Initialize (TS.Cbor_Decoder);
      Test_Support.Check
        (TS.Cbor_Decoder.Workbuf_Len = Wuffs.Base.Ranges.Make_Range_II_U64 (0, 0),
         "cbor workbuf_len");
      Test_Support.Check
        (TS.Cbor_Decoder.Set_Quirk (Json_Quirks_Base, 1) = Wuffs.Base.Error_Unsupported_Option,
         "cbor set_quirk");
      Test_Support.Check_U64 (TS.Cbor_Decoder.Get_Quirk (Json_Quirks_Base), 0, "cbor get_quirk");
   end Check_Lifecycle;

   Line : String renames TS.Line;
   Last : Natural;

begin
   Ada.Text_IO.Put ("test_tokens: record sizes (bytes): json decoder");
   Ada.Text_IO.Put (Natural'Image (TS.Json_Decoder'Size / 8));
   Ada.Text_IO.Put (", cbor decoder");
   Ada.Text_IO.Put_Line (Natural'Image (TS.Cbor_Decoder'Size / 8));
   Check_Lifecycle;
   while not Ada.Text_IO.End_Of_File loop
      Ada.Text_IO.Get_Line (Line, Last);
      if Last > 0 then
         Do_Case (Line (1 .. Last));
      end if;
   end loop;
   if Dumping then
      Ada.Text_IO.Close (Index_File);
   end if;
   if Chaos_On then
      Ada.Text_IO.Put ("test_tokens: chaos runs:");
      Ada.Text_IO.Put (Chaos_Runs'Image);
      Ada.Text_IO.Put (", calls:");
      Ada.Text_IO.Put (Chaos_Calls'Image);
      Ada.Text_IO.Put (", calls rejected as planned:");
      Ada.Text_IO.Put (Chaos_Rejected'Image);
      Ada.Text_IO.Put (", digest of the results ");
      Put_Hex_64 (Chaos_Hash);
      Ada.Text_IO.New_Line;
   end if;
   Ada.Text_IO.Put ("test_tokens: cases:");
   Ada.Text_IO.Put (Cases'Image);
   Ada.Text_IO.Put (", runs:");
   Ada.Text_IO.Put_Line (Runs'Image);
   Test_Support.Finish ("test_tokens");
end Test_Tokens;
