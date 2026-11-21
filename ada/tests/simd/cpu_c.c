// Part of wuffada (wuffs-ada: Wuffs to Ada).
// SPDX-License-Identifier: Apache-2.0 OR MIT

// What GCC's __builtin_cpu_supports says about the features that upstream's
// wuffs_base__cpu_arch__have_x86_sse42, _avx2 and _bmi2 test, combined as
// they combine them, in the format of test_simd's "cpu" lines.
#include <stdio.h>

int main(void) {
  __builtin_cpu_init();
  int sse42 = __builtin_cpu_supports("sse4.2") && __builtin_cpu_supports("pclmul") &&
              __builtin_cpu_supports("popcnt");
  int avx2 = __builtin_cpu_supports("avx2") && sse42;
  int bmi2 = __builtin_cpu_supports("bmi2");
  printf("cpu x86_sse42 %d\ncpu x86_avx2 %d\ncpu x86_bmi2 %d\n", sse42 ? 1 : 0, avx2 ? 1 : 0, bmi2 ? 1 : 0);
  return 0;
}
