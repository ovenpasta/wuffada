--  Library-level state for test_decode: the decoders and the buffers.  The
--  decoders are big (deflate's is about 43 KiB, zlib's and gzip's contain
--  one) and must not be on the stack: see docs/DESIGN.md.

with Wuffs.Std.Bzip2;
with Wuffs.Std.Deflate;
with Wuffs.Std.Gzip;
with Wuffs.Std.Lzip;
with Wuffs.Std.Lzma;
with Wuffs.Std.Lzw;
with Wuffs.Std.Xz;
with Wuffs.Std.Zlib;

package Decode_Support is

   Capacity : constant := 4 * 1024 * 1024;

   Last : constant := Capacity - 1;

   subtype Buffer is Wuffs.Bytes (0 .. Last);

   Input    : Buffer;  --  The compressed file.
   Expected : Buffer;  --  The expected output, if there is one.
   Src_Work : Buffer;  --  The source I/O buffer.
   Dst_Work : Buffer;  --  The destination I/O buffer.
   --  The work buffer of a call is as long as the decoder says it wants,
   --  within these bounds (lzma wants its dictionary size and a little more).
   Work_Capacity : constant := 40 * 1024 * 1024;
   Workbuf       : Wuffs.Bytes (1 .. Work_Capacity);

   --  A preset dictionary for zlib, at an index other than 0.
   Dictionary : Wuffs.Bytes (100 .. 1099);

   Lzw_Decoder     : Wuffs.Std.Lzw.Decoder;
   Deflate_Decoder : Wuffs.Std.Deflate.Decoder;
   Zlib_Decoder    : Wuffs.Std.Zlib.Decoder;
   Gzip_Decoder    : Wuffs.Std.Gzip.Decoder;
   Bzip2_Decoder   : Wuffs.Std.Bzip2.Decoder;
   Lzma_Decoder    : Wuffs.Std.Lzma.Decoder;
   Lzip_Decoder    : Wuffs.Std.Lzip.Decoder;
   Xz_Decoder      : Wuffs.Std.Xz.Decoder;

end Decode_Support;
