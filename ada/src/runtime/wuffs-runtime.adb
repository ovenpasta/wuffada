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
