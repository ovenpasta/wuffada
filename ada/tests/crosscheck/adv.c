// Part of wuffada (wuffs-ada: Wuffs to Ada).
// SPDX-License-Identifier: Apache-2.0 OR MIT

// The C side of the advtest cross-check: it makes the same calls, in the
// same order, as ada/tests/test_adv.adb, on the C code that upstream's
// wuffs-c generates from internal/adagen/testdata/advtest.wuffs, and prints
// the same trace lines. See run_adv.sh, which builds and runs this. Keep it
// in step with test_adv.adb.

#include <inttypes.h>
#include <stdio.h>
#include <string.h>

#define WUFFS_IMPLEMENTATION
#define WUFFS_CONFIG__MODULES
#define WUFFS_CONFIG__MODULE__BASE
#define WUFFS_CONFIG__MODULE__ADVTEST
#include "./advtest.gen.c"

#define LEN 48
#define OUT_CAP 4096
#define NUM_FUNCS 30
#define NUM_SEEDS 64
#define MAX_CALLS 3000

static uint8_t g_in[LEN];
static uint8_t g_out[OUT_CAP];
static uint8_t g_workbuf[8];
static wuffs_advtest__thing g_t;

typedef wuffs_base__status (*fn)(wuffs_advtest__thing*,
                                 wuffs_base__io_buffer*,
                                 wuffs_base__io_buffer*,
                                 wuffs_base__slice_u8);

static const fn g_fns[NUM_FUNCS] = {
    wuffs_advtest__thing__t1, wuffs_advtest__thing__t2,
    wuffs_advtest__thing__t3, wuffs_advtest__thing__t4,
    wuffs_advtest__thing__t5, wuffs_advtest__thing__t6,
    wuffs_advtest__thing__t7, wuffs_advtest__thing__t8,
    wuffs_advtest__thing__t9, wuffs_advtest__thing__u1,
    wuffs_advtest__thing__u2, wuffs_advtest__thing__u3,
    wuffs_advtest__thing__u4, wuffs_advtest__thing__u5,
    wuffs_advtest__thing__v1, wuffs_advtest__thing__w1,
    wuffs_advtest__thing__x1, wuffs_advtest__thing__x2,
    wuffs_advtest__thing__x3, wuffs_advtest__thing__x4,
    wuffs_advtest__thing__x5, wuffs_advtest__thing__x6,
    wuffs_advtest__thing__x7, wuffs_advtest__thing__x8,
    wuffs_advtest__thing__x9, wuffs_advtest__thing__x10,
    wuffs_advtest__thing__x11, wuffs_advtest__thing__y1,
    wuffs_advtest__thing__z1, wuffs_advtest__thing__z2,
};

// The numbering of statuses that test_adv.adb uses too.
static uint64_t status_number(wuffs_base__status s) {
  if (!s.repr) {
    return 0;
  } else if (s.repr == wuffs_base__suspension__short_read) {
    return 1;
  } else if (s.repr == wuffs_base__suspension__short_write) {
    return 2;
  } else if (s.repr == wuffs_advtest__error__bad_thing) {
    return 3;
  } else if (s.repr == wuffs_advtest__error__inner_failed) {
    return 4;
  } else if (s.repr == wuffs_base__error__interleaved_coroutine_calls) {
    return 5;
  } else if (s.repr == wuffs_base__error__disabled_by_previous_error) {
    return 6;
  } else if (s.repr == wuffs_base__note__end_of_data) {
    return 7;
  }
  return 9;
}

// Pseudo-random input: a linear congruential generator, masked in three of
// every four seeds so that small values (which steer the test functions'
// control flow) are common.
static void fill(uint32_t seed) {
  uint32_t x = seed * 2654435761u + 12345u;
  for (int i = 0; i < LEN; i++) {
    x = x * 1103515245u + 12345u;
    uint8_t b = (uint8_t)(x >> 16);
    if (seed % 4 == 1) {
      b &= 7;
    } else if (seed % 4 == 2) {
      b &= 15;
    } else if (seed % 4 == 3 && (i % 3)) {
      b &= 3;
    }
    g_in[i] = b;
  }
}

// How much source the coroutine gets at first and after each "short read",
// and how much room in the destination at first and after each "short
// write". 0 means everything.
static const size_t g_schedules[][2] = {
    {0, 0}, {1, 0}, {0, 1}, {1, 1}, {2, 3}, {3, 2}, {5, 1}, {1, 5}, {7, 7},
};

// FNV-1a over the 8 bytes of x, least significant first.
static void hash_64(uint64_t* h, uint64_t x) {
  for (int i = 0; i < 8; i++) {
    *h = (*h ^ (x & 0xFF)) * 0x100000001B3ull;
    x >>= 8;
  }
}

static void run(int f, uint32_t seed, size_t s, size_t d) {
  fill(seed);
  memset(g_out, 0, sizeof g_out);
  memset(g_workbuf, 0, sizeof g_workbuf);
  wuffs_base__status z = wuffs_advtest__thing__initialize(
      &g_t, sizeof g_t, WUFFS_VERSION, 0);
  if (z.repr) {
    fprintf(stderr, "adv: initialize: %s\n", z.repr);
  }

  wuffs_base__io_buffer src = wuffs_base__empty_io_buffer();
  wuffs_base__io_buffer dst = wuffs_base__empty_io_buffer();
  src.data = wuffs_base__make_slice_u8(g_in, LEN);
  src.meta.wi = s ? s : LEN;
  // Neither stream starts at position zero.
  src.meta.pos = 1000;
  dst.meta.pos = 77;
  size_t cap = d ? d : OUT_CAP;

  uint64_t st = 0;
  uint64_t calls = 0;
  uint64_t h = 0xCBF29CE484222325ull;
  int oks = 0;
  int errs = 0;
  while (1) {
    src.meta.closed = src.meta.wi == LEN;
    dst.data = wuffs_base__make_slice_u8(g_out, cap);
    st = status_number(
        g_fns[f](&g_t, &dst, &src, wuffs_base__make_slice_u8(g_workbuf, 8)));
    calls++;
    hash_64(&h, st);
    hash_64(&h, src.meta.ri);
    hash_64(&h, src.meta.wi);
    hash_64(&h, dst.meta.wi);
    hash_64(&h, wuffs_advtest__thing__get_sum(&g_t));
    hash_64(&h, wuffs_advtest__thing__get_st(&g_t));

    if (st == 1) {
      // Short read: more source, unless there is none.
      if (src.meta.wi == LEN) {
        break;
      }
      src.meta.wi += s;
      if (src.meta.wi > LEN) {
        src.meta.wi = LEN;
      }
    } else if (st == 2) {
      // Short write: more room, unless there is none.
      if (cap == OUT_CAP) {
        break;
      }
      cap += d;
      if (cap > OUT_CAP) {
        cap = OUT_CAP;
      }
    } else if (st == 0 || st == 7) {
      // Complete: call it again (it starts afresh), twice.
      if (++oks >= 3) {
        break;
      }
    } else if (st == 5 || st == 6) {
      break;
    } else {
      // An error: call it once more, to see it refuse.
      if (errs++) {
        break;
      }
    }
    if (calls >= MAX_CALLS) {
      break;
    }
  }

  uint32_t out_hash = 0x811C9DC5u;
  for (size_t i = 0; i < dst.meta.wi; i++) {
    out_hash = (out_hash ^ g_out[i]) * 0x01000193u;
  }
  uint64_t workbuf = 0;
  for (int i = 0; i < 8; i++) {
    workbuf = workbuf * 256 + g_workbuf[i];
  }
  printf("= f%d seed%" PRIu32 " s%zu d%zu calls=%" PRIu64 " status=%" PRIu64
         " ri=%zu out=%zu sum=%08" PRIX32 " st=%08" PRIX32 " outhash=%08" PRIX32
         " workbuf=%016" PRIX64 " callhash=%016" PRIX64 "\n",
         f + 1, seed, s, d, calls, st, src.meta.ri, dst.meta.wi,
         wuffs_advtest__thing__get_sum(&g_t),
         wuffs_advtest__thing__get_st(&g_t), out_hash, workbuf, h);
}

// ---- The n functions: nullable pixel buffers, pixel blends, ranges.

static uint8_t g_pix[64];
static uint8_t g_pal[1024];

static uint64_t fnv_bytes(const uint8_t* p, size_t n) {
  uint64_t h = 0xCBF29CE484222325ull;
  for (size_t i = 0; i < n; i++) {
    h = (h ^ p[i]) * 0x100000001B3ull;
  }
  return h;
}

// Pixel buffer k: 0, BGRA (not premultiplied) 4 by 3; 1, indexed 5 by 2;
// 2, a null pixel buffer.
static void make_pb(wuffs_base__pixel_buffer* pb, int k) {
  for (int i = 0; i < 64; i++) {
    g_pix[i] = (uint8_t)(i * 5 + 2);
  }
  for (int i = 0; i < 1024; i++) {
    g_pal[i] = (uint8_t)(i * 3 + 1);
  }
  *pb = wuffs_base__null_pixel_buffer();
  if (k == 2) {
    return;
  }
  wuffs_base__pixel_config pc = wuffs_base__null_pixel_config();
  uint32_t w = k ? 5 : 4, h = k ? 2 : 3, bpp = k ? 1 : 4;
  wuffs_base__pixel_config__set(
      &pc,
      k ? WUFFS_BASE__PIXEL_FORMAT__INDEXED__BGRA_BINARY
        : WUFFS_BASE__PIXEL_FORMAT__BGRA_NONPREMUL,
      0, w, h);
  wuffs_base__table_u8 t = wuffs_base__make_table_u8(g_pix, w * bpp, h, w * bpp);
  wuffs_base__status st = wuffs_base__pixel_buffer__set_interleaved(
      pb, &pc, t, wuffs_base__make_slice_u8(g_pal, 1024));
  if (st.repr) {
    fprintf(stderr, "adv: set_interleaved: %s\n", st.repr);
  }
}

static void run_n(void) {
  wuffs_base__pixel_buffer pb;
  for (int k = 0; k < 3; k++) {
    for (uint32_t sel = 0; sel < 8; sel++) {
      for (int f = 1; f <= 2; f++) {
        make_pb(&pb, k);
        if (wuffs_advtest__thing__initialize(&g_t, sizeof g_t, WUFFS_VERSION, 0)
                .repr) {
          return;
        }
        if (f == 1) {
          wuffs_advtest__thing__n1(&g_t, &pb, sel);
        } else {
          wuffs_advtest__thing__n2(&g_t, (sel & 4) ? NULL : &pb, sel);
        }
        printf("= n%d pb%d sel%" PRIu32 " r=%016" PRIX64 " pix=%016" PRIX64
               " pal=%016" PRIX64 "\n",
               f, k, sel, wuffs_advtest__thing__get_nres(&g_t), fnv_bytes(g_pix, 64),
               fnv_bytes(g_pal, 1024));
      }
    }
  }
  if (wuffs_advtest__thing__initialize(&g_t, sizeof g_t, WUFFS_VERSION, 0)
          .repr) {
    return;
  }
  static const uint8_t blends[] = {0, 1, 2, 255};
  for (int i = 0; i < 4; i++) {
    for (int j = 0; j < 4; j++) {
      printf("= n3 b%d x%d r=%08" PRIX32 "\n", blends[i], blends[j],
             wuffs_advtest__thing__n3(&g_t, blends[i], blends[j]));
    }
  }
  static const uint64_t ranges[][2] = {
      {0, 0}, {1, 0}, {5, 9}, {UINT64_MAX, UINT64_MAX}, {10, 5}, {3, UINT64_MAX},
  };
  for (int i = 0; i < 6; i++) {
    printf("= n4 %d r=%016" PRIX64 "\n", i,
           wuffs_advtest__thing__n4(&g_t, ranges[i][0], ranges[i][1]));
  }
}

int main(void) {
  for (int f = 0; f < NUM_FUNCS; f++) {
    for (uint32_t seed = 0; seed < NUM_SEEDS; seed++) {
      for (size_t k = 0; k < sizeof g_schedules / sizeof g_schedules[0];
           k++) {
        run(f, seed, g_schedules[k][0], g_schedules[k][1]);
      }
    }
  }

  // Interleaved public coroutines: while t9 is suspended, t1 is refused,
  // and that disables the object.
  fill(0);
  if (wuffs_advtest__thing__initialize(&g_t, sizeof g_t, WUFFS_VERSION, 0)
          .repr) {
    return 1;
  }
  wuffs_base__io_buffer src = wuffs_base__empty_io_buffer();
  wuffs_base__io_buffer dst = wuffs_base__empty_io_buffer();
  src.data = wuffs_base__make_slice_u8(g_in, LEN);
  dst.data = wuffs_base__make_slice_u8(g_out, 64);
  src.meta.wi = 1;
  wuffs_base__slice_u8 workbuf = wuffs_base__make_slice_u8(g_workbuf, 8);
  printf("= interleave 1 %" PRIu64 "\n",
         status_number(wuffs_advtest__thing__t9(&g_t, &dst, &src, workbuf)));
  printf("= interleave 2 %" PRIu64 "\n",
         status_number(wuffs_advtest__thing__t9(&g_t, &dst, &src, workbuf)));
  printf("= interleave 3 %" PRIu64 "\n",
         status_number(wuffs_advtest__thing__t1(&g_t, &dst, &src, workbuf)));
  printf("= interleave 4 %" PRIu64 "\n",
         status_number(wuffs_advtest__thing__t9(&g_t, &dst, &src, workbuf)));
  printf("= interleave 5 %" PRIu64 "\n",
         (uint64_t)wuffs_advtest__thing__get_sum(&g_t));
  run_n();
  return 0;
}
