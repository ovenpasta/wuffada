--  YCbCr to RGB colour conversion.
--
--  C: wuffs_base__color_ycc_bt601fr__as__color_u32 (and ..._abgr) and
--  wuffs_base__color_ycc_bt601sr__as__color_u32 (and ..._abgr) in
--  wuffs/internal/cgen/base/image-public.h; the unsuffixed C names
--  wuffs_base__color_ycc__as__color_u32[_abgr] are macros for the bt601fr
--  pair.  "fr" is BT.601 full range (JPEG), "sr" is studio range (WebP,
--  video).  Each takes one 8 bit Y, Cb, Cr sample and returns an opaque
--  0xFFRRGGBB colour (or 0xFFBBGGRR for the Abgr forms).  Plain numbers;
--  no arrays.
--
--  The full range conversion is C's unsigned 32 bit fixed point
--  arithmetic, wrap for wrap.  The studio range conversion is C's signed
--  arithmetic; every intermediate value fits in 32 bits (proved here as
--  absence of overflow).

package Wuffs.Base.Color_YCC with Pure, SPARK_Mode is

   pragma Assertion_Policy (Post => Ignore);

   use Interfaces;

   --  One channel of the full range conversion: a 32 bit fixed point value
   --  with the result in bits 16 .. 23, saturated to 0 or 16#FF# in those
   --  bits if it is negative or too large.  (C: `if (v >> 24) v = ~((uint32_t)
   --  (((int32_t)v) >> 31));`.)
   function Saturate_FR (V : U32) return U32 is
     (if Shift_Right (V, 24) = 0 then V
      elsif (V and 16#8000_0000#) /= 0 then 0
      else 16#FFFF_FFFF#);

   function FR_Y (YY : U8) return U32 is (Shift_Left (U32 (YY), 16) or 16#8000#);
   function FR_C (C : U8) return U32 is (U32 (C) - 16#80#);

   function FR_Red (YY, Cr : U8) return U32 is
     (16#00FF_0000# and Saturate_FR (FR_Y (YY) + 16#1_66E9# * FR_C (Cr)));
   function FR_Green (YY, Cb, Cr : U8) return U32 is
     (16#00FF_0000#
      and Saturate_FR
            (FR_Y (YY) - 16#0_581A# * FR_C (Cb) - 16#0_B6D2# * FR_C (Cr)));
   function FR_Blue (YY, Cb : U8) return U32 is
     (16#00FF_0000# and Saturate_FR (FR_Y (YY) + 16#1_C5A2# * FR_C (Cb)));

   --  C: wuffs_base__color_ycc_bt601fr__as__color_u32.
   function YCC_BT601FR_As_Color_U32 (YY, Cb, Cr : U8) return U32 is
     (16#FF00_0000#
      or FR_Red (YY, Cr)
      or Shift_Right (FR_Green (YY, Cb, Cr), 8)
      or Shift_Right (FR_Blue (YY, Cb), 16));

   --  C: wuffs_base__color_ycc_bt601fr__as__color_u32_abgr.
   function YCC_BT601FR_As_Color_U32_ABGR (YY, Cb, Cr : U8) return U32 is
     (16#FF00_0000#
      or FR_Blue (YY, Cb)
      or Shift_Right (FR_Green (YY, Cb, Cr), 8)
      or Shift_Right (FR_Red (YY, Cr), 16));

   --  One channel of the studio range conversion: a signed fixed point
   --  value with 6 fraction bits, clamped to 0 .. 255.
   function Clamp_SR (V : Integer) return U32 is
     (if V < 0 then 0 elsif V > 16320 then 255 else U32 (V / 64))
   with Post => Clamp_SR'Result <= 255;

   function SR_Red (YY, Cr : U8) return U32 is
     (Clamp_SR (Integer (YY) * 19077 / 256 + Integer (Cr) * 26149 / 256 - 14234));
   function SR_Green (YY, Cb, Cr : U8) return U32 is
     (Clamp_SR
        (Integer (YY) * 19077 / 256 - Integer (Cb) * 6419 / 256
         - Integer (Cr) * 13320 / 256 + 8708));
   function SR_Blue (YY, Cb : U8) return U32 is
     (Clamp_SR (Integer (YY) * 19077 / 256 + Integer (Cb) * 33050 / 256 - 17685));

   --  C: wuffs_base__color_ycc_bt601sr__as__color_u32.
   function YCC_BT601SR_As_Color_U32 (YY, Cb, Cr : U8) return U32 is
     (16#FF00_0000#
      or Shift_Left (SR_Red (YY, Cr), 16)
      or Shift_Left (SR_Green (YY, Cb, Cr), 8)
      or SR_Blue (YY, Cb));

   --  C: wuffs_base__color_ycc_bt601sr__as__color_u32_abgr.
   function YCC_BT601SR_As_Color_U32_ABGR (YY, Cb, Cr : U8) return U32 is
     (16#FF00_0000#
      or Shift_Left (SR_Blue (YY, Cb), 16)
      or Shift_Left (SR_Green (YY, Cb, Cr), 8)
      or SR_Red (YY, Cr));

end Wuffs.Base.Color_YCC;
