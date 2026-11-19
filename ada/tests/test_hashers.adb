--  Tests the generated Wuffs.Std.Adler32 and Wuffs.Std.Crc32 hashers.
--
--  1. Fixed vectors with independently known checksums.
--  2. Files: each line of standard input is "ADLER32 CRC32 PATH" (hexadecimal
--     checksums, as printed by ada/tests/hashexpect, which computes them with
--     Go's standard library).  The summary says how many files were checked.
--
--  All data is hashed in one piece and again in pieces of several awkward
--  sizes, to exercise the hashers' state across Update calls, and always
--  through the Wuffs.Runtime.Hasher_U32 interface (dynamic dispatch).
--
--  Exits with a failure status if any check fails.

with Ada.Streams.Stream_IO;
with Ada.Text_IO;
with Test_Support;
with Wuffs.Runtime.Temp_Base;
with Wuffs.Std.Adler32;
with Wuffs.Std.Crc32;

procedure Test_Hashers is

   use type Wuffs.U32;
   use type Wuffs.Status;
   use type Wuffs.Offset;
   use type Ada.Streams.Stream_Element_Offset;
   use type Ada.Streams.Stream_IO.Count;

   Adler : Wuffs.Std.Adler32.Hasher;
   Crc   : Wuffs.Std.Crc32.Ieee_Hasher;

   Files : Natural := 0;

   type Size_List is array (Positive range <>) of Wuffs.Index;

   Chunk_Sizes : constant Size_List := [1, 2, 3, 7, 8, 9, 31, 32, 33, 4095, 4096, 4097];

   function Feed
     (H : in out Wuffs.Runtime.Hasher_U32'Class; Data : Wuffs.Bytes; Sizes : Size_List)
      return Wuffs.U32;

   procedure Check_Data (Data : Wuffs.Bytes; Want_Adler, Want_Crc : Wuffs.U32; What : String);

   procedure Check_Text (Text : String; Want_Adler, Want_Crc : Wuffs.U32);

   procedure Check_Lifecycle;

   function Hex_Value (C : Character; OK : in out Boolean) return Wuffs.U32;

   procedure Load (Name : String; Length : out Wuffs.Index; OK : out Boolean);

   procedure Check_Files;

   --  Feeds Data to H (which the caller has just initialized), cycling
   --  through the chunk sizes in Sizes, and returns the last Update_U32
   --  result.
   function Feed
     (H : in out Wuffs.Runtime.Hasher_U32'Class; Data : Wuffs.Bytes; Sizes : Size_List)
      return Wuffs.U32
   is
      Pos    : Wuffs.Offset := Data'First;
      N      : Wuffs.Index;
      K      : Positive := Sizes'First;
      Result : Wuffs.U32;
   begin
      if Data'Length = 0 then
         --  One update with nothing.  (Without any update at all, the Wuffs
         --  Adler-32 hasher reports 0, not 1: see Check_Lifecycle.)
         return H.Update_U32 (Data);
      end if;
      Result := 0;
      while Pos <= Data'Last loop
         N := Wuffs.Index'Min (Sizes (K), Data'Last - Pos + 1);
         Result := H.Update_U32 (Data (Pos .. Pos + N - 1));
         Pos := Pos + N;
         K := (if K = Sizes'Last then Sizes'First else K + 1);
      end loop;
      return Result;
   end Feed;

   procedure Check_Data (Data : Wuffs.Bytes; Want_Adler, Want_Crc : Wuffs.U32; What : String) is
      Got : Wuffs.U32;
      N   : Integer;
   begin
      --  In one piece, with the procedure form of Update.
      Wuffs.Std.Adler32.Initialize (Adler);
      Adler.Update (Data);
      Test_Support.Check_U32 (Adler.Checksum_U32, Want_Adler, "adler32, one piece", -1, What);
      Wuffs.Std.Crc32.Initialize (Crc);
      Crc.Update (Data);
      Test_Support.Check_U32 (Crc.Checksum_U32, Want_Crc, "crc32, one piece", -1, What);

      --  In pieces of each size.
      for I in Chunk_Sizes'Range loop
         N := Integer (Chunk_Sizes (I));

         Wuffs.Std.Adler32.Initialize (Adler);
         Got := Feed (Adler, Data, Chunk_Sizes (I .. I));
         Test_Support.Check_U32 (Got, Want_Adler, "adler32 Update_U32, pieces of", N, What);
         Test_Support.Check_U32
           (Adler.Checksum_U32, Want_Adler, "adler32 Checksum_U32, pieces of", N, What);

         Wuffs.Std.Crc32.Initialize (Crc);
         Got := Feed (Crc, Data, Chunk_Sizes (I .. I));
         Test_Support.Check_U32 (Got, Want_Crc, "crc32 Update_U32, pieces of", N, What);
         Test_Support.Check_U32
           (Crc.Checksum_U32, Want_Crc, "crc32 Checksum_U32, pieces of", N, What);
      end loop;

      --  In pieces of mixed sizes.
      Wuffs.Std.Adler32.Initialize (Adler);
      Got := Feed (Adler, Data, Chunk_Sizes);
      Test_Support.Check_U32 (Got, Want_Adler, "adler32, mixed pieces", -1, What);
      Wuffs.Std.Crc32.Initialize (Crc);
      Got := Feed (Crc, Data, Chunk_Sizes);
      Test_Support.Check_U32 (Got, Want_Crc, "crc32, mixed pieces", -1, What);
   end Check_Data;

   --  Copies Text into the shared buffer at a non-zero offset (so that the
   --  slices passed down do not start at index zero) and checks it.
   procedure Check_Text (Text : String; Want_Adler, Want_Crc : Wuffs.U32) is
      Base : constant Wuffs.Index := 5;
      Pos  : Wuffs.Index := Base;
   begin
      for C of Text loop
         Test_Support.Buffer (Pos) := Character'Pos (C);
         Pos := Pos + 1;
      end loop;
      Check_Data (Test_Support.Buffer (Base .. Pos - 1), Want_Adler, Want_Crc, Text);
   end Check_Text;

   procedure Check_Lifecycle is
      A : Wuffs.Std.Adler32.Hasher;
      C : Wuffs.Std.Crc32.Ieee_Hasher;
      D : constant Wuffs.Bytes (1 .. 3) := [97, 98, 99];
   begin
      --  Before Initialize, everything is a no-op.
      A.Update (D);
      C.Update (D);
      Test_Support.Check_U32 (A.Checksum_U32, 0, "adler32 checksum before Initialize");
      Test_Support.Check_U32 (C.Checksum_U32, 0, "crc32 checksum before Initialize");
      Test_Support.Check_U32 (A.Update_U32 (D), 0, "adler32 Update_U32 before Initialize");
      Test_Support.Check_U32 (C.Update_U32 (D), 0, "crc32 Update_U32 before Initialize");
      Test_Support.Check
        (A.Set_Quirk (1, 2) = Wuffs.Runtime.Temp_Base.Error_Initialize_Not_Called,
         "adler32 Set_Quirk before Initialize");
      Test_Support.Check
        (C.Set_Quirk (1, 2) = Wuffs.Runtime.Temp_Base.Error_Initialize_Not_Called,
         "crc32 Set_Quirk before Initialize");

      Wuffs.Std.Adler32.Initialize (A);
      Wuffs.Std.Crc32.Initialize (C);
      Test_Support.Check
        (A.Set_Quirk (1, 2) = Wuffs.Runtime.Temp_Base.Error_Unsupported_Option,
         "adler32 Set_Quirk");
      Test_Support.Check
        (C.Set_Quirk (1, 2) = Wuffs.Runtime.Temp_Base.Error_Unsupported_Option, "crc32 Set_Quirk");
      Test_Support.Check_U64 (A.Get_Quirk (1), 0, "adler32 Get_Quirk");
      Test_Support.Check_U64 (C.Get_Quirk (1), 0, "crc32 Get_Quirk");

      --  A freshly initialized hasher, given nothing.  (Adler-32 of nothing
      --  is 1, but the Wuffs hasher only reports that once updated.)
      Test_Support.Check_U32 (A.Checksum_U32, 0, "adler32 checksum of no updates");
      Test_Support.Check_U32 (C.Checksum_U32, 0, "crc32 checksum of no updates");

      --  Initialize again resets the state.
      A.Update (D);
      Wuffs.Std.Adler32.Initialize (A);
      Test_Support.Check_U32 (A.Update_U32 (D), 16#024D_0127#, "adler32 after re-Initialize");
      C.Update (D);
      Wuffs.Std.Crc32.Initialize (C);
      Test_Support.Check_U32 (C.Update_U32 (D), 16#3524_41C2#, "crc32 after re-Initialize");
   end Check_Lifecycle;

   function Hex_Value (C : Character; OK : in out Boolean) return Wuffs.U32 is
   begin
      case C is
         when '0' .. '9' =>
            return Character'Pos (C) - Character'Pos ('0');
         when 'A' .. 'F' =>
            return Character'Pos (C) - Character'Pos ('A') + 10;
         when 'a' .. 'f' =>
            return Character'Pos (C) - Character'Pos ('a') + 10;
         when others =>
            OK := False;
            return 0;
      end case;
   end Hex_Value;

   --  Reads the file called Name into the shared buffer.
   procedure Load (Name : String; Length : out Wuffs.Index; OK : out Boolean) is
      package SIO renames Ada.Streams.Stream_IO;
      File : SIO.File_Type;
      Size : SIO.Count;
   begin
      Length := 0;
      OK := False;
      SIO.Open (File, SIO.In_File, Name);
      Size := SIO.Size (File);
      if Size <= Test_Support.Buffer_Size then
         if Size > 0 then
            declare
               subtype SEO is Ada.Streams.Stream_Element_Offset;
               Item : Ada.Streams.Stream_Element_Array (1 .. SEO (Size))
               with Import, Address => Test_Support.Buffer'Address;
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

   procedure Check_Files is
      Line : String (1 .. 4096);
      Last : Natural;
   begin
      while not Ada.Text_IO.End_Of_File loop
         Ada.Text_IO.Get_Line (Line, Last);
         if Last > 0 then
            declare
               OK         : Boolean := Last > 18 and then Line (9) = ' ' and then Line (18) = ' ';
               Want_Adler : Wuffs.U32 := 0;
               Want_Crc   : Wuffs.U32 := 0;
               Length     : Wuffs.Index := 0;
            begin
               if OK then
                  for I in 1 .. 8 loop
                     Want_Adler := Want_Adler * 16 + Hex_Value (Line (I), OK);
                     Want_Crc := Want_Crc * 16 + Hex_Value (Line (9 + I), OK);
                  end loop;
               end if;
               Test_Support.Check (OK, "malformed line", -1, Line (1 .. Last));
               if OK then
                  Load (Line (19 .. Last), Length, OK);
                  Test_Support.Check (OK, "cannot load", -1, Line (19 .. Last));
               end if;
               if OK then
                  Files := Files + 1;
                  Check_Data
                    (Test_Support.Buffer (0 .. Length - 1),
                     Want_Adler,
                     Want_Crc,
                     Line (19 .. Last));
               end if;
            end;
         end if;
      end loop;
   end Check_Files;

begin
   Check_Lifecycle;

   --  Adler-32 and CRC-32/IEEE of well-known inputs.  "123456789" is the
   --  standard check input of the CRC catalogues.
   Check_Text ("", 16#0000_0001#, 16#0000_0000#);
   Check_Text ("a", 16#0062_0062#, 16#E8B7_BE43#);
   Check_Text ("abc", 16#024D_0127#, 16#3524_41C2#);
   Check_Text ("123456789", 16#091E_01DE#, 16#CBF4_3926#);
   Check_Text ("message digest", 16#29750586#, 16#20159D7F#);
   Check_Text ("The quick brown fox jumps over the lazy dog", 16#5BDC_0FDA#, 16#414F_A339#);

   Check_Files;
   Ada.Text_IO.Put ("test_hashers: files checked:");
   Ada.Text_IO.Put_Line (Files'Image);
   Test_Support.Finish ("test_hashers");
end Test_Hashers;
