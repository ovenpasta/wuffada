package body Wuffs.Base.Tokens with SPARK_Mode is

   -----------------------
   -- Compact_Retaining --
   -----------------------

   procedure Compact_Retaining
     (Data                  : in out U64_Array;
      M                     : in out Token_Buffer_Meta;
      History_Retain_Length : U64;
      N                     : out Index)
   is
      Old_Ri : constant Index := M.Ri;
      New_Ri : constant Index :=
        (if U64 (Old_Ri) <= History_Retain_Length
         then Old_Ri else Index (History_Retain_Length));
      Start  : constant Index := Old_Ri - New_Ri;
      New_Wi : constant Index := M.Wi - Start;
   begin
      if not Is_Valid (Data, M) then
         N := 0;
         return;
      end if;
      if New_Wi /= 0 and then Start /= 0 then
         --  Source and destination overlap when Start < New_Wi; an Ada
         --  slice assignment has memmove semantics.
         Data (Data'First .. Data'First + (New_Wi - 1)) :=
           Data (Data'First + Start .. Data'First + Start + (New_Wi - 1));
      end if;
      M :=
        (Wi     => New_Wi,
         Ri     => New_Ri,
         Pos    => Ints.Sat_Add_U64 (M.Pos, U64 (Start)),
         Closed => M.Closed);
      N := Start;
   end Compact_Retaining;

   -------------
   -- Compact --
   -------------

   procedure Compact (Data : in out U64_Array; M : in out Token_Buffer_Meta; N : out Index) is
   begin
      Compact_Retaining (Data, M, 0, N);
   end Compact;

   ----------
   -- Save --
   ----------

   procedure Save (M : in out Token_Buffer_Meta; W : Token_Writer) is
   begin
      M := (M with delta Wi => W.Iop);
   end Save;

   procedure Save (M : in out Token_Buffer_Meta; R : Token_Reader) is
   begin
      M := (M with delta Ri => R.Iop);
   end Save;

   ------------
   -- Reload --
   ------------

   procedure Reload (W : in out Token_Writer; M : Token_Buffer_Meta) is
   begin
      W := (W with delta Iop => M.Wi);
   end Reload;

   procedure Reload (R : in out Token_Reader; M : Token_Buffer_Meta) is
   begin
      R := (R with delta Iop => M.Ri);
   end Reload;

   -----------------------------
   -- Write_Simple_Token_Fast --
   -----------------------------

   procedure Write_Simple_Token_Fast
     (Data        : in out U64_Array;
      W           : in out Token_Writer;
      Value_Major : Value_Major_Arg;
      Value_Minor : Value_Minor_Arg;
      Continued   : Continued_Arg;
      Length      : Length_Arg)
   is
   begin
      Data (Data'First + W.Iop) := Make_Simple_Token (Value_Major, Value_Minor, Continued, Length);
      W := (W with delta Iop => W.Iop + 1);
   end Write_Simple_Token_Fast;

   -------------------------------
   -- Write_Extended_Token_Fast --
   -------------------------------

   procedure Write_Extended_Token_Fast
     (Data            : in out U64_Array;
      W               : in out Token_Writer;
      Value_Extension : Value_Extension_Arg;
      Continued       : Continued_Arg;
      Length          : Length_Arg)
   is
   begin
      Data (Data'First + W.Iop) := Make_Extended_Token (Value_Extension, Continued, Length);
      W := (W with delta Iop => W.Iop + 1);
   end Write_Extended_Token_Fast;

end Wuffs.Base.Tokens;
