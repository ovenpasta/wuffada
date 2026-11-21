--  Part of wuffada (wuffs-ada: Wuffs to Ada).
--  SPDX-License-Identifier: Apache-2.0 OR MIT

--  test_simd's decoders, at library level (never on the stack).

with Wuffs.Std.Adler32;
with Wuffs.Std.Crc32;
with Wuffs.Std.Crc64;
with Wuffs.Std.Deflate;
with Wuffs.Std.Jpeg;
with Wuffs.Std.Png;

package Simd_Test_Objects is

   Adler : Wuffs.Std.Adler32.Hasher;
   Crc   : Wuffs.Std.Crc32.Ieee_Hasher;
   Crc64 : Wuffs.Std.Crc64.Ecma_Hasher;
   Png   : Wuffs.Std.Png.Decoder;
   Jpeg  : Wuffs.Std.Jpeg.Decoder;
   Defl  : Wuffs.Std.Deflate.Decoder;

end Simd_Test_Objects;
