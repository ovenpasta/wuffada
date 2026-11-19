with Wuffs.Base.Endian;

package body Wuffs.Base.Pixel_Buffers with SPARK_Mode is

   pragma Assertion_Policy (Ignore);

   use Wuffs.Base.Colors;
   use Wuffs.Base.Endian;

   subtype Pixel_Size is Index range 1 .. 8;

   --  Offset from Pixels'First of the first byte of pixel (X, Y), for a
   --  format of BPP bytes per pixel.  The BPP bytes from there exist.
   function Pixel_Start
     (PB            : Pixel_Buffer;
      Pixels_Length : Array_Length;
      X, Y          : U32;
      BPP           : Pixel_Size) return Offset
   with
     Pre  => Fits (PB.Planes (0), Pixels_Length)
       and then Row_Bytes (PB.Pixcfg) <= U64 (PB.Planes (0).Width)
       and then Index (PB.Pixcfg.Height) <= PB.Planes (0).Height
       and then X < PB.Pixcfg.Width
       and then Y < PB.Pixcfg.Height
       and then U32 (BPP) = Bytes_Per_Pixel (PB.Pixcfg.Pixfmt),
     Post => Pixel_Start'Result >= 0
       and then Pixel_Start'Result <= Pixels_Length - BPP;

   --  If A whole Bs fit in C, then A is at most C / B.
   procedure Lemma_Div_Lower (A, B, C : Offset) with
     Ghost,
     Pre  => A >= 0 and then B > 0 and then C >= 0
       and then A <= Offset'Last / B
       and then A * B <= C,
     Post => A <= C / B;

   --  If H rows of Row elements fit in Avail elements, then one row fits
   --  and H - 1 rows fit in what is left after one row.
   procedure Lemma_Rows_Fit (H, Row, Avail : Offset) with
     Ghost,
     Pre  => H >= 1 and then Row >= 1 and then Avail >= 0 and then H <= Avail / Row,
     Post => Row <= Avail and then H - 1 <= (Avail - Row) / Row;

   --  Row_Bytes as an Index.
   function Row_Width (C : Pixel_Config) return Index with
     Post => U64 (Row_Width'Result) = Row_Bytes (C);

   --  The palette slice that C passes to closest_element: the first 1024
   --  bytes if PB has a palette, else nothing.
   function Closest_In_Palette
     (PB      : Pixel_Buffer;
      Palette : Bytes;
      C       : Color_U32_ARGB_Premul) return U8
   with Pre => (if Is_Indexed (PB.Pixcfg.Pixfmt) then Palette'Length >= Palette_Byte_Length);

   ---------------------
   -- Lemma_Div_Lower --
   ---------------------

   procedure Lemma_Div_Lower (A, B, C : Offset) is
      Q : constant Offset := C / B;
   begin
      if A > Q then
         pragma Assert (A >= Q + 1);
         pragma Assert ((Q + 1) * B <= A * B);
         pragma Assert ((Q + 1) * B = Q * B + B);
         pragma Assert (C - Q * B < B);
         pragma Assert (False);
      end if;
   end Lemma_Div_Lower;

   --------------------
   -- Lemma_Rows_Fit --
   --------------------

   procedure Lemma_Rows_Fit (H, Row, Avail : Offset) is
      Q : constant Offset := Avail / Row;
   begin
      pragma Assert (Q * Row <= Avail);
      pragma Assert (H * Row <= Q * Row);
      pragma Assert (Row <= H * Row);
      pragma Assert ((H - 1) * Row = H * Row - Row);
      pragma Assert ((H - 1) * Row <= Avail - Row);
      Lemma_Div_Lower (H - 1, Row, Avail - Row);
   end Lemma_Rows_Fit;

   ---------------
   -- Row_Width --
   ---------------

   function Row_Width (C : Pixel_Config) return Index is
      W   : constant Index := Index (C.Width);
      BPP : constant Index := Index (Bytes_Per_Pixel (C.Pixfmt));
   begin
      return W * BPP;
   end Row_Width;

   ---------------
   -- Row_Start --
   ---------------

   function Row_Start (T : Table; Y : Index; Length : Array_Length) return Offset is
   begin
      if Y = 0 or else T.Stride = 0 then
         return T.Offset;
      end if;
      declare
         Room : constant Offset := Length - T.Width - T.Offset;
         Q    : constant Offset := Room / T.Stride;
      begin
         pragma Assert (Y <= Q);
         pragma Assert (Q * T.Stride <= Room);
         pragma Assert (Y * T.Stride <= Q * T.Stride);
         return T.Offset + Y * T.Stride;
      end;
   end Row_Start;

   -----------------
   -- Pixel_Start --
   -----------------

   function Pixel_Start
     (PB            : Pixel_Buffer;
      Pixels_Length : Array_Length;
      X, Y          : U32;
      BPP           : Pixel_Size) return Offset
   is
      W   : constant Index := Index (PB.Pixcfg.Width);
      XI  : constant Index := Index (X);
      Row : Offset;
   begin
      pragma Assert (Row_Bytes (PB.Pixcfg) = U64 (W) * U64 (BPP));
      pragma Assert (W * BPP >= 1);
      pragma Assert (Has_Elements (PB.Planes (0)));
      Row := Row_Start (PB.Planes (0), Index (Y), Pixels_Length);
      pragma Assert (Row_Bytes (PB.Pixcfg) = U64 (W) * U64 (BPP));
      pragma Assert (W * BPP <= PB.Planes (0).Width);
      pragma Assert (XI + 1 <= W);
      pragma Assert ((XI + 1) * BPP <= W * BPP);
      return Row + XI * BPP;
   end Pixel_Start;

   -------------
   -- Row_U32 --
   -------------

   procedure Row_U32
     (T      : Table;
      Y      : U32;
      Length : Array_Length;
      First  : out Offset;
      Count  : out Element_Count)
   is
   begin
      First := 0;
      Count := 0;
      if Fits (T, Length) and then Has_Row (T, Y) and then T.Width > 0 then
         First := Row_Start (T, Index (Y), Length);
         Count := T.Width;
      end if;
   end Row_U32;

   --------------
   -- Subtable --
   --------------

   procedure Subtable
     (T              : Table;
      IX, IY, JX, JY : U64;
      Length         : Array_Length;
      Result         : out Table)
   is
   begin
      Result := Empty_Table;
      if not Fits (T, Length)
        or else IX > JX or else JX > U64 (T.Width)
        or else IY > JY or else JY > U64 (T.Height)
      then
         return;
      end if;
      declare
         W : constant Index := Index (JX - IX);
         H : constant Index := Index (JY - IY);
      begin
         if W = 0 or else H = 0 then
            --  No elements: such a table fits anywhere.
            Result := (Offset => 0, Width => W, Height => H, Stride => T.Stride);
            return;
         end if;
         declare
            Row      : constant Offset := Row_Start (T, Index (IY), Length);
            Last_Row : constant Offset := Row_Start (T, Index (JY) - 1, Length);
         begin
            pragma Assert (Index (IX) + W <= T.Width);
            pragma Assert (Row <= Length - T.Width);
            pragma Assert (Last_Row <= Length - T.Width);
            pragma Assert (Row + Index (IX) + W <= Length);
            if H >= 2 and then T.Stride /= 0 then
               pragma Assert
                 (Last_Row - Row
                  = (Index (JY) - 1) * T.Stride - Index (IY) * T.Stride);
               pragma Assert (Last_Row - Row = (H - 1) * T.Stride);
               pragma Assert
                 ((H - 1) * T.Stride <= Length - W - (Row + Index (IX)));
               Lemma_Div_Lower
                 (H - 1, T.Stride, Length - W - (Row + Index (IX)));
            end if;
            Result :=
              (Offset => Row + Index (IX), Width => W, Height => H, Stride => T.Stride);
            pragma Assert (Fits (Result, Length));
         end;
      end;
   end Subtable;

   ---------------------
   -- Set_Interleaved --
   ---------------------

   procedure Set_Interleaved
     (PB             : out Pixel_Buffer;
      Pixcfg         : Pixel_Config;
      Primary        : Table;
      Pixels_Length  : Array_Length;
      Palette_Length : Array_Length;
      Result         : out Status)
   is
   begin
      PB := Null_Pixel_Buffer;
      if Is_Planar (Pixcfg.Pixfmt) then
         Result := Error_Bad_Argument;
      elsif Is_Indexed (Pixcfg.Pixfmt) and then Palette_Length < Palette_Byte_Length then
         Result := Error_Bad_Argument_Length_Too_Short;
      elsif Bits_Per_Pixel (Pixcfg.Pixfmt) = 0
        or else Bits_Per_Pixel (Pixcfg.Pixfmt) mod 8 /= 0
      then
         Result := Error_Unsupported_Option;
      elsif Row_Bytes (Pixcfg) > U64 (Primary.Width)
        or else Index (Pixcfg.Height) > Primary.Height
      then
         Result := Error_Bad_Argument;
      elsif not Fits (Primary, Pixels_Length) then
         --  Not a C check: see the specification.
         Result := Error_Bad_Argument;
      else
         PB.Pixcfg := Pixcfg;
         PB.Planes (0) := Primary;
         if Is_Indexed (Pixcfg.Pixfmt) then
            PB.Planes (Indexed_Color_Plane) :=
              (Offset => 0,
               Width  => Palette_Byte_Length,
               Height => 1,
               Stride => Palette_Byte_Length);
         end if;
         Result := Ok_Status;
      end if;
   end Set_Interleaved;

   --------------------
   -- Set_From_Slice --
   --------------------

   procedure Set_From_Slice
     (PB            : out Pixel_Buffer;
      Pixcfg        : Pixel_Config;
      Pixbuf_Length : Array_Length;
      Result        : out Status)
   is
      BPP : constant U64 := U64 (Bytes_Per_Pixel (Pixcfg.Pixfmt));
      WH  : constant U64 := U64 (Pixcfg.Width) * U64 (Pixcfg.Height);
   begin
      PB := Null_Pixel_Buffer;
      if Is_Planar (Pixcfg.Pixfmt) or else BPP = 0 then
         Result := Error_Unsupported_Option;
         return;
      end if;
      if Pixbuf_Length < Pixel_Memory_Offset (Pixcfg) then
         Result := Error_Bad_Argument_Length_Too_Short;
         return;
      end if;
      --  As in C, the palette plane is filled in before the remaining
      --  checks and stays if one of them fails.
      if Is_Indexed (Pixcfg.Pixfmt) then
         PB.Planes (Indexed_Color_Plane) :=
           (Offset => 0,
            Width  => Palette_Byte_Length,
            Height => 1,
            Stride => Palette_Byte_Length);
      end if;
      --  (The C code also tests width > SIZE_MAX / bytes_per_pixel, which
      --  is never true where size_t has 64 bits.)
      if WH > U64'Last / BPP then
         Result := Error_Bad_Argument;
         return;
      end if;
      declare
         Avail : constant Offset := Pixbuf_Length - Pixel_Memory_Offset (Pixcfg);
         Row   : constant Index := Row_Width (Pixcfg);
         H     : constant Index := Index (Pixcfg.Height);
      begin
         --  C: `wh * bytes_per_pixel > len`, a product that cannot wrap
         --  here.  The same test without the product: height rows of Row
         --  bytes do not fit in Avail bytes.
         if Row /= 0 and then H > Avail / Row then
            Result := Error_Bad_Argument_Length_Too_Short;
            return;
         end if;
         if H >= 1 and then Row >= 1 then
            Lemma_Rows_Fit (H, Row, Avail);
         end if;
         PB.Pixcfg := Pixcfg;
         PB.Planes (0) := (Offset => 0, Width => Row, Height => H, Stride => Row);
         pragma Assert (Fits (PB.Planes (0), Avail));
      end;
      Result := Ok_Status;
   end Set_From_Slice;

   ---------------------
   -- Closest_Element --
   ---------------------

   function Closest_Element
     (Palette_Slice  : Bytes;
      Palette_Format : Pixel_Format;
      C              : Color_U32_ARGB_Premul) return U8
   is
      N          : constant Offset := Offset'Min (Palette_Slice'Length / 4, 256);
      Best_Index : U8 := 0;
      Best_Score : U64 := U64'Last;
      CA         : constant U32 := 16#101# * Ch8 (C, 24);
      CR         : constant U32 := 16#101# * Ch8 (C, 16);
      CG         : constant U32 := 16#101# * Ch8 (C, 8);
      CB         : constant U32 := 16#101# * Ch8 (C, 0);
      Nonpremul  : constant Boolean := Palette_Format.Repr = Repr_Indexed_BGRA_Nonpremul;
      PB, PG, PR, PA : U32;
      Score      : U64;
      E          : Index;
   begin
      if Palette_Format.Repr not in Repr_Indexed_BGRA_Nonpremul
                                  | Repr_Indexed_BGRA_Premul
                                  | Repr_Indexed_BGRA_Binary
      then
         return 0;
      end if;
      for I in 0 .. N - 1 loop
         E := Palette_Slice'First + 4 * I;
         PB := 16#101# * U32 (Palette_Slice (E));
         PG := 16#101# * U32 (Palette_Slice (E + 1));
         PR := 16#101# * U32 (Palette_Slice (E + 2));
         PA := 16#101# * U32 (Palette_Slice (E + 3));
         if Nonpremul and then PA /= 16#FFFF# then
            PB := (PB * PA) / 16#FFFF#;
            PG := (PG * PA) / 16#FFFF#;
            PR := (PR * PA) / 16#FFFF#;
         end if;
         --  Unsigned differences and squares, wrapping at 32 bits as in C.
         PB := PB - CB;
         PG := PG - CG;
         PR := PR - CR;
         PA := PA - CA;
         Score := U64 (PB * PB) + U64 (PG * PG) + U64 (PR * PR) + U64 (PA * PA);
         if Best_Score > Score then
            Best_Score := Score;
            Best_Index := U8 (I);
         end if;
      end loop;
      return Best_Index;
   end Closest_Element;

   ------------------------
   -- Closest_In_Palette --
   ------------------------

   function Closest_In_Palette
     (PB      : Pixel_Buffer;
      Palette : Bytes;
      C       : Color_U32_ARGB_Premul) return U8
   is
     (if Has_Palette (PB)
      then Closest_Element
             (Palette (Palette'First .. Palette'First + (Palette_Byte_Length - 1)),
              PB.Pixcfg.Pixfmt, C)
      else 0);

   ------------------
   -- Color_U32_At --
   ------------------

   function Color_U32_At
     (PB      : Pixel_Buffer;
      Pixels  : Bytes;
      Palette : Bytes;
      X, Y    : U32) return Color_U32_ARGB_Premul
   is
      F : constant U32 := PB.Pixcfg.Pixfmt.Repr;
      P : Index;

      --  First index of the palette entry that pixel byte Pixels (P)
      --  selects.
      function Entry_Of return Index is (Palette'First + 4 * Index (Pixels (P)))
      with Pre => P in Pixels'Range and then Palette'Length >= Palette_Byte_Length;
   begin
      if not Is_Valid (PB, Pixels'Length, Palette'Length)
        or else X >= PB.Pixcfg.Width or else Y >= PB.Pixcfg.Height
        or else Is_Planar (PB.Pixcfg.Pixfmt)
      then
         return 0;
      end if;
      case F is
         when Repr_BGRA_Premul | Repr_BGRA_Binary =>
            P := Pixels'First + Pixel_Start (PB, Pixels'Length, X, Y, 4);
            return Peek_U32LE (Pixels, P);
         when Repr_Indexed_BGRA_Premul | Repr_Indexed_BGRA_Binary =>
            P := Pixels'First + Pixel_Start (PB, Pixels'Length, X, Y, 1);
            return Peek_U32LE (Palette, Entry_Of);
         when Repr_Y =>
            P := Pixels'First + Pixel_Start (PB, Pixels'Length, X, Y, 1);
            return 16#FF00_0000# or (16#0001_0101# * U32 (Pixels (P)));
         when Repr_Y_16LE =>
            P := Pixels'First + Pixel_Start (PB, Pixels'Length, X, Y, 2);
            return 16#FF00_0000# or (16#0001_0101# * U32 (Pixels (P + 1)));
         when Repr_Y_16BE =>
            P := Pixels'First + Pixel_Start (PB, Pixels'Length, X, Y, 2);
            return 16#FF00_0000# or (16#0001_0101# * U32 (Pixels (P)));
         when Repr_YA_Nonpremul =>
            P := Pixels'First + Pixel_Start (PB, Pixels'Length, X, Y, 2);
            return Nonpremul_U32_As_Premul_U32
                     (Shift_Left (U32 (Pixels (P + 1)), 24)
                      or (U32 (Pixels (P)) * 16#0001_0101#));
         when Repr_Indexed_BGRA_Nonpremul =>
            P := Pixels'First + Pixel_Start (PB, Pixels'Length, X, Y, 1);
            return Nonpremul_U32_As_Premul_U32 (Peek_U32LE (Palette, Entry_Of));
         when Repr_BGR_565 =>
            P := Pixels'First + Pixel_Start (PB, Pixels'Length, X, Y, 2);
            return RGB_565_As_Premul_U32 (Peek_U16LE (Pixels, P));
         when Repr_BGR =>
            P := Pixels'First + Pixel_Start (PB, Pixels'Length, X, Y, 3);
            return 16#FF00_0000# or Peek_U24LE (Pixels, P);
         when Repr_BGRA_Nonpremul =>
            P := Pixels'First + Pixel_Start (PB, Pixels'Length, X, Y, 4);
            return Nonpremul_U32_As_Premul_U32 (Peek_U32LE (Pixels, P));
         when Repr_BGRA_Nonpremul_4x16LE =>
            P := Pixels'First + Pixel_Start (PB, Pixels'Length, X, Y, 8);
            return Nonpremul_U64_As_Premul_U32 (Peek_U64LE (Pixels, P));
         when Repr_BGRA_Premul_4x16LE =>
            P := Pixels'First + Pixel_Start (PB, Pixels'Length, X, Y, 8);
            return U64_As_U32 (Peek_U64LE (Pixels, P));
         when Repr_BGRX =>
            P := Pixels'First + Pixel_Start (PB, Pixels'Length, X, Y, 4);
            return 16#FF00_0000# or Peek_U32LE (Pixels, P);
         when Repr_RGB =>
            P := Pixels'First + Pixel_Start (PB, Pixels'Length, X, Y, 3);
            return 16#FF00_0000# or Peek_U24BE (Pixels, P);
         when Repr_RGBA_Nonpremul =>
            P := Pixels'First + Pixel_Start (PB, Pixels'Length, X, Y, 4);
            return Swap_U32_ARGB_ABGR
                     (Nonpremul_U32_As_Premul_U32 (Peek_U32LE (Pixels, P)));
         when Repr_RGBA_Premul | Repr_RGBA_Binary =>
            P := Pixels'First + Pixel_Start (PB, Pixels'Length, X, Y, 4);
            return Swap_U32_ARGB_ABGR (Peek_U32LE (Pixels, P));
         when Repr_RGBX =>
            P := Pixels'First + Pixel_Start (PB, Pixels'Length, X, Y, 4);
            return Swap_U32_ARGB_ABGR (16#FF00_0000# or Peek_U32LE (Pixels, P));
         when others =>
            return 0;
      end case;
   end Color_U32_At;

   ----------------------
   -- Set_Color_U32_At --
   ----------------------

   procedure Set_Color_U32_At
     (PB      : Pixel_Buffer;
      Pixels  : in out Bytes;
      Palette : Bytes;
      X, Y    : U32;
      Color   : Color_U32_ARGB_Premul;
      Result  : out Status)
   is
      F : constant U32 := PB.Pixcfg.Pixfmt.Repr;
      P : Index;
   begin
      if not Is_Valid (PB, Pixels'Length, Palette'Length)
        or else X >= PB.Pixcfg.Width or else Y >= PB.Pixcfg.Height
      then
         Result := Error_Bad_Argument;
         return;
      elsif Is_Planar (PB.Pixcfg.Pixfmt) then
         Result := Error_Unsupported_Option;
         return;
      end if;
      Result := Ok_Status;
      case F is
         when Repr_BGRA_Premul | Repr_BGRX =>
            P := Pixels'First + Pixel_Start (PB, Pixels'Length, X, Y, 4);
            Poke_U32LE (Pixels, P, Color);
         when Repr_Y =>
            P := Pixels'First + Pixel_Start (PB, Pixels'Length, X, Y, 1);
            Poke_U8 (Pixels, P, Premul_U32_As_Gray_U8 (Color));
         when Repr_Y_16LE =>
            P := Pixels'First + Pixel_Start (PB, Pixels'Length, X, Y, 2);
            Poke_U16LE (Pixels, P, Premul_U32_As_Gray_U16 (Color));
         when Repr_Y_16BE =>
            P := Pixels'First + Pixel_Start (PB, Pixels'Length, X, Y, 2);
            Poke_U16BE (Pixels, P, Premul_U32_As_Gray_U16 (Color));
         when Repr_YA_Nonpremul =>
            P := Pixels'First + Pixel_Start (PB, Pixels'Length, X, Y, 2);
            Poke_U16LE (Pixels, P, Premul_U32_As_Alpha_Gray_Nonpremul_U16 (Color));
         when Repr_Indexed_BGRA_Nonpremul
            | Repr_Indexed_BGRA_Premul
            | Repr_Indexed_BGRA_Binary =>
            P := Pixels'First + Pixel_Start (PB, Pixels'Length, X, Y, 1);
            Poke_U8 (Pixels, P, Closest_In_Palette (PB, Palette, Color));
         when Repr_BGR_565 =>
            P := Pixels'First + Pixel_Start (PB, Pixels'Length, X, Y, 2);
            Poke_U16LE (Pixels, P, Premul_U32_As_RGB_565 (Color));
         when Repr_BGR =>
            P := Pixels'First + Pixel_Start (PB, Pixels'Length, X, Y, 3);
            Poke_U24LE (Pixels, P, Color);
         when Repr_BGRA_Nonpremul =>
            P := Pixels'First + Pixel_Start (PB, Pixels'Length, X, Y, 4);
            Poke_U32LE (Pixels, P, Premul_U32_As_Nonpremul_U32 (Color));
         when Repr_BGRA_Nonpremul_4x16LE =>
            P := Pixels'First + Pixel_Start (PB, Pixels'Length, X, Y, 8);
            Poke_U64LE (Pixels, P, Premul_U32_As_Nonpremul_U64 (Color));
         when Repr_BGRA_Premul_4x16LE =>
            P := Pixels'First + Pixel_Start (PB, Pixels'Length, X, Y, 8);
            Poke_U64LE (Pixels, P, U32_As_U64 (Color));
         when Repr_BGRA_Binary =>
            P := Pixels'First + Pixel_Start (PB, Pixels'Length, X, Y, 4);
            Poke_U32LE
              (Pixels, P,
               (if Shift_Right (Color, 31) /= 0 then Color or 16#FF00_0000# else 0));
         when Repr_RGB =>
            P := Pixels'First + Pixel_Start (PB, Pixels'Length, X, Y, 3);
            Poke_U24LE (Pixels, P, Swap_U32_ARGB_ABGR (Color));
         when Repr_RGBA_Nonpremul =>
            P := Pixels'First + Pixel_Start (PB, Pixels'Length, X, Y, 4);
            Poke_U32LE
              (Pixels, P, Premul_U32_As_Nonpremul_U32 (Swap_U32_ARGB_ABGR (Color)));
         when Repr_RGBA_Premul | Repr_RGBX =>
            P := Pixels'First + Pixel_Start (PB, Pixels'Length, X, Y, 4);
            Poke_U32LE (Pixels, P, Swap_U32_ARGB_ABGR (Color));
         when others =>
            Result := Error_Unsupported_Option;
      end case;
   end Set_Color_U32_At;

   -------------------------------------
   -- Set_Color_U32_ARGB_Nonpremul_At --
   -------------------------------------

   procedure Set_Color_U32_ARGB_Nonpremul_At
     (PB      : Pixel_Buffer;
      Pixels  : in out Bytes;
      Palette : Bytes;
      X, Y    : U32;
      Color   : Color_U32_ARGB_Nonpremul;
      Result  : out Status)
   is
      F      : constant U32 := PB.Pixcfg.Pixfmt.Repr;
      Premul : constant U32 := Nonpremul_U32_As_Premul_U32 (Color);
      P      : Index;
   begin
      if not Is_Valid (PB, Pixels'Length, Palette'Length)
        or else X >= PB.Pixcfg.Width or else Y >= PB.Pixcfg.Height
      then
         Result := Error_Bad_Argument;
         return;
      elsif Is_Planar (PB.Pixcfg.Pixfmt) then
         Result := Error_Unsupported_Option;
         return;
      end if;
      Result := Ok_Status;
      case F is
         when Repr_BGRA_Premul | Repr_BGRX =>
            P := Pixels'First + Pixel_Start (PB, Pixels'Length, X, Y, 4);
            Poke_U32LE (Pixels, P, Premul);
         when Repr_Y =>
            P := Pixels'First + Pixel_Start (PB, Pixels'Length, X, Y, 1);
            Poke_U8 (Pixels, P, Premul_U32_As_Gray_U8 (Premul));
         when Repr_Y_16LE =>
            P := Pixels'First + Pixel_Start (PB, Pixels'Length, X, Y, 2);
            Poke_U16LE (Pixels, P, Premul_U32_As_Gray_U16 (Premul));
         when Repr_Y_16BE =>
            P := Pixels'First + Pixel_Start (PB, Pixels'Length, X, Y, 2);
            Poke_U16BE (Pixels, P, Premul_U32_As_Gray_U16 (Premul));
         when Repr_YA_Nonpremul =>
            P := Pixels'First + Pixel_Start (PB, Pixels'Length, X, Y, 2);
            Poke_U8 (Pixels, P, Premul_U32_As_Gray_U8 (Color or 16#FF00_0000#));
            Poke_U8 (Pixels, P + 1, U8 (Shift_Right (Color, 24)));
         when Repr_Indexed_BGRA_Nonpremul
            | Repr_Indexed_BGRA_Premul
            | Repr_Indexed_BGRA_Binary =>
            P := Pixels'First + Pixel_Start (PB, Pixels'Length, X, Y, 1);
            Poke_U8 (Pixels, P, Closest_In_Palette (PB, Palette, Premul));
         when Repr_BGR_565 =>
            P := Pixels'First + Pixel_Start (PB, Pixels'Length, X, Y, 2);
            Poke_U16LE (Pixels, P, Premul_U32_As_RGB_565 (Premul));
         when Repr_BGR =>
            P := Pixels'First + Pixel_Start (PB, Pixels'Length, X, Y, 3);
            Poke_U24LE (Pixels, P, Premul);
         when Repr_BGRA_Nonpremul =>
            P := Pixels'First + Pixel_Start (PB, Pixels'Length, X, Y, 4);
            Poke_U32LE (Pixels, P, Color);
         when Repr_BGRA_Nonpremul_4x16LE =>
            P := Pixels'First + Pixel_Start (PB, Pixels'Length, X, Y, 8);
            Poke_U64LE (Pixels, P, U32_As_U64 (Color));
         when Repr_BGRA_Premul_4x16LE =>
            P := Pixels'First + Pixel_Start (PB, Pixels'Length, X, Y, 8);
            Poke_U64LE (Pixels, P, Nonpremul_U64_As_Premul_U64 (U32_As_U64 (Color)));
         when Repr_BGRA_Binary =>
            P := Pixels'First + Pixel_Start (PB, Pixels'Length, X, Y, 4);
            Poke_U32LE
              (Pixels, P,
               (if Shift_Right (Color, 31) /= 0 then Premul or 16#FF00_0000# else 0));
         when Repr_RGB =>
            P := Pixels'First + Pixel_Start (PB, Pixels'Length, X, Y, 3);
            Poke_U24LE (Pixels, P, Swap_U32_ARGB_ABGR (Premul));
         when Repr_RGBA_Nonpremul =>
            P := Pixels'First + Pixel_Start (PB, Pixels'Length, X, Y, 4);
            Poke_U32LE (Pixels, P, Swap_U32_ARGB_ABGR (Color));
         when Repr_RGBA_Premul | Repr_RGBX =>
            P := Pixels'First + Pixel_Start (PB, Pixels'Length, X, Y, 4);
            Poke_U32LE (Pixels, P, Swap_U32_ARGB_ABGR (Premul));
         when others =>
            Result := Error_Unsupported_Option;
      end case;
   end Set_Color_U32_ARGB_Nonpremul_At;

   -----------------------------
   -- Set_Color_U32_Fill_Rect --
   -----------------------------

   procedure Set_Color_U32_Fill_Rect
     (PB      : Pixel_Buffer;
      Pixels  : in out Bytes;
      Palette : Bytes;
      Rect    : Ranges.Rect_IE_U32;
      Color   : Color_U32_ARGB_Premul;
      Result  : out Status)
   is
      Ignored : Status;
   begin
      Result := Ok_Status;
      if not Is_Valid (PB, Pixels'Length, Palette'Length) then
         Result := Error_Bad_Argument;
         return;
      elsif Ranges.Is_Empty (Rect) then
         return;
      elsif not Ranges.Contains_Rect (Bounds (PB.Pixcfg), Rect) then
         Result := Error_Bad_Argument;
         return;
      elsif Is_Planar (PB.Pixcfg.Pixfmt) then
         Result := Error_Unsupported_Option;
         return;
      end if;
      --  C has faster loops for eight formats, which write the bytes that
      --  Set_Color_U32_At writes; for the rest it calls that function per
      --  pixel and ignores its status, as here.
      for YY in Rect.Min_Incl_Y .. Rect.Max_Excl_Y - 1 loop
         for XX in Rect.Min_Incl_X .. Rect.Max_Excl_X - 1 loop
            Set_Color_U32_At (PB, Pixels, Palette, XX, YY, Color, Ignored);
         end loop;
      end loop;
   end Set_Color_U32_Fill_Rect;

   ---------------
   -- Is_Opaque --
   ---------------

   function Is_Opaque
     (PB : Pixel_Buffer; Pixels : Bytes; Palette : Bytes) return Boolean
   is
      F    : constant U32 := PB.Pixcfg.Pixfmt.Repr;
      W    : constant U32 := PB.Pixcfg.Width;
      H    : constant U32 := PB.Pixcfg.Height;
      P    : Index;
      Skip : Boolean;
   begin
      if not Is_Valid (PB, Pixels'Length, Palette'Length) then
         return False;
      elsif Transparency (PB.Pixcfg.Pixfmt) = Opaque then
         return True;
      elsif W = 0 or else H = 0 then
         return True;
      end if;
      case F is
         when Repr_BGRA_Nonpremul | Repr_BGRA_Premul | Repr_BGRA_Binary
            | Repr_RGBA_Nonpremul | Repr_RGBA_Premul | Repr_RGBA_Binary =>
            for YY in 0 .. H - 1 loop
               for XX in 0 .. W - 1 loop
                  P := Pixels'First + Pixel_Start (PB, Pixels'Length, XX, YY, 4);
                  if Pixels (P + 3) /= 16#FF# then
                     return False;
                  end if;
               end loop;
            end loop;
            return True;
         when Repr_BGRA_Nonpremul_4x16LE =>
            for YY in 0 .. H - 1 loop
               for XX in 0 .. W - 1 loop
                  P := Pixels'First + Pixel_Start (PB, Pixels'Length, XX, YY, 8);
                  if Pixels (P + 6) /= 16#FF# or else Pixels (P + 7) /= 16#FF# then
                     return False;
                  end if;
               end loop;
            end loop;
            return True;
         when Repr_YA_Nonpremul =>
            for YY in 0 .. H - 1 loop
               for XX in 0 .. W - 1 loop
                  P := Pixels'First + Pixel_Start (PB, Pixels'Length, XX, YY, 2);
                  if Pixels (P + 1) /= 16#FF# then
                     return False;
                  end if;
               end loop;
            end loop;
            return True;
         when Repr_Indexed_BGRA_Premul
            | Repr_Indexed_BGRA_Binary
            | Repr_Indexed_BGRA_Nonpremul =>
            --  If every palette entry is opaque, so is the image.
            Skip := True;
            for I in Index range 0 .. 255 loop
               if Palette (Palette'First + 4 * I + 3) /= 16#FF# then
                  Skip := False;
                  exit;
               end if;
            end loop;
            if Skip then
               return True;
            end if;
            for YY in 0 .. H - 1 loop
               for XX in 0 .. W - 1 loop
                  P := Pixels'First + Pixel_Start (PB, Pixels'Length, XX, YY, 1);
                  if Palette (Palette'First + 4 * Index (Pixels (P)) + 3) /= 16#FF# then
                     return False;
                  end if;
               end loop;
            end loop;
            return True;
         when others =>
            return False;
      end case;
   end Is_Opaque;

end Wuffs.Base.Pixel_Buffers;
