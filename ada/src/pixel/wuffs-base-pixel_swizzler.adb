with Wuffs.Base.Pixel_Select;
with Wuffs.Base.Slices;

package body Wuffs.Base.Pixel_Swizzler with SPARK_Mode is

   pragma Assertion_Policy (Ignore);

   use Wuffs.Base.Pixel_Rows;
   use Wuffs.Base.Pixel_Select;

   --  How prepare fills the destination palette for an indexed source.
   --  C: wuffs_private_impl__pixel_swizzler__prepare__indexed__bgra_nonpremul
   --  and ..._prepare__indexed__bgra_binary.
   type Palette_Prep is
     (Prep_None,
      Prep_Copy,                          --  slice copy, must give 1024 bytes
      Prep_Squash_Y_Nonpremul,            --  the rest must give 256 entries
      Prep_Squash_Y,
      Prep_Squash_565_Nonpremul,
      Prep_Squash_565,
      Prep_Premul_From_BGRA_Nonpremul,
      Prep_Premul_From_RGBA_Nonpremul,
      Prep_Swap_RGBX_BGRX);

   function Prep_For
     (Src, Dst : U32; Blend : Blend_Class) return Palette_Prep
   is
     (case Src is
        when Repr_Indexed_BGRA_Nonpremul =>
          (case Dst is
             when Repr_Y =>
               (case Blend is
                  when 0 => Prep_Squash_Y_Nonpremul,
                  when 1 => Prep_Copy,
                  when 2 => Prep_None),
             when Repr_Indexed_BGRA_Nonpremul
                | Repr_BGRA_Nonpremul
                | Repr_BGRA_Nonpremul_4x16LE => Prep_Copy,
             when Repr_BGR_565 =>
               (case Blend is
                  when 0 => Prep_Squash_565_Nonpremul,
                  when 1 => Prep_Copy,
                  when 2 => Prep_None),
             when Repr_BGR | Repr_BGRA_Premul =>
               (case Blend is
                  when 0 => Prep_Premul_From_BGRA_Nonpremul,
                  when 1 => Prep_Copy,
                  when 2 => Prep_None),
             when Repr_RGB | Repr_RGBA_Premul =>
               (case Blend is
                  when 0 => Prep_Premul_From_RGBA_Nonpremul,
                  when 1 => Prep_Swap_RGBX_BGRX,
                  when 2 => Prep_None),
             when Repr_RGBA_Nonpremul => Prep_Swap_RGBX_BGRX,
             when others => Prep_None),
        when Repr_Indexed_BGRA_Binary =>
          (case Dst is
             when Repr_Y => Prep_Squash_Y,
             when Repr_BGR_565 => Prep_Squash_565,
             when Repr_Indexed_BGRA_Nonpremul
                | Repr_Indexed_BGRA_Premul
                | Repr_Indexed_BGRA_Binary
                | Repr_BGR
                | Repr_BGRA_Nonpremul
                | Repr_BGRA_Premul
                | Repr_BGRA_Binary
                | Repr_BGRA_Nonpremul_4x16LE
                | Repr_BGRA_Premul_4x16LE => Prep_Copy,
             when Repr_RGB
                | Repr_RGBA_Nonpremul
                | Repr_RGBA_Premul
                | Repr_RGBA_Binary => Prep_Swap_RGBX_BGRX,
             when others => Prep_None),
        when others => Prep_None);

   --  Runs the preparation; Complete is True if it filled all 1024 bytes
   --  (or there was nothing to do).
   procedure Prepare_Palette
     (Prep        : Palette_Prep;
      Dst_Palette : in out Bytes;
      Src_Palette : Bytes;
      Complete    : out Boolean);

   ---------------------
   -- Prepare_Palette --
   ---------------------

   procedure Prepare_Palette
     (Prep        : Palette_Prep;
      Dst_Palette : in out Bytes;
      Src_Palette : Bytes;
      Complete    : out Boolean)
   is
      No_Palette : constant Bytes (1 .. 0) := [];
      Copied     : U64;
      N          : Pixel_Count;
   begin
      case Prep is
         when Prep_None =>
            Complete := True;
            return;
         when Prep_Copy =>
            Slices.Copy_From_Slice (Dst_Palette, Src_Palette, Copied);
            Complete := Copied = Palette_Byte_Length;
            return;
         when Prep_Squash_Y_Nonpremul =>
            Squash_Align4_Y_8888 (Dst_Palette, Src_Palette, True, N);
         when Prep_Squash_Y =>
            Squash_Align4_Y_8888 (Dst_Palette, Src_Palette, False, N);
         when Prep_Squash_565_Nonpremul =>
            Squash_Align4_Bgr_565_8888 (Dst_Palette, Src_Palette, True, N);
         when Prep_Squash_565 =>
            Squash_Align4_Bgr_565_8888 (Dst_Palette, Src_Palette, False, N);
         when Prep_Premul_From_BGRA_Nonpremul =>
            Bgra_Premul_From_Bgra_Nonpremul_Src (Dst_Palette, No_Palette, Src_Palette, N);
         when Prep_Premul_From_RGBA_Nonpremul =>
            Bgra_Premul_From_Rgba_Nonpremul_Src (Dst_Palette, No_Palette, Src_Palette, N);
         when Prep_Swap_RGBX_BGRX =>
            Swap_Rgbx_Bgrx (Dst_Palette, No_Palette, Src_Palette, N);
      end case;
      Complete := N = Palette_Byte_Length / 4;
   end Prepare_Palette;

   -------------
   -- Prepare --
   -------------

   procedure Prepare
     (S           : out Swizzler;
      Dst_Pixfmt  : Pixel_Format;
      Dst_Palette : in out Bytes;
      Src_Pixfmt  : Pixel_Format;
      Src_Palette : Bytes;
      Blend       : Pixel_Blend;
      Result      : out Status)
   is
      Dst_Bits : constant U32 := Bits_Per_Pixel (Dst_Pixfmt);
      Src_Bits : constant U32 := Bits_Per_Pixel (Src_Pixfmt);
      Class    : constant Blend_Class := (if Blend <= 1 then U8 (Blend) else 2);
      Sel      : Selection;
      Complete : Boolean;
   begin
      S := (Has_Func          => False,
            Func              => Row_Function'First,
            Transparent_Black => TB_None,
            Dst_BPP           => 0,
            Src_BPP           => 0);
      Result := Error_Unsupported_Pixel_Swizzler_Option;
      if Dst_Bits = 0 or else Dst_Bits mod 8 /= 0
        or else Src_Bits = 0 or else Src_Bits mod 8 /= 0
      then
         return;
      end if;

      Sel := Select_Row_Function (Src_Pixfmt.Repr, Dst_Pixfmt.Repr, Class);
      Prepare_Palette
        (Prep_For (Src_Pixfmt.Repr, Dst_Pixfmt.Repr, Class),
         Dst_Palette, Src_Palette, Complete);
      if not Complete then
         Sel := None;
      end if;

      --  That every row function named by the generated table converts
      --  between pixels of exactly these two formats' sizes (the Swizzler
      --  predicate, on which the reader forms rely when they advance the
      --  reader by Src_BPP per pixel, as C does) is established by proof:
      --  GNATprove checks the predicate here against the table.
      S := (Has_Func          => Sel.Found,
            Func              => Sel.Fn,
            Transparent_Black =>
              (if Blend = Blend_Src then TB_Src
               elsif Blend = Blend_Src_Over then TB_Src_Over
               else TB_None),
            Dst_BPP           => Dst_Bits / 8,
            Src_BPP           => Src_Bits / 8);
      if Sel.Found then
         Result := Ok_Status;
      end if;
   end Prepare;

   ------------------------------------
   -- Swizzle_Interleaved_From_Slice --
   ------------------------------------

   procedure Swizzle_Interleaved_From_Slice
     (S           : Swizzler;
      Dst         : in out Bytes;
      Dst_Palette : Bytes;
      Src         : Bytes;
      N           : out U64)
   is
      Count : Pixel_Count;
   begin
      if S.Has_Func then
         Swizzle_Row (S.Func, Dst, Dst_Palette, Src, Count);
         pragma Assert (Count <= Dst'Length / Pixel_Rows.Dst_BPP (S.Func));
         pragma Assert (Count <= Src'Length / Pixel_Rows.Src_BPP (S.Func));
         pragma Assert (Count <= Dst'Length and then Count <= Src'Length);
         pragma Assert (Count * Pixel_Rows.Dst_BPP (S.Func) <= Dst'Length);
         N := U64 (Count);
         pragma Assert (Offset (N) = Count);
      else
         N := 0;
      end if;
   end Swizzle_Interleaved_From_Slice;

   --  The two reader forms: swizzle from the Src_Length unread bytes at
   --  the reader's cursor, then advance it.
   procedure From_Reader
     (S           : Swizzler;
      Dst         : in out Bytes;
      Dst_Palette : Bytes;
      Src_Data    : Bytes;
      R           : in out IO.Reader;
      Src_Length  : Index;
      Count       : out Index)
   with
     Pre  => IO.Valid (Src_Data, R) and then Src_Length <= R.Io2 - R.Iop,
     Post => Count <= Src_Length
       and then Count * Index (S.Src_BPP) <= Src_Length
       and then (if S.Has_Func then Count <= Src_Length / Index (S.Src_BPP))
       and then R = (R'Old with delta Iop => R'Old.Iop + Count * Index (S.Src_BPP))
       and then (if not S.Has_Func then Count = 0);

   -----------------
   -- From_Reader --
   -----------------

   procedure From_Reader
     (S           : Swizzler;
      Dst         : in out Bytes;
      Dst_Palette : Bytes;
      Src_Data    : Bytes;
      R           : in out IO.Reader;
      Src_Length  : Index;
      Count       : out Index)
   is
   begin
      Count := 0;
      if not S.Has_Func or else Src_Length = 0 then
         return;
      end if;
      declare
         First  : constant Index := Src_Data'First + R.Iop;
         BPP    : constant Index := Pixel_Rows.Src_BPP (S.Func);
         Pixels : Pixel_Count;
      begin
         Swizzle_Row
           (S.Func, Dst, Dst_Palette, Src_Data (First .. First + (Src_Length - 1)), Pixels);
         pragma Assert (BPP = Index (S.Src_BPP));
         pragma Assert (Pixels <= Src_Length / BPP);
         pragma Assert (Src_Length / BPP <= Src_Length);
         pragma Assert ((Src_Length / BPP) * BPP <= Src_Length);
         pragma Assert (Pixels * BPP <= (Src_Length / BPP) * BPP);
         pragma Assert (Pixels * BPP <= Src_Length);
         Count := Pixels;
         R := (R with delta Iop => R.Iop + Pixels * BPP);
      end;
   end From_Reader;

   -------------------------------------
   -- Swizzle_Interleaved_From_Reader --
   -------------------------------------

   procedure Swizzle_Interleaved_From_Reader
     (S           : Swizzler;
      Dst         : in out Bytes;
      Dst_Palette : Bytes;
      Src_Data    : Bytes;
      R           : in out IO.Reader;
      N           : out U64)
   is
      Count : Index;
   begin
      From_Reader (S, Dst, Dst_Palette, Src_Data, R, R.Io2 - R.Iop, Count);
      N := U64 (Count);
      pragma Assert (Index (N) = Count);
   end Swizzle_Interleaved_From_Reader;

   -------------------------------------------------
   -- Limited_Swizzle_U32_Interleaved_From_Reader --
   -------------------------------------------------

   procedure Limited_Swizzle_U32_Interleaved_From_Reader
     (S                : Swizzler;
      Up_To_Num_Pixels : U32;
      Dst              : in out Bytes;
      Dst_Palette      : Bytes;
      Src_Data         : Bytes;
      R                : in out IO.Reader;
      N                : out U64)
   is
      --  C: min (up_to_num_pixels * src_bytes_per_pixel, io2 - iop), in 64
      --  bits; the product is below 2**37.
      BPP    : constant Index := Index (S.Src_BPP);
      Wanted : constant Index := Index (Up_To_Num_Pixels) * BPP;
      Avail  : constant Index := R.Io2 - R.Iop;
      Length : constant Index := Index'Min (Wanted, Avail);
      Count  : Index;
   begin
      if not S.Has_Func then
         N := 0;
         return;
      end if;
      pragma Assert (Wanted / BPP = Index (Up_To_Num_Pixels));
      pragma Assert (Length / BPP <= Wanted / BPP);
      From_Reader (S, Dst, Dst_Palette, Src_Data, R, Length, Count);
      pragma Assert (Count <= Index (Up_To_Num_Pixels));
      N := U64 (Count);
      pragma Assert (Index (N) = Count);
   end Limited_Swizzle_U32_Interleaved_From_Reader;

   -------------------------------------------
   -- Swizzle_Interleaved_Transparent_Black --
   -------------------------------------------

   procedure Swizzle_Interleaved_Transparent_Black
     (S           : Swizzler;
      Dst         : in out Bytes;
      Dst_Palette : Bytes;
      Num_Pixels  : U64;
      N           : out U64)
   is
      pragma Unreferenced (Dst_Palette);
   begin
      if S.Transparent_Black = TB_None then
         N := 0;
         return;
      end if;
      declare
         BPP   : constant Index := Index (S.Dst_BPP);
         Whole : constant Offset := Dst'Length / BPP;
         Count : constant Offset :=
           (if U64 (Whole) > Num_Pixels then Offset (Num_Pixels) else Whole);
         Total : Offset;
      begin
         pragma Assert (Whole * BPP <= Dst'Length);
         pragma Assert (Count in 0 .. Whole);
         pragma Assert (Count * BPP <= Whole * BPP);
         Total := Count * BPP;
         if S.Transparent_Black = TB_Src then
            for J in 0 .. Total - 1 loop
               Dst (Dst'First + J) := 0;
               pragma Loop_Invariant (Total <= Dst'Length);
               pragma Loop_Invariant
                 (for all K in Dst'Range =>
                    (if K - Dst'First <= J then Dst (K) = 0
                     else Dst (K) = Dst'Loop_Entry (K)));
            end loop;
         end if;
         N := U64 (Count);
      end;
   end Swizzle_Interleaved_Transparent_Black;

end Wuffs.Base.Pixel_Swizzler;
