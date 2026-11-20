--  The buffers of ycck_fuzz.adb (library level: too large for the stack).
--  Every array starts at a different index, none at 0.
with Wuffs; use Wuffs;

package YCCK_Fuzz_Data is

   Max_Src     : constant := 4_500_000;
   Max_Dst     : constant := 4_000_000;
   Max_Scratch : constant := 5_000;

   Src0    : Bytes (3 .. 3 + Max_Src - 1) := [others => 0];
   Src1    : Bytes (11 .. 11 + Max_Src - 1) := [others => 0];
   Src2    : Bytes (1001 .. 1001 + Max_Src - 1) := [others => 0];
   Src3    : Bytes (17 .. 17 + Max_Src - 1) := [others => 0];
   Dst     : Bytes (5 .. 5 + Max_Dst - 1) := [others => 0];
   Dst0    : Bytes (5 .. 5 + Max_Dst - 1) := [others => 0];
   Palette : Bytes (64 .. 64 + 1023) := [others => 0];
   Scratch : Bytes (2 ** 40 .. 2 ** 40 + Max_Scratch - 1) := [others => 0];

end YCCK_Fuzz_Data;
