--  Part of wuffada (wuffs-ada: Wuffs to Ada).
--  SPDX-License-Identifier: Apache-2.0 OR MIT

--  Wuffs.Runtime.CPU: what generated code asks before it picks a SIMD
--  implementation (C: wuffs_base__cpu_arch__have_x86_sse42 and so on, at a
--  Wuffs `choose` statement).  Only in a SIMD build.  This is its own
--  package, in its own directory, so that a test build can substitute one
--  that pretends that the CPU lacks a feature (ada/tests/cpu_env, selected
--  by the WUFFS_TEST_CPU scenario variable of ada/wuffs_gen.gpr), and so
--  exercise every alternative of every `choose` on one machine.

with Wuffs.Runtime.X86.CPUID;

package Wuffs.Runtime.CPU with Preelaborate, SPARK_Mode => Off is

   function Have_X86_SSE42 return Boolean renames Wuffs.Runtime.X86.CPUID.Have_X86_SSE42;
   function Have_X86_AVX2 return Boolean renames Wuffs.Runtime.X86.CPUID.Have_X86_AVX2;
   function Have_X86_BMI2 return Boolean renames Wuffs.Runtime.X86.CPUID.Have_X86_BMI2;

end Wuffs.Runtime.CPU;
