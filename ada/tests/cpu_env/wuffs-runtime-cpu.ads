--  Part of wuffada (wuffs-ada: Wuffs to Ada).
--  SPDX-License-Identifier: Apache-2.0 OR MIT

--  TEST ONLY.  A substitute for ada/src/simd/cpu/wuffs-runtime-cpu.ads that
--  answers as the real one does, except for the features named in the
--  environment variable WUFFS_TEST_CPU_DISABLE, which it says the CPU lacks:
--  a comma-separated list of "x86_sse42", "x86_avx2", "x86_bmi2", or "all".
--  So one test build runs every SIMD implementation that the machine has
--  and, with the variable set, every scalar one.  Selected by
--  -XWUFFS_TEST_CPU=env (the default of ada/wuffs_gen.gpr in a SIMD build).
--  The variable is read once, at the first call.

package Wuffs.Runtime.CPU with Preelaborate, SPARK_Mode => Off is

   function Have_X86_SSE42 return Boolean;
   function Have_X86_AVX2 return Boolean;
   function Have_X86_BMI2 return Boolean;

end Wuffs.Runtime.CPU;
