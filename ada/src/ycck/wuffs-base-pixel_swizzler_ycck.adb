with Wuffs.Base.Color_YCC;
with Wuffs.Base.Colors;
with Wuffs.Base.Endian;
with Wuffs.Base.Pixel_Buffers.Rows;
with Wuffs.Base.Pixel_Composite;
with Wuffs.Base.Pixel_Formats;

package body Wuffs.Base.Pixel_Swizzler_YCCK with SPARK_Mode is

   pragma Assertion_Policy (Ignore);

   use Interfaces;
   use Wuffs.Base.Color_YCC;
   use Wuffs.Base.Colors;
   use Wuffs.Base.Endian;
   use Wuffs.Base.Pixel_Buffers;
   use Wuffs.Base.Pixel_Buffers.Rows;
   use Wuffs.Base.Pixel_Composite;
   use Wuffs.Base.Pixel_Formats;

   --  Every subprogram below names the C function (of wuffs/internal/cgen/
   --  base/pixconv-submodule-ycck.c, prefix wuffs_private_impl__swizzle_)
   --  that it corresponds to.  Where C has a three plane function
   --  (ycc__...) and a four plane one (ycck__...) that differ only in the
   --  fourth plane and in the chunk size (672 or 480), there is one Ada
   --  subprogram for both.  C's pointers into a plane or into the scratch
   --  buffer are positions (Ada indexes) here.

   --------------
   -- Geometry --
   --------------

   --  The largest width or height of a source plane (C: 0x10000).
   Max_Size : constant := 16#1_0000#;

   --  How much coarser than the destination a plane is in one direction
   --  (C: inv_h, inv_v): 1 for full resolution, up to 4.
   subtype Inverse is Index range 1 .. 4;

   --  0 stands for "not a whole number" or "no such plane".
   subtype Inverse_Or_0 is Index range 0 .. 4;

   --  Max / F if that is a whole number in 1 .. 4, else 0.
   function Exact_Inverse (Max, F : U8) return Inverse_Or_0 is
     (if F in 1 .. 4 and then Max in 1 .. 4 and then Max mod F = 0
      then Index (Max / F)
      else 0);

   --  A / Inv, as a case so that the provers see a constant divisor.
   function Div (A : Index; Inv : Inverse) return Index is
     (case Inv is
        when 1 => A,
        when 2 => A / 2,
        when 3 => A / 3,
        when 4 => A / 4);

   --  C: the upsample functions (ycc__upsample_inv_*), as chosen from the
   --  upfuncs table.  The libjpeg and libwebp forms of the h2v2 triangle
   --  filter differ in the rounding constant, Geometry.OC.
   type Upsample_Func is
     (H1VN_Box,        --  the samples as they are; nothing is written
      H2VN_Box,        --  each sample twice
      H3VN_Box,        --  each sample three times
      H4VN_Box,        --  each sample four times
      H1V2_Triangle,   --  triangle filter, vertically
      H2V1_Triangle,   --  triangle filter, horizontally
      H2V2_Triangle);  --  triangle filter, both

   subtype Vertical_Triangle is Upsample_Func
   with Static_Predicate => Vertical_Triangle in H1V2_Triangle | H2V2_Triangle;

   --  C: wuffs_private_impl__swizzle_has_triangle_upsampler.
   function Has_Triangle_Upsampler (Inv_H, Inv_V : Inverse_Or_0) return Boolean is
     ((Inv_H = 1 and then Inv_V = 2)
      or else (Inv_H = 2 and then Inv_V in 1 | 2));

   --  C: upfuncs[inv_h - 1][inv_v - 1], where upfuncs is the table
   --  ycc__upsample_funcs (box filters only) with, if Triangle, the three
   --  triangle filters put in.
   function Choose_Upsample_Func
     (Inv_H, Inv_V : Inverse; Triangle : Boolean) return Upsample_Func
   is
     (if Triangle and then Inv_H = 1 and then Inv_V = 2 then H1V2_Triangle
      elsif Triangle and then Inv_H = 2 and then Inv_V = 1 then H2V1_Triangle
      elsif Triangle and then Inv_H = 2 and then Inv_V = 2 then H2V2_Triangle
      else (case Inv_H is
              when 1 => H1VN_Box,
              when 2 => H2VN_Box,
              when 3 => H3VN_Box,
              when 4 => H4VN_Box));

   type Plane is record
      T     : Table;
      Inv_H : Inverse       := 1;
      Inv_V : Inverse       := 1;
      Up    : Upsample_Func := H1VN_Box;
   end record;

   subtype Chunk_Size is Index
   with Static_Predicate => Chunk_Size in 480 | 672;

   subtype Coordinate is Index range 0 .. 16#FFFF#;

   --  The part of the call that does not depend on the plane.
   type Geometry is record
      X_Min  : Coordinate := 0;    --  first column and row converted
      Y_Min  : Coordinate := 0;
      X_End  : Coordinate := 0;    --  one past the last, clipped to the buffer
      Y_End  : Coordinate := 0;
      Chunk  : Chunk_Size := 672;  --  pixels upsampled and converted at a time
      Half_W : Index      := 0;    --  C: half_width_for_2to1
      Half_H : Index      := 0;    --  C: half_height_for_2to1
      OC     : Natural range 7 .. 8 := 8;  --  C: odd_column_rounding
   end record;

   --  The size of the scratch buffer that the code below relies on, and
   --  the offset in it of plane K's section.
   Scratch_Length : constant := Scratch_Buffer_Length;

   --  What the row code needs to know about a plane to stay within its
   --  array: the plane is at offset 0 of an array of Length samples and
   --  covers the rectangle; and for the triangle filters, the rectangle
   --  starts at the origin and the neighbouring samples and rows that they
   --  read exist.
   function Plane_OK (P : Plane; G : Geometry; Length : Array_Length) return Boolean is
     (P.T.Offset = 0
      and then Has_Elements (P.T)
      and then P.T.Width <= Max_Size
      and then P.T.Height <= Max_Size
      and then Fits (P.T, Length)
      and then G.X_Min < G.X_End
      and then G.Y_Min < G.Y_End
      and then G.X_End - G.X_Min <= P.T.Width * P.Inv_H
      and then G.Y_End - G.Y_Min <= P.T.Height * P.Inv_V
      and then
        (case P.Up is
           when H1VN_Box      => P.Inv_H = 1,
           when H2VN_Box      => P.Inv_H = 2,
           when H3VN_Box      => P.Inv_H = 3,
           when H4VN_Box      => P.Inv_H = 4,
           when H1V2_Triangle =>
             P.Inv_H = 1 and then P.Inv_V = 2
             and then G.X_Min = 0 and then G.Y_Min = 0
             and then (G.Y_End < 2 * P.T.Height or else G.Y_End = 2 * G.Half_H),
           when H2V1_Triangle =>
             P.Inv_H = 2 and then P.Inv_V = 1
             and then G.X_Min = 0 and then G.Y_Min = 0
             and then G.Half_W <= P.T.Width,
           when H2V2_Triangle =>
             P.Inv_H = 2 and then P.Inv_V = 2
             and then G.X_Min = 0 and then G.Y_Min = 0
             and then G.Half_W <= P.T.Width
             and then (G.Y_End < 2 * P.T.Height or else G.Y_End = 2 * G.Half_H)));

   --  If A < W * Inv then Div (A, Inv) < W.
   procedure Lemma_Div (A, W : Index; Inv : Inverse) with
     Ghost,
     Pre  => W <= Max_Size and then A < W * Inv,
     Post => Div (A, Inv) < W;

   --  If A whole Bs fit in C, then A is at most C / B.
   procedure Lemma_Div_Lower (A, B, C : Offset) with
     Ghost,
     Pre  => A >= 0 and then B > 0 and then C >= 0
       and then A <= 16#1_0000# and then B <= 16#1_0000_0000#
       and then A * B <= C,
     Post => A <= C / B;

   --  About one chunk of one plane.  A is how far the chunk starts from
   --  the rectangle's left edge (a multiple of 12, as the chunk sizes are,
   --  and so of every Inv), B is the chunk's width in pixels and W the
   --  plane's width.  The chunk's Div (B + Inv - 1, Inv) samples, starting
   --  at sample Div (A, Inv), exist, and upsampled they fit in a section of
   --  the scratch buffer.
   procedure Lemma_Chunk (A, B, W : Index; Inv : Inverse; Chunk : Chunk_Size) with
     Ghost,
     Pre  => A mod 12 = 0 and then B in 1 .. Chunk
       and then W <= Max_Size and then A + B <= W * Inv,
     Post => Div (B + Inv - 1, Inv) >= 1
       and then Div (A, Inv) + Div (B + Inv - 1, Inv) <= W
       and then Div (B + Inv - 1, Inv) * Inv <= Chunk
       and then Div (B + Inv - 1, Inv) * Inv >= B
       and then (if A > 0 then Div (A, Inv) >= 1);

   --  A plane halved vertically, of H rows, in a rectangle of DY rows of
   --  which Y_End are converted: unless fewer than 2 * H rows are converted,
   --  the last one is the last of the image.
   procedure Lemma_Last_Row (Y_End, DY, H, Half_H : Index) with
     Ghost,
     Pre  => Y_End <= DY and then DY <= 2 * H and then H <= Max_Size
       and then Half_H = (DY + 1) / 2,
     Post => Y_End < 2 * H or else Y_End = 2 * Half_H;

   ---------------
   -- Lemma_Div --
   ---------------

   procedure Lemma_Div (A, W : Index; Inv : Inverse) is
   begin
      case Inv is
         when 1 => pragma Assert (A < W);
         when 2 => pragma Assert (A < W * 2);
         when 3 => pragma Assert (A < W * 3);
         when 4 => pragma Assert (A < W * 4);
      end case;
   end Lemma_Div;

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
   -- Lemma_Last_Row --
   --------------------

   procedure Lemma_Last_Row (Y_End, DY, H, Half_H : Index) is
   begin
      if Y_End >= 2 * H then
         pragma Assert (DY = 2 * H);
         pragma Assert (Half_H = H);
      end if;
   end Lemma_Last_Row;

   -----------------
   -- Lemma_Chunk --
   -----------------

   procedure Lemma_Chunk (A, B, W : Index; Inv : Inverse; Chunk : Chunk_Size) is
   begin
      case Inv is
         when 1 =>
            pragma Assert (A + B <= W);
         when 2 =>
            pragma Assert (A mod 2 = 0 and then Chunk mod 2 = 0);
            pragma Assert (A + B <= W * 2);
            pragma Assert (A / 2 + (B + 1) / 2 <= W);
            pragma Assert (((B + 1) / 2) * 2 <= Chunk);
         when 3 =>
            pragma Assert (A mod 3 = 0 and then Chunk mod 3 = 0);
            pragma Assert (A + B <= W * 3);
            pragma Assert (A / 3 + (B + 2) / 3 <= W);
            pragma Assert (((B + 2) / 3) * 3 <= Chunk);
         when 4 =>
            pragma Assert (A mod 4 = 0 and then Chunk mod 4 = 0);
            pragma Assert (A + B <= W * 4);
            pragma Assert (A / 4 + (B + 3) / 4 <= W);
            pragma Assert (((B + 3) / 4) * 4 <= Chunk);
      end case;
   end Lemma_Chunk;

   --  C: wuffs_private_impl__swizzle_flattened_length.
   function Flattened_Length (S : Source_Plane) return Offset is
     (if S.Height = 0 then 0
      else (Offset (S.Height) - 1) * Offset (S.Stride) + Offset (S.Width))
   with Pre => S.Width <= Max_Size and then S.Height <= Max_Size;

   --  The description of source plane S that the row code uses, given what
   --  Swizzle_YCCK has checked about it.
   function Make_Plane
     (S        : Source_Plane;
      Inv_H    : Inverse;
      Inv_V    : Inverse;
      Triangle : Boolean;
      G        : Geometry;
      Length   : Array_Length) return Plane
   with
     Pre  => S.Width <= Max_Size and then S.Height <= Max_Size
       and then Length >= Flattened_Length (S)
       and then G.X_Min < G.X_End
       and then G.Y_Min < G.Y_End
       and then G.X_End - G.X_Min <= Index (S.Width) * Inv_H
       and then G.Y_End - G.Y_Min <= Index (S.Height) * Inv_V
       and then (if Triangle then G.X_Min = 0 and then G.Y_Min = 0)
       and then (if Inv_H = 2 then G.Half_W <= Index (S.Width))
       and then (if Inv_V = 2 and then Triangle
                 then G.Y_End < 2 * Index (S.Height) or else G.Y_End = 2 * G.Half_H),
     Post => Plane_OK (Make_Plane'Result, G, Length)
       and then Make_Plane'Result.Up = Choose_Upsample_Func (Inv_H, Inv_V, Triangle);

   ----------------
   -- Make_Plane --
   ----------------

   function Make_Plane
     (S        : Source_Plane;
      Inv_H    : Inverse;
      Inv_V    : Inverse;
      Triangle : Boolean;
      G        : Geometry;
      Length   : Array_Length) return Plane
   is
      pragma Unreferenced (G);
      P : constant Plane :=
        (T     => (Offset => 0,
                   Width  => Index (S.Width),
                   Height => Index (S.Height),
                   Stride => Index (S.Stride)),
         Inv_H => Inv_H,
         Inv_V => Inv_V,
         Up    => Choose_Upsample_Func (Inv_H, Inv_V, Triangle));
   begin
      pragma Assert (P.T.Width >= 1 and then P.T.Height >= 1);
      pragma Assert (Length >= (P.T.Height - 1) * P.T.Stride + P.T.Width);
      if P.T.Stride > 0 then
         Lemma_Div_Lower (P.T.Height - 1, P.T.Stride, Length - P.T.Width);
      end if;
      pragma Assert (Fits (P.T, Length));
      return P;
   end Make_Plane;

   ----------------
   -- Upsampling --
   ----------------

   subtype Sample_Value is Natural range 0 .. 255;

   --  The most samples in a chunk.
   subtype Source_Length is Index range 1 .. 672;

   --  In all the upsample procedures: Dst is the scratch buffer and D the
   --  position in it of the plane's section (C: dst_ptr); Src is the plane
   --  and S the position in it of the chunk's first sample (C:
   --  src_ptr_major); Src_Len is the number of samples.  Sample J of the
   --  chunk becomes the Inv_H bytes from D + Inv_H * J.  (The C functions
   --  walk pointers dp and sp; here both are computed from J.)

   --  C: ycc__upsample_inv_h2vn_box.
   procedure Upsample_Inv_H2VN_Box
     (Dst     : in out Bytes;
      D       : Index;
      Src     : Bytes;
      S       : Index;
      Src_Len : Source_Length)
   with
     Pre => Has (Dst, D, 2 * Src_Len) and then Has (Src, S, Src_Len);

   --  C: ycc__upsample_inv_h3vn_box.
   procedure Upsample_Inv_H3VN_Box
     (Dst     : in out Bytes;
      D       : Index;
      Src     : Bytes;
      S       : Index;
      Src_Len : Source_Length)
   with
     Pre => Has (Dst, D, 3 * Src_Len) and then Has (Src, S, Src_Len);

   --  C: ycc__upsample_inv_h4vn_box.
   procedure Upsample_Inv_H4VN_Box
     (Dst     : in out Bytes;
      D       : Index;
      Src     : Bytes;
      S       : Index;
      Src_Len : Source_Length)
   with
     Pre => Has (Dst, D, 4 * Src_Len) and then Has (Src, S, Src_Len);

   --  C: ycc__upsample_inv_h1v2_triangle.  S_Minor is the position of the
   --  chunk's first sample in the other row that contributes.
   procedure Upsample_Inv_H1V2_Triangle
     (Dst       : in out Bytes;
      D         : Index;
      Src       : Bytes;
      S_Major   : Index;
      S_Minor   : Index;
      Src_Len   : Source_Length;
      H1V2_Bias : Natural)
   with
     Pre => H1V2_Bias <= 2
       and then Has (Dst, D, Src_Len)
       and then Has (Src, S_Major, Src_Len)
       and then Has (Src, S_Minor, Src_Len);

   --  C: ycc__upsample_inv_h2v1_triangle.  Unless First_Column, the sample
   --  before the chunk's first is read; unless Last_Column, the sample after
   --  its last.
   procedure Upsample_Inv_H2V1_Triangle
     (Dst          : in out Bytes;
      D            : Index;
      Src          : Bytes;
      S            : Index;
      Src_Len      : Source_Length;
      First_Column : Boolean;
      Last_Column  : Boolean)
   with
     Pre => Has (Dst, D, 2 * Src_Len)
       and then Has (Src, S, Src_Len)
       and then (First_Column or else S > Src'First)
       and then (Last_Column or else Has (Src, S, Src_Len + 1));

   --  C: ycc__upsample_inv_h2v2_triangle (and its two callers, ..._libjpeg
   --  with Odd_Column_Rounding 7 and ..._libwebp with 8).
   procedure Upsample_Inv_H2V2_Triangle
     (Dst                 : in out Bytes;
      D                   : Index;
      Src                 : Bytes;
      S_Major             : Index;
      S_Minor             : Index;
      Src_Len             : Source_Length;
      First_Column        : Boolean;
      Last_Column         : Boolean;
      Odd_Column_Rounding : Natural)
   with
     Pre => Odd_Column_Rounding <= 8
       and then Has (Dst, D, 2 * Src_Len)
       and then Has (Src, S_Major, Src_Len)
       and then Has (Src, S_Minor, Src_Len)
       and then (First_Column
                 or else (S_Major > Src'First and then S_Minor > Src'First))
       and then (Last_Column
                 or else (Has (Src, S_Major, Src_Len + 1)
                          and then Has (Src, S_Minor, Src_Len + 1)));

   ---------------------------
   -- Upsample_Inv_H2VN_Box --
   ---------------------------

   procedure Upsample_Inv_H2VN_Box
     (Dst     : in out Bytes;
      D       : Index;
      Src     : Bytes;
      S       : Index;
      Src_Len : Source_Length)
   is
      SV : U8;
   begin
      for J in 0 .. Src_Len - 1 loop
         SV := Src (S + J);
         Dst (D + 2 * J) := SV;
         Dst (D + 2 * J + 1) := SV;
      end loop;
   end Upsample_Inv_H2VN_Box;

   ---------------------------
   -- Upsample_Inv_H3VN_Box --
   ---------------------------

   procedure Upsample_Inv_H3VN_Box
     (Dst     : in out Bytes;
      D       : Index;
      Src     : Bytes;
      S       : Index;
      Src_Len : Source_Length)
   is
      SV : U8;
   begin
      for J in 0 .. Src_Len - 1 loop
         SV := Src (S + J);
         Dst (D + 3 * J) := SV;
         Dst (D + 3 * J + 1) := SV;
         Dst (D + 3 * J + 2) := SV;
      end loop;
   end Upsample_Inv_H3VN_Box;

   ---------------------------
   -- Upsample_Inv_H4VN_Box --
   ---------------------------

   procedure Upsample_Inv_H4VN_Box
     (Dst     : in out Bytes;
      D       : Index;
      Src     : Bytes;
      S       : Index;
      Src_Len : Source_Length)
   is
      SV : U8;
   begin
      for J in 0 .. Src_Len - 1 loop
         SV := Src (S + J);
         Dst (D + 4 * J) := SV;
         Dst (D + 4 * J + 1) := SV;
         Dst (D + 4 * J + 2) := SV;
         Dst (D + 4 * J + 3) := SV;
      end loop;
   end Upsample_Inv_H4VN_Box;

   --------------------------------
   -- Upsample_Inv_H1V2_Triangle --
   --------------------------------

   procedure Upsample_Inv_H1V2_Triangle
     (Dst       : in out Bytes;
      D         : Index;
      Src       : Bytes;
      S_Major   : Index;
      S_Minor   : Index;
      Src_Len   : Source_Length;
      H1V2_Bias : Natural)
   is
   begin
      for J in 0 .. Src_Len - 1 loop
         Dst (D + J) :=
           U8 ((3 * Sample_Value (Src (S_Major + J))
                + Sample_Value (Src (S_Minor + J)) + H1V2_Bias) / 4);
      end loop;
   end Upsample_Inv_H1V2_Triangle;

   --------------------------------
   -- Upsample_Inv_H2V1_Triangle --
   --------------------------------

   procedure Upsample_Inv_H2V1_Triangle
     (Dst          : in out Bytes;
      D            : Index;
      Src          : Bytes;
      S            : Index;
      Src_Len      : Source_Length;
      First_Column : Boolean;
      Last_Column  : Boolean)
   is
      --  The samples that C's middle loop handles: all but the first of a
      --  First_Column chunk and the last of a Last_Column chunk.
      J_First : constant Index := (if First_Column then 1 else 0);
      J_Last  : constant Offset := Src_Len - 1 - (if Last_Column then 1 else 0);
      SV      : Sample_Value;
      SVM1    : Sample_Value;
      SVP1    : Sample_Value;
      SP      : Index;
      DP      : Index;
   begin
      if First_Column then
         SV := Sample_Value (Src (S));
         if Src_Len = 1 and then Last_Column then
            Dst (D) := U8 (SV);
            Dst (D + 1) := U8 (SV);
            return;
         end if;
         SVP1 := Sample_Value (Src (S + 1));
         Dst (D) := U8 (SV);
         Dst (D + 1) := U8 ((3 * SV + SVP1 + 2) / 4);
         if Src_Len = 1 then
            return;
         end if;
      end if;

      for J in J_First .. J_Last loop
         SP := S + J;
         DP := D + 2 * J;
         SVM1 := Sample_Value (Src (SP - 1));
         SVP1 := Sample_Value (Src (SP + 1));
         SV := Sample_Value (Src (SP));
         Dst (DP) := U8 ((3 * SV + SVM1 + 1) / 4);
         Dst (DP + 1) := U8 ((3 * SV + SVP1 + 2) / 4);
      end loop;

      if Last_Column then
         SP := S + (Src_Len - 1);
         DP := D + 2 * (Src_Len - 1);
         SVM1 := Sample_Value (Src (SP - 1));
         SV := Sample_Value (Src (SP));
         Dst (DP) := U8 ((3 * SV + SVM1 + 1) / 4);
         Dst (DP + 1) := U8 (SV);
      end if;
   end Upsample_Inv_H2V1_Triangle;

   --------------------------------
   -- Upsample_Inv_H2V2_Triangle --
   --------------------------------

   procedure Upsample_Inv_H2V2_Triangle
     (Dst                 : in out Bytes;
      D                   : Index;
      Src                 : Bytes;
      S_Major             : Index;
      S_Minor             : Index;
      Src_Len             : Source_Length;
      First_Column        : Boolean;
      Last_Column         : Boolean;
      Odd_Column_Rounding : Natural)
   is
      OC      : constant Natural := Odd_Column_Rounding;
      J_First : constant Index := (if First_Column then 1 else 0);
      J_Last  : constant Offset := Src_Len - 1 - (if Last_Column then 1 else 0);
      SV      : Natural;
      Major_M1, Minor_M1, Major_P1, Minor_P1 : Sample_Value;
      SP_Major, SP_Minor, DP                 : Index;
   begin
      if First_Column then
         if Src_Len = 1 and then Last_Column then
            SV := 12 * Sample_Value (Src (S_Major)) + 4 * Sample_Value (Src (S_Minor));
            Dst (D) := U8 ((SV + 8) / 16);
            Dst (D + 1) := U8 ((SV + OC) / 16);
            return;
         end if;
         --  There is no sample before the first: it stands in for itself.
         Major_M1 := Sample_Value (Src (S_Major));
         Minor_M1 := Sample_Value (Src (S_Minor));
         Major_P1 := Sample_Value (Src (S_Major + 1));
         Minor_P1 := Sample_Value (Src (S_Minor + 1));
         SV := 9 * Sample_Value (Src (S_Major)) + 3 * Sample_Value (Src (S_Minor));
         Dst (D) := U8 ((SV + 3 * Major_M1 + Minor_M1 + 8) / 16);
         Dst (D + 1) := U8 ((SV + 3 * Major_P1 + Minor_P1 + OC) / 16);
         if Src_Len = 1 then
            return;
         end if;
      end if;

      for J in J_First .. J_Last loop
         SP_Major := S_Major + J;
         SP_Minor := S_Minor + J;
         DP := D + 2 * J;
         Major_M1 := Sample_Value (Src (SP_Major - 1));
         Minor_M1 := Sample_Value (Src (SP_Minor - 1));
         Major_P1 := Sample_Value (Src (SP_Major + 1));
         Minor_P1 := Sample_Value (Src (SP_Minor + 1));
         SV := 9 * Sample_Value (Src (SP_Major)) + 3 * Sample_Value (Src (SP_Minor));
         Dst (DP) := U8 ((SV + 3 * Major_M1 + Minor_M1 + 8) / 16);
         Dst (DP + 1) := U8 ((SV + 3 * Major_P1 + Minor_P1 + OC) / 16);
      end loop;

      if Last_Column then
         SP_Major := S_Major + (Src_Len - 1);
         SP_Minor := S_Minor + (Src_Len - 1);
         DP := D + 2 * (Src_Len - 1);
         Major_M1 := Sample_Value (Src (SP_Major - 1));
         Minor_M1 := Sample_Value (Src (SP_Minor - 1));
         --  There is no sample after the last: it stands in for itself.
         Major_P1 := Sample_Value (Src (SP_Major));
         Minor_P1 := Sample_Value (Src (SP_Minor));
         SV := 9 * Sample_Value (Src (SP_Major)) + 3 * Sample_Value (Src (SP_Minor));
         Dst (DP) := U8 ((SV + 3 * Major_M1 + Minor_M1 + 8) / 16);
         Dst (DP + 1) := U8 ((SV + 3 * Major_P1 + Minor_P1 + OC) / 16);
      end if;
   end Upsample_Inv_H2V2_Triangle;

   --  Where a chunk's full resolution samples of one plane are (C: the
   --  pointer that an upsample function returns, up0 .. up3): in the
   --  plane's own array if From_Source (C: ..._h1vn_box returns
   --  src_ptr_major), else in the scratch buffer; at position Pos.
   type Upsampled is record
      From_Source : Boolean := False;
      Pos         : Index   := 0;
   end record;

   --  The N samples that Up refers to exist.
   function Upsampled_OK
     (Up : Upsampled; Src : Bytes; Scratch : Bytes; N : Index) return Boolean
   is
     (if Up.From_Source then Has (Src, Up.Pos, N) else Has (Scratch, Up.Pos, N))
   with Pre => N >= 1;

   --  One plane's part of one chunk: pixels X .. X_Chunk_End - 1 of a
   --  destination row whose samples come from row Major_Row of the plane
   --  (and, for the vertical triangle filters, Minor_Row).  C: the
   --  computation of src_len and of the upsample function's arguments, and
   --  the call `(*upfuncK)(...)`, in the chunk loops of
   --  ycc[k]__general__box_filter, ..._triangle_filter and
   --  ..._triangle_filter_edge_row.  Slot is the offset of the plane's
   --  section of the scratch buffer.
   --
   --  The box filter functions pass first_column = last_column = false and
   --  the triangle filter functions pass what is computed here; that is
   --  the same thing, because the upsamplers that look at the two flags are
   --  only ever chosen for the triangle filter.  C's last_column is
   --  total_src_len >= half_width_for_2to1, where total_src_len is the
   --  number of samples up to and including this chunk's: Col + Src_Len.
   procedure Upsample_Plane
     (Scratch      : in out Bytes;
      Slot         : Index;
      Src          : Bytes;
      P            : Plane;
      G            : Geometry;
      Major_Row    : Index;
      Minor_Row    : Index;
      X            : Index;
      X_Chunk_End  : Index;
      H1V2_Bias    : Natural;
      Up           : out Upsampled)
   with
     Pre  => Scratch'Length >= Scratch_Length
       and then Slot + G.Chunk <= Scratch_Length
       and then Plane_OK (P, G, Src'Length)
       and then Major_Row < P.T.Height
       and then Minor_Row < P.T.Height
       and then X in G.X_Min .. X_Chunk_End - 1
       and then X_Chunk_End <= G.X_End
       and then X_Chunk_End - X <= G.Chunk
       and then (X - G.X_Min) mod 12 = 0
       and then H1V2_Bias <= 2,
     Post => Upsampled_OK (Up, Src, Scratch, X_Chunk_End - X);

   --------------------
   -- Upsample_Plane --
   --------------------

   procedure Upsample_Plane
     (Scratch      : in out Bytes;
      Slot         : Index;
      Src          : Bytes;
      P            : Plane;
      G            : Geometry;
      Major_Row    : Index;
      Minor_Row    : Index;
      X            : Index;
      X_Chunk_End  : Index;
      H1V2_Bias    : Natural;
      Up           : out Upsampled)
   is
      Col          : constant Index := Div (X - G.X_Min, P.Inv_H);
      Src_Len      : constant Index := Div (X_Chunk_End - X + P.Inv_H - 1, P.Inv_H);
      First_Column : constant Boolean := X = 0;
      Last_Column  : constant Boolean := Col + Src_Len >= G.Half_W;
      D            : constant Index := Scratch'First + Slot;
      S_Major      : Index;
      S_Minor      : Index;
   begin
      Lemma_Chunk (X - G.X_Min, X_Chunk_End - X, P.T.Width, P.Inv_H, G.Chunk);
      S_Major := Src'First + Row_Start (P.T, Major_Row, Src'Length) + Col;
      S_Minor := Src'First + Row_Start (P.T, Minor_Row, Src'Length) + Col;
      pragma Assert (Has (Src, S_Major, Src_Len));
      pragma Assert (Has (Src, S_Minor, Src_Len));
      pragma Assert (Has (Scratch, D, G.Chunk));

      Up := (From_Source => False, Pos => D);
      case P.Up is
         when H1VN_Box =>
            Up := (From_Source => True, Pos => S_Major);
         when H2VN_Box =>
            Upsample_Inv_H2VN_Box (Scratch, D, Src, S_Major, Src_Len);
         when H3VN_Box =>
            Upsample_Inv_H3VN_Box (Scratch, D, Src, S_Major, Src_Len);
         when H4VN_Box =>
            Upsample_Inv_H4VN_Box (Scratch, D, Src, S_Major, Src_Len);
         when H1V2_Triangle =>
            Upsample_Inv_H1V2_Triangle
              (Scratch, D, Src, S_Major, S_Minor, Src_Len, H1V2_Bias);
         when H2V1_Triangle =>
            pragma Assert (if not First_Column then Col >= 1);
            pragma Assert (if not Last_Column then Col + Src_Len < P.T.Width);
            Upsample_Inv_H2V1_Triangle
              (Scratch, D, Src, S_Major, Src_Len, First_Column, Last_Column);
         when H2V2_Triangle =>
            pragma Assert (if not First_Column then Col >= 1);
            pragma Assert (if not Last_Column then Col + Src_Len < P.T.Width);
            Upsample_Inv_H2V2_Triangle
              (Scratch, D, Src, S_Major, S_Minor, Src_Len, First_Column, Last_Column,
               G.OC);
      end case;
   end Upsample_Plane;

   ----------------
   -- Conversion --
   ----------------

   --  C: the convert functions (the conv3func or conv4func chosen).
   type Convert_Func is
     (RGB_Convert_3_General,
      YCC_BT601FR_Convert_3_General,
      YCC_BT601FR_Convert_3_BGRX,
      YCC_BT601FR_Convert_3_RGBX,
      YCC_BT601SR_Convert_3_General,
      YCC_BT601SR_Convert_3_BGRX,
      YCC_BT601SR_Convert_3_RGBX,
      YCCA_BT601SR_Src_Convert_4_General,
      YCCA_BT601SR_Src_Convert_4_BGRA_Premul,
      YCCA_BT601SR_Src_Over_Convert_4_General,
      YCCA_BT601SR_Src_Over_Convert_4_BGRA_Premul,
      CMYK_Convert_4_General,
      YCCK_Convert_4_General);

   subtype Convert_General_Func is Convert_Func
   with Static_Predicate =>
     Convert_General_Func in RGB_Convert_3_General | YCC_BT601FR_Convert_3_General
       | YCC_BT601SR_Convert_3_General | YCCA_BT601SR_Src_Convert_4_General
       | YCCA_BT601SR_Src_Over_Convert_4_General | CMYK_Convert_4_General
       | YCCK_Convert_4_General;

   subtype Convert_3_XXXX_Func is Convert_Func
   with Static_Predicate =>
     Convert_3_XXXX_Func in YCC_BT601FR_Convert_3_BGRX | YCC_BT601FR_Convert_3_RGBX
       | YCC_BT601SR_Convert_3_BGRX | YCC_BT601SR_Convert_3_RGBX;

   subtype Convert_4_BGRA_Premul_Func is Convert_Func
   with Static_Predicate =>
     Convert_4_BGRA_Premul_Func in YCCA_BT601SR_Src_Convert_4_BGRA_Premul
       | YCCA_BT601SR_Src_Over_Convert_4_BGRA_Premul;

   subtype Convert_4_Func is Convert_Func
     range YCCA_BT601SR_Src_Convert_4_General .. YCCK_Convert_4_General;

   --  The convert functions that write four bytes per pixel themselves.
   subtype Convert_Fast_Func is Convert_Func
   with Static_Predicate =>
     Convert_Fast_Func in Convert_3_XXXX_Func | Convert_4_BGRA_Premul_Func;

   --  C: the body of wuffs_private_impl__swizzle_cmyk__convert_4_general:
   --  R, G, B scaled by W / 255, rounded.
   function Scale_By_K (R, G, B, W : U32) return U32 is
     (16#FF00_0000#
      or Shift_Left ((R * W + 16#7F#) / 16#FF#, 16)
      or Shift_Left ((G * W + 16#7F#) / 16#FF#, 8)
      or ((B * W + 16#7F#) / 16#FF#));

   --  What all the convert procedures need of the destination: a valid
   --  buffer, in which pixels X .. X_End - 1 of row Y exist.
   function Destination_OK
     (PB             : Pixel_Buffer;
      Pixels_Length  : Array_Length;
      Palette_Length : Array_Length;
      X, X_End, Y    : Index) return Boolean
   is
     (Is_Valid (PB, Pixels_Length, Palette_Length)
      and then Is_Supported (PB.Pixcfg.Pixfmt)
      and then Bytes_Per_Pixel (PB.Pixcfg.Pixfmt) in 1 .. 8
      and then X < X_End
      and then X_End <= Index (PB.Pixcfg.Width)
      and then Y < Index (PB.Pixcfg.Height));

   --  In all the convert procedures: pixels X .. X_End - 1 of row Y are
   --  written; pixel X + I comes from sample I of each plane, which is
   --  element UK + I of UpK (C: the pointers up0 .. up3).

   --  C: the seven ..._general convert functions (rgb__convert_3_general,
   --  ycc_bt601fr__convert_3_general, ycc_bt601sr__convert_3_general,
   --  ycca_bt601sr_src__convert_4_general,
   --  ycca_bt601sr_src_over__convert_4_general, cmyk__convert_4_general,
   --  ycck__convert_4_general).  They are the same loop around different
   --  colour computations: one pixel at a time through the pixel buffer's
   --  set or composite operation for whatever format it has.  The three
   --  plane ones do not read Up3.
   procedure Convert_General
     (Func               : Convert_General_Func;
      PB                 : Pixel_Buffer;
      Pixels             : in out Bytes;
      Palette            : Bytes;
      X, X_End, Y        : Index;
      Up0, Up1, Up2, Up3 : Bytes;
      U0, U1, U2, U3     : Index)
   with
     Pre => Destination_OK (PB, Pixels'Length, Palette'Length, X, X_End, Y)
       and then Has (Up0, U0, X_End - X)
       and then Has (Up1, U1, X_End - X)
       and then Has (Up2, U2, X_End - X)
       and then Has (Up3, U3, X_End - X);

   --  C: ycc_bt601fr__convert_3_bgrx, ycc_bt601fr__convert_3_rgbx,
   --  ycc_bt601sr__convert_3_bgrx and ycc_bt601sr__convert_3_rgbx: for the
   --  destination formats of four bytes per pixel whose bytes are those of
   --  the opaque colour (little endian 0xFFRRGGBB, or 0xFFBBGGRR for rgbx).
   procedure Convert_3_XXXX
     (Func          : Convert_3_XXXX_Func;
      PB            : Pixel_Buffer;
      Pixels        : in out Bytes;
      X, X_End, Y   : Index;
      Up0, Up1, Up2 : Bytes;
      U0, U1, U2    : Index)
   with
     Pre => Destination_OK (PB, Pixels'Length, 1024, X, X_End, Y)
       and then Has_Pixel_Size (PB, 4)
       and then Has (Up0, U0, X_End - X)
       and then Has (Up1, U1, X_End - X)
       and then Has (Up2, U2, X_End - X);

   --  C: ycca_bt601sr_src__convert_4_bgra_premul and
   --  ycca_bt601sr_src_over__convert_4_bgra_premul.
   procedure Convert_4_BGRA_Premul
     (Func               : Convert_4_BGRA_Premul_Func;
      PB                 : Pixel_Buffer;
      Pixels             : in out Bytes;
      X, X_End, Y        : Index;
      Up0, Up1, Up2, Up3 : Bytes;
      U0, U1, U2, U3     : Index)
   with
     Pre => Destination_OK (PB, Pixels'Length, 1024, X, X_End, Y)
       and then Has_Pixel_Size (PB, 4)
       and then Has (Up0, U0, X_End - X)
       and then Has (Up1, U1, X_End - X)
       and then Has (Up2, U2, X_End - X)
       and then Has (Up3, U3, X_End - X);

   --  In an array with bounds First .. Last, a row of W pixels of BPP bytes
   --  each starts at Row and lies within the array: then so do the BPP
   --  bytes of its pixel number XI.
   procedure Lemma_Pixel (First, Last : Offset; Row, W, XI : Index; BPP : Pixel_Size)
   with
     Ghost,
     Pre  => First >= 0 and then Last >= -1 and then Last < Offset'Last
       and then W <= 16#FFFF_FFFF# and then XI < W
       and then Row >= First
       and then Row - First + W * BPP <= Last - First + 1,
     Post => Row + XI * BPP >= First
       and then Row + XI * BPP <= Last
       and then Last - (Row + XI * BPP) >= BPP - 1;

   -----------------
   -- Lemma_Pixel --
   -----------------

   procedure Lemma_Pixel (First, Last : Offset; Row, W, XI : Index; BPP : Pixel_Size) is
   begin
      pragma Assert (XI + 1 <= W);
      pragma Assert ((XI + 1) * BPP <= W * BPP);
      pragma Assert ((XI + 1) * BPP = XI * BPP + BPP);
      pragma Assert (Row + XI * BPP + BPP <= Last + 1);
      pragma Assert (Row + XI * BPP >= First);
   end Lemma_Pixel;

   ---------------------
   -- Convert_General --
   ---------------------

   procedure Convert_General
     (Func               : Convert_General_Func;
      PB                 : Pixel_Buffer;
      Pixels             : in out Bytes;
      Palette            : Bytes;
      X, X_End, Y        : Index;
      Up0, Up1, Up2, Up3 : Bytes;
      U0, U1, U2, U3     : Index)
   is
      BPP   : constant Pixel_Size := Index (Bytes_Per_Pixel (PB.Pixcfg.Pixfmt));
      W     : constant Index := Index (PB.Pixcfg.Width);
      Row   : constant Index := Row_Position (PB, Pixels, U32 (Y), BPP);
      Pos   : Index;
      Color : U32;
   begin
      for I in 0 .. X_End - X - 1 loop
         Lemma_Pixel (Pixels'First, Pixels'Last, Row, W, X + I, BPP);
         Pos := Row + (X + I) * BPP;
         pragma Assert (Pos >= Pixels'First and then Pos <= Pixels'Last);
         pragma Assert (Pixels'Last - Pos >= BPP - 1);
         pragma Assert (Has (Pixels, Pos, BPP));
         pragma Assert (BPP = Index (Bytes_Per_Pixel (PB.Pixcfg.Pixfmt)));
         pragma Assert (Writable (PB, Pixels, Pos, Palette'Length));
         case Func is
            when RGB_Convert_3_General =>
               Color := 16#FF00_0000# or Shift_Left (U32 (Up0 (U0 + I)), 16)
                 or Shift_Left (U32 (Up1 (U1 + I)), 8) or U32 (Up2 (U2 + I));
               Set_Color_U32_At_Position (PB, Pixels, Palette, Pos, Color);
            when YCC_BT601FR_Convert_3_General =>
               Color := YCC_BT601FR_As_Color_U32
                 (Up0 (U0 + I), Up1 (U1 + I), Up2 (U2 + I));
               Set_Color_U32_At_Position (PB, Pixels, Palette, Pos, Color);
            when YCC_BT601SR_Convert_3_General =>
               Color := YCC_BT601SR_As_Color_U32
                 (Up0 (U0 + I), Up1 (U1 + I), Up2 (U2 + I));
               Set_Color_U32_At_Position (PB, Pixels, Palette, Pos, Color);
            when YCCA_BT601SR_Src_Convert_4_General =>
               Color := YCC_BT601SR_As_Color_U32
                 (Up0 (U0 + I), Up1 (U1 + I), Up2 (U2 + I));
               Color := (Color and 16#00FF_FFFF#)
                 or Shift_Left (U32 (Up3 (U3 + I)), 24);
               Set_Color_U32_ARGB_Nonpremul_At_Position
                 (PB, Pixels, Palette, Pos, Color);
            when YCCA_BT601SR_Src_Over_Convert_4_General =>
               Color := YCC_BT601SR_As_Color_U32
                 (Up0 (U0 + I), Up1 (U1 + I), Up2 (U2 + I));
               Color := (Color and 16#00FF_FFFF#)
                 or Shift_Left (U32 (Up3 (U3 + I)), 24);
               Composite_Color_U32_Nonpremul_At_Position
                 (PB, Pixels, Palette, Pos, Color);
            when CMYK_Convert_4_General =>
               Color := Scale_By_K
                 (U32 (Up0 (U0 + I)), U32 (Up1 (U1 + I)), U32 (Up2 (U2 + I)),
                  U32 (Up3 (U3 + I)));
               Set_Color_U32_At_Position (PB, Pixels, Palette, Pos, Color);
            when YCCK_Convert_4_General =>
               Color := YCC_BT601FR_As_Color_U32
                 (Up0 (U0 + I), Up1 (U1 + I), Up2 (U2 + I));
               Color := Scale_By_K
                 (16#FF# - Ch8 (Color, 16), 16#FF# - Ch8 (Color, 8),
                  16#FF# - Ch8 (Color, 0), U32 (Up3 (U3 + I)));
               Set_Color_U32_At_Position (PB, Pixels, Palette, Pos, Color);
         end case;
      end loop;
   end Convert_General;

   --------------------
   -- Convert_3_XXXX --
   --------------------

   procedure Convert_3_XXXX
     (Func          : Convert_3_XXXX_Func;
      PB            : Pixel_Buffer;
      Pixels        : in out Bytes;
      X, X_End, Y   : Index;
      Up0, Up1, Up2 : Bytes;
      U0, U1, U2    : Index)
   is
      Row   : constant Index := Row_Position (PB, Pixels, U32 (Y), 4);
      D     : constant Index := Row + 4 * X;
      Pos   : Index;
      Color : U32;
   begin
      --  One loop per C function; each ends with the four byte stores of
      --  C's wuffs_base__poke_u32le__no_bounds_check.
      case Func is
         when YCC_BT601FR_Convert_3_BGRX =>
            for I in 0 .. X_End - X - 1 loop
               Color := YCC_BT601FR_As_Color_U32
                 (Up0 (U0 + I), Up1 (U1 + I), Up2 (U2 + I));
               Pos := D + 4 * I;
               Pixels (Pos) := U8 (Color and 16#FF#);
               Pixels (Pos + 1) := U8 (Shift_Right (Color, 8) and 16#FF#);
               Pixels (Pos + 2) := U8 (Shift_Right (Color, 16) and 16#FF#);
               Pixels (Pos + 3) := U8 (Shift_Right (Color, 24));
            end loop;
         when YCC_BT601FR_Convert_3_RGBX =>
            for I in 0 .. X_End - X - 1 loop
               Color := YCC_BT601FR_As_Color_U32_ABGR
                 (Up0 (U0 + I), Up1 (U1 + I), Up2 (U2 + I));
               Pos := D + 4 * I;
               Pixels (Pos) := U8 (Color and 16#FF#);
               Pixels (Pos + 1) := U8 (Shift_Right (Color, 8) and 16#FF#);
               Pixels (Pos + 2) := U8 (Shift_Right (Color, 16) and 16#FF#);
               Pixels (Pos + 3) := U8 (Shift_Right (Color, 24));
            end loop;
         when YCC_BT601SR_Convert_3_BGRX =>
            for I in 0 .. X_End - X - 1 loop
               Color := YCC_BT601SR_As_Color_U32
                 (Up0 (U0 + I), Up1 (U1 + I), Up2 (U2 + I));
               Pos := D + 4 * I;
               Pixels (Pos) := U8 (Color and 16#FF#);
               Pixels (Pos + 1) := U8 (Shift_Right (Color, 8) and 16#FF#);
               Pixels (Pos + 2) := U8 (Shift_Right (Color, 16) and 16#FF#);
               Pixels (Pos + 3) := U8 (Shift_Right (Color, 24));
            end loop;
         when YCC_BT601SR_Convert_3_RGBX =>
            for I in 0 .. X_End - X - 1 loop
               Color := YCC_BT601SR_As_Color_U32_ABGR
                 (Up0 (U0 + I), Up1 (U1 + I), Up2 (U2 + I));
               Pos := D + 4 * I;
               Pixels (Pos) := U8 (Color and 16#FF#);
               Pixels (Pos + 1) := U8 (Shift_Right (Color, 8) and 16#FF#);
               Pixels (Pos + 2) := U8 (Shift_Right (Color, 16) and 16#FF#);
               Pixels (Pos + 3) := U8 (Shift_Right (Color, 24));
            end loop;
      end case;
   end Convert_3_XXXX;

   ---------------------------
   -- Convert_4_BGRA_Premul --
   ---------------------------

   procedure Convert_4_BGRA_Premul
     (Func               : Convert_4_BGRA_Premul_Func;
      PB                 : Pixel_Buffer;
      Pixels             : in out Bytes;
      X, X_End, Y        : Index;
      Up0, Up1, Up2, Up3 : Bytes;
      U0, U1, U2, U3     : Index)
   is
      Row       : constant Index := Row_Position (PB, Pixels, U32 (Y), 4);
      D         : constant Index := Row + 4 * X;
      Pos       : Index;
      Color     : U32;
      Dst_Color : U32;
   begin
      for I in 0 .. X_End - X - 1 loop
         Color := YCC_BT601SR_As_Color_U32 (Up0 (U0 + I), Up1 (U1 + I), Up2 (U2 + I));
         Color := (Color and 16#00FF_FFFF#) or Shift_Left (U32 (Up3 (U3 + I)), 24);
         Pos := D + 4 * I;
         if Func = YCCA_BT601SR_Src_Convert_4_BGRA_Premul then
            Dst_Color := Nonpremul_U32_As_Premul_U32 (Color);
         else
            Dst_Color := Composite_Premul_Nonpremul_U32_Axxx
              (Peek_U32LE (Pixels, Pos), Color);
         end if;
         Poke_U32LE (Pixels, Pos, Dst_Color);
      end loop;
   end Convert_4_BGRA_Premul;

   --  C: the call `(*conv3func)(dst, x, end, y, up0, up1, up2)` or
   --  `(*conv4func)(dst, x, end, y, up0, up1, up2, up3)`.
   procedure Convert
     (Func               : Convert_Func;
      PB                 : Pixel_Buffer;
      Pixels             : in out Bytes;
      Palette            : Bytes;
      X, X_End, Y        : Index;
      Up0, Up1, Up2, Up3 : Bytes;
      U0, U1, U2, U3     : Index)
   with
     Pre => Destination_OK (PB, Pixels'Length, Palette'Length, X, X_End, Y)
       and then (if Func in Convert_Fast_Func then Has_Pixel_Size (PB, 4))
       and then Has (Up0, U0, X_End - X)
       and then Has (Up1, U1, X_End - X)
       and then Has (Up2, U2, X_End - X)
       and then Has (Up3, U3, X_End - X);

   -------------
   -- Convert --
   -------------

   procedure Convert
     (Func               : Convert_Func;
      PB                 : Pixel_Buffer;
      Pixels             : in out Bytes;
      Palette            : Bytes;
      X, X_End, Y        : Index;
      Up0, Up1, Up2, Up3 : Bytes;
      U0, U1, U2, U3     : Index)
   is
   begin
      case Func is
         when Convert_General_Func =>
            Convert_General
              (Func, PB, Pixels, Palette, X, X_End, Y, Up0, Up1, Up2, Up3,
               U0, U1, U2, U3);
         when Convert_3_XXXX_Func =>
            Convert_3_XXXX (Func, PB, Pixels, X, X_End, Y, Up0, Up1, Up2, U0, U1, U2);
         when Convert_4_BGRA_Premul_Func =>
            Convert_4_BGRA_Premul
              (Func, PB, Pixels, X, X_End, Y, Up0, Up1, Up2, Up3, U0, U1, U2, U3);
      end case;
   end Convert;

   --  Convert, with each plane's samples taken from where its Upsampled
   --  says: the plane's own array or the scratch buffer.  (In C that is
   --  just the pointer; here the array has to be named, hence the sixteen
   --  calls.)  For a three plane function, Up3 is given as Up2.
   procedure Convert_Chunk
     (Func                   : Convert_Func;
      PB                     : Pixel_Buffer;
      Pixels                 : in out Bytes;
      Palette                : Bytes;
      Scratch                : Bytes;
      Src0, Src1, Src2, Src3 : Bytes;
      X, X_End, Y            : Index;
      Up0, Up1, Up2, Up3     : Upsampled)
   with
     Pre => Destination_OK (PB, Pixels'Length, Palette'Length, X, X_End, Y)
       and then (if Func in Convert_Fast_Func then Has_Pixel_Size (PB, 4))
       and then Upsampled_OK (Up0, Src0, Scratch, X_End - X)
       and then Upsampled_OK (Up1, Src1, Scratch, X_End - X)
       and then Upsampled_OK (Up2, Src2, Scratch, X_End - X)
       and then Upsampled_OK (Up3, Src3, Scratch, X_End - X);

   -------------------
   -- Convert_Chunk --
   -------------------

   procedure Convert_Chunk
     (Func                   : Convert_Func;
      PB                     : Pixel_Buffer;
      Pixels                 : in out Bytes;
      Palette                : Bytes;
      Scratch                : Bytes;
      Src0, Src1, Src2, Src3 : Bytes;
      X, X_End, Y            : Index;
      Up0, Up1, Up2, Up3     : Upsampled)
   is
      U0 : constant Index := Up0.Pos;
      U1 : constant Index := Up1.Pos;
      U2 : constant Index := Up2.Pos;
      U3 : constant Index := Up3.Pos;
   begin
      if Up0.From_Source then
         if Up1.From_Source then
            if Up2.From_Source then
               if Up3.From_Source then
                  Convert (Func, PB, Pixels, Palette, X, X_End, Y,
                           Src0, Src1, Src2, Src3, U0, U1, U2, U3);
               else
                  Convert (Func, PB, Pixels, Palette, X, X_End, Y,
                           Src0, Src1, Src2, Scratch, U0, U1, U2, U3);
               end if;
            elsif Up3.From_Source then
               Convert (Func, PB, Pixels, Palette, X, X_End, Y,
                        Src0, Src1, Scratch, Src3, U0, U1, U2, U3);
            else
               Convert (Func, PB, Pixels, Palette, X, X_End, Y,
                        Src0, Src1, Scratch, Scratch, U0, U1, U2, U3);
            end if;
         elsif Up2.From_Source then
            if Up3.From_Source then
               Convert (Func, PB, Pixels, Palette, X, X_End, Y,
                        Src0, Scratch, Src2, Src3, U0, U1, U2, U3);
            else
               Convert (Func, PB, Pixels, Palette, X, X_End, Y,
                        Src0, Scratch, Src2, Scratch, U0, U1, U2, U3);
            end if;
         elsif Up3.From_Source then
            Convert (Func, PB, Pixels, Palette, X, X_End, Y,
                     Src0, Scratch, Scratch, Src3, U0, U1, U2, U3);
         else
            Convert (Func, PB, Pixels, Palette, X, X_End, Y,
                     Src0, Scratch, Scratch, Scratch, U0, U1, U2, U3);
         end if;
      elsif Up1.From_Source then
         if Up2.From_Source then
            if Up3.From_Source then
               Convert (Func, PB, Pixels, Palette, X, X_End, Y,
                        Scratch, Src1, Src2, Src3, U0, U1, U2, U3);
            else
               Convert (Func, PB, Pixels, Palette, X, X_End, Y,
                        Scratch, Src1, Src2, Scratch, U0, U1, U2, U3);
            end if;
         elsif Up3.From_Source then
            Convert (Func, PB, Pixels, Palette, X, X_End, Y,
                     Scratch, Src1, Scratch, Src3, U0, U1, U2, U3);
         else
            Convert (Func, PB, Pixels, Palette, X, X_End, Y,
                     Scratch, Src1, Scratch, Scratch, U0, U1, U2, U3);
         end if;
      elsif Up2.From_Source then
         if Up3.From_Source then
            Convert (Func, PB, Pixels, Palette, X, X_End, Y,
                     Scratch, Scratch, Src2, Src3, U0, U1, U2, U3);
         else
            Convert (Func, PB, Pixels, Palette, X, X_End, Y,
                     Scratch, Scratch, Src2, Scratch, U0, U1, U2, U3);
         end if;
      elsif Up3.From_Source then
         Convert (Func, PB, Pixels, Palette, X, X_End, Y,
                  Scratch, Scratch, Scratch, Src3, U0, U1, U2, U3);
      else
         Convert (Func, PB, Pixels, Palette, X, X_End, Y,
                  Scratch, Scratch, Scratch, Scratch, U0, U1, U2, U3);
      end if;
   end Convert_Chunk;

   -------------
   -- Filters --
   -------------

   --  The rows of the source planes that one destination row is made from
   --  (C: the pointers srcK_major and srcK_minor, as row numbers).
   type Row_Pair is record
      Major : Index := 0;
      Minor : Index := 0;
   end record;

   type Row_Pairs is array (0 .. 3) of Row_Pair;

   --  What the filter procedures need: a destination that the rectangle
   --  lies in, a scratch buffer, and planes that cover the rectangle (the
   --  fourth only for a four plane conversion, whose chunks are 480 pixels
   --  so that four sections fit in the scratch buffer).
   function Filter_OK
     (Func                               : Convert_Func;
      PB                                 : Pixel_Buffer;
      Pixels_Length                      : Array_Length;
      Palette_Length                     : Array_Length;
      Scratch_Len                        : Array_Length;
      Len0, Len1, Len2, Len3             : Array_Length;
      P0, P1, P2, P3                     : Plane;
      G                                  : Geometry) return Boolean
   is
     (Is_Valid (PB, Pixels_Length, Palette_Length)
      and then Is_Supported (PB.Pixcfg.Pixfmt)
      and then Bytes_Per_Pixel (PB.Pixcfg.Pixfmt) in 1 .. 8
      and then (if Func in Convert_Fast_Func then Has_Pixel_Size (PB, 4))
      and then G.X_Min < G.X_End
      and then G.Y_Min < G.Y_End
      and then G.X_End <= Index (PB.Pixcfg.Width)
      and then G.Y_End <= Index (PB.Pixcfg.Height)
      and then Scratch_Len >= Scratch_Length
      and then Plane_OK (P0, G, Len0)
      and then Plane_OK (P1, G, Len1)
      and then Plane_OK (P2, G, Len2)
      and then (if Func in Convert_4_Func
                then G.Chunk = 480 and then Plane_OK (P3, G, Len3)));

   --  One destination row: for each chunk, upsample every plane and
   --  convert.  C: the loop `while (x < x_max_excl) { ... }` that appears,
   --  with the same body, in ycc[k]__general__box_filter, in
   --  ycc[k]__general__triangle_filter_edge_row and in the middle rows'
   --  loop of ycc[k]__general__triangle_filter.
   procedure Filter_Row
     (Func                   : Convert_Func;
      PB                     : Pixel_Buffer;
      Pixels                 : in out Bytes;
      Palette                : Bytes;
      Scratch                : in out Bytes;
      Src0, Src1, Src2, Src3 : Bytes;
      P0, P1, P2, P3         : Plane;
      G                      : Geometry;
      Y                      : Index;
      Rows                   : Row_Pairs;
      H1V2_Bias              : Natural)
   with
     Pre => Filter_OK (Func, PB, Pixels'Length, Palette'Length, Scratch'Length,
                       Src0'Length, Src1'Length, Src2'Length, Src3'Length,
                       P0, P1, P2, P3, G)
       and then Y in G.Y_Min .. G.Y_End - 1
       and then H1V2_Bias <= 2
       and then Rows (0).Major < P0.T.Height and then Rows (0).Minor < P0.T.Height
       and then Rows (1).Major < P1.T.Height and then Rows (1).Minor < P1.T.Height
       and then Rows (2).Major < P2.T.Height and then Rows (2).Minor < P2.T.Height
       and then (if Func in Convert_4_Func
                 then Rows (3).Major < P3.T.Height
                   and then Rows (3).Minor < P3.T.Height);

   ----------------
   -- Filter_Row --
   ----------------

   procedure Filter_Row
     (Func                   : Convert_Func;
      PB                     : Pixel_Buffer;
      Pixels                 : in out Bytes;
      Palette                : Bytes;
      Scratch                : in out Bytes;
      Src0, Src1, Src2, Src3 : Bytes;
      P0, P1, P2, P3         : Plane;
      G                      : Geometry;
      Y                      : Index;
      Rows                   : Row_Pairs;
      H1V2_Bias              : Natural)
   is
      X                  : Index := G.X_Min;
      X_Chunk_End        : Index;
      Up0, Up1, Up2, Up3 : Upsampled;
   begin
      loop
         pragma Loop_Invariant (X in G.X_Min .. G.X_End - 1);
         pragma Loop_Invariant ((X - G.X_Min) mod 12 = 0);
         pragma Loop_Variant (Increases => X);

         X_Chunk_End := Index'Min (X + G.Chunk, G.X_End);

         Upsample_Plane
           (Scratch, 0, Src0, P0, G, Rows (0).Major, Rows (0).Minor,
            X, X_Chunk_End, H1V2_Bias, Up0);
         Upsample_Plane
           (Scratch, G.Chunk, Src1, P1, G, Rows (1).Major, Rows (1).Minor,
            X, X_Chunk_End, H1V2_Bias, Up1);
         Upsample_Plane
           (Scratch, 2 * G.Chunk, Src2, P2, G, Rows (2).Major, Rows (2).Minor,
            X, X_Chunk_End, H1V2_Bias, Up2);
         if Func in Convert_4_Func then
            Upsample_Plane
              (Scratch, 3 * G.Chunk, Src3, P3, G, Rows (3).Major, Rows (3).Minor,
               X, X_Chunk_End, H1V2_Bias, Up3);
            Convert_Chunk
              (Func, PB, Pixels, Palette, Scratch, Src0, Src1, Src2, Src3,
               X, X_Chunk_End, Y, Up0, Up1, Up2, Up3);
         else
            Convert_Chunk
              (Func, PB, Pixels, Palette, Scratch, Src0, Src1, Src2, Src2,
               X, X_Chunk_End, Y, Up0, Up1, Up2, Up2);
         end if;

         exit when X_Chunk_End >= G.X_End;
         X := X_Chunk_End;
      end loop;
   end Filter_Row;

   --  C: ycc__general__box_filter and ycck__general__box_filter.
   procedure General_Box_Filter
     (Func                   : Convert_Func;
      PB                     : Pixel_Buffer;
      Pixels                 : in out Bytes;
      Palette                : Bytes;
      Scratch                : in out Bytes;
      Src0, Src1, Src2, Src3 : Bytes;
      P0, P1, P2, P3         : Plane;
      G                      : Geometry)
   with
     Pre => Filter_OK (Func, PB, Pixels'Length, Palette'Length, Scratch'Length,
                       Src0'Length, Src1'Length, Src2'Length, Src3'Length,
                       P0, P1, P2, P3, G);

   --  C: ycc__general__triangle_filter_edge_row and
   --  ycck__general__triangle_filter_edge_row: the first row, and the last
   --  one if it is the last of the image; the vertical triangle filters
   --  have only the row itself to work from.
   procedure General_Triangle_Filter_Edge_Row
     (Func                   : Convert_Func;
      PB                     : Pixel_Buffer;
      Pixels                 : in out Bytes;
      Palette                : Bytes;
      Scratch                : in out Bytes;
      Src0, Src1, Src2, Src3 : Bytes;
      P0, P1, P2, P3         : Plane;
      G                      : Geometry;
      Y                      : Index;
      H1V2_Bias              : Natural)
   with
     Pre => Filter_OK (Func, PB, Pixels'Length, Palette'Length, Scratch'Length,
                       Src0'Length, Src1'Length, Src2'Length, Src3'Length,
                       P0, P1, P2, P3, G)
       and then G.Y_Min = 0
       and then Y < G.Y_End
       and then H1V2_Bias <= 2;

   --  C: ycc__general__triangle_filter and ycck__general__triangle_filter.
   --  (The C functions begin by returning if x_min_incl or y_min_incl is
   --  not zero; swizzle_ycck has rejected that already, and here it is the
   --  precondition.)
   procedure General_Triangle_Filter
     (Func                   : Convert_Func;
      PB                     : Pixel_Buffer;
      Pixels                 : in out Bytes;
      Palette                : Bytes;
      Scratch                : in out Bytes;
      Src0, Src1, Src2, Src3 : Bytes;
      P0, P1, P2, P3         : Plane;
      G                      : Geometry)
   with
     Pre => Filter_OK (Func, PB, Pixels'Length, Palette'Length, Scratch'Length,
                       Src0'Length, Src1'Length, Src2'Length, Src3'Length,
                       P0, P1, P2, P3, G)
       and then G.X_Min = 0
       and then G.Y_Min = 0;

   ------------------------
   -- General_Box_Filter --
   ------------------------

   procedure General_Box_Filter
     (Func                   : Convert_Func;
      PB                     : Pixel_Buffer;
      Pixels                 : in out Bytes;
      Palette                : Bytes;
      Scratch                : in out Bytes;
      Src0, Src1, Src2, Src3 : Bytes;
      P0, P1, P2, P3         : Plane;
      G                      : Geometry)
   is
      R0, R1, R2, R3 : Index;
   begin
      for Y in G.Y_Min .. G.Y_End - 1 loop
         Lemma_Div (Y - G.Y_Min, P0.T.Height, P0.Inv_V);
         Lemma_Div (Y - G.Y_Min, P1.T.Height, P1.Inv_V);
         Lemma_Div (Y - G.Y_Min, P2.T.Height, P2.Inv_V);
         R0 := Div (Y - G.Y_Min, P0.Inv_V);
         R1 := Div (Y - G.Y_Min, P1.Inv_V);
         R2 := Div (Y - G.Y_Min, P2.Inv_V);
         if Func in Convert_4_Func then
            Lemma_Div (Y - G.Y_Min, P3.T.Height, P3.Inv_V);
            R3 := Div (Y - G.Y_Min, P3.Inv_V);
         else
            R3 := 0;
         end if;
         Filter_Row
           (Func, PB, Pixels, Palette, Scratch, Src0, Src1, Src2, Src3,
            P0, P1, P2, P3, G, Y,
            [(R0, R0), (R1, R1), (R2, R2), (R3, R3)], 0);
      end loop;
   end General_Box_Filter;

   --------------------------------------
   -- General_Triangle_Filter_Edge_Row --
   --------------------------------------

   procedure General_Triangle_Filter_Edge_Row
     (Func                   : Convert_Func;
      PB                     : Pixel_Buffer;
      Pixels                 : in out Bytes;
      Palette                : Bytes;
      Scratch                : in out Bytes;
      Src0, Src1, Src2, Src3 : Bytes;
      P0, P1, P2, P3         : Plane;
      G                      : Geometry;
      Y                      : Index;
      H1V2_Bias              : Natural)
   is
      R0, R1, R2, R3 : Index;
   begin
      Lemma_Div (Y, P0.T.Height, P0.Inv_V);
      Lemma_Div (Y, P1.T.Height, P1.Inv_V);
      Lemma_Div (Y, P2.T.Height, P2.Inv_V);
      R0 := Div (Y, P0.Inv_V);
      R1 := Div (Y, P1.Inv_V);
      R2 := Div (Y, P2.Inv_V);
      if Func in Convert_4_Func then
         Lemma_Div (Y, P3.T.Height, P3.Inv_V);
         R3 := Div (Y, P3.Inv_V);
      else
         R3 := 0;
      end if;
      Filter_Row
        (Func, PB, Pixels, Palette, Scratch, Src0, Src1, Src2, Src3,
         P0, P1, P2, P3, G, Y,
         [(R0, R0), (R1, R1), (R2, R2), (R3, R3)], H1V2_Bias);
   end General_Triangle_Filter_Edge_Row;

   --  The rows of plane P that a middle row Y of the triangle filter is
   --  made from.  C: srcK_major is row y / inv_v; srcK_minor is the same
   --  row unless inv_v is 2, and then the row below (odd y) or above (even
   --  y).  Here the minor row is only different for the two upsamplers
   --  that read it (C computes the pointer for every plane with inv_v = 2,
   --  used or not).
   function Middle_Rows (P : Plane; G : Geometry; Y : Index) return Row_Pair is
     (Major => Div (Y, P.Inv_V),
      Minor => (if P.Up not in Vertical_Triangle then Div (Y, P.Inv_V)
                elsif Y mod 2 = 1 then Div (Y, P.Inv_V) + 1
                else Div (Y, P.Inv_V) - 1))
   with
     Pre  => P.T.Height in 1 .. Max_Size
       and then G.Y_Min = 0
       and then G.Y_End <= P.T.Height * P.Inv_V
       and then (if P.Up in Vertical_Triangle
                 then P.Inv_V = 2
                   and then (G.Y_End < 2 * P.T.Height or else G.Y_End = 2 * G.Half_H))
       and then Y >= 1
       and then Y < (if G.Y_End = 2 * G.Half_H then G.Y_End - 1 else G.Y_End),
     Post => Middle_Rows'Result.Major < P.T.Height
       and then Middle_Rows'Result.Minor < P.T.Height;

   -----------------------------
   -- General_Triangle_Filter --
   -----------------------------

   procedure General_Triangle_Filter
     (Func                   : Convert_Func;
      PB                     : Pixel_Buffer;
      Pixels                 : in out Bytes;
      Palette                : Bytes;
      Scratch                : in out Bytes;
      Src0, Src1, Src2, Src3 : Bytes;
      P0, P1, P2, P3         : Plane;
      G                      : Geometry)
   is
      Last_Row     : constant Boolean := G.Y_End = 2 * G.Half_H;
      Middle_Y_End : constant Index := (if Last_Row then G.Y_End - 1 else G.Y_End);
      H1V2_Bias    : Natural := 1;
      Rows         : Row_Pairs;
   begin
      General_Triangle_Filter_Edge_Row
        (Func, PB, Pixels, Palette, Scratch, Src0, Src1, Src2, Src3,
         P0, P1, P2, P3, G, 0, H1V2_Bias);
      H1V2_Bias := 2;

      for Y in 1 .. Middle_Y_End - 1 loop
         pragma Loop_Invariant (H1V2_Bias in 1 .. 2);
         Rows := [0 => Middle_Rows (P0, G, Y),
                  1 => Middle_Rows (P1, G, Y),
                  2 => Middle_Rows (P2, G, Y),
                  3 => (if Func in Convert_4_Func then Middle_Rows (P3, G, Y)
                        else (0, 0))];
         Filter_Row
           (Func, PB, Pixels, Palette, Scratch, Src0, Src1, Src2, Src3,
            P0, P1, P2, P3, G, Y, Rows, H1V2_Bias);
         H1V2_Bias := 3 - H1V2_Bias;  --  C: h1v2_bias ^= 3
      end loop;

      if Middle_Y_End /= G.Y_End then
         General_Triangle_Filter_Edge_Row
           (Func, PB, Pixels, Palette, Scratch, Src0, Src1, Src2, Src3,
            P0, P1, P2, P3, G, Middle_Y_End, H1V2_Bias);
      end if;
   end General_Triangle_Filter;

   --  C: dst_view, in wuffs_base__pixel_swizzler__swizzle_ycck.  The pixel
   --  buffer that the conversion writes to, for the destination offset (DX,
   --  DY): the part of PB from pixel (DX, DY), of the same format and
   --  palette.  If that is empty (the offset is outside PB), a view of no
   --  pixels.  If the format does not have 1 to 8 whole bytes per pixel (no
   --  format that the conversion accepts), only the size is reduced: such a
   --  format is rejected anyway, after the clipping that uses that size.
   --
   --  Nothing here needs PB to be valid.  For a valid PB the view is proved
   --  valid (Make_View's postcondition: its plane 0 is a part of PB's, at
   --  least as wide and as high as its size says), so Swizzle_Window's first
   --  check, which it makes of any pixel buffer, never fails for it.  The
   --  three lemmas state the facts about mixed U32, U64 and Index values
   --  that the provers do not find by themselves within the step limit.
   procedure Lemma_Row_Bytes_Split (W, DX, B : U32)
   with
     Ghost,
     Pre  => DX < W and then B <= 32,
     Post => U64 (DX) * U64 (B) <= U64 (W) * U64 (B)
       and then U64 (W - DX) * U64 (B) = U64 (W) * U64 (B) - U64 (DX) * U64 (B);

   procedure Lemma_Row_Bytes_Split (W, DX, B : U32) is null;

   procedure Lemma_Lt_Index (A, B : U32; C : Index)
   with
     Ghost,
     Pre  => A < B and then Index (B) <= C,
     Post => Index (A) < C
       and then U64 (A) < U64 (C)
       and then Index (B) - Index (A) <= C - Index (A);

   procedure Lemma_Lt_Index (A, B : U32; C : Index) is null;

   procedure Lemma_Sub (A, B : U32; C : Index)
   with
     Ghost,
     Pre  => A < B and then Index (A) < C,
     Post => Index (B - A) = Index (B) - Index (A)
       and then (if U64 (A) <= U64 (C) then Index (U64 (C) - U64 (A)) = C - Index (A));

   procedure Lemma_Sub (A, B : U32; C : Index) is null;

   procedure Make_View
     (PB             : Pixel_Buffer;
      Length         : Array_Length;
      Palette_Length : Array_Length;
      DX, DY         : U32;
      View           : out Pixel_Buffer)
   with
     Post => (if Is_Valid (PB, Length, Palette_Length)
              then Is_Valid (View, Length, Palette_Length));

   ---------------
   -- Make_View --
   ---------------

   procedure Make_View
     (PB             : Pixel_Buffer;
      Length         : Array_Length;
      Palette_Length : Array_Length;
      DX, DY         : U32;
      View           : out Pixel_Buffer)
   is
      B : constant U32 := Bytes_Per_Pixel (PB.Pixcfg.Pixfmt);
      T : constant Table := PB.Planes (0);
   begin
      View := PB;
      if DX >= PB.Pixcfg.Width or else DY >= PB.Pixcfg.Height then
         View.Pixcfg.Width := 0;
         View.Pixcfg.Height := 0;
         pragma Assert (Row_Bytes (View.Pixcfg) = 0);
      else
         View.Pixcfg.Width := PB.Pixcfg.Width - DX;
         View.Pixcfg.Height := PB.Pixcfg.Height - DY;
         Lemma_Row_Bytes_Split (PB.Pixcfg.Width, DX, B);
         pragma Assert (Bytes_Per_Pixel (View.Pixcfg.Pixfmt) = B);
         pragma Assert (Row_Bytes (View.Pixcfg) = U64 (PB.Pixcfg.Width - DX) * U64 (B));
         pragma Assert (Row_Bytes (PB.Pixcfg) = U64 (PB.Pixcfg.Width) * U64 (B));
         pragma Assert
           (if Is_Valid (PB, Length, Palette_Length)
            then U64 (DX) * U64 (B) <= U64 (T.Width)
              and then Row_Bytes (View.Pixcfg) <= U64 (T.Width) - U64 (DX) * U64 (B));
         if Is_Valid (PB, Length, Palette_Length) then
            Lemma_Lt_Index (DY, PB.Pixcfg.Height, T.Height);
            Lemma_Sub (DY, PB.Pixcfg.Height, T.Height);
            pragma Assert (Index (View.Pixcfg.Height) <= T.Height - Index (DY));
         end if;
         if B in 1 .. 8 then
            Pixel_Buffers.Subtable
              (T      => T,
               IX     => U64 (DX) * U64 (B),
               IY     => U64 (DY),
               JX     => U64 (T.Width),
               JY     => U64 (T.Height),
               Length => Length,
               Result => View.Planes (0));
            pragma Assert
              (if Is_Valid (PB, Length, Palette_Length)
               then U64 (View.Planes (0).Width) = U64 (T.Width) - U64 (DX) * U64 (B)
                 and then View.Planes (0).Height = T.Height - Index (DY));
            pragma Assert
              (if Is_Valid (PB, Length, Palette_Length)
               then Index (View.Pixcfg.Height) <= View.Planes (0).Height);
         else
            pragma Assert (View.Planes (0).Height = T.Height);
            pragma Assert
              (if Is_Valid (PB, Length, Palette_Length)
               then Index (View.Pixcfg.Height) <= View.Planes (0).Height);
         end if;
      end if;
   end Make_View;

   --  The conversion of the rectangle to the pixel buffer PB, which is the
   --  caller's pixel buffer or a view of it (Make_View): C's
   --  wuffs_base__pixel_swizzler__swizzle_ycck, every check and the clipping
   --  included, for a zero offset.
   procedure Swizzle_Window
     (PB                : Pixel_Buffers.Pixel_Buffer;
      Pixels            : in out Bytes;
      Palette           : Bytes;
      Dst_Palette       : Bytes;
      X_Min_Incl        : U32;
      X_Max_Excl        : U32;
      Y_Min_Incl        : U32;
      Y_Max_Excl        : U32;
      Src0              : Bytes;
      Src1              : Bytes;
      Src2              : Bytes;
      Src3              : Bytes;
      Planes            : Source_Planes;
      YCC_Model         : U8;
      YCC_Upsampling    : U8;
      Scratch_Buffer_2K : in out Bytes;
      Result            : out Status)
   with
     Post => (Is_Ok (Result)
              or else Result = Error_Bad_Argument
              or else Result = Error_Unsupported_Pixel_Swizzler_Option)
       and then (if not Is_Ok (Result)
                 then Pixels = Pixels'Old
                   and then Scratch_Buffer_2K = Scratch_Buffer_2K'Old);

   --------------------
   -- Swizzle_Window --
   --------------------

   procedure Swizzle_Window
     (PB                : Pixel_Buffers.Pixel_Buffer;
      Pixels            : in out Bytes;
      Palette           : Bytes;
      Dst_Palette       : Bytes;
      X_Min_Incl        : U32;
      X_Max_Excl        : U32;
      Y_Min_Incl        : U32;
      Y_Max_Excl        : U32;
      Src0              : Bytes;
      Src1              : Bytes;
      Src2              : Bytes;
      Src3              : Bytes;
      Planes            : Source_Planes;
      YCC_Model         : U8;
      YCC_Upsampling    : U8;
      Scratch_Buffer_2K : in out Bytes;
      Result            : out Status)
   is
      pragma Unreferenced (Dst_Palette);

      function Bad_Factor (V : U8) return Boolean is (V not in 1 .. 4);

      --  X is not 0 and not a multiple of Inv either (for Inv /= 0).
      function Misaligned (X : U32; Inv : Inverse_Or_0) return Boolean is
        (Inv /= 0 and then X /= 0 and then Index (X) mod Inv /= 0);

      Four_Planes : constant Boolean := Planes (3).H /= 0 or else Planes (3).V /= 0;
      Format      : constant U32 := PB.Pixcfg.Pixfmt.Repr;

      Max_H, Max_V           : U8;
      IH0, IH1, IH2, IH3     : Inverse_Or_0;
      IV0, IV1, IV2, IV3     : Inverse_Or_0;
      DX, DY                 : Index;
      Expanded_W, Expanded_H : Index;
      Half_W, Half_H         : Index;
      X_End, Y_End           : Index;
      Triangle               : Boolean;
      G                      : Geometry;
      P0, P1, P2, P3         : Plane;
      Func                   : Convert_Func;
   begin
      Result := Error_Bad_Argument;

      --  Not a C check (C trusts its pixel_buffer argument).
      if not Is_Valid (PB, Pixels'Length, Palette'Length) then
         return;
      end if;

      if X_Max_Excl > 16#FFFF# or else Y_Max_Excl > 16#FFFF#
        or else (for some S of Planes => S.Width > Max_Size or else S.Height > Max_Size)
      then
         return;
      end if;
      if Src0'Length < Flattened_Length (Planes (0))
        or else Src1'Length < Flattened_Length (Planes (1))
        or else Src2'Length < Flattened_Length (Planes (2))
        or else Src3'Length < Flattened_Length (Planes (3))
        or else Bad_Factor (Planes (0).H) or else Bad_Factor (Planes (1).H)
        or else Bad_Factor (Planes (2).H)
        or else Bad_Factor (Planes (0).V) or else Bad_Factor (Planes (1).V)
        or else Bad_Factor (Planes (2).V)
        or else (YCC_Upsampling /= 0 and then (X_Min_Incl /= 0 or else Y_Min_Incl /= 0))
        or else Scratch_Buffer_2K'Length < Scratch_Buffer_Length
      then
         return;
      end if;
      if Four_Planes
        and then (Bad_Factor (Planes (3).H) or else Bad_Factor (Planes (3).V))
      then
         return;
      end if;

      Max_H := U8'Max (U8'Max (Planes (0).H, Planes (1).H),
                       U8'Max (Planes (2).H, Planes (3).H));
      Max_V := U8'Max (U8'Max (Planes (0).V, Planes (1).V),
                       U8'Max (Planes (2).V, Planes (3).V));
      IH0 := Exact_Inverse (Max_H, Planes (0).H);
      IH1 := Exact_Inverse (Max_H, Planes (1).H);
      IH2 := Exact_Inverse (Max_H, Planes (2).H);
      IH3 := Exact_Inverse (Max_H, Planes (3).H);
      IV0 := Exact_Inverse (Max_V, Planes (0).V);
      IV1 := Exact_Inverse (Max_V, Planes (1).V);
      IV2 := Exact_Inverse (Max_V, Planes (2).V);
      IV3 := Exact_Inverse (Max_V, Planes (3).V);
      --  (C tests v3 here as well as h3, as below, although for a call
      --  that gets this far the test on v3 changes nothing: kept as in C.)
      if IH0 = 0 or else IH1 = 0 or else IH2 = 0
        or else IV0 = 0 or else IV1 = 0 or else IV2 = 0
        or else (Four_Planes and then (IH3 = 0 or else IV3 = 0))
      then
         return;
      end if;

      if X_Min_Incl >= X_Max_Excl or else Y_Min_Incl >= Y_Max_Excl then
         Result := Ok_Status;
         return;
      end if;
      DX := Index (X_Max_Excl - X_Min_Incl);
      DY := Index (Y_Max_Excl - Y_Min_Incl);
      pragma Assert (DX = Index (X_Max_Excl) - Index (X_Min_Incl));
      pragma Assert (DY = Index (Y_Max_Excl) - Index (Y_Min_Incl));
      Expanded_W := Index (Planes (0).Width) * IH0;
      Expanded_H := Index (Planes (0).Height) * IV0;
      if Expanded_W < DX or else Expanded_H < DY
        or else Expanded_W /= Index (Planes (1).Width) * IH1
        or else Expanded_W /= Index (Planes (2).Width) * IH2
        or else Expanded_H /= Index (Planes (1).Height) * IV1
        or else Expanded_H /= Index (Planes (2).Height) * IV2
      then
         return;
      elsif not Four_Planes then
         null;
      elsif IH3 = 1 and then IV3 = 1
        and then DX = Index (Planes (3).Width) and then DY = Index (Planes (3).Height)
      then
         --  A full resolution fourth plane may be exactly the rectangle's
         --  size instead of the other planes' expanded size.
         null;
      elsif Index (Planes (3).Width) * IH3 /= Expanded_W
        or else Index (Planes (3).Height) * IV3 /= Expanded_H
      then
         return;
      end if;

      if Misaligned (X_Min_Incl, IH0) or else Misaligned (X_Min_Incl, IH1)
        or else Misaligned (X_Min_Incl, IH2) or else Misaligned (X_Min_Incl, IH3)
        or else Misaligned (Y_Min_Incl, IV0) or else Misaligned (Y_Min_Incl, IV1)
        or else Misaligned (Y_Min_Incl, IV2) or else Misaligned (Y_Min_Incl, IV3)
      then
         return;
      end if;

      --  C: half_width_for_2to1 and half_height_for_2to1.
      Half_W := (DX + 1) / 2;
      if IH0 = 2 then
         Half_W := Index'Min (Half_W, Index (Planes (0).Width));
      end if;
      if IH1 = 2 then
         Half_W := Index'Min (Half_W, Index (Planes (1).Width));
      end if;
      if IH2 = 2 then
         Half_W := Index'Min (Half_W, Index (Planes (2).Width));
      end if;
      if IH3 = 2 then
         Half_W := Index'Min (Half_W, Index (Planes (3).Width));
      end if;
      Half_H := (DY + 1) / 2;
      if IV0 = 2 then
         Half_H := Index'Min (Half_H, Index (Planes (0).Height));
      end if;
      if IV1 = 2 then
         Half_H := Index'Min (Half_H, Index (Planes (1).Height));
      end if;
      if IV2 = 2 then
         Half_H := Index'Min (Half_H, Index (Planes (2).Height));
      end if;
      if IV3 = 2 then
         Half_H := Index'Min (Half_H, Index (Planes (3).Height));
      end if;
      --  Each plane that is halved vertically has Expanded_H / 2 rows,
      --  which is at least (DY + 1) / 2: the smallest is (DY + 1) / 2.
      pragma Assert (Half_H = (DY + 1) / 2);

      pragma Assert (Index (X_Max_Excl) <= 16#FFFF#);
      pragma Assert (Index (Y_Max_Excl) <= 16#FFFF#);
      X_End := Index'Min (Index (X_Max_Excl), Index (PB.Pixcfg.Width));
      Y_End := Index'Min (Index (Y_Max_Excl), Index (PB.Pixcfg.Height));
      if Index (X_Min_Incl) >= X_End or else Index (Y_Min_Incl) >= Y_End then
         Result := Ok_Status;
         return;
      end if;

      Result := Error_Unsupported_Pixel_Swizzler_Option;
      if Is_Planar (PB.Pixcfg.Pixfmt)
        or else not Is_Supported (PB.Pixcfg.Pixfmt)
      then
         return;
      end if;
      --  The accepted formats' sizes, one by one for the provers.
      case Format is
         when Repr_Y =>
            pragma Assert (Bytes_Per_Pixel (PB.Pixcfg.Pixfmt) = 1);
         when Repr_Indexed_BGRA_Nonpremul =>
            pragma Assert (Bytes_Per_Pixel (PB.Pixcfg.Pixfmt) = 1);
         when Repr_Indexed_BGRA_Premul =>
            pragma Assert (Bytes_Per_Pixel (PB.Pixcfg.Pixfmt) = 1);
         when Repr_Indexed_BGRA_Binary =>
            pragma Assert (Bytes_Per_Pixel (PB.Pixcfg.Pixfmt) = 1);
         when Repr_Y_16LE =>
            pragma Assert (Bytes_Per_Pixel (PB.Pixcfg.Pixfmt) = 2);
         when Repr_Y_16BE =>
            pragma Assert (Bytes_Per_Pixel (PB.Pixcfg.Pixfmt) = 2);
         when Repr_YA_Nonpremul =>
            pragma Assert (Bytes_Per_Pixel (PB.Pixcfg.Pixfmt) = 2);
         when Repr_BGR_565 =>
            pragma Assert (Bytes_Per_Pixel (PB.Pixcfg.Pixfmt) = 2);
         when Repr_BGR =>
            pragma Assert (Bytes_Per_Pixel (PB.Pixcfg.Pixfmt) = 3);
         when Repr_RGB =>
            pragma Assert (Bytes_Per_Pixel (PB.Pixcfg.Pixfmt) = 3);
         when Repr_BGRA_Nonpremul =>
            pragma Assert (Bytes_Per_Pixel (PB.Pixcfg.Pixfmt) = 4);
         when Repr_BGRA_Premul =>
            pragma Assert (Bytes_Per_Pixel (PB.Pixcfg.Pixfmt) = 4);
         when Repr_BGRX =>
            pragma Assert (Bytes_Per_Pixel (PB.Pixcfg.Pixfmt) = 4);
         when Repr_RGBA_Nonpremul =>
            pragma Assert (Bytes_Per_Pixel (PB.Pixcfg.Pixfmt) = 4);
         when Repr_RGBA_Premul =>
            pragma Assert (Bytes_Per_Pixel (PB.Pixcfg.Pixfmt) = 4);
         when Repr_RGBX =>
            pragma Assert (Bytes_Per_Pixel (PB.Pixcfg.Pixfmt) = 4);
         when Repr_BGRA_Nonpremul_4x16LE =>
            pragma Assert (Bytes_Per_Pixel (PB.Pixcfg.Pixfmt) = 8);
         when others =>
            null;
      end case;
      pragma Assert (Bytes_Per_Pixel (PB.Pixcfg.Pixfmt) in 1 .. 8);

      if not Four_Planes then
         if YCC_Model >= YCC_Model_RGB then
            Func := RGB_Convert_3_General;
         elsif YCC_Model >= YCC_Model_BT_601_Studio_Range then
            Func := (case Format is
                       when Repr_BGRA_Nonpremul | Repr_BGRA_Premul | Repr_BGRX =>
                         YCC_BT601SR_Convert_3_BGRX,
                       when Repr_RGBA_Nonpremul | Repr_RGBA_Premul | Repr_RGBX =>
                         YCC_BT601SR_Convert_3_RGBX,
                       when others =>
                         YCC_BT601SR_Convert_3_General);
         else
            Func := (case Format is
                       when Repr_BGRA_Nonpremul | Repr_BGRA_Premul | Repr_BGRX =>
                         YCC_BT601FR_Convert_3_BGRX,
                       when Repr_RGBA_Nonpremul | Repr_RGBA_Premul | Repr_RGBX =>
                         YCC_BT601FR_Convert_3_RGBX,
                       when others =>
                         YCC_BT601FR_Convert_3_General);
         end if;
      elsif YCC_Model = YCC_Model_BT_601_Full_Range then
         Func := YCCK_Convert_4_General;
      elsif YCC_Model = YCC_Model_BT_601_Studio_Range_Alpha_Src then
         Func := (if Format = Repr_BGRA_Premul
                  then YCCA_BT601SR_Src_Convert_4_BGRA_Premul
                  else YCCA_BT601SR_Src_Convert_4_General);
      elsif YCC_Model = YCC_Model_BT_601_Studio_Range_Alpha_Src_Over then
         Func := (if Format = Repr_BGRA_Premul
                  then YCCA_BT601SR_Src_Over_Convert_4_BGRA_Premul
                  else YCCA_BT601SR_Src_Over_Convert_4_General);
      elsif YCC_Model = YCC_Model_CMY then
         Func := CMYK_Convert_4_General;
      else
         return;
      end if;
      pragma Assert ((Func in Convert_4_Func) = Four_Planes);
      pragma Assert (if Func in Convert_Fast_Func then Has_Pixel_Size (PB, 4));

      --  C: func3 / func4 and upfuncs.  The triangle filter is used if
      --  fancy upsampling is asked for and some plane has a triangle
      --  upsampler; then each plane uses its triangle upsampler if it has
      --  one, and its box upsampler otherwise.
      Triangle := YCC_Upsampling /= 0
        and then (Has_Triangle_Upsampler (IH0, IV0)
                  or else Has_Triangle_Upsampler (IH1, IV1)
                  or else Has_Triangle_Upsampler (IH2, IV2)
                  or else Has_Triangle_Upsampler (IH3, IV3));

      G := (X_Min  => Index (X_Min_Incl),
            Y_Min  => Index (Y_Min_Incl),
            X_End  => X_End,
            Y_End  => Y_End,
            Chunk  => (if Four_Planes then 480 else 672),
            Half_W => Half_W,
            Half_H => Half_H,
            OC     => (if YCC_Upsampling = YCC_Upsampling_Fancy_Like_Libjpeg
                       then 7 else 8));

      pragma Assert (G.X_End <= Index (X_Max_Excl));
      pragma Assert (G.Y_End <= Index (Y_Max_Excl));
      pragma Assert (G.X_End <= Index (PB.Pixcfg.Width));
      pragma Assert (G.Y_End <= Index (PB.Pixcfg.Height));
      pragma Assert (G.X_End - G.X_Min <= DX and then G.Y_End - G.Y_Min <= DY);
      pragma Assert (DX <= Index (Planes (0).Width) * IH0);
      pragma Assert (DX <= Index (Planes (1).Width) * IH1);
      pragma Assert (DX <= Index (Planes (2).Width) * IH2);
      pragma Assert (DY <= Index (Planes (0).Height) * IV0);
      pragma Assert (DY <= Index (Planes (1).Height) * IV1);
      pragma Assert (DY <= Index (Planes (2).Height) * IV2);
      pragma Assert (if Four_Planes then DX <= Index (Planes (3).Width) * IH3);
      pragma Assert (if Four_Planes then DY <= Index (Planes (3).Height) * IV3);

      pragma Assert (G.Half_H = (DY + 1) / 2);
      pragma Assert (if Triangle then G.Y_End <= DY);
      if Triangle and then IV0 = 2 then
         Lemma_Last_Row (G.Y_End, DY, Index (Planes (0).Height), G.Half_H);
      end if;
      if Triangle and then IV1 = 2 then
         Lemma_Last_Row (G.Y_End, DY, Index (Planes (1).Height), G.Half_H);
      end if;
      if Triangle and then IV2 = 2 then
         Lemma_Last_Row (G.Y_End, DY, Index (Planes (2).Height), G.Half_H);
      end if;
      if Triangle and then Four_Planes and then IV3 = 2 then
         Lemma_Last_Row (G.Y_End, DY, Index (Planes (3).Height), G.Half_H);
      end if;

      P0 := Make_Plane (Planes (0), IH0, IV0, Triangle, G, Src0'Length);
      P1 := Make_Plane (Planes (1), IH1, IV1, Triangle, G, Src1'Length);
      P2 := Make_Plane (Planes (2), IH2, IV2, Triangle, G, Src2'Length);
      if Four_Planes then
         P3 := Make_Plane (Planes (3), IH3, IV3, Triangle, G, Src3'Length);
      end if;

      Result := Ok_Status;
      if Triangle then
         General_Triangle_Filter
           (Func, PB, Pixels, Palette, Scratch_Buffer_2K, Src0, Src1, Src2, Src3,
            P0, P1, P2, P3, G);
      else
         General_Box_Filter
           (Func, PB, Pixels, Palette, Scratch_Buffer_2K, Src0, Src1, Src2, Src3,
            P0, P1, P2, P3, G);
      end if;
   end Swizzle_Window;

   ------------------
   -- Swizzle_YCCK --
   ------------------

   --  C: wuffs_base__pixel_swizzler__swizzle_ycck.  C makes its view of the
   --  pixel buffer for a non-zero offset after its argument checks and
   --  clipping (which uses the view's size); here the view is made first
   --  and Swizzle_Window does those checks and that clipping on it, which
   --  gives the same statuses, in the same order, and the same pixels.
   procedure Swizzle_YCCK
     (PB                : Pixel_Buffers.Pixel_Buffer;
      Pixels            : in out Bytes;
      Palette           : Bytes;
      Dst_Palette       : Bytes;
      Dst_X_Offset      : U32;
      Dst_Y_Offset      : U32;
      X_Min_Incl        : U32;
      X_Max_Excl        : U32;
      Y_Min_Incl        : U32;
      Y_Max_Excl        : U32;
      Src0              : Bytes;
      Src1              : Bytes;
      Src2              : Bytes;
      Src3              : Bytes;
      Planes            : Source_Planes;
      YCC_Model         : U8;
      YCC_Upsampling    : U8;
      Scratch_Buffer_2K : in out Bytes;
      Result            : out Status)
   is
      View : Pixel_Buffer := PB;
   begin
      --  (An invalid PB is rejected by Swizzle_Window's first check.)
      if (Dst_X_Offset /= 0 or else Dst_Y_Offset /= 0)
        and then Is_Valid (PB, Pixels'Length, Palette'Length)
      then
         Make_View (PB, Pixels'Length, Palette'Length, Dst_X_Offset, Dst_Y_Offset, View);
         pragma Assert (Is_Valid (View, Pixels'Length, Palette'Length));
      end if;
      Swizzle_Window
        (PB                => View,
         Pixels            => Pixels,
         Palette           => Palette,
         Dst_Palette       => Dst_Palette,
         X_Min_Incl        => X_Min_Incl,
         X_Max_Excl        => X_Max_Excl,
         Y_Min_Incl        => Y_Min_Incl,
         Y_Max_Excl        => Y_Max_Excl,
         Src0              => Src0,
         Src1              => Src1,
         Src2              => Src2,
         Src3              => Src3,
         Planes            => Planes,
         YCC_Model         => YCC_Model,
         YCC_Upsampling    => YCC_Upsampling,
         Scratch_Buffer_2K => Scratch_Buffer_2K,
         Result            => Result);
   end Swizzle_YCCK;

end Wuffs.Base.Pixel_Swizzler_YCCK;
