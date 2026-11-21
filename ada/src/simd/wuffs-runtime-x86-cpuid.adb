--  Part of wuffada (wuffs-ada: Wuffs to Ada).
--  SPDX-License-Identifier: Apache-2.0 OR MIT

with System.Machine_Code;

package body Wuffs.Runtime.X86.CPUID with SPARK_Mode => Off is

   --  Bit 0: x86_sse42, bit 1: x86_avx2, bit 2: x86_bmi2.  Bit 31: the
   --  other bits are known.
   Known : constant Unsigned_32 := 16#8000_0000#;
   Cache : Unsigned_32 := 0 with Atomic;

   SSE42_Ecx1 : constant Unsigned_32 := 16#0090_0002#;
   AVX2_Ebx7  : constant Unsigned_32 := 16#0000_0020#;
   BMI2_Ebx7  : constant Unsigned_32 := 16#0000_0100#;
   OSXSAVE_Ecx1 : constant Unsigned_32 := 16#0800_0000#;
   AVX_State    : constant Unsigned_32 := 16#0000_0006#;

   function Xgetbv_0 return Unsigned_32;

   function Detect return Unsigned_32;
   function Features return Unsigned_32;

   procedure Cpuid (Leaf, Subleaf : Unsigned_32; Eax, Ebx, Ecx, Edx : out Unsigned_32) is
      use System.Machine_Code;
   begin
      --  GCC's cpuid.h: __cpuid_count.
      Asm ("cpuid",
           Outputs  =>
             [Unsigned_32'Asm_Output ("=a", Eax),
              Unsigned_32'Asm_Output ("=b", Ebx),
              Unsigned_32'Asm_Output ("=c", Ecx),
              Unsigned_32'Asm_Output ("=d", Edx)],
           Inputs   => [Unsigned_32'Asm_Input ("0", Leaf), Unsigned_32'Asm_Input ("2", Subleaf)],
           Volatile => True);
   end Cpuid;

   --  XCR0's low 32 bits.  Only to be called if CPUID says OSXSAVE:
   --  otherwise XGETBV is an illegal instruction.
   function Xgetbv_0 return Unsigned_32 is
      use System.Machine_Code;
      Eax, Edx : Unsigned_32;
   begin
      Asm ("xgetbv",
           Outputs  => [Unsigned_32'Asm_Output ("=a", Eax), Unsigned_32'Asm_Output ("=d", Edx)],
           Inputs   => Unsigned_32'Asm_Input ("c", 0),
           Volatile => True);
      return Eax;
   end Xgetbv_0;

   function Decode (Max_Leaf, Ecx1, Ebx7, Xcr0 : Unsigned_32) return Unsigned_32 is
      --  __get_cpuid (1, ...) and __get_cpuid_count (7, 0, ...) fail when
      --  the maximum leaf is 0 or below the leaf asked for.
      Have_Leaf_1 : constant Boolean := Max_Leaf >= 1;
      Have_Leaf_7 : constant Boolean := Max_Leaf >= 7;
      SSE42       : constant Boolean := Have_Leaf_1 and then (Ecx1 and SSE42_Ecx1) = SSE42_Ecx1;
      Ret         : Unsigned_32 := 0;
   begin
      if SSE42 then
         Ret := Ret or 1;
      end if;
      if Have_Leaf_7 and then (Ebx7 and AVX2_Ebx7) = AVX2_Ebx7 and then SSE42
        and then (Ecx1 and OSXSAVE_Ecx1) /= 0 and then (Xcr0 and AVX_State) = AVX_State
      then
         Ret := Ret or 2;
      end if;
      if Have_Leaf_7 and then (Ebx7 and BMI2_Ebx7) = BMI2_Ebx7 then
         Ret := Ret or 4;
      end if;
      return Ret;
   end Decode;

   function Detect return Unsigned_32 is
      Max_Leaf   : Unsigned_32;
      Ecx1, Ebx7 : Unsigned_32 := 0;
      Xcr0       : Unsigned_32 := 0;
      A, B, C, D : Unsigned_32;
   begin
      --  __get_cpuid_max (0, 0).
      Cpuid (Leaf => 0, Subleaf => 0, Eax => Max_Leaf, Ebx => B, Ecx => C, Edx => D);
      if Max_Leaf >= 1 then
         Cpuid (Leaf => 1, Subleaf => 0, Eax => A, Ebx => B, Ecx => Ecx1, Edx => D);
      end if;
      if Max_Leaf >= 7 then
         Cpuid (Leaf => 7, Subleaf => 0, Eax => A, Ebx => Ebx7, Ecx => C, Edx => D);
      end if;
      if (Ecx1 and OSXSAVE_Ecx1) /= 0 then
         Xcr0 := Xgetbv_0;
      end if;
      return Known or Decode (Max_Leaf => Max_Leaf, Ecx1 => Ecx1, Ebx7 => Ebx7, Xcr0 => Xcr0);
   end Detect;

   function Features return Unsigned_32 is
      F : Unsigned_32 := Cache;
   begin
      if (F and Known) = 0 then
         F := Detect;
         Cache := F;
      end if;
      return F;
   end Features;

   function Have_X86_SSE42 return Boolean is ((Features and 1) /= 0);
   function Have_X86_AVX2 return Boolean is ((Features and 2) /= 0);
   function Have_X86_BMI2 return Boolean is ((Features and 4) /= 0);

end Wuffs.Runtime.X86.CPUID;
