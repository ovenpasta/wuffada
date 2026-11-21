// Part of wuffada (wuffs-ada: Wuffs to Ada).
// SPDX-License-Identifier: Apache-2.0 OR MIT

// webpenc: encodes raw RGBA pixels with libwebp's advanced API, exposing the
// WebPConfig knobs that cwebp would (loop filter type, strength and
// sharpness, segments, token partitions, alpha compression and filtering,
// lossless effort...). Used by make.py in this directory only; the files it
// made are checked in.
//
// usage: webpenc W H IN.rgba OUT.webp [key=value...]
//
// IN.rgba is W*H*4 bytes, row by row. Keys: lossless, quality, method,
// filter_strength, filter_sharpness, filter_type, autofilter, segments,
// sns_strength, partitions, alpha_compression, alpha_filtering,
// alpha_quality, exact, near_lossless, preprocessing, use_sharp_yuv,
// rgb (1: import as RGB, ignoring alpha).

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include <webp/encode.h>

int main(int argc, char** argv) {
  if (argc < 5) {
    fprintf(stderr, "usage: webpenc W H IN.rgba OUT.webp [key=value...]\n");
    return 1;
  }
  int w = atoi(argv[1]);
  int h = atoi(argv[2]);
  size_t n = (size_t)w * (size_t)h * 4;
  uint8_t* rgba = malloc(n ? n : 1);
  FILE* f = fopen(argv[3], "rb");
  if (!f || fread(rgba, 1, n, f) != n) {
    fprintf(stderr, "webpenc: cannot read %s\n", argv[3]);
    return 1;
  }
  fclose(f);

  WebPConfig config;
  if (!WebPConfigInit(&config)) {
    return 1;
  }
  int rgb = 0;
  for (int i = 5; i < argc; i++) {
    char* eq = strchr(argv[i], '=');
    if (!eq) {
      fprintf(stderr, "webpenc: bad option %s\n", argv[i]);
      return 1;
    }
    *eq = 0;
    const char* k = argv[i];
    double v = atof(eq + 1);
    if (!strcmp(k, "lossless")) config.lossless = (int)v;
    else if (!strcmp(k, "quality")) config.quality = (float)v;
    else if (!strcmp(k, "method")) config.method = (int)v;
    else if (!strcmp(k, "filter_strength")) config.filter_strength = (int)v;
    else if (!strcmp(k, "filter_sharpness")) config.filter_sharpness = (int)v;
    else if (!strcmp(k, "filter_type")) config.filter_type = (int)v;
    else if (!strcmp(k, "autofilter")) config.autofilter = (int)v;
    else if (!strcmp(k, "segments")) config.segments = (int)v;
    else if (!strcmp(k, "sns_strength")) config.sns_strength = (int)v;
    else if (!strcmp(k, "partitions")) config.partitions = (int)v;
    else if (!strcmp(k, "alpha_compression")) config.alpha_compression = (int)v;
    else if (!strcmp(k, "alpha_filtering")) config.alpha_filtering = (int)v;
    else if (!strcmp(k, "alpha_quality")) config.alpha_quality = (int)v;
    else if (!strcmp(k, "exact")) config.exact = (int)v;
    else if (!strcmp(k, "near_lossless")) config.near_lossless = (int)v;
    else if (!strcmp(k, "preprocessing")) config.preprocessing = (int)v;
    else if (!strcmp(k, "use_sharp_yuv")) config.use_sharp_yuv = (int)v;
    else if (!strcmp(k, "rgb")) rgb = (int)v;
    else {
      fprintf(stderr, "webpenc: unknown option %s\n", k);
      return 1;
    }
  }
  if (!WebPValidateConfig(&config)) {
    fprintf(stderr, "webpenc: invalid configuration\n");
    return 1;
  }

  WebPPicture pic;
  if (!WebPPictureInit(&pic)) {
    return 1;
  }
  pic.width = w;
  pic.height = h;
  pic.use_argb = config.lossless;
  int ok;
  if (rgb) {
    uint8_t* p = malloc(n ? n : 1);
    for (size_t i = 0, j = 0; i < n; i += 4, j += 3) {
      p[j] = rgba[i];
      p[j + 1] = rgba[i + 1];
      p[j + 2] = rgba[i + 2];
    }
    ok = WebPPictureImportRGB(&pic, p, w * 3);
    free(p);
  } else {
    ok = WebPPictureImportRGBA(&pic, rgba, w * 4);
  }
  if (!ok) {
    fprintf(stderr, "webpenc: import failed\n");
    return 1;
  }
  WebPMemoryWriter wr;
  WebPMemoryWriterInit(&wr);
  pic.writer = WebPMemoryWrite;
  pic.custom_ptr = &wr;
  if (!WebPEncode(&config, &pic)) {
    fprintf(stderr, "webpenc: encode failed: %d\n", pic.error_code);
    return 1;
  }
  f = fopen(argv[4], "wb");
  if (!f || fwrite(wr.mem, 1, wr.size, f) != wr.size || fclose(f)) {
    fprintf(stderr, "webpenc: cannot write %s\n", argv[4]);
    return 1;
  }
  WebPMemoryWriterClear(&wr);
  WebPPictureFree(&pic);
  free(rgba);
  return 0;
}
