// Oracle for ada/tests_base: runs upstream Wuffs' own C base library over
// fixed input sweeps and prints one 64-bit digest per sweep.  The Ada tests
// run the same sweeps through Wuffs.Base.* and compare digests, so the
// expected values come from the C code being replaced, not from the Ada.
//
// Build and run via ./regen.sh, which writes ../base_oracle_data.ads.
//
// Each sweep here has a twin of the same name in ../test_*.adb.  The two
// must enumerate the same cases, draw random numbers and call mix() in the
// same order.

#define WUFFS_IMPLEMENTATION
#define WUFFS_CONFIG__MODULES
#define WUFFS_CONFIG__MODULE__BASE
#define WUFFS_CONFIG__MODULE__BASE__CORE

#include WUFFS_C_FILE

#include <inttypes.h>
#include <stdio.h>

static uint64_t g_h;
static uint64_t g_rng;

static void begin(uint64_t seed) {
  g_h = 0xCBF29CE484222325ull;
  g_rng = seed;
}

static void mix(uint64_t v) {
  g_h = (g_h ^ v) * 0x100000001B3ull;
}

static uint64_t rnd(void) {
  g_rng = (g_rng * 6364136223846793005ull) + 1442695040888963407ull;
  return g_rng ^ (g_rng >> 31);
}

static void fill(uint8_t* p, size_t n) {
  for (size_t i = 0; i < n; i++) {
    p[i] = (uint8_t)(rnd() >> 56);
  }
}

static void mix_bytes(const uint8_t* p, size_t n) {
  for (size_t i = 0; i < n; i++) {
    mix(p[i]);
  }
}

static void end(const char* name) {
  printf("   %s : constant Wuffs.U64 := 16#%016" PRIX64 "#;\n", name, g_h);
}

// ---------------- Ints

// vals fills v[0..16] with 8 edge values and 8 random values of the width.
static void vals(uint64_t* v, int width) {
  uint64_t all = (width == 64) ? ~0ull : ((1ull << width) - 1);
  uint64_t top = 1ull << (width - 1);
  v[0] = 0;
  v[1] = 1;
  v[2] = 2;
  v[3] = top - 1;
  v[4] = top;
  v[5] = all - 1;
  v[6] = all;
  v[7] = 0x5555555555555555ull & all;
  for (int i = 8; i < 16; i++) {
    v[i] = rnd() & all;
  }
}

static void sweep_ints_arith(void) {
  begin(1);
  uint64_t v[16];

  vals(v, 8);
  for (int i = 0; i < 16; i++) {
    for (int j = 0; j < 16; j++) {
      uint8_t x = (uint8_t)v[i], y = (uint8_t)v[j];
      mix(wuffs_base__u8__min(x, y));
      mix(wuffs_base__u8__max(x, y));
      mix(wuffs_base__u8__sat_add(x, y));
      mix(wuffs_base__u8__sat_sub(x, y));
    }
  }
  vals(v, 16);
  for (int i = 0; i < 16; i++) {
    for (int j = 0; j < 16; j++) {
      uint16_t x = (uint16_t)v[i], y = (uint16_t)v[j];
      mix(wuffs_base__u16__min(x, y));
      mix(wuffs_base__u16__max(x, y));
      mix(wuffs_base__u16__sat_add(x, y));
      mix(wuffs_base__u16__sat_sub(x, y));
    }
  }
  vals(v, 32);
  for (int i = 0; i < 16; i++) {
    for (int j = 0; j < 16; j++) {
      uint32_t x = (uint32_t)v[i], y = (uint32_t)v[j];
      mix(wuffs_base__u32__min(x, y));
      mix(wuffs_base__u32__max(x, y));
      mix(wuffs_base__u32__sat_add(x, y));
      mix(wuffs_base__u32__sat_sub(x, y));
    }
  }
  vals(v, 64);
  for (int i = 0; i < 16; i++) {
    for (int j = 0; j < 16; j++) {
      uint64_t x = v[i], y = v[j];
      mix(wuffs_base__u64__min(x, y));
      mix(wuffs_base__u64__max(x, y));
      mix(wuffs_base__u64__sat_add(x, y));
      mix(wuffs_base__u64__sat_sub(x, y));
    }
  }
  end("Ints_Arith");
}

// The low_bits and high_bits expressions are the ones that
// wuffs/internal/cgen/builtin.go (writeBuiltinNumType) emits.  high_bits
// starts at n = 1: for n = 0 the emitted C shifts by the full width, which
// is undefined for u32 and u64.
static void sweep_ints_bits(void) {
  begin(2);
  uint64_t v[16];

  vals(v, 8);
  for (int i = 0; i < 16; i++) {
    uint8_t x = (uint8_t)v[i];
    for (uint32_t n = 0; n < 8; n++) {
      mix((uint8_t)((x) & WUFFS_PRIVATE_IMPL__LOW_BITS_MASK__U8(n)));
    }
    for (uint32_t n = 1; n < 8; n++) {
      mix((uint8_t)((x) >> (8u - n)));
    }
  }
  vals(v, 16);
  for (int i = 0; i < 16; i++) {
    uint16_t x = (uint16_t)v[i];
    for (uint32_t n = 0; n < 16; n++) {
      mix((uint16_t)((x) & WUFFS_PRIVATE_IMPL__LOW_BITS_MASK__U16(n)));
    }
    for (uint32_t n = 1; n < 16; n++) {
      mix((uint16_t)((x) >> (16u - n)));
    }
  }
  vals(v, 32);
  for (int i = 0; i < 16; i++) {
    uint32_t x = (uint32_t)v[i];
    for (uint32_t n = 0; n < 32; n++) {
      mix(((x) & WUFFS_PRIVATE_IMPL__LOW_BITS_MASK__U32(n)));
    }
    for (uint32_t n = 1; n < 32; n++) {
      mix(((x) >> (32u - n)));
    }
  }
  vals(v, 64);
  for (int i = 0; i < 16; i++) {
    uint64_t x = v[i];
    for (uint32_t n = 0; n < 64; n++) {
      mix(((x) & WUFFS_PRIVATE_IMPL__LOW_BITS_MASK__U64(n)));
    }
    for (uint32_t n = 1; n < 64; n++) {
      mix(((x) >> (64u - n)));
    }
  }
  end("Ints_Bits");
}

static void sweep_ints_sign(void) {
  begin(3);
  uint64_t v[16];

  vals(v, 8);
  for (int i = 0; i < 16; i++) {
    uint8_t x = (uint8_t)v[i];
    mix(wuffs_base__utility__sign_extend_convert_u8_u32(x));
    mix(wuffs_base__utility__sign_extend_convert_u8_u64(x));
  }
  vals(v, 16);
  for (int i = 0; i < 16; i++) {
    uint16_t x = (uint16_t)v[i];
    mix(wuffs_base__utility__sign_extend_convert_u16_u32(x));
    mix(wuffs_base__utility__sign_extend_convert_u16_u64(x));
    for (uint16_t n = 0; n < 16; n++) {
      mix(wuffs_base__utility__sign_extend_rshift_u16(x, n));
    }
  }
  vals(v, 32);
  for (int i = 0; i < 16; i++) {
    uint32_t x = (uint32_t)v[i];
    mix(wuffs_base__utility__sign_extend_convert_u32_u64(x));
    for (uint32_t n = 0; n < 32; n++) {
      mix(wuffs_base__utility__sign_extend_rshift_u32(x, n));
    }
  }
  vals(v, 64);
  for (int i = 0; i < 16; i++) {
    uint64_t x = v[i];
    for (uint32_t n = 0; n < 64; n++) {
      mix(wuffs_base__utility__sign_extend_rshift_u64(x, n));
    }
  }
  // i64_divide.  Skipped: b == 0 (excluded by the Wuffs signature) and
  // INT64_MIN / -1 (undefined in C).
  for (int i = 0; i < 16; i++) {
    for (int j = 0; j < 16; j++) {
      uint64_t a = v[i], b = v[j];
      if ((b == 0) || ((a == 0x8000000000000000ull) && (b == ~0ull))) {
        continue;
      }
      mix(wuffs_base__utility__i64_divide(a, b));
    }
  }
  // bitvec256 and optional_u63.
  wuffs_base__bitvec256 bv =
      wuffs_base__utility__make_bitvec256(v[8], v[9], v[10], v[11]);
  for (uint32_t i = 0; i < 8; i++) {
    mix(wuffs_base__bitvec256__get_u64(&bv, i));
  }
  for (int i = 0; i < 16; i++) {
    for (int h = 0; h < 2; h++) {
      wuffs_base__optional_u63 o =
          wuffs_base__utility__make_optional_u63(h != 0, v[i] >> 1);
      mix(wuffs_base__optional_u63__has_value(&o) ? 1 : 0);
      mix(wuffs_base__optional_u63__value(&o));
      mix(wuffs_base__optional_u63__value_or(&o, 123));
    }
  }
  end("Ints_Sign");
}

// ---------------- Endian

static void sweep_endian_peek(void) {
  begin(4);
  uint8_t buf[24];
  fill(buf, 24);
  for (int off = 0; off <= 16; off++) {
    const uint8_t* p = buf + off;
    mix(wuffs_base__peek_u8__no_bounds_check(p));
    mix(wuffs_base__peek_u16be__no_bounds_check(p));
    mix(wuffs_base__peek_u16le__no_bounds_check(p));
    mix(wuffs_base__peek_u24be__no_bounds_check(p));
    mix(wuffs_base__peek_u24le__no_bounds_check(p));
    mix(wuffs_base__peek_u32be__no_bounds_check(p));
    mix(wuffs_base__peek_u32le__no_bounds_check(p));
    mix(wuffs_base__peek_u40be__no_bounds_check(p));
    mix(wuffs_base__peek_u40le__no_bounds_check(p));
    mix(wuffs_base__peek_u48be__no_bounds_check(p));
    mix(wuffs_base__peek_u48le__no_bounds_check(p));
    mix(wuffs_base__peek_u56be__no_bounds_check(p));
    mix(wuffs_base__peek_u56le__no_bounds_check(p));
    mix(wuffs_base__peek_u64be__no_bounds_check(p));
    mix(wuffs_base__peek_u64le__no_bounds_check(p));
  }
  end("Endian_Peek");
}

static void sweep_endian_poke(void) {
  begin(5);
  uint8_t buf[24];
  uint8_t d[24];
  fill(buf, 24);
  static const int offs[3] = {0, 5, 16};
  for (int kind = 0; kind < 15; kind++) {
    for (int o = 0; o < 3; o++) {
      // The full 64 random bits are passed (truncated to the parameter
      // type), so the 24, 40, 48 and 56 bit pokes see non-zero high bits.
      uint64_t v = rnd();
      memcpy(d, buf, 24);
      uint8_t* p = d + offs[o];
      switch (kind) {
        case 0: wuffs_base__poke_u8__no_bounds_check(p, (uint8_t)v); break;
        case 1: wuffs_base__poke_u16be__no_bounds_check(p, (uint16_t)v); break;
        case 2: wuffs_base__poke_u16le__no_bounds_check(p, (uint16_t)v); break;
        case 3: wuffs_base__poke_u24be__no_bounds_check(p, (uint32_t)v); break;
        case 4: wuffs_base__poke_u24le__no_bounds_check(p, (uint32_t)v); break;
        case 5: wuffs_base__poke_u32be__no_bounds_check(p, (uint32_t)v); break;
        case 6: wuffs_base__poke_u32le__no_bounds_check(p, (uint32_t)v); break;
        case 7: wuffs_base__poke_u40be__no_bounds_check(p, v); break;
        case 8: wuffs_base__poke_u40le__no_bounds_check(p, v); break;
        case 9: wuffs_base__poke_u48be__no_bounds_check(p, v); break;
        case 10: wuffs_base__poke_u48le__no_bounds_check(p, v); break;
        case 11: wuffs_base__poke_u56be__no_bounds_check(p, v); break;
        case 12: wuffs_base__poke_u56le__no_bounds_check(p, v); break;
        case 13: wuffs_base__poke_u64be__no_bounds_check(p, v); break;
        case 14: wuffs_base__poke_u64le__no_bounds_check(p, v); break;
      }
      mix_bytes(d, 24);
    }
  }
  end("Endian_Poke");
}

// ---------------- Ranges

static const uint32_t S32[6] = {0, 1, 2, 5, 0xFFFFFFFEu, 0xFFFFFFFFu};
static const uint64_t S64[6] = {0, 1, 2, 5, 0xFFFFFFFFFFFFFFFEull,
                                0xFFFFFFFFFFFFFFFFull};

#define RANGE_SWEEP(T, S, MAX, HAS_LENGTH)                                   \
  for (int a = 0; a < 6; a++)                                                \
    for (int b = 0; b < 6; b++)                                              \
      for (int c = 0; c < 6; c++)                                            \
        for (int d = 0; d < 6; d++) {                                        \
          wuffs_base__##T r = wuffs_base__make_##T(S[a], S[b]);              \
          wuffs_base__##T s = wuffs_base__make_##T(S[c], S[d]);              \
          mix(wuffs_base__##T##__is_empty(&r) ? 1 : 0);                      \
          mix(wuffs_base__##T##__equals(&r, s) ? 1 : 0);                     \
          wuffs_base__##T t = wuffs_base__##T##__intersect(&r, s);           \
          mix(t.min_incl);                                                   \
          mix(t.MAX);                                                        \
          wuffs_base__##T u = wuffs_base__##T##__unite(&r, s);               \
          mix(u.min_incl);                                                   \
          mix(u.MAX);                                                        \
          mix(wuffs_base__##T##__contains_range(&r, s) ? 1 : 0);             \
          HAS_LENGTH                                                         \
          for (int x = 0; x < 6; x++) {                                      \
            mix(wuffs_base__##T##__contains(&r, S[x]) ? 1 : 0);              \
          }                                                                  \
        }

static void sweep_ranges(void) {
  begin(6);
  RANGE_SWEEP(range_ie_u32, S32, max_excl,
              mix(wuffs_base__range_ie_u32__length(&r));)
  end("Range_IE_U32");
  begin(7);
  RANGE_SWEEP(range_ii_u32, S32, max_incl, )
  end("Range_II_U32");
  begin(8);
  RANGE_SWEEP(range_ie_u64, S64, max_excl,
              mix(wuffs_base__range_ie_u64__length(&r));)
  end("Range_IE_U64");
  begin(9);
  RANGE_SWEEP(range_ii_u64, S64, max_incl, )
  end("Range_II_U64");
}

static const uint32_t R32[4] = {0, 1, 3, 0xFFFFFFFFu};

#define RECT_SWEEP(T, MAXX, MAXY, HAS_SIZE)                                  \
  for (int a = 0; a < 4; a++)                                                \
    for (int b = 0; b < 4; b++)                                              \
      for (int c = 0; c < 4; c++)                                            \
        for (int d = 0; d < 4; d++)                                          \
          for (int e = 0; e < 4; e++)                                        \
            for (int f = 0; f < 4; f++)                                      \
              for (int g = 0; g < 4; g++)                                    \
                for (int h = 0; h < 4; h++) {                                \
                  wuffs_base__##T r =                                        \
                      wuffs_base__make_##T(R32[a], R32[b], R32[c], R32[d]);  \
                  wuffs_base__##T s =                                        \
                      wuffs_base__make_##T(R32[e], R32[f], R32[g], R32[h]);  \
                  mix(wuffs_base__##T##__is_empty(&r) ? 1 : 0);              \
                  mix(wuffs_base__##T##__equals(&r, s) ? 1 : 0);             \
                  wuffs_base__##T t = wuffs_base__##T##__intersect(&r, s);   \
                  mix(t.min_incl_x);                                         \
                  mix(t.min_incl_y);                                         \
                  mix(t.MAXX);                                               \
                  mix(t.MAXY);                                               \
                  wuffs_base__##T u = wuffs_base__##T##__unite(&r, s);       \
                  mix(u.min_incl_x);                                         \
                  mix(u.min_incl_y);                                         \
                  mix(u.MAXX);                                               \
                  mix(u.MAXY);                                               \
                  mix(wuffs_base__##T##__contains_rect(&r, s) ? 1 : 0);      \
                  HAS_SIZE                                                   \
                  for (int x = 0; x < 4; x++) {                              \
                    for (int y = 0; y < 4; y++) {                            \
                      mix(wuffs_base__##T##__contains(&r, R32[x], R32[y])    \
                              ? 1                                            \
                              : 0);                                          \
                    }                                                        \
                  }                                                          \
                }

static void sweep_rects(void) {
  begin(10);
  RECT_SWEEP(rect_ie_u32, max_excl_x, max_excl_y,
             mix(wuffs_base__rect_ie_u32__width(&r));
             mix(wuffs_base__rect_ie_u32__height(&r));)
  end("Rect_IE_U32");
  begin(11);
  RECT_SWEEP(rect_ii_u32, max_incl_x, max_incl_y, )
  end("Rect_II_U32");
}

// ---------------- Slices

static const uint64_t UP_TOS[8] = {0,   1,                     3, 6, 7,
                                   100, 0x8000000000000000ull, ~0ull};

static void sweep_slices_prefix_suffix(void) {
  begin(12);
  uint8_t buf[8] = {0};
  for (size_t len = 0; len <= 6; len++) {
    for (int u = 0; u < 8; u++) {
      wuffs_base__slice_u8 s = wuffs_base__make_slice_u8(buf, len);
      wuffs_base__slice_u8 p = wuffs_private_impl__slice_u8__prefix(s, UP_TOS[u]);
      mix(p.len);
      wuffs_base__slice_u8 q = wuffs_private_impl__slice_u8__suffix(s, UP_TOS[u]);
      mix(q.len);
      mix((uint64_t)(q.ptr - buf));
    }
  }
  end("Slices_Prefix_Suffix");
}

static void sweep_slices_iterate(void) {
  begin(31);
  for (size_t total = 0; total <= 20; total++) {
    for (size_t len = 1; len <= 6; len++) {
      for (size_t adv = 1; adv <= len; adv++) {
        mix(wuffs_private_impl__iterate_total_advance(total, len, adv));
      }
    }
  }
  end("Slices_Iterate");
}

static void sweep_slices_copy(void) {
  begin(13);
  uint8_t src[10], dst[10], d[10];
  fill(src, 10);
  fill(dst, 10);
  for (size_t dl = 0; dl <= 10; dl++) {
    for (size_t sl = 0; sl <= 10; sl++) {
      memcpy(d, dst, 10);
      mix(wuffs_private_impl__slice_u8__copy_from_slice(
          wuffs_base__make_slice_u8(d, dl), wuffs_base__make_slice_u8(src, sl)));
      mix_bytes(d, 10);
    }
  }
  end("Slices_Copy");
}

// Destination and source are both parts of one 12 byte array, in every
// arrangement: this is the memmove behaviour that Copy_Within reproduces.
static void sweep_slices_copy_within(void) {
  begin(14);
  uint8_t base[12], d[12];
  fill(base, 12);
  for (size_t df = 0; df <= 12; df++) {
    for (size_t dl = 0; dl <= 12 - df; dl++) {
      for (size_t sf = 0; sf <= 12; sf++) {
        for (size_t sl = 0; sl <= 12 - sf; sl++) {
          memcpy(d, base, 12);
          mix(wuffs_private_impl__slice_u8__copy_from_slice(
              wuffs_base__make_slice_u8(d + df, dl),
              wuffs_base__make_slice_u8(d + sf, sl)));
          mix_bytes(d, 12);
        }
      }
    }
  }
  end("Slices_Copy_Within");
}

static const uint8_t MEMSET_VALUES[4] = {0x00, 0x80, 0xFF, 0x5A};

static void sweep_slices_memset(void) {
  begin(15);
  for (size_t n = 0; n <= 5; n++) {
    for (int k = 0; k < 4; k++) {
      uint8_t a8[5];
      uint16_t a16[5];
      uint32_t a32[5];
      uint64_t a64[5];
      for (int i = 0; i < 5; i++) {
        uint64_t x = 0x0123456789ABCDEFull * (uint64_t)(i + 1);
        a8[i] = (uint8_t)x;
        a16[i] = (uint16_t)x;
        a32[i] = (uint32_t)x;
        a64[i] = x;
      }
      wuffs_private_impl__bulk_memset(a8, n * 1, MEMSET_VALUES[k]);
      wuffs_private_impl__bulk_memset(a16, n * 2, MEMSET_VALUES[k]);
      wuffs_private_impl__bulk_memset(a32, n * 4, MEMSET_VALUES[k]);
      wuffs_private_impl__bulk_memset(a64, n * 8, MEMSET_VALUES[k]);
      for (int i = 0; i < 5; i++) {
        mix(a8[i]);
        mix(a16[i]);
        mix(a32[i]);
        mix(a64[i]);
      }
    }
  }
  end("Slices_Memset");
}

// Host endian: this digest is only valid on a machine with the byte order
// of the one that ran the oracle (regen.sh records it).
static void sweep_slices_bulk(void) {
  begin(16);
  uint8_t bytes[40], d[40];
  fill(bytes, 40);
  for (size_t size = 1; size <= 8; size *= 2) {
    for (size_t n = 0; n <= 5; n++) {
      size_t lens[4] = {0, (n * size) > 0 ? (n * size) - 1 : 0, n * size, 40};
      for (int k = 0; k < 4; k++) {
        uint8_t a8[5];
        uint16_t a16[5];
        uint32_t a32[5];
        uint64_t a64[5];
        for (int i = 0; i < 5; i++) {
          uint64_t x = 0x0123456789ABCDEFull * (uint64_t)(i + 1);
          a8[i] = (uint8_t)x;
          a16[i] = (uint16_t)x;
          a32[i] = (uint32_t)x;
          a64[i] = x;
        }
        void* p = (size == 1)   ? (void*)a8
                  : (size == 2) ? (void*)a16
                  : (size == 4) ? (void*)a32
                                : (void*)a64;
        // Save first (from the fixed element values), then load.
        memcpy(d, bytes, 40);
        wuffs_private_impl__bulk_save_host_endian(
            p, n * size, wuffs_base__make_slice_u8(d, lens[k]));
        mix_bytes(d, 40);
        wuffs_private_impl__bulk_load_host_endian(
            p, n * size, wuffs_base__make_slice_u8(bytes, lens[k]));
        for (int i = 0; i < 5; i++) {
          mix((size == 1)   ? a8[i]
              : (size == 2) ? a16[i]
              : (size == 4) ? a32[i]
                            : a64[i]);
        }
      }
    }
  }
  end("Slices_Bulk");
}

// ---------------- I/O

static void sweep_io_count_limit(void) {
  begin(17);
  static const uint64_t cs[4] = {0, 1, 5, ~0ull};
  for (int i = 0; i < 4; i++) {
    for (int j = 0; j < 4; j++) {
      mix(wuffs_private_impl__io__count_since(cs[i], cs[j]));
    }
  }
  static const uint64_t limits[8] = {0, 1, 4, 5, 6, 20, 21, ~0ull};
  uint8_t buf[20] = {0};
  for (size_t iop = 0; iop <= 20; iop += 5) {
    for (size_t io2 = iop; io2 <= 20; io2 += 5) {
      for (int k = 0; k < 8; k++) {
        const uint8_t* r2 = buf + io2;
        wuffs_private_impl__io_reader__limit(&r2, buf + iop, limits[k]);
        mix((uint64_t)(r2 - buf));
        uint8_t* w2 = buf + io2;
        wuffs_private_impl__io_writer__limit(&w2, buf + iop, limits[k]);
        mix((uint64_t)(w2 - buf));
      }
    }
  }
  end("IO_Count_Limit");
}

// For each number of available bytes, closed flag and prefix length n: a
// matching prefix (variant == n) and one that differs in byte `variant`.
// Prefix bytes beyond n are garbage that must be ignored.  Skipped: n == 0
// with 8 or more bytes available, where the C code shifts by 64.
static void sweep_io_match7(void) {
  begin(18);
  uint8_t buf[12];
  fill(buf, 12);
  for (size_t iop = 0; iop <= 2; iop += 2) {
    for (size_t avail = 0; avail <= 10; avail++) {
      for (int closed = 0; closed < 2; closed++) {
        for (uint32_t n = 0; n < 8; n++) {
          for (uint32_t variant = 0; variant <= n; variant++) {
            if ((n == 0) && (avail >= 8)) {
              continue;
            }
            uint64_t a = n;
            for (uint32_t j = 0; j < 7; j++) {
              uint8_t b = (j < n) ? buf[iop + j] : 0xA5;
              if (j == variant) {
                b ^= 0x01;
              }
              a |= ((uint64_t)b) << (8 * (j + 1));
            }
            wuffs_base__io_buffer r =
                wuffs_base__ptr_u8__reader(buf, 12, closed != 0);
            mix(wuffs_private_impl__io_reader__match7(
                buf + iop, buf + iop + avail, &r, a));
          }
        }
      }
    }
  }
  end("IO_Match7");
}

static const uint32_t COPY_UP_TOS[4] = {0, 1, 5, 100};
static const size_t COPY_LENS[4] = {0, 1, 4, 12};

static void sweep_io_copies(void) {
  begin(19);
  uint8_t src[12], dst[12], d[12];
  fill(src, 12);
  fill(dst, 12);

  // io_reader.limited_copy_u32_to_slice.
  for (size_t iop = 0; iop <= 3; iop += 3) {
    size_t io2s[3] = {iop, iop + 1, 12};
    for (int i = 0; i < 3; i++) {
      for (int u = 0; u < 4; u++) {
        for (int l = 0; l < 4; l++) {
          memcpy(d, dst, 12);
          const uint8_t* p = src + iop;
          mix(wuffs_private_impl__io_reader__limited_copy_u32_to_slice(
              &p, src + io2s[i], COPY_UP_TOS[u],
              wuffs_base__make_slice_u8(d, COPY_LENS[l])));
          mix((uint64_t)(p - src));
          mix_bytes(d, 12);
        }
      }
    }
  }
  end("IO_Copy_To_Slice");

  // io_writer.copy_from_slice and limited_copy_u32_from_slice.
  begin(20);
  fill(src, 12);
  fill(dst, 12);
  for (size_t iop = 0; iop <= 3; iop += 3) {
    size_t io2s[3] = {iop, iop + 1, 12};
    for (int i = 0; i < 3; i++) {
      for (int l = 0; l < 4; l++) {
        memcpy(d, dst, 12);
        uint8_t* p = d + iop;
        mix(wuffs_private_impl__io_writer__copy_from_slice(
            &p, d + io2s[i], wuffs_base__make_slice_u8(src, COPY_LENS[l])));
        mix((uint64_t)(p - d));
        mix_bytes(d, 12);
        for (int u = 0; u < 4; u++) {
          memcpy(d, dst, 12);
          p = d + iop;
          mix(wuffs_private_impl__io_writer__limited_copy_u32_from_slice(
              &p, d + io2s[i], COPY_UP_TOS[u],
              wuffs_base__make_slice_u8(src, COPY_LENS[l])));
          mix((uint64_t)(p - d));
          mix_bytes(d, 12);
        }
      }
    }
  }
  end("IO_Copy_From_Slice");

  // io_writer.limited_copy_u32_from_reader.
  begin(21);
  fill(src, 12);
  fill(dst, 12);
  for (size_t wp = 0; wp <= 3; wp += 3) {
    size_t w2s[3] = {wp, wp + 2, 12};
    for (int i = 0; i < 3; i++) {
      for (size_t rp = 0; rp <= 5; rp += 5) {
        size_t r2s[3] = {rp, rp + 3, 12};
        for (int j = 0; j < 3; j++) {
          for (int u = 0; u < 4; u++) {
            memcpy(d, dst, 12);
            uint8_t* pw = d + wp;
            const uint8_t* pr = src + rp;
            mix(wuffs_private_impl__io_writer__limited_copy_u32_from_reader(
                &pw, d + w2s[i], COPY_UP_TOS[u], &pr, src + r2s[j]));
            mix((uint64_t)(pw - d));
            mix((uint64_t)(pr - src));
            mix_bytes(d, 12);
          }
        }
      }
    }
  }
  end("IO_Copy_From_Reader");
}

// The four two-operand I/O copies and the two U8 bulk copies, with both
// operands inside one 16 byte array, overlapping in every way the sweep can
// arrange.  The C functions are memmoves; the Ada twins are the _Within
// forms.
static void sweep_io_within(void) {
  begin(32);
  uint8_t base[16], d[16];
  fill(base, 16);
  static const uint32_t up_tos[3] = {0, 2, 100};

  // Reader to slice, and slice to writer (plain and limited): the cursor
  // runs over [iop, io2), the slice is [off, off + len).
  for (size_t iop = 0; iop <= 8; iop += 4) {
    size_t io2s[2] = {iop + 6, 16};
    for (int i = 0; i < 2; i++) {
      for (size_t off = 0; off <= 12; off += 2) {
        size_t lens[3] = {0, 3, (16 - off) < 8 ? (16 - off) : 8};
        for (int l = 0; l < 3; l++) {
          memcpy(d, base, 16);
          uint8_t* pw = d + iop;
          mix(wuffs_private_impl__io_writer__copy_from_slice(
              &pw, d + io2s[i], wuffs_base__make_slice_u8(d + off, lens[l])));
          mix((uint64_t)(pw - d));
          mix_bytes(d, 16);
          for (int u = 0; u < 3; u++) {
            memcpy(d, base, 16);
            const uint8_t* pr = d + iop;
            mix(wuffs_private_impl__io_reader__limited_copy_u32_to_slice(
                &pr, d + io2s[i], up_tos[u],
                wuffs_base__make_slice_u8(d + off, lens[l])));
            mix((uint64_t)(pr - d));
            mix_bytes(d, 16);

            memcpy(d, base, 16);
            pw = d + iop;
            mix(wuffs_private_impl__io_writer__limited_copy_u32_from_slice(
                &pw, d + io2s[i], up_tos[u],
                wuffs_base__make_slice_u8(d + off, lens[l])));
            mix((uint64_t)(pw - d));
            mix_bytes(d, 16);
          }
        }
      }
    }
  }

  // Reader to writer.
  for (size_t wp = 0; wp <= 9; wp += 3) {
    size_t w2s[2] = {wp + 5, 16};
    for (int i = 0; i < 2; i++) {
      for (size_t rp = 0; rp <= 10; rp += 2) {
        size_t r2s[2] = {rp + 4, 16};
        for (int j = 0; j < 2; j++) {
          for (int u = 0; u < 3; u++) {
            memcpy(d, base, 16);
            uint8_t* pw = d + wp;
            const uint8_t* pr = d + rp;
            mix(wuffs_private_impl__io_writer__limited_copy_u32_from_reader(
                &pw, d + w2s[i], up_tos[u], &pr, d + r2s[j]));
            mix((uint64_t)(pw - d));
            mix((uint64_t)(pr - d));
            mix_bytes(d, 16);
          }
        }
      }
    }
  }
  end("IO_Within");

  // bulk_load_host_endian and bulk_save_host_endian on u8 elements.
  begin(33);
  fill(base, 16);
  for (size_t ef = 0; ef <= 12; ef += 3) {      // element slice
    for (size_t el = 0; el <= 16 - ef; el += 2) {
      for (size_t bf = 0; bf <= 12; bf += 2) {  // byte slice
        for (size_t bl = 0; bl <= 16 - bf; bl += 3) {
          memcpy(d, base, 16);
          wuffs_private_impl__bulk_load_host_endian(
              d + ef, el, wuffs_base__make_slice_u8(d + bf, bl));
          mix_bytes(d, 16);
          memcpy(d, base, 16);
          wuffs_private_impl__bulk_save_host_endian(
              d + ef, el, wuffs_base__make_slice_u8(d + bf, bl));
          mix_bytes(d, 16);
        }
      }
    }
  }
  end("Slices_Bulk_U8_Within");
}

// History copies.  One 64 byte buffer; every combination of history length
// (the cursor), distance, requested length and writable limit, for each of
// the seven functions, restricted to the combinations that meet the
// function's documented preconditions.
static const size_t HIST[8] = {0, 1, 2, 3, 7, 8, 9, 20};
static const uint32_t DIST[9] = {0, 1, 2, 3, 7, 8, 9, 21, 1000};
static const uint32_t HLEN[12] = {0,  1,  2,  3,  7,   8,
                                  9,  16, 17, 30, 100, 0xFFFFFFFFu};

typedef uint32_t (*history_func)(uint8_t** ptr_iop_w,
                                 uint8_t* io0_w,
                                 uint8_t* io2_w,
                                 uint32_t length,
                                 uint32_t distance);

// kind: 0 = no preconditions, 1 = fast, 2 = 8 byte chunks (distance >= 8),
// 3 = 8 byte chunks distance 1.
static void sweep_history(const char* name,
                          uint64_t seed,
                          history_func f,
                          int kind) {
  begin(seed);
  uint8_t base[64], d[64];
  fill(base, 64);
  for (int h = 0; h < 8; h++) {
    size_t iop = HIST[h];
    size_t io2s[3] = {iop, iop + 5, 64};
    for (int i = 0; i < 3; i++) {
      size_t avail = io2s[i] - iop;
      for (int di = 0; di < 9; di++) {
        uint32_t dist = DIST[di];
        for (int li = 0; li < 12; li++) {
          uint32_t len = HLEN[li];
          if (kind != 0) {
            if ((len < 1) || (dist < 1) || (dist > iop)) {
              continue;
            } else if ((kind == 1) && (len > avail)) {
              continue;
            } else if ((kind >= 2) && (((uint64_t)len) + 8 > avail)) {
              continue;
            } else if ((kind == 2) && (dist < 8)) {
              continue;
            } else if ((kind == 3) && (dist != 1)) {
              continue;
            }
          }
          memcpy(d, base, 64);
          uint8_t* p = d + iop;
          mix((*f)(&p, d, d + io2s[i], len, dist));
          mix((uint64_t)(p - d));
          mix_bytes(d, 64);
        }
      }
    }
  }
  end(name);
}

static void sweep_io_history(void) {
  sweep_history("IO_History", 22,
                &wuffs_private_impl__io_writer__limited_copy_u32_from_history,
                0);
  sweep_history(
      "IO_History_Fast", 23,
      &wuffs_private_impl__io_writer__limited_copy_u32_from_history_fast, 1);
  sweep_history(
      "IO_History_Fast_Cusp", 24,
      &wuffs_private_impl__io_writer__limited_copy_u32_from_history_fast_return_cusp,
      1);
  sweep_history(
      "IO_History_Chunks", 25,
      &wuffs_private_impl__io_writer__limited_copy_u32_from_history_8_byte_chunks_fast,
      2);
  sweep_history(
      "IO_History_Chunks_Cusp", 26,
      &wuffs_private_impl__io_writer__limited_copy_u32_from_history_8_byte_chunks_fast_return_cusp,
      2);
  sweep_history(
      "IO_History_Chunks_D1", 27,
      &wuffs_private_impl__io_writer__limited_copy_u32_from_history_8_byte_chunks_distance_1_fast,
      3);
  sweep_history(
      "IO_History_Chunks_D1_Cusp", 28,
      &wuffs_private_impl__io_writer__limited_copy_u32_from_history_8_byte_chunks_distance_1_fast_return_cusp,
      3);
}

static void sweep_io_compact(void) {
  begin(29);
  uint8_t base[16], d[16];
  fill(base, 16);
  static const uint64_t poss[3] = {0, 5, 0xFFFFFFFFFFFFFFFEull};
  static const uint64_t retains[4] = {0, 1, 3, 100};
  for (size_t wi = 0; wi <= 16; wi += 2) {
    size_t ris[4] = {0, wi > 0 ? 1 : 0, wi / 2, wi};
    for (int r = 0; r < 4; r++) {
      for (int p = 0; p < 3; p++) {
        for (int closed = 0; closed < 2; closed++) {
          // retain index 4 means plain compact.
          for (int k = 0; k < 5; k++) {
            memcpy(d, base, 16);
            wuffs_base__io_buffer b = wuffs_base__make_io_buffer(
                wuffs_base__make_slice_u8(d, 16),
                wuffs_base__make_io_buffer_meta(wi, ris[r], poss[p],
                                                closed != 0));
            if (k < 4) {
              mix(wuffs_base__io_buffer__compact_retaining(&b, retains[k]));
            } else {
              mix(wuffs_base__io_buffer__compact(&b));
            }
            mix(b.meta.wi);
            mix(b.meta.ri);
            mix(b.meta.pos);
            mix(b.meta.closed ? 1 : 0);
            mix(wuffs_base__io_buffer__reader_length(&b));
            mix(wuffs_base__io_buffer__reader_position(&b));
            mix(wuffs_base__io_buffer__writer_length(&b));
            mix(wuffs_base__io_buffer__writer_position(&b));
            mix_bytes(d, 16);
          }
        }
      }
    }
  }
  end("IO_Compact");
}

// The slow path of io_reader.read_uNNxe?(), transcribed from the C that
// wuffs/internal/cgen/builtin.go (writeReadUxxAsUyy) emits; compare any
// "num_bits_0" loop in the release C file.  One byte per iteration, mixing
// the scratch word after every step and the result at the end.
static void sweep_io_read_steps(void) {
  begin(30);
  uint8_t buf[8];
  for (uint32_t xx = 16; xx <= 64; xx += 8) {
    for (int le = 0; le < 2; le++) {
      fill(buf, 8);
      const uint8_t* iop = buf;
      uint64_t scratch_storage = 0;
      uint64_t t = 0;
      while (true) {
        uint64_t* scratch = &scratch_storage;
        if (le) {
          uint32_t num_bits_0 = ((uint32_t)(*scratch >> 56));
          *scratch <<= 8;
          *scratch >>= 8;
          *scratch |= ((uint64_t)(*iop++)) << num_bits_0;
          if (num_bits_0 == (xx - 8)) {
            t = ((uint64_t)(*scratch));
            break;
          }
          num_bits_0 += 8u;
          *scratch |= ((uint64_t)(num_bits_0)) << 56;
        } else {
          uint32_t num_bits_0 = ((uint32_t)(*scratch & 0xFFu));
          *scratch >>= 8;
          *scratch <<= 8;
          *scratch |= ((uint64_t)(*iop++)) << (56 - num_bits_0);
          if (num_bits_0 == (xx - 8)) {
            t = ((uint64_t)(*scratch >> (64 - xx)));
            break;
          }
          num_bits_0 += 8u;
          *scratch |= ((uint64_t)(num_bits_0));
        }
        mix(*scratch);
      }
      mix(scratch_storage);
      mix(t);
      mix((uint64_t)(iop - buf));
    }
  }
  end("IO_Read_Steps");
}

int main(void) {
  sweep_ints_arith();
  sweep_ints_bits();
  sweep_ints_sign();
  sweep_endian_peek();
  sweep_endian_poke();
  sweep_ranges();
  sweep_rects();
  sweep_slices_prefix_suffix();
  sweep_slices_iterate();
  sweep_slices_copy();
  sweep_slices_copy_within();
  sweep_slices_memset();
  sweep_slices_bulk();
  sweep_io_count_limit();
  sweep_io_match7();
  sweep_io_copies();
  sweep_io_within();
  sweep_io_history();
  sweep_io_compact();
  sweep_io_read_steps();
  return 0;
}
