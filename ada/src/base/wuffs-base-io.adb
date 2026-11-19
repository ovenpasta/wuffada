package body Wuffs.Base.IO with SPARK_Mode is

   pragma Assertion_Policy (Ignore);

   --  The copy behind the _Within forms: Count elements from offset
   --  Src_Offset to offset Dst_Offset of the same array, memmove semantics.
   procedure Move
     (Data : in out Bytes; Dst_Offset, Src_Offset : Offset; Count : Element_Count)
   with
     Pre  => Slice_Within (Data, Dst_Offset, Count)
       and then Slice_Within (Data, Src_Offset, Count),
     Post => Is_Move (Data'Old, Data, Dst_Offset, Src_Offset, Count);

   --  The three copy loops behind the history copies.  Here, unlike in the
   --  public interface of this package, Pos is an Ada index into Data.

   --  Byte by byte, front to back.  (The C code unrolls this loop by 3;
   --  the effect is the same.)
   procedure Copy_History (Data : in out Bytes; Pos, Count, Dist : Index) with
     Pre  => Dist >= 1
       and then Count >= 1
       and then Endian.Has (Data, Pos, Count)
       and then Pos - Dist >= Data'First,
     Post => Is_History_Copy (Data'Old, Data, Pos, Count, Dist);

   --  Total / 8 chunks of 8 bytes, front to back.  With Dist >= 8 a chunk's
   --  source lies wholly before the chunk, so this equals the byte by byte
   --  copy of Total bytes.
   procedure Copy_History_Chunks (Data : in out Bytes; Pos, Total, Dist : Index) with
     Pre  => Dist >= 8
       and then Total >= 8
       and then Total mod 8 = 0
       and then Endian.Has (Data, Pos, Total)
       and then Pos - Dist >= Data'First,
     Post => Is_History_Copy (Data'Old, Data, Pos, Total, Dist);

   --  Total / 8 chunks of 8 copies of the byte before Pos, which equals
   --  the byte by byte copy of Total bytes with distance 1.
   procedure Repeat_History_Chunks (Data : in out Bytes; Pos, Total : Index) with
     Pre  => Total >= 8
       and then Total mod 8 = 0
       and then Endian.Has (Data, Pos, Total)
       and then Pos - Data'First >= 1,
     Post => Is_History_Copy (Data'Old, Data, Pos, Total, 1);

   ----------
   -- Move --
   ----------

   procedure Move
     (Data : in out Bytes; Dst_Offset, Src_Offset : Offset; Count : Element_Count)
   is
   begin
      if Count > 0 then
         --  One array object on both sides: an Ada slice assignment
         --  copies as if through a temporary (RM 5.2), whatever the
         --  overlap.
         Data (Data'First + Dst_Offset .. Data'First + Dst_Offset + (Count - 1)) :=
           Data (Data'First + Src_Offset .. Data'First + Src_Offset + (Count - 1));
      end if;
   end Move;

   ------------------
   -- Copy_History --
   ------------------

   procedure Copy_History (Data : in out Bytes; Pos, Count, Dist : Index) is
   begin
      for K in 0 .. Count - 1 loop
         Data (Pos + K) := Data (Pos + K - Dist);
         pragma Loop_Invariant (Is_History_Copy (Data'Loop_Entry, Data, Pos, K + 1, Dist));
      end loop;
   end Copy_History;

   -------------------------
   -- Copy_History_Chunks --
   -------------------------

   procedure Copy_History_Chunks (Data : in out Bytes; Pos, Total, Dist : Index) is
      C : Index := 0;
   begin
      loop
         Data (Pos + C .. Pos + C + 7) := Data (Pos + C - Dist .. Pos + C - Dist + 7);
         C := C + 8;
         pragma Loop_Invariant (C mod 8 = 0 and then C <= Total);
         pragma Loop_Invariant (Is_History_Copy (Data'Loop_Entry, Data, Pos, C, Dist));
         pragma Loop_Variant (Increases => C);
         exit when C = Total;
      end loop;
   end Copy_History_Chunks;

   ---------------------------
   -- Repeat_History_Chunks --
   ---------------------------

   procedure Repeat_History_Chunks (Data : in out Bytes; Pos, Total : Index) is
      B : constant U8 := Data (Pos - 1);
      C : Index := 0;
   begin
      loop
         Data (Pos + C .. Pos + C + 7) := [others => B];
         C := C + 8;
         pragma Loop_Invariant (C mod 8 = 0 and then C <= Total);
         pragma Loop_Invariant
           (for all J in Data'Range =>
              (if J >= Pos and then J - Pos < C
               then Data (J) = B
               else Data (J) = Data'Loop_Entry (J)));
         pragma Loop_Variant (Increases => C);
         exit when C = Total;
      end loop;
   end Repeat_History_Chunks;

   -----------------------
   -- Compact_Retaining --
   -----------------------

   procedure Compact_Retaining
     (Data                  : in out Bytes;
      M                     : in out Buffer_Meta;
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

   procedure Compact (Data : in out Bytes; M : in out Buffer_Meta; N : out Index) is
   begin
      Compact_Retaining (Data, M, 0, N);
   end Compact;

   ----------
   -- Save --
   ----------

   procedure Save (M : in out Buffer_Meta; R : Reader) is
   begin
      M := (M with delta Ri => R.Iop);
   end Save;

   procedure Save (M : in out Buffer_Meta; W : Writer) is
   begin
      M := (M with delta Wi => W.Iop);
   end Save;

   ---------------
   -- Undo_Byte --
   ---------------

   procedure Undo_Byte (R : in out Reader) is
   begin
      R := (R with delta Iop => R.Iop - 1);
   end Undo_Byte;

   procedure Undo_Byte (W : in out Writer) is
   begin
      W := (W with delta Iop => W.Iop - 1);
   end Undo_Byte;

   ------------
   -- Reload --
   ------------

   procedure Reload (R : in out Reader; M : Buffer_Meta) is
   begin
      R := (R with delta Iop => M.Ri);
   end Reload;

   procedure Reload (W : in out Writer; M : Buffer_Meta) is
   begin
      W := (W with delta Iop => M.Wi);
   end Reload;

   -----------------
   -- Begin_Limit --
   -----------------

   procedure Begin_Limit
     (M     : in out Buffer_Meta;
      R     : in out Reader;
      Up_To : U64;
      Saved : out Reader_Limit_State)
   is
      New_Io2 : constant Index :=
        (if Length (R) > Up_To then R.Iop + Index (Up_To) else R.Io2);
      Closed  : constant Boolean := M.Closed and then M.Wi <= New_Io2;
   begin
      Saved := (Io2 => R.Io2, Closed => M.Closed);
      M := (M with delta Wi => New_Io2, Closed => Closed);
      R := (R with delta Io2 => New_Io2, Closed => Closed);
   end Begin_Limit;

   procedure Begin_Limit
     (W         : in out Writer;
      Up_To     : U64;
      Saved_Io2 : out First_Offset)
   is
   begin
      Saved_Io2 := W.Io2;
      if Length (W) > Up_To then
         W := (W with delta Io2 => W.Iop + Index (Up_To));
      end if;
   end Begin_Limit;

   ---------------
   -- End_Limit --
   ---------------

   procedure End_Limit
     (M     : in out Buffer_Meta;
      R     : in out Reader;
      Saved : Reader_Limit_State)
   is
   begin
      R := (R with delta Io2 => Saved.Io2, Closed => Saved.Closed);
      M := (M with delta Wi => Saved.Io2, Closed => Saved.Closed);
   end End_Limit;

   procedure End_Limit (W : in out Writer; Saved_Io2 : First_Offset) is
   begin
      W := (W with delta Io2 => Saved_Io2);
   end End_Limit;

   --------------------------
   -- Begin_Forget_History --
   --------------------------

   procedure Begin_Forget_History
     (M     : in out Buffer_Meta;
      W     : in out Writer;
      Saved : out Forget_State)
   is
      New_Pos : constant U64 := Ints.Sat_Add_U64 (M.Pos, U64 (M.Wi));
   begin
      Saved := (Meta => M, Io0 => W.Io0, Io1 => W.Io1);
      M := (Wi => 0, Ri => 0, Pos => New_Pos, Closed => M.Closed);
      W := (W with delta Io0 => W.Iop, Io1 => W.Iop, Pos => New_Pos);
   end Begin_Forget_History;

   ------------------------
   -- End_Forget_History --
   ------------------------

   procedure End_Forget_History
     (M     : out Buffer_Meta;
      W     : in out Writer;
      Saved : Forget_State)
   is
   begin
      M := (Saved.Meta with delta Wi => W.Iop);
      W := (W with delta Io0 => Saved.Io0, Io1 => Saved.Io1, Pos => Saved.Meta.Pos);
   end End_Forget_History;

   --------------------
   -- Save_Forgotten --
   --------------------

   procedure Save_Forgotten
     (M : in out Buffer_Meta; W : Writer; Saved : Forget_State)
   is
   begin
      M := (M with delta Wi => W.Iop - Forgotten_Base (Saved));
   end Save_Forgotten;

   ----------------------
   -- Reload_Forgotten --
   ----------------------

   procedure Reload_Forgotten
     (W : in out Writer; M : Buffer_Meta; Saved : Forget_State)
   is
   begin
      W := (W with delta Iop => Forgotten_Base (Saved) + M.Wi);
   end Reload_Forgotten;

   ------------
   -- Match7 --
   ------------

   function Match7 (Data : Bytes; R : Reader; A : U64) return U32 is
      N      : constant Natural := Natural (A and 7);
      Prefix : constant U64 := Interfaces.Shift_Right (A, 8);
   begin
      if R.Io2 - R.Iop >= 8 then
         declare
            X     : constant U64 := Endian.Peek_U64LE (Data, Data'First + R.Iop);
            Shift : constant Natural := 8 * (8 - N);
         begin
            return
              (if Interfaces.Shift_Left (Prefix, Shift) = Interfaces.Shift_Left (X, Shift)
               then 0 else 2);
         end;
      end if;

      --  Fewer than 8 bytes are available.  N is at most 7.
      for K in 0 .. 6 loop
         exit when K >= N;
         if R.Iop + Index (K) >= R.Io2 then
            return (if R.Closed then 2 else 1);
         elsif Data (Data'First + (R.Iop + Index (K))) /=
           U8 (Interfaces.Shift_Right (Prefix, 8 * K) and 16#FF#)
         then
            return 2;
         end if;
      end loop;
      return 0;
   end Match7;

   -------------------
   -- Skip_U32_Fast --
   -------------------

   procedure Skip_U32_Fast (R : in out Reader; Actual : U32) is
   begin
      R := (R with delta Iop => R.Iop + Index (Actual));
   end Skip_U32_Fast;

   -------------------------------
   -- Limited_Copy_U32_To_Slice --
   -------------------------------

   procedure Limited_Copy_U32_To_Slice
     (Data  : Bytes;
      R     : in out Reader;
      Up_To : U32;
      Dst   : in out Bytes;
      N     : out U32)
   is
      Count : constant Offset :=
        Offset'Min (Offset'Min (Dst'Length, Offset (Up_To)), R.Io2 - R.Iop);
   begin
      if Count > 0 then
         Dst (Dst'First .. Dst'First + (Count - 1)) :=
           Data (Data'First + R.Iop .. Data'First + R.Iop + (Count - 1));
         R := (R with delta Iop => R.Iop + Count);
      end if;
      N := U32 (Count);
   end Limited_Copy_U32_To_Slice;

   -------------
   -- Read_U8 --
   -------------

   procedure Read_U8 (Data : Bytes; R : in out Reader; V : out U8) is
   begin
      V := Data (Data'First + R.Iop);
      R := (R with delta Iop => R.Iop + 1);
   end Read_U8;

   ------------------
   -- Read_Step_LE --
   ------------------

   procedure Read_Step_LE
     (Data       : Bytes;
      R          : in out Reader;
      Scratch    : in out U64;
      Last_Shift : Read_Last_Shift;
      Done       : out Boolean;
      Value      : out U64)
   is
      Num_Bits : constant U64 := Interfaces.Shift_Right (Scratch, 56);
      B        : constant U8 := Data (Data'First + R.Iop);
   begin
      R := (R with delta Iop => R.Iop + 1);
      Scratch := Interfaces.Shift_Right (Interfaces.Shift_Left (Scratch, 8), 8);
      Scratch := Scratch or Interfaces.Shift_Left (U64 (B), Natural (Num_Bits));
      if Num_Bits = U64 (Last_Shift) then
         Done := True;
         Value := Scratch;
      else
         Done := False;
         Value := 0;
         Scratch := Scratch or Interfaces.Shift_Left (Num_Bits + 8, 56);
      end if;
   end Read_Step_LE;

   ------------------
   -- Read_Step_BE --
   ------------------

   procedure Read_Step_BE
     (Data       : Bytes;
      R          : in out Reader;
      Scratch    : in out U64;
      Last_Shift : Read_Last_Shift;
      Done       : out Boolean;
      Value      : out U64)
   is
      Num_Bits : constant U64 := Scratch and 16#FF#;
      B        : constant U8 := Data (Data'First + R.Iop);
   begin
      R := (R with delta Iop => R.Iop + 1);
      Scratch := Interfaces.Shift_Left (Interfaces.Shift_Right (Scratch, 8), 8);
      Scratch := Scratch or Interfaces.Shift_Left (U64 (B), 56 - Natural (Num_Bits));
      if Num_Bits = U64 (Last_Shift) then
         Done := True;
         Value := Interfaces.Shift_Right (Scratch, 56 - Natural (Last_Shift));
      else
         Done := False;
         Value := 0;
         Scratch := Scratch or (Num_Bits + 8);
      end if;
   end Read_Step_BE;

   ----------
   -- Skip --
   ----------

   procedure Skip (R : in out Reader; Scratch : in out U64; Done : out Boolean) is
      Available : constant U64 := Length (R);
   begin
      if Scratch > Available then
         Scratch := Scratch - Available;
         R := (R with delta Iop => R.Io2);
         Done := False;
      else
         R := (R with delta Iop => R.Iop + Index (Scratch));
         Done := True;
      end if;
   end Skip;

   -------------------
   -- Write_U8_Fast --
   -------------------

   procedure Write_U8_Fast (Data : in out Bytes; W : in out Writer; V : U8) is
   begin
      Endian.Poke_U8 (Data, Data'First + W.Iop, V);
      W := (W with delta Iop => W.Iop + 1);
   end Write_U8_Fast;

   ----------------------
   -- Write_U16BE_Fast --
   ----------------------

   procedure Write_U16BE_Fast (Data : in out Bytes; W : in out Writer; V : U16) is
   begin
      Endian.Poke_U16BE (Data, Data'First + W.Iop, V);
      W := (W with delta Iop => W.Iop + 2);
   end Write_U16BE_Fast;

   ----------------------
   -- Write_U16LE_Fast --
   ----------------------

   procedure Write_U16LE_Fast (Data : in out Bytes; W : in out Writer; V : U16) is
   begin
      Endian.Poke_U16LE (Data, Data'First + W.Iop, V);
      W := (W with delta Iop => W.Iop + 2);
   end Write_U16LE_Fast;

   ----------------------
   -- Write_U24BE_Fast --
   ----------------------

   procedure Write_U24BE_Fast (Data : in out Bytes; W : in out Writer; V : U32) is
   begin
      Endian.Poke_U24BE (Data, Data'First + W.Iop, V);
      W := (W with delta Iop => W.Iop + 3);
   end Write_U24BE_Fast;

   ----------------------
   -- Write_U24LE_Fast --
   ----------------------

   procedure Write_U24LE_Fast (Data : in out Bytes; W : in out Writer; V : U32) is
   begin
      Endian.Poke_U24LE (Data, Data'First + W.Iop, V);
      W := (W with delta Iop => W.Iop + 3);
   end Write_U24LE_Fast;

   ----------------------
   -- Write_U32BE_Fast --
   ----------------------

   procedure Write_U32BE_Fast (Data : in out Bytes; W : in out Writer; V : U32) is
   begin
      Endian.Poke_U32BE (Data, Data'First + W.Iop, V);
      W := (W with delta Iop => W.Iop + 4);
   end Write_U32BE_Fast;

   ----------------------
   -- Write_U32LE_Fast --
   ----------------------

   procedure Write_U32LE_Fast (Data : in out Bytes; W : in out Writer; V : U32) is
   begin
      Endian.Poke_U32LE (Data, Data'First + W.Iop, V);
      W := (W with delta Iop => W.Iop + 4);
   end Write_U32LE_Fast;

   ----------------------
   -- Write_U40BE_Fast --
   ----------------------

   procedure Write_U40BE_Fast (Data : in out Bytes; W : in out Writer; V : U64) is
   begin
      Endian.Poke_U40BE (Data, Data'First + W.Iop, V);
      W := (W with delta Iop => W.Iop + 5);
   end Write_U40BE_Fast;

   ----------------------
   -- Write_U40LE_Fast --
   ----------------------

   procedure Write_U40LE_Fast (Data : in out Bytes; W : in out Writer; V : U64) is
   begin
      Endian.Poke_U40LE (Data, Data'First + W.Iop, V);
      W := (W with delta Iop => W.Iop + 5);
   end Write_U40LE_Fast;

   ----------------------
   -- Write_U48BE_Fast --
   ----------------------

   procedure Write_U48BE_Fast (Data : in out Bytes; W : in out Writer; V : U64) is
   begin
      Endian.Poke_U48BE (Data, Data'First + W.Iop, V);
      W := (W with delta Iop => W.Iop + 6);
   end Write_U48BE_Fast;

   ----------------------
   -- Write_U48LE_Fast --
   ----------------------

   procedure Write_U48LE_Fast (Data : in out Bytes; W : in out Writer; V : U64) is
   begin
      Endian.Poke_U48LE (Data, Data'First + W.Iop, V);
      W := (W with delta Iop => W.Iop + 6);
   end Write_U48LE_Fast;

   ----------------------
   -- Write_U56BE_Fast --
   ----------------------

   procedure Write_U56BE_Fast (Data : in out Bytes; W : in out Writer; V : U64) is
   begin
      Endian.Poke_U56BE (Data, Data'First + W.Iop, V);
      W := (W with delta Iop => W.Iop + 7);
   end Write_U56BE_Fast;

   ----------------------
   -- Write_U56LE_Fast --
   ----------------------

   procedure Write_U56LE_Fast (Data : in out Bytes; W : in out Writer; V : U64) is
   begin
      Endian.Poke_U56LE (Data, Data'First + W.Iop, V);
      W := (W with delta Iop => W.Iop + 7);
   end Write_U56LE_Fast;

   ----------------------
   -- Write_U64BE_Fast --
   ----------------------

   procedure Write_U64BE_Fast (Data : in out Bytes; W : in out Writer; V : U64) is
   begin
      Endian.Poke_U64BE (Data, Data'First + W.Iop, V);
      W := (W with delta Iop => W.Iop + 8);
   end Write_U64BE_Fast;

   ----------------------
   -- Write_U64LE_Fast --
   ----------------------

   procedure Write_U64LE_Fast (Data : in out Bytes; W : in out Writer; V : U64) is
   begin
      Endian.Poke_U64LE (Data, Data'First + W.Iop, V);
      W := (W with delta Iop => W.Iop + 8);
   end Write_U64LE_Fast;
   ---------------------
   -- Copy_From_Slice --
   ---------------------

   procedure Copy_From_Slice
     (Data : in out Bytes;
      W    : in out Writer;
      Src  : Bytes;
      N    : out U64)
   is
      Count : constant Offset := Offset'Min (Src'Length, W.Io2 - W.Iop);
   begin
      if Count > 0 then
         Data (Data'First + W.Iop .. Data'First + W.Iop + (Count - 1)) :=
           Src (Src'First .. Src'First + (Count - 1));
         W := (W with delta Iop => W.Iop + Count);
      end if;
      N := U64 (Count);
   end Copy_From_Slice;

   ---------------------------------
   -- Limited_Copy_U32_From_Slice --
   ---------------------------------

   procedure Limited_Copy_U32_From_Slice
     (Data  : in out Bytes;
      W     : in out Writer;
      Up_To : U32;
      Src   : Bytes;
      N     : out U32)
   is
      Count : constant Offset :=
        Offset'Min (Offset'Min (Src'Length, Offset (Up_To)), W.Io2 - W.Iop);
   begin
      if Count > 0 then
         Data (Data'First + W.Iop .. Data'First + W.Iop + (Count - 1)) :=
           Src (Src'First .. Src'First + (Count - 1));
         W := (W with delta Iop => W.Iop + Count);
      end if;
      N := U32 (Count);
   end Limited_Copy_U32_From_Slice;

   ----------------------------------
   -- Limited_Copy_U32_From_Reader --
   ----------------------------------

   procedure Limited_Copy_U32_From_Reader
     (Data     : in out Bytes;
      W        : in out Writer;
      Up_To    : U32;
      Src_Data : Bytes;
      R        : in out Reader;
      N        : out U32)
   is
      Count : constant Index :=
        Index'Min (Index'Min (Index (Up_To), W.Io2 - W.Iop), R.Io2 - R.Iop);
   begin
      if Count > 0 then
         Data (Data'First + W.Iop .. Data'First + W.Iop + (Count - 1)) :=
           Src_Data (Src_Data'First + R.Iop .. Src_Data'First + R.Iop + (Count - 1));
         W := (W with delta Iop => W.Iop + Count);
         R := (R with delta Iop => R.Iop + Count);
      end if;
      N := U32 (Count);
   end Limited_Copy_U32_From_Reader;

   --------------------------------------
   -- Limited_Copy_U32_To_Slice_Within --
   --------------------------------------

   procedure Limited_Copy_U32_To_Slice_Within
     (Data       : in out Bytes;
      R_Base     : First_Offset;
      R          : in out Reader;
      Up_To      : U32;
      Dst_Offset : First_Offset;
      Dst_Length : Element_Count;
      N          : out U32)
   is
      Count : constant Index :=
        Index'Min (Index'Min (Index (Up_To), Dst_Length), R.Io2 - R.Iop);
   begin
      Move (Data, Dst_Offset, R_Base + R.Iop, Count);
      R := (R with delta Iop => R.Iop + Count);
      N := U32 (Count);
   end Limited_Copy_U32_To_Slice_Within;

   ----------------------------
   -- Copy_From_Slice_Within --
   ----------------------------

   procedure Copy_From_Slice_Within
     (Data       : in out Bytes;
      W_Base     : First_Offset;
      W          : in out Writer;
      Src_Offset : First_Offset;
      Src_Length : Element_Count;
      N          : out U64)
   is
      Count : constant Index := Index'Min (Src_Length, W.Io2 - W.Iop);
   begin
      Move (Data, W_Base + W.Iop, Src_Offset, Count);
      W := (W with delta Iop => W.Iop + Count);
      N := U64 (Count);
   end Copy_From_Slice_Within;

   ----------------------------------------
   -- Limited_Copy_U32_From_Slice_Within --
   ----------------------------------------

   procedure Limited_Copy_U32_From_Slice_Within
     (Data       : in out Bytes;
      W_Base     : First_Offset;
      W          : in out Writer;
      Up_To      : U32;
      Src_Offset : First_Offset;
      Src_Length : Element_Count;
      N          : out U32)
   is
      Count : constant Index :=
        Index'Min (Index'Min (Index (Up_To), Src_Length), W.Io2 - W.Iop);
   begin
      Move (Data, W_Base + W.Iop, Src_Offset, Count);
      W := (W with delta Iop => W.Iop + Count);
      N := U32 (Count);
   end Limited_Copy_U32_From_Slice_Within;

   -----------------------------------------
   -- Limited_Copy_U32_From_Reader_Within --
   -----------------------------------------

   procedure Limited_Copy_U32_From_Reader_Within
     (Data   : in out Bytes;
      W_Base : First_Offset;
      W      : in out Writer;
      Up_To  : U32;
      R_Base : First_Offset;
      R      : in out Reader;
      N      : out U32)
   is
      Count : constant Index :=
        Index'Min (Index'Min (Index (Up_To), W.Io2 - W.Iop), R.Io2 - R.Iop);
   begin
      Move (Data, W_Base + W.Iop, R_Base + R.Iop, Count);
      W := (W with delta Iop => W.Iop + Count);
      R := (R with delta Iop => R.Iop + Count);
      N := U32 (Count);
   end Limited_Copy_U32_From_Reader_Within;

   -----------------------------------
   -- Limited_Copy_U32_From_History --
   -----------------------------------

   procedure Limited_Copy_U32_From_History
     (Data     : in out Bytes;
      W        : in out Writer;
      Up_To    : U32;
      Distance : U32;
      N        : out U32)
   is
      Count : Index;
   begin
      N := 0;
      if Distance = 0 or else W.Iop - W.Io0 < Index (Distance) then
         return;
      end if;
      Count := Index'Min (Index (Up_To), W.Io2 - W.Iop);
      if Count = 0 then
         return;
      end if;
      Copy_History (Data, Data'First + W.Iop, Count, Index (Distance));
      W := (W with delta Iop => W.Iop + Count);
      N := U32 (Count);
   end Limited_Copy_U32_From_History;

   ----------------------------------------
   -- Limited_Copy_U32_From_History_Fast --
   ----------------------------------------

   procedure Limited_Copy_U32_From_History_Fast
     (Data     : in out Bytes;
      W        : in out Writer;
      Up_To    : U32;
      Distance : U32;
      N        : out U32)
   is
   begin
      Copy_History (Data, Data'First + W.Iop, Index (Up_To), Index (Distance));
      W := (W with delta Iop => W.Iop + Index (Up_To));
      N := Up_To;
   end Limited_Copy_U32_From_History_Fast;

   ----------------------------------------------------
   -- Limited_Copy_U32_From_History_Fast_Return_Cusp --
   ----------------------------------------------------

   procedure Limited_Copy_U32_From_History_Fast_Return_Cusp
     (Data     : in out Bytes;
      W        : in out Writer;
      Up_To    : U32;
      Distance : U32;
      Cusp     : out U32)
   is
   begin
      Copy_History (Data, Data'First + W.Iop, Index (Up_To), Index (Distance));
      Cusp := Cusp_At (Data, W.Iop, Up_To, Distance);
      W := (W with delta Iop => W.Iop + Index (Up_To));
   end Limited_Copy_U32_From_History_Fast_Return_Cusp;

   ------------------------------------------------------
   -- Limited_Copy_U32_From_History_8_Byte_Chunks_Fast --
   ------------------------------------------------------

   procedure Limited_Copy_U32_From_History_8_Byte_Chunks_Fast
     (Data     : in out Bytes;
      W        : in out Writer;
      Up_To    : U32;
      Distance : U32;
      N        : out U32)
   is
   begin
      Copy_History_Chunks
        (Data, Data'First + W.Iop, Chunked_Length (Up_To), Index (Distance));
      W := (W with delta Iop => W.Iop + Index (Up_To));
      N := Up_To;
   end Limited_Copy_U32_From_History_8_Byte_Chunks_Fast;

   ------------------------------------------------------------------
   -- Limited_Copy_U32_From_History_8_Byte_Chunks_Fast_Return_Cusp --
   ------------------------------------------------------------------

   procedure Limited_Copy_U32_From_History_8_Byte_Chunks_Fast_Return_Cusp
     (Data     : in out Bytes;
      W        : in out Writer;
      Up_To    : U32;
      Distance : U32;
      Cusp     : out U32)
   is
   begin
      Copy_History_Chunks
        (Data, Data'First + W.Iop, Chunked_Length (Up_To), Index (Distance));
      Cusp := Cusp_At (Data, W.Iop, Up_To, Distance);
      W := (W with delta Iop => W.Iop + Index (Up_To));
   end Limited_Copy_U32_From_History_8_Byte_Chunks_Fast_Return_Cusp;

   -----------------------------------------------------------------
   -- Limited_Copy_U32_From_History_8_Byte_Chunks_Distance_1_Fast --
   -----------------------------------------------------------------

   procedure Limited_Copy_U32_From_History_8_Byte_Chunks_Distance_1_Fast
     (Data     : in out Bytes;
      W        : in out Writer;
      Up_To    : U32;
      Distance : U32;
      N        : out U32)
   is
      pragma Unreferenced (Distance);
   begin
      Repeat_History_Chunks (Data, Data'First + W.Iop, Chunked_Length (Up_To));
      W := (W with delta Iop => W.Iop + Index (Up_To));
      N := Up_To;
   end Limited_Copy_U32_From_History_8_Byte_Chunks_Distance_1_Fast;

   -----------------------------------------------------------------------------
   -- Limited_Copy_U32_From_History_8_Byte_Chunks_Distance_1_Fast_Return_Cusp --
   -----------------------------------------------------------------------------

   procedure Limited_Copy_U32_From_History_8_Byte_Chunks_Distance_1_Fast_Return_Cusp
     (Data     : in out Bytes;
      W        : in out Writer;
      Up_To    : U32;
      Distance : U32;
      Cusp     : out U32)
   is
   begin
      Repeat_History_Chunks (Data, Data'First + W.Iop, Chunked_Length (Up_To));
      Cusp := Cusp_At (Data, W.Iop, Up_To, Distance);
      W := (W with delta Iop => W.Iop + Index (Up_To));
   end Limited_Copy_U32_From_History_8_Byte_Chunks_Distance_1_Fast_Return_Cusp;

end Wuffs.Base.IO;
