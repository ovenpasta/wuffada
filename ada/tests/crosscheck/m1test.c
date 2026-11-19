// Part of wuffada (wuffs-ada: Wuffs to Ada).
// SPDX-License-Identifier: Apache-2.0 OR MIT

// The C side of the m1test cross-check: it makes the same calls, in the same
// order, as ada/tests/test_m1.adb, on the C code that upstream's wuffs-c
// generates from internal/adagen/testdata/m1test.wuffs, and prints each value
// as a trace line "= LABEL N HEX". See run.sh, which builds and runs this.
// Keep it in step with test_m1.adb.

#include <inttypes.h>
#include <stdio.h>
#include <string.h>

// Compile the base module and the generated m1test module into this
// translation unit. m1test.gen.c (the output of wuffs-c) includes
// "./wuffs-base.c", which run.sh provides as a copy of
// wuffs/release/c/wuffs-unsupported-snapshot.c.
#define WUFFS_IMPLEMENTATION
#define WUFFS_CONFIG__MODULES
#define WUFFS_CONFIG__MODULE__BASE
#define WUFFS_CONFIG__MODULE__M1TEST
#include "./m1test.gen.c"

static void v(const char* label, int n, uint64_t got) {
  printf("= %s %d %016" PRIX64 "\n", label, n, got);
}

// The numbering of statuses that test_m1.adb uses too.
static uint64_t status_number(wuffs_base__status s) {
  if (s.repr == NULL) {
    return 0;
  } else if (s.repr == wuffs_m1test__error__widget_error) {
    return 1;
  } else if (s.repr == wuffs_m1test__note__widget_note) {
    return 2;
  } else if (s.repr == wuffs_base__error__bad_argument) {
    return 3;
  } else if (s.repr == wuffs_base__error__initialize_not_called) {
    return 4;
  } else if (s.repr == wuffs_base__error__disabled_by_previous_error) {
    return 5;
  }
  return 99;
}

static wuffs_m1test__widget w;

static void initialize(void) {
  wuffs_base__status s =
      wuffs_m1test__widget__initialize(&w, sizeof w, WUFFS_VERSION, 0);
  if (s.repr) {
    fprintf(stderr, "initialize: %s\n", s.repr);
  }
}

int main(void) {
  uint8_t data[11];
  uint32_t total = 0;
  int i;

  for (i = 0; i < 11; i++) {
    data[i] = (uint8_t)((37 * i + 11) % 256);
  }
  // An Ada object that was never initialized has a zero magic field.
  memset(&w, 0, sizeof w);

  v("LIMIT", 0, WUFFS_M1TEST__LIMIT);
  for (i = 0; i < 4; i++) {
    total += WUFFS_M1TEST__WEIGHTS[i];
  }
  v("sum of WEIGHTS", 0, total);
  total = 0;

  v("loops before initialize", 0, wuffs_m1test__widget__loops(&w, 5));
  v("use_small before initialize", 0,
    status_number(wuffs_m1test__widget__use_small(&w, 0)));
  v("toggle_u32 before initialize", 0, wuffs_m1test__widget__toggle_u32(&w));

  initialize();

  v("loops", 0, wuffs_m1test__widget__loops(&w, 0));
  v("loops", 1, wuffs_m1test__widget__loops(&w, 1));
  v("loops", 2, wuffs_m1test__widget__loops(&w, 2));
  v("loops", 5, wuffs_m1test__widget__loops(&w, 5));
  v("loops", 999, wuffs_m1test__widget__loops(&w, 999));
  v("loops", 1000, wuffs_m1test__widget__loops(&w, 1000));
  v("loops", 5000, wuffs_m1test__widget__loops(&w, 5000));
  v("loops", -1, wuffs_m1test__widget__loops(&w, 0xFFFFFFFFu));

  v("arith", 1, wuffs_m1test__widget__arith(&w, 0, 0, 0));
  v("arith", 2, wuffs_m1test__widget__arith(&w, 1, 2, 3));
  v("arith", 3, wuffs_m1test__widget__arith(&w, 6, 2, 0));
  v("toggle_u32", 1, wuffs_m1test__widget__toggle_u32(&w));
  v("arith", 4, wuffs_m1test__widget__arith(&w, 1, 2, 3));
  v("arith", 5, wuffs_m1test__widget__arith(&w, 0xFFFFFFFFu, 0xFFFFFFFFu, 7));
  v("arith", 6, wuffs_m1test__widget__arith(&w, 100, 7, 9));
  v("arith", 7, wuffs_m1test__widget__arith(&w, 12, 0, 0));
  v("arith", 8, wuffs_m1test__widget__arith(&w, 4, 0, 0));
  v("arith", 9, wuffs_m1test__widget__arith(&w, 3, 1, 0));
  v("arith", 10, wuffs_m1test__widget__arith(&w, 6, 2, 0));
  v("toggle_u32", 2, wuffs_m1test__widget__toggle_u32(&w));

  for (i = 0; i < 8; i++) {
    v("use_small", i,
      status_number(wuffs_m1test__widget__use_small(&w, (uint32_t)i + 8)));
    v("get_total", i, wuffs_m1test__widget__get_total(&w));
  }
  for (i = 0; i < 8; i++) {
    v("get_hist", i, wuffs_m1test__widget__get_hist(&w, (uint32_t)i));
  }

  for (i = 0; i < 12; i++) {
    v("windows", i,
      wuffs_m1test__widget__windows(
          &w, wuffs_base__make_slice_u8(data, (size_t)i)));
  }

  v("countdown", 10, wuffs_m1test__widget__countdown(&w, 10));
  v("countdown", 0, wuffs_m1test__widget__countdown(&w, 0));
  v("narrow", 0, wuffs_m1test__widget__narrow(&w, 0));
  v("narrow", 100, wuffs_m1test__widget__narrow(&w, 100));
  v("narrow", 101, wuffs_m1test__widget__narrow(&w, 101));
  v("narrow", 255, wuffs_m1test__widget__narrow(&w, 255));
  v("narrow", 256, wuffs_m1test__widget__narrow(&w, 256));
  v("narrow", 511, wuffs_m1test__widget__narrow(&w, 511));

  for (i = 0; i < 4; i++) {
    v("names", i,
      wuffs_m1test__widget__names(
          &w, wuffs_base__make_slice_u8(data, (size_t)i)));
  }
  v("call_loops", 0, wuffs_m1test__widget__call_loops(&w, 0));
  v("call_loops", 500, wuffs_m1test__widget__call_loops(&w, 500));
  v("get_total", 99, wuffs_m1test__widget__get_total(&w));

  for (i = 0; i < 6; i++) {
    v("find", i, wuffs_m1test__widget__find(&w, (uint32_t)i));
  }
  v("find", 1000, wuffs_m1test__widget__find(&w, 1000));
  v("pick", 11, wuffs_m1test__widget__pick(&w, 11));
  v("pick", 10, wuffs_m1test__widget__pick(&w, 10));
  v("pick", 6, wuffs_m1test__widget__pick(&w, 6));
  v("pick", 5, wuffs_m1test__widget__pick(&w, 5));
  v("pick", 0, wuffs_m1test__widget__pick(&w, 0));

  {
    static const size_t slices_length[6] = {0, 1, 2, 4, 6, 6};
    static const uint32_t slices_k[6] = {0, 5, 77, 1000, 0xFFFFFFFFu, 3};
    for (i = 0; i < 6; i++) {
      uint8_t scratch[6];
      uint64_t x = 0;
      int j;
      for (j = 0; j < 6; j++) {
        scratch[j] = (uint8_t)((13 * j + 5 + i) % 256);
      }
      v("slices", i,
        wuffs_m1test__widget__slices(
            &w, wuffs_base__make_slice_u8(scratch, slices_length[i]),
            slices_k[i]));
      for (j = 0; j < 6; j++) {
        x = x * 256 + scratch[j];
      }
      v("slices x", i, x);
    }
  }

  wuffs_m1test__widget__set_count(&w, 500);
  v("get_count", 500, wuffs_m1test__widget__get_count(&w));
  wuffs_m1test__widget__set_count(&w, 1000);
  v("get_count", 1000, wuffs_m1test__widget__get_count(&w));
  wuffs_m1test__widget__set_count(&w, 1001);
  v("get_count", 1001, wuffs_m1test__widget__get_count(&w));
  wuffs_m1test__widget__set_count(&w, 1);
  v("get_count", 1, wuffs_m1test__widget__get_count(&w));
  v("loops when disabled", 0, wuffs_m1test__widget__loops(&w, 5));
  v("use_small when disabled", 0,
    status_number(wuffs_m1test__widget__use_small(&w, 0)));

  initialize();
  v("get_count after initialize", 0, wuffs_m1test__widget__get_count(&w));
  v("get_total after initialize", 0, wuffs_m1test__widget__get_total(&w));
  for (i = 0; i < 8; i++) {
    v("get_hist after initialize", i,
      wuffs_m1test__widget__get_hist(&w, (uint32_t)i));
  }
  v("loops after initialize", 0, wuffs_m1test__widget__loops(&w, 5));
  return 0;
}
