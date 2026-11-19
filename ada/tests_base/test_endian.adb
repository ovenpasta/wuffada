--  Wuffs.Base.Endian.  Sweeps Endian_Peek and Endian_Poke mirror the
--  functions of the same names in oracle/oracle.c.  The arrays here do not
--  start at index 0, unlike any C pointer.

with Base_Oracle_Data;
with Base_Test_Support; use Base_Test_Support;
with Interfaces;
with Wuffs.Base.Endian;

procedure Test_Endian is

   use Wuffs;
   use Wuffs.Base.Endian;
   use type Interfaces.Unsigned_8;
   use type Interfaces.Unsigned_16;
   use type Interfaces.Unsigned_32;
   use type Interfaces.Unsigned_64;

   First : constant := 100;
   Buf   : Bytes (First .. First + 23);
   D     : Bytes (First .. First + 23);

   Poke_Offsets : constant array (0 .. 2) of Index := [0, 5, 16];

begin
   -----------------
   -- Endian_Peek --
   -----------------

   Start (4);
   Fill (Buf);
   for Off in Index range 0 .. 16 loop
      declare
         P : constant Index := First + Off;
      begin
         Mix (U64 (Peek_U8 (Buf, P)));
         Mix (U64 (Peek_U16BE (Buf, P)));
         Mix (U64 (Peek_U16LE (Buf, P)));
         Mix (U64 (Peek_U24BE (Buf, P)));
         Mix (U64 (Peek_U24LE (Buf, P)));
         Mix (U64 (Peek_U32BE (Buf, P)));
         Mix (U64 (Peek_U32LE (Buf, P)));
         Mix (Peek_U40BE (Buf, P));
         Mix (Peek_U40LE (Buf, P));
         Mix (Peek_U48BE (Buf, P));
         Mix (Peek_U48LE (Buf, P));
         Mix (Peek_U56BE (Buf, P));
         Mix (Peek_U56LE (Buf, P));
         Mix (Peek_U64BE (Buf, P));
         Mix (Peek_U64LE (Buf, P));
      end;
   end loop;
   Finish ("endian: sweep Endian_Peek", Base_Oracle_Data.Endian_Peek);

   -----------------
   -- Endian_Poke --
   -----------------

   Start (5);
   Fill (Buf);
   for Kind in 0 .. 14 loop
      for O of Poke_Offsets loop
         declare
            V   : constant U64 := Rnd;
            V32 : constant U32 := U32 (V and 16#FFFF_FFFF#);
            V16 : constant U16 := U16 (V and 16#FFFF#);
            P   : constant Index := First + O;
         begin
            D := Buf;
            case Kind is
               when 0  => Poke_U8 (D, P, U8 (V and 16#FF#));
               when 1  => Poke_U16BE (D, P, V16);
               when 2  => Poke_U16LE (D, P, V16);
               when 3  => Poke_U24BE (D, P, V32);
               when 4  => Poke_U24LE (D, P, V32);
               when 5  => Poke_U32BE (D, P, V32);
               when 6  => Poke_U32LE (D, P, V32);
               when 7  => Poke_U40BE (D, P, V);
               when 8  => Poke_U40LE (D, P, V);
               when 9  => Poke_U48BE (D, P, V);
               when 10 => Poke_U48LE (D, P, V);
               when 11 => Poke_U56BE (D, P, V);
               when 12 => Poke_U56LE (D, P, V);
               when 13 => Poke_U64BE (D, P, V);
               when 14 => Poke_U64LE (D, P, V);
            end case;
            Mix_Bytes (D);
         end;
      end loop;
   end loop;
   Finish ("endian: sweep Endian_Poke", Base_Oracle_Data.Endian_Poke);

   --------------------
   -- Explicit cases --
   --------------------

   declare
      B : constant Bytes (5 .. 12) := [16#01#, 16#02#, 16#03#, 16#04#,
                                       16#05#, 16#06#, 16#07#, 16#08#];
   begin
      Check (Peek_U8 (B, 5) = 16#01#, "endian: peek_u8 first");
      Check (Peek_U8 (B, 12) = 16#08#, "endian: peek_u8 last");
      Check (Peek_U16BE (B, 5) = 16#0102#, "endian: peek_u16be");
      Check (Peek_U16LE (B, 5) = 16#0201#, "endian: peek_u16le");
      Check (Peek_U16LE (B, 11) = 16#0807#, "endian: peek_u16le at end");
      Check (Peek_U24BE (B, 5) = 16#01_0203#, "endian: peek_u24be");
      Check (Peek_U24LE (B, 5) = 16#03_0201#, "endian: peek_u24le");
      Check (Peek_U32BE (B, 5) = 16#0102_0304#, "endian: peek_u32be");
      Check (Peek_U32LE (B, 5) = 16#0403_0201#, "endian: peek_u32le");
      Check (Peek_U32LE (B, 9) = 16#0807_0605#, "endian: peek_u32le at end");
      Check (Peek_U40BE (B, 5) = 16#01_0203_0405#, "endian: peek_u40be");
      Check (Peek_U40LE (B, 5) = 16#05_0403_0201#, "endian: peek_u40le");
      Check (Peek_U48BE (B, 5) = 16#0102_0304_0506#, "endian: peek_u48be");
      Check (Peek_U48LE (B, 5) = 16#0605_0403_0201#, "endian: peek_u48le");
      Check (Peek_U56BE (B, 5) = 16#01_0203_0405_0607#, "endian: peek_u56be");
      Check (Peek_U56LE (B, 5) = 16#07_0605_0403_0201#, "endian: peek_u56le");
      Check (Peek_U56LE (B, 6) = 16#08_0706_0504_0302#, "endian: peek_u56le at end");
      Check (Peek_U64BE (B, 5) = 16#0102_0304_0506_0708#, "endian: peek_u64be");
      Check (Peek_U64LE (B, 5) = 16#0807_0605_0403_0201#, "endian: peek_u64le");
   end;

   --  Maximal values survive (no sign or carry trouble in the top bit).
   declare
      B : constant Bytes (0 .. 7) := [others => 16#FF#];
   begin
      Check (Peek_U16BE (B, 0) = U16'Last, "endian: peek_u16be max");
      Check (Peek_U24LE (B, 0) = 16#FF_FFFF#, "endian: peek_u24le max");
      Check (Peek_U32BE (B, 0) = U32'Last, "endian: peek_u32be max");
      Check (Peek_U56BE (B, 0) = 16#FF_FFFF_FFFF_FFFF#, "endian: peek_u56be max");
      Check (Peek_U64LE (B, 0) = U64'Last, "endian: peek_u64le max");
      Check (Peek_U64BE (B, 0) = U64'Last, "endian: peek_u64be max");
   end;

   --  Arrays of exactly the width, and of length 1.
   declare
      One : Bytes (9 .. 9) := [16#00#];
      Two : Bytes (0 .. 1) := [0, 0];
      Big : Bytes (3 .. 10) := [others => 0];
   begin
      Poke_U8 (One, 9, 16#AB#);
      Check (One (9) = 16#AB# and then Peek_U8 (One, 9) = 16#AB#, "endian: length 1");
      Poke_U16BE (Two, 0, 16#1234#);
      Check (Two = [16#12#, 16#34#], "endian: poke_u16be exact fit");
      Poke_U16LE (Two, 0, 16#1234#);
      Check (Two = [16#34#, 16#12#], "endian: poke_u16le exact fit");
      Poke_U64BE (Big, 3, 16#0102_0304_0506_0708#);
      Check (Big = [1, 2, 3, 4, 5, 6, 7, 8], "endian: poke_u64be exact fit");
      Poke_U64LE (Big, 3, 16#0102_0304_0506_0708#);
      Check (Big = [8, 7, 6, 5, 4, 3, 2, 1], "endian: poke_u64le exact fit");
   end;

   --  Pokes write their own bytes only, and narrow forms ignore high bits.
   declare
      B : Bytes (20 .. 29) := [others => 16#EE#];
   begin
      Poke_U32LE (B, 23, 16#1122_3344#);
      Check (B = [16#EE#, 16#EE#, 16#EE#, 16#44#, 16#33#, 16#22#, 16#11#,
                  16#EE#, 16#EE#, 16#EE#], "endian: poke_u32le frame");
      Poke_U32BE (B, 23, 16#1122_3344#);
      Check (B = [16#EE#, 16#EE#, 16#EE#, 16#11#, 16#22#, 16#33#, 16#44#,
                  16#EE#, 16#EE#, 16#EE#], "endian: poke_u32be frame");
      B := [others => 16#EE#];
      Poke_U24LE (B, 20, 16#FFAA_BBCC#);
      Check (B (20 .. 23) = [16#CC#, 16#BB#, 16#AA#, 16#EE#], "endian: poke_u24le masks");
      Check (Peek_U24LE (B, 20) = 16#AA_BBCC#, "endian: poke_u24le round trip");
      Poke_U24BE (B, 27, 16#FFAA_BBCC#);
      Check (B (26 .. 29) = [16#EE#, 16#AA#, 16#BB#, 16#CC#], "endian: poke_u24be masks");
      B := [others => 16#EE#];
      Poke_U40LE (B, 21, U64'Last);
      Check (B = [16#EE#, 16#FF#, 16#FF#, 16#FF#, 16#FF#, 16#FF#, 16#EE#,
                  16#EE#, 16#EE#, 16#EE#], "endian: poke_u40le frame");
      B := [others => 16#EE#];
      Poke_U56BE (B, 22, 16#99_0102_0304_0506_07#);
      Check (B = [16#EE#, 16#EE#, 1, 2, 3, 4, 5, 6, 7, 16#EE#], "endian: poke_u56be masks");
      Check (Peek_U56BE (B, 22) = 16#01_0203_0405_0607#, "endian: poke_u56be round trip");
      B := [others => 16#EE#];
      Poke_U48LE (B, 24, 16#9999_0102_0304_0506#);
      Check (B = [16#EE#, 16#EE#, 16#EE#, 16#EE#, 6, 5, 4, 3, 2, 1], "endian: poke_u48le masks");
   end;
end Test_Endian;
