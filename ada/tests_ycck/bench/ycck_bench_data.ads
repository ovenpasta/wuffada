--  The buffers of ycck_bench.adb (library level: too large for the stack).
with Wuffs; use Wuffs;

package YCCK_Bench_Data is
   W : constant := 1600;
   H : constant := 1200;

   Y       : Bytes (0 .. W * H - 1) := [others => 0];
   Cb      : Bytes (0 .. W * H / 4 - 1) := [others => 0];
   Cr      : Bytes (0 .. W * H / 4 - 1) := [others => 0];
   Dst     : Bytes (0 .. W * H * 4 - 1) := [others => 0];
   Scratch : Bytes (0 .. 2047) := [others => 0];
   Empty   : constant Bytes (1 .. 0) := [];
end YCCK_Bench_Data;
