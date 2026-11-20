// Part of wuffada (wuffs-ada: Wuffs to Ada).
// SPDX-License-Identifier: Apache-2.0 OR MIT

// The C side of the image decoder cross-check: it runs upstream's C decoders
// (wuffs/release/c/wuffs-unsupported-snapshot.c) for netpbm, bmp, gif, png,
// wbmp, nie, targa, jpeg and the others over the same manifest, with the same calls, the same source buffer
// handling and the same pixel buffers as ada/tests/test_image.adb, and
// prints the same trace lines. See run_image.sh, which builds and runs this.
// Keep it in step with test_image.adb.
//
// usage: image STATUS_TABLE < MANIFEST
//
// A manifest line (see ada/tests/imgcorpus/main.go) is
//
//   FORMAT PIXFMT BLEND SCHEDULE FLAGS SCRIPT EXPECTED PATH
//
// and a trace line is "= CASE WHAT key=value ...".

#include <inttypes.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define WUFFS_IMPLEMENTATION
#define WUFFS_CONFIG__MODULES
#define WUFFS_CONFIG__MODULE__BASE
#define WUFFS_CONFIG__MODULE__ADLER32
#define WUFFS_CONFIG__MODULE__BMP
#define WUFFS_CONFIG__MODULE__CRC32
#define WUFFS_CONFIG__MODULE__DEFLATE
#define WUFFS_CONFIG__MODULE__GIF
#define WUFFS_CONFIG__MODULE__NETPBM
#define WUFFS_CONFIG__MODULE__NIE
#define WUFFS_CONFIG__MODULE__PNG
#define WUFFS_CONFIG__MODULE__TARGA
#define WUFFS_CONFIG__MODULE__WBMP
#define WUFFS_CONFIG__MODULE__QOI
#define WUFFS_CONFIG__MODULE__ETC2
#define WUFFS_CONFIG__MODULE__THUMBHASH
#define WUFFS_CONFIG__MODULE__HANDSUM
#define WUFFS_CONFIG__MODULE__JPEG
#define WUFFS_CONFIG__MODULE__ZLIB
#include "wuffs-unsupported-snapshot.c"

#define CAP_FILE (4 * 1024 * 1024)
#define CAP_PIX (40 * 1024 * 1024)
#define CAP_WORK (40 * 1024 * 1024)
#define WINDOW 4096
#define OUT_LENGTH 4096
#define MAX_FRAMES 400
#define MAX_QUIRKS 8

static uint8_t g_file[CAP_FILE];
static uint8_t g_src[CAP_FILE + WINDOW];
static uint8_t g_pix[CAP_PIX];
static uint8_t g_work[CAP_WORK];
static uint8_t g_out[OUT_LENGTH];

static wuffs_netpbm__decoder g_netpbm;
static wuffs_bmp__decoder g_bmp;
static wuffs_gif__decoder g_gif;
static wuffs_png__decoder g_png;
static wuffs_wbmp__decoder g_wbmp;
static wuffs_nie__decoder g_nie;
static wuffs_targa__decoder g_targa;
static wuffs_qoi__decoder g_qoi;
static wuffs_etc2__decoder g_etc2;
static wuffs_thumbhash__decoder g_thumbhash;
static wuffs_handsum__decoder g_handsum;
static wuffs_jpeg__decoder g_jpeg;

// ---- The status table.

#define MAX_STATUSES 512
static struct {
  uint64_t category;
  uint64_t code;
  char text[128];
} g_statuses[MAX_STATUSES];
static int g_num_statuses = 0;

static void load_statuses(const char* filename) {
  FILE* f = fopen(filename, "r");
  if (!f) {
    fprintf(stderr, "image: cannot open %s\n", filename);
    exit(1);
  }
  char line[256];
  while (fgets(line, sizeof line, f)) {
    if (g_num_statuses >= MAX_STATUSES) {
      fprintf(stderr, "image: too many statuses\n");
      exit(1);
    }
    char* end = NULL;
    g_statuses[g_num_statuses].category = strtoull(line, &end, 10);
    g_statuses[g_num_statuses].code = strtoull(end, &end, 10);
    while (*end == ' ') {
      end++;
    }
    size_t n = strlen(end);
    while (n > 0 && (end[n - 1] == '\n' || end[n - 1] == '\r')) {
      end[--n] = 0;
    }
    snprintf(g_statuses[g_num_statuses].text,
             sizeof g_statuses[g_num_statuses].text, "%s", end);
    g_num_statuses++;
  }
  fclose(f);
}

static void put_status(wuffs_base__status s) {
  if (!s.repr) {
    printf(" st=0:0");
    return;
  }
  for (int i = 0; i < g_num_statuses; i++) {
    if (!strcmp(g_statuses[i].text, s.repr)) {
      printf(" st=%" PRIu64 ":%" PRIu64, g_statuses[i].category,
             g_statuses[i].code);
      return;
    }
  }
  fprintf(stderr, "image: status \"%s\" is not in the table\n", s.repr);
  exit(1);
}

static void kv(const char* key, uint64_t value) {
  printf(" %s=%" PRIu64, key, value);
}

// ---- A run.

typedef struct {
  int id;
  uint32_t pixfmt;
  int blend;
  char sched;  // 'W', 'C' or 'K'.
  size_t chunk;
  int meta;
  int small_pix;
  int small_work;
  uint32_t quirks[MAX_QUIRKS];
  uint64_t values[MAX_QUIRKS];
  int num_quirks;
} run_case;

static run_case g_run;
static wuffs_base__image_decoder* g_dec;
static size_t g_len;
static size_t g_fed;
static wuffs_base__io_buffer g_sb;
static wuffs_base__pixel_buffer g_pb;
static int g_have_pb;
static uint64_t g_ffio;

static uint64_t fnv(uint64_t h, const uint8_t* p, size_t n) {
  for (size_t i = 0; i < n; i++) {
    h = (h ^ p[i]) * 0x100000001B3ull;
  }
  return h;
}

static uint64_t fnv_u64(uint64_t h, uint64_t x) {
  for (int i = 0; i < 8; i++) {
    h = (h ^ (x & 0xFF)) * 0x100000001B3ull;
    x >>= 8;
  }
  return h;
}

#define FNV_START 0xCBF29CE484222325ull

static uint64_t position(void) {
  return g_sb.meta.pos + g_sb.meta.ri;
}

static void src_begin(void) {
  g_fed = 0;
  g_sb.data.ptr = g_src;
  g_sb.meta.ri = 0;
  g_sb.meta.pos = 0;
  if (g_run.sched == 'K') {
    g_sb.data.len = WINDOW;
    g_sb.meta.wi = 0;
    g_sb.meta.closed = g_len == 0;
    return;
  }
  memcpy(g_src, g_file, g_len);
  g_sb.data.len = g_len;
  g_sb.meta.wi = g_len;
  if (g_run.sched == 'C' && g_run.chunk < g_len) {
    g_sb.meta.wi = g_run.chunk;
  }
  g_sb.meta.closed = g_sb.meta.wi == g_len;
}

static void src_seek(uint64_t at) {
  if (at > g_len) {
    at = g_len;
  }
  if (g_run.sched == 'K') {
    g_sb.meta.ri = 0;
    g_sb.meta.wi = 0;
    g_sb.meta.pos = at;
    g_fed = (size_t)at;
    g_sb.meta.closed = g_fed == g_len;
    return;
  }
  g_sb.meta.ri = (size_t)at;
  if (g_sb.meta.wi < g_sb.meta.ri) {
    g_sb.meta.wi = g_sb.meta.ri;
  }
  g_sb.meta.closed = g_sb.meta.wi == g_len;
}

// Makes more of the file available. Returns 0 if it cannot.
static int src_feed(void) {
  if (g_sb.meta.closed) {
    return 0;
  }
  if (g_run.sched == 'C') {
    size_t add = g_len - g_sb.meta.wi;
    if (add > g_run.chunk) {
      add = g_run.chunk;
    }
    g_sb.meta.wi += add;
    g_sb.meta.closed = g_sb.meta.wi == g_len;
    return 1;
  }
  if (g_run.sched == 'K') {
    size_t n = g_sb.meta.wi - g_sb.meta.ri;
    memmove(g_src, g_src + g_sb.meta.ri, n);
    g_sb.meta.pos += g_sb.meta.ri;
    g_sb.meta.ri = 0;
    g_sb.meta.wi = n;
    size_t add = g_run.chunk;
    if (add > WINDOW - n) {
      add = WINDOW - n;
    }
    if (add > g_len - g_fed) {
      add = g_len - g_fed;
    }
    if (add == 0) {
      return 0;
    }
    memcpy(g_src + n, g_file + g_fed, add);
    g_sb.meta.wi += add;
    g_fed += add;
    g_sb.meta.closed = g_fed == g_len;
    return 1;
  }
  return 0;
}

static void tell_more(void) {
  for (int i = 0; i < 100000; i++) {
    wuffs_base__more_information mi = wuffs_base__empty_more_information();
    wuffs_base__io_buffer ob;
    memset(&ob, 0, sizeof ob);
    ob.data.ptr = g_out;
    ob.data.len = OUT_LENGTH;
    wuffs_base__status st =
        wuffs_base__image_decoder__tell_me_more(g_dec, &ob, &mi, &g_sb);
    printf("= %d T", g_run.id);
    put_status(st);
    kv("ri", position());
    kv("wi", ob.meta.wi);
    kv("fl", mi.flavor);
    kv("w", mi.w);
    kv("x", mi.x);
    kv("y", mi.y);
    kv("z", mi.z);
    kv("out", fnv(FNV_START, g_out, ob.meta.wi));
    printf("\n");
    if (!st.repr) {
      break;
    } else if (!wuffs_base__status__is_suspension(&st)) {
      break;
    } else if (mi.flavor == WUFFS_BASE__MORE_INFORMATION__FLAVOR__IO_SEEK) {
      src_seek(mi.x);
    } else if (st.repr == wuffs_base__suspension__short_read) {
      if (!src_feed()) {
        break;
      }
    }
  }
}

static void setup_pb(uint32_t w, uint32_t h) {
  if (g_run.small_pix) {
    w = (w + 1) / 2;
    h = (h + 1) / 2;
  }
  wuffs_base__pixel_config pc = wuffs_base__null_pixel_config();
  wuffs_base__pixel_config__set(&pc, g_run.pixfmt, 0, w, h);
  uint64_t n = wuffs_base__pixel_config__pixbuf_len(&pc);
  g_have_pb = 0;
  printf("= %d pb", g_run.id);
  if (n > CAP_PIX) {
    printf(" toobig\n");
    return;
  }
  wuffs_base__status st = wuffs_base__pixel_buffer__set_from_slice(
      &g_pb, &pc, wuffs_base__make_slice_u8(g_pix, (size_t)n));
  put_status(st);
  kv("w", w);
  kv("h", h);
  printf("\n");
  if (st.repr) {
    return;
  }
  g_have_pb = 1;
  wuffs_base__slice_u8 pal = wuffs_base__pixel_buffer__palette(&g_pb);
  for (size_t i = 0; i < pal.len; i++) {
    pal.ptr[i] = (uint8_t)(i * 5 + 1);
  }
  wuffs_base__table_u8 tab = wuffs_base__pixel_buffer__plane(&g_pb, 0);
  for (size_t y = 0; y < tab.height; y++) {
    uint8_t* row = tab.ptr + y * tab.stride;
    for (size_t x = 0; x < tab.width; x++) {
      row[x] = (uint8_t)(x * 7 + y * 13 + 3);
    }
  }
}

static void put_pixels(void) {
  uint64_t pix = FNV_START;
  uint64_t pal = FNV_START;
  if (g_have_pb) {
    wuffs_base__slice_u8 p = wuffs_base__pixel_buffer__palette(&g_pb);
    pal = fnv(pal, p.ptr, p.len);
    wuffs_base__table_u8 tab = wuffs_base__pixel_buffer__plane(&g_pb, 0);
    for (size_t y = 0; y < tab.height; y++) {
      pix = fnv(pix, tab.ptr + y * tab.stride, tab.width);
    }
  }
  kv("pix", pix);
  kv("pal", pal);
}

static void put_counts(void) {
  kv("nfc", wuffs_base__image_decoder__num_decoded_frame_configs(g_dec));
  kv("nf", wuffs_base__image_decoder__num_decoded_frames(g_dec));
  kv("loops", wuffs_base__image_decoder__num_animation_loops(g_dec));
  wuffs_base__rect_ie_u32 d =
      wuffs_base__image_decoder__frame_dirty_rect(g_dec);
  kv("dx0", d.min_incl_x);
  kv("dy0", d.min_incl_y);
  kv("dx1", d.max_excl_x);
  kv("dy1", d.max_excl_y);
}

// Does one operation, calling the decoder as often as it takes, and prints
// its trace line. Returns the last status.
static wuffs_base__status run_op(char op) {
  wuffs_base__status st = wuffs_base__make_status(NULL);
  wuffs_base__image_config ic = wuffs_base__null_image_config();
  wuffs_base__frame_config fc = wuffs_base__null_frame_config();
  uint64_t calls = 0;
  uint64_t h = FNV_START;
  uint64_t limit = 4 * (uint64_t)g_len + 1000;
  size_t work_len = 0;

  if (op == 'F') {
    if (!g_have_pb) {
      setup_pb(16, 16);
    }
    wuffs_base__range_ii_u64 wl =
        wuffs_base__image_decoder__workbuf_len(g_dec);
    uint64_t n = wl.max_incl;
    if (g_run.small_work) {
      n = wl.min_incl ? (wl.min_incl - 1) : 0;
    }
    if (!g_have_pb || n > CAP_WORK) {
      printf("= %d F toobig\n", g_run.id);
      return wuffs_base__make_status(wuffs_base__error__bad_argument);
    }
    work_len = (size_t)n;
  }

  while (1) {
    switch (op) {
      case 'I':
        st = wuffs_base__image_decoder__decode_image_config(g_dec, &ic,
                                                            &g_sb);
        break;
      case 'i':
        st = wuffs_base__image_decoder__decode_image_config(g_dec, NULL,
                                                            &g_sb);
        break;
      case 'C':
        st = wuffs_base__image_decoder__decode_frame_config(g_dec, &fc,
                                                            &g_sb);
        break;
      case 'c':
        st = wuffs_base__image_decoder__decode_frame_config(g_dec, NULL,
                                                            &g_sb);
        break;
      case 'F':
        st = wuffs_base__image_decoder__decode_frame(
            g_dec, &g_pb, &g_sb, (wuffs_base__pixel_blend)g_run.blend,
            wuffs_base__make_slice_u8(g_work, work_len), NULL);
        break;
    }
    calls++;
    h = fnv_u64(h, wuffs_base__status__is_ok(&st)
                       ? 0
                       : (wuffs_base__status__is_suspension(&st) ? 1 : 2));
    h = fnv_u64(h, position());
    {
      // Also what a caller can see of a frame while it is suspended.
      wuffs_base__rect_ie_u32 d =
          wuffs_base__image_decoder__frame_dirty_rect(g_dec);
      h = fnv_u64(h, d.min_incl_x);
      h = fnv_u64(h, d.min_incl_y);
      h = fnv_u64(h, d.max_excl_x);
      h = fnv_u64(h, d.max_excl_y);
    }
    if (calls >= limit) {
      break;
    } else if (st.repr == wuffs_base__suspension__short_read) {
      if (!src_feed()) {
        break;
      }
    } else if (g_run.meta && st.repr == wuffs_base__note__metadata_reported) {
      tell_more();
    } else {
      break;
    }
  }

  printf("= %d %c", g_run.id, op);
  put_status(st);
  kv("n", calls);
  kv("h", h);
  kv("ri", position());
  if (op == 'I' && !st.repr) {
    kv("fmt", ic.pixcfg.private_impl.pixfmt.repr);
    kv("sub", ic.pixcfg.private_impl.pixsub.repr);
    kv("w", wuffs_base__pixel_config__width(&ic.pixcfg));
    kv("h", wuffs_base__pixel_config__height(&ic.pixcfg));
    kv("ffio", wuffs_base__image_config__first_frame_io_position(&ic));
    kv("opq", wuffs_base__image_config__first_frame_is_opaque(&ic));
    wuffs_base__range_ii_u64 wl =
        wuffs_base__image_decoder__workbuf_len(g_dec);
    kv("wlmin", wl.min_incl);
    kv("wlmax", wl.max_incl);
  } else if (op == 'C' && !st.repr) {
    wuffs_base__rect_ie_u32 b = wuffs_base__frame_config__bounds(&fc);
    kv("x0", b.min_incl_x);
    kv("y0", b.min_incl_y);
    kv("x1", b.max_excl_x);
    kv("y1", b.max_excl_y);
    kv("dur", wuffs_base__frame_config__duration(&fc));
    kv("idx", wuffs_base__frame_config__index(&fc));
    kv("io", wuffs_base__frame_config__io_position(&fc));
    kv("disp", wuffs_base__frame_config__disposal(&fc));
    kv("opq", wuffs_base__frame_config__opaque_within_bounds(&fc));
    kv("ovr", wuffs_base__frame_config__overwrite_instead_of_blend(&fc));
    kv("bg", wuffs_base__frame_config__background_color(&fc));
  } else if (op == 'F') {
    put_pixels();
  }
  put_counts();
  printf("\n");

  if (op == 'I' && !st.repr) {
    g_ffio = wuffs_base__image_config__first_frame_io_position(&ic);
    if (!g_have_pb) {
      setup_pb(wuffs_base__pixel_config__width(&ic.pixcfg),
               wuffs_base__pixel_config__height(&ic.pixcfg));
    }
  }
  return st;
}

static void run_script(const char* script) {
  for (const char* p = script; *p; p++) {
    wuffs_base__status st;
    switch (*p) {
      case '*':
        for (int i = 0; i < MAX_FRAMES; i++) {
          st = run_op('C');
          if (st.repr) {
            break;
          }
          st = run_op('F');
          if (st.repr) {
            break;
          }
        }
        break;
      case 'R':
      case 'r':
        st = (*p == 'R')
                 ? wuffs_base__image_decoder__restart_frame(g_dec, 0, g_ffio)
                 : wuffs_base__image_decoder__restart_frame(g_dec, 1, 0);
        printf("= %d %c", g_run.id, *p);
        put_status(st);
        put_counts();
        printf("\n");
        if (*p == 'R' && !st.repr) {
          src_seek(g_ffio);
        }
        break;
      case 'T':
        tell_more();
        break;
      default:
        run_op(*p);
        break;
    }
  }
}

static void initialize(const char* format) {
  wuffs_base__status st = wuffs_base__make_status(NULL);
  if (!strcmp(format, "netpbm")) {
    st = wuffs_netpbm__decoder__initialize(&g_netpbm, sizeof g_netpbm,
                                           WUFFS_VERSION, 0);
    g_dec = wuffs_netpbm__decoder__upcast_as__wuffs_base__image_decoder(
        &g_netpbm);
  } else if (!strcmp(format, "bmp")) {
    st = wuffs_bmp__decoder__initialize(&g_bmp, sizeof g_bmp, WUFFS_VERSION,
                                        0);
    g_dec = wuffs_bmp__decoder__upcast_as__wuffs_base__image_decoder(&g_bmp);
  } else if (!strcmp(format, "gif")) {
    st = wuffs_gif__decoder__initialize(&g_gif, sizeof g_gif, WUFFS_VERSION,
                                        0);
    g_dec = wuffs_gif__decoder__upcast_as__wuffs_base__image_decoder(&g_gif);
  } else if (!strcmp(format, "png")) {
    st = wuffs_png__decoder__initialize(&g_png, sizeof g_png, WUFFS_VERSION,
                                        0);
    g_dec = wuffs_png__decoder__upcast_as__wuffs_base__image_decoder(&g_png);
  } else if (!strcmp(format, "wbmp")) {
    st = wuffs_wbmp__decoder__initialize(&g_wbmp, sizeof g_wbmp, WUFFS_VERSION,
                                       0);
    g_dec = wuffs_wbmp__decoder__upcast_as__wuffs_base__image_decoder(&g_wbmp);
  } else if (!strcmp(format, "nie")) {
    st = wuffs_nie__decoder__initialize(&g_nie, sizeof g_nie, WUFFS_VERSION,
                                       0);
    g_dec = wuffs_nie__decoder__upcast_as__wuffs_base__image_decoder(&g_nie);
  } else if (!strcmp(format, "targa")) {
    st = wuffs_targa__decoder__initialize(&g_targa, sizeof g_targa, WUFFS_VERSION,
                                       0);
    g_dec = wuffs_targa__decoder__upcast_as__wuffs_base__image_decoder(&g_targa);
  } else if (!strcmp(format, "qoi")) {
    st = wuffs_qoi__decoder__initialize(&g_qoi, sizeof g_qoi, WUFFS_VERSION,
                                       0);
    g_dec = wuffs_qoi__decoder__upcast_as__wuffs_base__image_decoder(&g_qoi);
  } else if (!strcmp(format, "etc2")) {
    st = wuffs_etc2__decoder__initialize(&g_etc2, sizeof g_etc2, WUFFS_VERSION,
                                       0);
    g_dec = wuffs_etc2__decoder__upcast_as__wuffs_base__image_decoder(&g_etc2);
  } else if (!strcmp(format, "thumbhash")) {
    st = wuffs_thumbhash__decoder__initialize(&g_thumbhash, sizeof g_thumbhash, WUFFS_VERSION,
                                       0);
    g_dec = wuffs_thumbhash__decoder__upcast_as__wuffs_base__image_decoder(&g_thumbhash);
  } else if (!strcmp(format, "jpeg")) {
    st = wuffs_jpeg__decoder__initialize(&g_jpeg, sizeof g_jpeg, WUFFS_VERSION,
                                         0);
    g_dec = wuffs_jpeg__decoder__upcast_as__wuffs_base__image_decoder(&g_jpeg);
  } else if (!strcmp(format, "handsum")) {
    st = wuffs_handsum__decoder__initialize(&g_handsum, sizeof g_handsum, WUFFS_VERSION,
                                       0);
    g_dec = wuffs_handsum__decoder__upcast_as__wuffs_base__image_decoder(&g_handsum);
  } else {
    fprintf(stderr, "image: unknown format %s\n", format);
    exit(1);
  }
  if (st.repr) {
    fprintf(stderr, "image: initialize: %s\n", st.repr);
    exit(1);
  }
}

static const uint32_t g_fourccs[] = {
    0x4348524D,  // CHRM
    0x45584946,  // EXIF
    0x47414D41,  // GAMA
    0x49434350,  // ICCP
    0x4B565020,  // KVP
    0x53524742,  // SRGB
    0x584D5020,  // XMP
};

static void do_case(int id, char* line) {
  char format[32], sched[32], flags[256], script[64], expected[1024],
      path[1024];
  unsigned pixfmt = 0;
  int blend = 0;
  if (sscanf(line, "%31s %x %d %31s %255s %63s %1023s %1023s", format,
             &pixfmt, &blend, sched, flags, script, expected, path) != 8) {
    fprintf(stderr, "image: bad manifest line: %s\n", line);
    exit(1);
  }
  memset(&g_run, 0, sizeof g_run);
  g_run.id = id;
  g_run.pixfmt = pixfmt;
  g_run.blend = blend;
  g_run.sched = sched[0];
  g_run.chunk = (size_t)strtoull(sched + 1, NULL, 10);
  for (char* f = strtok(flags, ","); f; f = strtok(NULL, ",")) {
    if (!strcmp(f, "m")) {
      g_run.meta = 1;
    } else if (!strcmp(f, "p")) {
      g_run.small_pix = 1;
    } else if (!strcmp(f, "w")) {
      g_run.small_work = 1;
    } else if ((f[0] == 'q' || f[0] == 'Q') && g_run.num_quirks < MAX_QUIRKS) {
      g_run.values[g_run.num_quirks] = (f[0] == 'Q') ? 0x8000000000000000ull : 1;
      g_run.quirks[g_run.num_quirks++] = (uint32_t)strtoull(f + 1, NULL, 10);
    }
  }

  FILE* f = fopen(path, "rb");
  if (!f) {
    fprintf(stderr, "image: cannot open %s\n", path);
    exit(1);
  }
  g_len = fread(g_file, 1, CAP_FILE, f);
  if (fgetc(f) != EOF) {
    fprintf(stderr, "image: %s is too long\n", path);
    exit(1);
  }
  fclose(f);

  initialize(format);
  g_have_pb = 0;
  g_ffio = 0;
  for (int i = 0; i < g_run.num_quirks; i++) {
    wuffs_base__status st =
        wuffs_base__image_decoder__set_quirk(g_dec, g_run.quirks[i],
                                             g_run.values[i]);
    printf("= %d q", id);
    put_status(st);
    kv("key", g_run.quirks[i]);
    kv("get", wuffs_base__image_decoder__get_quirk(g_dec, g_run.quirks[i]));
    printf("\n");
  }
  if (g_run.meta) {
    for (size_t i = 0; i < sizeof g_fourccs / sizeof g_fourccs[0]; i++) {
      wuffs_base__image_decoder__set_report_metadata(g_dec, g_fourccs[i],
                                                     true);
    }
  }
  src_begin();
  run_script(script);
  printf("= %d end", id);
  put_counts();
  printf("\n");
}

int main(int argc, char** argv) {
  if (argc != 2) {
    fprintf(stderr, "usage: image STATUS_TABLE < MANIFEST\n");
    return 1;
  }
  load_statuses(argv[1]);
  static char line[4096];
  int id = 0;
  while (fgets(line, sizeof line, stdin)) {
    size_t n = strlen(line);
    while (n > 0 && (line[n - 1] == '\n' || line[n - 1] == '\r')) {
      line[--n] = 0;
    }
    if (n > 0) {
      do_case(++id, line);
    }
  }
  return 0;
}
