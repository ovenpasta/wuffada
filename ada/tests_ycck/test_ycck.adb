with Interfaces;
with Wuffs.Base.Color_YCC;
with Wuffs.Base.Pixel_Buffers;
with Wuffs.Base.Pixel_Formats;
with Wuffs.Base.Pixel_Swizzler_YCCK;
with Wuffs;
with YCCK_Oracle_Data;
with YCCK_Test_Support;

package body Test_YCCK is

   use Interfaces;
   use Wuffs;
   use Wuffs.Base.Pixel_Swizzler_YCCK;
   use YCCK_Test_Support;

   package PF renames Wuffs.Base.Pixel_Formats;
   package PBs renames Wuffs.Base.Pixel_Buffers;
   package OD renames YCCK_Oracle_Data;

   --  The oracle's FORMATS and ACCEPTED.
   Formats : constant array (U32 range 0 .. 33) of U32 :=
     [16#0200_0008#, 16#2000_0008#, 16#2000_000B#, 16#2010_000B#, 16#2100_0088#,
      16#2200_0088#, 16#3000_8888#, 16#8104_0008#, 16#8204_0008#, 16#8304_0008#,
      16#8000_0565#, 16#8000_0888#, 16#8100_8888#, 16#8100_BBBB#, 16#8200_8888#,
      16#8200_BBBB#, 16#8300_8888#, 16#9000_8888#, 16#A000_0888#, 16#A100_8888#,
      16#A100_BBBB#, 16#A200_8888#, 16#A200_BBBB#, 16#A300_8888#, 16#B000_8888#,
      16#4002_0888#, 16#4103_8888#, 16#5003_8888#, 16#6002_0888#, 16#6103_8888#,
      16#7003_8888#, 16#C002_0888#, 16#D003_8888#, 16#0000_0000#];

   Accepted : constant array (U32 range 0 .. 16) of U32 :=
     [16#8100_8888#, 16#9000_8888#, 16#A000_0888#, 16#8000_0888#, 16#8000_0565#,
      16#2000_0008#, 16#2000_000B#, 16#2010_000B#, 16#2100_0088#, 16#8104_0008#,
      16#8204_0008#, 16#8304_0008#, 16#8200_8888#, 16#8100_BBBB#, 16#A100_8888#,
      16#A200_8888#, 16#B000_8888#];

   --  The oracle's test_bpp.
   function Test_BPP (Fmt : U32) return U32 is
     (if (for some A of Accepted => A = Fmt)
      then PF.Bits_Per_Pixel ((Repr => Fmt)) / 8
      else 8);

   type Quad is array (0 .. 3) of U32;
   type Lengths is array (0 .. 3) of Index;
   type HV_Array is array (0 .. 7) of U32;  --  h0 v0 h1 v1 h2 v2 h3 v3

   --  The oracle's call_t.
   type Call is record
      Fmt            : U32 := 0;
      DW, DH, DPad   : U32 := 0;
      DOff, DMode    : U32 := 0;
      No_Pal         : Boolean := False;
      X0, X1, Y0, Y1 : U32 := 0;
      W, H, S        : Quad := [others => 0];
      HH, VV         : Quad := [others => 0];
      Len            : Lengths := [others => 0];
      Model, Ups     : U32 := 0;
      Scratch_Len    : Index := 0;
      Mode           : U32 := 0;
   end record;

   Max_Src : constant := 2_400_000;
   Max_Dst : constant := 8_000_000;

   --  Library level: far too large for the stack.  Every array starts at a
   --  different index, none at 0, so that code that forgot an array's 'First
   --  cannot pass.
   B0 : constant := 3;
   B1 : constant := 5;
   B2 : constant := 1001;
   B3 : constant := 64;
   DB : constant := 7;

   Src0    : Bytes (B0 .. B0 + Max_Src - 1) := [others => 0];
   Src1    : Bytes (B1 .. B1 + Max_Src - 1) := [others => 0];
   Src2    : Bytes (B2 .. B2 + Max_Src - 1) := [others => 0];
   Src3    : Bytes (B3 .. B3 + Max_Src - 1) := [others => 0];
   Dst     : Bytes (DB .. DB + Max_Dst - 1) := [others => 0];
   Dst2    : Bytes (DB .. DB + 1_000_000 - 1) := [others => 0];
   Palette : Bytes (29 .. 29 + 1023) := [others => 0];
   Scratch : Bytes (17 .. 17 + 2048) := [others => 0];

   type Count_Array is array (U32 range 0 .. 3) of Long_Long_Integer;
   Status_Counts : Count_Array := [others => 0];
   Calls         : Long_Long_Integer := 0;
   Pixels_Done   : Long_Long_Integer := 0;

   function Flat (W, H, S : U32) return Index is
     (if H = 0 then 0 else Index (H - 1) * Index (S) + Index (W));

   function Code (S : Status) return U32 is
     (if S = Ok_Status then 0
      elsif S = Wuffs.Base.Error_Bad_Argument then 1
      elsif S = Wuffs.Base.Error_Unsupported_Pixel_Swizzler_Option then 2
      else 3);

   function Dst_Len (C : Call) return Index;
   procedure Invoke (C : Call; Off : Lengths; Pixels : in out Bytes; K : out U32);
   procedure Run (C : Call);
   function GCD (A, B : U32) return U32;
   function Make
     (HV               : HV_Array;
      DX, DY           : U32;
      X0N, Y0N         : U32;
      Extra_W, Extra_H : U32;
      SPad             : U32;
      DDW, DDH         : Integer) return Call;
   procedure Reset_Counts;
   procedure Check_Counts
     (Name                                       : String;
      N_Calls, N_Ok, N_Bad, N_Unsupported, N_Pix : Long_Long_Integer);
   procedure Sweep_Colors;
   procedure Sweep_Formats;
   procedure Sweep_Sampling;
   procedure Sweep_Sizes;
   procedure Sweep_Large;
   procedure Change (C : in out Call; Kind : U32; K : Natural);
   procedure Sweep_Errors;
   procedure Sweep_Origins;
   procedure Sweep_Bands;
   procedure Sweep_Order;
   procedure Sweep_Limits;

   -------------
   -- Dst_Len --
   -------------

   function Dst_Len (C : Call) return Index is
     (Index (C.DOff)
      + (Index (C.DW * Test_BPP (C.Fmt)) + Index (C.DPad)) * Index (C.DH));

   ------------
   -- Invoke --
   ------------

   --  The oracle's call: the planes are the C.Len (K) bytes of SrcK from
   --  Off (K), the destination is Pixels, the scratch buffer is the first
   --  C.Scratch_Len bytes of Scratch.  K is the status code.
   procedure Invoke (C : Call; Off : Lengths; Pixels : in out Bytes; K : out U32) is
      BPP     : constant U32 := Test_BPP (C.Fmt);
      DStride : constant Index := Index (C.DW * BPP) + Index (C.DPad);
      PB      : PBs.Pixel_Buffer;
      Result  : Status;
   begin
      PB :=
        (Pixcfg => (Pixfmt => (Repr => C.Fmt),
                    Pixsub => (Repr => 0),
                    Width  => C.DW,
                    Height => C.DH),
         Planes => [0      => (Offset => Index (C.DOff),
                               Width  => Index (C.DW * BPP),
                               Height => Index (C.DH),
                               Stride => DStride),
                    3      => (if PF.Is_Indexed ((Repr => C.Fmt)) and then not C.No_Pal
                               then (Offset => 0, Width => 1024, Height => 1,
                                     Stride => 1024)
                               else PBs.Empty_Table),
                    others => PBs.Empty_Table]);
      Swizzle_YCCK
        (PB                => PB,
         Pixels            => Pixels,
         Palette           => Palette,
         Dst_Palette       => Palette,
         X_Min_Incl        => C.X0,
         X_Max_Excl        => C.X1,
         Y_Min_Incl        => C.Y0,
         Y_Max_Excl        => C.Y1,
         Src0              => Src0 (B0 + Off (0) .. B0 + Off (0) + C.Len (0) - 1),
         Src1              => Src1 (B1 + Off (1) .. B1 + Off (1) + C.Len (1) - 1),
         Src2              => Src2 (B2 + Off (2) .. B2 + Off (2) + C.Len (2) - 1),
         Src3              => Src3 (B3 + Off (3) .. B3 + Off (3) + C.Len (3) - 1),
         Planes            =>
           [for I in 0 .. 3 =>
              (Width  => C.W (I),
               Height => C.H (I),
               Stride => C.S (I),
               H      => U8 (C.HH (I)),
               V      => U8 (C.VV (I)))],
         YCC_Model         => U8 (C.Model),
         YCC_Upsampling    => U8 (C.Ups),
         Scratch_Buffer_2K => Scratch (17 .. 17 + C.Scratch_Len - 1),
         Result            => Result);
      K := Code (Result);
      Status_Counts (K) := Status_Counts (K) + 1;
      Calls := Calls + 1;
      if K = 0 then
         Pixels_Done := Pixels_Done + Long_Long_Integer (C.DW) * Long_Long_Integer (C.DH);
      end if;
   end Invoke;

   ---------
   -- Run --
   ---------

   --  The oracle's run: makes the call on fresh random planes, destination
   --  and scratch buffer and mixes the status, the whole destination and the
   --  whole scratch buffer.
   procedure Run (C : Call) is
      DLen : constant Index := Dst_Len (C);
      K    : U32;
   begin
      Fill (Src0 (B0 .. B0 + C.Len (0) - 1), C.Mode);
      Fill (Src1 (B1 .. B1 + C.Len (1) - 1), C.Mode);
      Fill (Src2 (B2 .. B2 + C.Len (2) - 1), C.Mode);
      Fill (Src3 (B3 .. B3 + C.Len (3) - 1), C.Mode);
      Fill (Dst (DB .. DB + DLen - 1), C.DMode);
      Fill (Scratch (17 .. 17 + C.Scratch_Len - 1), 0);
      Invoke (C, [others => 0], Dst (DB .. DB + DLen - 1), K);
      Mix (U64 (K));
      Mix_Bytes (Dst (DB .. DB + DLen - 1));
      Mix_Bytes (Scratch (17 .. 17 + C.Scratch_Len - 1));
   end Run;

   function GCD (A, B : U32) return U32 is
      X : U32 := A;
      Y : U32 := B;
      T : U32;
   begin
      while Y /= 0 loop
         T := X mod Y;
         X := Y;
         Y := T;
      end loop;
      return X;
   end GCD;

   ----------
   -- Make --
   ----------

   --  The oracle's make.
   function Make
     (HV               : HV_Array;
      DX, DY           : U32;
      X0N, Y0N         : U32;
      Extra_W, Extra_H : U32;
      SPad             : U32;
      DDW, DDH         : Integer) return Call
   is
      C            : Call;
      Max_H, Max_V : U32 := 1;
      Inv_H, Inv_V : Quad;
      LH, LV       : U32 := 1;
      EW, EH       : U32;
      DW, DH       : Integer;
   begin
      for K in 0 .. 3 loop
         C.HH (K) := HV (2 * K);
         C.VV (K) := HV (2 * K + 1);
         Max_H := U32'Max (Max_H, C.HH (K));
         Max_V := U32'Max (Max_V, C.VV (K));
      end loop;
      for K in 0 .. 3 loop
         Inv_H (K) := (if C.HH (K) = 0 then 1 else Max_H / C.HH (K));
         Inv_V (K) := (if C.VV (K) = 0 then 1 else Max_V / C.VV (K));
         LH := (LH * Inv_H (K)) / GCD (LH, Inv_H (K));
         LV := (LV * Inv_V (K)) / GCD (LV, Inv_V (K));
      end loop;
      EW := LH * ((DX + LH - 1) / LH + Extra_W);
      EH := LV * ((DY + LV - 1) / LV + Extra_H);
      for K in 0 .. 3 loop
         C.W (K) := EW / Inv_H (K);
         C.H (K) := EH / Inv_V (K);
         C.S (K) := C.W (K) + SPad;
         C.Len (K) := Flat (C.W (K), C.H (K), C.S (K));
      end loop;
      if C.HH (3) = 0 and then C.VV (3) = 0 then
         C.W (3) := 0;
         C.H (3) := 0;
         C.S (3) := 0;
         C.Len (3) := 0;
      end if;
      C.X0 := X0N * LH;
      C.Y0 := Y0N * LV;
      C.X1 := C.X0 + DX;
      C.Y1 := C.Y0 + DY;
      DW := Integer (C.X1) + DDW;
      DH := Integer (C.Y1) + DDH;
      C.DW := (if DW < 0 then 0 else U32 (DW));
      C.DH := (if DH < 0 then 0 else U32 (DH));
      C.DPad := SPad;
      C.DOff := SPad * 5;
      C.DMode := 0;
      C.Scratch_Len := 2048;
      C.Mode := 0;
      C.Fmt := 16#8100_8888#;
      C.Model := 0;
      C.Ups := 0;
      return C;
   end Make;

   procedure Reset_Counts is
   begin
      Status_Counts := [others => 0];
      Calls := 0;
      Pixels_Done := 0;
   end Reset_Counts;

   procedure Check_Counts
     (Name                                       : String;
      N_Calls, N_Ok, N_Bad, N_Unsupported, N_Pix : Long_Long_Integer) is
   begin
      Check_Count (Name, "calls", Calls, N_Calls);
      Check_Count (Name, "accepted (ok)", Status_Counts (0), N_Ok);
      Check_Count (Name, "rejected (bad argument)", Status_Counts (1), N_Bad);
      Check_Count
        (Name, "rejected (unsupported option)", Status_Counts (2), N_Unsupported);
      Check_Count (Name, "other statuses", Status_Counts (3), 0);
      Check_Count (Name, "pixels", Pixels_Done, N_Pix);
   end Check_Counts;

   ------------------
   -- Sweep_Colors --
   ------------------

   procedure Sweep_Colors is
      use Wuffs.Base.Color_YCC;
   begin
      Start (1);
      for Y in U8 loop
         for Cb in U8 loop
            for Cr in U8 loop
               Mix (U64 (YCC_BT601FR_As_Color_U32 (Y, Cb, Cr)));
               Mix (U64 (YCC_BT601FR_As_Color_U32_ABGR (Y, Cb, Cr)));
               Mix (U64 (YCC_BT601SR_As_Color_U32 (Y, Cb, Cr)));
               Mix (U64 (YCC_BT601SR_As_Color_U32_ABGR (Y, Cb, Cr)));
            end loop;
         end loop;
         if Y mod 16 = 15 then
            Mark (OD.YCC_Colors_Marks, "YCC_Colors, Y up to", Integer (Y));
         end if;
      end loop;
      Finish ("YCC_Colors", OD.YCC_Colors);
   end Sweep_Colors;

   Models   : constant array (U32 range 0 .. 7) of U32 :=
     [16#00#, 16#04#, 16#06#, 16#07#, 16#40#, 16#80#, 16#01#, 16#FF#];
   Models_3 : constant array (U32 range 0 .. 2) of U32 := [16#00#, 16#04#, 16#40#];
   Models_4 : constant array (U32 range 0 .. 3) of U32 :=
     [16#00#, 16#06#, 16#07#, 16#80#];
   HV_420_3 : constant HV_Array := [2, 2, 1, 1, 1, 1, 0, 0];
   HV_420_4 : constant HV_Array := [2, 2, 1, 1, 1, 1, 2, 2];
   Sizes    : constant array (U32 range 0 .. 10) of U32 :=
     [0, 1, 2, 3, 7, 8, 9, 15, 16, 17, 33];

   -------------------
   -- Sweep_Formats --
   -------------------

   procedure Sweep_Formats is
      C : Call;
   begin
      Start (2);
      Reset_Counts;
      Fill (Palette, 0);
      for F in Formats'Range loop
         for M in Models'Range loop
            for Four in Boolean loop
               for Ups in U32 range 0 .. 2 loop
                  for SM in U32 range 0 .. 3 loop
                     C := Make ((if Four then HV_420_4 else HV_420_3), 9, 7, 0, 0, 0,
                                0, F mod 3, 0, 0);
                     C.Fmt := Formats (F);
                     C.Model := Models (M);
                     C.Ups := Ups;
                     C.Mode := SM mod 3;
                     C.DMode := (if SM = 1 then 1 else 0);
                     C.No_Pal := SM = 3;
                     Run (C);
                  end loop;
               end loop;
            end loop;
         end loop;
         Mark (OD.YCCK_Formats_Marks, "YCCK_Formats, format number", Integer (F));
      end loop;
      Finish ("YCCK_Formats", OD.YCCK_Formats);
      Check_Counts
        ("YCCK_Formats", OD.YCCK_Formats_Calls, OD.YCCK_Formats_Ok,
         OD.YCCK_Formats_Bad_Argument, OD.YCCK_Formats_Unsupported,
         OD.YCCK_Formats_Pixels);
   end Sweep_Formats;

   --------------------
   -- Sweep_Sampling --
   --------------------

   procedure Sweep_Sampling is
      HV               : HV_Array := [others => 0];
      C                : Call;
      Four             : U32;
      DX, DY           : U32;
      X0N, Y0N         : U32;
      Extra_W, Extra_H : U32;
      SPad             : U32;
      DDW, DDH         : Integer;
   begin
      Start (3);
      Reset_Counts;
      Fill (Palette, 0);
      for Ups in U32 range 0 .. 2 loop
         for H0 in U32 range 1 .. 4 loop
            for V0 in U32 range 1 .. 4 loop
               for H1 in U32 range 1 .. 4 loop
                  for V1 in U32 range 1 .. 4 loop
                     for H2 in U32 range 1 .. 4 loop
                        for V2 in U32 range 1 .. 4 loop
                           HV (0 .. 5) := [H0, V0, H1, V1, H2, V2];
                           Four := Pick (8);
                           if Four < 3 then
                              HV (6) := 1 + Pick (4);
                              HV (7) := 1 + Pick (4);
                           elsif Four = 3 then
                              HV (6) := Pick (5);
                              HV (7) := Pick (5);
                           else
                              HV (6) := 0;
                              HV (7) := 0;
                           end if;
                           DX := Sizes (Pick (11));
                           DY := Sizes (Pick (11));
                           X0N := 0;
                           Y0N := 0;
                           if Ups = 0 and then Pick (3) = 0 then
                              X0N := Pick (3);
                              Y0N := Pick (3);
                           end if;
                           Extra_W := Pick (2);
                           Extra_H := Pick (2);
                           SPad := Pick (3);
                           DDW := Integer (Pick (3)) - 1;
                           DDH := Integer (Pick (3)) - 1;
                           C := Make (HV, DX, DY, X0N, Y0N, Extra_W, Extra_H, SPad,
                                      DDW, DDH);
                           C.Fmt := Accepted (Pick (17));
                           C.Model := (if (HV (6) or HV (7)) /= 0
                                       then Models_4 (Pick (4))
                                       else Models_3 (Pick (3)));
                           C.Ups := Ups;
                           C.Mode := Pick (5);
                           Run (C);
                        end loop;
                     end loop;
                  end loop;
               end loop;
               Mark (OD.YCCK_Sampling_Marks,
                     "YCCK_Sampling, upsampling, 10 * h0 + v0",
                     Integer (Ups), Integer (10 * H0 + V0));
            end loop;
         end loop;
      end loop;
      Finish ("YCCK_Sampling", OD.YCCK_Sampling);
      Check_Counts
        ("YCCK_Sampling", OD.YCCK_Sampling_Calls, OD.YCCK_Sampling_Ok,
         OD.YCCK_Sampling_Bad_Argument, OD.YCCK_Sampling_Unsupported,
         OD.YCCK_Sampling_Pixels);
   end Sweep_Sampling;

   Layouts : constant array (U32 range 0 .. 13) of HV_Array :=
     [[1, 1, 1, 1, 1, 1, 0, 0],
      [2, 1, 1, 1, 1, 1, 0, 0],
      [1, 2, 1, 1, 1, 1, 0, 0],
      [2, 2, 1, 1, 1, 1, 0, 0],
      [4, 1, 1, 1, 1, 1, 0, 0],
      [4, 2, 1, 1, 1, 1, 0, 0],
      [1, 1, 2, 2, 2, 2, 0, 0],
      [2, 2, 2, 1, 1, 2, 0, 0],
      [3, 3, 1, 1, 3, 1, 0, 0],
      [1, 1, 1, 1, 1, 1, 1, 1],
      [2, 2, 1, 1, 1, 1, 2, 2],
      [2, 2, 1, 2, 2, 1, 1, 1],
      [4, 1, 1, 1, 2, 1, 4, 1],
      [3, 1, 1, 1, 3, 1, 1, 1]];
   Widths  : constant array (U32 range 0 .. 31) of U32 :=
     [0, 1, 2, 3, 7, 8, 9, 15, 16, 17, 33, 479, 480, 481, 671, 672, 673, 959, 960,
      961, 1343, 1344, 1345, 1439, 1440, 1441, 1919, 1920, 1921, 2015, 2016, 2017];
   Tall    : constant array (U32 range 0 .. 3) of U32 := [1, 2, 3, 9];

   -----------------
   -- Sweep_Sizes --
   -----------------

   procedure Sweep_Sizes is
      C     : Call;
      N     : U32 := 0;
      Num_H : U32;
      DY    : U32;
      Clip  : Integer;
   begin
      Start (4);
      Reset_Counts;
      Fill (Palette, 0);
      for L in Layouts'Range loop
         for Ups in U32 range 0 .. 2 loop
            for WI in Widths'Range loop
               Num_H := (if WI < 11 then 11 else 4);
               for HI in 0 .. Num_H - 1 loop
                  DY := (if WI < 11 then Sizes (HI) else Tall (HI));
                  Clip := (if N mod 7 = 3 then -1 else 0);
                  C := Make (Layouts (L), Widths (WI), DY, 0, 0, 0, 0, N mod 2, Clip,
                             Clip);
                  C.Fmt := Accepted (N mod 17);
                  C.Model := (if Layouts (L) (6) /= 0 then Models_4 (N mod 4)
                              else Models_3 (N mod 3));
                  C.Ups := Ups;
                  C.Mode := N mod 5;
                  Run (C);
                  N := N + 1;
               end loop;
            end loop;
            Mark (OD.YCCK_Sizes_Marks, "YCCK_Sizes, layout, upsampling",
                  Integer (L), Integer (Ups));
         end loop;
      end loop;
      Finish ("YCCK_Sizes", OD.YCCK_Sizes);
      Check_Counts
        ("YCCK_Sizes", OD.YCCK_Sizes_Calls, OD.YCCK_Sizes_Ok,
         OD.YCCK_Sizes_Bad_Argument, OD.YCCK_Sizes_Unsupported, OD.YCCK_Sizes_Pixels);
   end Sweep_Sizes;

   -----------------
   -- Sweep_Large --
   -----------------

   procedure Sweep_Large is
      C : Call;
   begin
      Start (5);
      Reset_Counts;
      for Ups in U32 range 0 .. 2 loop
         for Four in Boolean loop
            C := Make ((if Four then HV_420_4 else HV_420_3), 1501, 1203, 0, 0, 0, 0,
                       3, 0, 0);
            C.Fmt := (if Four then 16#8100_8888# else 16#9000_8888#);
            C.Model := (if Four then 16#07# else 16#00#);
            C.Ups := Ups;
            Run (C);
            Mark (OD.YCCK_Large_Marks, "YCCK_Large, upsampling, four planes",
                  Integer (Ups), Boolean'Pos (Four));
         end loop;
      end loop;
      Finish ("YCCK_Large", OD.YCCK_Large);
      Check_Counts
        ("YCCK_Large", OD.YCCK_Large_Calls, OD.YCCK_Large_Ok,
         OD.YCCK_Large_Bad_Argument, OD.YCCK_Large_Unsupported, OD.YCCK_Large_Pixels);
   end Sweep_Large;

   Num_Changes : constant := 46;

   ------------
   -- Change --
   ------------

   --  The oracle's change.
   procedure Change (C : in out Call; Kind : U32; K : Natural) is
      K3 : constant Natural := K mod 3;
   begin
      case Kind is
         when 1 => C.X1 := 16#1_0000#;
         when 2 => C.Y1 := 16#1_0000#;
         when 3 => C.X1 := 16#FFFF_FFFF#;
         when 4 => C.W (K) := 16#1_0001#;
         when 5 => C.H (K) := 16#1_0001#;
         when 6 =>
            if C.Len (K) > 0 then
               C.Len (K) := C.Len (K) - 1;
            end if;
         when 7 => C.Len (K) := 0;
         when 8 => C.Len (K) := C.Len (K) + 1;
         when 9 => C.HH (K3) := 0;
         when 10 => C.HH (K3) := 5;
         when 11 => C.VV (K3) := 0;
         when 12 => C.VV (K3) := 5;
         when 13 => C.HH (K3) := 255;
         when 14 => C.HH (3) := 0;
         when 15 => C.VV (3) := 0;
         when 16 => C.HH (3) := 5;
         when 17 => C.VV (3) := 5;
         when 18 => C.X0 := C.X0 + 1;
         when 19 => C.Y0 := C.Y0 + 1;
         when 20 =>
            C.X0 := C.X0 + 12;
            C.X1 := C.X1 + 12;
         when 21 => C.Scratch_Len := 2047;
         when 22 => C.Scratch_Len := 0;
         when 23 => C.Scratch_Len := 2049;
         when 24 => C.W (K) := C.W (K) + 1;
         when 25 =>
            if C.W (K) > 0 then
               C.W (K) := C.W (K) - 1;
            end if;
         when 26 => C.H (K) := C.H (K) + 1;
         when 27 =>
            if C.H (K) > 0 then
               C.H (K) := C.H (K) - 1;
            end if;
         when 28 =>
            if C.X1 - C.X0 > 16#1_0000# or else C.Y1 - C.Y0 > 16#1_0000# then
               return;
            end if;
            C.HH (3) := 4;
            C.VV (3) := 4;
            C.W (3) := C.X1 - C.X0;
            C.H (3) := C.Y1 - C.Y0;
            C.S (3) := C.W (3);
            C.Len (3) := Flat (C.W (3), C.H (3), C.S (3));
         when 29 => C.X1 := C.X0;
         when 30 => C.Y1 := C.Y0;
         when 31 => C.X0 := C.X1 + 1;
         when 32 => C.DW := 0;
         when 33 => C.DH := 0;
         when 34 => C.DW := C.DW / 2;
         when 35 => C.DH := C.DH / 2;
         when 36 => C.Model := Pick (256);
         when 37 => C.Ups := 3 + Pick (253);
         when 38 =>
            C.S (K) := C.W (K) / 2;
            C.Len (K) := Flat (C.W (K), C.H (K), C.S (K));
         when 39 =>
            C.S (K) := 0;
            C.Len (K) := Flat (C.W (K), C.H (K), C.S (K));
         when 40 => C.Fmt := Formats (Pick (34));
         when 41 => C.X1 := 16#FFFF#;
         when 42 => C.Y1 := 16#FFFF#;
         when 43 =>
            C.Y0 := C.Y0 + 12;
            C.Y1 := C.Y1 + 12;
         when 44 => C.Fmt := 16#4002_0888#;
         when 45 => C.Fmt := 16#8200_BBBB#;
         when others => null;
      end case;
   end Change;

   ------------------
   -- Sweep_Errors --
   ------------------

   procedure Sweep_Errors is
      HV       : HV_Array;
      C        : Call;
      Ups      : U32;
      DX, DY   : U32;
      X0N, Y0N : U32;
      A        : U32;
   begin
      Start (6);
      Reset_Counts;
      Fill (Palette, 0);
      for Kind in U32 range 0 .. Num_Changes - 1 loop
         for I in 1 .. 400 loop
            for J in 0 .. 5 loop
               A := 1 + Pick (2);
               if Pick (4) = 0 then
                  A := A + 2 * Pick (2);
               end if;
               HV (J) := A;
            end loop;
            if Pick (2) = 0 then
               HV (6) := 1 + Pick (2);
               HV (7) := 1 + Pick (2);
            else
               HV (6) := 0;
               HV (7) := 0;
            end if;
            Ups := Pick (3);
            DX := Sizes (Pick (11));
            DY := Sizes (Pick (11));
            X0N := (if Ups = 0 then Pick (2) else 0);
            Y0N := (if Ups = 0 then Pick (2) else 0);
            A := Pick (2);
            C := Make (HV, DX, DY, X0N, Y0N, 0, 0, A, 0, 0);
            C.Fmt := Accepted (Pick (17));
            C.Model := (if (HV (6) or HV (7)) /= 0 then Models_4 (Pick (4))
                        else Models_3 (Pick (3)));
            C.Ups := Ups;
            A := Pick (4);
            Change (C, Kind, Natural (A));
            Run (C);
         end loop;
         Mark (OD.YCCK_Errors_Marks, "YCCK_Errors, kind of change", Integer (Kind));
      end loop;
      Finish ("YCCK_Errors", OD.YCCK_Errors);
      Check_Counts
        ("YCCK_Errors", OD.YCCK_Errors_Calls, OD.YCCK_Errors_Ok,
         OD.YCCK_Errors_Bad_Argument, OD.YCCK_Errors_Unsupported,
         OD.YCCK_Errors_Pixels);
   end Sweep_Errors;

   Origins        : constant array (U32 range 0 .. 3) of U32 := [0, 1, 3, 5];
   Origin_Widths  : constant array (U32 range 0 .. 4) of U32 := [1, 17, 480, 673, 1345];
   Origin_Heights : constant array (U32 range 0 .. 1) of U32 := [1, 5];

   -------------------
   -- Sweep_Origins --
   -------------------

   procedure Sweep_Origins is
      C : Call;
      N : U32 := 0;
   begin
      Start (7);
      Reset_Counts;
      Fill (Palette, 0);
      for L in Layouts'Range loop
         for XI in Origins'Range loop
            for YI in Origins'Range loop
               for WI in Origin_Widths'Range loop
                  for HI in Origin_Heights'Range loop
                     C := Make (Layouts (L), Origin_Widths (WI), Origin_Heights (HI),
                                Origins (XI), Origins (YI), 0, 0, N mod 2, 0, 0);
                     C.Fmt := Accepted (N mod 17);
                     C.Model := (if Layouts (L) (6) /= 0 then Models_4 (N mod 4)
                                 else Models_3 (N mod 3));
                     C.Mode := N mod 5;
                     Run (C);
                     N := N + 1;
                  end loop;
               end loop;
            end loop;
         end loop;
         Mark (OD.YCCK_Origins_Marks, "YCCK_Origins, layout", Integer (L));
      end loop;
      Finish ("YCCK_Origins", OD.YCCK_Origins);
      Check_Counts
        ("YCCK_Origins", OD.YCCK_Origins_Calls, OD.YCCK_Origins_Ok,
         OD.YCCK_Origins_Bad_Argument, OD.YCCK_Origins_Unsupported,
         OD.YCCK_Origins_Pixels);
   end Sweep_Origins;

   Band_Rows : constant := 12;
   Num_Bands : constant := 4;

   -----------------
   -- Sweep_Bands --
   -----------------

   procedure Sweep_Bands is
      C, CB : Call;
      N     : U32 := 0;
      DLen  : Index;
      K     : U32;
      Rows  : U32;
      Off   : Lengths;
      Same  : Boolean := True;
      Equal : Boolean;
   begin
      Start (8);
      Reset_Counts;
      Fill (Palette, 0);
      for L in Layouts'Range loop
         for WI in 0 .. 2 loop
            C := Make (Layouts (L), (if WI = 0 then 13 elsif WI = 1 then 481 else 1345),
                       Band_Rows * Num_Bands, 0, 0, 0, 0, N mod 2, 0, 0);
            C.Fmt := Accepted (N mod 17);
            C.Model := (if Layouts (L) (6) /= 0 then Models_4 (N mod 4)
                        else Models_3 (N mod 3));
            DLen := Dst_Len (C);
            Fill (Src0 (B0 .. B0 + C.Len (0) - 1), 0);
            Fill (Src1 (B1 .. B1 + C.Len (1) - 1), 0);
            Fill (Src2 (B2 .. B2 + C.Len (2) - 1), 0);
            Fill (Src3 (B3 .. B3 + C.Len (3) - 1), 0);
            Fill (Dst (DB .. DB + DLen - 1), 0);
            Dst2 (DB .. DB + DLen - 1) := Dst (DB .. DB + DLen - 1);
            Scratch := [others => 0];
            Invoke (C, [others => 0], Dst (DB .. DB + DLen - 1), K);
            Mix (U64 (K));
            for B in U32 range 0 .. Num_Bands - 1 loop
               CB := C;
               CB.Y0 := B * Band_Rows;
               CB.Y1 := CB.Y0 + Band_Rows;
               for P in 0 .. 3 loop
                  Rows := C.H (P) / Num_Bands;
                  CB.H (P) := Rows;
                  CB.Len (P) := Flat (C.W (P), Rows, C.S (P));
                  Off (P) := Index (B) * Index (Rows) * Index (C.S (P));
               end loop;
               Invoke (CB, Off, Dst2 (DB .. DB + DLen - 1), K);
               Mix (U64 (K));
            end loop;
            Mix_Bytes (Dst2 (DB .. DB + DLen - 1));
            Equal := Dst (DB .. DB + DLen - 1) = Dst2 (DB .. DB + DLen - 1);
            Mix (U64'(if Equal then 1 else 0));
            Same := Same and then Equal;
            N := N + 1;
         end loop;
         Mark (OD.YCCK_Bands_Marks, "YCCK_Bands, layout", Integer (L));
      end loop;
      Check (Same, "YCCK_Bands: banded calls give the same pixels as one call");
      Finish ("YCCK_Bands", OD.YCCK_Bands);
      Check_Counts
        ("YCCK_Bands", OD.YCCK_Bands_Calls, OD.YCCK_Bands_Ok,
         OD.YCCK_Bands_Bad_Argument, OD.YCCK_Bands_Unsupported, OD.YCCK_Bands_Pixels);
   end Sweep_Bands;

   -----------------
   -- Sweep_Order --
   -----------------

   procedure Sweep_Order is
      HV     : HV_Array;
      C      : Call;
      Ups    : U32;
      DX, DY : U32;
      A      : U32;
   begin
      Start (9);
      Reset_Counts;
      Fill (Palette, 0);
      for Kind1 in U32 range 0 .. Num_Changes - 1 loop
         for Kind2 in U32 range 0 .. Num_Changes - 1 loop
            for I in 1 .. 3 loop
               for J in 0 .. 5 loop
                  HV (J) := 1 + Pick (2);
               end loop;
               if Pick (2) = 0 then
                  HV (6) := 1 + Pick (2);
                  HV (7) := 1 + Pick (2);
               else
                  HV (6) := 0;
                  HV (7) := 0;
               end if;
               Ups := Pick (3);
               DX := Sizes (1 + Pick (10));
               DY := Sizes (1 + Pick (10));
               A := Pick (2);
               C := Make (HV, DX, DY, 0, 0, 0, 0, A, 0, 0);
               C.Fmt := Accepted (Pick (17));
               C.Model := (if (HV (6) or HV (7)) /= 0 then Models_4 (Pick (4))
                           else Models_3 (Pick (3)));
               C.Ups := Ups;
               A := Pick (4);
               Change (C, Kind1, Natural (A));
               A := Pick (4);
               Change (C, Kind2, Natural (A));
               Run (C);
            end loop;
         end loop;
         Mark (OD.YCCK_Order_Marks, "YCCK_Order, first kind of change", Integer (Kind1));
      end loop;
      Finish ("YCCK_Order", OD.YCCK_Order);
      Check_Counts
        ("YCCK_Order", OD.YCCK_Order_Calls, OD.YCCK_Order_Ok,
         OD.YCCK_Order_Bad_Argument, OD.YCCK_Order_Unsupported, OD.YCCK_Order_Pixels);
   end Sweep_Order;

   Limit_Layouts : constant array (0 .. 3) of U32 := [0, 3, 9, 10];

   ------------------
   -- Sweep_Limits --
   ------------------

   procedure Sweep_Limits is
      C : Call;
      N : U32 := 0;
   begin
      Start (10);
      Reset_Counts;
      Fill (Palette, 0);
      for LI in Limit_Layouts'Range loop
         for Ups in U32 range 0 .. 2 loop
            for Extra in U32 range 0 .. 2 loop
               for Wide in Boolean loop
                  if Wide then
                     C := Make (Layouts (Limit_Layouts (LI)), 16#FFFF#, 2, 0, 0, Extra, 0,
                                N mod 2, 0, 0);
                  else
                     C := Make (Layouts (Limit_Layouts (LI)), 2, 16#FFFF#, 0, 0, 0, Extra,
                                N mod 2, 0, 0);
                  end if;
                  C.Fmt := Accepted (N mod 17);
                  C.Model := (if Layouts (Limit_Layouts (LI)) (6) /= 0
                              then Models_4 (N mod 4) else Models_3 (N mod 3));
                  C.Ups := Ups;
                  Run (C);
                  N := N + 1;
               end loop;
            end loop;
         end loop;
         Mark (OD.YCCK_Limits_Marks, "YCCK_Limits, layout number", LI);
      end loop;
      Finish ("YCCK_Limits", OD.YCCK_Limits);
      Check_Counts
        ("YCCK_Limits", OD.YCCK_Limits_Calls, OD.YCCK_Limits_Ok,
         OD.YCCK_Limits_Bad_Argument, OD.YCCK_Limits_Unsupported, OD.YCCK_Limits_Pixels);
   end Sweep_Limits;

   ---------
   -- Run --
   ---------

   procedure Run is
   begin
      Sweep_Colors;
      Sweep_Formats;
      Sweep_Sampling;
      Sweep_Sizes;
      Sweep_Large;
      Sweep_Errors;
      Sweep_Origins;
      Sweep_Bands;
      Sweep_Order;
      Sweep_Limits;
   end Run;

end Test_YCCK;
