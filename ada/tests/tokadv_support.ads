--  Library-level state for test_tokadv (the token buffer is too big for the
--  stack, and decoder records are never declared locally: docs/DESIGN.md).

with Wuffs.Std.Tokadv;

package Tokadv_Support is

   Tokens : Wuffs.U64_Array (100 .. 4195);

   Thing : Wuffs.Std.Tokadv.Thing;

end Tokadv_Support;
