--  Explicit cases with expected values worked out by hand (from the bit
--  layout in token-public.h and doc/note/tokens.md, and from RFC 3629), not
--  from the oracle: the edges, and the examples upstream's documentation
--  gives.

with Interfaces;
with Token_Test_Support; use Token_Test_Support;
with Wuffs.Base.IO;
with Wuffs.Base.Tokens;
with Wuffs.Base.UTF8;

procedure Test_Token_Cases is

   use Wuffs;
   use type Interfaces.Unsigned_32;
   use type Interfaces.Unsigned_64;
   use type Interfaces.Integer_64;

   package Tok renames Wuffs.Base.Tokens;
   package UTF8 renames Wuffs.Base.UTF8;
   use type UTF8.Next_Output;
   use type Tok.Token_Buffer_Meta;

   --  Load (S) puts the bytes of S in Buf (1001 .. 1000 + S'Length).  (The
   --  non-ASCII literals below are UTF-8 in the source, and so each of
   --  their bytes is one Character.)
   Buf : Bytes (1001 .. 1016) := [others => 0];
   Len : Index := 0;

   procedure Load (S : String) with Pre => S'Length <= 16;

   procedure Load (S : String) is
   begin
      Len := S'Length;
      for I in S'Range loop
         Buf (1001 + Index (I - S'First)) := Character'Pos (S (I));
      end loop;
   end Load;

   T : U64;
   O : UTF8.Next_Output;
begin
   --  doc/note/tokens.md: "pos=0 len=0x0001 con=0 vbc=1:Structure
   --  vbd=0x004011" is VBC 1 (bits 41 .. 38), VBD 0x4011 (bits 37 .. 17),
   --  length 1: 16#40_0000_0000# + 16#4011# * 2**17 + 1.
   T := Tok.Make_Simple_Token (0, 16#20_4011#, 0, 1);
   Check (T = 16#0000_0040_8022_0001#, "case: the structure token of tokens.md");
   Check (Tok.Value_Base_Category (T) = 1 and then Tok.Value_Base_Detail (T) = 16#4011#
          and then Tok.Length (T) = 1 and then not Tok.Continued (T)
          and then Tok.Value_Major (T) = 0 and then Tok.Value_Minor (T) = 16#20_4011#,
          "case: the fields of the structure token");
   --  value_major in bits 62 .. 42; continued is bit 16.
   T := Tok.Make_Simple_Token (16#1F_FFFF#, 16#1FF_FFFF#, 1, 16#FFFF#);
   Check (T = 16#7FFF_FFFF_FFFF_FFFF#, "case: the largest simple token");
   Check (Tok.Value_Major (T) = 16#1F_FFFF# and then Tok.Continued (T)
          and then Tok.Value (T) = 2 ** 46 - 1, "case: its fields");
   --  An extended token: bit 63 set, bits 62 .. 17 the complement of the
   --  extension, so value_extension gives it back and value_major is -1.
   T := Tok.Make_Extended_Token (16#2A#, 1, 7);
   Check (T = (16#FFFF_FFFF_FFFF_FFFF# - 16#2A# * 2 ** 17 - 16#1_FFFF#) + 16#1_0007#,
          "case: an extended token");
   Check (Tok.Value_Extension (T) = 16#2A# and then Tok.Value_Major (T) = -1
          and then Tok.Length (T) = 7 and then Tok.Continued (T), "case: its fields");
   T := Tok.Make_Extended_Token (0, 0, 0);
   Check (T = 16#FFFF_FFFF_FFFE_0000#, "case: the extended token 0");
   T := Tok.Make_Extended_Token (16#3FFF_FFFF_FFFF#, 0, 0);
   Check (T = 16#8000_0000_0000_0000# and then Tok.Value_Extension (T) = 16#3FFF_FFFF_FFFF#,
          "case: the largest extended token");
   --  value_base_detail__sign_extended: bit 37 is the sign of the VBD.
   Check (Tok.Value_Base_Detail_Sign_Extended (Tok.Make_Simple_Token (0, 16#1F_FFFF#, 0, 0)) = -1
          and then Tok.Value_Base_Detail_Sign_Extended (Tok.Make_Simple_Token (0, 16#F_FFFF#, 0, 0))
                   = 16#F_FFFF#,
          "case: value_base_detail__sign_extended");
   Check (Tok.To_Signed (16#8000_0000_0000_0000#) = Interfaces.Integer_64'First
          and then Tok.To_Signed (16#FFFF_FFFF_FFFF_FFFF#) = -1
          and then Tok.To_Signed (16#7FFF_FFFF_FFFF_FFFF#) = Interfaces.Integer_64'Last,
          "case: To_Signed");

   --  Cursors: a closed buffer takes no tokens; Save and Reload; a write
   --  goes to Data'First + Iop.
   declare
      Data : U64_Array (500 .. 503) := [others => 0];
      M    : Tok.Token_Buffer_Meta := (Wi => 1, Ri => 0, Pos => 9, Closed => True);
      W    : Tok.Token_Writer;
   begin
      W := Tok.To_Writer (M, Data'Length);
      Check (Tok.Length (W) = 0 and then W.Iop = 1, "case: a closed token buffer");
      M.Closed := False;
      W := Tok.To_Writer (M, Data'Length);
      Check (Tok.Length (W) = 3, "case: an open token buffer");
      Tok.Write_Simple_Token_Fast (Data, W, 0, 5, 0, 2);
      Check (Data = [0, Tok.Make_Simple_Token (0, 5, 0, 2), 0, 0] and then W.Iop = 2,
             "case: a write at Data'First + Iop");
      Tok.Save (M, W);
      Check (M = (Wi => 2, Ri => 0, Pos => 9, Closed => False), "case: Save");
      M.Wi := 4;
      Tok.Reload (W, M);
      Check (W.Iop = 4 and then Tok.Length (W) = 0, "case: Reload");
   end;

   Load ("€");

   --  The caller-side helpers take any meta: one whose write index is
   --  beyond the array is left alone (C's behaviour is undefined there).
   declare
      Data : U64_Array (7 .. 8) := [11, 22];
      M    : Tok.Token_Buffer_Meta := (Wi => 5, Ri => 1, Pos => 3, Closed => False);
      N    : Index;
   begin
      Check (Tok.Writer_Length (Data, M) = 0, "case: writer_length of a meta beyond its array");
      Tok.Compact (Data, M, N);
      Check (N = 0 and then M = (Wi => 5, Ri => 1, Pos => 3, Closed => False)
             and then Data = [11, 22], "case: compact of a meta beyond its array");
      Tok.Compact_Retaining (Data, M, 0, N);
      Check (N = 0 and then M.Wi = 5 and then Data = [11, 22],
             "case: compact_retaining of a meta beyond its array");
      M := (Wi => 2, Ri => 1, Pos => U64'Last - 1, Closed => True);
      Tok.Compact (Data, M, N);
      Check (N = 1 and then M = (Wi => 1, Ri => 0, Pos => U64'Last, Closed => True)
             and then Data = [22, 22], "case: compact (the position saturates)");
   end;

   --  UTF-8 (RFC 3629).
   O := UTF8.Next (Buf (1001 .. 1000 + Len));
   Check (O = (16#20AC#, 3), "case: next of the euro sign");
   Load ("" & Character'Val (16#C0#) & Character'Val (16#80#));
   O := UTF8.Next (Buf (1001 .. 1000 + Len));
   Check (O = (16#FFFD#, 1), "case: next of an overlong NUL");
   Load ("" & Character'Val (16#ED#) & Character'Val (16#A0#)
                             & Character'Val (16#80#));
   O := UTF8.Next (Buf (1001 .. 1000 + Len));
   Check (O = (16#FFFD#, 1), "case: next of a surrogate");
   Load ("" & Character'Val (16#F4#) & Character'Val (16#8F#)
                             & Character'Val (16#BF#) & Character'Val (16#BF#));
   O := UTF8.Next (Buf (1001 .. 1000 + Len));
   Check (O = (16#10_FFFF#, 4), "case: next of U+10FFFF");
   Load ("" & Character'Val (16#F4#) & Character'Val (16#90#)
                             & Character'Val (16#80#) & Character'Val (16#80#));
   O := UTF8.Next (Buf (1001 .. 1000 + Len));
   Check (O = (16#FFFD#, 1), "case: next of U+110000");
   Load ("");
   O := UTF8.Next (Buf (1001 .. 1000 + Len));
   Check (O = (0, 0), "case: next of nothing");
   Load ("aé");
   O := UTF8.Next_From_End (Buf (1001 .. 1000 + Len));
   Check (O = (16#E9#, 2), "case: next_from_end of a 2-byte sequence");
   Load ("x€");
   O := UTF8.Next_From_End (Buf (1001 .. 1000 + Len));
   Check (O = (16#20AC#, 3), "case: next_from_end of a 3-byte sequence");
   Load ("" & Character'Val (16#80#) & Character'Val (16#80#)
                                      & Character'Val (16#80#) & Character'Val (16#80#)
                                      & Character'Val (16#80#));
   O := UTF8.Next_From_End (Buf (1001 .. 1000 + Len));
   Check (O = (16#FFFD#, 1), "case: next_from_end of tail bytes only");
   Load ("abé" & Character'Val (16#FF#) & "c");
   Check (UTF8.Longest_Valid_Prefix (Buf (1001 .. 1000 + Len)) = 4,
          "case: longest_valid_prefix");
   Load ("ab" & Character'Val (16#E2#) & Character'Val (16#82#));
   Check (UTF8.Longest_Valid_Prefix (Buf (1001 .. 1000 + Len))
          = 2, "case: longest_valid_prefix of a truncated sequence");
   Load ("ab" & Character'Val (16#80#) & "c");
   Check (UTF8.ASCII_Longest_Valid_Prefix (Buf (1001 .. 1000 + Len)) = 2,
          "case: ascii longest_valid_prefix");
   declare
      subtype Five is Bytes (31 .. 35);
      Dst  : Five := [others => 16#AA#];
      Fill : constant Five := [others => 16#AA#];
      N    : Index;
   begin
      UTF8.Encode (Dst, 16#1F600#, N);
      Check (N = 4 and then Dst = [16#F0#, 16#9F#, 16#98#, 16#80#, 16#AA#], "case: encode U+1F600");
      Dst := [others => 16#AA#];
      UTF8.Encode (Dst, 16#D800#, N);
      Check (N = 0 and then Dst = Fill, "case: encode a surrogate");
      UTF8.Encode (Dst, 16#11_0000#, N);
      Check (N = 0 and then Dst = Fill, "case: encode U+110000");
      UTF8.Encode (Dst (31 .. 32), 16#800#, N);
      Check (N = 0 and then Dst = Fill, "case: encode into too little room");
      UTF8.Encode (Dst (31 .. 30), 16#41#, N);
      Check (N = 0, "case: encode into nothing");
   end;
   Load ("abé" & Character'Val (16#FF#) & "xyz");
   declare
      Data : Bytes renames Buf (1001 .. 1000 + Len);
      R    : constant Wuffs.Base.IO.Reader :=
        (Io0 => 0, Io1 => 1, Iop => 1, Io2 => 6, Pos => 0, Closed => False);
   begin
      Check (UTF8.Valid_UTF_8_Length (Data, R, 100) = 3
             and then UTF8.Valid_UTF_8_Length (Data, R, 3) = 3
             and then UTF8.Valid_UTF_8_Length (Data, R, 2) = 1
             and then UTF8.Valid_UTF_8_Length (Data, R, 0) = 0,
             "case: valid_utf_8_length");
   end;
end Test_Token_Cases;
