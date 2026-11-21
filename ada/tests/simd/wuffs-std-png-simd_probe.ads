--  Part of wuffada (wuffs-ada: Wuffs to Ada).
--  SPDX-License-Identifier: Apache-2.0 OR MIT

--  A test's view into which filter implementations the decoder selected
--  (see test_simd.adb).  Written by hand; only in a SIMD build.

package Wuffs.Std.Png.Simd_Probe is

   function Choice_Filter_1 (D : Decoder) return Wuffs.U8;
   function Choice_Filter_3 (D : Decoder) return Wuffs.U8;
   function Choice_Filter_4 (D : Decoder) return Wuffs.U8;

private

   function Choice_Filter_1 (D : Decoder) return Wuffs.U8 is (D.G_Choosy_Filter_1);
   function Choice_Filter_3 (D : Decoder) return Wuffs.U8 is (D.G_Choosy_Filter_3);
   function Choice_Filter_4 (D : Decoder) return Wuffs.U8 is (D.G_Choosy_Filter_4);

end Wuffs.Std.Png.Simd_Probe;
