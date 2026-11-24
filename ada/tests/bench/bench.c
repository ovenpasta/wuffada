// Part of wuffada (wuffs-ada: Wuffs to Ada).
// SPDX-License-Identifier: Apache-2.0 OR MIT

// The C side of the benchmark: the same measurements as
// ada/tests/bench_main.adb, with upstream's C decoders. See run.sh.
// Output: KIND PATH BYTES BEST-NS CHECKSUM MEDIAN-NS.

#define _POSIX_C_SOURCE 200809L
#include <inttypes.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#define WUFFS_IMPLEMENTATION
#define WUFFS_CONFIG__MODULES
#define WUFFS_CONFIG__MODULE__BASE
#define WUFFS_CONFIG__MODULE__ADLER32
#define WUFFS_CONFIG__MODULE__BZIP2
#define WUFFS_CONFIG__MODULE__CRC32
#define WUFFS_CONFIG__MODULE__CRC64
#define WUFFS_CONFIG__MODULE__DEFLATE
#define WUFFS_CONFIG__MODULE__GIF
#define WUFFS_CONFIG__MODULE__GZIP
#define WUFFS_CONFIG__MODULE__PNG
#define WUFFS_CONFIG__MODULE__JPEG
#define WUFFS_CONFIG__MODULE__JSON
#define WUFFS_CONFIG__MODULE__LZMA
#define WUFFS_CONFIG__MODULE__SHA256
#define WUFFS_CONFIG__MODULE__VP8
#define WUFFS_CONFIG__MODULE__WEBP
#define WUFFS_CONFIG__MODULE__XZ
#define WUFFS_CONFIG__MODULE__ZLIB
#include "wuffs-unsupported-snapshot.c"

#define CAP_FILE (4 * 1024 * 1024)
#define CAP_PIX (40 * 1024 * 1024)
static uint8_t g_file[CAP_FILE];
static uint8_t g_pix[CAP_PIX];
static uint8_t g_work[CAP_PIX];
static size_t g_len;
static uint64_t g_result;
static int g_failed;

static wuffs_adler32__hasher g_adler;
static wuffs_crc64__ecma_hasher g_crc64;
static wuffs_crc32__ieee_hasher g_crc;
static wuffs_gzip__decoder g_gzip;
static wuffs_bzip2__decoder g_bzip2;
static wuffs_lzma__decoder g_lzma;
static wuffs_xz__decoder g_xz;
static wuffs_png__decoder g_png;
static wuffs_jpeg__decoder g_jpeg;
static wuffs_gif__decoder g_gif;
static wuffs_webp__decoder g_webp;
static wuffs_json__decoder g_json;
#define CAP_TOK (4 * 1024 * 1024)
static wuffs_base__token g_tok[CAP_TOK];

static uint64_t fnv(uint64_t h, const uint8_t* p, size_t n) {
  for (size_t i = 0; i < n; i++) {
    h = (h ^ p[i]) * 0x100000001B3ull;
  }
  return h;
}

static void decode_image(wuffs_base__image_decoder* d) {
  wuffs_base__io_buffer src = wuffs_base__ptr_u8__reader(g_file, g_len, true);
  wuffs_base__image_config ic = wuffs_base__null_image_config();
  wuffs_base__status st = wuffs_base__image_decoder__decode_image_config(d, &ic, &src);
  if (st.repr) {
    g_failed = 1;
    return;
  }
  uint32_t w = wuffs_base__pixel_config__width(&ic.pixcfg);
  uint32_t h = wuffs_base__pixel_config__height(&ic.pixcfg);
  wuffs_base__pixel_config pc = wuffs_base__null_pixel_config();
  wuffs_base__pixel_config__set(&pc, WUFFS_BASE__PIXEL_FORMAT__BGRA_PREMUL, 0, w, h);
  uint64_t n = (uint64_t)w * h * 4;
  uint64_t work = wuffs_base__image_decoder__workbuf_len(d).max_incl;
  if (n > CAP_PIX || work > CAP_PIX) {
    g_failed = 1;
    return;
  }
  wuffs_base__pixel_buffer pb;
  wuffs_base__pixel_buffer__set_from_slice(&pb, &pc, wuffs_base__make_slice_u8(g_pix, (size_t)n));
  uint64_t frames = 0;
  while (1) {
    wuffs_base__frame_config fc = wuffs_base__null_frame_config();
    st = wuffs_base__image_decoder__decode_frame_config(d, &fc, &src);
    if (st.repr) {
      break;
    }
    st = wuffs_base__image_decoder__decode_frame(
        d, &pb, &src, WUFFS_BASE__PIXEL_BLEND__SRC,
        wuffs_base__make_slice_u8(g_work, (size_t)work), NULL);
    if (st.repr) {
      break;
    }
    frames++;
  }
  if (st.repr != wuffs_base__note__end_of_data) {
    g_failed = 1;
  }
  g_result = n * 1000 + frames;
}

// Decompresses g_file into g_pix in one call, with all of g_work as the
// work buffer (more than any of these decoders asks for).
static void transform(wuffs_base__io_transformer* t) {
  wuffs_base__io_buffer src = wuffs_base__ptr_u8__reader(g_file, g_len, true);
  wuffs_base__io_buffer dst = wuffs_base__ptr_u8__writer(g_pix, CAP_PIX);
  wuffs_base__status st = wuffs_base__io_transformer__transform_io(
      t, &dst, &src, wuffs_base__make_slice_u8(g_work, CAP_PIX));
  if (st.repr) {
    g_failed = 1;
  }
  g_result = dst.meta.wi;
}

static void once(const char* kind) {
  wuffs_base__slice_u8 s = wuffs_base__make_slice_u8(g_file, g_len);
  if (!strcmp(kind, "crc32")) {
    if (wuffs_crc32__ieee_hasher__initialize(&g_crc, sizeof g_crc, WUFFS_VERSION, 0).repr) {
      g_failed = 1;
    }
    g_result = wuffs_crc32__ieee_hasher__update_u32(&g_crc, s);
  } else if (!strcmp(kind, "adler32")) {
    if (wuffs_adler32__hasher__initialize(&g_adler, sizeof g_adler, WUFFS_VERSION, 0).repr) {
      g_failed = 1;
    }
    g_result = wuffs_adler32__hasher__update_u32(&g_adler, s);
  } else if (!strcmp(kind, "crc64")) {
    if (wuffs_crc64__ecma_hasher__initialize(&g_crc64, sizeof g_crc64, WUFFS_VERSION, 0).repr) {
      g_failed = 1;
    }
    g_result = wuffs_crc64__ecma_hasher__update_u64(&g_crc64, s);
  } else if (!strcmp(kind, "gzip")) {
    wuffs_base__io_buffer src = wuffs_base__ptr_u8__reader(g_file, g_len, true);
    wuffs_base__io_buffer dst = wuffs_base__ptr_u8__writer(g_pix, CAP_PIX);
    uint8_t work[1] = {0};
    if (wuffs_gzip__decoder__initialize(&g_gzip, sizeof g_gzip, WUFFS_VERSION, 0).repr) {
      g_failed = 1;
    }
    wuffs_base__status st = wuffs_gzip__decoder__transform_io(
        &g_gzip, &dst, &src, wuffs_base__make_slice_u8(work, 1));
    if (st.repr) {
      g_failed = 1;
    }
    g_result = dst.meta.wi;
  } else if (!strcmp(kind, "bzip2")) {
    if (wuffs_bzip2__decoder__initialize(&g_bzip2, sizeof g_bzip2, WUFFS_VERSION, 0).repr) {
      g_failed = 1;
    }
    transform(wuffs_bzip2__decoder__upcast_as__wuffs_base__io_transformer(&g_bzip2));
  } else if (!strcmp(kind, "lzma")) {
    if (wuffs_lzma__decoder__initialize(&g_lzma, sizeof g_lzma, WUFFS_VERSION, 0).repr) {
      g_failed = 1;
    }
    transform(wuffs_lzma__decoder__upcast_as__wuffs_base__io_transformer(&g_lzma));
  } else if (!strcmp(kind, "xz")) {
    if (wuffs_xz__decoder__initialize(&g_xz, sizeof g_xz, WUFFS_VERSION, 0).repr) {
      g_failed = 1;
    }
    transform(wuffs_xz__decoder__upcast_as__wuffs_base__io_transformer(&g_xz));
  } else if (!strcmp(kind, "png")) {
    if (wuffs_png__decoder__initialize(&g_png, sizeof g_png, WUFFS_VERSION, 0).repr) {
      g_failed = 1;
    }
    decode_image(wuffs_png__decoder__upcast_as__wuffs_base__image_decoder(&g_png));
  } else if (!strcmp(kind, "gif")) {
    if (wuffs_gif__decoder__initialize(&g_gif, sizeof g_gif, WUFFS_VERSION, 0).repr) {
      g_failed = 1;
    }
    decode_image(wuffs_gif__decoder__upcast_as__wuffs_base__image_decoder(&g_gif));
  } else if (!strcmp(kind, "jpeg")) {
    if (wuffs_jpeg__decoder__initialize(&g_jpeg, sizeof g_jpeg, WUFFS_VERSION, 0).repr) {
      g_failed = 1;
    }
    decode_image(wuffs_jpeg__decoder__upcast_as__wuffs_base__image_decoder(&g_jpeg));
  } else if (!strcmp(kind, "json")) {
    wuffs_base__io_buffer src = wuffs_base__ptr_u8__reader(g_file, g_len, true);
    wuffs_base__token_buffer dst =
        wuffs_base__slice_token__writer(wuffs_base__make_slice_token(g_tok, CAP_TOK));
    uint8_t work[1] = {0};
    if (wuffs_json__decoder__initialize(&g_json, sizeof g_json, WUFFS_VERSION, 0).repr) {
      g_failed = 1;
    }
    wuffs_base__status st = wuffs_json__decoder__decode_tokens(
        &g_json, &dst, &src, wuffs_base__make_slice_u8(work, 1));
    if (st.repr) {
      g_failed = 1;
    }
    g_result = dst.meta.wi;
  } else if (!strcmp(kind, "webp")) {
    if (wuffs_webp__decoder__initialize(&g_webp, sizeof g_webp, WUFFS_VERSION, 0).repr) {
      g_failed = 1;
    }
    decode_image(wuffs_webp__decoder__upcast_as__wuffs_base__image_decoder(&g_webp));
  }
}

int main(void) {
  char line[4096], kind[32], path[4000];
  int reps;
  while (fgets(line, sizeof line, stdin)) {
    if (sscanf(line, "%31s %d %3999s", kind, &reps, path) != 3) {
      continue;
    }
    FILE* f = fopen(path, "rb");
    if (!f) {
      fprintf(stderr, "bench: cannot open %s\n", path);
      return 1;
    }
    g_len = fread(g_file, 1, CAP_FILE, f);
    fclose(f);
    int64_t best = INT64_MAX;
    int64_t times[200];
    if (reps > 200) {
      reps = 200;
    }
    for (int r = 0; r < reps; r++) {
      struct timespec t0, t1;
      clock_gettime(CLOCK_MONOTONIC, &t0);
      once(kind);
      clock_gettime(CLOCK_MONOTONIC, &t1);
      int64_t ns = (int64_t)(t1.tv_sec - t0.tv_sec) * 1000000000 + (t1.tv_nsec - t0.tv_nsec);
      if (ns < best) {
        best = ns;
      }
      times[r] = ns;
    }
    // The median, for the spread of the measurements.
    for (int i = 1; i < reps; i++) {
      for (int j = i; j > 0 && times[j - 1] > times[j]; j--) {
        int64_t x = times[j];
        times[j] = times[j - 1];
        times[j - 1] = x;
      }
    }
    int64_t median = times[reps / 2];
    uint64_t check = 0xCBF29CE484222325ull;
    if (!strcmp(kind, "gzip") || !strcmp(kind, "bzip2") || !strcmp(kind, "lzma") ||
        !strcmp(kind, "xz")) {
      check = fnv(check, g_pix, (size_t)g_result);
    } else if (!strcmp(kind, "json")) {
      check = fnv(check, (const uint8_t*)g_tok, (size_t)g_result * 8);
    } else if (!strcmp(kind, "png") || !strcmp(kind, "gif") || !strcmp(kind, "jpeg") ||
               !strcmp(kind, "webp")) {
      check = fnv(check, g_pix, (size_t)(g_result / 1000)) + g_result % 1000;
    } else {
      check = g_result;
    }
    printf("%s %s %zu %" PRId64 " %" PRIu64 " %" PRId64 "\n", kind, path, g_len, best, check,
           median);
  }
  if (g_failed) {
    fprintf(stderr, "bench: a decoder failed\n");
  }
  return 0;
}
