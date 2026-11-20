with Wuffs.Base.Pixel_Composite;

package body Wuffs.Base.Pixel_Buffers.Rows with SPARK_Mode is

   pragma Assertion_Policy (Ignore);

   use Wuffs.Base.Colors;
   use Wuffs.Base.Endian;
   use Wuffs.Base.Pixel_Composite;

   --  As the parent body's function of this name: the index of the palette
   --  entry nearest to C; 0 if PB has no palette.
   function Closest_In_Palette
     (PB      : Pixel_Buffer;
      Palette : Bytes;
      C       : Color_U32_ARGB_Premul) return U8
   is
     (if Has_Palette (PB)
      then Closest_Element
             (Palette (Palette'First .. Palette'First + (Palette_Byte_Length - 1)),
              PB.Pixcfg.Pixfmt, C)
      else 0)
   with
     Pre => (if Is_Indexed (PB.Pixcfg.Pixfmt)
             then Palette'Length >= Palette_Byte_Length);

   ------------------
   -- Row_Position --
   ------------------

   function Row_Position
     (PB : Pixel_Buffer; Pixels : Bytes; Y : U32; BPP : Pixel_Size) return Index
   is
      W   : constant Index := Index (PB.Pixcfg.Width);
      Row : Offset;
   begin
      pragma Assert (U64 (W) = U64 (PB.Pixcfg.Width));
      pragma Assert (U64 (BPP) = U64 (Bytes_Per_Pixel (PB.Pixcfg.Pixfmt)));
      pragma Assert (Row_Bytes (PB.Pixcfg) = U64 (W) * U64 (BPP));
      pragma Assert (W * BPP >= 1);
      pragma Assert (W * BPP <= PB.Planes (0).Width);
      pragma Assert (Has_Elements (PB.Planes (0)));
      Row := Row_Start (PB.Planes (0), Index (Y), Pixels'Length);
      return Pixels'First + Row;
   end Row_Position;

   -------------------------------
   -- Set_Color_U32_At_Position --
   -------------------------------

   procedure Set_Color_U32_At_Position
     (PB      : Pixel_Buffer;
      Pixels  : in out Bytes;
      Palette : Bytes;
      Pos     : Index;
      Color   : Colors.Color_U32_ARGB_Premul)
   is
      F : constant U32 := PB.Pixcfg.Pixfmt.Repr;
   begin
      case F is
         when Repr_BGRA_Premul | Repr_BGRX =>
            Poke_U32LE (Pixels, Pos, Color);
         when Repr_Y =>
            Poke_U8 (Pixels, Pos, Premul_U32_As_Gray_U8 (Color));
         when Repr_Y_16LE =>
            Poke_U16LE (Pixels, Pos, Premul_U32_As_Gray_U16 (Color));
         when Repr_Y_16BE =>
            Poke_U16BE (Pixels, Pos, Premul_U32_As_Gray_U16 (Color));
         when Repr_YA_Nonpremul =>
            Poke_U16LE (Pixels, Pos, Premul_U32_As_Alpha_Gray_Nonpremul_U16 (Color));
         when Repr_Indexed_BGRA_Nonpremul
            | Repr_Indexed_BGRA_Premul
            | Repr_Indexed_BGRA_Binary =>
            Poke_U8 (Pixels, Pos, Closest_In_Palette (PB, Palette, Color));
         when Repr_BGR_565 =>
            Poke_U16LE (Pixels, Pos, Premul_U32_As_RGB_565 (Color));
         when Repr_BGR =>
            Poke_U24LE (Pixels, Pos, Color);
         when Repr_BGRA_Nonpremul =>
            Poke_U32LE (Pixels, Pos, Premul_U32_As_Nonpremul_U32 (Color));
         when Repr_BGRA_Nonpremul_4x16LE =>
            Poke_U64LE (Pixels, Pos, Premul_U32_As_Nonpremul_U64 (Color));
         when Repr_RGB =>
            Poke_U24LE (Pixels, Pos, Swap_U32_ARGB_ABGR (Color));
         when Repr_RGBA_Nonpremul =>
            Poke_U32LE
              (Pixels, Pos, Premul_U32_As_Nonpremul_U32 (Swap_U32_ARGB_ABGR (Color)));
         when Repr_RGBA_Premul | Repr_RGBX =>
            Poke_U32LE (Pixels, Pos, Swap_U32_ARGB_ABGR (Color));
         when others =>
            --  Not a supported format: excluded by the precondition.
            pragma Assert (False);
      end case;
   end Set_Color_U32_At_Position;

   ----------------------------------------------
   -- Set_Color_U32_ARGB_Nonpremul_At_Position --
   ----------------------------------------------

   procedure Set_Color_U32_ARGB_Nonpremul_At_Position
     (PB      : Pixel_Buffer;
      Pixels  : in out Bytes;
      Palette : Bytes;
      Pos     : Index;
      Color   : Colors.Color_U32_ARGB_Nonpremul)
   is
      F      : constant U32 := PB.Pixcfg.Pixfmt.Repr;
      Premul : constant U32 := Nonpremul_U32_As_Premul_U32 (Color);
   begin
      case F is
         when Repr_BGRA_Premul | Repr_BGRX =>
            Poke_U32LE (Pixels, Pos, Premul);
         when Repr_Y =>
            Poke_U8 (Pixels, Pos, Premul_U32_As_Gray_U8 (Premul));
         when Repr_Y_16LE =>
            Poke_U16LE (Pixels, Pos, Premul_U32_As_Gray_U16 (Premul));
         when Repr_Y_16BE =>
            Poke_U16BE (Pixels, Pos, Premul_U32_As_Gray_U16 (Premul));
         when Repr_YA_Nonpremul =>
            Poke_U8 (Pixels, Pos, Premul_U32_As_Gray_U8 (Color or 16#FF00_0000#));
            Poke_U8 (Pixels, Pos + 1, U8 (Shift_Right (Color, 24)));
         when Repr_Indexed_BGRA_Nonpremul
            | Repr_Indexed_BGRA_Premul
            | Repr_Indexed_BGRA_Binary =>
            Poke_U8 (Pixels, Pos, Closest_In_Palette (PB, Palette, Premul));
         when Repr_BGR_565 =>
            Poke_U16LE (Pixels, Pos, Premul_U32_As_RGB_565 (Premul));
         when Repr_BGR =>
            Poke_U24LE (Pixels, Pos, Premul);
         when Repr_BGRA_Nonpremul =>
            Poke_U32LE (Pixels, Pos, Color);
         when Repr_BGRA_Nonpremul_4x16LE =>
            Poke_U64LE (Pixels, Pos, U32_As_U64 (Color));
         when Repr_RGB =>
            Poke_U24LE (Pixels, Pos, Swap_U32_ARGB_ABGR (Premul));
         when Repr_RGBA_Nonpremul =>
            Poke_U32LE (Pixels, Pos, Swap_U32_ARGB_ABGR (Color));
         when Repr_RGBA_Premul | Repr_RGBX =>
            Poke_U32LE (Pixels, Pos, Swap_U32_ARGB_ABGR (Premul));
         when others =>
            --  Not a supported format: excluded by the precondition.
            pragma Assert (False);
      end case;
   end Set_Color_U32_ARGB_Nonpremul_At_Position;

   -----------------------------------------------
   -- Composite_Color_U32_Nonpremul_At_Position --
   -----------------------------------------------

   procedure Composite_Color_U32_Nonpremul_At_Position
     (PB      : Pixel_Buffer;
      Pixels  : in out Bytes;
      Palette : Bytes;
      Pos     : Index;
      Color   : Colors.Color_U32_ARGB_Nonpremul)
   is
      F   : constant U32 := PB.Pixcfg.Pixfmt.Repr;
      E   : Index;
      D32 : U32;
      D64 : U64;
   begin
      case F is
         when Repr_BGRA_Premul =>
            Poke_U32LE
              (Pixels, Pos,
               Composite_Premul_Nonpremul_U32_Axxx (Peek_U32LE (Pixels, Pos), Color));
         when Repr_BGRX =>
            Poke_U32LE
              (Pixels, Pos,
               Composite_Premul_Nonpremul_U32_Axxx
                 (Peek_U32LE (Pixels, Pos) or 16#FF00_0000#, Color));
         when Repr_Y =>
            D32 := Composite_Premul_Nonpremul_U32_Axxx
              (16#FF00_0000# or (16#0001_0101# * U32 (Pixels (Pos))), Color);
            Pixels (Pos) := U8 (D32 and 16#FF#);
         when Repr_Y_16LE =>
            D64 := Composite_Premul_Nonpremul_U64_Axxx
              (16#FFFF_0000_0000_0000#
               or (16#0001_0001_0001# * U64 (Peek_U16LE (Pixels, Pos))),
               U32_As_U64 (Color));
            Poke_U16LE (Pixels, Pos, U16 (D64 and 16#FFFF#));
         when Repr_Y_16BE =>
            D64 := Composite_Premul_Nonpremul_U64_Axxx
              (16#FFFF_0000_0000_0000#
               or (16#0001_0001_0001# * U64 (Peek_U16BE (Pixels, Pos))),
               U32_As_U64 (Color));
            Poke_U16BE (Pixels, Pos, U16 (D64 and 16#FFFF#));
         when Repr_YA_Nonpremul =>
            D32 := Composite_Nonpremul_Nonpremul_U32_Axxx
              (Shift_Left (U32 (Pixels (Pos + 1)), 24)
               or (U32 (Pixels (Pos)) * 16#0001_0101#),
               Color);
            Pixels (Pos) := Premul_U32_As_Gray_U8 (D32 or 16#FF00_0000#);
            Pixels (Pos + 1) := U8 (Shift_Right (D32, 24));
         when Repr_Indexed_BGRA_Nonpremul
            | Repr_Indexed_BGRA_Premul
            | Repr_Indexed_BGRA_Binary =>
            if Has_Palette (PB) then
                  E := Palette'First + 4 * Index (Pixels (Pos));
               D32 := Peek_U32LE (Palette, E);
               if F = Repr_Indexed_BGRA_Nonpremul then
                  D32 := Nonpremul_U32_As_Premul_U32
                    (Composite_Nonpremul_Nonpremul_U32_Axxx (D32, Color));
               else
                  D32 := Composite_Premul_Nonpremul_U32_Axxx (D32, Color);
               end if;
               Pixels (Pos) := Closest_Element
                 (Palette (Palette'First .. Palette'First + (Palette_Byte_Length - 1)),
                  PB.Pixcfg.Pixfmt, D32);
            end if;
         when Repr_BGR_565 =>
            Poke_U16LE
              (Pixels, Pos,
               Premul_U32_As_RGB_565
                 (Composite_Premul_Nonpremul_U32_Axxx
                    (RGB_565_As_Premul_U32 (Peek_U16LE (Pixels, Pos)), Color)));
         when Repr_BGR =>
            Poke_U24LE
              (Pixels, Pos,
               Composite_Premul_Nonpremul_U32_Axxx
                 (16#FF00_0000# or Peek_U24LE (Pixels, Pos), Color));
         when Repr_BGRA_Nonpremul =>
            Poke_U32LE
              (Pixels, Pos,
               Composite_Nonpremul_Nonpremul_U32_Axxx (Peek_U32LE (Pixels, Pos), Color));
         when Repr_BGRA_Nonpremul_4x16LE =>
            Poke_U64LE
              (Pixels, Pos,
               Composite_Nonpremul_Nonpremul_U64_Axxx
                 (Peek_U64LE (Pixels, Pos), U32_As_U64 (Color)));
         when Repr_RGB =>
            Poke_U24LE
              (Pixels, Pos,
               Composite_Premul_Nonpremul_U32_Axxx
                 (16#FF00_0000# or Peek_U24LE (Pixels, Pos), Swap_U32_ARGB_ABGR (Color)));
         when Repr_RGBA_Nonpremul =>
            Poke_U32LE
              (Pixels, Pos,
               Composite_Nonpremul_Nonpremul_U32_Axxx
                 (Peek_U32LE (Pixels, Pos), Swap_U32_ARGB_ABGR (Color)));
         when Repr_RGBA_Premul =>
            Poke_U32LE
              (Pixels, Pos,
               Composite_Premul_Nonpremul_U32_Axxx
                 (Peek_U32LE (Pixels, Pos), Swap_U32_ARGB_ABGR (Color)));
         when Repr_RGBX =>
            Poke_U32LE
              (Pixels, Pos,
               Composite_Premul_Nonpremul_U32_Axxx
                 (Peek_U32LE (Pixels, Pos) or 16#FF00_0000#, Swap_U32_ARGB_ABGR (Color)));
         when others =>
            --  Not a supported format: excluded by the precondition.
            pragma Assert (False);
      end case;
   end Composite_Color_U32_Nonpremul_At_Position;

end Wuffs.Base.Pixel_Buffers.Rows;
