--  Part of wuffada (wuffs-ada: Wuffs to Ada).
--  SPDX-License-Identifier: Apache-2.0 OR MIT

--  Tests the generated Wuffs.Std.Xxhash32, Wuffs.Std.Xxhash64, Wuffs.Std.Crc64
--  and Wuffs.Std.Sha256 hashers against an independent implementation
--  (ada/tests/hashexpect2), whose output for a list of files is this
--  program's standard input: lines "XXHASH32 XXHASH64 CRC64 SHA256 PATH".  Each file
--  is hashed in one piece and in pieces of several sizes.

with Ada.Streams.Stream_IO;
with Ada.Text_IO;
with Test_Support;
with Wuffs.Base;
with Wuffs.Runtime;
with Wuffs.Base.Ints;
with Wuffs.Std.Crc64;
with Wuffs.Std.Sha256;
with Wuffs.Std.Xxhash32;
with Wuffs.Std.Xxhash64;

procedure Test_Hashers2 is

   use type Wuffs.U32;
   use type Wuffs.U64;
   use type Wuffs.Index;
   use type Wuffs.Status;
   use type Wuffs.Base.Ints.Bitvec256;
   use type Ada.Streams.Stream_IO.Count;

   X32 : Wuffs.Std.Xxhash32.Hasher;
   X64 : Wuffs.Std.Xxhash64.Hasher;
   C64 : Wuffs.Std.Crc64.Ecma_Hasher;
   S256 : Wuffs.Std.Sha256.Hasher;

   --  Also the lengths around crc64's SIMD block sizes (16, 32, 64, 128).
   Sizes : constant array (1 .. 16) of Wuffs.Index :=
     [1, 3, 15, 16, 17, 31, 32, 33, 63, 64, 65, 127, 128, 129, 1000, 65_537];

   Files : Natural := 0;

   procedure Load (Name : String; Length : out Wuffs.Index; OK : out Boolean);

   function Hex (S : String) return Wuffs.U64;

   function Feed_U32
     (H : in out Wuffs.Runtime.Hasher_U32'Class; Data : Wuffs.Bytes; Piece : Wuffs.Index)
      return Wuffs.U32;

   function Feed_U64
     (H : in out Wuffs.Runtime.Hasher_U64'Class; Data : Wuffs.Bytes; Piece : Wuffs.Index)
      return Wuffs.U64;

   procedure Check_File (Line : String);

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
               use type Ada.Streams.Stream_Element_Offset;
               Item : Ada.Streams.Stream_Element_Array
                        (1 .. Ada.Streams.Stream_Element_Offset (Size))
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

   function Hex (S : String) return Wuffs.U64 is
      V : Wuffs.U64 := 0;
   begin
      for C of S loop
         V :=
           V * 16
           + (case C is
                when '0' .. '9' => Character'Pos (C) - Character'Pos ('0'),
                when 'A' .. 'F' => Character'Pos (C) - Character'Pos ('A') + 10,
                when others => 0);
      end loop;
      return V;
   end Hex;

   function Feed_U32
     (H : in out Wuffs.Runtime.Hasher_U32'Class; Data : Wuffs.Bytes; Piece : Wuffs.Index)
      return Wuffs.U32
   is
      Pos : Wuffs.Index := Data'First;
      N   : Wuffs.Index;
   begin
      while Pos <= Data'Last loop
         N := Wuffs.Index'Min (Piece, Data'Last - Pos + 1);
         H.Update (Data (Pos .. Pos + N - 1));
         Pos := Pos + N;
      end loop;
      return H.Checksum_U32;
   end Feed_U32;

   function Feed_U64
     (H : in out Wuffs.Runtime.Hasher_U64'Class; Data : Wuffs.Bytes; Piece : Wuffs.Index)
      return Wuffs.U64
   is
      Pos : Wuffs.Index := Data'First;
      N   : Wuffs.Index;
      V   : Wuffs.U64 := 0;
   begin
      while Pos <= Data'Last loop
         N := Wuffs.Index'Min (Piece, Data'Last - Pos + 1);
         V := H.Update_U64 (Data (Pos .. Pos + N - 1));
         Pos := Pos + N;
      end loop;
      Test_Support.Check
        (Data'Length = 0 or else V = H.Checksum_U64, "update_u64 and checksum_u64 differ");
      return H.Checksum_U64;
   end Feed_U64;

   procedure Check_File (Line : String) is
      --  8 + 1 + 16 + 1 + 16 + 1 + 64 + 1 characters, then the name.  The
      --  SHA-256 digest's first 16 digits are element 3 of the bit vector.
      Name   : String renames Line (Line'First + 108 .. Line'Last);
      Want32 : constant Wuffs.U32 := Wuffs.U32 (Hex (Line (Line'First .. Line'First + 7)));
      Want64 : constant Wuffs.U64 := Hex (Line (Line'First + 9 .. Line'First + 24));
      WantC  : constant Wuffs.U64 := Hex (Line (Line'First + 26 .. Line'First + 41));
      WantS  : constant Wuffs.Base.Ints.Bitvec256 :=
        [3 => Hex (Line (Line'First + 43 .. Line'First + 58)),
         2 => Hex (Line (Line'First + 59 .. Line'First + 74)),
         1 => Hex (Line (Line'First + 75 .. Line'First + 90)),
         0 => Hex (Line (Line'First + 91 .. Line'First + 106))];
      Length : Wuffs.Index;
      OK     : Boolean;
   begin
      Load (Name, Length, OK);
      if not OK then
         Test_Support.Check (False, "cannot read ", -1, Name);
         return;
      end if;
      Files := Files + 1;
      declare
         Data : Wuffs.Bytes renames Test_Support.Buffer (0 .. Length - 1);
      begin
         Wuffs.Std.Xxhash32.Initialize (X32);
         Test_Support.Check_U32 (X32.Update_U32 (Data), Want32, "xxhash32, one piece: ", -1, Name);
         Wuffs.Std.Xxhash64.Initialize (X64);
         Test_Support.Check_U64 (X64.Update_U64 (Data), Want64, "xxhash64, one piece: ", -1, Name);
         Wuffs.Std.Crc64.Initialize (C64);
         Test_Support.Check_U64 (C64.Update_U64 (Data), WantC, "crc64, one piece: ", -1, Name);
         Wuffs.Std.Sha256.Initialize (S256);
         Test_Support.Check (S256.Update_Bitvec256 (Data) = WantS, "sha256, one piece: ", -1, Name);
         for Piece of Sizes loop
            if Piece > 3 or else Length <= 100_000 then
               Wuffs.Std.Sha256.Initialize (S256);
               declare
                  Pos : Wuffs.Index := 0;
                  N   : Wuffs.Index;
               begin
                  --  (At least one call, also for no data: upstream's hasher
                  --  sets up its state in update.)
                  loop
                     N := Wuffs.Index'Min (Piece, Length - Pos);
                     S256.Update (Data (Pos .. Pos + N - 1));
                     Pos := Pos + N;
                     exit when Pos >= Length;
                  end loop;
               end;
               Test_Support.Check
                 (S256.Checksum_Bitvec256 = WantS, "sha256, pieces of", Integer (Piece), Name);
            end if;
         end loop;
         for Piece of Sizes loop
            --  (Single bytes only for the smaller files.)
            if Piece > 3 or else Length <= 100_000 then
               Wuffs.Std.Xxhash32.Initialize (X32);
               Test_Support.Check_U32
                 (Feed_U32 (X32, Data, Piece), Want32, "xxhash32, pieces of",
                  Integer (Piece), Name);
               Wuffs.Std.Xxhash64.Initialize (X64);
               Test_Support.Check_U64
                 (Feed_U64 (X64, Data, Piece), Want64, "xxhash64, pieces of",
                  Integer (Piece), Name);
               Wuffs.Std.Crc64.Initialize (C64);
               Test_Support.Check_U64
                 (Feed_U64 (C64, Data, Piece), WantC, "crc64, pieces of", Integer (Piece), Name);
            end if;
         end loop;
         --  crc64 at every alignment (mod 64) of the first byte: in one
         --  piece for files up to 256 KiB, in pieces of each size up to 129
         --  for files up to 16 KiB.
         if Length <= 256 * 1024 then
            for K in 0 .. 63 loop
               declare
                  First : Wuffs.Index;
               begin
                  Test_Support.Unaligned_Copy (Data, K, First);
                  declare
                     Copy : Wuffs.Bytes renames Test_Support.Buffer (First .. First + Length - 1);
                  begin
                     Wuffs.Std.Crc64.Initialize (C64);
                     Test_Support.Check_U64
                       (C64.Update_U64 (Copy), WantC, "crc64, at alignment", K, Name);
                     if Length <= 16 * 1024 then
                        for Piece of Sizes (1 .. 14) loop
                           Wuffs.Std.Crc64.Initialize (C64);
                           Test_Support.Check_U64
                             (Feed_U64 (C64, Copy, Piece), WantC, "crc64, pieces, alignment", K,
                              Name);
                        end loop;
                     end if;
                  end;
               end;
            end loop;
         end if;
      end;
   end Check_File;

   Line : String (1 .. 4096);
   Last : Natural;

begin
   --  Before Initialize, and with an unsupported quirk.
   Test_Support.Check
     (X32.Update_U32 (Test_Support.Buffer (0 .. 9)) = 0, "xxhash32 before Initialize");
   Test_Support.Check
     (X64.Update_U64 (Test_Support.Buffer (0 .. 9)) = 0, "xxhash64 before Initialize");
   Test_Support.Check
     (C64.Update_U64 (Test_Support.Buffer (0 .. 9)) = 0, "crc64 before Initialize");
   Wuffs.Std.Xxhash64.Initialize (X64);
   Test_Support.Check
     (X64.Set_Quirk (A_Key => 1, A_Value => 1) = Wuffs.Base.Error_Unsupported_Option,
      "xxhash64 set_quirk");

   while not Ada.Text_IO.End_Of_File loop
      Ada.Text_IO.Get_Line (Line, Last);
      if Last > 108 then
         Check_File (Line (1 .. Last));
      end if;
   end loop;
   Ada.Text_IO.Put ("test_hashers2: files checked:");
   Ada.Text_IO.Put_Line (Files'Image);
   Test_Support.Finish ("test_hashers2");
end Test_Hashers2;
