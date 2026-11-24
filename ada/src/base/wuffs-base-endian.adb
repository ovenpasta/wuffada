package body Wuffs.Base.Endian with SPARK_Mode is

   --  Each poke builds its bytes in B and stores them with one slice
   --  assignment, which GCC compiles to one store (plus a byte swap for big
   --  endian).

   pragma Assertion_Policy (Ignore);

   -------------
   -- Poke_U8 --
   -------------

   procedure Poke_U8 (Data : in out Bytes; Pos : Array_Index; V : U8) is
   begin
      Data (Pos) := V;
   end Poke_U8;

   ----------------
   -- Poke_U16BE --
   ----------------

   procedure Poke_U16BE (Data : in out Bytes; Pos : Array_Index; V : U16) is
      B : constant Bytes_2 :=
        [U8 (Interfaces.Shift_Right (V, 8) and 16#FF#),
         U8 (V and 16#FF#)];
   begin
      pragma Assert (Combine_U16BE (B) = V);
      Data (Pos .. Pos + 1) := B;
   end Poke_U16BE;

   ----------------
   -- Poke_U16LE --
   ----------------

   procedure Poke_U16LE (Data : in out Bytes; Pos : Array_Index; V : U16) is
      B : constant Bytes_2 :=
        [U8 (V and 16#FF#),
         U8 (Interfaces.Shift_Right (V, 8) and 16#FF#)];
   begin
      pragma Assert (Combine_U16LE (B) = V);
      Data (Pos .. Pos + 1) := B;
   end Poke_U16LE;

   ----------------
   -- Poke_U24BE --
   ----------------

   procedure Poke_U24BE (Data : in out Bytes; Pos : Array_Index; V : U32) is
      B : constant Bytes_3 :=
        [U8 (Interfaces.Shift_Right (V, 16) and 16#FF#),
         U8 (Interfaces.Shift_Right (V, 8) and 16#FF#),
         U8 (V and 16#FF#)];
   begin
      pragma Assert (Combine_U24BE (B) = (V and 16#FF_FFFF#));
      Data (Pos .. Pos + 2) := B;
   end Poke_U24BE;

   ----------------
   -- Poke_U24LE --
   ----------------

   procedure Poke_U24LE (Data : in out Bytes; Pos : Array_Index; V : U32) is
      B : constant Bytes_3 :=
        [U8 (V and 16#FF#),
         U8 (Interfaces.Shift_Right (V, 8) and 16#FF#),
         U8 (Interfaces.Shift_Right (V, 16) and 16#FF#)];
   begin
      pragma Assert (Combine_U24LE (B) = (V and 16#FF_FFFF#));
      Data (Pos .. Pos + 2) := B;
   end Poke_U24LE;

   ----------------
   -- Poke_U32BE --
   ----------------

   procedure Poke_U32BE (Data : in out Bytes; Pos : Array_Index; V : U32) is
      B : constant Bytes_4 :=
        [U8 (Interfaces.Shift_Right (V, 24) and 16#FF#),
         U8 (Interfaces.Shift_Right (V, 16) and 16#FF#),
         U8 (Interfaces.Shift_Right (V, 8) and 16#FF#),
         U8 (V and 16#FF#)];
   begin
      pragma Assert (Combine_U32BE (B) = V);
      Data (Pos .. Pos + 3) := B;
   end Poke_U32BE;

   ----------------
   -- Poke_U32LE --
   ----------------

   procedure Poke_U32LE (Data : in out Bytes; Pos : Array_Index; V : U32) is
      B : constant Bytes_4 :=
        [U8 (V and 16#FF#),
         U8 (Interfaces.Shift_Right (V, 8) and 16#FF#),
         U8 (Interfaces.Shift_Right (V, 16) and 16#FF#),
         U8 (Interfaces.Shift_Right (V, 24) and 16#FF#)];
   begin
      pragma Assert (Combine_U32LE (B) = V);
      Data (Pos .. Pos + 3) := B;
   end Poke_U32LE;

   ----------------
   -- Poke_U40BE --
   ----------------

   procedure Poke_U40BE (Data : in out Bytes; Pos : Array_Index; V : U64) is
      B : constant Bytes_5 :=
        [U8 (Interfaces.Shift_Right (V, 32) and 16#FF#),
         U8 (Interfaces.Shift_Right (V, 24) and 16#FF#),
         U8 (Interfaces.Shift_Right (V, 16) and 16#FF#),
         U8 (Interfaces.Shift_Right (V, 8) and 16#FF#),
         U8 (V and 16#FF#)];
   begin
      pragma Assert (Combine_U40BE (B) = (V and 16#FF_FFFF_FFFF#));
      Data (Pos .. Pos + 4) := B;
   end Poke_U40BE;

   ----------------
   -- Poke_U40LE --
   ----------------

   procedure Poke_U40LE (Data : in out Bytes; Pos : Array_Index; V : U64) is
      B : constant Bytes_5 :=
        [U8 (V and 16#FF#),
         U8 (Interfaces.Shift_Right (V, 8) and 16#FF#),
         U8 (Interfaces.Shift_Right (V, 16) and 16#FF#),
         U8 (Interfaces.Shift_Right (V, 24) and 16#FF#),
         U8 (Interfaces.Shift_Right (V, 32) and 16#FF#)];
   begin
      pragma Assert (Combine_U40LE (B) = (V and 16#FF_FFFF_FFFF#));
      Data (Pos .. Pos + 4) := B;
   end Poke_U40LE;

   ----------------
   -- Poke_U48BE --
   ----------------

   procedure Poke_U48BE (Data : in out Bytes; Pos : Array_Index; V : U64) is
      B : constant Bytes_6 :=
        [U8 (Interfaces.Shift_Right (V, 40) and 16#FF#),
         U8 (Interfaces.Shift_Right (V, 32) and 16#FF#),
         U8 (Interfaces.Shift_Right (V, 24) and 16#FF#),
         U8 (Interfaces.Shift_Right (V, 16) and 16#FF#),
         U8 (Interfaces.Shift_Right (V, 8) and 16#FF#),
         U8 (V and 16#FF#)];
   begin
      pragma Assert (Combine_U48BE (B) = (V and 16#FFFF_FFFF_FFFF#));
      Data (Pos .. Pos + 5) := B;
   end Poke_U48BE;

   ----------------
   -- Poke_U48LE --
   ----------------

   procedure Poke_U48LE (Data : in out Bytes; Pos : Array_Index; V : U64) is
      B : constant Bytes_6 :=
        [U8 (V and 16#FF#),
         U8 (Interfaces.Shift_Right (V, 8) and 16#FF#),
         U8 (Interfaces.Shift_Right (V, 16) and 16#FF#),
         U8 (Interfaces.Shift_Right (V, 24) and 16#FF#),
         U8 (Interfaces.Shift_Right (V, 32) and 16#FF#),
         U8 (Interfaces.Shift_Right (V, 40) and 16#FF#)];
   begin
      pragma Assert (Combine_U48LE (B) = (V and 16#FFFF_FFFF_FFFF#));
      Data (Pos .. Pos + 5) := B;
   end Poke_U48LE;

   ----------------
   -- Poke_U56BE --
   ----------------

   procedure Poke_U56BE (Data : in out Bytes; Pos : Array_Index; V : U64) is
      B : constant Bytes_7 :=
        [U8 (Interfaces.Shift_Right (V, 48) and 16#FF#),
         U8 (Interfaces.Shift_Right (V, 40) and 16#FF#),
         U8 (Interfaces.Shift_Right (V, 32) and 16#FF#),
         U8 (Interfaces.Shift_Right (V, 24) and 16#FF#),
         U8 (Interfaces.Shift_Right (V, 16) and 16#FF#),
         U8 (Interfaces.Shift_Right (V, 8) and 16#FF#),
         U8 (V and 16#FF#)];
   begin
      pragma Assert (Combine_U56BE (B) = (V and 16#FF_FFFF_FFFF_FFFF#));
      Data (Pos .. Pos + 6) := B;
   end Poke_U56BE;

   ----------------
   -- Poke_U56LE --
   ----------------

   procedure Poke_U56LE (Data : in out Bytes; Pos : Array_Index; V : U64) is
      B : constant Bytes_7 :=
        [U8 (V and 16#FF#),
         U8 (Interfaces.Shift_Right (V, 8) and 16#FF#),
         U8 (Interfaces.Shift_Right (V, 16) and 16#FF#),
         U8 (Interfaces.Shift_Right (V, 24) and 16#FF#),
         U8 (Interfaces.Shift_Right (V, 32) and 16#FF#),
         U8 (Interfaces.Shift_Right (V, 40) and 16#FF#),
         U8 (Interfaces.Shift_Right (V, 48) and 16#FF#)];
   begin
      pragma Assert (Combine_U56LE (B) = (V and 16#FF_FFFF_FFFF_FFFF#));
      Data (Pos .. Pos + 6) := B;
   end Poke_U56LE;

   ----------------
   -- Poke_U64BE --
   ----------------

   procedure Poke_U64BE (Data : in out Bytes; Pos : Array_Index; V : U64) is
      B : constant Bytes_8 :=
        [U8 (Interfaces.Shift_Right (V, 56) and 16#FF#),
         U8 (Interfaces.Shift_Right (V, 48) and 16#FF#),
         U8 (Interfaces.Shift_Right (V, 40) and 16#FF#),
         U8 (Interfaces.Shift_Right (V, 32) and 16#FF#),
         U8 (Interfaces.Shift_Right (V, 24) and 16#FF#),
         U8 (Interfaces.Shift_Right (V, 16) and 16#FF#),
         U8 (Interfaces.Shift_Right (V, 8) and 16#FF#),
         U8 (V and 16#FF#)];
   begin
      pragma Assert (Combine_U64BE (B) = V);
      Data (Pos .. Pos + 7) := B;
   end Poke_U64BE;

   ----------------
   -- Poke_U64LE --
   ----------------

   procedure Poke_U64LE (Data : in out Bytes; Pos : Array_Index; V : U64) is
      B : constant Bytes_8 :=
        [U8 (V and 16#FF#),
         U8 (Interfaces.Shift_Right (V, 8) and 16#FF#),
         U8 (Interfaces.Shift_Right (V, 16) and 16#FF#),
         U8 (Interfaces.Shift_Right (V, 24) and 16#FF#),
         U8 (Interfaces.Shift_Right (V, 32) and 16#FF#),
         U8 (Interfaces.Shift_Right (V, 40) and 16#FF#),
         U8 (Interfaces.Shift_Right (V, 48) and 16#FF#),
         U8 (Interfaces.Shift_Right (V, 56) and 16#FF#)];
   begin
      pragma Assert (Combine_U64LE (B) = V);
      Data (Pos .. Pos + 7) := B;
   end Poke_U64LE;

end Wuffs.Base.Endian;
