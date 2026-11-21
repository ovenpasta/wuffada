--  Part of wuffada (wuffs-ada: Wuffs to Ada).
--  SPDX-License-Identifier: Apache-2.0 OR MIT

--  A test's view into which implementation a choose statement selected
--  (see test_simd.adb).  Written by hand; only in a SIMD build, where the
--  selector component exists.

package Wuffs.Std.Crc32.Simd_Probe is

   --  0: the scalar (choosy) default; 1 .. : the alternatives, numbered in
   --  the order the generator first meets them (ada/gen/simd).
   function Choice_Up (D : Ieee_Hasher) return Wuffs.U8;

private

   function Choice_Up (D : Ieee_Hasher) return Wuffs.U8 is (D.G_Choosy_Up);

end Wuffs.Std.Crc32.Simd_Probe;
