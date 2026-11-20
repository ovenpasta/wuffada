with System.Storage_Elements;

package body Wuffs.Runtime is

   use type System.Address;
   use type System.Storage_Elements.Storage_Offset;

   package SE renames System.Storage_Elements;
   package IO renames Wuffs.Base.IO;

   --  The enclosing run of two views that share an element: where it
   --  starts, how long it is, and where each view starts in it.
   type Union is record
      Start    : System.Address;
      Length   : Wuffs.Index;
      A_Offset : Wuffs.Index;
      B_Offset : Wuffs.Index;
   end record;

   function Union_Of (A, B : Wuffs.Bytes) return Union
   with Pre => Share_An_Element (A, B);

   procedure Set (S : Slice_U8; I : Wuffs.Index; V : Wuffs.U8) is
   begin
      S.Base (S.First .. Last (S)) (S.First + I) := V;
   end Set;

   function Share_An_Element (A, B : Wuffs.Bytes) return Boolean is
   begin
      if A'Length = 0 or else B'Length = 0 then
         return False;
      end if;
      --  Half-open address ranges [first, first + length) intersect.
      return First_Address (A) < First_Address (B) + SE.Storage_Offset (B'Length)
        and then First_Address (B) < First_Address (A) + SE.Storage_Offset (A'Length);
   end Share_An_Element;

   function Union_Of (A, B : Wuffs.Bytes) return Union is
      A_First : constant System.Address := First_Address (A);
      B_First : constant System.Address := First_Address (B);
      A_End   : constant System.Address := A_First + SE.Storage_Offset (A'Length);
      B_End   : constant System.Address := B_First + SE.Storage_Offset (B'Length);
      Start   : constant System.Address := (if A_First < B_First then A_First else B_First);
      Finish  : constant System.Address := (if A_End < B_End then B_End else A_End);
   begin
      return
        (Start    => Start,
         Length   => Wuffs.Index (Finish - Start),
         A_Offset => Wuffs.Index (A_First - Start),
         B_Offset => Wuffs.Index (B_First - Start));
   end Union_Of;

   function Shares_Storage
     (A : Wuffs.Bytes; Address : System.Address; Size_In_Bits : Long_Long_Integer)
      return Boolean
   is
      Size : constant SE.Storage_Offset := SE.Storage_Offset ((Size_In_Bits + 7) / 8);
   begin
      if A'Length = 0 or else Size <= 0 then
         return False;
      end if;
      return First_Address (A) < Address + Size
        and then Address < First_Address (A) + SE.Storage_Offset (A'Length);
   end Shares_Storage;

   function Valid_Pixel_Buffer
     (PB      : Wuffs.Base.Pixel_Buffers.Pixel_Buffer;
      Pixels  : Wuffs.Bytes;
      Palette : Wuffs.Bytes) return Boolean is
   begin
      for P in PB.Planes'Range loop
         if not (PB.Planes (P).Offset'Valid
                 and then PB.Planes (P).Width'Valid
                 and then PB.Planes (P).Height'Valid
                 and then PB.Planes (P).Stride'Valid)
         then
            return False;
         end if;
      end loop;
      return Wuffs.Base.Pixel_Buffers.Is_Valid (PB, Pixels'Length, Palette'Length);
   end Valid_Pixel_Buffer;

   procedure Swizzler_Prepare
     (S           : out Wuffs.Base.Pixel_Swizzler.Swizzler;
      Dst_Pixfmt  : Wuffs.Base.Pixel_Formats.Pixel_Format;
      Dst_Palette : in out Wuffs.Bytes;
      Src_Pixfmt  : Wuffs.Base.Pixel_Formats.Pixel_Format;
      Src_Palette : Wuffs.Bytes;
      Blend       : Wuffs.Base.Pixel_Formats.Pixel_Blend;
      Result      : out Wuffs.Status) is
   begin
      if Share_An_Element (Dst_Palette, Src_Palette) then
         --  The un-prepared swizzler: it converts nothing.
         S := (others => <>);
         Result := Wuffs.Base.Error_Bad_Argument;
         return;
      end if;
      Wuffs.Base.Pixel_Swizzler.Prepare
        (S           => S,
         Dst_Pixfmt  => Dst_Pixfmt,
         Dst_Palette => Dst_Palette,
         Src_Pixfmt  => Src_Pixfmt,
         Src_Palette => Src_Palette,
         Blend       => Blend,
         Result      => Result);
   end Swizzler_Prepare;

   procedure Swizzle_Interleaved_From_Slice
     (S           : Wuffs.Base.Pixel_Swizzler.Swizzler;
      Dst         : in out Wuffs.Bytes;
      Dst_Palette : Wuffs.Bytes;
      Src         : Wuffs.Bytes;
      N           : out Wuffs.U64) is
   begin
      if Share_An_Element (Dst, Dst_Palette) or else Share_An_Element (Dst, Src) then
         N := 0;
         return;
      end if;
      Wuffs.Base.Pixel_Swizzler.Swizzle_Interleaved_From_Slice
        (S => S, Dst => Dst, Dst_Palette => Dst_Palette, Src => Src, N => N);
   end Swizzle_Interleaved_From_Slice;

   procedure Swizzle_Interleaved_From_Reader
     (S           : Wuffs.Base.Pixel_Swizzler.Swizzler;
      Dst         : in out Wuffs.Bytes;
      Dst_Palette : Wuffs.Bytes;
      Src_Data    : Wuffs.Bytes;
      R           : in out Wuffs.Base.IO.Reader;
      N           : out Wuffs.U64) is
   begin
      if Share_An_Element (Dst, Dst_Palette) or else Share_An_Element (Dst, Src_Data) then
         N := 0;
         return;
      end if;
      Wuffs.Base.Pixel_Swizzler.Swizzle_Interleaved_From_Reader
        (S => S, Dst => Dst, Dst_Palette => Dst_Palette, Src_Data => Src_Data, R => R, N => N);
   end Swizzle_Interleaved_From_Reader;

   procedure Limited_Swizzle_U32_Interleaved_From_Reader
     (S                : Wuffs.Base.Pixel_Swizzler.Swizzler;
      Up_To_Num_Pixels : Wuffs.U32;
      Dst              : in out Wuffs.Bytes;
      Dst_Palette      : Wuffs.Bytes;
      Src_Data         : Wuffs.Bytes;
      R                : in out Wuffs.Base.IO.Reader;
      N                : out Wuffs.U64) is
   begin
      if Share_An_Element (Dst, Dst_Palette) or else Share_An_Element (Dst, Src_Data) then
         N := 0;
         return;
      end if;
      Wuffs.Base.Pixel_Swizzler.Limited_Swizzle_U32_Interleaved_From_Reader
        (S                => S,
         Up_To_Num_Pixels => Up_To_Num_Pixels,
         Dst              => Dst,
         Dst_Palette      => Dst_Palette,
         Src_Data         => Src_Data,
         R                => R,
         N                => N);
   end Limited_Swizzle_U32_Interleaved_From_Reader;

   procedure Swizzle_Interleaved_Transparent_Black
     (S           : Wuffs.Base.Pixel_Swizzler.Swizzler;
      Dst         : in out Wuffs.Bytes;
      Dst_Palette : Wuffs.Bytes;
      Num_Pixels  : Wuffs.U64;
      N           : out Wuffs.U64) is
   begin
      if Share_An_Element (Dst, Dst_Palette) then
         N := 0;
         return;
      end if;
      Wuffs.Base.Pixel_Swizzler.Swizzle_Interleaved_Transparent_Black
        (S => S, Dst => Dst, Dst_Palette => Dst_Palette, Num_Pixels => Num_Pixels, N => N);
   end Swizzle_Interleaved_Transparent_Black;

   procedure Reader_Limited_Copy_U32_To_Slice
     (Data  : Wuffs.Bytes;
      R     : in out Wuffs.Base.IO.Reader;
      Up_To : Wuffs.U32;
      Dst   : in out Wuffs.Bytes;
      N     : out Wuffs.U32) is
   begin
      if not Share_An_Element (Data, Dst) then
         IO.Limited_Copy_U32_To_Slice (Data => Data, R => R, Up_To => Up_To, Dst => Dst, N => N);
      else
         declare
            U     : constant Union := Union_Of (Data, Dst);
            Whole : Wuffs.Bytes (0 .. U.Length - 1)
            with Import, Address => U.Start;
         begin
            IO.Limited_Copy_U32_To_Slice_Within
              (Data       => Whole,
               R_Base     => U.A_Offset,
               R          => R,
               Up_To      => Up_To,
               Dst_Offset => U.B_Offset,
               Dst_Length => Dst'Length,
               N          => N);
         end;
      end if;
   end Reader_Limited_Copy_U32_To_Slice;

   procedure Set
     (M      : out More_Information;
      Flavor : Wuffs.U32;
      W      : Wuffs.U32;
      X      : Wuffs.U64;
      Y      : Wuffs.U64;
      Z      : Wuffs.U64) is
   begin
      M.Flavor := Flavor;
      M.W := W;
      M.X := X;
      M.Y := Y;
      M.Z := Z;
   end Set;

   procedure Copy_Message (Text : String; Buffer : out String; Length : out Natural) is
   begin
      Length := Integer'Min (Text'Length, Buffer'Length);
      Buffer := [others => ' '];
      if Length > 0 then
         Buffer (Buffer'First .. Buffer'First + (Length - 1)) :=
           Text (Text'First .. Text'First + (Length - 1));
      end if;
   end Copy_Message;

   procedure Copy_From_Slice (Dst : in out Wuffs.Bytes; Src : Wuffs.Bytes; N : out Wuffs.U64) is
   begin
      if not Share_An_Element (Dst, Src) then
         Wuffs.Base.Slices.Copy_From_Slice (Dst, Src, N);
      else
         declare
            U     : constant Union := Union_Of (Dst, Src);
            Whole : Wuffs.Bytes (0 .. U.Length - 1)
            with Import, Address => U.Start;
         begin
            Wuffs.Base.Slices.Copy_Within
              (Data       => Whole,
               Dst_First  => U.A_Offset,
               Dst_Length => Dst'Length,
               Src_First  => U.B_Offset,
               Src_Length => Src'Length,
               N          => N);
         end;
      end if;
   end Copy_From_Slice;

   procedure Writer_Copy_From_Slice
     (Data : in out Wuffs.Bytes;
      W    : in out Wuffs.Base.IO.Writer;
      Src  : Wuffs.Bytes;
      N    : out Wuffs.U64) is
   begin
      if not Share_An_Element (Data, Src) then
         IO.Copy_From_Slice (Data => Data, W => W, Src => Src, N => N);
      else
         declare
            U     : constant Union := Union_Of (Data, Src);
            Whole : Wuffs.Bytes (0 .. U.Length - 1)
            with Import, Address => U.Start;
         begin
            IO.Copy_From_Slice_Within
              (Data       => Whole,
               W_Base     => U.A_Offset,
               W          => W,
               Src_Offset => U.B_Offset,
               Src_Length => Src'Length,
               N          => N);
         end;
      end if;
   end Writer_Copy_From_Slice;

   procedure Writer_Limited_Copy_U32_From_Slice
     (Data  : in out Wuffs.Bytes;
      W     : in out Wuffs.Base.IO.Writer;
      Up_To : Wuffs.U32;
      Src   : Wuffs.Bytes;
      N     : out Wuffs.U32) is
   begin
      if not Share_An_Element (Data, Src) then
         IO.Limited_Copy_U32_From_Slice (Data => Data, W => W, Up_To => Up_To, Src => Src, N => N);
      else
         declare
            U     : constant Union := Union_Of (Data, Src);
            Whole : Wuffs.Bytes (0 .. U.Length - 1)
            with Import, Address => U.Start;
         begin
            IO.Limited_Copy_U32_From_Slice_Within
              (Data       => Whole,
               W_Base     => U.A_Offset,
               W          => W,
               Up_To      => Up_To,
               Src_Offset => U.B_Offset,
               Src_Length => Src'Length,
               N          => N);
         end;
      end if;
   end Writer_Limited_Copy_U32_From_Slice;

   procedure Writer_Limited_Copy_U32_From_Reader
     (Data     : in out Wuffs.Bytes;
      W        : in out Wuffs.Base.IO.Writer;
      Up_To    : Wuffs.U32;
      Src_Data : Wuffs.Bytes;
      R        : in out Wuffs.Base.IO.Reader;
      N        : out Wuffs.U32) is
   begin
      if not Share_An_Element (Data, Src_Data) then
         IO.Limited_Copy_U32_From_Reader
           (Data => Data, W => W, Up_To => Up_To, Src_Data => Src_Data, R => R, N => N);
      else
         declare
            U     : constant Union := Union_Of (Data, Src_Data);
            Whole : Wuffs.Bytes (0 .. U.Length - 1)
            with Import, Address => U.Start;
         begin
            IO.Limited_Copy_U32_From_Reader_Within
              (Data   => Whole,
               W_Base => U.A_Offset,
               W      => W,
               Up_To  => Up_To,
               R_Base => U.B_Offset,
               R      => R,
               N      => N);
         end;
      end if;
   end Writer_Limited_Copy_U32_From_Reader;

end Wuffs.Runtime;
