--  TEMPORARY.  Stand-ins for what the SPARK-proved base library (Wuffs.Base.*)
--  will provide.  Generated code refers to this package by a single generator
--  setting (`wuffs-ada gen -base_package`), so that it can be swapped for the
--  proved one.  Each declaration names the C entity that it mirrors.

package Wuffs.Runtime.Temp_Base with Preelaborate, SPARK_Mode => Off is

   use type Wuffs.U8;
   use type Wuffs.U16;
   use type Wuffs.U32;
   use type Wuffs.U64;

   ---------------------------------------------------------------------------
   --  Base statuses.  The Ada name is the category followed by the mangled
   --  message; Code is the 1-based position of the status in the Wuffs
   --  compiler's lang/builtin.Statuses list (package id 0).
   ---------------------------------------------------------------------------

   --  C: wuffs_base__error__bad_argument
   Error_Bad_Argument : constant Wuffs.Status := (Wuffs.Error, 13);

   --  C: wuffs_base__error__bad_receiver
   Error_Bad_Receiver : constant Wuffs.Status := (Wuffs.Error, 16);

   --  C: wuffs_base__error__disabled_by_previous_error
   Error_Disabled_By_Previous_Error : constant Wuffs.Status := (Wuffs.Error, 24);

   --  C: wuffs_base__error__initialize_not_called
   Error_Initialize_Not_Called : constant Wuffs.Status := (Wuffs.Error, 26);

   --  C: wuffs_base__error__unsupported_option
   Error_Unsupported_Option : constant Wuffs.Status := (Wuffs.Error, 34);

   ---------------------------------------------------------------------------
   --  Saturating arithmetic (Wuffs `~sat+` and `~sat-`).
   ---------------------------------------------------------------------------

   --  C: wuffs_base__u8__sat_add
   function Sat_Add_U8 (X, Y : Wuffs.U8) return Wuffs.U8
   is (if X + Y < X then Wuffs.U8'Last else X + Y);

   --  C: wuffs_base__u8__sat_sub
   function Sat_Sub_U8 (X, Y : Wuffs.U8) return Wuffs.U8 is (if X < Y then 0 else X - Y);

   --  C: wuffs_base__u16__sat_add
   function Sat_Add_U16 (X, Y : Wuffs.U16) return Wuffs.U16
   is (if X + Y < X then Wuffs.U16'Last else X + Y);

   --  C: wuffs_base__u16__sat_sub
   function Sat_Sub_U16 (X, Y : Wuffs.U16) return Wuffs.U16 is (if X < Y then 0 else X - Y);

   --  C: wuffs_base__u32__sat_add
   function Sat_Add_U32 (X, Y : Wuffs.U32) return Wuffs.U32
   is (if X + Y < X then Wuffs.U32'Last else X + Y);

   --  C: wuffs_base__u32__sat_sub
   function Sat_Sub_U32 (X, Y : Wuffs.U32) return Wuffs.U32 is (if X < Y then 0 else X - Y);

   --  C: wuffs_base__u64__sat_add
   function Sat_Add_U64 (X, Y : Wuffs.U64) return Wuffs.U64
   is (if X + Y < X then Wuffs.U64'Last else X + Y);

   --  C: wuffs_base__u64__sat_sub
   function Sat_Sub_U64 (X, Y : Wuffs.U64) return Wuffs.U64 is (if X < Y then 0 else X - Y);

   ---------------------------------------------------------------------------
   --  Iterate loops.
   ---------------------------------------------------------------------------

   --  C: wuffs_private_impl__iterate_total_advance
   function Iterate_Total_Advance
     (Total_Len : Wuffs.Index; Iter_Len : Wuffs.Index; Iter_Advance : Wuffs.Index)
      return Wuffs.Index
   is (if Total_Len >= Iter_Len
       then ((Total_Len - Iter_Len) / Iter_Advance) * Iter_Advance + Iter_Advance
       else 0)
   with Pre => Iter_Advance in 1 .. Iter_Len;

end Wuffs.Runtime.Temp_Base;
