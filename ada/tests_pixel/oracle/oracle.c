// Oracle for ada/tests_pixel: runs upstream Wuffs' own C (colours, pixel
// formats and configs, pixel buffers, the pixel swizzler) over fixed input
// sweeps and prints one 64-bit digest per sweep, as Ada constants.  The Ada
// tests run the same sweeps through Wuffs.Base.* and compare digests.
//
// Build and run via ./regen.sh, which writes ../pixel_oracle_data.ads.
//
// Each sweep here has a twin of the same name in ../test_*.adb.  The two
// must enumerate the same cases, draw random numbers and call mix() in the
// same order.
//
// WUFFS_CONFIG__AVOID_CPU_ARCH (given by regen.sh) selects the scalar row
// functions.  regen.sh also builds this file without it and checks that
// the SIMD build prints the same digests.

#define WUFFS_IMPLEMENTATION
#define WUFFS_CONFIG__MODULES
#define WUFFS_CONFIG__MODULE__BASE
#define WUFFS_CONFIG__MODULE__BASE__CORE
#define WUFFS_CONFIG__MODULE__BASE__PIXCONV

#include WUFFS_C_FILE

#include <inttypes.h>
#include <stdio.h>
#include <stdlib.h>

static uint64_t g_h;
static uint64_t g_rng;

// Checkpoints: the digest so far, recorded at chosen points of a sweep
// (after each format, each combination, each function).  The Ada twin
// compares at the same points, so a mismatch is reported with the first
// combination that differs and not only with the name of the sweep.
static uint64_t g_marks[2048];
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
  if (g_num_marks > 0) {
    printf("   %s_Marks : constant Mark_Array (0 .. %zu) :=\n     [", name,
           g_num_marks - 1);
    for (size_t i = 0; i < g_num_marks; i++) {
      printf("%s16#%016" PRIX64 "#", (i == 0) ? "" : ((i % 4) ? ", " : ",\n      "),
             g_marks[i]);
    }
    printf("];\n");
  }
}

static void count(const char* name, uint64_t n) {
  printf("   %s : constant := %" PRIu64 ";\n", name, n);
}

// Status as a small number: 0 ok, then the base errors these functions use.
static uint64_t status_code(wuffs_base__status s) {
  if (s.repr == NULL) {
    return 0;
  } else if (s.repr == wuffs_base__error__bad_argument) {
    return 1;
  } else if (s.repr == wuffs_base__error__bad_argument_length_too_short) {
    return 2;
  } else if (s.repr == wuffs_base__error__unsupported_option) {
    return 3;
  } else if (s.repr == wuffs_base__error__unsupported_pixel_swizzler_option) {
    return 4;
  }
  return 99;
}

// Every named pixel format, in the order of image-public.h.  The first
// NUM_WHOLE have a whole number of bytes per pixel and one plane.
#define PF(x) WUFFS_BASE__PIXEL_FORMAT__##x
static const uint32_t FORMATS[34] = {
    PF(A),
    PF(Y),
    PF(Y_16LE),
    PF(Y_16BE),
    PF(YA_NONPREMUL),
    PF(YA_PREMUL),
    PF(YXXX),
    PF(INDEXED__BGRA_NONPREMUL),
    PF(INDEXED__BGRA_PREMUL),
    PF(INDEXED__BGRA_BINARY),
    PF(BGR_565),
    PF(BGR),
    PF(BGRA_NONPREMUL),
    PF(BGRA_NONPREMUL_4X16LE),
    PF(BGRA_PREMUL),
    PF(BGRA_PREMUL_4X16LE),
    PF(BGRA_BINARY),
    PF(BGRX),
    PF(RGB),
    PF(RGBA_NONPREMUL),
    PF(RGBA_NONPREMUL_4X16LE),
    PF(RGBA_PREMUL),
    PF(RGBA_PREMUL_4X16LE),
    PF(RGBA_BINARY),
    PF(RGBX),
    // Planar formats, and the invalid format.
    PF(YCBCR),
    PF(YCBCRA_NONPREMUL),
    PF(YCBCRK),
    PF(YCOCG),
    PF(YCOCGA_NONPREMUL),
    PF(YCOCGK),
    PF(CMY),
    PF(CMYK),
    PF(INVALID),
};
#define NUM_FORMATS 34
#define NUM_WHOLE 25

// ---------------- Colours

// 8 bit and 16 bit channel values that the colour sweeps combine.
static const uint32_t C8[7] = {0, 1, 2, 127, 128, 254, 255};
static const uint64_t C16[8] = {0,      1,      0xFF,   0x100,
                                0x7FFF, 0x8000, 0xFFFE, 0xFFFF};

static void mix_u32_color(uint32_t c) {
  mix(wuffs_base__color_u32_argb_premul__is_valid(c) ? 1 : 0);
  mix(wuffs_base__color_u32_argb_premul__as__color_u16_rgb_565(c));
  mix(wuffs_base__color_u32_argb_premul__as__color_u8_gray(c));
  mix(wuffs_base__color_u32_argb_premul__as__color_u16_gray(c));
  mix(wuffs_base__color_u32_argb_premul__as__color_u16_alpha_gray_nonpremul(c));
  mix(wuffs_base__color_u32_argb_nonpremul__as__color_u32_argb_premul(c));
  mix(wuffs_base__color_u32_argb_premul__as__color_u32_argb_nonpremul(c));
  mix(wuffs_base__color_u32_argb_premul__as__color_u64_argb_nonpremul(c));
  mix(wuffs_base__color_u32__as__color_u64(c));
  mix(wuffs_base__color_swap_u32_argb_abgr(c));
}

static void mix_u64_color(uint64_t c) {
  mix(wuffs_base__color_u64_argb_nonpremul__as__color_u32_argb_premul(c));
  mix(wuffs_base__color_u64_argb_premul__as__color_u8_gray(c));
  mix(wuffs_base__color_u64_argb_premul__as__color_u64_argb_nonpremul(c));
  mix(wuffs_base__color_u64_argb_nonpremul__as__color_u64_argb_premul(c));
  mix(wuffs_base__color_u64_argb_nonpremul__as__color_u8_gray(c));
  mix(wuffs_base__color_u64__as__color_u32(c));
  mix(wuffs_base__color_swap_u64_argb_abgr(c));
}

static void sweep_colors(void) {
  // Exhaustive: every RGB 565 value.
  begin(101);
  for (uint32_t v = 0; v < 0x10000; v++) {
    mix(wuffs_base__color_u16_rgb_565__as__color_u32_argb_premul((uint16_t)v));
  }
  end("Colors_565");

  // Exhaustive: every gray level under every alpha.
  begin(102);
  for (uint32_t a = 0; a < 256; a++) {
    for (uint32_t y = 0; y < 256; y++) {
      mix_u32_color((a << 24) | (y * 0x010101));
    }
  }
  end("Colors_Gray");

  // Edge values in every channel, then random colours.
  begin(103);
  for (int a = 0; a < 7; a++) {
    for (int r = 0; r < 7; r++) {
      for (int g = 0; g < 7; g++) {
        for (int b = 0; b < 7; b++) {
          mix_u32_color((C8[a] << 24) | (C8[r] << 16) | (C8[g] << 8) | C8[b]);
        }
      }
    }
  }
  for (int i = 0; i < 20000; i++) {
    mix_u32_color((uint32_t)(rnd() >> 32));
  }
  end("Colors_U32");

  begin(104);
  for (int a = 0; a < 8; a++) {
    for (int r = 0; r < 8; r++) {
      for (int g = 0; g < 8; g++) {
        for (int b = 0; b < 8; b++) {
          mix_u64_color((C16[a] << 48) | (C16[r] << 32) | (C16[g] << 16) |
                        C16[b]);
        }
      }
    }
  }
  for (int i = 0; i < 20000; i++) {
    mix_u64_color(rnd());
  }
  end("Colors_U64");
}

// ---------------- Pixel formats and configs

static void mix_format(uint32_t repr) {
  wuffs_base__pixel_format f = wuffs_base__make_pixel_format(repr);
  mix(wuffs_base__pixel_format__is_valid(&f) ? 1 : 0);
  mix(wuffs_base__pixel_format__bits_per_pixel(&f));
  mix(wuffs_base__pixel_format__default_background_color(&f));
  mix(wuffs_base__pixel_format__is_direct(&f) ? 1 : 0);
  mix(wuffs_base__pixel_format__is_indexed(&f) ? 1 : 0);
  mix(wuffs_base__pixel_format__is_interleaved(&f) ? 1 : 0);
  mix(wuffs_base__pixel_format__is_planar(&f) ? 1 : 0);
  mix(wuffs_base__pixel_format__coloration(&f));
  mix(wuffs_base__pixel_format__num_planes(&f));
  mix(wuffs_base__pixel_format__transparency(&f));
}

static const uint32_t SUBSAMPLINGS[6] = {0x000000, 0x010100, 0x101000,
                                         0x111100, 0x303000, 0x313100};
static const uint32_t DIMS[8] = {0,       1,        2,        3,
                                 0xFFFF,  0x10000,  0xFFFFFF, 0xFFFFFFFFu};

static void sweep_formats(void) {
  begin(111);
  for (int i = 0; i < NUM_FORMATS; i++) {
    mix_format(FORMATS[i]);
  }
  for (int i = 0; i < 2000; i++) {
    mix_format((uint32_t)(rnd() >> 32));
  }
  for (int i = 0; i < 6 + 200; i++) {
    wuffs_base__pixel_subsampling s = wuffs_base__make_pixel_subsampling(
        (i < 6) ? SUBSAMPLINGS[i] : (uint32_t)(rnd() >> 32));
    for (uint32_t plane = 0; plane < 6; plane++) {
      mix(wuffs_base__pixel_subsampling__bias_x(&s, plane));
      mix(wuffs_base__pixel_subsampling__denominator_x(&s, plane));
      mix(wuffs_base__pixel_subsampling__bias_y(&s, plane));
      mix(wuffs_base__pixel_subsampling__denominator_y(&s, plane));
    }
  }
  end("Formats");

  // pixel_config: every format with every pair of dimensions, including
  // sizes whose byte count does not fit in 64 bits.
  begin(112);
  for (int i = 0; i < NUM_FORMATS; i++) {
    for (int w = 0; w < 8; w++) {
      for (int h = 0; h < 8; h++) {
        wuffs_base__pixel_config c = wuffs_base__null_pixel_config();
        wuffs_base__pixel_config__set(&c, FORMATS[i], SUBSAMPLINGS[w % 6],
                                      DIMS[w], DIMS[h]);
        mix(wuffs_base__pixel_config__is_valid(&c) ? 1 : 0);
        mix(wuffs_base__pixel_config__pixel_format(&c).repr);
        mix(wuffs_base__pixel_config__pixel_subsampling(&c).repr);
        mix(wuffs_base__pixel_config__width(&c));
        mix(wuffs_base__pixel_config__height(&c));
        wuffs_base__rect_ie_u32 b = wuffs_base__pixel_config__bounds(&c);
        mix(b.min_incl_x);
        mix(b.min_incl_y);
        mix(b.max_excl_x);
        mix(b.max_excl_y);
        mix(wuffs_base__pixel_config__pixbuf_len(&c));

        wuffs_base__image_config ic = wuffs_base__null_image_config();
        wuffs_base__image_config__set(&ic, FORMATS[i], SUBSAMPLINGS[h % 6],
                                      DIMS[w], DIMS[h], rnd(), (w & 1) != 0);
        mix(wuffs_base__image_config__is_valid(&ic) ? 1 : 0);
        mix(wuffs_base__image_config__first_frame_io_position(&ic));
        mix(wuffs_base__image_config__first_frame_is_opaque(&ic) ? 1 : 0);
        mix(wuffs_base__pixel_config__pixbuf_len(&ic.pixcfg));
        mix(wuffs_base__pixel_config__width(&ic.pixcfg));
      }
    }
  }
  end("Configs");

  begin(113);
  for (int i = 0; i < 50; i++) {
    wuffs_base__frame_config fc = wuffs_base__null_frame_config();
    uint64_t a = rnd(), b = rnd(), c = rnd(), d = rnd(), e = rnd();
    wuffs_base__frame_config__set(
        &fc,
        wuffs_base__make_rect_ie_u32((uint32_t)a, (uint32_t)(a >> 32),
                                     (uint32_t)b, (uint32_t)(b >> 32)),
        (wuffs_base__flicks)(c >> 1), d, e, (uint8_t)(i % 3), (i & 1) != 0,
        (i & 2) != 0, (uint32_t)(e >> 7));
    wuffs_base__rect_ie_u32 r = wuffs_base__frame_config__bounds(&fc);
    mix(r.min_incl_x);
    mix(r.min_incl_y);
    mix(r.max_excl_x);
    mix(r.max_excl_y);
    mix(wuffs_base__frame_config__width(&fc));
    mix(wuffs_base__frame_config__height(&fc));
    mix((uint64_t)wuffs_base__frame_config__duration(&fc));
    mix(wuffs_base__frame_config__index(&fc));
    mix(wuffs_base__frame_config__io_position(&fc));
    mix(wuffs_base__frame_config__disposal(&fc));
    mix(wuffs_base__frame_config__opaque_within_bounds(&fc) ? 1 : 0);
    mix(wuffs_base__frame_config__overwrite_instead_of_blend(&fc) ? 1 : 0);
    mix(wuffs_base__frame_config__background_color(&fc));
  }
  end("Frame_Configs");
}

// ---------------- Tables and pixel buffers

static void mix_table(const wuffs_base__table_u8* t, const uint8_t* base) {
  mix(t->width);
  mix(t->height);
  mix(t->stride);
  // The pointer only matters (and is only compared) where the table has
  // elements.
  if ((t->width > 0) && (t->height > 0)) {
    mix((uint64_t)(t->ptr - base));
  }
}

static void sweep_tables(void) {
  begin(121);
  uint8_t mem[64];
  wuffs_base__table_u8 t = wuffs_base__make_table_u8(mem + 3, 5, 4, 7);
  for (uint64_t ix = 0; ix <= 6; ix++) {
    for (uint64_t iy = 0; iy <= 5; iy++) {
      for (uint64_t jx = 0; jx <= 6; jx++) {
        for (uint64_t jy = 0; jy <= 5; jy++) {
          wuffs_base__table_u8 u =
              wuffs_base__table_u8__subtable_ij(t, ix, iy, jx, jy);
          mix_table(&u, mem);
        }
      }
    }
  }
  for (uint32_t y = 0; y <= 5; y++) {
    wuffs_base__slice_u8 row = wuffs_private_impl__table_u8__row_u32(t, y);
    mix(row.len);
    if (row.len > 0) {
      mix((uint64_t)(row.ptr - mem));
    }
  }
  for (size_t w = 0; w <= 3; w++) {
    for (size_t h = 0; h <= 3; h++) {
      for (size_t s = 0; s <= 4; s++) {
        mix(wuffs_base__table__flattened_length(w, h, s));
      }
    }
  }
  end("Tables");
}

static const uint32_t PB_DIMS[6] = {0, 1, 3, 5, 0x10000, 0xFFFFFFFFu};

static void sweep_pixel_buffer_set(void) {
  begin(122);
  static uint8_t mem[2048];
  for (int i = 0; i < NUM_FORMATS; i++) {
    for (int w = 0; w < 6; w++) {
      for (int h = 0; h < 6; h++) {
        wuffs_base__pixel_config c = wuffs_base__null_pixel_config();
        wuffs_base__pixel_config__set(&c, FORMATS[i], 0, PB_DIMS[w],
                                      PB_DIMS[h]);
        uint64_t need = wuffs_base__pixel_config__pixbuf_len(&c);
        uint64_t lens[6] = {0, 1023, 1024, 2048, 0, 0};
        lens[4] = (need > 0 && need <= 2048) ? need - 1 : 7;
        lens[5] = (need <= 2048) ? need : 9;
        for (int k = 0; k < 6; k++) {
          wuffs_base__pixel_buffer pb;
          wuffs_base__status s = wuffs_base__pixel_buffer__set_from_slice(
              &pb, &c, wuffs_base__make_slice_u8(mem, (size_t)lens[k]));
          mix(status_code(s));
          mix(pb.pixcfg.private_impl.pixfmt.repr);
          mix(pb.pixcfg.private_impl.width);
          mix(pb.pixcfg.private_impl.height);
          // Plane 0 is relative to the pixel memory, after the palette.
          size_t split =
              wuffs_base__pixel_format__is_indexed(&c.private_impl.pixfmt)
                  ? 1024
                  : 0;
          mix_table(&pb.private_impl.planes[0], mem + split);
          mix_table(&pb.private_impl.planes[3], mem);
          mix(wuffs_base__pixel_buffer__palette(&pb).len);
          mix(wuffs_base__pixel_buffer__pixel_format(&pb).repr);
          mix(wuffs_base__pixel_buffer__plane(&pb, 3).width);
          mix(wuffs_base__pixel_buffer__plane(&pb, 4).width);
        }
        // set_interleaved with a table that has gaps, and palettes of
        // three lengths.
        static const size_t pal_lens[3] = {0, 1023, 1024};
        static const size_t tw[3] = {0, 12, 40};
        static const size_t th[3] = {0, 3, 5};
        for (int p = 0; p < 3; p++) {
          for (int a = 0; a < 3; a++) {
            for (int b = 0; b < 3; b++) {
              static uint8_t pal[1024];
              wuffs_base__pixel_buffer pb;
              wuffs_base__status s = wuffs_base__pixel_buffer__set_interleaved(
                  &pb, &c, wuffs_base__make_table_u8(mem + 5, tw[a], th[b], 50),
                  wuffs_base__make_slice_u8(pal, pal_lens[p]));
              mix(status_code(s));
              mix(pb.pixcfg.private_impl.pixfmt.repr);
              mix_table(&pb.private_impl.planes[0], mem);
              mix_table(&pb.private_impl.planes[3], pal);
              mix(wuffs_base__pixel_buffer__palette(&pb).len);
            }
          }
        }
      }
    }
    mark();
  }
  end("Pixel_Buffer_Set");
}

// Colours for the accessor sweeps: valid and invalid premul values.
static const uint32_t PB_COLORS[12] = {
    0x00000000, 0xFF000000, 0xFFFFFFFF, 0xFF123456, 0x80402010, 0x80FF8040,
    0x01010101, 0x7F7F7F7F, 0xFE0000FE, 0x00FFFFFF, 0xFF00FF00, 0xC0C08040,
};

static void sweep_pixel_buffer_colors(void) {
  begin(123);
  static uint8_t base[1024 + 240];
  static uint8_t mem[1024 + 240];
  const uint32_t w = 5, h = 3;
  for (int i = 0; i < NUM_WHOLE; i++) {
    fill(base, sizeof(base));
    // Palette entries: some transparent, some opaque, the rest random.
    for (int e = 0; e < 256; e++) {
      if ((e % 4) == 0) {
        base[(4 * e) + 3] = 0x00;
      } else if ((e % 4) == 1) {
        base[(4 * e) + 3] = 0xFF;
      }
    }
    wuffs_base__pixel_config c = wuffs_base__null_pixel_config();
    wuffs_base__pixel_config__set(&c, FORMATS[i], 0, w, h);
    wuffs_base__pixel_buffer pb;
    memcpy(mem, base, sizeof(mem));
    wuffs_base__status s0 = wuffs_base__pixel_buffer__set_from_slice(
        &pb, &c, wuffs_base__make_slice_u8(mem, sizeof(mem)));
    mix(status_code(s0));
    if (s0.repr) {
      mark();
      continue;
    }
    for (uint32_t y = 0; y <= h; y++) {
      for (uint32_t x = 0; x <= w; x++) {
        mix(wuffs_base__pixel_buffer__color_u32_at(&pb, x, y));
      }
    }
    mix(wuffs_base__pixel_buffer__is_opaque(&pb) ? 1 : 0);
    for (int k = 0; k < 12 + 12; k++) {
      uint32_t color = (k < 12) ? PB_COLORS[k] : (uint32_t)(rnd() >> 32);
      uint32_t x = (uint32_t)k % (w + 1);
      uint32_t y = (uint32_t)k % (h + 1);
      memcpy(mem, base, sizeof(mem));
      mix(status_code(
          wuffs_base__pixel_buffer__set_color_u32_at(&pb, x, y, color)));
      mix_bytes(mem, sizeof(mem));
      mix(wuffs_base__pixel_buffer__color_u32_at(&pb, x, y));
      memcpy(mem, base, sizeof(mem));
      mix(status_code(wuffs_base__pixel_buffer__set_color_u32_argb_nonpremul_at(
          &pb, x, y, color)));
      mix_bytes(mem, sizeof(mem));
    }
    static const uint32_t rects[7][4] = {
        {0, 0, 5, 3}, {1, 1, 4, 2}, {0, 2, 5, 3}, {4, 0, 5, 3},
        {2, 2, 2, 3}, {0, 0, 6, 3}, {3, 1, 5, 4},
    };
    for (int r = 0; r < 7; r++) {
      memcpy(mem, base, sizeof(mem));
      mix(status_code(wuffs_base__pixel_buffer__set_color_u32_fill_rect(
          &pb,
          wuffs_base__make_rect_ie_u32(rects[r][0], rects[r][1], rects[r][2],
                                       rects[r][3]),
          PB_COLORS[(r + 3) % 12])));
      mix_bytes(mem, sizeof(mem));
    }
    // is_opaque with every byte 0xFF (opaque in every format), then with
    // one pixel's bytes cleared.
    memset(mem, 0xFF, sizeof(mem));
    mix(wuffs_base__pixel_buffer__is_opaque(&pb) ? 1 : 0);
    size_t split =
        wuffs_base__pixel_format__is_indexed(&c.private_impl.pixfmt) ? 1024 : 0;
    size_t bpp = wuffs_base__pixel_format__bits_per_pixel(&c.private_impl.pixfmt) / 8;
    memset(mem + split + (bpp * 7), 0x00, bpp);
    // (For an indexed format that pixel now selects palette entry 0.)
    mix(wuffs_base__pixel_buffer__is_opaque(&pb) ? 1 : 0);
    memset(mem, 0x00, 4);
    mix(wuffs_base__pixel_buffer__is_opaque(&pb) ? 1 : 0);
    mark();
  }
  end("Pixel_Buffer_Colors");

  // A buffer whose rows have gaps (set_interleaved, stride 29).
  begin(124);
  for (int i = 0; i < NUM_WHOLE; i++) {
    static uint8_t pixels[200];
    static uint8_t palette[1024];
    fill(pixels, sizeof(pixels));
    fill(palette, sizeof(palette));
    wuffs_base__pixel_config c = wuffs_base__null_pixel_config();
    wuffs_base__pixel_config__set(&c, FORMATS[i], 0, 3, 4);
    wuffs_base__pixel_buffer pb;
    wuffs_base__status s0 = wuffs_base__pixel_buffer__set_interleaved(
        &pb, &c, wuffs_base__make_table_u8(pixels + 6, 26, 4, 29),
        wuffs_base__make_slice_u8(palette, 1024));
    mix(status_code(s0));
    if (s0.repr) {
      mark();
      continue;
    }
    for (uint32_t y = 0; y < 4; y++) {
      for (uint32_t x = 0; x < 3; x++) {
        mix(wuffs_base__pixel_buffer__color_u32_at(&pb, x, y));
        mix(status_code(wuffs_base__pixel_buffer__set_color_u32_at(
            &pb, x, y, PB_COLORS[(x + (3 * y)) % 12])));
      }
    }
    mix(status_code(wuffs_base__pixel_buffer__set_color_u32_fill_rect(
        &pb, wuffs_base__make_rect_ie_u32(1, 1, 3, 4), 0xFF336699)));
    mix_bytes(pixels, sizeof(pixels));
    mix(wuffs_base__pixel_buffer__is_opaque(&pb) ? 1 : 0);
    mark();
  }
  end("Pixel_Buffer_Gaps");

  begin(125);
  {
    static uint8_t palette[1028];
    fill(palette, sizeof(palette));
    static const size_t lens[7] = {0, 3, 4, 8, 1023, 1024, 1028};
    static const uint32_t fmts[4] = {
        PF(INDEXED__BGRA_NONPREMUL), PF(INDEXED__BGRA_PREMUL),
        PF(INDEXED__BGRA_BINARY), PF(BGRA_PREMUL)};
    for (int f = 0; f < 4; f++) {
      for (int l = 0; l < 7; l++) {
        for (int k = 0; k < 12 + 100; k++) {
          uint32_t color = (k < 12) ? PB_COLORS[k] : (uint32_t)(rnd() >> 32);
          mix(wuffs_base__pixel_palette__closest_element(
              wuffs_base__make_slice_u8(palette, lens[l]),
              wuffs_base__make_pixel_format(fmts[f]), color));
        }
      }
    }
  }
  end("Closest_Element");
}

// pixbuf_len at the edge of 64 bits, including indexed formats of more
// than one byte per pixel (not named formats, but valid reprs), for which
// adding the palette's 1024 bytes can be what overflows.
static void sweep_pixbuf_len_edges(void) {
  begin(114);
  static const uint32_t reprs[5] = {0x81040088u, 0x81048888u, 0x81040008u,
                                    0x8104BBBBu, 0x81040888u};
  static const uint32_t dims[11][2] = {
      {4294967264u, 2147483664u}, {4294967265u, 2147483664u},
      {4294967263u, 2147483664u}, {2147483647u, 2147483649u},
      {2147483647u, 2147483648u}, {4294967295u, 4294967295u},
      {65536, 65536},             {3, 5},
      {4294967295u, 2863311530u}, {4294967295u, 1431655765u},
      {4294967294u, 1431655766u},
  };
  for (int r = 0; r < 5; r++) {
    for (int d = 0; d < 11; d++) {
      wuffs_base__pixel_config c = wuffs_base__null_pixel_config();
      wuffs_base__pixel_config__set(&c, reprs[r], 0, dims[d][0], dims[d][1]);
      mix(wuffs_base__pixel_config__pixbuf_len(&c));
    }
  }
  end("Pixbuf_Len_Edges");
}

// Pixel buffers without pixels: tables with no columns or no rows, over
// no memory at all.  C accepts them (it never dereferences the pointer).
static void sweep_pixel_buffer_elementless(void) {
  begin(126);
  static uint8_t one[1];
  static uint8_t pal[1024];
  static const uint32_t cfg[3][2] = {{0, 5}, {5, 0}, {0, 0}};
  static const size_t tab[4][3] = {
      {0, 5, 100}, {7, 0, 100}, {0, 0, 0}, {0, 5, 0}};
  for (int i = 0; i < NUM_FORMATS; i++) {
    for (int c = 0; c < 3; c++) {
      for (int t = 0; t < 4; t++) {
        wuffs_base__pixel_config pc = wuffs_base__null_pixel_config();
        wuffs_base__pixel_config__set(&pc, FORMATS[i], 0, cfg[c][0], cfg[c][1]);
        wuffs_base__pixel_buffer pb;
        wuffs_base__status s = wuffs_base__pixel_buffer__set_interleaved(
            &pb, &pc,
            wuffs_base__make_table_u8(one, tab[t][0], tab[t][1], tab[t][2]),
            wuffs_base__make_slice_u8(pal, 1024));
        mix(status_code(s));
        if (s.repr) {
          continue;
        }
        mix(wuffs_base__pixel_buffer__color_u32_at(&pb, 0, 0));
        mix(wuffs_base__pixel_buffer__is_opaque(&pb) ? 1 : 0);
        mix(status_code(
            wuffs_base__pixel_buffer__set_color_u32_at(&pb, 0, 0, 0xFF010203)));
        mix(status_code(wuffs_base__pixel_buffer__set_color_u32_fill_rect(
            &pb, wuffs_base__make_rect_ie_u32(0, 0, 0, 0), 0xFF010203)));
        for (uint32_t y = 0; y <= 5; y++) {
          mix(wuffs_private_impl__table_u8__row_u32(
                  wuffs_base__pixel_buffer__plane(&pb, 0), y)
                  .len);
        }
      }
    }
    mark();
  }
  end("Pixel_Buffer_Elementless");
}

// Tables whose stride is not the row width: 0, 1, one pixel, one byte less
// than a row (rows overlap), two bytes more than a row; with and without
// two spare bytes of table width.
static void sweep_pixel_buffer_strides(void) {
  begin(127);
  static uint8_t px[200];
  static uint8_t pal[1024];
  for (int i = 0; i < NUM_WHOLE; i++) {
    wuffs_base__pixel_format f = wuffs_base__make_pixel_format(FORMATS[i]);
    size_t bpp = wuffs_base__pixel_format__bits_per_pixel(&f) / 8;
    size_t strides[5] = {0, 1, bpp, (3 * bpp) - 1, (3 * bpp) + 2};
    for (int si = 0; si < 5; si++) {
      for (size_t wi = 0; wi < 2; wi++) {
        for (int op = 0; op < 2; op++) {
          if (op) {
            memset(px, 0xFF, sizeof(px));
          } else {
            fill(px, sizeof(px));
          }
          if (op && (si < 2)) {
            memset(pal, 0xFF, sizeof(pal));
          } else {
            fill(pal, sizeof(pal));
          }
          wuffs_base__pixel_config c = wuffs_base__null_pixel_config();
          wuffs_base__pixel_config__set(&c, FORMATS[i], 0, 3, 4);
          wuffs_base__pixel_buffer pb;
          wuffs_base__status s = wuffs_base__pixel_buffer__set_interleaved(
              &pb, &c,
              wuffs_base__make_table_u8(px + 6, (3 * bpp) + (wi * 2), 4,
                                        strides[si]),
              wuffs_base__make_slice_u8(pal, 1024));
          mix(status_code(s));
          if (s.repr) {
            continue;
          }
          mix(wuffs_base__pixel_buffer__is_opaque(&pb) ? 1 : 0);
          for (uint32_t y = 0; y < 4; y++) {
            for (uint32_t x = 0; x < 3; x++) {
              mix(wuffs_base__pixel_buffer__color_u32_at(&pb, x, y));
              mix(status_code(wuffs_base__pixel_buffer__set_color_u32_at(
                  &pb, x, y,
                  0x80402010u + (x * 0x01010101u) + (y * 0x10000000u))));
              mix(status_code(
                  wuffs_base__pixel_buffer__set_color_u32_argb_nonpremul_at(
                      &pb, (x + 1) % 3, y, 0x90FF2010u + (x * 0x01010101u))));
            }
          }
          mix(status_code(wuffs_base__pixel_buffer__set_color_u32_fill_rect(
              &pb, wuffs_base__make_rect_ie_u32(1, 1, 3, 3), 0xFF336699)));
          mix(wuffs_base__pixel_buffer__is_opaque(&pb) ? 1 : 0);
          mix_bytes(px, sizeof(px));
        }
      }
    }
    mark();
  }
  end("Pixel_Buffer_Strides");
}

// is_opaque with exactly one byte that is not 0xFF, for every byte of one
// pixel (so, for the 16 bit formats, the low as well as the high byte of
// the alpha channel) and for the alpha byte of the palette entry that
// every pixel then selects.
static void sweep_pixel_buffer_opaque(void) {
  begin(128);
  static uint8_t mem[1024 + 240];
  for (int i = 0; i < NUM_WHOLE; i++) {
    wuffs_base__pixel_config c = wuffs_base__null_pixel_config();
    wuffs_base__pixel_config__set(&c, FORMATS[i], 0, 5, 3);
    wuffs_base__pixel_buffer pb;
    wuffs_base__status s0 = wuffs_base__pixel_buffer__set_from_slice(
        &pb, &c, wuffs_base__make_slice_u8(mem, sizeof(mem)));
    mix(status_code(s0));
    if (!s0.repr) {
      size_t split =
          wuffs_base__pixel_format__is_indexed(&c.private_impl.pixfmt) ? 1024
                                                                       : 0;
      size_t bpp =
          wuffs_base__pixel_format__bits_per_pixel(&c.private_impl.pixfmt) / 8;
      for (size_t b = 0; b < bpp; b++) {
        memset(mem, 0xFF, sizeof(mem));
        mem[split + (bpp * 7) + b] = 0xFE;
        mix(wuffs_base__pixel_buffer__is_opaque(&pb) ? 1 : 0);
      }
      memset(mem, 0xFF, sizeof(mem));
      mem[(4 * 255) + 3] = 0xFE;
      mix(wuffs_base__pixel_buffer__is_opaque(&pb) ? 1 : 0);
    }
    mark();
  }
  end("Pixel_Buffer_Opaque");
}

// ---------------- Pixel swizzler

static uint64_t g_accepted;
static uint64_t g_rejected;

// Source palettes: alpha 0 for every fourth entry, 0xFF for the next, the
// rest random; for the binary-alpha format every entry is either all zero
// or opaque.
static void make_src_palette(uint8_t* p, uint32_t src_format) {
  fill(p, 1028);
  for (int e = 0; e < 256; e++) {
    if (src_format == PF(INDEXED__BGRA_BINARY)) {
      if ((e % 3) == 0) {
        memset(p + (4 * e), 0, 4);
      } else {
        p[(4 * e) + 3] = 0xFF;
      }
    } else if ((e % 4) == 0) {
      p[(4 * e) + 3] = 0x00;
    } else if ((e % 4) == 1) {
      p[(4 * e) + 3] = 0xFF;
    }
  }
}

static uint64_t tb_kind(const wuffs_base__pixel_swizzler* p) {
  if (p->private_impl.transparent_black_func == NULL) {
    return 0;
  } else if (p->private_impl.transparent_black_func ==
             &wuffs_private_impl__swizzle_transparent_black_src) {
    return 1;
  }
  return 2;
}

// prepare, for every pair of formats (all 34, so including planar and
// invalid ones), four blend values and several palette lengths: which
// combinations are accepted, with which status, what the swizzler then
// holds, and what was written to the destination palette.
static void sweep_swizzler_prepare(void) {
  begin(131);
  g_accepted = 0;
  g_rejected = 0;
  static const uint8_t blends[4] = {0, 1, 2, 255};
  static const size_t pal_lens[7][2] = {
      {1024, 1024}, {0, 0},       {1024, 1020}, {1020, 1024},
      {1023, 1024}, {1028, 1024}, {1024, 1028},
  };
  static uint8_t sp[1028];
  static uint8_t dp0[1028];
  static uint8_t dp[1028];
  fill(dp0, 1028);
  for (int s = 0; s < NUM_FORMATS; s++) {
    make_src_palette(sp, FORMATS[s]);
    for (int d = 0; d < NUM_FORMATS; d++) {
      for (int b = 0; b < 4; b++) {
        for (int l = 0; l < 7; l++) {
          memcpy(dp, dp0, 1028);
          wuffs_base__pixel_swizzler p;
          wuffs_base__status st = wuffs_base__pixel_swizzler__prepare(
              &p, wuffs_base__make_pixel_format(FORMATS[d]),
              wuffs_base__make_slice_u8(dp, pal_lens[l][0]),
              wuffs_base__make_pixel_format(FORMATS[s]),
              wuffs_base__make_slice_u8(sp, pal_lens[l][1]), blends[b]);
          mix(status_code(st));
          mix(p.private_impl.func ? 1 : 0);
          mix(tb_kind(&p));
          mix(p.private_impl.dst_pixfmt_bytes_per_pixel);
          mix(p.private_impl.src_pixfmt_bytes_per_pixel);
          mix_bytes(dp, 1028);
          if (st.repr) {
            g_rejected++;
          } else {
            g_accepted++;
          }
        }
      }
      mark();
    }
  }
  end("Swizzler_Prepare");
  count("Swizzler_Prepare_Accepted", g_accepted);
  count("Swizzler_Prepare_Rejected", g_rejected);
}

// Row lengths, in pixels.
static const size_t ROW_PIXELS[15] = {0, 1,  2,  3,  4,  5,  7,   8,
                                      9, 15, 16, 17, 31, 33, 1000};

// Fills a source row.  kind 0: random; 1: all zero; 2: all 0xFF; 3: every
// byte 0x00 or 0xFF (so every channel, alpha included, is at an extreme);
// 4: random with every fourth byte 0xFF and every eighth 0x00 (opaque and
// transparent pixels among translucent ones, for the 4 byte formats).
static void fill_row(uint8_t* p, size_t n, int kind) {
  switch (kind) {
    case 0:
      fill(p, n);
      break;
    case 1:
      memset(p, 0x00, n);
      break;
    case 2:
      memset(p, 0xFF, n);
      break;
    case 3:
      for (size_t i = 0; i < n; i++) {
        p[i] = (rnd() >> 63) ? 0xFF : 0x00;
      }
      break;
    default:
      fill(p, n);
      for (size_t i = 3; i < n; i += 4) {
        p[i] = ((i & 7) == 7) ? 0x00 : 0xFF;
      }
      break;
  }
}

// Every row function that prepare selects, through
// swizzle_interleaved_from_slice: every accepted (source, destination,
// blend), 15 row lengths, 4 arrangements of destination and source length,
// 5 kinds of source content, over a destination with random content.
static void sweep_swizzler_rows(void) {
  static uint8_t sp[1028];
  static uint8_t dp[1028];
  static uint8_t src[8 * 1002 + 8];
  static uint8_t dst0[8 * 1002 + 8];
  static uint8_t dst[8 * 1002 + 8];
  uint64_t combos = 0;
  uint64_t rows = 0;
  begin(132);
  fill(dst0, sizeof(dst0));
  for (int s = 0; s < NUM_WHOLE; s++) {
    for (int d = 0; d < NUM_WHOLE; d++) {
      for (uint8_t blend = 0; blend < 2; blend++) {
        make_src_palette(sp, FORMATS[s]);
        fill(dp, 1028);
        wuffs_base__pixel_swizzler p;
        wuffs_base__status st = wuffs_base__pixel_swizzler__prepare(
            &p, wuffs_base__make_pixel_format(FORMATS[d]),
            wuffs_base__make_slice_u8(dp, 1024),
            wuffs_base__make_pixel_format(FORMATS[s]),
            wuffs_base__make_slice_u8(sp, 1024), blend);
        if (st.repr) {
          continue;
        }
        combos++;
        size_t dbpp = p.private_impl.dst_pixfmt_bytes_per_pixel;
        size_t sbpp = p.private_impl.src_pixfmt_bytes_per_pixel;
        for (int li = 0; li < 15; li++) {
          size_t n = ROW_PIXELS[li];
          for (int arr = 0; arr < 4; arr++) {
            // 0: equal; 1: source two pixels longer; 2: destination two
            // pixels longer; 3: both with trailing bytes that are not a
            // whole pixel.
            size_t dlen = (n + ((arr == 2) ? 2 : 0)) * dbpp;
            size_t slen = (n + ((arr == 1) ? 2 : 0)) * sbpp;
            if (arr == 3) {
              dlen += dbpp - 1;
              slen += sbpp - 1;
            }
            for (int kind = 0; kind < 5; kind++) {
              if ((n == 1000) && (kind != 0) && (arr != 0)) {
                continue;
              }
              fill_row(src, slen, kind);
              memcpy(dst, dst0, dlen + 8);
              mix(wuffs_base__pixel_swizzler__swizzle_interleaved_from_slice(
                  &p, wuffs_base__make_slice_u8(dst, dlen),
                  wuffs_base__make_slice_u8(dp, 1024),
                  wuffs_base__make_slice_u8(src, slen)));
              mix_bytes(dst, dlen + 8);
              rows++;
            }
          }
        }
        // A destination palette of the wrong length: conversions that use
        // it do nothing.
        fill_row(src, 9 * sbpp, 0);
        memcpy(dst, dst0, (9 * dbpp) + 8);
        mix(wuffs_base__pixel_swizzler__swizzle_interleaved_from_slice(
            &p, wuffs_base__make_slice_u8(dst, 9 * dbpp),
            wuffs_base__make_slice_u8(dp, 1020),
            wuffs_base__make_slice_u8(src, 9 * sbpp)));
        mix_bytes(dst, (9 * dbpp) + 8);
        mark();
      }
    }
  }
  end("Swizzler_Rows");
  count("Swizzler_Rows_Combinations", combos);
  count("Swizzler_Rows_Swizzles", rows);
}

// The reader forms and transparent black, for every accepted combination.
static void sweep_swizzler_reader(void) {
  static uint8_t sp[1028];
  static uint8_t dp[1028];
  static uint8_t src[400];
  static uint8_t dst0[400];
  static uint8_t dst[400];
  static const uint32_t up_tos[5] = {0, 1, 5, 40, 0xFFFFFFFFu};
  static const uint64_t blacks[5] = {0, 1, 7, 1000, 0xFFFFFFFFFFFFFFFFull};
  begin(133);
  fill(dst0, sizeof(dst0));
  for (int s = 0; s < NUM_WHOLE; s++) {
    for (int d = 0; d < NUM_WHOLE; d++) {
      for (uint8_t blend = 0; blend < 2; blend++) {
        make_src_palette(sp, FORMATS[s]);
        fill(dp, 1028);
        wuffs_base__pixel_swizzler p;
        wuffs_base__status st = wuffs_base__pixel_swizzler__prepare(
            &p, wuffs_base__make_pixel_format(FORMATS[d]),
            wuffs_base__make_slice_u8(dp, 1024),
            wuffs_base__make_pixel_format(FORMATS[s]),
            wuffs_base__make_slice_u8(sp, 1024), blend);
        (void)st;
        // Transparent black works after a rejected prepare too.
        for (int k = 0; k < 5; k++) {
          for (size_t dlen = 0; dlen <= 33; dlen += 11) {
            memcpy(dst, dst0, sizeof(dst));
            mix(wuffs_base__pixel_swizzler__swizzle_interleaved_transparent_black(
                &p, wuffs_base__make_slice_u8(dst, dlen),
                wuffs_base__make_slice_u8(dp, 1024), blacks[k]));
            mix_bytes(dst, 40);
          }
        }
        fill(src, sizeof(src));
        // The reader's readable bytes are src[iop .. io2).
        for (size_t iop = 0; iop <= 3; iop += 3) {
          for (size_t io2 = iop; io2 <= iop + 150; io2 += 75) {
            for (size_t dlen = 0; dlen <= 200; dlen += 100) {
              memcpy(dst, dst0, sizeof(dst));
              const uint8_t* ptr = src + iop;
              mix(wuffs_base__pixel_swizzler__swizzle_interleaved_from_reader(
                  &p, wuffs_base__make_slice_u8(dst, dlen),
                  wuffs_base__make_slice_u8(dp, 1024), &ptr, src + io2));
              mix((uint64_t)(ptr - src));
              mix_bytes(dst, 208);
              for (int u = 0; u < 5; u++) {
                memcpy(dst, dst0, sizeof(dst));
                ptr = src + iop;
                mix(wuffs_base__pixel_swizzler__limited_swizzle_u32_interleaved_from_reader(
                    &p, up_tos[u], wuffs_base__make_slice_u8(dst, dlen),
                    wuffs_base__make_slice_u8(dp, 1024), &ptr, src + io2));
                mix((uint64_t)(ptr - src));
                mix_bytes(dst, 208);
              }
            }
          }
        }
        mark();
      }
    }
  }
  end("Swizzler_Reader");
}

// Every scalar row function called directly (not through prepare), with
// independent destination and source lengths and five palette lengths.
// row_funcs.inc is generated by ada/src/pixel/tools/gen_rows.py.
typedef uint64_t (*squash_func)(uint8_t* dst_ptr,
                                size_t dst_len,
                                const uint8_t* src_ptr,
                                size_t src_len,
                                bool nonpremul);

static void sweep_row_fuzz(void) {
  static const struct {
    wuffs_base__pixel_swizzler__func f;
    size_t dbpp;
    size_t sbpp;
  } rows[] = {
#define ROW(f, d, s) {&f, d, s},
#define SQUASH(f)
#include "row_funcs.inc"
#undef ROW
#undef SQUASH
  };
  static const squash_func squashes[] = {
#define ROW(f, d, s)
#define SQUASH(f) &f,
#include "row_funcs.inc"
#undef ROW
#undef SQUASH
  };
  static const size_t pal_lens[5] = {1024, 1020, 0, 1028, 1023};
  static uint8_t pal[1028];
  static uint8_t src[80];
  static uint8_t dst[80];
  uint64_t calls = 0;
  begin(134);
  for (size_t r = 0; r < sizeof(rows) / sizeof(rows[0]); r++) {
    for (int pl = 0; pl < 5; pl++) {
      for (int k = 0; k < 12; k++) {
        fill(pal, 1028);
        size_t dlen = (size_t)(rnd() % 71);
        size_t slen = (size_t)(rnd() % 71);
        fill(src, 80);
        fill(dst, 80);
        mix((*rows[r].f)(dst, dlen, pal, pal_lens[pl], src, slen));
        mix_bytes(dst, 80);
        calls++;
      }
    }
    mark();
  }
  for (size_t q = 0; q < sizeof(squashes) / sizeof(squashes[0]); q++) {
    for (int nonpremul = 0; nonpremul < 2; nonpremul++) {
      for (int k = 0; k < 12; k++) {
        size_t dlen = (size_t)(rnd() % 71);
        size_t slen = (size_t)(rnd() % 71);
        fill(src, 80);
        fill(dst, 80);
        mix((*squashes[q])(dst, dlen, src, slen, nonpremul != 0));
        mix_bytes(dst, 80);
        calls++;
      }
    }
    mark();
  }
  end("Row_Fuzz");
  count("Row_Fuzz_Calls", calls);
}

int main(void) {
  sweep_colors();
  sweep_formats();
  sweep_pixbuf_len_edges();
  sweep_tables();
  sweep_pixel_buffer_set();
  sweep_pixel_buffer_colors();
  sweep_pixel_buffer_elementless();
  sweep_pixel_buffer_strides();
  sweep_pixel_buffer_opaque();
  sweep_swizzler_prepare();
  sweep_swizzler_rows();
  sweep_swizzler_reader();
  sweep_row_fuzz();
  return 0;
}
