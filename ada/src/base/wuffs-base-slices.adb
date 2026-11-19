with System;

package body Wuffs.Base.Slices with SPARK_Mode is

   pragma Assertion_Policy (Ignore);

   ---------------------------
   -- Host_Is_Little_Endian --
   ---------------------------

   function Host_Is_Little_Endian return Boolean is
      use type System.Bit_Order;
   begin
      return System.Default_Bit_Order = System.Low_Order_First;
   end Host_Is_Little_Endian;

   ---------------------
   -- Copy_From_Slice --
   ---------------------

   procedure Copy_From_Slice (Dst : in out Bytes; Src : Bytes; N : out U64) is
      Len : constant Offset := Offset'Min (Dst'Length, Src'Length);
   begin
      if Len > 0 then
         Dst (Dst'First .. Dst'First + (Len - 1)) := Src (Src'First .. Src'First + (Len - 1));
      end if;
      N := U64 (Len);
   end Copy_From_Slice;

   -----------------
   -- Copy_Within --
   -----------------

   procedure Copy_Within
     (Data       : in out Bytes;
      Dst_First  : Array_Index;
      Dst_Length : Element_Count;
      Src_First  : Array_Index;
      Src_Length : Element_Count;
      N          : out U64)
   is
      Len : constant Index := Index'Min (Dst_Length, Src_Length);
   begin
      if Len > 0 then
         --  One array object on both sides: the Ada language defines a
         --  slice assignment as copying as if through a temporary (RM
         --  5.2), whatever the overlap, and that is the semantics
         --  GNATprove uses.  Nothing here depends on how two different
         --  parameters would be compiled.
         Data (Dst_First .. Dst_First + (Len - 1)) := Data (Src_First .. Src_First + (Len - 1));
      end if;
      N := U64 (Len);
   end Copy_Within;

   --------------------
   -- Bulk_Memset_U8 --
   --------------------

   procedure Bulk_Memset_U8 (Dst : in out Bytes; Byte_Value : U8) is
   begin
      for J in Dst'Range loop
         Dst (J) := Byte_Value;
         pragma Loop_Invariant
           (for all K in Dst'First .. J => Dst (K) = Byte_Value);
      end loop;
   end Bulk_Memset_U8;

   ---------------------
   -- Bulk_Memset_U16 --
   ---------------------

   procedure Bulk_Memset_U16 (Dst : in out U16_Array; Byte_Value : U8) is
      V : constant U16 := Repeat_U16 (Byte_Value);
   begin
      for J in Dst'Range loop
         Dst (J) := V;
         pragma Loop_Invariant
           (for all K in Dst'First .. J => Dst (K) = V);
      end loop;
   end Bulk_Memset_U16;

   ---------------------
   -- Bulk_Memset_U32 --
   ---------------------

   procedure Bulk_Memset_U32 (Dst : in out U32_Array; Byte_Value : U8) is
      V : constant U32 := Repeat_U32 (Byte_Value);
   begin
      for J in Dst'Range loop
         Dst (J) := V;
         pragma Loop_Invariant
           (for all K in Dst'First .. J => Dst (K) = V);
      end loop;
   end Bulk_Memset_U32;

   ---------------------
   -- Bulk_Memset_U64 --
   ---------------------

   procedure Bulk_Memset_U64 (Dst : in out U64_Array; Byte_Value : U8) is
      V : constant U64 := Repeat_U64 (Byte_Value);
   begin
      for J in Dst'Range loop
         Dst (J) := V;
         pragma Loop_Invariant
           (for all K in Dst'First .. J => Dst (K) = V);
      end loop;
   end Bulk_Memset_U64;

   ------------------------------
   -- Bulk_Load_Host_Endian_U8 --
   ------------------------------

   procedure Bulk_Load_Host_Endian_U8 (Dst : in out Bytes; Src : Bytes) is
   begin
      if Bulk_Fits (Dst'Length, 1, Src'Length) then
         Dst := Src (Src'First .. Src'First + (Dst'Length - 1));
      end if;
   end Bulk_Load_Host_Endian_U8;

   ------------------------------
   -- Bulk_Save_Host_Endian_U8 --
   ------------------------------

   procedure Bulk_Save_Host_Endian_U8 (Dst : in out Bytes; Src : Bytes) is
   begin
      if Bulk_Fits (Src'Length, 1, Dst'Length) then
         Dst (Dst'First .. Dst'First + (Src'Length - 1)) := Src;
      end if;
   end Bulk_Save_Host_Endian_U8;

   -------------------------------------
   -- Bulk_Load_Host_Endian_U8_Within --
   -------------------------------------

   procedure Bulk_Load_Host_Endian_U8_Within
     (Data       : in out Bytes;
      Dst_First  : Array_Index;
      Dst_Length : Element_Count;
      Src_First  : Array_Index;
      Src_Length : Element_Count)
   is
   begin
      if Bulk_Fits (Dst_Length, 1, Src_Length) then
         --  An Ada slice assignment has memmove semantics.
         Data (Dst_First .. Dst_First + (Dst_Length - 1)) :=
           Data (Src_First .. Src_First + (Dst_Length - 1));
      end if;
   end Bulk_Load_Host_Endian_U8_Within;

   -------------------------------------
   -- Bulk_Save_Host_Endian_U8_Within --
   -------------------------------------

   procedure Bulk_Save_Host_Endian_U8_Within
     (Data       : in out Bytes;
      Dst_First  : Array_Index;
      Dst_Length : Element_Count;
      Src_First  : Array_Index;
      Src_Length : Element_Count)
   is
   begin
      if Bulk_Fits (Src_Length, 1, Dst_Length) then
         Data (Dst_First .. Dst_First + (Src_Length - 1)) :=
           Data (Src_First .. Src_First + (Src_Length - 1));
      end if;
   end Bulk_Save_Host_Endian_U8_Within;

   -------------------------------
   -- Bulk_Load_Host_Endian_U16 --
   -------------------------------

   procedure Bulk_Load_Host_Endian_U16 (Dst : in out U16_Array; Src : Bytes) is
   begin
      if Bulk_Fits (Dst'Length, 2, Src'Length) then
         for J in Dst'Range loop
            Dst (J) := Host_U16 (Src, Src'First + 2 * (J - Dst'First));
            pragma Loop_Invariant
              (for all K in Dst'First .. J =>
                 Dst (K) = Host_U16 (Src, Src'First + 2 * (K - Dst'First)));
         end loop;
      end if;
   end Bulk_Load_Host_Endian_U16;

   -------------------------------
   -- Bulk_Save_Host_Endian_U16 --
   -------------------------------

   procedure Bulk_Save_Host_Endian_U16 (Dst : in out Bytes; Src : U16_Array) is
      Pos : Index;
   begin
      if Bulk_Fits (Src'Length, 2, Dst'Length) then
         for J in Src'Range loop
            Pos := Dst'First + 2 * (J - Src'First);
            if Host_Is_Little_Endian then
               Endian.Poke_U16LE (Dst, Pos, Src (J));
            else
               Endian.Poke_U16BE (Dst, Pos, Src (J));
            end if;
            pragma Loop_Invariant
              (for all K in Src'First .. J =>
                 Host_U16 (Dst, Dst'First + 2 * (K - Src'First)) = Src (K));
            pragma Loop_Invariant
              (for all K in Dst'Range =>
                 (if K - Dst'First >= 2 * (J - Src'First + 1)
                  then Dst (K) = Dst'Loop_Entry (K)));
         end loop;
      end if;
   end Bulk_Save_Host_Endian_U16;

   -------------------------------
   -- Bulk_Load_Host_Endian_U32 --
   -------------------------------

   procedure Bulk_Load_Host_Endian_U32 (Dst : in out U32_Array; Src : Bytes) is
   begin
      if Bulk_Fits (Dst'Length, 4, Src'Length) then
         for J in Dst'Range loop
            Dst (J) := Host_U32 (Src, Src'First + 4 * (J - Dst'First));
            pragma Loop_Invariant
              (for all K in Dst'First .. J =>
                 Dst (K) = Host_U32 (Src, Src'First + 4 * (K - Dst'First)));
         end loop;
      end if;
   end Bulk_Load_Host_Endian_U32;

   -------------------------------
   -- Bulk_Save_Host_Endian_U32 --
   -------------------------------

   procedure Bulk_Save_Host_Endian_U32 (Dst : in out Bytes; Src : U32_Array) is
      Pos : Index;
   begin
      if Bulk_Fits (Src'Length, 4, Dst'Length) then
         for J in Src'Range loop
            Pos := Dst'First + 4 * (J - Src'First);
            if Host_Is_Little_Endian then
               Endian.Poke_U32LE (Dst, Pos, Src (J));
            else
               Endian.Poke_U32BE (Dst, Pos, Src (J));
            end if;
            pragma Loop_Invariant
              (for all K in Src'First .. J =>
                 Host_U32 (Dst, Dst'First + 4 * (K - Src'First)) = Src (K));
            pragma Loop_Invariant
              (for all K in Dst'Range =>
                 (if K - Dst'First >= 4 * (J - Src'First + 1)
                  then Dst (K) = Dst'Loop_Entry (K)));
         end loop;
      end if;
   end Bulk_Save_Host_Endian_U32;

   -------------------------------
   -- Bulk_Load_Host_Endian_U64 --
   -------------------------------

   procedure Bulk_Load_Host_Endian_U64 (Dst : in out U64_Array; Src : Bytes) is
   begin
      if Bulk_Fits (Dst'Length, 8, Src'Length) then
         for J in Dst'Range loop
            Dst (J) := Host_U64 (Src, Src'First + 8 * (J - Dst'First));
            pragma Loop_Invariant
              (for all K in Dst'First .. J =>
                 Dst (K) = Host_U64 (Src, Src'First + 8 * (K - Dst'First)));
         end loop;
      end if;
   end Bulk_Load_Host_Endian_U64;

   -------------------------------
   -- Bulk_Save_Host_Endian_U64 --
   -------------------------------

   procedure Bulk_Save_Host_Endian_U64 (Dst : in out Bytes; Src : U64_Array) is
      Pos : Index;
   begin
      if Bulk_Fits (Src'Length, 8, Dst'Length) then
         for J in Src'Range loop
            Pos := Dst'First + 8 * (J - Src'First);
            if Host_Is_Little_Endian then
               Endian.Poke_U64LE (Dst, Pos, Src (J));
            else
               Endian.Poke_U64BE (Dst, Pos, Src (J));
            end if;
            pragma Loop_Invariant
              (for all K in Src'First .. J =>
                 Host_U64 (Dst, Dst'First + 8 * (K - Src'First)) = Src (K));
            pragma Loop_Invariant
              (for all K in Dst'Range =>
                 (if K - Dst'First >= 8 * (J - Src'First + 1)
                  then Dst (K) = Dst'Loop_Entry (K)));
         end loop;
      end if;
   end Bulk_Save_Host_Endian_U64;

end Wuffs.Base.Slices;
