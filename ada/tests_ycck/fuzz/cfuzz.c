// The C side of the differential fuzz test (written by the independent
// reviewer of the YCCK milestone; adopted with the scratch buffer added to
// what is compared and the digests printed as decimal halves).
//
// Reads calls of swizzle_ycck from standard input, one per line as printed
// by gen.py:
//
//   fmt dw dh plane0_width dstride x0 x1 y0 y1
//   (width height stride h v) for each of the four planes
//   len0 len1 len2 len3 model upsampling scratch_len seed
//
// makes each call with upstream's C on buffers filled from the seed, and
// prints the line again followed by what the Ada side must reproduce:
//
//   status  dst_digest_high dst_digest_low  dst_changed
//   scratch_digest_high scratch_digest_low
//
// Every buffer is malloc'ed at exactly its length, for ASan.  See regen.sh.
#define WUFFS_IMPLEMENTATION
#define WUFFS_CONFIG__MODULES
#define WUFFS_CONFIG__MODULE__BASE
#define WUFFS_CONFIG__MODULE__BASE__CORE
#define WUFFS_CONFIG__MODULE__BASE__PIXCONV
#include WUFFS_C_FILE
#include <inttypes.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static void fill(uint8_t* p, size_t n, uint64_t seed, int mode) {
  uint64_t x = seed;
  for (size_t i = 0; i < n; i++) {
    x = x * 6364136223846793005ull + 1442695040888963407ull;
    uint8_t r = (uint8_t)(x >> 56);
    uint8_t q = (uint8_t)(x >> 40);
    if (mode == 0) p[i] = r;
    else if (mode == 1) p[i] = (r & 1) ? 255 : 0;
    else p[i] = (q & 3) == 0 ? r : ((r & 1) ? 255 : 0);
  }
}
static uint64_t fnv(const uint8_t* p, size_t n) {
  uint64_t h = 0xCBF29CE484222325ull;
  for (size_t i = 0; i < n; i++) h = (h ^ p[i]) * 0x100000001B3ull;
  return h;
}
int main(int argc, char** argv) {
  long long v[40];
  (void)argc;
  (void)argv;
  for (;;) {
    for (int i = 0; i < 37; i++) {
      if (scanf("%lld", &v[i]) != 1) return 0;
    }
    uint32_t fmt = (uint32_t)v[0], dw = (uint32_t)v[1], dh = (uint32_t)v[2];
    size_t p0w = (size_t)v[3], dstride = (size_t)v[4];
    uint32_t x0 = (uint32_t)v[5], x1 = (uint32_t)v[6], y0 = (uint32_t)v[7], y1 = (uint32_t)v[8];
    uint32_t w[4], h[4], s[4]; uint8_t hf[4], vf[4]; size_t len[4];
    for (int k = 0; k < 4; k++) {
      w[k] = (uint32_t)v[9 + 5 * k]; h[k] = (uint32_t)v[10 + 5 * k]; s[k] = (uint32_t)v[11 + 5 * k];
      hf[k] = (uint8_t)v[12 + 5 * k]; vf[k] = (uint8_t)v[13 + 5 * k];
      len[k] = (size_t)v[29 + k];
    }
    uint8_t model = (uint8_t)v[33], ups = (uint8_t)v[34];
    size_t scratch_len = (size_t)v[35];
    uint64_t seed = (uint64_t)v[36] >> 2; int mode = (int)(v[36] & 3);
    size_t off = ((seed >> 5) % 3 == 0) ? (size_t)((seed >> 8) % 13) : 0;
    int dmode = (int)((seed >> 3) % 4); dmode = dmode < 2 ? 0 : dmode - 1;
    size_t dlen = off + dstride * dh;
    uint8_t* src[4];
    for (int k = 0; k < 4; k++) {
      src[k] = (uint8_t*)malloc(len[k] ? len[k] : 1);
      fill(src[k], len[k], seed * 8 + k, mode);
    }
    uint8_t* dst = (uint8_t*)malloc(dlen ? dlen : 1);
    uint8_t* dst0 = (uint8_t*)malloc(dlen ? dlen : 1);
    fill(dst, dlen, seed * 8 + 4, dmode);
    memcpy(dst0, dst, dlen);
    uint8_t* pal = (uint8_t*)malloc(1024);
    fill(pal, 1024, seed * 8 + 5, 0);
    uint8_t* scratch = (uint8_t*)malloc(scratch_len ? scratch_len : 1);
    fill(scratch, scratch_len, seed * 8 + 6, 0);
    wuffs_base__pixel_buffer pb;
    memset(&pb, 0, sizeof pb);
    pb.pixcfg.private_impl.pixfmt.repr = fmt;
    pb.pixcfg.private_impl.width = dw;
    pb.pixcfg.private_impl.height = dh;
    pb.private_impl.planes[0].ptr = dst + off;
    pb.private_impl.planes[0].width = p0w;
    pb.private_impl.planes[0].height = dh;
    pb.private_impl.planes[0].stride = dstride;
    // One indexed destination in sixteen has no palette plane.
    int nopal = ((seed >> 12) % 16) == 0;
    if (((fmt >> 18) & 1) && !nopal) {
      pb.private_impl.planes[3].ptr = pal;
      pb.private_impl.planes[3].width = 1024;
      pb.private_impl.planes[3].height = 1;
      pb.private_impl.planes[3].stride = 1024;
    }
    wuffs_base__pixel_swizzler sw;
    memset(&sw, 0, sizeof sw);
    wuffs_base__status st = wuffs_base__pixel_swizzler__swizzle_ycck(
        &sw, &pb, wuffs_base__make_slice_u8(pal, 1024), x0, x1, y0, y1,
        wuffs_base__make_slice_u8(src[0], len[0]), wuffs_base__make_slice_u8(src[1], len[1]),
        wuffs_base__make_slice_u8(src[2], len[2]), wuffs_base__make_slice_u8(src[3], len[3]),
        w[0], w[1], w[2], w[3], h[0], h[1], h[2], h[3], s[0], s[1], s[2], s[3],
        hf[0], hf[1], hf[2], hf[3], vf[0], vf[1], vf[2], vf[3], model, ups,
        wuffs_base__make_slice_u8(scratch, scratch_len));
    int code = (st.repr == NULL) ? 0
               : (st.repr == wuffs_base__error__bad_argument) ? 1
               : (st.repr == wuffs_base__error__unsupported_pixel_swizzler_option) ? 2 : 3;
    uint64_t hd = fnv(dst, dlen);
    uint64_t hs = fnv(scratch, scratch_len);
    for (int i = 0; i < 37; i++) {
      printf("%lld ", v[i]);
    }
    printf("%d %" PRIu64 " %" PRIu64 " %d %" PRIu64 " %" PRIu64 "\n", code,
           hd >> 32, hd & 0xFFFFFFFFu, memcmp(dst, dst0, dlen) != 0, hs >> 32,
           hs & 0xFFFFFFFFu);
    for (int k = 0; k < 4; k++) free(src[k]);
    free(dst); free(dst0); free(pal); free(scratch);
  }
}
