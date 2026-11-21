with Wuffs.Base.Endian;

package body Wuffs.Base.UTF8 with SPARK_Mode is

   ----------
   -- Next --
   ----------

   --  Follows the C bit for bit: the multi-byte cases peek 2, 3 or 4 bytes
   --  little-endian, check the tail bytes' top two bits with one mask, and
   --  assemble the code point with shifts and masks.
   function Next (S : Bytes) return Next_Output is
      Bad : constant Next_Output := (Code_Point => Replacement_Character, Byte_Length => 1);
      C   : U32;
   begin
      if S'Length = 0 then
         return (Code_Point => 0, Byte_Length => 0);
      end if;
      C := U32 (S (S'First));
      case Byte_Length_Minus_1 (S (S'First)) is
         when 0 =>
            return (Code_Point => C, Byte_Length => 1);
         when 1 =>
            if S'Length < 2 then
               return Bad;
            end if;
            C := U32 (Endian.Peek_U16LE (S, S'First));
            if (C and 16#C000#) /= 16#8000# then
               return Bad;
            end if;
            C := (16#0007C0# and Interfaces.Shift_Left (C, 6))
              or (16#00003F# and Interfaces.Shift_Right (C, 8));
            return (Code_Point => C, Byte_Length => 2);
         when 2 =>
            if S'Length < 3 then
               return Bad;
            end if;
            C := Endian.Peek_U24LE (S, S'First);
            if (C and 16#C0C000#) /= 16#808000# then
               return Bad;
            end if;
            C := (16#00F000# and Interfaces.Shift_Left (C, 12))
              or (16#000FC0# and Interfaces.Shift_Right (C, 2))
              or (16#00003F# and Interfaces.Shift_Right (C, 16));
            if C <= 16#07FF# or else (16#D800# <= C and then C <= 16#DFFF#) then
               return Bad;
            end if;
            return (Code_Point => C, Byte_Length => 3);
         when 3 =>
            if S'Length < 4 then
               return Bad;
            end if;
            C := Endian.Peek_U32LE (S, S'First);
            if (C and 16#C0C0_C000#) /= 16#8080_8000# then
               return Bad;
            end if;
            C := (16#1C0000# and Interfaces.Shift_Left (C, 18))
              or (16#03F000# and Interfaces.Shift_Left (C, 4))
              or (16#000FC0# and Interfaces.Shift_Right (C, 10))
              or (16#00003F# and Interfaces.Shift_Right (C, 24));
            if C <= 16#FFFF# or else 16#11_0000# <= C then
               return Bad;
            end if;
            return (Code_Point => C, Byte_Length => 4);
         when others =>
            return Bad;
      end case;
   end Next;

   -------------------
   -- Next_From_End --
   -------------------

   function Next_From_End (S : Bytes) return Next_Output is
      Bad : constant Next_Output := (Code_Point => Replacement_Character, Byte_Length => 1);
   begin
      if S'Length = 0 then
         return (Code_Point => 0, Byte_Length => 0);
      end if;
      pragma Assert (S'First in Index and then S'Last in Index);
      declare
         Last  : constant Index := S'Last;
         Len   : constant Offset := S'Last - S'First + 1;
         Max_N : constant U32 := (if Len > 4 then 4 else U32 (Len));
         N     : U32;
         P     : Index;
         O     : Next_Output;
      begin
         if S (Last) < 16#80# then
            return (Code_Point => U32 (S (Last)), Byte_Length => 1);
         elsif S (Last) < 16#C0# then
            --  C: too_far = &s_ptr[(s_len > 4) ? (s_len - 4) : 0], and a
            --  loop that walks ptr back from the last byte towards too_far,
            --  one byte at a time, n being the number of bytes from ptr to
            --  the end.  So n goes up to Max_N = min (s_len, 4), and ptr is
            --  S'Last - n + 1.
            N := 1;
            while N < Max_N loop
               pragma Loop_Invariant (N in 1 .. Max_N - 1);
               pragma Loop_Variant (Increases => N);
               N := N + 1;
               P := Last - Offset (N) + 1;
               pragma Assert (P in S'Range);
               if S (P) < 16#80# then
                  exit;
               elsif S (P) < 16#C0# then
                  null;
               else
                  O := Next (S (P .. Last));
                  if O.Byte_Length /= N then
                     exit;
                  end if;
                  pragma Assert (O.Byte_Length >= 2 and then Offset (O.Byte_Length) <= Len);
                  return O;
               end if;
            end loop;
         end if;
      end;
      return Bad;
   end Next_From_End;

   --------------------------
   -- Longest_Valid_Prefix --
   --------------------------

   function Longest_Valid_Prefix (S : Bytes) return U64 is
      P : Index;  --  the first byte not yet consumed
      O : Next_Output;
   begin
      if S'Length = 0 then
         return 0;
      end if;
      P := S'First;
      loop
         pragma Loop_Invariant (P in S'First .. S'Last);
         pragma Loop_Variant (Increases => P);
         O := Next (S (P .. S'Last));
         pragma Assert (O.Byte_Length >= 1 and then Offset (O.Byte_Length) <= S'Last - P + 1);
         if O.Code_Point > 16#7F# and then O.Byte_Length = 1 then
            return U64 (P - S'First);
         end if;
         if Offset (O.Byte_Length) = S'Last - P + 1 then
            return U64 (S'Length);
         end if;
         P := P + Index (O.Byte_Length);
      end loop;
   end Longest_Valid_Prefix;

   --------------------------------
   -- ASCII_Longest_Valid_Prefix --
   --------------------------------

   function ASCII_Longest_Valid_Prefix (S : Bytes) return U64 is
   begin
      for J in S'Range loop
         pragma Loop_Invariant (for all K in S'First .. J - 1 => S (K) < 16#80#);
         if S (J) >= 16#80# then
            pragma Assert (Offset (U64 (J - S'First)) = J - S'First);
            return U64 (J - S'First);
         end if;
      end loop;
      return U64 (S'Length);
   end ASCII_Longest_Valid_Prefix;

   ------------
   -- Encode --
   ------------

   procedure Encode (Dst : in out Bytes; Code_Point : U32; N : out Element_Count) is
      F : constant Offset := Dst'First;
   begin
      N := 0;
      if Code_Point <= 16#7F# then
         if Dst'Length >= 1 then
            Dst (F) := U8 (Code_Point);
            N := 1;
         end if;
      elsif Code_Point <= 16#07FF# then
         if Dst'Length >= 2 then
            Dst (F) := U8 (16#C0# or Interfaces.Shift_Right (Code_Point, 6));
            Dst (F + 1) := U8 (16#80# or (Interfaces.Shift_Right (Code_Point, 0) and 16#3F#));
            N := 2;
         end if;
      elsif Code_Point <= 16#FFFF# then
         if Dst'Length >= 3 and then (Code_Point < 16#D800# or else 16#DFFF# < Code_Point) then
            Dst (F) := U8 (16#E0# or Interfaces.Shift_Right (Code_Point, 12));
            Dst (F + 1) := U8 (16#80# or (Interfaces.Shift_Right (Code_Point, 6) and 16#3F#));
            Dst (F + 2) := U8 (16#80# or (Interfaces.Shift_Right (Code_Point, 0) and 16#3F#));
            N := 3;
         end if;
      elsif Code_Point <= Code_Point_Max_Incl then
         if Dst'Length >= 4 then
            Dst (F) := U8 (16#F0# or Interfaces.Shift_Right (Code_Point, 18));
            Dst (F + 1) := U8 (16#80# or (Interfaces.Shift_Right (Code_Point, 12) and 16#3F#));
            Dst (F + 2) := U8 (16#80# or (Interfaces.Shift_Right (Code_Point, 6) and 16#3F#));
            Dst (F + 3) := U8 (16#80# or (Interfaces.Shift_Right (Code_Point, 0) and 16#3F#));
            N := 4;
         end if;
      end if;
   end Encode;

   ------------------------
   -- Valid_UTF_8_Length --
   ------------------------

   function Valid_UTF_8_Length (Data : Bytes; R : IO.Reader; Up_To : U64) return U64 is
      Avail : constant Element_Count := R.Io2 - R.Iop;
      Count : Element_Count;
      N     : U64;
   begin
      if U64 (Avail) <= Up_To then
         Count := Avail;
      else
         Count := Index (Up_To);
      end if;
      if Count = 0 then
         return 0;
      end if;
      pragma Assert (Data'First in Index);
      declare
         First : constant Index := Data'First + R.Iop;
         Last  : constant Index := First + (Count - 1);
      begin
         pragma Assert (Last <= Data'Last);
         N := Longest_Valid_Prefix (Data (First .. Last));
      end;
      pragma Assert (N <= U64 (Count));
      return N;
   end Valid_UTF_8_Length;

end Wuffs.Base.UTF8;
