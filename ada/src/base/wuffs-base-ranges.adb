package body Wuffs.Base.Ranges with SPARK_Mode is

   pragma Assertion_Policy (Ignore);

   --  Each function returns the C expression, Equals (S, Intersect (R, S)).
   --  In Contains_Range the assertions name the two extreme points of a
   --  non-empty S: if R contains those, it contains all of S, which is what
   --  lets the provers conclude the "for all" half of the postcondition.

   function Contains_Range (R, S : Range_IE_U32) return Boolean is
   begin
      if not Is_Empty (S) then
         pragma Assert (Contains (S, S.Min_Incl));
         pragma Assert (Contains (S, S.Max_Excl - 1));
      end if;
      return Equals (S, Intersect (R, S));
   end Contains_Range;

   function Contains_Range (R, S : Range_IE_U64) return Boolean is
   begin
      if not Is_Empty (S) then
         pragma Assert (Contains (S, S.Min_Incl));
         pragma Assert (Contains (S, S.Max_Excl - 1));
      end if;
      return Equals (S, Intersect (R, S));
   end Contains_Range;

   function Contains_Range (R, S : Range_II_U32) return Boolean is
   begin
      if not Is_Empty (S) then
         pragma Assert (Contains (S, S.Min_Incl));
         pragma Assert (Contains (S, S.Max_Incl));
      end if;
      return Equals (S, Intersect (R, S));
   end Contains_Range;

   function Contains_Range (R, S : Range_II_U64) return Boolean is
   begin
      if not Is_Empty (S) then
         pragma Assert (Contains (S, S.Min_Incl));
         pragma Assert (Contains (S, S.Max_Incl));
      end if;
      return Equals (S, Intersect (R, S));
   end Contains_Range;

   function Contains_Rect (R, S : Rect_IE_U32) return Boolean is
     (Equals (S, Intersect (R, S)));

   function Contains_Rect (R, S : Rect_II_U32) return Boolean is
     (Equals (S, Intersect (R, S)));

end Wuffs.Base.Ranges;
