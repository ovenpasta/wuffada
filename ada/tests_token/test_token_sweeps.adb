--  The token sweeps: twins of oracle/oracle.c's sweep_token_*, run through
--  Wuffs.Base.Tokens.  Each must enumerate the same cases, draw random
--  numbers and mix in the same order as its C twin.  The arrays here start
--  at index 1000, not 0, and empty ones are null slices of them.

with Interfaces;
with Token_Oracle_Data;
with Token_Test_Support; use Token_Test_Support;
with Wuffs.Base.Tokens;

procedure Test_Token_Sweeps is

   use Wuffs;
   use type Interfaces.Unsigned_64;

   package Tok renames Wuffs.Base.Tokens;

   Toks : U64_Array (1000 .. 1063);

   procedure Mix_Fields (Repr : U64);

   function Pick (Max : U64; I : Natural) return U64;

   procedure Mix_Fields (Repr : U64) is
   begin
      Mix_Signed (Tok.Value (Repr));
      Mix_Signed (Tok.Value_Extension (Repr));
      Mix_Signed (Tok.Value_Major (Repr));
      Mix_Signed (Tok.Value_Base_Category (Repr));
      Mix (Tok.Value_Minor (Repr));
      Mix (Tok.Value_Base_Detail (Repr));
      Mix_Signed (Tok.Value_Base_Detail_Sign_Extended (Repr));
      Mix (Tok.Continued (Repr));
      Mix (Tok.Length (Repr));
   end Mix_Fields;

   function Pick (Max : U64; I : Natural) return U64 is
   begin
      case I mod 8 is
         when 0 => return 0;
         when 1 => return 1;
         when 2 => return Max;
         when 3 => return Max - 1;
         when 4 => return Max / 2;
         when 5 => return Max / 2 + 1;
         when others => return Rnd mod (Max + 1);
      end case;
   end Pick;

begin
   --  sweep_token_fields
   Start (101);
   for K in 0 .. 63 loop
      Mix_Fields (Interfaces.Shift_Left (1, K));
      Mix_Fields (not Interfaces.Shift_Left (1, K));
      Mix_Fields (Interfaces.Shift_Left (1, K) - 1);
      Mix_Fields (not (Interfaces.Shift_Left (1, K) - 1));
   end loop;
   for I in 1 .. 200_000 loop
      Mix_Fields (Rnd);
   end loop;
   Finish ("Token_Fields", Token_Oracle_Data.Token_Fields);

   --  sweep_token_make: Make_Simple_Token / Make_Extended_Token, and the
   --  same tokens written through a cursor.
   Start (102);
   for A in 0 .. 15 loop
      for B in 0 .. 15 loop
         for C in U32 range 0 .. 1 loop
            for D in 0 .. 15 loop
               declare
                  Major : constant U32 := U32 (Pick (16#1F_FFFF#, A));
                  Minor : constant U32 := U32 (Pick (16#1FF_FFFF#, B));
                  Len   : constant U32 := U32 (Pick (16#FFFF#, D));
                  Ext   : constant U64 := Pick (16#3FFF_FFFF_FFFF#, A * 16 + B);
                  W     : Tok.Token_Writer := (Iop => 3, Io2 => 5);
                  S, E  : U64;
               begin
                  Toks := [others => 0];
                  Tok.Write_Simple_Token_Fast
                    (Data => Toks (1000 .. 1004), W => W, Value_Major => Major,
                     Value_Minor => Minor, Continued => C, Length => Len);
                  Tok.Write_Extended_Token_Fast
                    (Data => Toks (1000 .. 1004), W => W, Value_Extension => Ext, Continued => C,
                     Length => Len);
                  S := Toks (1003);
                  E := Toks (1004);
                  Check (W.Iop = 5 and then S = Tok.Make_Simple_Token (Major, Minor, C, Len)
                         and then E = Tok.Make_Extended_Token (Ext, C, Len)
                         and then Toks (1000) = 0 and then Toks (1005) = 0,
                         "Token_Make: the writes");
                  Mix (S);
                  Mix_Fields (S);
                  Mix (E);
                  Mix_Fields (E);
               end;
            end loop;
         end loop;
      end loop;
   end loop;
   for I in 1 .. 100_000 loop
      declare
         Major : constant U32 := U32 (Rnd and 16#1F_FFFF#);
         Minor : constant U32 := U32 (Rnd and 16#1FF_FFFF#);
         Cont  : constant U32 := U32 (Rnd and 1);
         Len   : constant U32 := U32 (Rnd and 16#FFFF#);
         Ext   : constant U64 := Rnd and 16#3FFF_FFFF_FFFF#;
      begin
         Mix (Tok.Make_Simple_Token (Major, Minor, Cont, Len));
         Mix (Tok.Make_Extended_Token (Ext, Cont, Len));
      end;
   end loop;
   Finish ("Token_Make", Token_Oracle_Data.Token_Make);

   --  sweep_token_buffer
   Start (103);
   for I in 0 .. 19_999 loop
      declare
         Len : constant Index := Index (Rnd mod 41);
         Wi  : constant Index := (if Len > 0 then Index (Rnd mod U64 (Len + 1)) else 0);
         Ri  : constant Index := Index (Rnd mod U64 (Wi + 1));
         Pos : U64 := (if (Rnd and 1) /= 0 then Rnd else U64'Last - (Rnd mod 50));
         H   : U64;
         N   : Index;
         M   : Tok.Token_Buffer_Meta;
      begin
         if I mod 4 = 0 then
            Pos := Rnd mod 1000;
         end if;
         for K in 0 .. Len - 1 loop
            Toks (1000 + K) := Rnd;
         end loop;
         M := (Wi => Wi, Ri => Ri, Pos => Pos, Closed => (I / 2) mod 2 = 1);
         Mix (Tok.Is_Valid (Toks (1000 .. 1000 + Len - 1), M));
         Mix (Tok.Reader_Length (M));
         Mix (Tok.Writer_Length (Toks (1000 .. 1000 + Len - 1), M));
         Mix (Tok.Reader_Token_Position (M));
         Mix (Tok.Writer_Token_Position (M));
         case I mod 6 is
            when 0 => H := 0;
            when 1 => H := 1;
            when 2 => H := 2;
            when 3 => H := U64'Last;
            when others => H := Rnd mod 45;
         end case;
         if I mod 7 = 0 then
            Tok.Compact (Toks (1000 .. 1000 + Len - 1), M, N);
         else
            Tok.Compact_Retaining (Toks (1000 .. 1000 + Len - 1), M, H, N);
         end if;
         Mix (U64 (N));
         Mix (U64 (M.Wi));
         Mix (U64 (M.Ri));
         Mix (M.Pos);
         Mix (M.Closed);
         for K in 0 .. Len - 1 loop
            Mix (Toks (1000 + K));
         end loop;
      end;
   end loop;
   Finish ("Token_Buffer", Token_Oracle_Data.Token_Buffer);

   --  sweep_token_cursor
   Start (104);
   for I in 0 .. 19_999 loop
      declare
         Len   : constant Index := Index (Rnd mod 33);
         Wi    : constant Index := (if Len > 0 then Index (Rnd mod U64 (Len + 1)) else 0);
         Ri    : constant Index := Index (Rnd mod U64 (Wi + 1));
         M     : Tok.Token_Buffer_Meta :=
           (Wi => Wi, Ri => Ri, Pos => Rnd mod 100, Closed => I mod 9 = 0);
         Data  : U64_Array renames Toks (1000 .. 1000 + Len - 1);
         W     : Tok.Token_Writer;
         Steps : constant Natural := Natural (Rnd mod 12);
         R     : U64;
      begin
         Data := [others => 0];
         W := Tok.To_Writer (M, Data'Length);
         for S in 1 .. Steps loop
            R := Rnd;
            Mix (Tok.Length (W));
            case R mod 5 is
               when 0 | 1 =>
                  if Tok.Length (W) >= 1 then
                     Tok.Write_Simple_Token_Fast
                       (Data        => Data,
                        W           => W,
                        Value_Major => U32 (Interfaces.Shift_Right (R, 8) and 16#1F_FFFF#),
                        Value_Minor => U32 (Interfaces.Shift_Right (R, 29) and 16#1FF_FFFF#),
                        Continued   => U32 (Interfaces.Shift_Right (R, 54) and 1),
                        Length      => U32 (Interfaces.Shift_Right (R, 3) and 16#FFFF#));
                  end if;
               when 2 =>
                  if Tok.Length (W) >= 1 then
                     Tok.Write_Extended_Token_Fast
                       (Data            => Data,
                        W               => W,
                        Value_Extension => Interfaces.Shift_Right (R, 8) and 16#3FFF_FFFF_FFFF#,
                        Continued       => U32 (Interfaces.Shift_Right (R, 54) and 1),
                        Length          => U32 (Interfaces.Shift_Right (R, 3) and 16#FFFF#));
                  end if;
               when 3 =>
                  --  A callee: Save, the callee's own cursor from the meta,
                  --  its writes and its Save, then Reload.
                  Tok.Save (M, W);
                  declare
                     CW : Tok.Token_Writer := Tok.To_Writer (M, Data'Length);
                     K  : Natural := Natural (Interfaces.Shift_Right (R, 8) mod 4);
                  begin
                     while K > 0 and then Tok.Length (CW) >= 1 loop
                        K := K - 1;
                        Tok.Write_Simple_Token_Fast
                          (Data        => Data,
                           W           => CW,
                           Value_Major => 0,
                           Value_Minor => U32 (Interfaces.Shift_Right (R, 16) and 16#FFFF#),
                           Continued   => 0,
                           Length      => 1);
                     end loop;
                     Tok.Save (M, CW);
                  end;
                  Tok.Reload (W, M);
               when others =>
                  --  A suspension: Save, then a new cursor from the meta.
                  Tok.Save (M, W);
                  W := Tok.To_Writer (M, Data'Length);
            end case;
         end loop;
         Tok.Save (M, W);
         Mix (U64 (M.Wi));
         Mix (U64 (M.Ri));
         Mix (M.Pos);
         for K in Data'Range loop
            Mix (Data (K));
         end loop;
      end;
   end loop;
   Finish ("Token_Cursor", Token_Oracle_Data.Token_Cursor);
end Test_Token_Sweeps;
