// Part of wuffada (wuffs-ada: Wuffs to Ada).
// SPDX-License-Identifier: Apache-2.0 OR MIT

// webpref: decodes WebP files with libwebp (the reference implementation,
// independent of Wuffs) and writes, for each file it can decode, the
// reference-pixels file that ada/tests/test_image.adb compares a frame with:
// four 32-bit little-endian numbers (the frame's bounds: 0, 0, width,
// height) and then the pixels as BGRA, not premultiplied. libwebp's default
// options: "fancy" chroma upsampling for lossy images.
//
// usage: webpref OUTDIR < LIST
//
// LIST has one path per line. The output for PATH is OUTDIR/N.libwebp, where
// N is the line number (from 1), and a line "N PATH ok" or "N PATH fail" is
// printed for each. test.sh builds this with libwebp (cc ... -lwebp).

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include <webp/decode.h>

#define CAP (8 * 1024 * 1024)

static uint8_t g_file[CAP];

static void put32(FILE* f, uint32_t v) {
  uint8_t b[4] = {(uint8_t)v, (uint8_t)(v >> 8), (uint8_t)(v >> 16), (uint8_t)(v >> 24)};
  fwrite(b, 1, 4, f);
}

int main(int argc, char** argv) {
  if (argc != 2) {
    fprintf(stderr, "usage: webpref OUTDIR < LIST\n");
    return 1;
  }
  static char line[4096];
  int n = 0;
  while (fgets(line, sizeof line, stdin)) {
    size_t len = strlen(line);
    while (len > 0 && (line[len - 1] == '\n' || line[len - 1] == '\r')) {
      line[--len] = 0;
    }
    if (len == 0) {
      continue;
    }
    n++;
    FILE* f = fopen(line, "rb");
    if (!f) {
      fprintf(stderr, "webpref: cannot open %s\n", line);
      return 1;
    }
    size_t size = fread(g_file, 1, CAP, f);
    fclose(f);
    int w = 0, h = 0;
    uint8_t* bgra = WebPDecodeBGRA(g_file, size, &w, &h);
    if (!bgra) {
      printf("%d %s fail\n", n, line);
      continue;
    }
    char out[4200];
    snprintf(out, sizeof out, "%s/%d.libwebp", argv[1], n);
    FILE* o = fopen(out, "wb");
    if (!o) {
      fprintf(stderr, "webpref: cannot write %s\n", out);
      return 1;
    }
    put32(o, 0);
    put32(o, 0);
    put32(o, (uint32_t)w);
    put32(o, (uint32_t)h);
    fwrite(bgra, 1, (size_t)w * (size_t)h * 4, o);
    if (fclose(o)) {
      fprintf(stderr, "webpref: cannot write %s\n", out);
      return 1;
    }
    WebPFree(bgra);
    printf("%d %s ok\n", n, line);
  }
  return 0;
}
