--  Ranges and rectangles: range_ie_u32, range_ii_u32, range_ie_u64,
--  range_ii_u64, rect_ie_u32 and rect_ii_u32.
--
--  "ie" is inclusive minimum, exclusive maximum; "ii" is inclusive both
--  ends.  See wuffs/doc/note/ranges-and-rects.md; the C is in
--  wuffs/internal/cgen/base/range-public.h and this package follows it
--  function for function.  All types are plain values that default to all
--  zeroes, which is what utility.empty_xxx() returns (note that the zero
--  "ii" value is not empty: it contains the one point 0).
--
--  Wuffs method                      Ada
--  --------------------------------  ---------------------------------
--  utility.make_range_ie_u32(a, b)   Make_Range_IE_U32 (A, B)
--  utility.empty_range_ie_u32()      Empty_Range_IE_U32
--  r.get_min_incl()                  Get_Min_Incl (R) or R.Min_Incl
--  r.is_empty(), r.intersect(s), r.unite(s)
--                                    Is_Empty (R), Intersect (R, S), Unite (R, S)
--
--  Equals, Contains, Contains_Range / Contains_Rect, Length, Width and
--  Height are the remaining functions of the C API.  As in C, there is a
--  Length only for the "ie" ranges and Width / Height only for the "ie"
--  rect; all three saturate at zero for empty values.
--
--  Two empty values are Equals even if their fields differ, so Equals is
--  not Ada's "=".
--
--  Every function but Contains_Range / Contains_Rect is an expression
--  function.  Intersect, Unite and Contains_Range / Contains_Rect also state
--  what they mean for membership.

package Wuffs.Base.Ranges with Pure, SPARK_Mode is

   pragma Assertion_Policy (Post => Ignore);

   use type Interfaces.Unsigned_32;
   use type Interfaces.Unsigned_64;

   ------------------
   -- Range_IE_U32 --
   ------------------

   type Range_IE_U32 is record
      Min_Incl : U32 := 0;
      Max_Excl : U32 := 0;
   end record;

   Empty_Range_IE_U32 : constant Range_IE_U32 := (Min_Incl => 0, Max_Excl => 0);

   function Make_Range_IE_U32 (Min_Incl, Max_Excl : U32) return Range_IE_U32 is
     (Min_Incl => Min_Incl, Max_Excl => Max_Excl);

   function Get_Min_Incl (R : Range_IE_U32) return U32 is (R.Min_Incl);
   function Get_Max_Excl (R : Range_IE_U32) return U32 is (R.Max_Excl);

   function Is_Empty (R : Range_IE_U32) return Boolean is
     (R.Min_Incl >= R.Max_Excl);

   function Equals (R, S : Range_IE_U32) return Boolean is
     ((R.Min_Incl = S.Min_Incl and then R.Max_Excl = S.Max_Excl)
      or else (Is_Empty (R) and then Is_Empty (S)));

   function Contains (R : Range_IE_U32; X : U32) return Boolean is
     (R.Min_Incl <= X and then X < R.Max_Excl);

   --  Exactly the points in both R and S.
   function Intersect (R, S : Range_IE_U32) return Range_IE_U32 is
     (Min_Incl => U32'Max (R.Min_Incl, S.Min_Incl),
      Max_Excl => U32'Min (R.Max_Excl, S.Max_Excl))
   with
     Post => (for all X in U32 =>
                Contains (Intersect'Result, X) = (Contains (R, X) and then Contains (S, X)));

   --  The smallest range containing both R and S: S if R is empty, R if S
   --  is empty.
   function Unite (R, S : Range_IE_U32) return Range_IE_U32 is
     (if Is_Empty (R) then S
      elsif Is_Empty (S) then R
      else (Min_Incl => U32'Min (R.Min_Incl, S.Min_Incl),
            Max_Excl => U32'Max (R.Max_Excl, S.Max_Excl)))
   with
     Post => (for all X in U32 =>
                (if Contains (R, X) or else Contains (S, X)
                 then Contains (Unite'Result, X)))
       and then (if Is_Empty (R) and then Is_Empty (S) then Is_Empty (Unite'Result));

   --  True if every point of S is in R (so always for an empty S).
   function Contains_Range (R, S : Range_IE_U32) return Boolean with
     Post => Contains_Range'Result = Equals (S, Intersect (R, S))
       and then Contains_Range'Result =
                  (for all X in U32 => (if Contains (S, X) then Contains (R, X)));

   --  Number of points in R.
   function Length (R : Range_IE_U32) return U32 is
     (if R.Max_Excl > R.Min_Incl then R.Max_Excl - R.Min_Incl else 0);

   ------------------
   -- Range_IE_U64 --
   ------------------

   type Range_IE_U64 is record
      Min_Incl : U64 := 0;
      Max_Excl : U64 := 0;
   end record;

   Empty_Range_IE_U64 : constant Range_IE_U64 := (Min_Incl => 0, Max_Excl => 0);

   function Make_Range_IE_U64 (Min_Incl, Max_Excl : U64) return Range_IE_U64 is
     (Min_Incl => Min_Incl, Max_Excl => Max_Excl);

   function Get_Min_Incl (R : Range_IE_U64) return U64 is (R.Min_Incl);
   function Get_Max_Excl (R : Range_IE_U64) return U64 is (R.Max_Excl);

   function Is_Empty (R : Range_IE_U64) return Boolean is
     (R.Min_Incl >= R.Max_Excl);

   function Equals (R, S : Range_IE_U64) return Boolean is
     ((R.Min_Incl = S.Min_Incl and then R.Max_Excl = S.Max_Excl)
      or else (Is_Empty (R) and then Is_Empty (S)));

   function Contains (R : Range_IE_U64; X : U64) return Boolean is
     (R.Min_Incl <= X and then X < R.Max_Excl);

   --  Exactly the points in both R and S.
   function Intersect (R, S : Range_IE_U64) return Range_IE_U64 is
     (Min_Incl => U64'Max (R.Min_Incl, S.Min_Incl),
      Max_Excl => U64'Min (R.Max_Excl, S.Max_Excl))
   with
     Post => (for all X in U64 =>
                Contains (Intersect'Result, X) = (Contains (R, X) and then Contains (S, X)));

   --  The smallest range containing both R and S: S if R is empty, R if S
   --  is empty.
   function Unite (R, S : Range_IE_U64) return Range_IE_U64 is
     (if Is_Empty (R) then S
      elsif Is_Empty (S) then R
      else (Min_Incl => U64'Min (R.Min_Incl, S.Min_Incl),
            Max_Excl => U64'Max (R.Max_Excl, S.Max_Excl)))
   with
     Post => (for all X in U64 =>
                (if Contains (R, X) or else Contains (S, X)
                 then Contains (Unite'Result, X)))
       and then (if Is_Empty (R) and then Is_Empty (S) then Is_Empty (Unite'Result));

   --  True if every point of S is in R (so always for an empty S).
   function Contains_Range (R, S : Range_IE_U64) return Boolean with
     Post => Contains_Range'Result = Equals (S, Intersect (R, S))
       and then Contains_Range'Result =
                  (for all X in U64 => (if Contains (S, X) then Contains (R, X)));

   --  Number of points in R.
   function Length (R : Range_IE_U64) return U64 is
     (if R.Max_Excl > R.Min_Incl then R.Max_Excl - R.Min_Incl else 0);

   ------------------
   -- Range_II_U32 --
   ------------------

   type Range_II_U32 is record
      Min_Incl : U32 := 0;
      Max_Incl : U32 := 0;
   end record;

   Empty_Range_II_U32 : constant Range_II_U32 := (Min_Incl => 0, Max_Incl => 0);

   function Make_Range_II_U32 (Min_Incl, Max_Incl : U32) return Range_II_U32 is
     (Min_Incl => Min_Incl, Max_Incl => Max_Incl);

   function Get_Min_Incl (R : Range_II_U32) return U32 is (R.Min_Incl);
   function Get_Max_Incl (R : Range_II_U32) return U32 is (R.Max_Incl);

   function Is_Empty (R : Range_II_U32) return Boolean is
     (R.Min_Incl > R.Max_Incl);

   function Equals (R, S : Range_II_U32) return Boolean is
     ((R.Min_Incl = S.Min_Incl and then R.Max_Incl = S.Max_Incl)
      or else (Is_Empty (R) and then Is_Empty (S)));

   function Contains (R : Range_II_U32; X : U32) return Boolean is
     (R.Min_Incl <= X and then X <= R.Max_Incl);

   --  Exactly the points in both R and S.
   function Intersect (R, S : Range_II_U32) return Range_II_U32 is
     (Min_Incl => U32'Max (R.Min_Incl, S.Min_Incl),
      Max_Incl => U32'Min (R.Max_Incl, S.Max_Incl))
   with
     Post => (for all X in U32 =>
                Contains (Intersect'Result, X) = (Contains (R, X) and then Contains (S, X)));

   --  The smallest range containing both R and S: S if R is empty, R if S
   --  is empty.
   function Unite (R, S : Range_II_U32) return Range_II_U32 is
     (if Is_Empty (R) then S
      elsif Is_Empty (S) then R
      else (Min_Incl => U32'Min (R.Min_Incl, S.Min_Incl),
            Max_Incl => U32'Max (R.Max_Incl, S.Max_Incl)))
   with
     Post => (for all X in U32 =>
                (if Contains (R, X) or else Contains (S, X)
                 then Contains (Unite'Result, X)))
       and then (if Is_Empty (R) and then Is_Empty (S) then Is_Empty (Unite'Result));

   --  True if every point of S is in R (so always for an empty S).
   function Contains_Range (R, S : Range_II_U32) return Boolean with
     Post => Contains_Range'Result = Equals (S, Intersect (R, S))
       and then Contains_Range'Result =
                  (for all X in U32 => (if Contains (S, X) then Contains (R, X)));

   ------------------
   -- Range_II_U64 --
   ------------------

   type Range_II_U64 is record
      Min_Incl : U64 := 0;
      Max_Incl : U64 := 0;
   end record;

   Empty_Range_II_U64 : constant Range_II_U64 := (Min_Incl => 0, Max_Incl => 0);

   function Make_Range_II_U64 (Min_Incl, Max_Incl : U64) return Range_II_U64 is
     (Min_Incl => Min_Incl, Max_Incl => Max_Incl);

   function Get_Min_Incl (R : Range_II_U64) return U64 is (R.Min_Incl);
   function Get_Max_Incl (R : Range_II_U64) return U64 is (R.Max_Incl);

   function Is_Empty (R : Range_II_U64) return Boolean is
     (R.Min_Incl > R.Max_Incl);

   function Equals (R, S : Range_II_U64) return Boolean is
     ((R.Min_Incl = S.Min_Incl and then R.Max_Incl = S.Max_Incl)
      or else (Is_Empty (R) and then Is_Empty (S)));

   function Contains (R : Range_II_U64; X : U64) return Boolean is
     (R.Min_Incl <= X and then X <= R.Max_Incl);

   --  Exactly the points in both R and S.
   function Intersect (R, S : Range_II_U64) return Range_II_U64 is
     (Min_Incl => U64'Max (R.Min_Incl, S.Min_Incl),
      Max_Incl => U64'Min (R.Max_Incl, S.Max_Incl))
   with
     Post => (for all X in U64 =>
                Contains (Intersect'Result, X) = (Contains (R, X) and then Contains (S, X)));

   --  The smallest range containing both R and S: S if R is empty, R if S
   --  is empty.
   function Unite (R, S : Range_II_U64) return Range_II_U64 is
     (if Is_Empty (R) then S
      elsif Is_Empty (S) then R
      else (Min_Incl => U64'Min (R.Min_Incl, S.Min_Incl),
            Max_Incl => U64'Max (R.Max_Incl, S.Max_Incl)))
   with
     Post => (for all X in U64 =>
                (if Contains (R, X) or else Contains (S, X)
                 then Contains (Unite'Result, X)))
       and then (if Is_Empty (R) and then Is_Empty (S) then Is_Empty (Unite'Result));

   --  True if every point of S is in R (so always for an empty S).
   function Contains_Range (R, S : Range_II_U64) return Boolean with
     Post => Contains_Range'Result = Equals (S, Intersect (R, S))
       and then Contains_Range'Result =
                  (for all X in U64 => (if Contains (S, X) then Contains (R, X)));

   -----------------
   -- Rect_IE_U32 --
   -----------------

   type Rect_IE_U32 is record
      Min_Incl_X : U32 := 0;
      Min_Incl_Y : U32 := 0;
      Max_Excl_X : U32 := 0;
      Max_Excl_Y : U32 := 0;
   end record;

   Empty_Rect_IE_U32 : constant Rect_IE_U32 :=
     (Min_Incl_X => 0, Min_Incl_Y => 0, Max_Excl_X => 0, Max_Excl_Y => 0);

   function Make_Rect_IE_U32
     (Min_Incl_X, Min_Incl_Y, Max_Excl_X, Max_Excl_Y : U32) return Rect_IE_U32
   is
     (Min_Incl_X => Min_Incl_X, Min_Incl_Y => Min_Incl_Y,
      Max_Excl_X => Max_Excl_X, Max_Excl_Y => Max_Excl_Y);

   function Is_Empty (R : Rect_IE_U32) return Boolean is
     (R.Min_Incl_X >= R.Max_Excl_X or else R.Min_Incl_Y >= R.Max_Excl_Y);

   function Equals (R, S : Rect_IE_U32) return Boolean is
     ((R.Min_Incl_X = S.Min_Incl_X and then R.Min_Incl_Y = S.Min_Incl_Y
       and then R.Max_Excl_X = S.Max_Excl_X and then R.Max_Excl_Y = S.Max_Excl_Y)
      or else (Is_Empty (R) and then Is_Empty (S)));

   function Contains (R : Rect_IE_U32; X, Y : U32) return Boolean is
     (R.Min_Incl_X <= X and then X < R.Max_Excl_X
      and then R.Min_Incl_Y <= Y and then Y < R.Max_Excl_Y);

   --  Exactly the points in both R and S.
   function Intersect (R, S : Rect_IE_U32) return Rect_IE_U32 is
     (Min_Incl_X => U32'Max (R.Min_Incl_X, S.Min_Incl_X),
      Min_Incl_Y => U32'Max (R.Min_Incl_Y, S.Min_Incl_Y),
      Max_Excl_X => U32'Min (R.Max_Excl_X, S.Max_Excl_X),
      Max_Excl_Y => U32'Min (R.Max_Excl_Y, S.Max_Excl_Y))
   with
     Post => (for all X in U32 =>
                (for all Y in U32 =>
                   Contains (Intersect'Result, X, Y) =
                     (Contains (R, X, Y) and then Contains (S, X, Y))));

   --  The smallest rect containing both R and S: S if R is empty, R if S
   --  is empty.
   function Unite (R, S : Rect_IE_U32) return Rect_IE_U32 is
     (if Is_Empty (R) then S
      elsif Is_Empty (S) then R
      else (Min_Incl_X => U32'Min (R.Min_Incl_X, S.Min_Incl_X),
            Min_Incl_Y => U32'Min (R.Min_Incl_Y, S.Min_Incl_Y),
            Max_Excl_X => U32'Max (R.Max_Excl_X, S.Max_Excl_X),
            Max_Excl_Y => U32'Max (R.Max_Excl_Y, S.Max_Excl_Y)))
   with
     Post => (for all X in U32 =>
                (for all Y in U32 =>
                   (if Contains (R, X, Y) or else Contains (S, X, Y)
                    then Contains (Unite'Result, X, Y))))
       and then (if Is_Empty (R) and then Is_Empty (S) then Is_Empty (Unite'Result));

   --  True if every point of S is in R (so always for an empty S).
   function Contains_Rect (R, S : Rect_IE_U32) return Boolean with
     Post => Contains_Rect'Result = Equals (S, Intersect (R, S))
       and then (if Contains_Rect'Result
                 then (for all X in U32 =>
                         (for all Y in U32 =>
                            (if Contains (S, X, Y) then Contains (R, X, Y)))));

   function Width (R : Rect_IE_U32) return U32 is
     (if R.Max_Excl_X > R.Min_Incl_X then R.Max_Excl_X - R.Min_Incl_X else 0);

   function Height (R : Rect_IE_U32) return U32 is
     (if R.Max_Excl_Y > R.Min_Incl_Y then R.Max_Excl_Y - R.Min_Incl_Y else 0);

   -----------------
   -- Rect_II_U32 --
   -----------------

   type Rect_II_U32 is record
      Min_Incl_X : U32 := 0;
      Min_Incl_Y : U32 := 0;
      Max_Incl_X : U32 := 0;
      Max_Incl_Y : U32 := 0;
   end record;

   Empty_Rect_II_U32 : constant Rect_II_U32 :=
     (Min_Incl_X => 0, Min_Incl_Y => 0, Max_Incl_X => 0, Max_Incl_Y => 0);

   function Make_Rect_II_U32
     (Min_Incl_X, Min_Incl_Y, Max_Incl_X, Max_Incl_Y : U32) return Rect_II_U32
   is
     (Min_Incl_X => Min_Incl_X, Min_Incl_Y => Min_Incl_Y,
      Max_Incl_X => Max_Incl_X, Max_Incl_Y => Max_Incl_Y);

   function Is_Empty (R : Rect_II_U32) return Boolean is
     (R.Min_Incl_X > R.Max_Incl_X or else R.Min_Incl_Y > R.Max_Incl_Y);

   function Equals (R, S : Rect_II_U32) return Boolean is
     ((R.Min_Incl_X = S.Min_Incl_X and then R.Min_Incl_Y = S.Min_Incl_Y
       and then R.Max_Incl_X = S.Max_Incl_X and then R.Max_Incl_Y = S.Max_Incl_Y)
      or else (Is_Empty (R) and then Is_Empty (S)));

   function Contains (R : Rect_II_U32; X, Y : U32) return Boolean is
     (R.Min_Incl_X <= X and then X <= R.Max_Incl_X
      and then R.Min_Incl_Y <= Y and then Y <= R.Max_Incl_Y);

   --  Exactly the points in both R and S.
   function Intersect (R, S : Rect_II_U32) return Rect_II_U32 is
     (Min_Incl_X => U32'Max (R.Min_Incl_X, S.Min_Incl_X),
      Min_Incl_Y => U32'Max (R.Min_Incl_Y, S.Min_Incl_Y),
      Max_Incl_X => U32'Min (R.Max_Incl_X, S.Max_Incl_X),
      Max_Incl_Y => U32'Min (R.Max_Incl_Y, S.Max_Incl_Y))
   with
     Post => (for all X in U32 =>
                (for all Y in U32 =>
                   Contains (Intersect'Result, X, Y) =
                     (Contains (R, X, Y) and then Contains (S, X, Y))));

   --  The smallest rect containing both R and S: S if R is empty, R if S
   --  is empty.
   function Unite (R, S : Rect_II_U32) return Rect_II_U32 is
     (if Is_Empty (R) then S
      elsif Is_Empty (S) then R
      else (Min_Incl_X => U32'Min (R.Min_Incl_X, S.Min_Incl_X),
            Min_Incl_Y => U32'Min (R.Min_Incl_Y, S.Min_Incl_Y),
            Max_Incl_X => U32'Max (R.Max_Incl_X, S.Max_Incl_X),
            Max_Incl_Y => U32'Max (R.Max_Incl_Y, S.Max_Incl_Y)))
   with
     Post => (for all X in U32 =>
                (for all Y in U32 =>
                   (if Contains (R, X, Y) or else Contains (S, X, Y)
                    then Contains (Unite'Result, X, Y))))
       and then (if Is_Empty (R) and then Is_Empty (S) then Is_Empty (Unite'Result));

   --  True if every point of S is in R (so always for an empty S).
   function Contains_Rect (R, S : Rect_II_U32) return Boolean with
     Post => Contains_Rect'Result = Equals (S, Intersect (R, S))
       and then (if Contains_Rect'Result
                 then (for all X in U32 =>
                         (for all Y in U32 =>
                            (if Contains (S, X, Y) then Contains (R, X, Y)))));

end Wuffs.Base.Ranges;
