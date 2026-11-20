// Part of wuffada (wuffs-ada: Wuffs to Ada).
// SPDX-License-Identifier: Apache-2.0 OR MIT

// Prints, for each file named on the command line, the line that
// ada/tests/hashexpect2 prints for it, computed by upstream's C hashers
// (xxhash32, xxhash64, crc64/ECMA). See run_hash2.sh.

#include <inttypes.h>
#include <stdio.h>
#include <stdlib.h>

#define WUFFS_IMPLEMENTATION
#define WUFFS_CONFIG__MODULES
#define WUFFS_CONFIG__MODULE__BASE
#define WUFFS_CONFIG__MODULE__CRC64
#define WUFFS_CONFIG__MODULE__SHA256
#define WUFFS_CONFIG__MODULE__XXHASH32
#define WUFFS_CONFIG__MODULE__XXHASH64
#include "wuffs-unsupported-snapshot.c"

#define CAPACITY (16 * 1024 * 1024)
static uint8_t g_data[CAPACITY];
static wuffs_xxhash32__hasher g_x32;
static wuffs_xxhash64__hasher g_x64;
static wuffs_crc64__ecma_hasher g_crc64;
static wuffs_sha256__hasher g_sha256;

int main(int argc, char** argv) {
  for (int i = 1; i < argc; i++) {
    FILE* f = fopen(argv[i], "rb");
    if (!f) {
      fprintf(stderr, "hash2: cannot open %s\n", argv[i]);
      return 1;
    }
    size_t n = fread(g_data, 1, CAPACITY, f);
    fclose(f);
    wuffs_base__slice_u8 s = wuffs_base__make_slice_u8(g_data, n);
    if (wuffs_xxhash32__hasher__initialize(&g_x32, sizeof g_x32, WUFFS_VERSION, 0).repr ||
        wuffs_xxhash64__hasher__initialize(&g_x64, sizeof g_x64, WUFFS_VERSION, 0).repr ||
        wuffs_crc64__ecma_hasher__initialize(&g_crc64, sizeof g_crc64, WUFFS_VERSION, 0).repr ||
        wuffs_sha256__hasher__initialize(&g_sha256, sizeof g_sha256, WUFFS_VERSION, 0).repr) {
      return 1;
    }
    wuffs_base__bitvec256 d = wuffs_sha256__hasher__update_bitvec256(&g_sha256, s);
    // The digest's first byte is the top byte of element 3.
    printf("%08" PRIX32 " %016" PRIX64 " %016" PRIX64 " %016" PRIX64 "%016" PRIX64
           "%016" PRIX64 "%016" PRIX64 " %s\n",
           wuffs_xxhash32__hasher__update_u32(&g_x32, s),
           wuffs_xxhash64__hasher__update_u64(&g_x64, s),
           wuffs_crc64__ecma_hasher__update_u64(&g_crc64, s),
           d.elements_u64[3], d.elements_u64[2], d.elements_u64[1], d.elements_u64[0], argv[i]);
  }
  return 0;
}
