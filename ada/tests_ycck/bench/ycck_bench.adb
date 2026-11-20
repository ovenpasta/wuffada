--  Benchmark of Wuffs.Base.Pixel_Swizzler_YCCK.Swizzle_YCCK, the
--  counterpart of bench_c.c: a 1600 x 1200 image, 4:2:0, BT.601 full
--  range, converted Repeats times; prints the best time per pixel of
--  Rounds rounds, in nanoseconds, and a digest of the result.  Not a test.
--  See bench.sh.
--
--  Usage: ycck_bench <destination pixel format, hex> <ycc_upsampling>

with Ada.Command_Line;
with Ada.Real_Time; use Ada.Real_Time;
with Ada.Text_IO;
with Interfaces;    use Interfaces;
with Wuffs;         use Wuffs;
with Wuffs.Base.Pixel_Buffers;
with Wuffs.Base.Pixel_Formats;
with Wuffs.Base.Pixel_Swizzler_YCCK; use Wuffs.Base.Pixel_Swizzler_YCCK;
with YCCK_Bench_Data; use YCCK_Bench_Data;

procedure YCCK_Bench is
   package PBs renames Wuffs.Base.Pixel_Buffers;

   Repeats : constant := 4;
   Rounds  : constant := 25;

   Fmt : constant U32 := U32'Value ("16#" & Ada.Command_Line.Argument (1) & "#");
   Ups : constant U8 := U8'Value (Ada.Command_Line.Argument (2));
   BPP : constant Index :=
     Index (Wuffs.Base.Pixel_Formats.Bits_Per_Pixel ((Repr => Fmt)) / 8);
   PB  : constant PBs.Pixel_Buffer :=
     (Pixcfg => (Pixfmt => (Repr => Fmt), Pixsub => (Repr => 0), Width => W,
                 Height => H),
      Planes => [0      => (Offset => 0, Width => W * BPP, Height => H,
                            Stride => W * BPP),
                 others => PBs.Empty_Table]);
   Planes : constant Source_Planes :=
     [(Width => W, Height => H, Stride => W, H => 2, V => 2),
      (Width => W / 2, Height => H / 2, Stride => W / 2, H => 1, V => 1),
      (Width => W / 2, Height => H / 2, Stride => W / 2, H => 1, V => 1),
      (Width => 0, Height => 0, Stride => 0, H => 0, V => 0)];

   package Float_IO is new Ada.Text_IO.Float_IO (Long_Float);
   package U64_IO is new Ada.Text_IO.Modular_IO (U64);

   Result : Status;
   T0     : Time;
   Per    : Long_Float;
   Best   : Long_Float := 1.0e30;
   Digest : U64 := 16#CBF2_9CE4_8422_2325#;
begin
   for I in Y'Range loop
      Y (I) := U8 (I * 7 mod 256);
   end loop;
   for I in Cb'Range loop
      Cb (I) := U8 (I * 13 mod 256);
      Cr (I) := U8 (I * 29 mod 256);
   end loop;
   for Round in 1 .. Rounds loop
      T0 := Clock;
      for I in 1 .. Repeats loop
         Swizzle_YCCK
           (PB, Dst (0 .. W * H * BPP - 1), Empty, Empty, 0, W, 0, H, Y, Cb, Cr, Empty,
            Planes, 0, Ups, Scratch, Result);
         if not Is_Ok (Result) then
            Ada.Text_IO.Put_Line ("error");
            Ada.Command_Line.Set_Exit_Status (Ada.Command_Line.Failure);
            return;
         end if;
      end loop;
      Per := Long_Float (To_Duration (Clock - T0)) * 1.0e9
        / (Long_Float (Repeats) * Long_Float (W) * Long_Float (H));
      Best := Long_Float'Min (Best, Per);
   end loop;
   for B of Dst loop
      Digest := (Digest xor U64 (B)) * 16#100_0000_01B3#;
   end loop;
   Float_IO.Put (Best, Fore => 1, Aft => 2, Exp => 0);
   Ada.Text_IO.Put (" ");
   U64_IO.Put (Digest, Width => 20, Base => 16);
   Ada.Text_IO.New_Line;
end YCCK_Bench;
