// Part of wuffada (wuffs-ada: Wuffs to Ada).
// SPDX-License-Identifier: Apache-2.0 OR MIT

// The C side of the decoder cross-check: it runs upstream's C decoders
// (wuffs/release/c/wuffs-unsupported-snapshot.c) for lzw, deflate, zlib and
// gzip over the same manifest, with the same schedules and the same buffer
// handling, as ada/tests/test_decode.adb, and prints the same trace lines.
// See run_decode.sh, which builds and runs this. Keep it in step with
// test_decode.adb.
//
// usage: decode STATUS_TABLE < MANIFEST
//
// STATUS_TABLE (from statustable) gives the Ada category and code of each
// C status string.

#include <inttypes.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define WUFFS_IMPLEMENTATION
#define WUFFS_CONFIG__MODULES
#define WUFFS_CONFIG__MODULE__BASE
#define WUFFS_CONFIG__MODULE__ADLER32
#define WUFFS_CONFIG__MODULE__CRC32
#define WUFFS_CONFIG__MODULE__DEFLATE
#define WUFFS_CONFIG__MODULE__GZIP
#define WUFFS_CONFIG__MODULE__LZW
#define WUFFS_CONFIG__MODULE__ZLIB
#include "wuffs-unsupported-snapshot.c"

#define CAPACITY (4 * 1024 * 1024)
#define REDUCED_ABOVE 60000
#define SRC_FIRST 5
#define DST_FIRST 1000
#define MAX_OUTPUT (8 * 1024 * 1024)
#define DICTIONARY_LENGTH 1000

static uint8_t g_input[CAPACITY];
static uint8_t g_src_work[CAPACITY];
static uint8_t g_dst_work[CAPACITY];
static uint8_t g_workbuf[1];
static uint8_t g_dictionary[DICTIONARY_LENGTH];

// What a manifest line asks for besides the decoder: see the format variants
// in ada/tests/corpus/main.go.
typedef struct {
  uint64_t literal_width;  // lzw2 .. lzw7
  int dictionary;          // 0 none, 1 the right one, 2 a wrong one
  int multi_member;        // gzipmulti
} variant;

static wuffs_lzw__decoder g_lzw;
static wuffs_deflate__decoder g_deflate;
static wuffs_zlib__decoder g_zlib;
static wuffs_gzip__decoder g_gzip;

// ---- The status table.

#define MAX_STATUSES 256
static struct {
  uint64_t category;
  uint64_t code;
  char text[128];
} g_statuses[MAX_STATUSES];
static int g_num_statuses = 0;

static void load_statuses(const char* filename) {
  FILE* f = fopen(filename, "r");
  if (!f) {
    fprintf(stderr, "decode: cannot open %s\n", filename);
    exit(1);
  }
  char line[256];
  while (fgets(line, sizeof line, f)) {
    if (g_num_statuses >= MAX_STATUSES) {
      fprintf(stderr, "decode: too many statuses\n");
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

static void lookup_status(wuffs_base__status s,
                          uint64_t* category,
                          uint64_t* code) {
  *category = 0;
  *code = 0;
  if (!s.repr) {
    return;
  }
  for (int i = 0; i < g_num_statuses; i++) {
    if (!strcmp(g_statuses[i].text, s.repr)) {
      *category = g_statuses[i].category;
      *code = g_statuses[i].code;
      return;
    }
  }
  fprintf(stderr, "decode: status \"%s\" is not in the table\n", s.repr);
  exit(1);
}

// ---- The decoders.

enum { FORMAT_LZW, FORMAT_DEFLATE, FORMAT_ZLIB, FORMAT_GZIP };

static void initialize(int format, variant v) {
  wuffs_base__status s = wuffs_base__make_status(NULL);
  switch (format) {
    case FORMAT_LZW:
      s = wuffs_lzw__decoder__initialize(&g_lzw, sizeof g_lzw, WUFFS_VERSION,
                                         0);
      if (!s.repr && v.literal_width != 8) {
        s = wuffs_lzw__decoder__set_quirk(
            &g_lzw, WUFFS_LZW__QUIRK_LITERAL_WIDTH_PLUS_ONE,
            v.literal_width + 1);
      }
      break;
    case FORMAT_DEFLATE:
      s = wuffs_deflate__decoder__initialize(&g_deflate, sizeof g_deflate,
                                             WUFFS_VERSION, 0);
      break;
    case FORMAT_ZLIB:
      s = wuffs_zlib__decoder__initialize(&g_zlib, sizeof g_zlib,
                                          WUFFS_VERSION, 0);
      break;
    case FORMAT_GZIP:
      s = wuffs_gzip__decoder__initialize(&g_gzip, sizeof g_gzip,
                                          WUFFS_VERSION, 0);
      break;
  }
  if (s.repr) {
    fprintf(stderr, "decode: initialize: %s\n", s.repr);
    exit(1);
  }
}

static wuffs_base__status call(int format,
                               wuffs_base__io_buffer* dst,
                               wuffs_base__io_buffer* src) {
  wuffs_base__slice_u8 workbuf = wuffs_base__make_slice_u8(g_workbuf, 1);
  switch (format) {
    case FORMAT_LZW:
      return wuffs_lzw__decoder__transform_io(&g_lzw, dst, src, workbuf);
    case FORMAT_DEFLATE:
      return wuffs_deflate__decoder__transform_io(&g_deflate, dst, src,
                                                  workbuf);
    case FORMAT_ZLIB:
      return wuffs_zlib__decoder__transform_io(&g_zlib, dst, src, workbuf);
  }
  return wuffs_gzip__decoder__transform_io(&g_gzip, dst, src, workbuf);
}

// ---- The schedules, as in test_decode.adb.

typedef struct {
  size_t src_chunk;  // 0 means everything at once.
  size_t dst_chunk;
} schedule;

static const schedule g_full_schedules[] = {
    {0, 0},   {1, 0},    {2, 0},    {3, 0}, {7, 0}, {31, 0}, {4095, 0},
    {4097, 0}, {0, 1},   {0, 2},    {0, 3}, {0, 7}, {0, 300}, {0, 4097},
    {1, 1},   {3, 5},    {5, 3},    {300, 266}, {1000, 1},
};

static const schedule g_reduced_schedules[] = {
    {0, 0}, {4097, 0}, {0, 4097}, {1000, 300}, {1, 0}, {0, 1},
};

// FNV-1a over the 8 bytes of x, least significant first.
static void hash_64(uint64_t* h, uint64_t x) {
  for (int i = 0; i < 8; i++) {
    *h = (*h ^ (x & 0xFF)) * 0x100000001B3ull;
    x >>= 8;
  }
}

static void run(int format,
                variant v,
                const char* name,
                size_t in_length,
                schedule s) {
  size_t src_cap = s.src_chunk ? s.src_chunk : (in_length ? in_length : 1);
  size_t dst_cap = s.dst_chunk ? s.dst_chunk : (CAPACITY - DST_FIRST);

  // As in test_decode.adb, the buffers do not start at the start of their
  // arrays. (In C that changes nothing.)
  uint8_t* src_work = g_src_work + SRC_FIRST;
  uint8_t* dst_work = g_dst_work + DST_FIRST;
  wuffs_base__io_buffer src = wuffs_base__empty_io_buffer();
  src.data = wuffs_base__make_slice_u8(src_work, src_cap);
  wuffs_base__io_buffer dst = wuffs_base__empty_io_buffer();
  dst.data = wuffs_base__make_slice_u8(dst_work, dst_cap);

  size_t in_pos = 0;
  uint64_t out_pos = 0;
  uint64_t calls = 0;
  uint32_t out_hash = 0x811C9DC5u;
  uint64_t call_hash = 0xCBF29CE484222325ull;
  uint64_t max_calls = 4 * (uint64_t)in_length + 4 * (uint64_t)MAX_OUTPUT + 1000;
  uint64_t category = 0;
  uint64_t code = 0;
  int added = 0;

  initialize(format, v);
  while (1) {
    // Give the decoder more source, after dropping what it has read.
    wuffs_base__io_buffer__compact(&src);
    size_t n = src_cap - src.meta.wi;
    if (n > in_length - in_pos) {
      n = in_length - in_pos;
    }
    if (n > 0) {
      memcpy(src_work + src.meta.wi, g_input + in_pos, n);
      src.meta.wi += n;
      in_pos += n;
    }
    src.meta.closed = in_pos == in_length;

    wuffs_base__status status = call(format, &dst, &src);
    calls++;
    lookup_status(status, &category, &code);

    hash_64(&call_hash, category);
    hash_64(&call_hash, code);
    hash_64(&call_hash, src.meta.ri);
    hash_64(&call_hash, src.meta.wi);
    hash_64(&call_hash, src.meta.pos);
    hash_64(&call_hash, dst.meta.wi);
    hash_64(&call_hash, dst.meta.pos);

    // Take the output, and make room again.
    for (size_t i = dst.meta.ri; i < dst.meta.wi; i++) {
      out_hash = (out_hash ^ dst_work[i]) * 0x01000193u;
      out_pos++;
    }
    dst.meta.ri = dst.meta.wi;
    wuffs_base__io_buffer__compact(&dst);

    if (v.dictionary && !added &&
        status.repr == wuffs_zlib__note__dictionary_required) {
      // The decoder has read the stream's header and wants the preset
      // dictionary. Give it one and carry on.
      added = 1;
      for (size_t i = 0; i < DICTIONARY_LENGTH; i++) {
        g_dictionary[i] = (v.dictionary == 1) ? (uint8_t)(7 * i + i / 13)
                                              : (uint8_t)(3 * i + 1);
      }
      wuffs_zlib__decoder__add_dictionary(
          &g_zlib,
          wuffs_base__make_slice_u8(g_dictionary, DICTIONARY_LENGTH));
      hash_64(&call_hash, wuffs_zlib__decoder__dictionary_id(&g_zlib));
    } else if (v.multi_member && !status.repr &&
               (in_pos < in_length || src.meta.ri < src.meta.wi)) {
      // The end of one gzip member, with input left: the next one, with a
      // decoder and a destination stream position that start afresh.
      initialize(format, v);
      dst.meta = wuffs_base__empty_io_buffer_meta();
    } else if (category != 2) {
      break;
    }

    // A decoder that does not come to an end.
    if (out_pos > MAX_OUTPUT || calls > max_calls) {
      break;
    }
  }

  printf("= %s s%zu d%zu calls=%" PRIu64 " status=%" PRIu64 ":%" PRIu64
         " in=%" PRIu64 " out=%" PRIu64 " outhash=%08" PRIX32
         " callhash=%016" PRIX64 "\n",
         name, s.src_chunk, s.dst_chunk, calls, category, code,
         wuffs_base__io_buffer__reader_position(&src), out_pos, out_hash,
         call_hash);
}

static size_t load(const char* filename) {
  FILE* f = fopen(filename, "rb");
  if (!f) {
    fprintf(stderr, "decode: cannot open %s\n", filename);
    exit(1);
  }
  size_t n = fread(g_input, 1, CAPACITY, f);
  if (!feof(f)) {
    fprintf(stderr, "decode: %s is too big\n", filename);
    exit(1);
  }
  fclose(f);
  return n;
}

int main(int argc, char** argv) {
  if (argc != 2) {
    fprintf(stderr, "usage: decode STATUS_TABLE < MANIFEST\n");
    return 1;
  }
  load_statuses(argv[1]);

  char line[4096];
  while (fgets(line, sizeof line, stdin)) {
    char kind[16];
    char in_name[2048];
    char exp_name[2048];
    if (sscanf(line, "%15s %2047s %2047s", kind, in_name, exp_name) != 3) {
      continue;
    }
    int format;
    variant v = {8, 0, 0};
    if (!strcmp(kind, "lzw")) {
      format = FORMAT_LZW;
    } else if (strlen(kind) == 4 && !strncmp(kind, "lzw", 3) &&
               kind[3] >= '2' && kind[3] <= '7') {
      format = FORMAT_LZW;
      v.literal_width = (uint64_t)(kind[3] - '0');
    } else if (!strcmp(kind, "deflate")) {
      format = FORMAT_DEFLATE;
    } else if (!strcmp(kind, "zlib")) {
      format = FORMAT_ZLIB;
    } else if (!strcmp(kind, "zlibdict")) {
      format = FORMAT_ZLIB;
      v.dictionary = 1;
    } else if (!strcmp(kind, "zlibwrongdict")) {
      format = FORMAT_ZLIB;
      v.dictionary = 2;
    } else if (!strcmp(kind, "gzip")) {
      format = FORMAT_GZIP;
    } else if (!strcmp(kind, "gzipmulti")) {
      format = FORMAT_GZIP;
      v.multi_member = 1;
    } else {
      fprintf(stderr, "decode: unknown format %s\n", kind);
      return 1;
    }
    size_t in_length = load(in_name);
    const char* slash = strrchr(in_name, '/');
    const char* name = slash ? slash + 1 : in_name;

    if (in_length > REDUCED_ABOVE) {
      for (size_t i = 0;
           i < sizeof g_reduced_schedules / sizeof g_reduced_schedules[0];
           i++) {
        run(format, v, name, in_length, g_reduced_schedules[i]);
      }
    } else {
      for (size_t i = 0;
           i < sizeof g_full_schedules / sizeof g_full_schedules[0]; i++) {
        run(format, v, name, in_length, g_full_schedules[i]);
      }
    }
  }
  return 0;
}
