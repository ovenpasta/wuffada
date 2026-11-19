--  Colour values and the conversions between them.
--
--  C: the wuffs_base__color_* inline functions of
--  wuffs/internal/cgen/base/image-public.h.  Every function here is the C
--  function of the matching name, operation for operation: the arithmetic
--  is unsigned 32 or 64 bit and wraps exactly as in C (for example when a
--  "premultiplied" input has a colour channel larger than its alpha).
--
--  Representations (all plain numbers, no arrays):
--
--    U32 ARGB    0xAARRGGBB, 8 bits per channel.
--    U64 ARGB    0xAAAARRRRGGGGBBBB, 16 bits per channel.
--    premul      colour channels already multiplied by alpha.
--    nonpremul   colour channels not multiplied by alpha.
--    RGB 565     0bRRRRRGGGGGGBBBBB in a U16.
--    gray        one luma channel, U8 or U16.
--    alpha gray  0xAAYY in a U16, nonpremul.
--
--  Not here: the YCbCr conversions (wuffs_base__color_ycc_*), which belong
--  to the YCCK swizzler of a later milestone.

package Wuffs.Base.Colors with Pure, SPARK_Mode is

   pragma Assertion_Policy (Post => Ignore);

   use Interfaces;

   subtype Color_U32_ARGB_Premul is U32;
   subtype Color_U32_ARGB_Nonpremul is U32;

   --  Channel K (0 = blue .. 3 = alpha) of a U32 ARGB colour, and channel
   --  K of a U64 ARGB colour.
   function Ch8 (C : U32; Shift : Natural) return U32 is
     (16#FF# and Shift_Right (C, Shift));
   function Ch16 (C : U64; Shift : Natural) return U64 is
     (16#FFFF# and Shift_Right (C, Shift));
   function Ch16_32 (C : U64; Shift : Natural) return U32 is
     (U32 (16#FFFF# and Shift_Right (C, Shift)));

   --  The luma of three 16 bit channels, as a 32 bit fixed point value:
   --  the result's top 8 bits are an 8 bit gray, its top 16 a 16 bit gray.
   function Weighted_Average (R16, G16, B16 : U32) return U32 is
     (19595 * R16 + 38470 * G16 + 7471 * B16 + 32768);

   --  C: wuffs_base__color_u32_argb_premul__is_valid.
   function Premul_Is_Valid (C : Color_U32_ARGB_Premul) return Boolean is
     (Ch8 (C, 24) >= Ch8 (C, 16)
      and then Ch8 (C, 24) >= Ch8 (C, 8)
      and then Ch8 (C, 24) >= Ch8 (C, 0));

   --  C: wuffs_base__color_u32_argb_premul__as__color_u16_rgb_565.
   function Premul_U32_As_RGB_565 (C : Color_U32_ARGB_Premul) return U16 is
     (U16 ((16#F800# and Shift_Right (C, 8))
           or (16#07E0# and Shift_Right (C, 5))
           or (16#001F# and Shift_Right (C, 3))));

   --  C: wuffs_base__color_u16_rgb_565__as__color_u32_argb_premul.
   function RGB_565_As_Premul_U32 (RGB_565 : U16) return Color_U32_ARGB_Premul is
     (declare
        B5 : constant U32 := 16#1F# and U32 (RGB_565);
        G6 : constant U32 := 16#3F# and Shift_Right (U32 (RGB_565), 5);
        R5 : constant U32 := 16#1F# and Shift_Right (U32 (RGB_565), 11);
        B  : constant U32 := Shift_Left (B5, 3) or Shift_Right (B5, 2);
        G  : constant U32 := Shift_Left (G6, 2) or Shift_Right (G6, 4);
        R  : constant U32 := Shift_Left (R5, 3) or Shift_Right (R5, 2);
      begin
        16#FF00_0000# or Shift_Left (R, 16) or Shift_Left (G, 8) or B);

   --  C: wuffs_base__color_u32_argb_premul__as__color_u8_gray.
   function Premul_U32_As_Gray_U8 (C : Color_U32_ARGB_Premul) return U8 is
     (U8 (Shift_Right
            (Weighted_Average
               (16#101# * Ch8 (C, 16), 16#101# * Ch8 (C, 8), 16#101# * Ch8 (C, 0)),
             24)));

   --  C: wuffs_base__color_u32_argb_premul__as__color_u16_gray.
   function Premul_U32_As_Gray_U16 (C : Color_U32_ARGB_Premul) return U16 is
     (U16 (Shift_Right
             (Weighted_Average
                (16#101# * Ch8 (C, 16), 16#101# * Ch8 (C, 8), 16#101# * Ch8 (C, 0)),
              16)));

   --  C: wuffs_base__color_u32_argb_premul__as__color_u16_alpha_gray_nonpremul.
   function Premul_U32_As_Alpha_Gray_Nonpremul_U16
     (C : Color_U32_ARGB_Premul) return U16
   is
     (if Ch8 (C, 24) = 0 then 0
      else
        (declare
           A16 : constant U32 := Ch8 (C, 24) * 16#101#;
           CR  : constant U32 := (Ch8 (C, 16) * (16#101# * 16#FFFF#)) / A16;
           CG  : constant U32 := (Ch8 (C, 8) * (16#101# * 16#FFFF#)) / A16;
           CB  : constant U32 := (Ch8 (C, 0) * (16#101# * 16#FFFF#)) / A16;
         begin
           U16 ((A16 and 16#FF00#)
                or Shift_Right (Weighted_Average (CR, CG, CB), 24))));

   --  C: wuffs_base__color_u32_argb_nonpremul__as__color_u32_argb_premul.
   function Nonpremul_U32_As_Premul_U32
     (C : Color_U32_ARGB_Nonpremul) return Color_U32_ARGB_Premul
   is
     (declare
        A   : constant U32 := Ch8 (C, 24);
        A16 : constant U32 := A * (16#101# * 16#101#);
        R   : constant U32 := Shift_Right ((Ch8 (C, 16) * A16) / 16#FFFF#, 8);
        G   : constant U32 := Shift_Right ((Ch8 (C, 8) * A16) / 16#FFFF#, 8);
        B   : constant U32 := Shift_Right ((Ch8 (C, 0) * A16) / 16#FFFF#, 8);
      begin
        Shift_Left (A, 24) or Shift_Left (R, 16) or Shift_Left (G, 8) or B);

   --  C: wuffs_base__color_u32_argb_premul__as__color_u32_argb_nonpremul.
   function Premul_U32_As_Nonpremul_U32
     (C : Color_U32_ARGB_Premul) return Color_U32_ARGB_Nonpremul
   is
     (if Ch8 (C, 24) = 16#FF# then C
      elsif Ch8 (C, 24) = 0 then 0
      else
        (declare
           A   : constant U32 := Ch8 (C, 24);
           A16 : constant U32 := A * 16#101#;
           R   : constant U32 :=
             Shift_Right ((Ch8 (C, 16) * (16#101# * 16#FFFF#)) / A16, 8);
           G   : constant U32 :=
             Shift_Right ((Ch8 (C, 8) * (16#101# * 16#FFFF#)) / A16, 8);
           B   : constant U32 :=
             Shift_Right ((Ch8 (C, 0) * (16#101# * 16#FFFF#)) / A16, 8);
         begin
           Shift_Left (A, 24) or Shift_Left (R, 16) or Shift_Left (G, 8) or B));

   --  C: wuffs_base__color_u64_argb_nonpremul__as__color_u32_argb_premul.
   function Nonpremul_U64_As_Premul_U32 (C : U64) return Color_U32_ARGB_Premul is
     (declare
        A16 : constant U32 := Ch16_32 (C, 48);
        R16 : constant U32 := (Ch16_32 (C, 32) * A16) / 16#FFFF#;
        G16 : constant U32 := (Ch16_32 (C, 16) * A16) / 16#FFFF#;
        B16 : constant U32 := (Ch16_32 (C, 0) * A16) / 16#FFFF#;
      begin
        Shift_Left (Shift_Right (A16, 8), 24)
        or Shift_Left (Shift_Right (R16, 8), 16)
        or Shift_Left (Shift_Right (G16, 8), 8)
        or Shift_Right (B16, 8));

   --  C: wuffs_base__color_u32_argb_premul__as__color_u64_argb_nonpremul.
   function Premul_U32_As_Nonpremul_U64 (C : Color_U32_ARGB_Premul) return U64 is
     (if Ch8 (C, 24) = 16#FF# then
        16#FFFF_0000_0000_0000#
        or Shift_Left (U64 (16#101# * Ch8 (C, 16)), 32)
        or Shift_Left (U64 (16#101# * Ch8 (C, 8)), 16)
        or U64 (16#101# * Ch8 (C, 0))
      elsif Ch8 (C, 24) = 0 then 0
      else
        (declare
           A16 : constant U64 := U64 (Ch8 (C, 24) * 16#101#);
           R16 : constant U64 := (U64 (Ch8 (C, 16)) * (16#101# * 16#FFFF#)) / A16;
           G16 : constant U64 := (U64 (Ch8 (C, 8)) * (16#101# * 16#FFFF#)) / A16;
           B16 : constant U64 := (U64 (Ch8 (C, 0)) * (16#101# * 16#FFFF#)) / A16;
         begin
           Shift_Left (A16, 48) or Shift_Left (R16, 32) or Shift_Left (G16, 16) or B16));

   --  C: wuffs_base__color_u64_argb_premul__as__color_u8_gray.
   function Premul_U64_As_Gray_U8 (C : U64) return U8 is
     (U8 (Shift_Right
            (Weighted_Average (Ch16_32 (C, 32), Ch16_32 (C, 16), Ch16_32 (C, 0)), 24)));

   --  C: wuffs_base__color_u64_argb_premul__as__color_u64_argb_nonpremul.
   function Premul_U64_As_Nonpremul_U64 (C : U64) return U64 is
     (if Ch16 (C, 48) = 16#FFFF# then C
      elsif Ch16 (C, 48) = 0 then 0
      else
        (declare
           A : constant U64 := Ch16 (C, 48);
           R : constant U64 := (Ch16 (C, 32) * 16#FFFF#) / A;
           G : constant U64 := (Ch16 (C, 16) * 16#FFFF#) / A;
           B : constant U64 := (Ch16 (C, 0) * 16#FFFF#) / A;
         begin
           Shift_Left (A, 48) or Shift_Left (R, 32) or Shift_Left (G, 16) or B));

   --  C: wuffs_base__color_u64_argb_nonpremul__as__color_u64_argb_premul.
   function Nonpremul_U64_As_Premul_U64 (C : U64) return U64 is
     (declare
        A : constant U64 := Ch16 (C, 48);
        R : constant U64 := (Ch16 (C, 32) * A) / 16#FFFF#;
        G : constant U64 := (Ch16 (C, 16) * A) / 16#FFFF#;
        B : constant U64 := (Ch16 (C, 0) * A) / 16#FFFF#;
      begin
        Shift_Left (A, 48) or Shift_Left (R, 32) or Shift_Left (G, 16) or B);

   --  C: wuffs_base__color_u64_argb_nonpremul__as__color_u8_gray.
   function Nonpremul_U64_As_Gray_U8 (C : U64) return U8 is
     (declare
        A16 : constant U32 := Ch16_32 (C, 48);
        R16 : constant U32 := (Ch16_32 (C, 32) * A16) / 16#FFFF#;
        G16 : constant U32 := (Ch16_32 (C, 16) * A16) / 16#FFFF#;
        B16 : constant U32 := (Ch16_32 (C, 0) * A16) / 16#FFFF#;
      begin
        U8 (Shift_Right (Weighted_Average (R16, G16, B16), 24)));

   --  C: wuffs_base__color_u32__as__color_u64.  Each 8 bit channel 0xXY
   --  becomes the 16 bit channel 0xXYXY.
   function U32_As_U64 (C : U32) return U64 is
     (Shift_Left (U64 (16#101# * Ch8 (C, 24)), 48)
      or Shift_Left (U64 (16#101# * Ch8 (C, 16)), 32)
      or Shift_Left (U64 (16#101# * Ch8 (C, 8)), 16)
      or U64 (16#101# * Ch8 (C, 0)));

   --  C: wuffs_base__color_u64__as__color_u32.  The high byte of each
   --  16 bit channel.
   function U64_As_U32 (C : U64) return U32 is
     (Shift_Left (U32 (16#FF# and Shift_Right (C, 56)), 24)
      or Shift_Left (U32 (16#FF# and Shift_Right (C, 40)), 16)
      or Shift_Left (U32 (16#FF# and Shift_Right (C, 24)), 8)
      or U32 (16#FF# and Shift_Right (C, 8)));

   --  C: wuffs_base__color_swap_u32_argb_abgr, ..._u64_argb_abgr.  Swap
   --  the red and blue channels.
   function Swap_U32_ARGB_ABGR (U : U32) return U32 is
     ((U and 16#FF00_FF00#)
      or Shift_Right (U and 16#00FF_0000#, 16)
      or Shift_Left (U and 16#0000_00FF#, 16));

   function Swap_U64_ARGB_ABGR (U : U64) return U64 is
     ((U and 16#FFFF_0000_FFFF_0000#)
      or Shift_Right (U and 16#0000_FFFF_0000_0000#, 32)
      or Shift_Left (U and 16#0000_0000_0000_FFFF#, 32));

end Wuffs.Base.Colors;
