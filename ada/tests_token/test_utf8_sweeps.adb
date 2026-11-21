--  The UTF-8 sweeps: twins of oracle/oracle.c's sweep_utf8_* and
--  sweep_valid_utf_8_length, run through Wuffs.Base.UTF8.  Each must
--  enumerate the same cases, draw random numbers and mix in the same order
--  as its C twin.  The byte arrays start at index 1000, not 0; empty ones
--  are null slices of them.

with Interfaces;
with Token_Oracle_Data;
with Token_Test_Support; use Token_Test_Support;
with Wuffs.Base.IO;
with Wuffs.Base.UTF8;

procedure Test_UTF8_Sweeps is

   use Wuffs;
   use type Interfaces.Unsigned_64;

   package UTF8 renames Wuffs.Base.UTF8;

   Buf : Bytes (1000 .. 1063) := [others => 0];

   Edges : constant Bytes (0 .. 9) := [16#00#, 16#7F#, 16#80#, 16#8F#, 16#90#,
                                        16#9F#, 16#A0#, 16#BF#, 16#C0#, 16#FF#];

   --  mix_next (g_buf + Offset, N).
   procedure Mix_Next (Offset : Index; N : Index);

   procedure Mix_Sequence (N : Index);

   procedure Mix_Next (Offset : Index; N : Index) is
      S : Bytes renames Buf (Buf'First + Offset .. Buf'First + Offset + N - 1);
      O : UTF8.Next_Output;
   begin
      O := UTF8.Next (S);
      Mix (U64 (O.Code_Point));
      Mix (U64 (O.Byte_Length));
      O := UTF8.Next_From_End (S);
      Mix (U64 (O.Code_Point));
      Mix (U64 (O.Byte_Length));
      Mix (UTF8.Longest_Valid_Prefix (S));
      Mix (UTF8.ASCII_Longest_Valid_Prefix (S));
   end Mix_Next;

   procedure Mix_Sequence (N : Index) is
   begin
      Mix_Next (0, N);
      Mix_Next (0, N - 1);
      Buf (Buf'First + N) := Character'Pos ('x');
      Mix_Next (0, N + 1);
      Buf (Buf'First + N) := 16#80#;
      Mix_Next (0, N + 1);
   end Mix_Sequence;

begin
   --  sweep_utf8_short
   Start (201);
   Mix_Next (0, 0);
   for A in U8 loop
      Buf (1000) := A;
      Mix_Sequence (1);
      for B in U8 loop
         Buf (1000) := A;
         Buf (1001) := B;
         Mix_Sequence (2);
      end loop;
   end loop;
   Finish ("UTF8_Short", Token_Oracle_Data.UTF8_Short);

   --  sweep_utf8_three
   Start (202);
   for A in U8 loop
      for B in U8 loop
         for C in U8 loop
            Buf (1000) := A;
            Buf (1001) := B;
            Buf (1002) := C;
            Mix_Sequence (3);
         end loop;
      end loop;
   end loop;
   Finish ("UTF8_Three", Token_Oracle_Data.UTF8_Three);

   --  sweep_utf8_four
   Start (203);
   for A in U8 loop
      for B in U8 loop
         for C in Edges'Range loop
            for D in Edges'Range loop
               Buf (1000) := A;
               Buf (1001) := B;
               Buf (1002) := Edges (C);
               Buf (1003) := Edges (D);
               Mix_Sequence (4);
            end loop;
         end loop;
      end loop;
   end loop;
   Finish ("UTF8_Four", Token_Oracle_Data.UTF8_Four);

   --  sweep_utf8_strings
   Start (204);
   for I in 1 .. 200_000 loop
      declare
         N : constant Index := Index (Rnd mod 65);
         K : Index := 0;
         R : U64;
      begin
         while K < N loop
            R := Rnd;
            case R mod 4 is
               when 0 =>
                  Buf (Buf'First + K) := U8 (Interfaces.Shift_Right (R, 8) and 16#7F#);
                  K := K + 1;
               when 1 =>
                  Buf (Buf'First + K) := U8 (Interfaces.Shift_Right (R, 8) and 16#FF#);
                  K := K + 1;
               when others =>
                  declare
                     Enc : Bytes (7 .. 10) := [others => 0];
                     M   : Index;
                  begin
                     UTF8.Encode (Enc, U32 (Interfaces.Shift_Right (R, 8) mod 16#11_0000#), M);
                     for J in 0 .. M - 1 loop
                        exit when K >= N;
                        Buf (Buf'First + K) := Enc (Enc'First + J);
                        K := K + 1;
                     end loop;
                  end;
            end case;
         end loop;
         Mix_Next (0, N);
         if N > 0 then
            Mix_Next (1, N - 1);
         end if;
      end;
   end loop;
   Finish ("UTF8_Strings", Token_Oracle_Data.UTF8_Strings);

   --  sweep_utf8_encode
   Start (205);
   for CP in U32 range 0 .. 16#11_00FF# loop
      for N in Index range 0 .. 5 loop
         declare
            Dst : Bytes (21 .. 25) := [others => 16#AA#];
            M   : Index;
         begin
            UTF8.Encode (Dst (21 .. 20 + N), CP, M);
            Mix (U64 (M));
            for J in Dst'Range loop
               Mix (U64 (Dst (J)));
            end loop;
         end;
      end loop;
   end loop;
   for I in 1 .. 100_000 loop
      declare
         CP  : constant U32 := U32 (Rnd and 16#FFFF_FFFF#);
         Dst : Bytes (21 .. 25) := [others => 16#AA#];
         M   : Index;
      begin
         UTF8.Encode (Dst (21 .. 24), CP, M);
         Mix (U64 (M));
         for J in Dst'Range loop
            Mix (U64 (Dst (J)));
         end loop;
      end;
   end loop;
   Finish ("UTF8_Encode", Token_Oracle_Data.UTF8_Encode);

   --  sweep_valid_utf_8_length
   Start (206);
   for I in 0 .. 99_999 loop
      declare
         R      : U64;
         Io2    : Index;
         Iop    : Index;
         Up_To  : U64;
         Reader : Wuffs.Base.IO.Reader;
      begin
         for K in Buf'Range loop
            R := Rnd;
            Buf (K) := (if (R and 1) /= 0 then U8 (Interfaces.Shift_Right (R, 8) and 16#7F#)
                        else U8 (Interfaces.Shift_Right (R, 8) and 16#FF#));
         end loop;
         Io2 := Index (Rnd mod 65);
         Iop := Index (Rnd mod U64 (Io2 + 1));
         case I mod 4 is
            when 0 => Up_To := 0;
            when 1 => Up_To := U64'Last;
            when others => Up_To := Rnd mod 70;
         end case;
         Reader := (Io0 => 0, Io1 => Iop, Iop => Iop, Io2 => Io2, Pos => 0, Closed => False);
         Mix (UTF8.Valid_UTF_8_Length (Buf, Reader, Up_To));
      end;
   end loop;
   Finish ("Valid_UTF_8_Length", Token_Oracle_Data.Valid_UTF_8_Length);
end Test_UTF8_Sweeps;
