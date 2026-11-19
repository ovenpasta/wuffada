--  Root package: the scalar and array types shared by the SPARK base library
--  (Wuffs.Base.*), the runtime glue (Wuffs.Runtime.*) and generated code
--  (Wuffs.Std.*).  Architect-owned: change only via docs/DESIGN.md.

with Interfaces;

package Wuffs with Pure, SPARK_Mode is

   --  Wuffs' u8/u16/u32/u64.  Modular, so `~mod+` is the native operator and
   --  shifts/bitwise operators are available.  Wuffs' checked `+` has already
   --  been proved not to overflow by the Wuffs compiler.
   subtype U8  is Interfaces.Unsigned_8;
   subtype U16 is Interfaces.Unsigned_16;
   subtype U32 is Interfaces.Unsigned_32;
   subtype U64 is Interfaces.Unsigned_64;

   --  Array indices and lengths.  Signed, so that out-of-range index
   --  arithmetic is an Ada overflow/range check rather than a silent wrap.
   --  Capped at 2**62 - 1 so that the sum of any two Index values fits in
   --  Offset, and so that the length of any array indexed by Index is at most
   --  2**62 (it fits in Offset, though not necessarily in Index).
   type Offset is range -(2 ** 63) .. 2 ** 63 - 1;
   subtype Index is Offset range 0 .. 2 ** 62 - 1;

   --  Wuffs' `slice T` / `array[N] T` storage.  Slices are passed to SPARK
   --  code as (sub)arrays of these types; bounds travel with the array.
   type Bytes     is array (Index range <>) of U8;
   type U16_Array is array (Index range <>) of U16;
   type U32_Array is array (Index range <>) of U32;
   type U64_Array is array (Index range <>) of U64;

   --  Wuffs' `status`.  A plain value (no pointers): Ok, or a category plus a
   --  code that is unique across packages.  Code = Package_Id * 2**16 + N,
   --  where Package_Id 0 is `base`; generated packages get their id from the
   --  generator.  Message text is looked up separately, never stored here.
   type Status_Category is (Ok, Note, Suspension, Error);
   type Status_Code is new U32;
   type Status is record
      Category : Status_Category := Ok;
      Code     : Status_Code     := 0;
   end record
     with Predicate => (Status.Category = Ok) = (Status.Code = 0);
   --  The predicate makes Ok unique: S = Ok_Status iff Is_Ok (S).

   Ok_Status : constant Status := (Category => Ok, Code => 0);

   function Is_Ok (S : Status) return Boolean is (S.Category = Ok);
   function Is_Error (S : Status) return Boolean is (S.Category = Error);
   function Is_Suspension (S : Status) return Boolean is (S.Category = Suspension);
   function Is_Note (S : Status) return Boolean is (S.Category = Note);

end Wuffs;
