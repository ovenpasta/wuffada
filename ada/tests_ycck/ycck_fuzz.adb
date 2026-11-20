--  The Ada side of the differential fuzz test (after the harness written
--  by the independent reviewer of the YCCK milestone).
--
--    bin/ycck_fuzz < tests_ycck/fuzz/fuzz_cases.txt
--
--  Each line of the input is one call of swizzle_ycck followed by what
--  upstream Wuffs' C did for it (fuzz/cfuzz.c says what the numbers are;
--  fuzz/regen.sh makes the file).  This program makes the same call with
--  Wuffs.Base.Pixel_Swizzler_YCCK on buffers filled the same way and
--  compares the status, a digest of the whole destination, whether the
--  destination changed, and a digest of the scratch buffer.
--
--  Prints a summary and exits with a failure status if any case differs,
--  or if there were no cases.

with Ada.Command_Line;
with Ada.Long_Long_Integer_Text_IO;
with Ada.Text_IO;
with Interfaces;
with Wuffs.Base.Pixel_Buffers;
with Wuffs.Base.Pixel_Swizzler_YCCK;
with Wuffs;
with YCCK_Fuzz_Data;

procedure YCCK_Fuzz is

   use Interfaces;
   use Wuffs;
   use Wuffs.Base.Pixel_Swizzler_YCCK;
   use YCCK_Fuzz_Data;

   package PBs renames Wuffs.Base.Pixel_Buffers;

   procedure Fill (P : out Bytes; Seed : U64; Mode : U64);
   function FNV (P : Bytes) return U64;
   procedure One_Case;

   --  The numbers of one line: 37 for the call, 6 expected.
   V : array (0 .. 42) of Long_Long_Integer := [others => 0];

   Cases      : Natural := 0;
   Mismatches : Natural := 0;
   Skipped    : Natural := 0;

   --  cfuzz.c: fill.
   procedure Fill (P : out Bytes; Seed : U64; Mode : U64) is
      X    : U64 := Seed;
      R, Q : U8;
   begin
      for B of P loop
         X := X * 6364136223846793005 + 1442695040888963407;
         R := U8 (Shift_Right (X, 56));
         Q := U8 (Shift_Right (X, 40) and 255);
         B := (if Mode = 0 then R
               elsif Mode = 1 then (if (R and 1) /= 0 then 255 else 0)
               elsif (Q and 3) = 0 then R
               elsif (R and 1) /= 0 then 255
               else 0);
      end loop;
   end Fill;

   function FNV (P : Bytes) return U64 is
      H : U64 := 16#CBF2_9CE4_8422_2325#;
   begin
      for B of P loop
         H := (H xor U64 (B)) * 16#100_0000_01B3#;
      end loop;
      return H;
   end FNV;

   procedure One_Case is
      Fmt     : constant U32 := U32 (V (0));
      DW      : constant U32 := U32 (V (1));
      DH      : constant U32 := U32 (V (2));
      P0W     : constant Index := Index (V (3));
      DStride : constant Index := Index (V (4));
      Seed    : constant U64 := Shift_Right (U64 (V (36)), 2);
      Mode    : constant U64 := U64 (V (36)) and 3;
      Off     : constant Index :=
        (if Shift_Right (Seed, 5) mod 3 = 0 then Index (Shift_Right (Seed, 8) mod 13)
         else 0);
      DM      : constant U64 := Shift_Right (Seed, 3) mod 4;
      DMode   : constant U64 := (if DM < 2 then 0 else DM - 1);
      No_Pal  : constant Boolean := Shift_Right (Seed, 12) mod 16 = 0;
      DLen    : constant Index := Off + DStride * Index (DH);
      SLen    : constant Index := Index (V (35));
      Len     : constant array (0 .. 3) of Index :=
        [Index (V (29)), Index (V (30)), Index (V (31)), Index (V (32))];
      Planes  : Source_Planes;
      PB      : PBs.Pixel_Buffer;
      Result  : Status;
      Code    : Long_Long_Integer;
      HD, HS  : U64;
      Changed : Boolean;
   begin
      if DLen > Max_Dst or else SLen > Max_Scratch
        or else (for some L of Len => L > Max_Src)
      then
         Skipped := Skipped + 1;
         return;
      end if;
      for K in 0 .. 3 loop
         Planes (K) :=
           (Width  => U32 (V (9 + 5 * K)),
            Height => U32 (V (10 + 5 * K)),
            Stride => U32 (V (11 + 5 * K)),
            H      => U8 (V (12 + 5 * K)),
            V      => U8 (V (13 + 5 * K)));
      end loop;
      Fill (Src0 (Src0'First .. Src0'First + Len (0) - 1), Seed * 8 + 0, Mode);
      Fill (Src1 (Src1'First .. Src1'First + Len (1) - 1), Seed * 8 + 1, Mode);
      Fill (Src2 (Src2'First .. Src2'First + Len (2) - 1), Seed * 8 + 2, Mode);
      Fill (Src3 (Src3'First .. Src3'First + Len (3) - 1), Seed * 8 + 3, Mode);
      Fill (Dst (Dst'First .. Dst'First + DLen - 1), Seed * 8 + 4, DMode);
      Dst0 (Dst0'First .. Dst0'First + DLen - 1) := Dst (Dst'First .. Dst'First + DLen - 1);
      Fill (Palette, Seed * 8 + 5, 0);
      Fill (Scratch (Scratch'First .. Scratch'First + SLen - 1), Seed * 8 + 6, 0);
      PB :=
        (Pixcfg => (Pixfmt => (Repr => Fmt), Pixsub => (Repr => 0), Width => DW,
                    Height => DH),
         Planes => [0      => (Offset => Off, Width => P0W, Height => Index (DH),
                               Stride => DStride),
                    3      => (if (Shift_Right (Fmt, 18) and 1) /= 0 and then not No_Pal
                               then (Offset => 0, Width => 1024, Height => 1,
                                     Stride => 1024)
                               else PBs.Empty_Table),
                    others => PBs.Empty_Table]);
      Swizzle_YCCK
        (PB                => PB,
         Pixels            => Dst (Dst'First .. Dst'First + DLen - 1),
         Palette           => Palette,
         Dst_Palette       => Palette,
         X_Min_Incl        => U32 (V (5)),
         X_Max_Excl        => U32 (V (6)),
         Y_Min_Incl        => U32 (V (7)),
         Y_Max_Excl        => U32 (V (8)),
         Src0              => Src0 (Src0'First .. Src0'First + Len (0) - 1),
         Src1              => Src1 (Src1'First .. Src1'First + Len (1) - 1),
         Src2              => Src2 (Src2'First .. Src2'First + Len (2) - 1),
         Src3              => Src3 (Src3'First .. Src3'First + Len (3) - 1),
         Planes            => Planes,
         YCC_Model         => U8 (V (33)),
         YCC_Upsampling    => U8 (V (34)),
         Scratch_Buffer_2K => Scratch (Scratch'First .. Scratch'First + SLen - 1),
         Result            => Result);
      Code := (if Result = Ok_Status then 0
               elsif Result = Wuffs.Base.Error_Bad_Argument then 1
               elsif Result = Wuffs.Base.Error_Unsupported_Pixel_Swizzler_Option then 2
               else 3);
      HD := FNV (Dst (Dst'First .. Dst'First + DLen - 1));
      HS := FNV (Scratch (Scratch'First .. Scratch'First + SLen - 1));
      Changed := Dst (Dst'First .. Dst'First + DLen - 1)
        /= Dst0 (Dst0'First .. Dst0'First + DLen - 1);
      if Code /= V (37)
        or else HD /= Shift_Left (U64 (V (38)), 32) + U64 (V (39))
        or else Boolean'Pos (Changed) /= V (40)
        or else HS /= Shift_Left (U64 (V (41)), 32) + U64 (V (42))
      then
         Mismatches := Mismatches + 1;
         if Mismatches <= 5 then
            Ada.Text_IO.Put_Line
              ("FAIL: fuzz case" & Cases'Image & ": status" & Code'Image & ", C"
               & V (37)'Image
               & (if HD /= Shift_Left (U64 (V (38)), 32) + U64 (V (39))
                  then "; destination differs" else "")
               & (if HS /= Shift_Left (U64 (V (41)), 32) + U64 (V (42))
                  then "; scratch buffer differs" else ""));
         end if;
      end if;
   end One_Case;

begin
   while not Ada.Text_IO.End_Of_File loop
      for I in V'Range loop
         Ada.Long_Long_Integer_Text_IO.Get (V (I));
      end loop;
      Ada.Text_IO.Skip_Line;
      Cases := Cases + 1;
      One_Case;
   end loop;
   Ada.Text_IO.Put_Line
     ("ycck_fuzz:" & Cases'Image & " cases," & Mismatches'Image & " differ from C,"
      & Skipped'Image & " skipped");
   if Mismatches /= 0 or else Skipped /= 0 or else Cases = 0 then
      Ada.Command_Line.Set_Exit_Status (Ada.Command_Line.Failure);
   end if;
end YCCK_Fuzz;
