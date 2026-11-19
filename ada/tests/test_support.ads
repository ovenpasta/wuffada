--  Library-level storage and reporting for the test drivers.  The project's
--  configuration pragmas (no secondary stack, no allocators) and its stack
--  limit apply to tests too, so file contents live here, not on the stack.

with Wuffs;

package Test_Support is

   Buffer_Size : constant := 16 * 1024 * 1024;

   Buffer_Last : constant := Buffer_Size - 1;

   Buffer : Wuffs.Bytes (0 .. Buffer_Last);

   Checks   : Natural := 0;
   Failures : Natural := 0;

   --  Each Check counts a check and, if it fails, reports a failure that is
   --  described by What, then (if not negative) N, then Detail.  The
   --  description comes in parts so that callers need not concatenate
   --  strings (whose stack usage the project's -Wstack-usage limit cannot
   --  bound).
   procedure Check (OK : Boolean; What : String; N : Integer := -1; Detail : String := "");

   procedure Check_U32
     (Got, Want : Wuffs.U32; What : String; N : Integer := -1; Detail : String := "");

   procedure Check_U64
     (Got, Want : Wuffs.U64; What : String; N : Integer := -1; Detail : String := "");

   --  Whether this program was built with the "checked" profile (run-time
   --  checks and assertions on) rather than "release".
   function Checks_Enabled return Boolean;

   --  Returns X, in a way that the compiler cannot see through.
   function Opaque (X : Integer) return Integer
   with No_Inline;

   --  Prints the trace line "= What N HEX" (Value as 16 hexadecimal digits),
   --  for comparison with another implementation's trace.
   procedure Trace (What : String; N : Integer; Value : Wuffs.U64);

   --  Writes X as 8 hexadecimal digits to standard output.
   procedure Put_Hex (X : Wuffs.U32);

   --  Prints a summary and sets the process' exit status.
   procedure Finish (Name : String);

end Test_Support;
