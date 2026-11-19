--  Library-level state for test_adv.

with Wuffs.Std.Advtest;

package Adv_Support is

   Length  : constant := 48;
   Out_Cap : constant := 4096;

   --  None of the arrays that the coroutines see starts at index 0, and no
   --  two start at the same index.
   Input_First   : constant := 1000;
   Output_First  : constant := 5;
   Workbuf_First : constant := 3;

   Input   : Wuffs.Bytes (1000 .. 1047);
   Output  : Wuffs.Bytes (5 .. 4100);
   Workbuf : Wuffs.Bytes (3 .. 10);

   Thing : Wuffs.Std.Advtest.Thing;

end Adv_Support;
