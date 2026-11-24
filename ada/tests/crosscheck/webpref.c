// Part of wuffada (wuffs-ada: Wuffs to Ada).
// SPDX-License-Identifier: Apache-2.0 OR MIT

// webpref: decodes WebP files with libwebp (the reference implementation,
// independent of Wuffs) and writes, for each file it can decode, the
// reference-pixels file that ada/tests/test_image.adb compares a frame with:
// four 32-bit little-endian numbers (the frame's bounds: 0, 0, width,
// height) and then the pixels as BGRA, not premultiplied. libwebp's default
// options: "fancy" chroma upsampling for lossy images.
//
// An animated file (the VP8X animation flag) is decoded with libwebp's
// WebPAnimDecoder (libwebpdemux) instead, which composites the frames onto
// the canvas (blending, disposal, its key-frame shortcuts, a transparent
// background): its reference file is three 32-bit little-endian numbers
// (the canvas width and height, the number of frames N) and then N canvases
// as BGRA, not premultiplied, one after each frame. test_image.adb (flag A)
// composites Wuffs' frames the same way and compares after each frame.
//
// usage: webpref OUTDIR < LIST
//
// LIST has one path per line. The output for PATH is OUTDIR/N.libwebp (or,
// for an animation, OUTDIR/N.libwebpanim), where N is the line number (from
// 1), and a line "N PATH ok", "N PATH anim" or "N PATH fail" is printed for
// each. test.sh builds this with libwebp (cc ... -lwebpdemux -lwebp).

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include <webp/decode.h>
#include <webp/demux.h>

#define CAP (8 * 1024 * 1024)

static uint8_t g_file[CAP];

static void put32(FILE* f, uint32_t v) {
  uint8_t b[4] = {(uint8_t)v, (uint8_t)(v >> 8), (uint8_t)(v >> 16), (uint8_t)(v >> 24)};
  fwrite(b, 1, 4, f);
}

// anim writes OUTDIR/N.libwebpanim for an animated file and returns whether
// libwebp decoded all of its frames. The canvases are capped at CAP bytes.
static int anim(const char* outdir, int n, size_t size) {
  WebPData data = {g_file, size};
  WebPAnimDecoderOptions opts;
  if (!WebPAnimDecoderOptionsInit(&opts)) {
    return 0;
  }
  opts.color_mode = MODE_BGRA;
  opts.use_threads = 0;
  WebPAnimDecoder* dec = WebPAnimDecoderNew(&data, &opts);
  if (!dec) {
    return 0;
  }
  WebPAnimInfo info;
  int ok = WebPAnimDecoderGetInfo(dec, &info);
  size_t canvas = (size_t)info.canvas_width * info.canvas_height * 4;
  if (!ok || ((size_t)info.frame_count * canvas > CAP)) {
    WebPAnimDecoderDelete(dec);
    return 0;
  }
  char out[4200];
  snprintf(out, sizeof out, "%s/%d.libwebpanim", outdir, n);
  FILE* o = fopen(out, "wb");
  if (!o) {
    fprintf(stderr, "webpref: cannot write %s\n", out);
    exit(1);
  }
  put32(o, info.canvas_width);
  put32(o, info.canvas_height);
  put32(o, info.frame_count);
  uint32_t frames = 0;
  while (WebPAnimDecoderHasMoreFrames(dec)) {
    uint8_t* pix;
    int timestamp;
    if (!WebPAnimDecoderGetNext(dec, &pix, &timestamp)) {
      ok = 0;
      break;
    }
    fwrite(pix, 1, canvas, o);
    frames++;
  }
  ok = ok && (frames == info.frame_count);
  if (fclose(o)) {
    fprintf(stderr, "webpref: cannot write %s\n", out);
    exit(1);
  }
  WebPAnimDecoderDelete(dec);
  return ok;
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
    WebPBitstreamFeatures features;
    if ((WebPGetFeatures(g_file, size, &features) == VP8_STATUS_OK) && features.has_animation) {
      printf("%d %s %s\n", n, line, anim(argv[1], n, size) ? "anim" : "fail");
      continue;
    }
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
