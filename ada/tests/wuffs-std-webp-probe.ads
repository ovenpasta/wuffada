--  Part of wuffada (wuffs-ada: Wuffs to Ada).
--  SPDX-License-Identifier: Apache-2.0 OR MIT

--  A test's view into the decoder's private state (see test_hostile.adb and
--  test_entry.adb).  Written by hand: ./gen.sh leaves this file alone.

with System;
with Wuffs.Base.Pixel_Swizzler;
with Wuffs.Std.Vp8.Probe;

package Wuffs.Std.Webp.Probe is

   --  True if D's pixel swizzler, and that of the std/vp8 decoder inside
   --  it, are the default ones, which convert nothing.
   function Swizzler_Is_Default (D : Decoder) return Boolean;

   --  Where the std/vp8 decoder inside D is, and its size in bits.
   function Vp8_Address (D : Decoder) return System.Address;
   function Vp8_Size (D : Decoder) return Long_Long_Integer;

private

   use type Wuffs.Base.Pixel_Swizzler.Swizzler;

   function Swizzler_Is_Default (D : Decoder) return Boolean
   is (D.F_Swizzler = Wuffs.Base.Pixel_Swizzler.Swizzler'(others => <>)
       and then Wuffs.Std.Vp8.Probe.Swizzler_Is_Default (D.F_Vp8));

   function Vp8_Address (D : Decoder) return System.Address is (D.F_Vp8'Address);

   function Vp8_Size (D : Decoder) return Long_Long_Integer is (D.F_Vp8'Size);

end Wuffs.Std.Webp.Probe;
