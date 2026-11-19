--  Pixel formats, subsampling, blend modes, and the plain-data configs:
--  Pixel_Config, Image_Config, Frame_Config.
--
--  C: wuffs/internal/cgen/base/image-public.h.  See also
--  wuffs/doc/note/pixel-formats.md and pixel-subsampling.md.  Everything
--  here is a value type and an expression function or a small procedure;
--  no arrays, so no index convention.
--
--  Wuffs method                           Ada
--  -------------------------------------  -------------------------------
--  utility.make_pixel_format(repr)        Make_Pixel_Format (Repr)
--  f.bits_per_pixel()                     Bits_Per_Pixel (F)
--  f.default_background_color()           Default_Background_Color (F)
--  utility.make_pixel_blend(repr)         Make_Pixel_Blend (Repr)
--  utility.demake_pixel_blend(b)          Demake_Pixel_Blend (B)
--  image_config.set!(...)                 Set (C : in out Image_Config, ...)
--  frame_config.set!(...)                 Set (C : in out Frame_Config, ...)
--  frame_config.disposal() etc.           Disposal (C), Get_Duration (C),
--                                         Get_Index (C), IO_Position (C)
--
--  The remaining functions are the C API (is_valid, is_indexed,
--  pixbuf_len, bounds, ...).
--
--  Differences from C, all forced by C's use of pointers:
--    * The C functions accept a NULL config and answer as for an invalid
--      one; here a config always exists.
--    * wuffs_base__pixel_config__set on a 32 bit machine invalidates the
--      config if width * height exceeds SIZE_MAX.  This port behaves as
--      the 64 bit C does: any width and height are stored.
--    * builtin.go lists frame_config.blend(), which upstream's C does not
--      implement; it is not here either.

with Wuffs.Base.Ranges;

package Wuffs.Base.Pixel_Formats with Pure, SPARK_Mode is

   pragma Assertion_Policy (Post => Ignore);

   use Interfaces;

   ------------------
   -- Pixel_Format --
   ------------------

   type Pixel_Format is record
      Repr : U32 := 0;
   end record;

   function Make_Pixel_Format (Repr : U32) return Pixel_Format is (Repr => Repr);

   --  The format numbers themselves (C: WUFFS_BASE__PIXEL_FORMAT__*), for
   --  use where a static value is needed, such as a case statement.
   Repr_Invalid                : constant U32 := 16#0000_0000#;
   Repr_A                      : constant U32 := 16#0200_0008#;
   Repr_Y                      : constant U32 := 16#2000_0008#;
   Repr_Y_16LE                 : constant U32 := 16#2000_000B#;
   Repr_Y_16BE                 : constant U32 := 16#2010_000B#;
   Repr_YA_Nonpremul           : constant U32 := 16#2100_0088#;
   Repr_YA_Premul              : constant U32 := 16#2200_0088#;
   Repr_YXXX                   : constant U32 := 16#3000_8888#;
   Repr_YCbCr                  : constant U32 := 16#4002_0888#;
   Repr_YCbCrA_Nonpremul       : constant U32 := 16#4103_8888#;
   Repr_YCbCrK                 : constant U32 := 16#5003_8888#;
   Repr_YCoCg                  : constant U32 := 16#6002_0888#;
   Repr_YCoCgA_Nonpremul       : constant U32 := 16#6103_8888#;
   Repr_YCoCgK                 : constant U32 := 16#7003_8888#;
   Repr_Indexed_BGRA_Nonpremul : constant U32 := 16#8104_0008#;
   Repr_Indexed_BGRA_Premul    : constant U32 := 16#8204_0008#;
   Repr_Indexed_BGRA_Binary    : constant U32 := 16#8304_0008#;
   Repr_BGR_565                : constant U32 := 16#8000_0565#;
   Repr_BGR                    : constant U32 := 16#8000_0888#;
   Repr_BGRA_Nonpremul         : constant U32 := 16#8100_8888#;
   Repr_BGRA_Nonpremul_4x16LE  : constant U32 := 16#8100_BBBB#;
   Repr_BGRA_Premul            : constant U32 := 16#8200_8888#;
   Repr_BGRA_Premul_4x16LE     : constant U32 := 16#8200_BBBB#;
   Repr_BGRA_Binary            : constant U32 := 16#8300_8888#;
   Repr_BGRX                   : constant U32 := 16#9000_8888#;
   Repr_RGB                    : constant U32 := 16#A000_0888#;
   Repr_RGBA_Nonpremul         : constant U32 := 16#A100_8888#;
   Repr_RGBA_Nonpremul_4x16LE  : constant U32 := 16#A100_BBBB#;
   Repr_RGBA_Premul            : constant U32 := 16#A200_8888#;
   Repr_RGBA_Premul_4x16LE     : constant U32 := 16#A200_BBBB#;
   Repr_RGBA_Binary            : constant U32 := 16#A300_8888#;
   Repr_RGBX                   : constant U32 := 16#B000_8888#;
   Repr_CMY                    : constant U32 := 16#C002_0888#;
   Repr_CMYK                   : constant U32 := 16#D003_8888#;

   Invalid                : constant Pixel_Format := (Repr => Repr_Invalid);
   A                      : constant Pixel_Format := (Repr => Repr_A);
   Y                      : constant Pixel_Format := (Repr => Repr_Y);
   Y_16LE                 : constant Pixel_Format := (Repr => Repr_Y_16LE);
   Y_16BE                 : constant Pixel_Format := (Repr => Repr_Y_16BE);
   YA_Nonpremul           : constant Pixel_Format := (Repr => Repr_YA_Nonpremul);
   YA_Premul              : constant Pixel_Format := (Repr => Repr_YA_Premul);
   YXXX                   : constant Pixel_Format := (Repr => Repr_YXXX);
   YCbCr                  : constant Pixel_Format := (Repr => Repr_YCbCr);
   YCbCrA_Nonpremul       : constant Pixel_Format := (Repr => Repr_YCbCrA_Nonpremul);
   YCbCrK                 : constant Pixel_Format := (Repr => Repr_YCbCrK);
   YCoCg                  : constant Pixel_Format := (Repr => Repr_YCoCg);
   YCoCgA_Nonpremul       : constant Pixel_Format := (Repr => Repr_YCoCgA_Nonpremul);
   YCoCgK                 : constant Pixel_Format := (Repr => Repr_YCoCgK);
   Indexed_BGRA_Nonpremul : constant Pixel_Format := (Repr => Repr_Indexed_BGRA_Nonpremul);
   Indexed_BGRA_Premul    : constant Pixel_Format := (Repr => Repr_Indexed_BGRA_Premul);
   Indexed_BGRA_Binary    : constant Pixel_Format := (Repr => Repr_Indexed_BGRA_Binary);
   BGR_565                : constant Pixel_Format := (Repr => Repr_BGR_565);
   BGR                    : constant Pixel_Format := (Repr => Repr_BGR);
   BGRA_Nonpremul         : constant Pixel_Format := (Repr => Repr_BGRA_Nonpremul);
   BGRA_Nonpremul_4x16LE  : constant Pixel_Format := (Repr => Repr_BGRA_Nonpremul_4x16LE);
   BGRA_Premul            : constant Pixel_Format := (Repr => Repr_BGRA_Premul);
   BGRA_Premul_4x16LE     : constant Pixel_Format := (Repr => Repr_BGRA_Premul_4x16LE);
   BGRA_Binary            : constant Pixel_Format := (Repr => Repr_BGRA_Binary);
   BGRX                   : constant Pixel_Format := (Repr => Repr_BGRX);
   RGB                    : constant Pixel_Format := (Repr => Repr_RGB);
   RGBA_Nonpremul         : constant Pixel_Format := (Repr => Repr_RGBA_Nonpremul);
   RGBA_Nonpremul_4x16LE  : constant Pixel_Format := (Repr => Repr_RGBA_Nonpremul_4x16LE);
   RGBA_Premul            : constant Pixel_Format := (Repr => Repr_RGBA_Premul);
   RGBA_Premul_4x16LE     : constant Pixel_Format := (Repr => Repr_RGBA_Premul_4x16LE);
   RGBA_Binary            : constant Pixel_Format := (Repr => Repr_RGBA_Binary);
   RGBX                   : constant Pixel_Format := (Repr => Repr_RGBX);
   CMY                    : constant Pixel_Format := (Repr => Repr_CMY);
   CMYK                   : constant Pixel_Format := (Repr => Repr_CMYK);

   Num_Planes_Max        : constant := 4;
   Indexed_Index_Plane   : constant := 0;
   Indexed_Color_Plane   : constant := 3;
   Palette_Byte_Length   : constant := 1024;

   --  C: WUFFS_BASE__IMAGE__DIMENSION_MAX_INCL.
   Image_Dimension_Max_Incl : constant := 16#FF_FFFF#;

   --  C: wuffs_private_impl__pixel_format__bits_per_channel.
   Bits_Per_Channel : constant array (U32 range 0 .. 15) of U32 :=
     [16#00#, 16#01#, 16#02#, 16#03#, 16#04#, 16#05#, 16#06#, 16#07#,
      16#08#, 16#0A#, 16#0C#, 16#10#, 16#18#, 16#20#, 16#30#, 16#40#];

   function Is_Valid (F : Pixel_Format) return Boolean is (F.Repr /= 0);

   function Is_Direct (F : Pixel_Format) return Boolean is
     ((Shift_Right (F.Repr, 18) and 1) = 0);

   function Is_Indexed (F : Pixel_Format) return Boolean is
     ((Shift_Right (F.Repr, 18) and 1) /= 0);

   function Is_Interleaved (F : Pixel_Format) return Boolean is
     ((Shift_Right (F.Repr, 16) and 3) = 0);

   function Is_Planar (F : Pixel_Format) return Boolean is
     ((Shift_Right (F.Repr, 16) and 3) /= 0);

   --  Zero for planar formats; otherwise the sum over the four channels,
   --  at most 256.
   function Bits_Per_Pixel (F : Pixel_Format) return U32 is
     (if Is_Planar (F) then 0
      else Bits_Per_Channel (F.Repr and 16#F#)
           + Bits_Per_Channel (Shift_Right (F.Repr, 4) and 16#F#)
           + Bits_Per_Channel (Shift_Right (F.Repr, 8) and 16#F#)
           + Bits_Per_Channel (Shift_Right (F.Repr, 12) and 16#F#))
   with Post => Bits_Per_Pixel'Result <= 256;

   --  Opaque black if the format has no alpha, else transparent black.
   function Default_Background_Color (F : Pixel_Format) return U32 is
     (if (F.Repr and 16#0300_0000#) = 0 then 16#FF00_0000# else 0);

   function Num_Planes (F : Pixel_Format) return U32 is
     ((Shift_Right (F.Repr, 16) and 3) + 1)
   with Post => Num_Planes'Result in 1 .. 4;

   --  C: wuffs_base__pixel_alpha_transparency.
   subtype Pixel_Alpha_Transparency is U32 range 0 .. 3;
   Opaque               : constant Pixel_Alpha_Transparency := 0;
   Nonpremultiplied_Alpha : constant Pixel_Alpha_Transparency := 1;
   Premultiplied_Alpha  : constant Pixel_Alpha_Transparency := 2;
   Binary_Alpha         : constant Pixel_Alpha_Transparency := 3;

   function Transparency (F : Pixel_Format) return Pixel_Alpha_Transparency is
     (Shift_Right (F.Repr, 24) and 3);

   --  C: wuffs_base__pixel_coloration.  0 none, 1 gray, 3 rich.
   subtype Pixel_Coloration is U32 range 0 .. 3;
   Coloration_None : constant Pixel_Coloration := 0;
   Coloration_Gray : constant Pixel_Coloration := 1;
   Coloration_Rich : constant Pixel_Coloration := 3;

   function Coloration (F : Pixel_Format) return Pixel_Coloration is
     (if Shift_Right (F.Repr, 29) <= 1 then Shift_Right (F.Repr, 29) else 3);

   -----------------
   -- Pixel_Blend --
   -----------------

   --  C: wuffs_base__pixel_blend, a uint8_t.  Any value can be made; the
   --  swizzler accepts only the two named ones.
   type Pixel_Blend is new U8;
   Blend_Src      : constant Pixel_Blend := 0;
   Blend_Src_Over : constant Pixel_Blend := 1;

   function Make_Pixel_Blend (Repr : U8) return Pixel_Blend is (Pixel_Blend (Repr));
   function Demake_Pixel_Blend (B : Pixel_Blend) return U8 is (U8 (B));

   -----------------------
   -- Pixel_Subsampling --
   -----------------------

   type Pixel_Subsampling is record
      Repr : U32 := 0;
   end record;

   function Make_Pixel_Subsampling (Repr : U32) return Pixel_Subsampling is
     (Repr => Repr);

   Subsampling_None : constant Pixel_Subsampling := (Repr => 16#00_0000#);
   Subsampling_444  : constant Pixel_Subsampling := (Repr => 16#00_0000#);
   Subsampling_440  : constant Pixel_Subsampling := (Repr => 16#01_0100#);
   Subsampling_422  : constant Pixel_Subsampling := (Repr => 16#10_1000#);
   Subsampling_420  : constant Pixel_Subsampling := (Repr => 16#11_1100#);
   Subsampling_411  : constant Pixel_Subsampling := (Repr => 16#30_3000#);
   Subsampling_410  : constant Pixel_Subsampling := (Repr => 16#31_3100#);

   --  As in C, only the low two bits of Plane are used.
   function Bias_X (S : Pixel_Subsampling; Plane : U32) return U32 is
     (Shift_Right (S.Repr, Natural ((Plane and 3) * 8 + 6)) and 3);
   function Denominator_X (S : Pixel_Subsampling; Plane : U32) return U32 is
     ((Shift_Right (S.Repr, Natural ((Plane and 3) * 8 + 4)) and 3) + 1);
   function Bias_Y (S : Pixel_Subsampling; Plane : U32) return U32 is
     (Shift_Right (S.Repr, Natural ((Plane and 3) * 8 + 2)) and 3);
   function Denominator_Y (S : Pixel_Subsampling; Plane : U32) return U32 is
     ((Shift_Right (S.Repr, Natural ((Plane and 3) * 8)) and 3) + 1);

   ------------------
   -- Pixel_Config --
   ------------------

   --  C: wuffs_base__pixel_config.  The default value is the null (invalid)
   --  config.  Use Set; a config with an invalid format is all zeroes.
   type Pixel_Config is record
      Pixfmt : Pixel_Format;
      Pixsub : Pixel_Subsampling;
      Width  : U32 := 0;
      Height : U32 := 0;
   end record;

   Null_Pixel_Config : constant Pixel_Config :=
     (Pixfmt => (Repr => 0), Pixsub => (Repr => 0), Width => 0, Height => 0);

   --  Stores the four values, or invalidates C if Pixfmt_Repr is zero.
   procedure Set
     (C           : out Pixel_Config;
      Pixfmt_Repr : U32;
      Pixsub_Repr : U32;
      Width       : U32;
      Height      : U32)
   with
     Post => C = (if Pixfmt_Repr /= 0
                  then (Pixfmt => (Repr => Pixfmt_Repr),
                        Pixsub => (Repr => Pixsub_Repr),
                        Width  => Width,
                        Height => Height)
                  else Null_Pixel_Config);

   procedure Invalidate (C : out Pixel_Config) with
     Post => C = Null_Pixel_Config;

   function Is_Valid (C : Pixel_Config) return Boolean is (C.Pixfmt.Repr /= 0);
   function Get_Pixel_Format (C : Pixel_Config) return Pixel_Format is (C.Pixfmt);
   function Get_Pixel_Subsampling (C : Pixel_Config) return Pixel_Subsampling is
     (C.Pixsub);
   function Width (C : Pixel_Config) return U32 is (C.Width);
   function Height (C : Pixel_Config) return U32 is (C.Height);

   function Bounds (C : Pixel_Config) return Ranges.Rect_IE_U32 is
     (Min_Incl_X => 0, Min_Incl_Y => 0, Max_Excl_X => C.Width, Max_Excl_Y => C.Height);

   --  Bytes per pixel of an interleaved format whose bits per pixel are a
   --  non-zero multiple of 8; zero for any other format.  (Not a C
   --  function: it is the test that pixbuf_len and the pixel buffer
   --  setters each spell out.)
   function Bytes_Per_Pixel (F : Pixel_Format) return U32 is
     (if Bits_Per_Pixel (F) mod 8 = 0 then Bits_Per_Pixel (F) / 8 else 0)
   with Post => Bytes_Per_Pixel'Result <= 32;

   --  C: wuffs_base__pixel_config__pixbuf_len.  The number of bytes a
   --  pixel buffer for C needs, including the 1024 byte palette of an
   --  indexed format; zero if the format is planar or not a whole number
   --  of bytes per pixel, or if the size does not fit in 64 bits.
   function Pixbuf_Len (C : Pixel_Config) return U64 is
     (declare
        BPP : constant U64 := U64 (Bytes_Per_Pixel (C.Pixfmt));
        N   : constant U64 := U64 (C.Width) * U64 (C.Height);
      begin
        (if BPP = 0 or else N > U64'Last / BPP then 0
         elsif not Is_Indexed (C.Pixfmt) then N * BPP
         elsif N * BPP > U64'Last - Palette_Byte_Length then 0
         else N * BPP + Palette_Byte_Length));

   ------------------
   -- Image_Config --
   ------------------

   --  C: wuffs_base__image_config.
   type Image_Config is record
      Pixcfg                  : Pixel_Config;
      First_Frame_IO_Position : U64 := 0;
      First_Frame_Is_Opaque   : Boolean := False;
   end record;

   Null_Image_Config : constant Image_Config :=
     (Pixcfg                  =>
        (Pixfmt => (Repr => 0), Pixsub => (Repr => 0), Width => 0, Height => 0),
      First_Frame_IO_Position => 0,
      First_Frame_Is_Opaque   => False);

   --  Stores the values, or invalidates C if Pixfmt_Repr is zero.
   procedure Set
     (C                       : out Image_Config;
      Pixfmt_Repr             : U32;
      Pixsub_Repr             : U32;
      Width                   : U32;
      Height                  : U32;
      First_Frame_IO_Position : U64;
      First_Frame_Is_Opaque   : Boolean)
   with
     Post => C = (if Pixfmt_Repr /= 0
                  then (Pixcfg => (Pixfmt => (Repr => Pixfmt_Repr),
                                   Pixsub => (Repr => Pixsub_Repr),
                                   Width  => Width,
                                   Height => Height),
                        First_Frame_IO_Position => First_Frame_IO_Position,
                        First_Frame_Is_Opaque   => First_Frame_Is_Opaque)
                  else Null_Image_Config);

   procedure Invalidate (C : out Image_Config) with
     Post => C = Null_Image_Config;

   function Is_Valid (C : Image_Config) return Boolean is (Is_Valid (C.Pixcfg));
   function First_Frame_IO_Position (C : Image_Config) return U64 is
     (C.First_Frame_IO_Position);
   function First_Frame_Is_Opaque (C : Image_Config) return Boolean is
     (C.First_Frame_Is_Opaque);

   ------------------
   -- Frame_Config --
   ------------------

   --  C: wuffs_base__animation_disposal.
   type Animation_Disposal is new U8;
   Disposal_None               : constant Animation_Disposal := 0;
   Disposal_Restore_Background : constant Animation_Disposal := 1;
   Disposal_Restore_Previous   : constant Animation_Disposal := 2;

   --  C: wuffs_base__flicks, an int64_t count of 1 / 705_600_000 seconds.
   --  Wuffs code can only set a duration in 0 .. 2**63 - 1.
   subtype Flicks is U64 range 0 .. 16#7FFF_FFFF_FFFF_FFFF#;
   Flicks_Per_Second      : constant := 705_600_000;
   Flicks_Per_Millisecond : constant := 705_600;

   --  C: wuffs_base__frame_config.
   type Frame_Config is record
      Bounds                     : Ranges.Rect_IE_U32;
      Duration                   : Flicks := 0;
      Index                      : U64 := 0;
      IO_Position                : U64 := 0;
      Disposal                   : Animation_Disposal := Disposal_None;
      Opaque_Within_Bounds       : Boolean := False;
      Overwrite_Instead_Of_Blend : Boolean := False;
      Background_Color           : U32 := 0;
   end record;

   procedure Set
     (C                          : out Frame_Config;
      Bounds                     : Ranges.Rect_IE_U32;
      Duration                   : Flicks;
      Index                      : U64;
      IO_Position                : U64;
      Disposal                   : Animation_Disposal;
      Opaque_Within_Bounds       : Boolean;
      Overwrite_Instead_Of_Blend : Boolean;
      Background_Color           : U32)
   with
     Post => C = (Bounds                     => Bounds,
                  Duration                   => Duration,
                  Index                      => Index,
                  IO_Position                => IO_Position,
                  Disposal                   => Disposal,
                  Opaque_Within_Bounds       => Opaque_Within_Bounds,
                  Overwrite_Instead_Of_Blend => Overwrite_Instead_Of_Blend,
                  Background_Color           => Background_Color);

   function Bounds (C : Frame_Config) return Ranges.Rect_IE_U32 is (C.Bounds);
   function Width (C : Frame_Config) return U32 is (Ranges.Width (C.Bounds));
   function Height (C : Frame_Config) return U32 is (Ranges.Height (C.Bounds));
   --  (Get_ because a function named Duration or Index would hide
   --  Standard.Duration and Wuffs.Index for clients with use clauses.)
   function Get_Duration (C : Frame_Config) return Flicks is (C.Duration);
   function Get_Index (C : Frame_Config) return U64 is (C.Index);
   function IO_Position (C : Frame_Config) return U64 is (C.IO_Position);
   function Disposal (C : Frame_Config) return Animation_Disposal is (C.Disposal);
   function Opaque_Within_Bounds (C : Frame_Config) return Boolean is
     (C.Opaque_Within_Bounds);
   function Overwrite_Instead_Of_Blend (C : Frame_Config) return Boolean is
     (C.Overwrite_Instead_Of_Blend);
   function Background_Color (C : Frame_Config) return U32 is (C.Background_Color);

end Wuffs.Base.Pixel_Formats;
