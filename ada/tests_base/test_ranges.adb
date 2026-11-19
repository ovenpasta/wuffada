--  Wuffs.Base.Ranges.  The six sweeps mirror RANGE_SWEEP and RECT_SWEEP in
--  oracle/oracle.c, one instantiation per type.

with Base_Oracle_Data;
with Base_Test_Support; use Base_Test_Support;
with Interfaces;
with Wuffs.Base.Ranges;

procedure Test_Ranges is

   use Wuffs;
   use Wuffs.Base.Ranges;
   use type Interfaces.Unsigned_32;
   use type Interfaces.Unsigned_64;

   -----------------
   -- Range sweep --
   -----------------

   generic
      type U is mod <>;
      type R is private;
      with function Make (Lo, Hi : U) return R;
      with function Lo_Of (X : R) return U;
      with function Hi_Of (X : R) return U;
      with function Is_Empty (X : R) return Boolean is <>;
      with function Equals (X, Y : R) return Boolean is <>;
      with function Intersect (X, Y : R) return R is <>;
      with function Unite (X, Y : R) return R is <>;
      with function Contains (X : R; P : U) return Boolean is <>;
      with function Contains_Range (X, Y : R) return Boolean is <>;
      Has_Length : Boolean;
      with function Length (X : R) return U;
   procedure Range_Sweep;

   procedure Range_Sweep is
      --  The values S32 / S64 of the oracle.
      S : constant array (0 .. 5) of U := [0, 1, 2, 5, U'Last - 1, U'Last];
   begin
      for A of S loop
         for B of S loop
            for C of S loop
               for D of S loop
                  declare
                     X : constant R := Make (A, B);
                     Y : constant R := Make (C, D);
                     T : constant R := Intersect (X, Y);
                     V : constant R := Unite (X, Y);
                  begin
                     Mix (Is_Empty (X));
                     Mix (Equals (X, Y));
                     Mix (U64 (Lo_Of (T)));
                     Mix (U64 (Hi_Of (T)));
                     Mix (U64 (Lo_Of (V)));
                     Mix (U64 (Hi_Of (V)));
                     Mix (Contains_Range (X, Y));
                     if Has_Length then
                        Mix (U64 (Length (X)));
                     end if;
                     for P of S loop
                        Mix (Contains (X, P));
                     end loop;
                  end;
               end loop;
            end loop;
         end loop;
      end loop;
   end Range_Sweep;

   --  Stand-ins for the Length that the "ii" ranges do not have.
   function No_Length (Unused : Range_II_U32) return U32 is (0);
   function No_Length (Unused : Range_II_U64) return U64 is (0);

   procedure Sweep_IE_U32 is new Range_Sweep
     (U => U32, R => Range_IE_U32, Make => Make_Range_IE_U32,
      Lo_Of => Get_Min_Incl, Hi_Of => Get_Max_Excl, Has_Length => True, Length => Length);
   procedure Sweep_II_U32 is new Range_Sweep
     (U => U32, R => Range_II_U32, Make => Make_Range_II_U32,
      Lo_Of => Get_Min_Incl, Hi_Of => Get_Max_Incl, Has_Length => False, Length => No_Length);
   procedure Sweep_IE_U64 is new Range_Sweep
     (U => U64, R => Range_IE_U64, Make => Make_Range_IE_U64,
      Lo_Of => Get_Min_Incl, Hi_Of => Get_Max_Excl, Has_Length => True, Length => Length);
   procedure Sweep_II_U64 is new Range_Sweep
     (U => U64, R => Range_II_U64, Make => Make_Range_II_U64,
      Lo_Of => Get_Min_Incl, Hi_Of => Get_Max_Incl, Has_Length => False, Length => No_Length);

   ----------------
   -- Rect sweep --
   ----------------

   type Corners is array (0 .. 3) of U32;

   generic
      type R is private;
      with function Make (X0, Y0, X1, Y1 : U32) return R;
      with function Corners_Of (X : R) return Corners;
      with function Is_Empty (X : R) return Boolean is <>;
      with function Equals (X, Y : R) return Boolean is <>;
      with function Intersect (X, Y : R) return R is <>;
      with function Unite (X, Y : R) return R is <>;
      with function Contains (X : R; PX, PY : U32) return Boolean is <>;
      with function Contains_Rect (X, Y : R) return Boolean is <>;
      Has_Size : Boolean;
      with function Width (X : R) return U32;
      with function Height (X : R) return U32;
   procedure Rect_Sweep;

   procedure Rect_Sweep is
      --  The values R32 of the oracle.
      S : constant array (0 .. 3) of U32 := [0, 1, 3, U32'Last];
   begin
      for A of S loop
         for B of S loop
            for C of S loop
               for D of S loop
                  for E of S loop
                     for F of S loop
                        for G of S loop
                           for H of S loop
                              declare
                                 X : constant R := Make (A, B, C, D);
                                 Y : constant R := Make (E, F, G, H);
                              begin
                                 Mix (Is_Empty (X));
                                 Mix (Equals (X, Y));
                                 for K of Corners_Of (Intersect (X, Y)) loop
                                    Mix (U64 (K));
                                 end loop;
                                 for K of Corners_Of (Unite (X, Y)) loop
                                    Mix (U64 (K));
                                 end loop;
                                 Mix (Contains_Rect (X, Y));
                                 if Has_Size then
                                    Mix (U64 (Width (X)));
                                    Mix (U64 (Height (X)));
                                 end if;
                                 for PX of S loop
                                    for PY of S loop
                                       Mix (Contains (X, PX, PY));
                                    end loop;
                                 end loop;
                              end;
                           end loop;
                        end loop;
                     end loop;
                  end loop;
               end loop;
            end loop;
         end loop;
      end loop;
   end Rect_Sweep;

   function Corners_Of (X : Rect_IE_U32) return Corners is
     [X.Min_Incl_X, X.Min_Incl_Y, X.Max_Excl_X, X.Max_Excl_Y];
   function Corners_Of (X : Rect_II_U32) return Corners is
     [X.Min_Incl_X, X.Min_Incl_Y, X.Max_Incl_X, X.Max_Incl_Y];
   function No_Size (Unused : Rect_II_U32) return U32 is (0);

   procedure Sweep_Rect_IE is new Rect_Sweep
     (R => Rect_IE_U32, Make => Make_Rect_IE_U32, Corners_Of => Corners_Of,
      Has_Size => True, Width => Width, Height => Height);
   procedure Sweep_Rect_II is new Rect_Sweep
     (R => Rect_II_U32, Make => Make_Rect_II_U32, Corners_Of => Corners_Of,
      Has_Size => False, Width => No_Size, Height => No_Size);

begin
   Start (6);
   Sweep_IE_U32;
   Finish ("ranges: sweep Range_IE_U32", Base_Oracle_Data.Range_IE_U32);
   Start (7);
   Sweep_II_U32;
   Finish ("ranges: sweep Range_II_U32", Base_Oracle_Data.Range_II_U32);
   Start (8);
   Sweep_IE_U64;
   Finish ("ranges: sweep Range_IE_U64", Base_Oracle_Data.Range_IE_U64);
   Start (9);
   Sweep_II_U64;
   Finish ("ranges: sweep Range_II_U64", Base_Oracle_Data.Range_II_U64);
   Start (10);
   Sweep_Rect_IE;
   Finish ("ranges: sweep Rect_IE_U32", Base_Oracle_Data.Rect_IE_U32);
   Start (11);
   Sweep_Rect_II;
   Finish ("ranges: sweep Rect_II_U32", Base_Oracle_Data.Rect_II_U32);

   --------------------
   -- Explicit cases --
   --------------------

   --  The zero values: empty for "ie", the single point 0 for "ii".
   declare
      IE : Range_IE_U32;
      II : Range_II_U32;
      RE : Rect_IE_U32;
      RI : Rect_II_U32;
   begin
      Check (IE = Empty_Range_IE_U32 and then Is_Empty (IE), "ranges: default ie is empty");
      Check (II = Empty_Range_II_U32 and then not Is_Empty (II), "ranges: default ii has 0");
      Check (Contains (II, 0) and then not Contains (II, 1), "ranges: default ii contains 0");
      Check (Length (IE) = 0, "ranges: default ie length");
      Check (RE = Empty_Rect_IE_U32 and then Is_Empty (RE), "ranges: default rect ie is empty");
      Check (RI = Empty_Rect_II_U32 and then not Is_Empty (RI), "ranges: default rect ii");
      Check (Contains (RI, 0, 0) and then not Contains (RI, 0, 1), "ranges: rect ii point");
      Check (Width (RE) = 0 and then Height (RE) = 0, "ranges: default rect ie size");
      Check (Is_Empty (Empty_Range_IE_U64), "ranges: default ie u64 is empty");
      Check (not Is_Empty (Empty_Range_II_U64), "ranges: default ii u64 has 0");
   end;

   --  Ordinary intervals, the example of the Wuffs documentation: [3, 8).
   declare
      A : constant Range_IE_U32 := Make_Range_IE_U32 (3, 8);
      B : constant Range_IE_U32 := Make_Range_IE_U32 (6, 20);
      C : constant Range_IE_U32 := Make_Range_IE_U32 (9, 9);
      D : constant Range_IE_U32 := Make_Range_IE_U32 (50, 10);
   begin
      Check (Length (A) = 5, "ranges: ie length");
      Check (Contains (A, 3) and then Contains (A, 7), "ranges: ie contains ends");
      Check (not Contains (A, 2) and then not Contains (A, 8), "ranges: ie excludes");
      Check (Intersect (A, B) = Make_Range_IE_U32 (6, 8), "ranges: ie intersect");
      Check (Unite (A, B) = Make_Range_IE_U32 (3, 20), "ranges: ie unite");
      Check (Is_Empty (C) and then Is_Empty (D), "ranges: ie empties");
      Check (Length (D) = 0, "ranges: ie length saturates");
      Check (Equals (C, D) and then C /= D, "ranges: empties are Equals");
      Check (Unite (A, D) = A and then Unite (D, A) = A, "ranges: unite with empty");
      Check (Unite (C, D) = D, "ranges: unite of two empties is the second");
      Check (Is_Empty (Intersect (A, C)), "ranges: intersect with empty");
      Check (Contains_Range (A, Make_Range_IE_U32 (4, 8)), "ranges: contains_range inside");
      Check (not Contains_Range (A, B), "ranges: contains_range overlap");
      Check (Contains_Range (A, D), "ranges: contains_range of empty");
      Check (not Contains_Range (D, A), "ranges: empty contains_range");
      Check (Length (Make_Range_IE_U32 (0, U32'Last)) = U32'Last, "ranges: ie max length");
   end;

   declare
      A : constant Range_II_U64 := Make_Range_II_U64 (3, 7);
      B : constant Range_II_U64 := Make_Range_II_U64 (7, U64'Last);
      E : constant Range_II_U64 := Make_Range_II_U64 (8, 7);
   begin
      Check (Contains (A, 3) and then Contains (A, 7), "ranges: ii contains ends");
      Check (not Contains (A, 8), "ranges: ii excludes");
      Check (Intersect (A, B) = Make_Range_II_U64 (7, 7), "ranges: ii intersect one point");
      Check (not Is_Empty (Intersect (A, B)), "ranges: ii one point is not empty");
      Check (Unite (A, B) = Make_Range_II_U64 (3, U64'Last), "ranges: ii unite");
      Check (Contains (B, U64'Last), "ranges: ii contains max");
      Check (Is_Empty (E) and then Unite (E, A) = A, "ranges: ii empty");
      Check (Contains_Range (B, Make_Range_II_U64 (U64'Last, U64'Last)),
             "ranges: ii contains_range max point");
   end;

   declare
      A : constant Rect_IE_U32 := Make_Rect_IE_U32 (1, 2, 5, 9);
      B : constant Rect_IE_U32 := Make_Rect_IE_U32 (3, 0, 10, 4);
      E : constant Rect_IE_U32 := Make_Rect_IE_U32 (3, 3, 3, 10);
   begin
      Check (Width (A) = 4 and then Height (A) = 7, "ranges: rect size");
      Check (Contains (A, 1, 2) and then Contains (A, 4, 8), "ranges: rect contains corners");
      Check (not Contains (A, 5, 2) and then not Contains (A, 1, 9), "ranges: rect excludes");
      Check (Intersect (A, B) = Make_Rect_IE_U32 (3, 2, 5, 4), "ranges: rect intersect");
      Check (Unite (A, B) = Make_Rect_IE_U32 (1, 0, 10, 9), "ranges: rect unite");
      Check (Is_Empty (E), "ranges: rect empty in one dimension");
      Check (Width (E) = 0 and then Height (E) = 7, "ranges: rect empty size");
      Check (Unite (A, E) = A and then Unite (E, A) = A, "ranges: rect unite with empty");
      Check (Contains_Rect (A, Make_Rect_IE_U32 (2, 3, 5, 9)), "ranges: contains_rect inside");
      Check (not Contains_Rect (A, B), "ranges: contains_rect overlap");
      Check (Contains_Rect (A, E), "ranges: contains_rect of empty");
      Check (Equals (E, Empty_Rect_IE_U32), "ranges: rect empties are Equals");
   end;

   declare
      A : constant Rect_II_U32 := Make_Rect_II_U32 (1, 2, 5, 9);
      B : constant Rect_II_U32 := Make_Rect_II_U32 (5, 9, U32'Last, U32'Last);
   begin
      Check (Contains (A, 5, 9), "ranges: rect ii contains max corner");
      Check (Intersect (A, B) = Make_Rect_II_U32 (5, 9, 5, 9), "ranges: rect ii intersect");
      Check (not Is_Empty (Intersect (A, B)), "ranges: rect ii one point");
      Check (Unite (A, B) = Make_Rect_II_U32 (1, 2, U32'Last, U32'Last),
             "ranges: rect ii unite");
      Check (Is_Empty (Make_Rect_II_U32 (2, 0, 1, 0)), "ranges: rect ii empty");
   end;
end Test_Ranges;
