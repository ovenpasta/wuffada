// Benchmark of upstream Wuffs' C wuffs_base__pixel_swizzler__swizzle_ycck,
// the counterpart of ycck_bench.adb: a 1600 x 1200 image, 4:2:0, BT.601
// full range, converted REPEATS times; prints the best time per pixel of
// ROUNDS rounds, in nanoseconds.  Not a test.  See bench.sh.
//
// Usage: bench_c <destination pixel format, hex> <ycc_upsampling>

#define WUFFS_IMPLEMENTATION
#define WUFFS_CONFIG__MODULES
#define WUFFS_CONFIG__MODULE__BASE
#define WUFFS_CONFIG__MODULE__BASE__CORE
#define WUFFS_CONFIG__MODULE__BASE__PIXCONV

#include WUFFS_C_FILE

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#define W 1600u
#define H 1200u
#define REPEATS 4
#define ROUNDS 25

int main(int argc, char** argv) {
  if (argc != 3) {
    return 2;
  }
  uint32_t fmt = (uint32_t)strtoul(argv[1], 0, 16);
  uint8_t ups = (uint8_t)atoi(argv[2]);
  uint8_t* y = malloc(W * H);
  uint8_t* cb = malloc(W * H / 4);
  uint8_t* cr = malloc(W * H / 4);
  uint8_t* dst = malloc(W * H * 4);
  uint8_t scratch[2048];
  for (size_t i = 0; i < W * H; i++) {
    y[i] = (uint8_t)(i * 7);
  }
  for (size_t i = 0; i < W * H / 4; i++) {
    cb[i] = (uint8_t)(i * 13);
    cr[i] = (uint8_t)(i * 29);
  }
  memset(dst, 0, W * H * 4);
  wuffs_base__pixel_config pc;
  wuffs_base__pixel_config__set(&pc, fmt, 0, W, H);
  wuffs_base__pixel_buffer pb;
  wuffs_base__pixel_buffer__set_from_slice(
      &pb, &pc, wuffs_base__make_slice_u8(dst, W * H * 4));
  wuffs_base__pixel_swizzler sw;
  memset(&sw, 0, sizeof sw);
  double best = 1e30;
  for (int round = 0; round < ROUNDS; round++) {
    struct timespec t0, t1;
    clock_gettime(CLOCK_MONOTONIC, &t0);
    for (int i = 0; i < REPEATS; i++) {
      wuffs_base__status st = wuffs_base__pixel_swizzler__swizzle_ycck(
          &sw, &pb, wuffs_base__empty_slice_u8(), 0, W, 0, H,
          wuffs_base__make_slice_u8(y, W * H),
          wuffs_base__make_slice_u8(cb, W * H / 4),
          wuffs_base__make_slice_u8(cr, W * H / 4),
          wuffs_base__empty_slice_u8(),  //
          W, W / 2, W / 2, 0,            //
          H, H / 2, H / 2, 0,            //
          W, W / 2, W / 2, 0,            //
          2, 1, 1, 0, 2, 1, 1, 0,        //
          0, ups, wuffs_base__make_slice_u8(scratch, 2048));
      if (st.repr) {
        printf("%s\n", st.repr);
        return 1;
      }
    }
    clock_gettime(CLOCK_MONOTONIC, &t1);
    double ns = ((double)(t1.tv_sec - t0.tv_sec) * 1e9) +
                (double)(t1.tv_nsec - t0.tv_nsec);
    double per = ns / ((double)REPEATS * W * H);
    if (per < best) {
      best = per;
    }
  }
  // A digest of the result, so that the work cannot be optimised away and
  // the two sides can be seen to have computed the same thing.
  uint64_t h = 0xCBF29CE484222325ull;
  for (size_t i = 0; i < W * H * 4; i++) {
    h = (h ^ dst[i]) * 0x100000001B3ull;
  }
  printf("%.2f %016llX\n", best, (unsigned long long)h);
  return 0;
}
