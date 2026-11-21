--  Part of wuffada (wuffs-ada: Wuffs to Ada).
--  SPDX-License-Identifier: Apache-2.0 OR MIT

--  Tests the run-time selection of the SIMD implementations (a SIMD build).
--
--  1. Prints "cpu FEATURE 0|1" for each feature, as the library's own
--     detection (Wuffs.Runtime.X86.CPUID) answers: test.sh compares the
--     lines with what GCC's __builtin_cpu_supports says (simd/cpu_c.c).
--  2. Prints "selected FEATURE 0|1": what Wuffs.Runtime.CPU answers, which
--     in a test build is the detection minus the features named in
--     WUFFS_TEST_CPU_DISABLE (ada/tests/cpu_env).
--  3. Runs each package's choose statements (crc32, adler32 and crc64 at
--     the first update; png at decode_image_config, for an RGBA (filter
--     distance 4) and an RGB (distance 3) image; jpeg at
--     decode_image_config; deflate at the start of transform_io), prints
--     "choice PACKAGE.FUNCTION N" and checks that N is the SIMD
--     implementation exactly when Wuffs.Runtime.CPU says that the CPU has
--     its feature, and the next alternative otherwise.
--
--  test.sh runs it with WUFFS_TEST_CPU_DISABLE unset, set to each feature
--  and set to "all", and checks the choices.  Run from the repository's
--  root: it reads three files of wuffs/test/data.

with Ada.Streams.Stream_IO;
with Ada.Text_IO;
with Simd_Test_Objects;
with Test_Support;
with Interfaces;
with Wuffs.Base.IO;
with Wuffs.Base.Pixel_Formats;
with Wuffs.Runtime.CPU;
with Wuffs.Runtime.X86.CPUID;
with Wuffs.Std.Adler32.Simd_Probe;
with Wuffs.Std.Crc32.Simd_Probe;
with Wuffs.Std.Crc64.Simd_Probe;
with Wuffs.Std.Deflate.Simd_Probe;
with Wuffs.Std.Jpeg.Simd_Probe;
with Wuffs.Std.Png.Simd_Probe;

procedure Test_Simd is

   use Test_Support;
   use type Wuffs.U8;
   use type Wuffs.Index;

   use Simd_Test_Objects;

   procedure Put_Flag (Prefix, Feature : String; Flag : Boolean);
   procedure Choice (What : String; Got, SIMD, Other : Wuffs.U8; Have : Boolean);
   procedure Load (Name : String; Length : out Wuffs.Index);

   procedure Put_Flag (Prefix, Feature : String; Flag : Boolean) is
   begin
      Ada.Text_IO.Put (Prefix);
      Ada.Text_IO.Put (" ");
      Ada.Text_IO.Put (Feature);
      Ada.Text_IO.Put_Line (if Flag then " 1" else " 0");
   end Put_Flag;

   --  Got must be SIMD if Have, else Other.
   procedure Choice (What : String; Got, SIMD, Other : Wuffs.U8; Have : Boolean) is
   begin
      Ada.Text_IO.Put ("choice ");
      Ada.Text_IO.Put (What);
      Ada.Text_IO.Put_Line (Got'Image);
      Check (Got = (if Have then SIMD else Other), "wrong implementation selected: ", -1, What);
   end Choice;

   procedure Load (Name : String; Length : out Wuffs.Index) is
      package SIO renames Ada.Streams.Stream_IO;
      File : SIO.File_Type;
   begin
      SIO.Open (File, SIO.In_File, Name);
      Length := Wuffs.Index (SIO.Size (File));
      declare
         subtype SEO is Ada.Streams.Stream_Element_Offset;
         Item : Ada.Streams.Stream_Element_Array (1 .. SEO (Length))
         with Import, Address => Buffer'Address;
         Last : Ada.Streams.Stream_Element_Offset;
      begin
         SIO.Read (File, Item, Last);
      end;
      SIO.Close (File);
   end Load;

   SSE42 : constant Boolean := Wuffs.Runtime.CPU.Have_X86_SSE42;
   AVX2  : constant Boolean := Wuffs.Runtime.CPU.Have_X86_AVX2;
   BMI2  : constant Boolean := Wuffs.Runtime.CPU.Have_X86_BMI2;

   procedure Image_Config (Name : String; D : in out Wuffs.Runtime.Image_Decoder'Class);

   procedure Image_Config (Name : String; D : in out Wuffs.Runtime.Image_Decoder'Class) is
      Length : Wuffs.Index;
      IC     : Wuffs.Base.Pixel_Formats.Image_Config;
      M      : Wuffs.Base.IO.Buffer_Meta;
      S      : Wuffs.Status;
   begin
      Load (Name, Length);
      M := (Wi => Length, Ri => 0, Pos => 0, Closed => True);
      S := D.Decode_Image_Config
        (A_Dst => IC, A_Dst_Null => False, A_Src => Buffer (0 .. Length - 1), A_Src_Meta => M);
      Check (Wuffs.Is_Ok (S), "decode_image_config failed: ", -1, Name);
   end Image_Config;

begin
   Put_Flag ("cpu", "x86_sse42", Wuffs.Runtime.X86.CPUID.Have_X86_SSE42);
   Put_Flag ("cpu", "x86_avx2", Wuffs.Runtime.X86.CPUID.Have_X86_AVX2);
   Put_Flag ("cpu", "x86_bmi2", Wuffs.Runtime.X86.CPUID.Have_X86_BMI2);
   --  The decoding of the CPUID registers, with values that this machine
   --  does not have: each feature needs its own bits of its own register.
   declare
      use Interfaces;
      function D (Max_Leaf, Ecx1, Ebx7, Xcr0 : Unsigned_32) return Unsigned_32
        renames Wuffs.Runtime.X86.CPUID.Decode;
      SSE      : constant Unsigned_32 := 16#0090_0002#;  --  What x86_sse42 needs.
      OS       : constant Unsigned_32 := 16#0800_0000#;  --  OSXSAVE.
      All_Ecx1 : constant Unsigned_32 := SSE or OS;
   begin
      Check (D (7, All_Ecx1, 16#120#, 6) = 7, "cpuid decode: everything");
      Check (D (7, 0, 0, 0) = 0, "cpuid decode: nothing");
      Check (D (7, All_Ecx1, 0, 6) = 1, "cpuid decode: sse42 only");
      Check (D (7, OS or 16#0090_0000#, 16#120#, 6) = 4, "cpuid decode: no pclmul");
      Check (D (7, OS or 16#0080_0002#, 16#120#, 6) = 4, "cpuid decode: no sse4.2");
      Check (D (7, OS or 16#0010_0002#, 16#120#, 6) = 4, "cpuid decode: no popcnt");
      Check (D (7, All_Ecx1, 16#020#, 6) = 3, "cpuid decode: avx2 without bmi2");
      Check (D (7, All_Ecx1, 16#100#, 6) = 5, "cpuid decode: bmi2 without avx2");
      Check (D (7, OS, 16#020#, 6) = 0, "cpuid decode: avx2 needs sse42");
      --  Bits 5 and 8 of other registers (leaf 7's ECX has WAITPKG and GFNI
      --  there; leaf 1's ECX has VMX and EIST) are not AVX2 and BMI2.
      Check (D (7, All_Ecx1 or 16#120#, 0, 6) = 1, "cpuid decode: leaf 1 bits 5 and 8");
      Check (D (7, 16#F76F_FFFD#, 16#FFFF_FEDF#, 16#FFFF_FFFF#) = 0, "cpuid decode: all but ours");
      --  Leaves that the CPU does not have.
      Check (D (0, All_Ecx1, 16#120#, 6) = 0, "cpuid decode: no leaf 1");
      Check (D (1, All_Ecx1, 16#120#, 6) = 1, "cpuid decode: no leaf 7");
      Check (D (6, All_Ecx1, 16#120#, 6) = 1, "cpuid decode: leaf 6 is the last");
      --  AVX2 needs the operating system to save the YMM state: OSXSAVE, and
      --  both the SSE and the AVX bit of XCR0.  The other features do not.
      Check (D (7, SSE, 16#120#, 6) = 5, "cpuid decode: avx2 without OSXSAVE");
      Check (D (7, All_Ecx1, 16#120#, 0) = 5, "cpuid decode: avx2 with XCR0 = 0");
      Check (D (7, All_Ecx1, 16#120#, 2) = 5, "cpuid decode: avx2 with the SSE state only");
      Check (D (7, All_Ecx1, 16#120#, 4) = 5, "cpuid decode: avx2 with the AVX bit only");
      Check (D (7, All_Ecx1, 16#120#, 16#FFFF_FFF9#) = 5, "cpuid decode: avx2, XCR0 all but ours");
      Check (D (7, All_Ecx1, 16#120#, 7) = 7, "cpuid decode: avx2 with x87, SSE and AVX state");
   end;

   Put_Flag ("selected", "x86_sse42", SSE42);
   Put_Flag ("selected", "x86_avx2", AVX2);
   Put_Flag ("selected", "x86_bmi2", BMI2);

   --  The hashers choose at their first update.
   Buffer (0 .. 299) := [others => 7];
   Wuffs.Std.Crc32.Initialize (Crc);
   Wuffs.Std.Crc32.Update (Crc, Buffer (0 .. 299));
   Choice ("crc32.up", Wuffs.Std.Crc32.Simd_Probe.Choice_Up (Crc), 1, 0, SSE42);
   Wuffs.Std.Adler32.Initialize (Adler);
   Wuffs.Std.Adler32.Update (Adler, Buffer (0 .. 299));
   Choice ("adler32.up", Wuffs.Std.Adler32.Simd_Probe.Choice_Up (Adler), 1, 0, SSE42);
   Wuffs.Std.Crc64.Initialize (Crc64);
   Wuffs.Std.Crc64.Update (Crc64, Buffer (0 .. 299));
   Choice ("crc64.up", Wuffs.Std.Crc64.Simd_Probe.Choice_Up (Crc64), 1, 0, SSE42);

   --  PNG: filter distance 4 (RGBA), then 3 (RGB).  The numbers are those
   --  of ada/gen/simd/wuffs-std-png.adb, Choose_Filter_Implementations.
   Wuffs.Std.Png.Initialize (Png);
   Image_Config ("wuffs/test/data/hibiscus.primitive.png", Png);
   Choice ("png.filter_1 (d4)", Wuffs.Std.Png.Simd_Probe.Choice_Filter_1 (Png), 1, 2, SSE42);
   Choice ("png.filter_3 (d4)", Wuffs.Std.Png.Simd_Probe.Choice_Filter_3 (Png), 1, 2, SSE42);
   Choice ("png.filter_4 (d4)", Wuffs.Std.Png.Simd_Probe.Choice_Filter_4 (Png), 1, 2, SSE42);
   Wuffs.Std.Png.Initialize (Png);
   Image_Config ("wuffs/test/data/bricks-color.png", Png);
   Choice ("png.filter_1 (d3)", Wuffs.Std.Png.Simd_Probe.Choice_Filter_1 (Png), 3, 3, SSE42);
   Choice ("png.filter_3 (d3)", Wuffs.Std.Png.Simd_Probe.Choice_Filter_3 (Png), 3, 3, SSE42);
   Choice ("png.filter_4 (d3)", Wuffs.Std.Png.Simd_Probe.Choice_Filter_4 (Png), 3, 4, SSE42);

   Wuffs.Std.Jpeg.Initialize (Jpeg);
   Image_Config ("wuffs/test/data/bricks-color.jpeg", Jpeg);
   Choice ("jpeg.decode_idct", Wuffs.Std.Jpeg.Simd_Probe.Choice_Decode_Idct (Jpeg), 1, 0, AVX2);

   --  Deflate chooses at the start of transform_io, whatever the input.
   declare
      Dst_M, Src_M : Wuffs.Base.IO.Buffer_Meta;
      Dst  : Wuffs.Bytes (0 .. 15) := [others => 0];
      Work : Wuffs.Bytes (1 .. 0);
      S    : Wuffs.Status;
   begin
      Wuffs.Std.Deflate.Initialize (Defl);
      Buffer (0 .. 3) := [16#03#, 16#00#, 0, 0];  --  An empty final fixed-Huffman block.
      Src_M := (Wi => 2, Ri => 0, Pos => 0, Closed => True);
      S := Defl.Transform_Io
        (A_Dst => Dst, A_Dst_Meta => Dst_M, A_Src => Buffer (0 .. 3), A_Src_Meta => Src_M,
         A_Workbuf => Work);
      Check (Wuffs.Is_Ok (S), "deflate transform_io failed");
      Choice ("deflate.decode_huffman_fast64",
              Wuffs.Std.Deflate.Simd_Probe.Choice_Decode_Huffman_Fast64 (Defl), 1, 0, BMI2);
   end;

   Finish ("test_simd");
end Test_Simd;
