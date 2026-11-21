--  Part of wuffada (wuffs-ada: Wuffs to Ada).
--  SPDX-License-Identifier: Apache-2.0 OR MIT

--  Wuffs.Runtime.X86.CPUID: what the CPU that runs the program can do, as
--  upstream's C decides it (wuffs/internal/cgen/base/fundamental-public.h,
--  wuffs_base__cpu_arch__have_x86_sse42, _avx2 and _bmi2, built with GCC
--  and without the -m options that would make them constant).  The same
--  CPUID leaves and bits, with the same "is the leaf there" tests that GCC's
--  __get_cpuid and __get_cpuid_count make (the leaf is at most the maximum
--  basic leaf, CPUID leaf 0's EAX), with one test more than upstream makes:
--  x86_avx2 also needs the operating system to save the AVX state (decided
--  by the project lead).  Upstream does not test that, and its AVX2 code
--  dies with an illegal instruction on a system that reports AVX2 but has
--  not enabled the YMM registers; here such a system uses the next
--  alternative.  The results are the same either way.
--
--    x86_sse42: leaf 1 ECX has PCLMULQDQ (bit 1), SSE4.2 (bit 20) and
--               POPCNT (bit 23): mask 16#0090_0002#.
--    x86_avx2:  leaf 7 subleaf 0 EBX has AVX2 (bit 5), and x86_sse42, and
--               leaf 1 ECX has OSXSAVE (bit 27) and XCR0 (read by XGETBV)
--               has the SSE and AVX state bits (1 and 2).
--    x86_bmi2:  leaf 7 subleaf 0 EBX has BMI2 (bit 8).
--
--  Upstream runs CPUID at every "choose"; this runs it once, at the first
--  call, and keeps the answer in an atomic variable (so concurrent first
--  calls are not a data race: they compute and store the same value).
--
--  Not a SIMD unit: compiled with the default switches, it has no
--  instruction beyond the x86-64 baseline (CPUID itself is baseline).

package Wuffs.Runtime.X86.CPUID with Preelaborate, SPARK_Mode => Off is

   function Have_X86_SSE42 return Boolean;
   function Have_X86_AVX2 return Boolean;
   function Have_X86_BMI2 return Boolean;

   --  What the three registers that Detect reads mean: bit 0 of the result
   --  is x86_sse42, bit 1 x86_avx2, bit 2 x86_bmi2.  A pure function of the
   --  maximum basic leaf, leaf 1's ECX, leaf 7's EBX and XCR0's low half
   --  (which matters only if Ecx1 has OSXSAVE), so that the tests can check
   --  the decoding with register values of CPUs other than the one that
   --  runs them.
   function Decode (Max_Leaf, Ecx1, Ebx7, Xcr0 : Unsigned_32) return Unsigned_32;

   --  The raw CPUID instruction, for the tests.
   procedure Cpuid (Leaf, Subleaf : Unsigned_32; Eax, Ebx, Ecx, Edx : out Unsigned_32);

end Wuffs.Runtime.X86.CPUID;
