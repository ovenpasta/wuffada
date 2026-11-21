--  Unicode and UTF-8: the functions of Wuffs' C base library's utf8
--  submodule, over Wuffs.Bytes parameters, plus the io_reader method
--  valid_utf_8_length that is built on them.
--
--  C: wuffs/internal/cgen/base/utf8-submodule.c (wuffs_base__utf_8__next,
--  __next_from_end, __longest_valid_prefix, __encode,
--  wuffs_base__ascii__longest_valid_prefix), strconv-public.h
--  (wuffs_base__utf_8__next__output), and the inline C that
--  wuffs/internal/cgen/builtin.go emits for io_reader.valid_utf_8_length
--  (writeBuiltinIOReader).
--
--  Every function here is total, as its C counterpart is: any array, of
--  any bounds and length (zero included), and any code point.
--
--  "Valid UTF-8" is RFC 3629's grammar, as the C comment has it:
--
--    UTF8-1      = %x00-7F
--    UTF8-2      = %xC2-DF UTF8-tail
--    UTF8-3      = %xE0 %xA0-BF UTF8-tail / %xE1-EC 2( UTF8-tail ) /
--                  %xED %x80-9F UTF8-tail / %xEE-EF 2( UTF8-tail )
--    UTF8-4      = %xF0 %x90-BF 2( UTF8-tail ) / %xF1-F3 3( UTF8-tail ) /
--                  %xF4 %x80-8F 2( UTF8-tail )
--    UTF8-tail   = %x80-BF

with Interfaces;
with Wuffs.Base.IO;

package Wuffs.Base.UTF8 with Pure, SPARK_Mode is

   pragma Assertion_Policy (Post => Ignore);

   use type Interfaces.Unsigned_8;
   use type Interfaces.Unsigned_32;
   use type Interfaces.Unsigned_64;

   --  C: WUFFS_BASE__UNICODE_REPLACEMENT_CHARACTER.
   Replacement_Character : constant := 16#FFFD#;

   --  C: WUFFS_BASE__UNICODE_CODE_POINT__MAX_INCL.
   Code_Point_Max_Incl : constant := 16#10_FFFF#;

   --  C: wuffs_base__utf_8__next__output.
   type Next_Output is record
      Code_Point  : U32 := 0;
      Byte_Length : U32 := 0;
   end record;

   --  C: wuffs_base__utf_8__next__output__is_valid.
   function Is_Valid (O : Next_Output) return Boolean is
     ((O.Code_Point < 16#D800# or else
         (16#DFFF# < O.Code_Point and then O.Code_Point <= Code_Point_Max_Incl))
      and then
        (case O.Code_Point is
            when 0 .. 16#7F#               => O.Byte_Length = 1,
            when 16#80# .. 16#7FF#         => O.Byte_Length = 2,
            when 16#800# .. 16#FFFF#       => O.Byte_Length = 3,
            when others                    => O.Byte_Length = 4));

   --  C: wuffs_base__utf_8__byte_length_minus_1, the table, as ranges:
   --  0 .. 3 is the byte length minus 1 of a sequence that starts with B,
   --  16#40# a tail byte (16#80# .. 16#BF#), 16#80# a byte that is not in
   --  valid UTF-8 at all.
   function Byte_Length_Minus_1 (B : U8) return U8 is
     (case B is
         when 16#00# .. 16#7F# => 0,
         when 16#80# .. 16#BF# => 16#40#,
         when 16#C0# .. 16#C1# => 16#80#,
         when 16#C2# .. 16#DF# => 1,
         when 16#E0# .. 16#EF# => 2,
         when 16#F0# .. 16#F4# => 3,
         when 16#F5# .. 16#FF# => 16#80#);

   --  C: wuffs_base__utf_8__next.  The code point that S starts with and
   --  the number of bytes that encode it.  (0, 0) if S is empty.  If S does
   --  not start with valid UTF-8: (Replacement_Character, 1).
   function Next (S : Bytes) return Next_Output with
     Post => Next'Result.Byte_Length <= 4
       and then Offset (Next'Result.Byte_Length) <= S'Length
       and then (Next'Result.Byte_Length = 0) = (S'Length = 0)
       and then Next'Result.Code_Point <= Code_Point_Max_Incl
       and then (if S'Length = 0 then Next'Result.Code_Point = 0)
       and then (if Next'Result.Byte_Length = 1
                 then (if S (S'First) < 16#80#
                       then Next'Result.Code_Point = U32 (S (S'First))
                       else Next'Result.Code_Point = Replacement_Character))
       and then (if Next'Result.Byte_Length >= 2 then Is_Valid (Next'Result));

   --  C: wuffs_base__utf_8__next_from_end.  Like Next, but for the code
   --  point that S ends with.  (0, 0) if S is empty, (Replacement_Character,
   --  1) if S does not end with valid UTF-8.
   function Next_From_End (S : Bytes) return Next_Output with
     Post => Next_From_End'Result.Byte_Length <= 4
       and then Offset (Next_From_End'Result.Byte_Length) <= S'Length
       and then (Next_From_End'Result.Byte_Length = 0) = (S'Length = 0)
       and then Next_From_End'Result.Code_Point <= Code_Point_Max_Incl;

   --  C: wuffs_base__utf_8__longest_valid_prefix.  The length of the
   --  longest prefix of S that is valid UTF-8.
   --  (Like C's size_t, the result is a U64: a length of 2**62 does not fit
   --  in Element_Count.)
   function Longest_Valid_Prefix (S : Bytes) return U64 with
     Post => Longest_Valid_Prefix'Result <= U64 (S'Length);

   --  C: wuffs_base__ascii__longest_valid_prefix.  The length of the
   --  longest prefix of S that is ASCII (every byte below 16#80#).
   function ASCII_Longest_Valid_Prefix (S : Bytes) return U64 with
     Post => ASCII_Longest_Valid_Prefix'Result <= U64 (S'Length)
       and then (for all J in S'Range =>
                   (if J - S'First < Offset (ASCII_Longest_Valid_Prefix'Result)
                    then S (J) < 16#80#
                    elsif J - S'First = Offset (ASCII_Longest_Valid_Prefix'Result)
                    then S (J) >= 16#80#));

   --  C: wuffs_base__utf_8__encode.  Writes the UTF-8 encoding of
   --  Code_Point to the start of Dst; N is the number of bytes written.  N
   --  is 0, and nothing is written, if Code_Point is a surrogate or above
   --  Code_Point_Max_Incl or if Dst is too short for its encoding.
   procedure Encode (Dst : in out Bytes; Code_Point : U32; N : out Element_Count) with
     Post => N <= 4
       and then N <= Dst'Length
       and then (for all J in Dst'Range => (if J - Dst'First >= N then Dst (J) = Dst'Old (J)))
       and then (if N > 0 then Is_Valid ((Code_Point => Code_Point, Byte_Length => U32 (N))));

   --  Wuffs io_reader.valid_utf_8_length(up_to: n), C (builtin.go):
   --    longest_valid_prefix (iop, min (io2 - iop, up_to)).
   --  The length of the longest valid UTF-8 prefix of the next
   --  min (Length (R), Up_To) bytes of the reader.  The cursor stays put.
   function Valid_UTF_8_Length (Data : Bytes; R : IO.Reader; Up_To : U64) return U64 with
     Pre  => IO.Valid (Data, R),
     Post => Valid_UTF_8_Length'Result <= Up_To
       and then Valid_UTF_8_Length'Result <= IO.Length (R);

end Wuffs.Base.UTF8;
