// Part of wuffada (wuffs-ada: Wuffs to Ada).
// SPDX-License-Identifier: Apache-2.0 OR MIT

// The C side of the token decoder cross-check: it runs upstream's C json and
// cbor decoders (wuffs/release/c/wuffs-unsupported-snapshot.c) over a
// manifest (from ada/tests/tokcorpus), with the same schedules and the same
// buffer handling as ada/tests/test_tokens.adb, and prints the same trace
// lines. See run_tokens.sh, which builds and runs this. Keep it in step with
// test_tokens.adb.
//
// usage: tokens STATUS_TABLE < MANIFEST
//
// STATUS_TABLE (from statustable) gives the Ada category and code of each C
// status string.

#include <inttypes.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define WUFFS_IMPLEMENTATION
#define WUFFS_CONFIG__MODULES
#define WUFFS_CONFIG__MODULE__BASE
#define WUFFS_CONFIG__MODULE__CBOR
#define WUFFS_CONFIG__MODULE__JSON
#include "wuffs-unsupported-snapshot.c"

#define CAPACITY (4 * 1024 * 1024)
#define TOKEN_CAPACITY (4 * 1024 * 1024)
#define REDUCED_ABOVE 60000
#define SRC_FIRST 5
#define TOK_FIRST 1000
#define WORK_LENGTH 16

static uint8_t g_input[CAPACITY];
static uint8_t g_src_work[CAPACITY];
static wuffs_base__token g_tok_work[TOKEN_CAPACITY];
static uint8_t g_workbuf[WORK_LENGTH];

static wuffs_json__decoder g_json;
static wuffs_cbor__decoder g_cbor;

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
    fprintf(stderr, "tokens: cannot open %s\n", filename);
    exit(1);
  }
  char line[256];
  while (fgets(line, sizeof line, f)) {
    if (g_num_statuses >= MAX_STATUSES) {
      fprintf(stderr, "tokens: too many statuses\n");
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
  fprintf(stderr, "tokens: status \"%s\" is not in the table\n", s.repr);
  exit(1);
}

// ---- The decoders.

enum { FORMAT_JSON, FORMAT_CBOR };

#define JSON_QUIRKS_BASE 0x45990800u
#define JSON_QUIRKS_COUNT 21

static void initialize(int format, uint32_t quirks) {
  wuffs_base__status s = wuffs_base__make_status(NULL);
  if (format == FORMAT_JSON) {
    s = wuffs_json__decoder__initialize(&g_json, sizeof g_json, WUFFS_VERSION,
                                        0);
    for (uint32_t i = 0; !s.repr && i < JSON_QUIRKS_COUNT; i++) {
      if (quirks & (1u << i)) {
        s = wuffs_json__decoder__set_quirk(&g_json, JSON_QUIRKS_BASE | i, 1);
        if (!s.repr &&
            wuffs_json__decoder__get_quirk(&g_json, JSON_QUIRKS_BASE | i) !=
                1) {
          fprintf(stderr, "tokens: get_quirk\n");
          exit(1);
        }
      }
    }
  } else {
    s = wuffs_cbor__decoder__initialize(&g_cbor, sizeof g_cbor, WUFFS_VERSION,
                                        0);
  }
  if (s.repr) {
    fprintf(stderr, "tokens: initialize: %s\n", s.repr);
    exit(1);
  }
}

static wuffs_base__status call(int format,
                               wuffs_base__token_buffer* dst,
                               wuffs_base__io_buffer* src) {
  wuffs_base__slice_u8 work = wuffs_base__make_slice_u8(g_workbuf, WORK_LENGTH);
  if (format == FORMAT_JSON) {
    return wuffs_json__decoder__decode_tokens(&g_json, dst, src, work);
  }
  return wuffs_cbor__decoder__decode_tokens(&g_cbor, dst, src, work);
}

// ---- The schedules, as in test_tokens.adb.

typedef struct {
  size_t src_chunk;  // 0 means everything at once.
  size_t dst_chunk;  // In tokens; 0 means TOKEN_CAPACITY - TOK_FIRST.
} schedule;

// std/json needs 100 bytes of source at once (DECODER_SRC_IO_BUFFER_LENGTH_
// MIN_INCL) and std/cbor 9 and two tokens of room, or they make no progress
// (see "stalled" below): the smaller sizes test the suspensions up to that
// point, the others every suspension point throughout.
static const schedule g_full_schedules[] = {
    {0, 0},   {1, 0},   {2, 0},   {3, 0},    {7, 0},   {9, 0},    {31, 0},
    {100, 0}, {101, 0}, {127, 0}, {4097, 0}, {0, 1},   {0, 2},    {0, 3},
    {0, 7},   {1, 1},   {1, 2},   {3, 2},    {9, 2},   {10, 3},   {100, 1},
    {100, 2}, {101, 3}, {128, 5}, {300, 5},  {1000, 1}, {7, 4097},
};

static const schedule g_reduced_schedules[] = {
    {0, 0},   {4097, 0}, {0, 4097}, {1000, 300}, {100, 0},
    {100, 1}, {101, 2},  {0, 2},    {9, 2},      {1, 0},
};

// FNV-1a over the 8 bytes of x, least significant first.
static void hash_64(uint64_t* h, uint64_t x) {
  for (int i = 0; i < 8; i++) {
    *h = (*h ^ (x & 0xFF)) * 0x100000001B3ull;
    x >>= 8;
  }
}

static void run(int format,
                uint32_t quirks,
                const char* name,
                size_t in_length,
                schedule s) {
  size_t src_cap = s.src_chunk ? s.src_chunk : (in_length ? in_length : 1);
  size_t dst_cap = s.dst_chunk ? s.dst_chunk : (TOKEN_CAPACITY - TOK_FIRST);

  // As in test_tokens.adb, the buffers do not start at the start of their
  // arrays. (In C that changes nothing.)
  uint8_t* src_work = g_src_work + SRC_FIRST;
  wuffs_base__token* tok_work = g_tok_work + TOK_FIRST;
  wuffs_base__io_buffer src = wuffs_base__empty_io_buffer();
  src.data = wuffs_base__make_slice_u8(src_work, src_cap);
  wuffs_base__token_buffer dst = wuffs_base__empty_token_buffer();
  dst.data = wuffs_base__make_slice_token(tok_work, dst_cap);

  size_t in_pos = 0;
  uint64_t tokens = 0;
  uint64_t calls = 0;
  uint64_t tok_hash = 0xCBF29CE484222325ull;
  uint64_t call_hash = 0xCBF29CE484222325ull;
  uint64_t max_calls = 4 * (uint64_t)in_length + 1000;
  uint64_t category = 0;
  uint64_t code = 0;
  int stalled = 0;

  initialize(format, quirks);
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

    size_t old_ri = src.meta.ri;
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

    // Take the tokens, and make room again.
    size_t written = dst.meta.wi - dst.meta.ri;
    for (size_t i = dst.meta.ri; i < dst.meta.wi; i++) {
      hash_64(&tok_hash, tok_work[i].repr);
      tokens++;
    }
    dst.meta.ri = dst.meta.wi;
    wuffs_base__token_buffer__compact(&dst);

    if (category != 2) {
      break;
    }
    // A run that makes no progress (no byte read, no token written) three
    // times in a row, with no more source to give, has come to an end (for
    // example, std/cbor with a one-token destination or a source buffer too
    // short for a header).
    if (src.meta.ri == old_ri && written == 0 &&
        (in_pos == in_length || src.meta.wi == src_cap)) {
      if (++stalled >= 3) {
        break;
      }
    } else {
      stalled = 0;
    }
    if (calls > max_calls) {
      break;
    }
  }

  printf("= %s q%08" PRIX32 " s%zu d%zu calls=%" PRIu64 " status=%" PRIu64
         ":%" PRIu64 " in=%" PRIu64 " tokens=%" PRIu64 " tokhash=%016" PRIX64
         " callhash=%016" PRIX64 "\n",
         name, quirks, s.src_chunk, s.dst_chunk, calls, category, code,
         wuffs_base__io_buffer__reader_position(&src), tokens, tok_hash,
         call_hash);
}

static size_t load(const char* filename) {
  FILE* f = fopen(filename, "rb");
  if (!f) {
    fprintf(stderr, "tokens: cannot open %s\n", filename);
    exit(1);
  }
  size_t n = fread(g_input, 1, CAPACITY, f);
  if (!feof(f)) {
    fprintf(stderr, "tokens: %s is too big\n", filename);
    exit(1);
  }
  fclose(f);
  return n;
}

int main(int argc, char** argv) {
  if (argc != 2) {
    fprintf(stderr, "usage: tokens STATUS_TABLE < MANIFEST\n");
    return 1;
  }
  load_statuses(argv[1]);

  char line[4096];
  while (fgets(line, sizeof line, stdin)) {
    char kind[16];
    char quirks_text[16];
    char in_name[2048];
    if (sscanf(line, "%15s %15s %2047s", kind, quirks_text, in_name) != 3) {
      continue;
    }
    int format;
    if (!strcmp(kind, "json")) {
      format = FORMAT_JSON;
    } else if (!strcmp(kind, "cbor")) {
      format = FORMAT_CBOR;
    } else {
      fprintf(stderr, "tokens: unknown format %s\n", kind);
      return 1;
    }
    uint32_t quirks = (uint32_t)strtoul(quirks_text, NULL, 16);
    size_t in_length = load(in_name);
    const char* slash = strrchr(in_name, '/');
    const char* name = slash ? slash + 1 : in_name;

    if (in_length > REDUCED_ABOVE) {
      for (size_t i = 0;
           i < sizeof g_reduced_schedules / sizeof g_reduced_schedules[0];
           i++) {
        run(format, quirks, name, in_length, g_reduced_schedules[i]);
      }
    } else {
      for (size_t i = 0;
           i < sizeof g_full_schedules / sizeof g_full_schedules[0]; i++) {
        run(format, quirks, name, in_length, g_full_schedules[i]);
      }
    }
  }
  return 0;
}
