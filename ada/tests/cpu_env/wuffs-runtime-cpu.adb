--  Part of wuffada (wuffs-ada: Wuffs to Ada).
--  SPDX-License-Identifier: Apache-2.0 OR MIT

with Ada.Environment_Variables;
with Interfaces;
with Wuffs.Runtime.X86.CPUID;

package body Wuffs.Runtime.CPU with SPARK_Mode => Off is

   use type Interfaces.Unsigned_32;

   --  Bit 0: x86_sse42, bit 1: x86_avx2, bit 2: x86_bmi2 are disabled.
   --  Bit 31: the variable has been read.
   Known : constant Interfaces.Unsigned_32 := 16#8000_0000#;
   Cache : Interfaces.Unsigned_32 := 0 with Atomic;

   procedure Scan (Name, Value : String);
   function Disabled return Interfaces.Unsigned_32;

   procedure Scan (Name, Value : String) is
      First : Positive := Value'First;
      D     : Interfaces.Unsigned_32 := Cache;

      procedure Token (T : String);

      procedure Token (T : String) is
      begin
         if T = "x86_sse42" or else T = "all" then
            D := D or 1;
         end if;
         if T = "x86_avx2" or else T = "all" then
            D := D or 2;
         end if;
         if T = "x86_bmi2" or else T = "all" then
            D := D or 4;
         end if;
      end Token;
   begin
      if Name /= "WUFFS_TEST_CPU_DISABLE" then
         return;
      end if;
      for I in Value'Range loop
         if Value (I) = ',' then
            Token (Value (First .. I - 1));
            First := I + 1;
         end if;
      end loop;
      Token (Value (First .. Value'Last));
      Cache := D;
   end Scan;

   function Disabled return Interfaces.Unsigned_32 is
   begin
      if (Cache and Known) = 0 then
         Cache := Known;
         Ada.Environment_Variables.Iterate (Scan'Access);
      end if;
      return Cache;
   end Disabled;

   function Have_X86_SSE42 return Boolean
   is (Wuffs.Runtime.X86.CPUID.Have_X86_SSE42 and then (Disabled and 1) = 0);

   function Have_X86_AVX2 return Boolean
   is (Wuffs.Runtime.X86.CPUID.Have_X86_AVX2 and then (Disabled and 2) = 0);

   function Have_X86_BMI2 return Boolean
   is (Wuffs.Runtime.X86.CPUID.Have_X86_BMI2 and then (Disabled and 4) = 0);

end Wuffs.Runtime.CPU;
