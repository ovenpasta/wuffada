// Part of wuffada (wuffs-ada: Wuffs to Ada).
// SPDX-License-Identifier: Apache-2.0 OR MIT

// Package webpconv converts the Y'CbCr planes that golang.org/x/image/webp
// returns for a lossy WebP image to BGRA, for the tests' comparisons
// (ada/tests/imgcorpus and ada/tests/pnmcheck): an implementation of its
// own, in floating point, of the chroma upsampling and colour conversion
// that VP8 specifies, independent of Wuffs and of libwebp.
package webpconv

import (
	"image"
	"math"
)

// FancyBGRA converts 4:2:0 Y'CbCr planes to BGRA: each chroma sample sits
// between two luma samples in each direction, and a luma sample's chroma is
// the bilinear interpolation of the four nearest chroma samples (weights
// 9/16, 3/16, 3/16, 1/16; at the edges, the nearest ones repeated), then
// BT.601 with studio-range Y' (16 to 235) and chroma (16 to 240).
func FancyBGRA(m *image.YCbCr, alpha []byte, aStride int) []byte {
	b := m.Bounds()
	w, h := b.Dx(), b.Dy()
	cw, ch := (w+1)/2, (h+1)/2
	cAt := func(plane []byte, cx, cy int) float64 {
		if cx < 0 {
			cx = 0
		} else if cx >= cw {
			cx = cw - 1
		}
		if cy < 0 {
			cy = 0
		} else if cy >= ch {
			cy = ch - 1
		}
		return float64(plane[cy*m.CStride+cx])
	}
	clamp := func(v float64) byte {
		v = math.Floor(v + 0.5)
		if v < 0 {
			return 0
		} else if v > 255 {
			return 255
		}
		return byte(v)
	}
	out := make([]byte, 0, 4*w*h)
	for y := 0; y < h; y++ {
		// The chroma rows above and below the sample.
		cy0 := (y - 1) >> 1
		for x := 0; x < w; x++ {
			cx0 := (x - 1) >> 1
			// Weights for cx0 and cx0+1; for cy0 and cy0+1.
			wx := [2]float64{0.25, 0.75}
			if x&1 == 1 {
				wx = [2]float64{0.75, 0.25}
			}
			wy := [2]float64{0.25, 0.75}
			if y&1 == 1 {
				wy = [2]float64{0.75, 0.25}
			}
			var cb, cr float64
			for j := 0; j < 2; j++ {
				for i := 0; i < 2; i++ {
					k := wx[i] * wy[j]
					cb += k * cAt(m.Cb, cx0+i, cy0+j)
					cr += k * cAt(m.Cr, cx0+i, cy0+j)
				}
			}
			yy := 255.0 / 219.0 * (float64(m.Y[y*m.YStride+x]) - 16)
			cb, cr = cb-128, cr-128
			r := yy + 255.0/112.0*0.701*cr
			g := yy - 255.0/112.0*0.886*0.114/0.587*cb - 255.0/112.0*0.701*0.299/0.587*cr
			bl := yy + 255.0/112.0*0.886*cb
			a := byte(0xFF)
			if alpha != nil {
				a = alpha[y*aStride+x]
			}
			out = append(out, clamp(bl), clamp(g), clamp(r), a)
		}
	}
	return out
}
