// Oracle for ada/tests_ycck: runs upstream Wuffs' own C
// wuffs_base__pixel_swizzler__swizzle_ycck (and the YCbCr colour functions)
// over fixed input sweeps and prints 64-bit digests, as Ada constants.  The
// Ada tests run the same sweeps through Wuffs.Base.Pixel_Swizzler_YCCK and
// Wuffs.Base.Color_YCC and compare.
//
// Build and run via ./regen.sh, which writes ../ycck_oracle_data.ads.
//
// Each sweep here has a twin of the same name in ../test_ycck.adb.  The two
// must enumerate the same cases, draw random numbers and call mix() in the
// same order.
//
// Every source plane, the destination and the scratch buffer are malloc'ed
// at exactly the length passed, so that ASan sees any access outside them.
//
// WUFFS_CONFIG__AVOID_CPU_ARCH (given by regen.sh) selects the scalar
// code.  regen.sh also builds this file without it and compares.

#define WUFFS_IMPLEMENTATION
#define WUFFS_CONFIG__MODULES
#define WUFFS_CONFIG__MODULE__BASE
#define WUFFS_CONFIG__MODULE__BASE__CORE
#define WUFFS_CONFIG__MODULE__BASE__PIXCONV

#include WUFFS_C_FILE

#include <inttypes.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static uint64_t g_h;
static uint64_t g_rng;
static uint64_t g_marks[4096];
static size_t g_num_marks;

static void begin(uint64_t seed) {
  g_h = 0xCBF29CE484222325ull;
  g_rng = seed;
  g_num_marks = 0;
}

static void mark(void) {
  if (g_num_marks >= (sizeof(g_marks) / sizeof(g_marks[0]))) {
    fprintf(stderr, "too many marks\n");
    exit(1);
  }
  g_marks[g_num_marks++] = g_h;
}

static void mix(uint64_t v) {
  g_h = (g_h ^ v) * 0x100000001B3ull;
}

static uint64_t rnd(void) {
  g_rng = (g_rng * 6364136223846793005ull) + 1442695040888963407ull;
  return g_rng ^ (g_rng >> 31);
}

// A random number in 0 .. n - 1.
static uint32_t pick(uint32_t n) {
  return (uint32_t)((rnd() >> 33) % n);
}

// Sample data.  Mode 0: random; 1: all 0; 2: all 255; 3: all 128; 4: each
// 0 or 255.  One rnd() per byte whatever the mode.
static void fill(uint8_t* p, size_t n, uint32_t mode) {
  for (size_t i = 0; i < n; i++) {
    uint8_t r = (uint8_t)(rnd() >> 56);
    p[i] = (mode == 0)   ? r
           : (mode == 1) ? 0
           : (mode == 2) ? 255
           : (mode == 3) ? 128
                         : ((r & 1) ? 255 : 0);
  }
}

static void mix_bytes(const uint8_t* p, size_t n) {
  for (size_t i = 0; i < n; i++) {
    mix(p[i]);
  }
}

static void end(const char* name) {
  printf("   %s : constant Wuffs.U64 := 16#%016" PRIX64 "#;\n", name, g_h);
  if (g_num_marks > 0) {
    printf("   %s_Marks : constant Mark_Array (0 .. %zu) :=\n     [", name,
           g_num_marks - 1);
    for (size_t i = 0; i < g_num_marks; i++) {
      printf("%s16#%016" PRIX64 "#",
             (i == 0) ? "" : ((i % 4) ? ", " : ",\n      "), g_marks[i]);
    }
    printf("];\n");
  }
}

static void count(const char* name, uint64_t n) {
  printf("   %s : constant := %" PRIu64 ";\n", name, n);
}

// Status as a small number.
static uint32_t status_code(wuffs_base__status s) {
  if (s.repr == NULL) {
    return 0;
  } else if (s.repr == wuffs_base__error__bad_argument) {
    return 1;
  } else if (s.repr == wuffs_base__error__unsupported_pixel_swizzler_option) {
    return 2;
  }
  return 3;
}

// The 34 named pixel formats (the order of ada/tests_pixel's oracle); the
// last is the invalid format 0.
static const uint32_t FORMATS[34] = {
    0x02000008, 0x20000008, 0x2000000B, 0x2010000B, 0x21000088, 0x22000088,
    0x30008888, 0x81040008, 0x82040008, 0x83040008, 0x80000565, 0x80000888,
    0x81008888, 0x8100BBBB, 0x82008888, 0x8200BBBB, 0x83008888, 0x90008888,
    0xA0000888, 0xA1008888, 0xA100BBBB, 0xA2008888, 0xA200BBBB, 0xA3008888,
    0xB0008888, 0x40020888, 0x41038888, 0x50038888, 0x60020888, 0x61038888,
    0x70038888, 0xC0020888, 0xD0038888, 0x00000000};

// The 17 destination formats that swizzle_ycck accepts.
static const uint32_t ACCEPTED[17] = {
    0x81008888, 0x90008888, 0xA0000888, 0x80000888, 0x80000565, 0x20000008,
    0x2000000B, 0x2010000B, 0x21000088, 0x81040008, 0x82040008, 0x83040008,
    0x82008888, 0x8100BBBB, 0xA1008888, 0xA2008888, 0xB0008888};

// Bytes per destination pixel as the tests lay the buffer out: the
// format's own for the accepted formats, 8 for the others.
static uint32_t test_bpp(uint32_t fmt) {
  for (int i = 0; i < 17; i++) {
    if (ACCEPTED[i] == fmt) {
      wuffs_base__pixel_format f = wuffs_base__make_pixel_format(fmt);
      return wuffs_base__pixel_format__bits_per_pixel(&f) / 8;
    }
  }
  return 8;
}

typedef struct {
  uint32_t fmt;
  uint32_t dw, dh, dpad;  // destination size in pixels; row padding in bytes
  uint32_t doff;          // bytes before the destination's first pixel
  uint32_t dmode;         // of the destination's initial contents
  uint32_t x0, x1, y0, y1;
  uint32_t w[4], h[4], s[4];
  uint32_t hh[4], vv[4];
  size_t len[4];
  uint32_t model, ups;
  size_t scratch_len;
  uint32_t mode;  // of the samples (see fill)
  uint32_t nopal;  // an indexed destination gets no palette plane
} call_t;

static uint8_t g_palette[1024];
static uint64_t g_status_counts[4];
static uint64_t g_calls;
static uint64_t g_pixels;

static size_t flat(uint32_t w, uint32_t h, uint32_t s) {
  return (h == 0) ? 0 : (((size_t)(h - 1) * s) + w);
}

// Makes the call: the destination is dst (c->dh rows of c->dw pixels plus
// c->dpad bytes, after c->doff unused bytes), the planes are src[0 .. 3] (c->len[k] bytes each) and the
// scratch buffer is scratch (c->scratch_len bytes).  Returns the status code.
static uint32_t call(const call_t* c,
                     uint8_t* const* src,
                     uint8_t* dst,
                     uint8_t* scratch) {
  uint32_t bpp = test_bpp(c->fmt);
  size_t dstride = ((size_t)c->dw * bpp) + c->dpad;
  wuffs_base__pixel_buffer pb;
  memset(&pb, 0, sizeof(pb));
  pb.pixcfg.private_impl.pixfmt.repr = c->fmt;
  pb.pixcfg.private_impl.width = c->dw;
  pb.pixcfg.private_impl.height = c->dh;
  pb.private_impl.planes[0].ptr = dst + c->doff;
  pb.private_impl.planes[0].width = c->dw * bpp;
  pb.private_impl.planes[0].height = c->dh;
  pb.private_impl.planes[0].stride = dstride;
  wuffs_base__pixel_format f = wuffs_base__make_pixel_format(c->fmt);
  if (wuffs_base__pixel_format__is_indexed(&f) && !c->nopal) {
    pb.private_impl.planes[3].ptr = g_palette;
    pb.private_impl.planes[3].width = 1024;
    pb.private_impl.planes[3].height = 1;
    pb.private_impl.planes[3].stride = 1024;
  }

  wuffs_base__pixel_swizzler swizzler;
  memset(&swizzler, 0, sizeof(swizzler));
  wuffs_base__status status = wuffs_base__pixel_swizzler__swizzle_ycck(
      &swizzler, &pb, wuffs_base__make_slice_u8(g_palette, 1024),  //
      c->x0, c->x1, c->y0, c->y1,                                  //
      wuffs_base__make_slice_u8(src[0], c->len[0]),
      wuffs_base__make_slice_u8(src[1], c->len[1]),
      wuffs_base__make_slice_u8(src[2], c->len[2]),
      wuffs_base__make_slice_u8(src[3], c->len[3]),  //
      c->w[0], c->w[1], c->w[2], c->w[3],            //
      c->h[0], c->h[1], c->h[2], c->h[3],            //
      c->s[0], c->s[1], c->s[2], c->s[3],            //
      (uint8_t)c->hh[0], (uint8_t)c->hh[1], (uint8_t)c->hh[2],
      (uint8_t)c->hh[3],  //
      (uint8_t)c->vv[0], (uint8_t)c->vv[1], (uint8_t)c->vv[2],
      (uint8_t)c->vv[3],  //
      (uint8_t)c->model, (uint8_t)c->ups,
      wuffs_base__make_slice_u8(scratch, c->scratch_len));
  uint32_t code = status_code(status);
  g_status_counts[code]++;
  g_calls++;
  if (code == 0) {
    g_pixels += (uint64_t)c->dw * c->dh;
  }
  return code;
}

static size_t dst_len(const call_t* c) {
  return c->doff + ((((size_t)c->dw * test_bpp(c->fmt)) + c->dpad) * c->dh);
}

// Makes the call on fresh random planes, destination and scratch buffer
// and mixes the status, the whole destination and the whole scratch buffer
// (which upstream's C leaves holding the last chunks' upsampled samples).
static void run(const call_t* c) {
  size_t dlen = dst_len(c);
  uint8_t* src[4];
  for (int k = 0; k < 4; k++) {
    src[k] = (uint8_t*)malloc(c->len[k] ? c->len[k] : 1);
    fill(src[k], c->len[k], c->mode);
  }
  uint8_t* dst = (uint8_t*)malloc(dlen ? dlen : 1);
  fill(dst, dlen, c->dmode);
  uint8_t* scratch = (uint8_t*)malloc(c->scratch_len ? c->scratch_len : 1);
  fill(scratch, c->scratch_len, 0);
  mix(call(c, src, dst, scratch));
  mix_bytes(dst, dlen);
  mix_bytes(scratch, c->scratch_len);
  for (int k = 0; k < 4; k++) {
    free(src[k]);
  }
  free(dst);
  free(scratch);
}

static uint32_t gcd(uint32_t a, uint32_t b) {
  while (b != 0) {
    uint32_t t = a % b;
    a = b;
    b = t;
  }
  return a;
}

// Fills in a call that is valid whenever the sampling factors are: the
// rectangle is (x0n, y0n) steps of the coarsest plane's sample size from the
// origin and dx by dy pixels large; every plane is just large enough (plus
// extra_w, extra_h whole coarsest samples); strides are widths plus spad;
// the destination's rows have spad bytes between them and 5 * spad bytes
// in front.
// The destination is ddw by ddh pixels larger (or, if negative, smaller)
// than the rectangle's far corner.
static void make(call_t* c,
                 const uint32_t* hv,  // h0 v0 h1 v1 h2 v2 h3 v3
                 uint32_t dx,
                 uint32_t dy,
                 uint32_t x0n,
                 uint32_t y0n,
                 uint32_t extra_w,
                 uint32_t extra_h,
                 uint32_t spad,
                 int32_t ddw,
                 int32_t ddh) {
  uint32_t max_h = 1;
  uint32_t max_v = 1;
  for (int k = 0; k < 4; k++) {
    c->hh[k] = hv[2 * k];
    c->vv[k] = hv[(2 * k) + 1];
    if (max_h < c->hh[k]) {
      max_h = c->hh[k];
    }
    if (max_v < c->vv[k]) {
      max_v = c->vv[k];
    }
  }
  uint32_t inv_h[4];
  uint32_t inv_v[4];
  uint32_t lh = 1;
  uint32_t lv = 1;
  for (int k = 0; k < 4; k++) {
    inv_h[k] = (c->hh[k] == 0) ? 1 : (max_h / c->hh[k]);
    inv_v[k] = (c->vv[k] == 0) ? 1 : (max_v / c->vv[k]);
    lh = (lh * inv_h[k]) / gcd(lh, inv_h[k]);
    lv = (lv * inv_v[k]) / gcd(lv, inv_v[k]);
  }
  uint32_t ew = lh * (((dx + lh - 1) / lh) + extra_w);
  uint32_t eh = lv * (((dy + lv - 1) / lv) + extra_h);
  for (int k = 0; k < 4; k++) {
    c->w[k] = ew / inv_h[k];
    c->h[k] = eh / inv_v[k];
    c->s[k] = c->w[k] + spad;
    c->len[k] = flat(c->w[k], c->h[k], c->s[k]);
  }
  if ((c->hh[3] == 0) && (c->vv[3] == 0)) {
    c->w[3] = 0;
    c->h[3] = 0;
    c->s[3] = 0;
    c->len[3] = 0;
  }
  c->x0 = x0n * lh;
  c->y0 = y0n * lv;
  c->x1 = c->x0 + dx;
  c->y1 = c->y0 + dy;
  int32_t dw = (int32_t)c->x1 + ddw;
  int32_t dh = (int32_t)c->y1 + ddh;
  c->dw = (dw < 0) ? 0 : (uint32_t)dw;
  c->dh = (dh < 0) ? 0 : (uint32_t)dh;
  c->dpad = spad;
  c->doff = spad * 5;
  c->dmode = 0;
  c->nopal = 0;
  c->scratch_len = 2048;
  c->mode = 0;
  c->fmt = 0x81008888;
  c->model = 0;
  c->ups = 0;
}

static void reset_counts(void) {
  memset(g_status_counts, 0, sizeof(g_status_counts));
  g_calls = 0;
  g_pixels = 0;
}

static void counts(const char* name) {
  char buf[96];
  snprintf(buf, sizeof(buf), "%s_Calls", name);
  count(buf, g_calls);
  snprintf(buf, sizeof(buf), "%s_Ok", name);
  count(buf, g_status_counts[0]);
  snprintf(buf, sizeof(buf), "%s_Bad_Argument", name);
  count(buf, g_status_counts[1]);
  snprintf(buf, sizeof(buf), "%s_Unsupported", name);
  count(buf, g_status_counts[2]);
  snprintf(buf, sizeof(buf), "%s_Other", name);
  count(buf, g_status_counts[3]);
  snprintf(buf, sizeof(buf), "%s_Pixels", name);
  count(buf, g_pixels);
}

// ---- The colour functions, exhaustively over (Y, Cb, Cr).

static void sweep_colors(void) {
  begin(1);
  for (uint32_t y = 0; y < 256; y++) {
    for (uint32_t cb = 0; cb < 256; cb++) {
      for (uint32_t cr = 0; cr < 256; cr++) {
        mix(wuffs_base__color_ycc_bt601fr__as__color_u32((uint8_t)y, (uint8_t)cb,
                                                         (uint8_t)cr));
        mix(wuffs_base__color_ycc_bt601fr__as__color_u32_abgr(
            (uint8_t)y, (uint8_t)cb, (uint8_t)cr));
        mix(wuffs_base__color_ycc_bt601sr__as__color_u32((uint8_t)y, (uint8_t)cb,
                                                         (uint8_t)cr));
        mix(wuffs_base__color_ycc_bt601sr__as__color_u32_abgr(
            (uint8_t)y, (uint8_t)cb, (uint8_t)cr));
      }
    }
    if ((y % 16) == 15) {
      mark();
    }
  }
  end("YCC_Colors");
}

// ---- Every destination format, with every kind of YCC model, three and
// four planes, plain and fancy upsampling.  One mark per format.

static const uint32_t MODELS[8] = {0x00, 0x04, 0x06, 0x07,
                                   0x40, 0x80, 0x01, 0xFF};
static const uint32_t HV_420_3[8] = {2, 2, 1, 1, 1, 1, 0, 0};
static const uint32_t HV_420_4[8] = {2, 2, 1, 1, 1, 1, 2, 2};

static void sweep_formats(void) {
  begin(2);
  reset_counts();
  fill(g_palette, 1024, 0);
  for (int f = 0; f < 34; f++) {
    for (int m = 0; m < 8; m++) {
      for (int four = 0; four < 2; four++) {
        for (uint32_t ups = 0; ups < 3; ups++) {
          // Random samples over a random destination; all zero samples
          // (so a transparent fourth plane) over an all zero destination;
          // all 255 over random; random over random with, for an
          // indexed destination, no palette plane in the pixel buffer.
          for (uint32_t sm = 0; sm < 4; sm++) {
            call_t c;
            make(&c, four ? HV_420_4 : HV_420_3, 9, 7, 0, 0, 0, 0,
                 (uint32_t)(f % 3), 0, 0);
            c.fmt = FORMATS[f];
            c.model = MODELS[m];
            c.ups = ups;
            c.mode = sm % 3;
            c.dmode = (sm == 1) ? 1 : 0;
            c.nopal = sm == 3;
            run(&c);
          }
        }
      }
    }
    mark();
  }
  end("YCCK_Formats");
  counts("YCCK_Formats");
}

// ---- Every combination of sampling factors of the first three planes
// (4 ** 6), for each upsampling option; the fourth plane, the sizes, the
// format, the model, the origin, the clipping and the sample data are
// drawn at random.  One mark per (ups, h0, v0).

static const uint32_t SIZES[11] = {0, 1, 2, 3, 7, 8, 9, 15, 16, 17, 33};
static const uint32_t MODELS_3[3] = {0x00, 0x04, 0x40};
static const uint32_t MODELS_4[4] = {0x00, 0x06, 0x07, 0x80};

static void sweep_sampling(void) {
  begin(3);
  reset_counts();
  fill(g_palette, 1024, 0);
  uint32_t hv[8];
  for (uint32_t ups = 0; ups < 3; ups++) {
    for (hv[0] = 1; hv[0] <= 4; hv[0]++) {
      for (hv[1] = 1; hv[1] <= 4; hv[1]++) {
        for (hv[2] = 1; hv[2] <= 4; hv[2]++) {
          for (hv[3] = 1; hv[3] <= 4; hv[3]++) {
            for (hv[4] = 1; hv[4] <= 4; hv[4]++) {
              for (hv[5] = 1; hv[5] <= 4; hv[5]++) {
                uint32_t four = pick(8);
                if (four < 3) {
                  hv[6] = 1 + pick(4);
                  hv[7] = 1 + pick(4);
                } else if (four == 3) {
                  hv[6] = pick(5);
                  hv[7] = pick(5);
                } else {
                  hv[6] = 0;
                  hv[7] = 0;
                }
                uint32_t dx = SIZES[pick(11)];
                uint32_t dy = SIZES[pick(11)];
                uint32_t x0n = 0;
                uint32_t y0n = 0;
                if ((ups == 0) && (pick(3) == 0)) {
                  x0n = pick(3);
                  y0n = pick(3);
                }
                uint32_t extra_w = pick(2);
                uint32_t extra_h = pick(2);
                uint32_t spad = pick(3);
                int32_t ddw = (int32_t)pick(3) - 1;
                int32_t ddh = (int32_t)pick(3) - 1;
                call_t c;
                make(&c, hv, dx, dy, x0n, y0n, extra_w, extra_h, spad, ddw,
                     ddh);
                c.fmt = ACCEPTED[pick(17)];
                c.model = ((hv[6] | hv[7]) != 0) ? MODELS_4[pick(4)]
                                                 : MODELS_3[pick(3)];
                c.ups = ups;
                c.mode = pick(5);
                run(&c);
              }
            }
          }
        }
        mark();
      }
    }
  }
  end("YCCK_Sampling");
  counts("YCCK_Sampling");
}

// ---- Common sampling layouts at every size in the list, including
// widths around every multiple of C's chunk sizes (672 pixels, 480 with
// four planes) up to 2016 and 1920, so that every upsample function meets
// every kind of chunk boundary.
// One mark per (layout, ups).

static const uint32_t LAYOUTS[14][8] = {
    {1, 1, 1, 1, 1, 1, 0, 0},  // 4:4:4
    {2, 1, 1, 1, 1, 1, 0, 0},  // 4:2:2
    {1, 2, 1, 1, 1, 1, 0, 0},  // 4:4:0
    {2, 2, 1, 1, 1, 1, 0, 0},  // 4:2:0
    {4, 1, 1, 1, 1, 1, 0, 0},  // 4:1:1
    {4, 2, 1, 1, 1, 1, 0, 0},  // 4:1:0
    {1, 1, 2, 2, 2, 2, 0, 0},  // luma at half resolution
    {2, 2, 2, 1, 1, 2, 0, 0},  // mixed
    {3, 3, 1, 1, 3, 1, 0, 0},  // thirds
    {1, 1, 1, 1, 1, 1, 1, 1},  // four planes, 4:4:4:4
    {2, 2, 1, 1, 1, 1, 2, 2},  // four planes, chroma halved
    {2, 2, 1, 2, 2, 1, 1, 1},  // four planes, mixed, fourth halved
    {4, 1, 1, 1, 2, 1, 4, 1},  // four planes, a quarter and a half
    {3, 1, 1, 1, 3, 1, 1, 1},  // four planes, thirds
};
#define NUM_WIDTHS 32
static const uint32_t WIDTHS[NUM_WIDTHS] = {
    0,    1,    2,    3,    7,    8,    9,    15,   16,   17,   33,
    479,  480,  481,  671,  672,  673,  959,  960,  961,  1343, 1344,
    1345, 1439, 1440, 1441, 1919, 1920, 1921, 2015, 2016, 2017};
static const uint32_t TALL[4] = {1, 2, 3, 9};

static void sweep_sizes(void) {
  begin(4);
  reset_counts();
  fill(g_palette, 1024, 0);
  uint32_t n = 0;
  for (int l = 0; l < 14; l++) {
    for (uint32_t ups = 0; ups < 3; ups++) {
      for (int wi = 0; wi < NUM_WIDTHS; wi++) {
        int num_h = (wi < 11) ? 11 : 4;
        for (int hi = 0; hi < num_h; hi++) {
          uint32_t dy = (wi < 11) ? SIZES[hi] : TALL[hi];
          call_t c;
          // Every seventh call clips the rectangle's right column and bottom
          // row off.
          int32_t clip = ((n % 7) == 3) ? -1 : 0;
          make(&c, LAYOUTS[l], WIDTHS[wi], dy, 0, 0, 0, 0, n % 2, clip, clip);
          c.fmt = ACCEPTED[n % 17];
          c.model = (LAYOUTS[l][6] != 0) ? MODELS_4[n % 4] : MODELS_3[n % 3];
          c.ups = ups;
          c.mode = n % 5;
          run(&c);
          n++;
        }
      }
      mark();
    }
  }
  end("YCCK_Sizes");
  counts("YCCK_Sizes");
}

// ---- One large image per upsampling option (three and four planes).

static void sweep_large(void) {
  begin(5);
  reset_counts();
  for (uint32_t ups = 0; ups < 3; ups++) {
    for (int four = 0; four < 2; four++) {
      call_t c;
      make(&c, four ? HV_420_4 : HV_420_3, 1501, 1203, 0, 0, 0, 0, 3, 0, 0);
      c.fmt = four ? 0x81008888 : 0x90008888;
      c.model = four ? 0x07 : 0x00;
      c.ups = ups;
      run(&c);
      mark();
    }
  }
  end("YCCK_Large");
  counts("YCCK_Large");
}

// ---- Argument checking: a valid call with one thing changed.  One mark
// per kind of change.

#define NUM_CHANGES 46

static void change(call_t* c, uint32_t kind, uint32_t k) {
  // k is a plane number, 0 .. 3; planes 0 .. 2 where 3 would not matter.
  uint32_t k3 = k % 3;
  switch (kind) {
    case 0:
      break;
    case 1:
      c->x1 = 0x10000;
      break;
    case 2:
      c->y1 = 0x10000;
      break;
    case 3:
      c->x1 = 0xFFFFFFFFu;
      break;
    case 4:
      c->w[k] = 0x10001;
      break;
    case 5:
      c->h[k] = 0x10001;
      break;
    case 6:
      if (c->len[k] > 0) {
        c->len[k]--;
      }
      break;
    case 7:
      c->len[k] = 0;
      break;
    case 8:
      c->len[k]++;
      break;
    case 9:
      c->hh[k3] = 0;
      break;
    case 10:
      c->hh[k3] = 5;
      break;
    case 11:
      c->vv[k3] = 0;
      break;
    case 12:
      c->vv[k3] = 5;
      break;
    case 13:
      c->hh[k3] = 255;
      break;
    case 14:
      c->hh[3] = 0;
      break;
    case 15:
      c->vv[3] = 0;
      break;
    case 16:
      c->hh[3] = 5;
      break;
    case 17:
      c->vv[3] = 5;
      break;
    case 18:
      c->x0 += 1;
      break;
    case 19:
      c->y0 += 1;
      break;
    case 20:
      c->x0 += 12;
      c->x1 += 12;
      break;
    case 21:
      c->scratch_len = 2047;
      break;
    case 22:
      c->scratch_len = 0;
      break;
    case 23:
      c->scratch_len = 2049;
      break;
    case 24:
      c->w[k]++;
      break;
    case 25:
      if (c->w[k] > 0) {
        c->w[k]--;
      }
      break;
    case 26:
      c->h[k]++;
      break;
    case 27:
      if (c->h[k] > 0) {
        c->h[k]--;
      }
      break;
    case 28:
      // The fourth plane at full resolution and exactly the rectangle's
      // size, whatever the other planes' expanded size.  (Not if an
      // earlier change made the rectangle absurdly large.)
      if (((c->x1 - c->x0) > 0x10000) || ((c->y1 - c->y0) > 0x10000)) {
        break;
      }
      c->hh[3] = 4;
      c->vv[3] = 4;
      c->w[3] = c->x1 - c->x0;
      c->h[3] = c->y1 - c->y0;
      c->s[3] = c->w[3];
      c->len[3] = flat(c->w[3], c->h[3], c->s[3]);
      break;
    case 29:
      c->x1 = c->x0;
      break;
    case 30:
      c->y1 = c->y0;
      break;
    case 31:
      c->x0 = c->x1 + 1;
      break;
    case 32:
      c->dw = 0;
      break;
    case 33:
      c->dh = 0;
      break;
    case 34:
      c->dw = c->dw / 2;
      break;
    case 35:
      c->dh = c->dh / 2;
      break;
    case 36:
      c->model = pick(256);
      break;
    case 37:
      c->ups = 3 + pick(253);
      break;
    case 38:
      // A stride smaller than the width: rows overlap.
      c->s[k] = c->w[k] / 2;
      c->len[k] = flat(c->w[k], c->h[k], c->s[k]);
      break;
    case 39:
      c->s[k] = 0;
      c->len[k] = flat(c->w[k], c->h[k], c->s[k]);
      break;
    case 40:
      c->fmt = FORMATS[pick(34)];
      break;
    case 41:
      c->x1 = 0xFFFF;
      break;
    case 42:
      c->y1 = 0xFFFF;
      break;
    case 43:
      c->y0 += 12;
      c->y1 += 12;
      break;
    case 44:
      c->fmt = 0x40020888;  // planar
      break;
    case 45:
      c->fmt = 0x8200BBBB;  // not planar, not supported
      break;
  }
}

static void sweep_errors(void) {
  begin(6);
  reset_counts();
  fill(g_palette, 1024, 0);
  for (uint32_t kind = 0; kind < NUM_CHANGES; kind++) {
    for (int i = 0; i < 400; i++) {
      uint32_t hv[8];
      for (int j = 0; j < 6; j++) {
        hv[j] = 1 + pick(2) + (pick(4) == 0 ? 2 * pick(2) : 0);
      }
      if (pick(2) == 0) {
        hv[6] = 1 + pick(2);
        hv[7] = 1 + pick(2);
      } else {
        hv[6] = 0;
        hv[7] = 0;
      }
      uint32_t ups = pick(3);
      uint32_t dx = SIZES[pick(11)];
      uint32_t dy = SIZES[pick(11)];
      uint32_t x0n = (ups == 0) ? pick(2) : 0;
      uint32_t y0n = (ups == 0) ? pick(2) : 0;
      call_t c;
      make(&c, hv, dx, dy, x0n, y0n, 0, 0, pick(2), 0, 0);
      c.fmt = ACCEPTED[pick(17)];
      c.model =
          ((hv[6] | hv[7]) != 0) ? MODELS_4[pick(4)] : MODELS_3[pick(3)];
      c.ups = ups;
      change(&c, kind, pick(4));
      run(&c);
    }
    mark();
  }
  end("YCCK_Errors");
  counts("YCCK_Errors");
}

// ---- The order of the checks: a valid call with two things changed (every
// pair of the kinds of change above, three times), so that calls that are
// wrong in two ways report what C reports.  One mark per first kind.

static void sweep_order(void) {
  begin(9);
  reset_counts();
  fill(g_palette, 1024, 0);
  for (uint32_t kind1 = 0; kind1 < NUM_CHANGES; kind1++) {
    for (uint32_t kind2 = 0; kind2 < NUM_CHANGES; kind2++) {
      for (int i = 0; i < 3; i++) {
        uint32_t hv[8];
        for (int j = 0; j < 6; j++) {
          hv[j] = 1 + pick(2);
        }
        if (pick(2) == 0) {
          hv[6] = 1 + pick(2);
          hv[7] = 1 + pick(2);
        } else {
          hv[6] = 0;
          hv[7] = 0;
        }
        uint32_t ups = pick(3);
        uint32_t dx = SIZES[1 + pick(10)];
        uint32_t dy = SIZES[1 + pick(10)];
        call_t c;
        make(&c, hv, dx, dy, 0, 0, 0, 0, pick(2), 0, 0);
        c.fmt = ACCEPTED[pick(17)];
        c.model =
            ((hv[6] | hv[7]) != 0) ? MODELS_4[pick(4)] : MODELS_3[pick(3)];
        c.ups = ups;
        change(&c, kind1, pick(4));
        change(&c, kind2, pick(4));
        run(&c);
      }
    }
    mark();
  }
  end("YCCK_Order");
  counts("YCCK_Order");
}

// ---- The limits, from the accepted side and from the rejected side:
// x_max_excl and y_max_excl of 0xFFFF, planes exactly 0x10000 wide or
// high, and one more.  The destination is as large as the rectangle in
// one direction and two pixels in the other.  One mark per layout.

static const int LIMIT_LAYOUTS[4] = {0, 3, 9, 10};

static void sweep_limits(void) {
  begin(10);
  reset_counts();
  fill(g_palette, 1024, 0);
  uint32_t n = 0;
  for (int li = 0; li < 4; li++) {
    const uint32_t* hv = LAYOUTS[LIMIT_LAYOUTS[li]];
    for (uint32_t ups = 0; ups < 3; ups++) {
      for (uint32_t extra = 0; extra < 3; extra++) {
        for (int wide = 0; wide < 2; wide++) {
          call_t c;
          if (wide) {
            make(&c, hv, 0xFFFF, 2, 0, 0, extra, 0, n % 2, 0, 0);
          } else {
            make(&c, hv, 2, 0xFFFF, 0, 0, 0, extra, n % 2, 0, 0);
          }
          c.fmt = ACCEPTED[n % 17];
          c.model = (hv[6] != 0) ? MODELS_4[n % 4] : MODELS_3[n % 3];
          c.ups = ups;
          run(&c);
          n++;
        }
      }
    }
    mark();
  }
  end("YCCK_Limits");
  counts("YCCK_Limits");
}

// ---- Rectangles that do not start at the origin (box filter only: the C
// rejects any other origin with fancy upsampling).  The origin is a
// multiple of the coarsest plane's sample size, which for a layout
// without subsampling means any pixel, odd ones included.  One mark per
// layout.

static const uint32_t ORIGINS[4] = {0, 1, 3, 5};
static const uint32_t ORIGIN_WIDTHS[5] = {1, 17, 480, 673, 1345};
static const uint32_t ORIGIN_HEIGHTS[2] = {1, 5};

static void sweep_origins(void) {
  begin(7);
  reset_counts();
  fill(g_palette, 1024, 0);
  uint32_t n = 0;
  for (int l = 0; l < 14; l++) {
    for (int xi = 0; xi < 4; xi++) {
      for (int yi = 0; yi < 4; yi++) {
        for (int wi = 0; wi < 5; wi++) {
          for (int hi = 0; hi < 2; hi++) {
            call_t c;
            make(&c, LAYOUTS[l], ORIGIN_WIDTHS[wi], ORIGIN_HEIGHTS[hi],
                 ORIGINS[xi], ORIGINS[yi], 0, 0, n % 2, 0, 0);
            c.fmt = ACCEPTED[n % 17];
            c.model = (LAYOUTS[l][6] != 0) ? MODELS_4[n % 4] : MODELS_3[n % 3];
            c.mode = n % 5;
            run(&c);
            n++;
          }
        }
      }
    }
    mark();
  }
  end("YCCK_Origins");
  counts("YCCK_Origins");
}

// ---- Bands: an image converted by one call, and again by four calls for
// consecutive ranges of 12 rows (each band's planes being the matching
// rows of the whole image's planes).  The two destinations must be equal;
// the digest covers the statuses, the banded destination and whether they
// were.  Box filter only (with fancy upsampling C accepts no y_min_incl
// other than 0).  One mark per layout.

#define BAND_ROWS 12
#define NUM_BANDS 4

static void sweep_bands(void) {
  begin(8);
  reset_counts();
  fill(g_palette, 1024, 0);
  uint32_t n = 0;
  for (int l = 0; l < 14; l++) {
    for (int wi = 0; wi < 3; wi++) {
      call_t c;
      make(&c, LAYOUTS[l], (wi == 0) ? 13 : ((wi == 1) ? 481 : 1345),
           BAND_ROWS * NUM_BANDS, 0, 0, 0, 0, n % 2, 0, 0);
      c.fmt = ACCEPTED[n % 17];
      c.model = (LAYOUTS[l][6] != 0) ? MODELS_4[n % 4] : MODELS_3[n % 3];
      size_t dlen = dst_len(&c);
      uint8_t* src[4];
      for (int k = 0; k < 4; k++) {
        src[k] = (uint8_t*)malloc(c.len[k] ? c.len[k] : 1);
        fill(src[k], c.len[k], 0);
      }
      uint8_t* whole = (uint8_t*)malloc(dlen);
      uint8_t* banded = (uint8_t*)malloc(dlen);
      fill(whole, dlen, 0);
      memcpy(banded, whole, dlen);
      uint8_t* scratch = (uint8_t*)malloc(2048);
      memset(scratch, 0, 2048);
      mix(call(&c, src, whole, scratch));
      for (uint32_t b = 0; b < NUM_BANDS; b++) {
        call_t cb = c;
        uint8_t* band_src[4];
        cb.y0 = b * BAND_ROWS;
        cb.y1 = cb.y0 + BAND_ROWS;
        for (int k = 0; k < 4; k++) {
          // Plane k has c.h[k] rows for the image's NUM_BANDS bands.
          uint32_t rows = c.h[k] / NUM_BANDS;
          cb.h[k] = rows;
          cb.len[k] = flat(c.w[k], rows, c.s[k]);
          band_src[k] = src[k] + ((size_t)b * rows * c.s[k]);
        }
        mix(call(&cb, band_src, banded, scratch));
      }
      mix_bytes(banded, dlen);
      mix(memcmp(whole, banded, dlen) == 0);
      for (int k = 0; k < 4; k++) {
        free(src[k]);
      }
      free(whole);
      free(banded);
      free(scratch);
      n++;
    }
    mark();
  }
  end("YCCK_Bands");
  counts("YCCK_Bands");
}

int main(void) {
  sweep_colors();
  sweep_formats();
  sweep_sampling();
  sweep_sizes();
  sweep_large();
  sweep_errors();
  sweep_origins();
  sweep_bands();
  sweep_order();
  sweep_limits();
  return 0;
}
