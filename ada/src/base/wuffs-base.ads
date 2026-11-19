--  Wuffs.Base: the hand-written, SPARK-proved replacement for Wuffs' C base
--  library (wuffs/internal/cgen/base).  See docs/DESIGN.md.
--
--  This parent package holds the base package's status values and their
--  messages.  The children are:
--
--    Wuffs.Base.Ints    integer helpers (min/max, saturating, bit fields)
--    Wuffs.Base.Endian  peek/poke of u8 .. u64, little and big endian
--    Wuffs.Base.Slices  slice helpers (copies, prefix/suffix, bulk ops)
--    Wuffs.Base.IO      io_reader / io_writer primitives
--    Wuffs.Base.Ranges  range_ie/ii u32/u64, rect_ie/ii u32
--
--  Assertion policy, in every unit of the library: preconditions follow the
--  build profile (executed in the `checked` profile, as the second net under
--  generated code; not in `release`).  Postconditions, loop invariants and
--  the other proof-only assertions are never executed: GNATprove proves
--  them, many are quantified over whole arrays (linear cost per call), and
--  evaluating X'Old for an array would copy it onto the stack.

package Wuffs.Base with Pure, SPARK_Mode is

   pragma Assertion_Policy (Post => Ignore);

   --  Three names for Wuffs.Index, used in parameter declarations across
   --  the library to say which of the two addressing conventions (or a
   --  plain count) a parameter follows.  They are subtypes without
   --  constraints: documentation that travels with the signature, not a
   --  check.
   --
   --    Array_Index    an Ada index: the element is Data (I).
   --    First_Offset   a count from the start of the array: the element is
   --                   Data (Data'First + K).  This is what C pointer
   --                   differences and Wuffs marks are.
   --    Element_Count  a number of elements.
   --
   --  Wuffs.Base.Endian and Wuffs.Base.Slices take Array_Index positions.
   --  Wuffs.Base.IO works in First_Offset throughout (Buffer_Meta, Reader
   --  and Writer fields and every position parameter).
   subtype Array_Index is Index;
   subtype First_Offset is Index;
   subtype Element_Count is Index;

   --  Package_Id of `base` in Wuffs.Status_Code (see Wuffs.Status).
   Package_Id : constant := 0;

   --  The base statuses, in the order of the Statuses list in
   --  wuffs/lang/builtin/builtin.go.  Code = Package_Id * 2**16 + position
   --  in that list, counted from 1.  Codes are stable: new statuses are
   --  appended upstream within their category, so a re-sync must keep the
   --  numbers below and give new entries fresh numbers.
   Num_Statuses : constant := 36;

   Note_IO_Redirect : constant Status :=
     (Category => Note, Code => 1);
   --  "base: I/O redirect"

   Note_End_Of_Data : constant Status :=
     (Category => Note, Code => 2);
   --  "base: end of data"

   Note_Metadata_Reported : constant Status :=
     (Category => Note, Code => 3);
   --  "base: metadata reported"

   Suspension_Even_More_Information : constant Status :=
     (Category => Suspension, Code => 4);
   --  "base: even more information"

   Suspension_Mispositioned_Read : constant Status :=
     (Category => Suspension, Code => 5);
   --  "base: mispositioned read"

   Suspension_Mispositioned_Write : constant Status :=
     (Category => Suspension, Code => 6);
   --  "base: mispositioned write"

   Suspension_Short_Read : constant Status :=
     (Category => Suspension, Code => 7);
   --  "base: short read"

   Suspension_Short_Workbuf : constant Status :=
     (Category => Suspension, Code => 8);
   --  "base: short workbuf"

   Suspension_Short_Write : constant Status :=
     (Category => Suspension, Code => 9);
   --  "base: short write"

   Error_Bad_IO_Position : constant Status :=
     (Category => Error, Code => 10);
   --  "base: bad I/O position"

   Error_Bad_Argument_Length_Too_Long : constant Status :=
     (Category => Error, Code => 11);
   --  "base: bad argument (length too long)"

   Error_Bad_Argument_Length_Too_Short : constant Status :=
     (Category => Error, Code => 12);
   --  "base: bad argument (length too short)"

   Error_Bad_Argument : constant Status :=
     (Category => Error, Code => 13);
   --  "base: bad argument"

   Error_Bad_Call_Sequence : constant Status :=
     (Category => Error, Code => 14);
   --  "base: bad call sequence"

   Error_Bad_Data : constant Status :=
     (Category => Error, Code => 15);
   --  "base: bad data"

   Error_Bad_Receiver : constant Status :=
     (Category => Error, Code => 16);
   --  "base: bad receiver"

   Error_Bad_Restart : constant Status :=
     (Category => Error, Code => 17);
   --  "base: bad restart"

   Error_Bad_Sizeof_Receiver : constant Status :=
     (Category => Error, Code => 18);
   --  "base: bad sizeof receiver"

   Error_Bad_Vtable : constant Status :=
     (Category => Error, Code => 19);
   --  "base: bad vtable"

   Error_Bad_Workbuf_Length : constant Status :=
     (Category => Error, Code => 20);
   --  "base: bad workbuf length"

   Error_Bad_Wuffs_Version : constant Status :=
     (Category => Error, Code => 21);
   --  "base: bad wuffs version"

   Error_Cannot_Return_A_Suspension : constant Status :=
     (Category => Error, Code => 22);
   --  "base: cannot return a suspension"

   Error_Disabled_By_Dst_Pixel_Format_Enable_Allowlist : constant Status :=
     (Category => Error, Code => 23);
   --  "base: disabled by WUFFS_CONFIG__DST_PIXEL_FORMAT__ENABLE_ALLOWLIST"

   Error_Disabled_By_Previous_Error : constant Status :=
     (Category => Error, Code => 24);
   --  "base: disabled by previous error"

   Error_Initialize_Falsely_Claimed_Already_Zeroed : constant Status :=
     (Category => Error, Code => 25);
   --  "base: initialize falsely claimed already zeroed"

   Error_Initialize_Not_Called : constant Status :=
     (Category => Error, Code => 26);
   --  "base: initialize not called"

   Error_Insufficient_History : constant Status :=
     (Category => Error, Code => 27);
   --  "base: insufficient history"

   Error_Interleaved_Coroutine_Calls : constant Status :=
     (Category => Error, Code => 28);
   --  "base: interleaved coroutine calls"

   Error_No_More_Information : constant Status :=
     (Category => Error, Code => 29);
   --  "base: no more information"

   Error_Not_Enough_Data : constant Status :=
     (Category => Error, Code => 30);
   --  "base: not enough data"

   Error_Out_Of_Bounds : constant Status :=
     (Category => Error, Code => 31);
   --  "base: out of bounds"

   Error_Unsupported_Image_Dimension : constant Status :=
     (Category => Error, Code => 32);
   --  "base: unsupported image dimension"

   Error_Unsupported_Method : constant Status :=
     (Category => Error, Code => 33);
   --  "base: unsupported method"

   Error_Unsupported_Option : constant Status :=
     (Category => Error, Code => 34);
   --  "base: unsupported option"

   Error_Unsupported_Pixel_Swizzler_Option : constant Status :=
     (Category => Error, Code => 35);
   --  "base: unsupported pixel swizzler option"

   Error_Too_Much_Data : constant Status :=
     (Category => Error, Code => 36);
   --  "base: too much data"

   --  True if S is one of the constants above (category and code).
   function Is_Base_Status (S : Status) return Boolean;

   --  C: wuffs_base__status__is_complete.  Ok or a note.
   function Is_Complete (S : Status) return Boolean is
     (S.Category in Ok | Note);

   --  C: wuffs_private_impl__status__ensure_not_a_suspension.
   function Ensure_Not_A_Suspension (S : Status) return Status is
     (if S.Category = Suspension then Error_Cannot_Return_A_Suspension else S);

   --------------
   -- Messages --
   --------------

   --  The message of a base status is the C string without its leading
   --  '@', '$' or '#' (what wuffs_base__status__message returns), for
   --  example "base: bad data".  The lookup writes into a caller-provided
   --  buffer rather than returning a String, so it needs neither the
   --  secondary stack nor a bounded-string type in every client; a buffer
   --  of Max_Message_Length characters always fits the whole message.

   Max_Message_Length : constant := 72;

   --  Zero unless Is_Base_Status (S); in particular zero for Ok_Status and
   --  for statuses of other packages.
   function Message_Length (S : Status) return Natural with
     Post => Message_Length'Result <= Max_Message_Length
       and then (Message_Length'Result > 0) = Is_Base_Status (S);

   --  Copies the first Length characters of the message of S to the start
   --  of Buffer, where Length is the message length or Buffer'Length if
   --  that is smaller, and sets the rest of Buffer to spaces.
   procedure Get_Message (S : Status; Buffer : out String; Length : out Natural) with
     Post => Length = Integer'Min (Message_Length (S), Buffer'Length)
       and then (for all I in Buffer'Range =>
                   (if I - Buffer'First >= Length then Buffer (I) = ' '));

end Wuffs.Base;
