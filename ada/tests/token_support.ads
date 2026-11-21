--  Library-level state for test_tokens: the decoders and the buffers, which
--  must not be on the stack (docs/DESIGN.md).

with Wuffs.Std.Cbor;
with Wuffs.Std.Json;

package Token_Support is

   Capacity : constant := 4 * 1024 * 1024;

   subtype Buffer is Wuffs.Bytes (0 .. 4_194_303);

   Input    : Buffer;  --  The file being decoded.
   Src_Work : Buffer;  --  The source I/O buffer.

   --  The token buffer, in tokens.
   Token_Capacity : constant := 4 * 1024 * 1024;
   Tok_Work : Wuffs.U64_Array (0 .. 4_194_303);

   --  The work buffer (both decoders want none).
   Workbuf : Wuffs.Bytes (1 .. 16);

   --  For the chaos runs: one piece of storage seen as tokens and as bytes
   --  (so that a token array and a source array can overlap), the bytes
   --  that the decoder has not read yet, and a work buffer.
   Chaos_Arena : aliased Wuffs.U64_Array (0 .. 8191) := [others => 0];
   Chaos_Bytes : Wuffs.Bytes (0 .. 65_535)
   with Import, Address => Chaos_Arena'Address;
   Chaos_Hold  : Wuffs.Bytes (0 .. 65_535);
   Chaos_Work  : Wuffs.Bytes (0 .. 63);

   --  test_tokens' manifest line and dump directory (not on the stack: the
   --  AddressSanitizer build's frames are larger).
   Line     : String (1 .. 4096);
   Dump_Dir : String (1 .. 1024);

   Json_Decoder : Wuffs.Std.Json.Decoder;
   Cbor_Decoder : Wuffs.Std.Cbor.Decoder;

end Token_Support;
