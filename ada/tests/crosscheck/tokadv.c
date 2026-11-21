// Part of wuffada (wuffs-ada: Wuffs to Ada).
// SPDX-License-Identifier: Apache-2.0 OR MIT

// The C side of the tokadv cross-check: it makes the same calls, in the
// same order, as ada/tests/test_tokadv.adb, on the C code that upstream's
// wuffs-c generates from internal/adagen/testdata/tokadv.wuffs, and prints
// the same trace lines. See run_tokadv.sh, which builds and runs this. Keep
// it in step with test_tokadv.adb.

#include <inttypes.h>
#include <stdio.h>
#include <string.h>

#define WUFFS_IMPLEMENTATION
#define WUFFS_CONFIG__MODULES
#define WUFFS_CONFIG__MODULE__BASE
#define WUFFS_CONFIG__MODULE__TOKADV
#include "./tokadv.gen.c"

#define LEN 64
#define TOK_CAP 4096
#define NUM_SEEDS 64
#define MAX_CALLS 3000

static uint8_t g_in[LEN];
static uint8_t g_src[LEN];
static wuffs_base__token g_tok[TOK_CAP];
static uint8_t g_workbuf[8];
static wuffs_tokadv__thing g_t;

typedef wuffs_base__status (*fn)(wuffs_tokadv__thing*,
                                 wuffs_base__token_buffer*,
                                 wuffs_base__io_buffer*,
                                 wuffs_base__slice_u8);

static const fn g_fns[5] = {
    wuffs_tokadv__thing__k1, wuffs_tokadv__thing__k2, wuffs_tokadv__thing__k3,
    wuffs_tokadv__thing__k4, wuffs_tokadv__thing__k5,
};

// The numbering of statuses that test_tokadv.adb uses too.
static uint64_t status_number(wuffs_base__status s) {
  if (!s.repr) {
    return 0;
  } else if (s.repr == wuffs_base__suspension__short_read) {
    return 1;
  } else if (s.repr == wuffs_base__suspension__short_write) {
    return 2;
  } else if (s.repr == wuffs_tokadv__error__bad_thing) {
    return 3;
  } else if (s.repr == wuffs_base__error__interleaved_coroutine_calls) {
    return 5;
  } else if (s.repr == wuffs_base__error__disabled_by_previous_error) {
    return 6;
  }
  return 9;
}

// Pseudo-random input, as in adv.c: masked in three of every four seeds so
// that small values (which steer the functions' control flow) are common.
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
    if (seed % 8 == 5 && i % 5 == 1) {
      b = 0x61 + (b & 1);
    }
    g_in[i] = b;
  }
}

// The source buffer's capacity and the token buffer's (0: everything).
static const size_t g_schedules[][2] = {
    {0, 0}, {1, 0}, {0, 1}, {1, 1}, {2, 3}, {3, 2}, {12, 1}, {13, 2}, {5, 7},
};

// FNV-1a over the 8 bytes of x, least significant first.
static void hash_64(uint64_t* h, uint64_t x) {
  for (int i = 0; i < 8; i++) {
    *h = (*h ^ (x & 0xFF)) * 0x100000001B3ull;
    x >>= 8;
  }
}

// f 1 .. 5: through decode_tokens (the token_decoder interface), with
// set_quirk selecting k1 .. k5; f 6 .. 10: k1 .. k5 called directly.
static void run(int f, uint32_t seed, size_t s, size_t d) {
  fill(seed);
  memset(g_tok, 0, sizeof g_tok);
  wuffs_base__status z =
      wuffs_tokadv__thing__initialize(&g_t, sizeof g_t, WUFFS_VERSION, 0);
  if (!z.repr && f <= 5) {
    z = wuffs_tokadv__thing__set_quirk(&g_t, 1, (uint64_t)f);
  }
  if (z.repr) {
    fprintf(stderr, "tokadv: initialize: %s\n", z.repr);
  }
  size_t src_cap = s ? s : LEN;
  size_t tok_cap = d ? d : TOK_CAP;
  wuffs_base__io_buffer src = wuffs_base__empty_io_buffer();
  src.data = wuffs_base__make_slice_u8(g_src, src_cap);
  wuffs_base__token_buffer dst = wuffs_base__empty_token_buffer();
  dst.data = wuffs_base__make_slice_token(g_tok, tok_cap);

  size_t in_pos = 0;
  uint64_t calls = 0;
  uint64_t tokens = 0;
  uint64_t tok_hash = 0xCBF29CE484222325ull;
  uint64_t call_hash = 0xCBF29CE484222325ull;
  uint64_t st = 0;
  int stalled = 0;
  while (1) {
    wuffs_base__io_buffer__compact(&src);
    size_t n = src_cap - src.meta.wi;
    if (n > LEN - in_pos) {
      n = LEN - in_pos;
    }
    memcpy(g_src + src.meta.wi, g_in + in_pos, n);
    src.meta.wi += n;
    in_pos += n;
    src.meta.closed = in_pos == LEN;
    size_t old_ri = src.meta.ri;

    wuffs_base__slice_u8 work = wuffs_base__make_slice_u8(g_workbuf, 8);
    wuffs_base__status status =
        (f <= 5) ? wuffs_tokadv__thing__decode_tokens(&g_t, &dst, &src, work)
                 : g_fns[f - 6](&g_t, &dst, &src, work);
    calls++;
    st = status_number(status);
    hash_64(&call_hash, st);
    hash_64(&call_hash, src.meta.ri);
    hash_64(&call_hash, dst.meta.wi);
    size_t written = dst.meta.wi - dst.meta.ri;
    for (size_t i = dst.meta.ri; i < dst.meta.wi; i++) {
      hash_64(&tok_hash, g_tok[i].repr);
      tokens++;
    }
    dst.meta.ri = dst.meta.wi;
    wuffs_base__token_buffer__compact(&dst);
    if (st != 1 && st != 2) {
      break;
    }
    if (src.meta.ri == old_ri && written == 0 &&
        (in_pos == LEN || src.meta.wi == src_cap)) {
      if (++stalled >= 3) {
        break;
      }
    } else {
      stalled = 0;
    }
    if (calls >= MAX_CALLS) {
      break;
    }
  }
  printf("= f%d seed%u s%zu d%zu calls=%" PRIu64 " status=%" PRIu64
         " in=%zu tokens=%" PRIu64 " tokhash=%016" PRIX64
         " callhash=%016" PRIX64 " sum=%08" PRIX32 "\n",
         f, seed, s, d, calls, st, in_pos - (src.meta.wi - src.meta.ri),
         tokens, tok_hash, call_hash, wuffs_tokadv__thing__get_sum(&g_t));
}

int main(void) {
  for (int f = 1; f <= 10; f++) {
    for (uint32_t seed = 0; seed < NUM_SEEDS; seed++) {
      for (size_t i = 0; i < sizeof g_schedules / sizeof g_schedules[0]; i++) {
        run(f, seed, g_schedules[i][0], g_schedules[i][1]);
      }
    }
  }
  return 0;
}
