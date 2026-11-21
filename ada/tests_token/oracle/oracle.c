// Oracle for ada/tests_token: runs upstream Wuffs' own C (token-public.h,
// the utf8 submodule, and the expressions that wuffs/internal/cgen emits
// for token_writer methods and io_reader.valid_utf_8_length) over fixed
// input sweeps and prints one 64-bit digest per sweep.  The Ada tests run
// the same sweeps through Wuffs.Base.Tokens and Wuffs.Base.UTF8 and compare
// digests, so the expected values come from the C code being replaced, not
// from the Ada.
//
// Build and run via ./regen.sh, which writes ../token_oracle_data.ads.
//
// Each sweep here has a twin of the same name in ../test_*.adb.  The two
// must enumerate the same cases, draw random numbers and call mix() in the
// same order.

#define WUFFS_IMPLEMENTATION
#define WUFFS_CONFIG__MODULES
#define WUFFS_CONFIG__MODULE__BASE
#define WUFFS_CONFIG__MODULE__BASE__CORE
#define WUFFS_CONFIG__MODULE__BASE__UTF8

#include WUFFS_C_FILE

#include <inttypes.h>
#include <stdio.h>
#include <string.h>

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

static void end(const char* name) {
  printf("   %s : constant Wuffs.U64 := 16#%016" PRIX64 "#;\n", name, g_h);
}

// ---------------- Tokens

// The token that wuffs-c emits for write_simple_token_fast! and
// write_extended_token_fast! (internal/cgen/builtin.go,
// writeBuiltinTokenWriter), as a function of the arguments.
static uint64_t simple_token(uint32_t major,
                             uint32_t minor,
                             uint32_t cont,
                             uint32_t len) {
  return wuffs_base__make_token(
             (((uint64_t)(major)) << WUFFS_BASE__TOKEN__VALUE_MAJOR__SHIFT) |
             (((uint64_t)(minor)) << WUFFS_BASE__TOKEN__VALUE_MINOR__SHIFT) |
             (((uint64_t)(cont)) << WUFFS_BASE__TOKEN__CONTINUED__SHIFT) |
             (((uint64_t)(len)) << WUFFS_BASE__TOKEN__LENGTH__SHIFT))
      .repr;
}

static uint64_t extended_token(uint64_t ext, uint32_t cont, uint32_t len) {
  return wuffs_base__make_token(
             (~ext << WUFFS_BASE__TOKEN__VALUE_EXTENSION__SHIFT) |
             (((uint64_t)(cont)) << WUFFS_BASE__TOKEN__CONTINUED__SHIFT) |
             (((uint64_t)(len)) << WUFFS_BASE__TOKEN__LENGTH__SHIFT))
      .repr;
}

static void mix_fields(uint64_t repr) {
  wuffs_base__token t = wuffs_base__make_token(repr);
  mix((uint64_t)wuffs_base__token__value(&t));
  mix((uint64_t)wuffs_base__token__value_extension(&t));
  mix((uint64_t)wuffs_base__token__value_major(&t));
  mix((uint64_t)wuffs_base__token__value_base_category(&t));
  mix(wuffs_base__token__value_minor(&t));
  mix(wuffs_base__token__value_base_detail(&t));
  mix((uint64_t)wuffs_base__token__value_base_detail__sign_extended(&t));
  mix(wuffs_base__token__continued(&t) ? 1 : 0);
  mix(wuffs_base__token__length(&t));
}

// Every single bit, its complement, every pair of adjacent bits around the
// field boundaries, and random values.
static void sweep_token_fields(void) {
  begin(101);
  for (int k = 0; k < 64; k++) {
    mix_fields(1ull << k);
    mix_fields(~(1ull << k));
    mix_fields((1ull << k) - 1);
    mix_fields(~((1ull << k) - 1));
  }
  for (int i = 0; i < 200000; i++) {
    mix_fields(rnd());
  }
  end("Token_Fields");
}

// Edge values of each argument's range, and random ones.
static uint64_t pick(uint64_t max, int i) {
  switch (i % 8) {
    case 0:
      return 0;
    case 1:
      return 1;
    case 2:
      return max;
    case 3:
      return max - 1;
    case 4:
      return max / 2;
    case 5:
      return (max / 2) + 1;
  }
  return rnd() % (max + 1);
}

static void sweep_token_make(void) {
  begin(102);
  for (int a = 0; a < 16; a++) {
    for (int b = 0; b < 16; b++) {
      for (int c = 0; c < 2; c++) {
        for (int d = 0; d < 16; d++) {
          uint32_t major = (uint32_t)pick(0x1FFFFF, a);
          uint32_t minor = (uint32_t)pick(0x1FFFFFF, b);
          uint32_t len = (uint32_t)pick(0xFFFF, d);
          uint64_t ext = pick(0x3FFFFFFFFFFFull, a * 16 + b);
          uint64_t s = simple_token(major, minor, (uint32_t)c, len);
          uint64_t e = extended_token(ext, (uint32_t)c, len);
          mix(s);
          mix_fields(s);
          mix(e);
          mix_fields(e);
        }
      }
    }
  }
  for (int i = 0; i < 100000; i++) {
    uint32_t major = (uint32_t)(rnd() & 0x1FFFFF);
    uint32_t minor = (uint32_t)(rnd() & 0x1FFFFFF);
    uint32_t cont = (uint32_t)(rnd() & 1);
    uint32_t len = (uint32_t)(rnd() & 0xFFFF);
    uint64_t ext = rnd() & 0x3FFFFFFFFFFFull;
    mix(simple_token(major, minor, cont, len));
    mix(extended_token(ext, cont, len));
  }
  end("Token_Make");
}

// Token buffers: compact and compact_retaining, and the length and position
// helpers, on random buffers.
static wuffs_base__token g_toks[64];

static void sweep_token_buffer(void) {
  begin(103);
  for (int i = 0; i < 20000; i++) {
    size_t len = (size_t)(rnd() % 41);
    size_t wi = len ? (size_t)(rnd() % (len + 1)) : 0;
    size_t ri = (size_t)(rnd() % (wi + 1));
    uint64_t pos = (rnd() & 1) ? rnd() : (UINT64_MAX - (rnd() % 50));
    if (i % 4 == 0) {
      pos = rnd() % 1000;
    }
    for (size_t k = 0; k < len; k++) {
      g_toks[k].repr = rnd();
    }
    wuffs_base__token_buffer b = wuffs_base__make_token_buffer(
        wuffs_base__make_slice_token(g_toks, len),
        wuffs_base__make_token_buffer_meta(wi, ri, pos, (i & 2) != 0));
    mix(wuffs_base__token_buffer__is_valid(&b) ? 1 : 0);
    mix(wuffs_base__token_buffer__reader_length(&b));
    mix(wuffs_base__token_buffer__writer_length(&b));
    mix(wuffs_base__token_buffer__reader_token_position(&b));
    mix(wuffs_base__token_buffer__writer_token_position(&b));
    uint64_t h;
    switch (i % 6) {
      case 0:
        h = 0;
        break;
      case 1:
        h = 1;
        break;
      case 2:
        h = 2;
        break;
      case 3:
        h = UINT64_MAX;
        break;
      default:
        h = rnd() % 45;
    }
    size_t n = (i % 7 == 0) ? wuffs_base__token_buffer__compact(&b)
                            : wuffs_base__token_buffer__compact_retaining(&b, h);
    mix(n);
    mix(b.meta.wi);
    mix(b.meta.ri);
    mix(b.meta.pos);
    mix(b.meta.closed ? 1 : 0);
    for (size_t k = 0; k < len; k++) {
      mix(g_toks[k].repr);
    }
  }
  end("Token_Buffer");
}

// The token_writer cursor, as the code that wuffs-c emits uses it (var.go,
// writeInitialLoadDerivedVar and friends): iop and io2 from the meta at
// entry (io2 = iop if the buffer is closed), length() = io2 - iop, a write
// stores at iop and increments it, saving stores iop - data.ptr in meta.wi,
// and reloading (after a callee, which builds its own cursor from the meta
// and writes some tokens) sets iop = data.ptr + meta.wi.
static void sweep_token_cursor(void) {
  begin(104);
  for (int i = 0; i < 20000; i++) {
    size_t len = (size_t)(rnd() % 33);
    size_t wi = len ? (size_t)(rnd() % (len + 1)) : 0;
    size_t ri = (size_t)(rnd() % (wi + 1));
    wuffs_base__token_buffer_meta meta =
        wuffs_base__make_token_buffer_meta(wi, ri, rnd() % 100, (i % 9) == 0);
    for (size_t k = 0; k < len; k++) {
      g_toks[k].repr = 0;
    }
    wuffs_base__token* ptr = g_toks;
    wuffs_base__token* iop = ptr + meta.wi;
    wuffs_base__token* io2 = meta.closed ? iop : ptr + len;
    int steps = (int)(rnd() % 12);
    for (int s = 0; s < steps; s++) {
      uint64_t r = rnd();
      mix((uint64_t)(io2 - iop));
      switch (r % 5) {
        case 0:
        case 1:
          if (io2 - iop >= 1) {
            *iop++ = wuffs_base__make_token(
                simple_token((uint32_t)((r >> 8) & 0x1FFFFF),
                             (uint32_t)((r >> 29) & 0x1FFFFFF), (r >> 54) & 1,
                             (uint32_t)((r >> 3) & 0xFFFF)));
          }
          break;
        case 2:
          if (io2 - iop >= 1) {
            *iop++ = wuffs_base__make_token(extended_token(
                (r >> 8) & 0x3FFFFFFFFFFFull, (r >> 54) & 1, (r >> 3) & 0xFFFF));
          }
          break;
        case 3: {
          // A callee.
          meta.wi = (size_t)(iop - ptr);
          wuffs_base__token* c_iop = ptr + meta.wi;
          wuffs_base__token* c_io2 = meta.closed ? c_iop : ptr + len;
          int k = (int)((r >> 8) % 4);
          while (k-- > 0 && c_io2 - c_iop >= 1) {
            *c_iop++ = wuffs_base__make_token(
                simple_token(0, (uint32_t)((r >> 16) & 0xFFFF), 0, 1));
          }
          meta.wi = (size_t)(c_iop - ptr);
          iop = ptr + meta.wi;
          break;
        }
        case 4:
          // A suspension: the cursor is stored, then built again.
          meta.wi = (size_t)(iop - ptr);
          iop = ptr + meta.wi;
          io2 = meta.closed ? iop : ptr + len;
          break;
      }
    }
    meta.wi = (size_t)(iop - ptr);
    mix(meta.wi);
    mix(meta.ri);
    mix(meta.pos);
    for (size_t k = 0; k < len; k++) {
      mix(g_toks[k].repr);
    }
  }
  end("Token_Cursor");
}

// ---------------- UTF-8

static uint8_t g_buf[64];

static void mix_next(const uint8_t* p, size_t n) {
  wuffs_base__utf_8__next__output o = wuffs_base__utf_8__next(p, n);
  mix(o.code_point);
  mix(o.byte_length);
  o = wuffs_base__utf_8__next_from_end(p, n);
  mix(o.code_point);
  mix(o.byte_length);
  mix(wuffs_base__utf_8__longest_valid_prefix(p, n));
  mix(wuffs_base__ascii__longest_valid_prefix(p, n));
}

// Every sequence of one, two and three bytes; for four bytes, every first
// and second byte with the third and fourth from a set of edge values.  Each
// sequence on its own, cut short by one byte, and followed by a byte (an
// ASCII one and a tail byte).
static const uint8_t g_edges[10] = {0x00, 0x7F, 0x80, 0x8F, 0x90,
                                    0x9F, 0xA0, 0xBF, 0xC0, 0xFF};

static void mix_sequence(size_t n) {
  mix_next(g_buf, n);
  mix_next(g_buf, n - 1);
  g_buf[n] = 'x';
  mix_next(g_buf, n + 1);
  g_buf[n] = 0x80;
  mix_next(g_buf, n + 1);
}

static void sweep_utf8_short(void) {
  begin(201);
  mix_next(g_buf, 0);
  for (int a = 0; a < 256; a++) {
    g_buf[0] = (uint8_t)a;
    mix_sequence(1);
    for (int b = 0; b < 256; b++) {
      g_buf[0] = (uint8_t)a;
      g_buf[1] = (uint8_t)b;
      mix_sequence(2);
    }
  }
  end("UTF8_Short");
}

static void sweep_utf8_three(void) {
  begin(202);
  for (int a = 0; a < 256; a++) {
    for (int b = 0; b < 256; b++) {
      for (int c = 0; c < 256; c++) {
        g_buf[0] = (uint8_t)a;
        g_buf[1] = (uint8_t)b;
        g_buf[2] = (uint8_t)c;
        mix_sequence(3);
      }
    }
  }
  end("UTF8_Three");
}

static void sweep_utf8_four(void) {
  begin(203);
  for (int a = 0; a < 256; a++) {
    for (int b = 0; b < 256; b++) {
      for (int c = 0; c < 10; c++) {
        for (int d = 0; d < 10; d++) {
          g_buf[0] = (uint8_t)a;
          g_buf[1] = (uint8_t)b;
          g_buf[2] = g_edges[c];
          g_buf[3] = g_edges[d];
          mix_sequence(4);
        }
      }
    }
  }
  end("UTF8_Four");
}

// Random strings, mostly of valid sequences with some ASCII and some
// invalid bytes, of every length up to 64.
static void sweep_utf8_strings(void) {
  begin(204);
  for (int i = 0; i < 200000; i++) {
    size_t n = (size_t)(rnd() % 65);
    size_t k = 0;
    while (k < n) {
      uint64_t r = rnd();
      switch (r % 4) {
        case 0:
          g_buf[k++] = (uint8_t)((r >> 8) & 0x7F);
          break;
        case 1:
          g_buf[k++] = (uint8_t)(r >> 8);
          break;
        default: {
          uint8_t enc[4];
          uint32_t cp = (uint32_t)((r >> 8) % 0x110000);
          size_t m = wuffs_base__utf_8__encode(wuffs_base__make_slice_u8(enc, 4), cp);
          for (size_t j = 0; j < m && k < n; j++) {
            g_buf[k++] = enc[j];
          }
        }
      }
    }
    mix_next(g_buf, n);
    if (n > 0) {
      mix_next(g_buf + 1, n - 1);
    }
  }
  end("UTF8_Strings");
}

// Every code point up to 0x10FFFF and some beyond, into destinations of 0
// to 5 bytes (filled with 0xAA before).
static void sweep_utf8_encode(void) {
  begin(205);
  for (uint32_t cp = 0; cp < 0x110100; cp++) {
    for (size_t n = 0; n <= 5; n++) {
      uint8_t dst[5] = {0xAA, 0xAA, 0xAA, 0xAA, 0xAA};
      size_t m = wuffs_base__utf_8__encode(wuffs_base__make_slice_u8(dst, n), cp);
      mix(m);
      for (int j = 0; j < 5; j++) {
        mix(dst[j]);
      }
    }
  }
  for (int i = 0; i < 100000; i++) {
    uint32_t cp = (uint32_t)rnd();
    uint8_t dst[5] = {0xAA, 0xAA, 0xAA, 0xAA, 0xAA};
    size_t m = wuffs_base__utf_8__encode(wuffs_base__make_slice_u8(dst, 4), cp);
    mix(m);
    for (int j = 0; j < 5; j++) {
      mix(dst[j]);
    }
  }
  end("UTF8_Encode");
}

// io_reader.valid_utf_8_length(up_to): the expression that wuffs-c emits
// (internal/cgen/builtin.go, writeBuiltinIOReader), for random readers
// (iop, io2 within a buffer) and up_to values.
static void sweep_valid_utf_8_length(void) {
  begin(206);
  for (int i = 0; i < 100000; i++) {
    for (int k = 0; k < 64; k++) {
      uint64_t r = rnd();
      g_buf[k] = (r & 1) ? (uint8_t)((r >> 8) & 0x7F) : (uint8_t)(r >> 8);
    }
    size_t io2 = (size_t)(rnd() % 65);
    size_t iop = (size_t)(rnd() % (io2 + 1));
    uint64_t up_to;
    switch (i % 4) {
      case 0:
        up_to = 0;
        break;
      case 1:
        up_to = UINT64_MAX;
        break;
      default:
        up_to = rnd() % 70;
    }
    const uint8_t* p_iop = g_buf + iop;
    const uint8_t* p_io2 = g_buf + io2;
    mix((uint64_t)(wuffs_base__utf_8__longest_valid_prefix(
        p_iop,
        ((size_t)(wuffs_base__u64__min(((uint64_t)(p_io2 - p_iop)), up_to))))));
  }
  end("Valid_UTF_8_Length");
}

int main(void) {
  sweep_token_fields();
  sweep_token_make();
  sweep_token_buffer();
  sweep_token_cursor();
  sweep_utf8_short();
  sweep_utf8_three();
  sweep_utf8_four();
  sweep_utf8_strings();
  sweep_utf8_encode();
  sweep_valid_utf_8_length();
  return 0;
}
