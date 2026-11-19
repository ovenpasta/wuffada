package body Wuffs.Base.Pixel_Formats with SPARK_Mode is

   pragma Assertion_Policy (Ignore);

   ---------
   -- Set --
   ---------

   procedure Set
     (C           : out Pixel_Config;
      Pixfmt_Repr : U32;
      Pixsub_Repr : U32;
      Width       : U32;
      Height      : U32)
   is
   begin
      if Pixfmt_Repr /= 0 then
         C := (Pixfmt => (Repr => Pixfmt_Repr),
               Pixsub => (Repr => Pixsub_Repr),
               Width  => Width,
               Height => Height);
      else
         C := Null_Pixel_Config;
      end if;
   end Set;

   procedure Set
     (C                       : out Image_Config;
      Pixfmt_Repr             : U32;
      Pixsub_Repr             : U32;
      Width                   : U32;
      Height                  : U32;
      First_Frame_IO_Position : U64;
      First_Frame_Is_Opaque   : Boolean)
   is
   begin
      if Pixfmt_Repr /= 0 then
         C := (Pixcfg => (Pixfmt => (Repr => Pixfmt_Repr),
                          Pixsub => (Repr => Pixsub_Repr),
                          Width  => Width,
                          Height => Height),
               First_Frame_IO_Position => First_Frame_IO_Position,
               First_Frame_Is_Opaque   => First_Frame_Is_Opaque);
      else
         C := Null_Image_Config;
      end if;
   end Set;

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
   is
   begin
      C := (Bounds                     => Bounds,
            Duration                   => Duration,
            Index                      => Index,
            IO_Position                => IO_Position,
            Disposal                   => Disposal,
            Opaque_Within_Bounds       => Opaque_Within_Bounds,
            Overwrite_Instead_Of_Blend => Overwrite_Instead_Of_Blend,
            Background_Color           => Background_Color);
   end Set;

   ----------------
   -- Invalidate --
   ----------------

   procedure Invalidate (C : out Pixel_Config) is
   begin
      C := Null_Pixel_Config;
   end Invalidate;

   procedure Invalidate (C : out Image_Config) is
   begin
      C := Null_Image_Config;
   end Invalidate;

end Wuffs.Base.Pixel_Formats;
