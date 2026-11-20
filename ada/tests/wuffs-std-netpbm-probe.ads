--  Part of wuffada (wuffs-ada: Wuffs to Ada).
--  SPDX-License-Identifier: Apache-2.0 OR MIT

--  A test's view into the decoder's private state (see test_hostile.adb).
--  Written by hand: ./gen.sh leaves this file alone.

with Wuffs.Base.Pixel_Swizzler;

package Wuffs.Std.Netpbm.Probe is

   --  True if D's pixel swizzler is the default one, which converts nothing.
   function Swizzler_Is_Default (D : Decoder) return Boolean;

private

   use type Wuffs.Base.Pixel_Swizzler.Swizzler;

   function Swizzler_Is_Default (D : Decoder) return Boolean
   is (D.F_Swizzler = Wuffs.Base.Pixel_Swizzler.Swizzler'(others => <>));

end Wuffs.Std.Netpbm.Probe;
