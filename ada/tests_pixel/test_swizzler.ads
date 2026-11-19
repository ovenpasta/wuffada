--  Wuffs.Base.Pixel_Swizzler (and through it every row function of
--  Wuffs.Base.Pixel_Rows).  A package rather than a procedure so that its
--  row buffers are library-level objects, not stack frames.

package Test_Swizzler is

   procedure Run;

end Test_Swizzler;
