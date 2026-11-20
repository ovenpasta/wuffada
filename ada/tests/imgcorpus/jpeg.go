// Part of wuffada (wuffs-ada: Wuffs to Ada).
// SPDX-License-Identifier: Apache-2.0 OR MIT

package main

// JPEG images for the corpus: a small encoder, written for this test (it is
// not derived from any other encoder), for what the JPEG files that are
// checked in under ada/tests/jpegcorpus (made with Pillow: see make.py there)
// cannot cover: every combination of sampling factors that std/jpeg accepts
// (and some that it rejects), four-component YCCK and CMYK, RGB by
// component ids, sequential images in several scans, restart intervals of
// every kind, 16-bit quantization tables, the frame types that std/jpeg
// rejects, and progressive images with spectral selection and DC successive
// approximation (Pillow's progressive images have AC successive
// approximation too).
//
// The reference pixels come from Go's image/jpeg, which is compared with a
// tolerance: JPEG decoders legitimately differ in the inverse DCT's
// rounding, in the colour conversion's rounding and in chroma upsampling
// (see the categories in jpegCategory).

import (
	"bytes"
	"encoding/binary"
	"fmt"
	"image"
	"image/color"
	"image/jpeg"
	"io/fs"
	"log"
	"math"
	"os"
	"path/filepath"
	"sort"
	"strings"
)

type jcomp struct {
	id     byte
	h, v   int
	tq     int
	td, ta int
}

type jpegOpts struct {
	w, h        int
	comps       []jcomp
	jfif        bool
	adobe       int  // The APP14 transform byte, or -1 for no APP14 segment.
	sof         byte // 0xC0, 0xC1 (sequential) or 0xC2 (progressive).
	interleaved bool // Sequential: one scan for all components, else one each.
	restart     int  // The DRI interval, in MCUs; 0 for none.
	driEach     bool // A DRI segment before every scan, alternating restart and 0.
	optimize    bool // Huffman tables from the image's statistics.
	quality     int  // Scales the standard quantization tables, 1 ..= 100.
	qflat       int  // If not zero: every quantization value is this.
	q16         bool // 16-bit quantization tables (Pq = 1), which std/jpeg rejects.
	dcAl        int  // Progressive: DC successive approximation (0 or 1).
	band        int  // Progressive: if not zero, the first component's AC bands are this wide.
	segments    [][]byte
	trailing    []byte
	fill        bool // Fill bytes (0xFF) before every marker.
	dhtEach     bool // The Huffman tables before each scan, not after the frame header.
	dhtFirst    bool // The Huffman tables before the frame header.
	model       string
	seed        uint32
}

var zigzag = [64]int{
	0, 1, 8, 16, 9, 2, 3, 10, 17, 24, 32, 25, 18, 11, 4, 5,
	12, 19, 26, 33, 40, 48, 41, 34, 27, 20, 13, 6, 7, 14, 21, 28,
	35, 42, 49, 56, 57, 50, 43, 36, 29, 22, 15, 23, 30, 37, 44, 51,
	58, 59, 52, 45, 38, 31, 39, 46, 53, 60, 61, 54, 47, 55, 62, 63,
}

// The example quantization tables of the JPEG specification (Annex K.1), in
// natural order.
var stdQuant = [2][64]int{{
	16, 11, 10, 16, 24, 40, 51, 61, 12, 12, 14, 19, 26, 58, 60, 55,
	14, 13, 16, 24, 40, 57, 69, 56, 14, 17, 22, 29, 51, 87, 80, 62,
	18, 22, 37, 56, 68, 109, 103, 77, 24, 35, 55, 64, 81, 104, 113, 92,
	49, 64, 78, 87, 103, 121, 120, 101, 72, 92, 95, 98, 112, 100, 103, 99,
}, {
	17, 18, 24, 47, 99, 99, 99, 99, 18, 21, 26, 66, 99, 99, 99, 99,
	24, 26, 56, 99, 99, 99, 99, 99, 47, 66, 99, 99, 99, 99, 99, 99,
	99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99,
	99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99,
}}

// The example Huffman tables of the JPEG specification (Annex K.3): bit
// counts and values, for DC luminance, DC chrominance, AC luminance and AC
// chrominance.
var stdHuffBits = [4][16]int{
	{0, 1, 5, 1, 1, 1, 1, 1, 1, 0, 0, 0, 0, 0, 0, 0},
	{0, 3, 1, 1, 1, 1, 1, 1, 1, 1, 1, 0, 0, 0, 0, 0},
	{0, 2, 1, 3, 3, 2, 4, 3, 5, 5, 4, 4, 0, 0, 1, 0x7d},
	{0, 2, 1, 2, 4, 4, 3, 4, 7, 5, 4, 4, 0, 1, 2, 0x77},
}

var stdHuffVals = [4][]byte{
	{0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11},
	{0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11},
	{
		0x01, 0x02, 0x03, 0x00, 0x04, 0x11, 0x05, 0x12, 0x21, 0x31, 0x41, 0x06, 0x13, 0x51, 0x61, 0x07,
		0x22, 0x71, 0x14, 0x32, 0x81, 0x91, 0xa1, 0x08, 0x23, 0x42, 0xb1, 0xc1, 0x15, 0x52, 0xd1, 0xf0,
		0x24, 0x33, 0x62, 0x72, 0x82, 0x09, 0x0a, 0x16, 0x17, 0x18, 0x19, 0x1a, 0x25, 0x26, 0x27, 0x28,
		0x29, 0x2a, 0x34, 0x35, 0x36, 0x37, 0x38, 0x39, 0x3a, 0x43, 0x44, 0x45, 0x46, 0x47, 0x48, 0x49,
		0x4a, 0x53, 0x54, 0x55, 0x56, 0x57, 0x58, 0x59, 0x5a, 0x63, 0x64, 0x65, 0x66, 0x67, 0x68, 0x69,
		0x6a, 0x73, 0x74, 0x75, 0x76, 0x77, 0x78, 0x79, 0x7a, 0x83, 0x84, 0x85, 0x86, 0x87, 0x88, 0x89,
		0x8a, 0x92, 0x93, 0x94, 0x95, 0x96, 0x97, 0x98, 0x99, 0x9a, 0xa2, 0xa3, 0xa4, 0xa5, 0xa6, 0xa7,
		0xa8, 0xa9, 0xaa, 0xb2, 0xb3, 0xb4, 0xb5, 0xb6, 0xb7, 0xb8, 0xb9, 0xba, 0xc2, 0xc3, 0xc4, 0xc5,
		0xc6, 0xc7, 0xc8, 0xc9, 0xca, 0xd2, 0xd3, 0xd4, 0xd5, 0xd6, 0xd7, 0xd8, 0xd9, 0xda, 0xe1, 0xe2,
		0xe3, 0xe4, 0xe5, 0xe6, 0xe7, 0xe8, 0xe9, 0xea, 0xf1, 0xf2, 0xf3, 0xf4, 0xf5, 0xf6, 0xf7, 0xf8,
		0xf9, 0xfa,
	},
	{
		0x00, 0x01, 0x02, 0x03, 0x11, 0x04, 0x05, 0x21, 0x31, 0x06, 0x12, 0x41, 0x51, 0x07, 0x61, 0x71,
		0x13, 0x22, 0x32, 0x81, 0x08, 0x14, 0x42, 0x91, 0xa1, 0xb1, 0xc1, 0x09, 0x23, 0x33, 0x52, 0xf0,
		0x15, 0x62, 0x72, 0xd1, 0x0a, 0x16, 0x24, 0x34, 0xe1, 0x25, 0xf1, 0x17, 0x18, 0x19, 0x1a, 0x26,
		0x27, 0x28, 0x29, 0x2a, 0x35, 0x36, 0x37, 0x38, 0x39, 0x3a, 0x43, 0x44, 0x45, 0x46, 0x47, 0x48,
		0x49, 0x4a, 0x53, 0x54, 0x55, 0x56, 0x57, 0x58, 0x59, 0x5a, 0x63, 0x64, 0x65, 0x66, 0x67, 0x68,
		0x69, 0x6a, 0x73, 0x74, 0x75, 0x76, 0x77, 0x78, 0x79, 0x7a, 0x82, 0x83, 0x84, 0x85, 0x86, 0x87,
		0x88, 0x89, 0x8a, 0x92, 0x93, 0x94, 0x95, 0x96, 0x97, 0x98, 0x99, 0x9a, 0xa2, 0xa3, 0xa4, 0xa5,
		0xa6, 0xa7, 0xa8, 0xa9, 0xaa, 0xb2, 0xb3, 0xb4, 0xb5, 0xb6, 0xb7, 0xb8, 0xb9, 0xba, 0xc2, 0xc3,
		0xc4, 0xc5, 0xc6, 0xc7, 0xc8, 0xc9, 0xca, 0xd2, 0xd3, 0xd4, 0xd5, 0xd6, 0xd7, 0xd8, 0xd9, 0xda,
		0xe2, 0xe3, 0xe4, 0xe5, 0xe6, 0xe7, 0xe8, 0xe9, 0xea, 0xf2, 0xf3, 0xf4, 0xf5, 0xf6, 0xf7, 0xf8,
		0xf9, 0xfa,
	},
}

// huffTable is a Huffman table as a DHT segment gives it, plus its codes.
type huffTable struct {
	bits  [16]int
	vals  []byte
	code  [256]uint32
	size  [256]int
	valid [256]bool
}

func makeHuff(bits [16]int, vals []byte) *huffTable {
	t := &huffTable{bits: bits, vals: vals}
	code, k := uint32(0), 0
	for n := 1; n <= 16; n++ {
		for i := 0; i < bits[n-1]; i++ {
			v := vals[k]
			t.code[v], t.size[v], t.valid[v] = code, n, true
			code++
			k++
		}
		code <<= 1
	}
	return t
}

// optimalHuff makes a table for the symbol frequencies freq, with code
// lengths of at most 16 bits: the procedure of the JPEG specification's
// Annex K.2, which reserves one code point (the all-ones code).
func optimalHuff(freq [257]int) *huffTable {
	freq[256] = 1
	codesize := [257]int{}
	others := [257]int{}
	for i := range others {
		others[i] = -1
	}
	for {
		c1, c2 := -1, -1
		for i := 0; i < 257; i++ {
			if freq[i] > 0 && (c1 < 0 || freq[i] <= freq[c1]) {
				c1 = i
			}
		}
		for i := 0; i < 257; i++ {
			if freq[i] > 0 && i != c1 && (c2 < 0 || freq[i] <= freq[c2]) {
				c2 = i
			}
		}
		if c2 < 0 {
			break
		}
		freq[c1] += freq[c2]
		freq[c2] = 0
		codesize[c1]++
		for others[c1] >= 0 {
			c1 = others[c1]
			codesize[c1]++
		}
		others[c1] = c2
		codesize[c2]++
		for others[c2] >= 0 {
			c2 = others[c2]
			codesize[c2]++
		}
	}
	bits := [33]int{}
	for i := 0; i < 257; i++ {
		if codesize[i] > 0 {
			bits[codesize[i]]++
		}
	}
	for i := 32; i > 16; i-- {
		for bits[i] > 0 {
			j := i - 2
			for bits[j] == 0 {
				j--
			}
			bits[i] -= 2
			bits[i-1]++
			bits[j+1] += 2
			bits[j]--
		}
	}
	i := 16
	for bits[i] == 0 {
		i--
	}
	bits[i]-- // The reserved code point.
	vals := []byte(nil)
	for n := 1; n <= 32; n++ {
		for s := 0; s < 256; s++ {
			if codesize[s] == n {
				vals = append(vals, byte(s))
			}
		}
	}
	b16 := [16]int{}
	copy(b16[:], bits[1:17])
	return makeHuff(b16, vals)
}

// bitWriter writes entropy-coded data, with byte stuffing.
type bitWriter struct {
	out   *bytes.Buffer
	acc   uint32
	n     int
	count bool // Only count symbols: write nothing.
}

func (b *bitWriter) bits(v uint32, n int) {
	if b.count || n == 0 {
		return
	}
	b.acc = b.acc<<uint(n) | (v & (1<<uint(n) - 1))
	b.n += n
	for b.n >= 8 {
		c := byte(b.acc >> uint(b.n-8))
		b.out.WriteByte(c)
		if c == 0xFF {
			b.out.WriteByte(0)
		}
		b.n -= 8
	}
}

func (b *bitWriter) flush() {
	if b.n > 0 {
		b.bits(0x7F, 8-b.n)
	}
	b.acc, b.n = 0, 0
}

// category returns the JPEG magnitude category of v and its bits.
func category(v int) (int, uint32) {
	a := v
	if a < 0 {
		a = -a
	}
	n := 0
	for a > 0 {
		n++
		a >>= 1
	}
	if v < 0 {
		return n, uint32(v + (1 << uint(n)) - 1)
	}
	return n, uint32(v)
}

type encoder struct {
	o        jpegOpts
	hmax     int
	vmax     int
	mcusX    int
	mcusY    int
	planes   [][]float64 // Per component, at its own resolution.
	pw, ph   []int
	coef     [][][64]int // Per component, per block (of the whole block grid).
	bw, bh   []int       // Per component, the block grid (MCU-padded).
	quant    [4][64]int
	freq     [8][257]int // DC 0..3, AC 4..7.
	tables   [8]*huffTable
	counting bool
}

// rgbAt is the test image's colour at (x, y): smooth gradients with some
// detail, different for each seed.
func rgbAt(x, y, w, h int, seed uint32) (float64, float64, float64) {
	fx, fy := float64(x)/float64(w+1), float64(y)/float64(h+1)
	s := float64(seed%97) / 97
	r := 128 + 100*math.Sin(6.0*fx+3*s) + 20*math.Cos(17*fy*fx)
	g := 128 + 90*math.Cos(5.0*fy-2*s+4*fx) + 25*math.Sin(float64(x*y%13))
	b := 255*fx*fy + 40*math.Sin(float64((x+y)%7))
	clamp := func(v float64) float64 { return math.Max(0, math.Min(255, v)) }
	return clamp(r), clamp(g), clamp(b)
}

// fullPlanes returns the components' samples at full resolution.
func (e *encoder) fullPlanes() [][]float64 {
	w, h := e.o.w, e.o.h
	n := len(e.o.comps)
	ps := make([][]float64, n)
	for c := range ps {
		ps[c] = make([]float64, w*h)
	}
	for y := 0; y < h; y++ {
		for x := 0; x < w; x++ {
			r, g, b := rgbAt(x, y, w, h, e.o.seed)
			yy := 0.299*r + 0.587*g + 0.114*b
			cb := 128 - 0.168736*r - 0.331264*g + 0.5*b
			cr := 128 + 0.5*r - 0.418688*g - 0.081312*b
			i := y*w + x
			k := 255 * (0.5 + 0.5*math.Sin(float64(x+2*y)/9))
			switch e.o.model {
			case "gray":
				ps[0][i] = yy
			case "ycbcr":
				ps[0][i], ps[1][i], ps[2][i] = yy, cb, cr
			case "rgb":
				ps[0][i], ps[1][i], ps[2][i] = r, g, b
			case "cmyk":
				// Adobe's convention: the samples are inverted.
				ps[0][i], ps[1][i], ps[2][i], ps[3][i] = r, g, b, 255-k
			case "ycck":
				ps[0][i], ps[1][i], ps[2][i], ps[3][i] = yy, cb, cr, 255-k
			default:
				log.Fatalf("imgcorpus: unknown model %q", e.o.model)
			}
		}
	}
	return ps
}

func encodeJPEG(o jpegOpts) []byte {
	e := &encoder{o: o}
	for _, c := range o.comps {
		if c.h > e.hmax {
			e.hmax = c.h
		}
		if c.v > e.vmax {
			e.vmax = c.v
		}
	}
	if len(o.comps) == 1 {
		// A single component's factors do not matter (Section A.2.2).
		e.hmax, e.vmax = o.comps[0].h, o.comps[0].v
	}
	e.mcusX = (o.w + 8*e.hmax - 1) / (8 * e.hmax)
	e.mcusY = (o.h + 8*e.vmax - 1) / (8 * e.vmax)

	// The quantization tables.
	for t := 0; t < 4; t++ {
		for i := 0; i < 64; i++ {
			q := stdQuant[t%2][i]
			if o.qflat > 0 {
				q = o.qflat + t
			} else {
				s := 5000 / o.quality
				if o.quality >= 50 {
					s = 200 - 2*o.quality
				}
				q = (q*s + 50) / 100
			}
			if q < 1 {
				q = 1
			} else if q > 255 {
				q = 255
			}
			e.quant[t][i] = q
		}
	}

	// Downsample, then transform and quantize every block of every
	// component's (MCU-padded) block grid.
	full := e.fullPlanes()
	for ci, c := range o.comps {
		ch, cv := c.h, c.v
		if len(o.comps) == 1 {
			ch, cv = e.hmax, e.vmax
		}
		// The component's size (Section A.1.1), and its samples: the
		// average of the full-resolution samples that each one covers.
		pw, ph := (o.w*ch+e.hmax-1)/e.hmax, (o.h*cv+e.vmax-1)/e.vmax
		span := func(i, f, fmax, limit int) (int, int) {
			lo, hi := i*fmax/f, (i+1)*fmax/f
			if hi <= lo {
				hi = lo + 1
			}
			if hi > limit {
				hi = limit
			}
			if lo >= limit {
				lo = limit - 1
			}
			return lo, hi
		}
		p := make([]float64, pw*ph)
		for y := 0; y < ph; y++ {
			y0, y1 := span(y, cv, e.vmax, o.h)
			for x := 0; x < pw; x++ {
				x0, x1 := span(x, ch, e.hmax, o.w)
				sum, n := 0.0, 0
				for yy := y0; yy < y1; yy++ {
					for xx := x0; xx < x1; xx++ {
						sum += full[ci][yy*o.w+xx]
						n++
					}
				}
				p[y*pw+x] = sum / float64(n)
			}
		}
		e.planes = append(e.planes, p)
		e.pw, e.ph = append(e.pw, pw), append(e.ph, ph)
		bw, bh := e.mcusX*c.h, e.mcusY*c.v
		if len(o.comps) == 1 {
			bw, bh = (pw+7)/8, (ph+7)/8
		}
		e.bw, e.bh = append(e.bw, bw), append(e.bh, bh)
		blocks := make([][64]int, bw*bh)
		for by := 0; by < bh; by++ {
			for bx := 0; bx < bw; bx++ {
				blocks[by*bw+bx] = e.fdct(ci, bx, by, c.tq)
			}
		}
		e.coef = append(e.coef, blocks)
	}

	// Two passes: the first only counts symbols (for optimized tables).
	if o.optimize {
		e.counting = true
		e.scans(&bytes.Buffer{})
		for t := 0; t < 8; t++ {
			total := 0
			for _, f := range e.freq[t] {
				total += f
			}
			if total > 0 {
				e.tables[t] = optimalHuff(e.freq[t])
			}
		}
		e.counting = false
	} else {
		for _, c := range o.comps {
			e.tables[c.td] = makeHuff(stdHuffBits[c.td%2], stdHuffVals[c.td%2])
			e.tables[4+c.ta] = makeHuff(stdHuffBits[2+c.ta%2], stdHuffVals[2+c.ta%2])
		}
	}

	out := &bytes.Buffer{}
	marker := func(m byte) {
		if o.fill {
			out.Write([]byte{0xFF, 0xFF})
		}
		out.Write([]byte{0xFF, m})
	}
	segment := func(m byte, payload []byte) {
		marker(m)
		binary.Write(out, binary.BigEndian, uint16(len(payload)+2))
		out.Write(payload)
	}
	marker(0xD8)
	if o.jfif {
		segment(0xE0, []byte{'J', 'F', 'I', 'F', 0, 1, 2, 0, 0, 1, 0, 1, 0, 0})
	}
	if o.adobe >= 0 {
		segment(0xEE, []byte{'A', 'd', 'o', 'b', 'e', 0, 100, 0, 0, 0, 0, byte(o.adobe)})
	}
	for _, s := range o.segments {
		out.Write(s)
	}
	used := map[int]bool{}
	for _, c := range o.comps {
		used[c.tq] = true
	}
	for t := 0; t < 4; t++ {
		if !used[t] {
			continue
		}
		p := []byte{byte(t)}
		if o.q16 {
			p[0] |= 0x10
		}
		for i := 0; i < 64; i++ {
			if o.q16 {
				p = append(p, 0)
			}
			p = append(p, byte(e.quant[t][zigzag[i]]))
		}
		segment(0xDB, p)
	}
	if o.restart > 0 && !o.driEach {
		segment(0xDD, []byte{byte(o.restart >> 8), byte(o.restart)})
	}
	dht := func() {
		for t := 0; t < 8; t++ {
			if e.tables[t] == nil {
				continue
			}
			p := []byte{byte((t/4)<<4 | t%4)}
			for _, b := range e.tables[t].bits {
				p = append(p, byte(b))
			}
			p = append(p, e.tables[t].vals...)
			segment(0xC4, p)
		}
	}
	if o.dhtFirst {
		dht()
	}
	sof := []byte{8, byte(o.h >> 8), byte(o.h), byte(o.w >> 8), byte(o.w), byte(len(o.comps))}
	for _, c := range o.comps {
		sof = append(sof, c.id, byte(c.h<<4|c.v), byte(c.tq))
	}
	segment(o.sof, sof)
	if !o.dhtEach && !o.dhtFirst {
		dht()
	}
	e.scansWith(out, func(i int) {
		if o.dhtEach {
			dht()
		}
		if o.driEach {
			r := o.restart
			if i%2 == 1 {
				r = 0
			}
			segment(0xDD, []byte{byte(r >> 8), byte(r)})
		}
	}, segment)
	marker(0xD9)
	out.Write(o.trailing)
	return out.Bytes()
}

// fdct returns the quantized coefficients (in natural order) of block (bx,
// by) of component ci.
func (e *encoder) fdct(ci, bx, by, tq int) [64]int {
	p, pw, ph := e.planes[ci], e.pw[ci], e.ph[ci]
	var s [64]float64
	for y := 0; y < 8; y++ {
		for x := 0; x < 8; x++ {
			xx, yy := bx*8+x, by*8+y
			if xx >= pw {
				xx = pw - 1
			}
			if yy >= ph {
				yy = ph - 1
			}
			s[y*8+x] = p[yy*pw+xx] - 128
		}
	}
	var out [64]int
	for v := 0; v < 8; v++ {
		for u := 0; u < 8; u++ {
			sum := 0.0
			for y := 0; y < 8; y++ {
				for x := 0; x < 8; x++ {
					sum += s[y*8+x] * math.Cos(float64(2*x+1)*float64(u)*math.Pi/16) *
						math.Cos(float64(2*y+1)*float64(v)*math.Pi/16)
				}
			}
			cu, cv := 1.0, 1.0
			if u == 0 {
				cu = 1 / math.Sqrt2
			}
			if v == 0 {
				cv = 1 / math.Sqrt2
			}
			f := sum * cu * cv / 4
			out[v*8+u] = int(math.Round(f / float64(e.quant[tq][v*8+u])))
		}
	}
	return out
}

// emit codes symbol s with table t, or counts it.
func (e *encoder) emit(w *bitWriter, t int, s int) {
	if e.counting {
		e.freq[t][s]++
		return
	}
	h := e.tables[t]
	if !h.valid[s] {
		log.Fatalf("imgcorpus: no Huffman code for symbol %#x in table %d", s, t)
	}
	w.bits(h.code[s], h.size[s])
}

type scan struct {
	comps          []int
	ss, se, ah, al int
}

func (e *encoder) scans(out *bytes.Buffer) {
	e.scansWith(out, func(int) {}, func(byte, []byte) {})
}

// scansWith writes every scan: before each, it calls before (with the
// scan's number), then writes its SOS segment with segment.
func (e *encoder) scansWith(out *bytes.Buffer, before func(int), segment func(byte, []byte)) {
	o := e.o
	all := []int{}
	for i := range o.comps {
		all = append(all, i)
	}
	ss := []scan(nil)
	switch {
	case o.sof == 0xC2:
		ss = append(ss, scan{comps: all, ss: 0, se: 0, al: o.dcAl})
		for i := range o.comps {
			if i == 0 && o.band > 0 {
				for k := 1; k <= 63; k += o.band {
					ss = append(ss, scan{comps: []int{i}, ss: k, se: min(k+o.band-1, 63)})
				}
			} else if i == 0 {
				ss = append(ss, scan{comps: []int{i}, ss: 1, se: 5}, scan{comps: []int{i}, ss: 6, se: 63})
			} else {
				ss = append(ss, scan{comps: []int{i}, ss: 1, se: 63})
			}
		}
		if o.dcAl > 0 {
			ss = append(ss, scan{comps: all, ss: 0, se: 0, ah: o.dcAl, al: 0})
		}
	case o.interleaved:
		ss = append(ss, scan{comps: all, ss: 0, se: 63})
	default:
		for i := range o.comps {
			ss = append(ss, scan{comps: []int{i}, ss: 0, se: 63})
		}
	}
	for i, sc := range ss {
		before(i)
		p := []byte{byte(len(sc.comps))}
		for _, c := range sc.comps {
			p = append(p, o.comps[c].id, byte(o.comps[c].td<<4|o.comps[c].ta))
		}
		p = append(p, byte(sc.ss), byte(sc.se), byte(sc.ah<<4|sc.al))
		segment(0xDA, p)
		e.scan(out, sc, i)
	}
}

// scan writes one scan's entropy-coded data.
func (e *encoder) scan(out *bytes.Buffer, sc scan, number int) {
	o := e.o
	w := &bitWriter{out: out, count: e.counting}
	restart := o.restart
	if o.driEach && number%2 == 1 {
		restart = 0
	}
	pred := make([]int, len(o.comps))
	units := []func(){}
	block := func(ci, bx, by int) func() {
		return func() {
			c := o.comps[ci]
			blk := &e.coef[ci][by*e.bw[ci]+bx]
			if sc.ss == 0 {
				dc := blk[0] >> uint(sc.al)
				if sc.ah > 0 {
					// DC refinement: one raw bit.
					w.bits(uint32(blk[0]>>uint(sc.al))&1, 1)
					return
				}
				n, bits := category(dc - pred[ci])
				pred[ci] = dc
				e.emit(w, c.td, n)
				w.bits(bits, n)
				if sc.se == 0 {
					return
				}
			}
			lo := sc.ss
			if lo == 0 {
				lo = 1
			}
			run := 0
			for k := lo; k <= sc.se; k++ {
				v := blk[zigzag[k]]
				if v == 0 {
					run++
					continue
				}
				for run > 15 {
					e.emit(w, 4+c.ta, 0xF0)
					run -= 16
				}
				n, bits := category(v)
				e.emit(w, 4+c.ta, run<<4|n)
				w.bits(bits, n)
				run = 0
			}
			if run > 0 {
				e.emit(w, 4+c.ta, 0x00) // EOB (an EOB run of 1 in a progressive scan).
			}
		}
	}
	if len(sc.comps) == 1 {
		// Non-interleaved: the component's blocks in raster order, over its
		// own size (not the MCU-padded grid).
		ci := sc.comps[0]
		for by := 0; by < (e.ph[ci]+7)/8; by++ {
			for bx := 0; bx < (e.pw[ci]+7)/8; bx++ {
				units = append(units, block(ci, bx, by))
			}
		}
	} else {
		for my := 0; my < e.mcusY; my++ {
			for mx := 0; mx < e.mcusX; mx++ {
				fs := []func(){}
				for _, ci := range sc.comps {
					c := o.comps[ci]
					for v := 0; v < c.v; v++ {
						for h := 0; h < c.h; h++ {
							fs = append(fs, block(ci, mx*c.h+h, my*c.v+v))
						}
					}
				}
				units = append(units, func() {
					for _, f := range fs {
						f()
					}
				})
			}
		}
	}
	for i, u := range units {
		if restart > 0 && i > 0 && i%restart == 0 {
			w.flush()
			if !w.count {
				out.Write([]byte{0xFF, byte(0xD0 + (i/restart-1)%8)})
			}
			for k := range pred {
				pred[k] = 0
			}
		}
		u()
	}
	w.flush()
}

// ---- The corpus.

// jpegHeader returns the frame type (the SOF marker) of a JPEG and whether
// any of its components is subsampled, or ok = false.
func jpegHeader(data []byte) (sof byte, subsampled bool, ok bool) {
	for i := 2; i+4 <= len(data); {
		if data[i] != 0xFF {
			return 0, false, false
		}
		m := data[i+1]
		if m == 0xFF {
			i++
			continue
		}
		n := int(data[i+2])<<8 | int(data[i+3])
		if 0xC0 <= m && m <= 0xCF && m != 0xC4 && m != 0xC8 && m != 0xCC {
			if i+4+n-2 > len(data) || n < 8 {
				return 0, false, false
			}
			p := data[i+4 : i+2+n]
			nc := int(p[5])
			if len(p) < 6+3*nc || nc == 0 {
				return 0, false, false
			}
			h0, v0 := p[7]>>4, p[7]&15
			for c := 1; c < nc; c++ {
				if p[7+3*c]>>4 != h0 || p[7+3*c]&15 != v0 {
					subsampled = true
				}
			}
			return m, subsampled && nc > 1, true
		}
		i += 2 + n
	}
	return 0, false, false
}

// jpegCategory is how a JPEG's pixels are compared with Go's image/jpeg: the
// category's name (for test_image's report) and the largest per-channel
// difference that is accepted (jpegMeanLimit gives the largest mean
// difference). The two decoders legitimately differ:
//
//   - in the inverse DCT: Wuffs ports libjpeg-turbo's "islow" integer
//     transform, Go has its own integer transform, and their rounding
//     differs by one here and there (gray images: measured 1 at most, mean
//     0.03);
//   - in the colour conversion's rounding (measured 3 at most, mean 0.50,
//     with the inverse DCT's differences, for YCbCr, RGB, CMYK and YCCK
//     images without subsampling);
//   - in chroma upsampling: Wuffs' default is libjpeg's triangle filter
//     ("fancy"), Go's is a box filter. With base.QUIRK_QUALITY set for
//     lower quality, Wuffs uses a box filter too (measured 4 at most, mean
//     0.32). Otherwise they differ near every chroma edge (measured 77 at
//     most, on upstream's bricks-color.jpeg, mean 8.16 on images of a few
//     pixels, which are all edge): there the wide limits only catch gross
//     errors (planes swapped or misplaced, a wrong colour model);
//   - for an incomplete progressive image (upstream's
//     peacock.progressive.scan00N.jpeg), Wuffs smooths the blocks, as
//     libjpeg-turbo does, and Go does not: those are only reported.
//
// The limits are a little above what was measured (the corpus is
// deterministic); test_image prints what it measures, test.sh shows it.
// jpegMeanLimit is the largest mean per-channel difference (in hundredths)
// that a run of category cat may have: with a wide tolerance for single
// pixels, it is what catches a gross error.
func jpegMeanLimit(cat string) int {
	switch {
	case cat == "progressive-partial":
		return 25500
	case strings.HasSuffix(cat, "-fancy"):
		return 1200
	case cat == "gray":
		return 50
	}
	return 100
}

func jpegCategory(m image.Image, subsampled bool, lowerQuality bool) (string, int) {
	model := ""
	switch m.(type) {
	case *image.Gray:
		return "gray", 2
	case *image.CMYK:
		model = "cmyk-ycck"
	case *image.RGBA:
		model = "rgb"
	case *image.YCbCr:
		model = "ycbcr"
	default:
		return "", 0
	}
	switch {
	case !subsampled:
		return model + "-444", 4
	case lowerQuality:
		return model + "-subsampled-box", 5
	}
	return model + "-subsampled-fancy", 96
}

// jpegReference decodes data with Go's image/jpeg: the BGRA pixels and the
// comparison's category and tolerance, or nil.
func jpegReference(data []byte, lowerQuality bool) (*reference, string, int) {
	m, err := jpeg.Decode(bytes.NewReader(data))
	if err != nil {
		return nil, "", 0
	}
	_, subsampled, ok := jpegHeader(data)
	if !ok {
		return nil, "", 0
	}
	cat, tol := jpegCategory(m, subsampled, lowerQuality)
	if cat == "" {
		return nil, "", 0
	}
	b := m.Bounds()
	ref := &reference{x0: 0, y0: 0, x1: b.Dx(), y1: b.Dy()}
	for y := b.Min.Y; y < b.Max.Y; y++ {
		for x := b.Min.X; x < b.Max.X; x++ {
			var r, g, bl uint8
			switch m := m.(type) {
			case *image.YCbCr:
				c := m.YCbCrAt(x, y)
				r, g, bl = color.YCbCrToRGB(c.Y, c.Cb, c.Cr)
			case *image.Gray:
				r = m.GrayAt(x, y).Y
				g, bl = r, r
			case *image.CMYK:
				c := m.CMYKAt(x, y)
				r, g, bl = color.CMYKToRGB(c.C, c.M, c.Y, c.K)
			case *image.RGBA:
				c := m.RGBAAt(x, y)
				r, g, bl = c.R, c.G, c.B
			}
			ref.bgra = append(ref.bgra, bl, g, r, 0xFF)
		}
	}
	return ref, cat, tol
}

func appSegment(m byte, payload []byte) []byte {
	b := []byte{0xFF, m, byte((len(payload) + 2) >> 8), byte(len(payload) + 2)}
	return append(b, payload...)
}

// makeJPEGs writes the encoder's images and adds the checked-in ones from
// dir. The first return value counts the encoder's images, the second the
// checked-in ones.
func makeJPEGs(dir string) (int, int) {
	n := 0
	add1 := func(name string, o jpegOpts) {
		if o.quality == 0 {
			o.quality = 75
		}
		data := encodeJPEG(o)
		if o.q16 || (o.band > 0 && o.band < 3) {
			// Go's decoder accepts 16-bit quantization tables and more than
			// 32 scans, std/jpeg rejects them ("#unsupported precision",
			// "#unsupported scan count"): no reference.
			add("jpeg", name, data, nil)
		} else {
			addJPEG(name, data)
		}
		n++
	}
	ycc := func(hv ...int) []jcomp {
		cs := []jcomp{}
		for i := 0; i+1 < len(hv); i += 2 {
			t := 0
			if i > 0 {
				t = 1
			}
			cs = append(cs, jcomp{id: byte(1 + i/2), h: hv[i], v: hv[i+1], tq: t, td: t, ta: t})
		}
		return cs
	}

	// Sampling factors: the usual ones, then everything that std/jpeg
	// accepts (factors 1, 2 and 4 together, or 1 and 3), within the limit of
	// 10 blocks per MCU, then mixtures that it rejects.
	type sub struct {
		name string
		hv   []int
	}
	subs := []sub{
		{"444", []int{1, 1, 1, 1, 1, 1}}, {"422", []int{2, 1, 1, 1, 1, 1}}, {"420", []int{2, 2, 1, 1, 1, 1}},
		{"440", []int{1, 2, 1, 1, 1, 1}}, {"411", []int{4, 1, 1, 1, 1, 1}}, {"410", []int{4, 2, 1, 1, 1, 1}},
		{"14", []int{1, 4, 1, 1, 1, 1}}, {"31", []int{3, 1, 1, 1, 1, 1}}, {"13", []int{1, 3, 1, 1, 1, 1}},
		{"32", []int{3, 2, 1, 1, 1, 1}}, {"22-21-12", []int{2, 2, 2, 1, 1, 2}}, {"12-21-11", []int{1, 2, 2, 1, 1, 1}},
		{"11-22-11", []int{1, 1, 2, 2, 1, 1}}, {"21-11-12", []int{2, 1, 1, 1, 1, 2}}, {"41-21-11", []int{4, 1, 2, 1, 1, 1}},
		{"24-11-11", []int{2, 4, 1, 1, 1, 1}}, {"31-13-11", []int{3, 1, 1, 3, 1, 1}}, {"33-31-13", []int{3, 3, 3, 1, 1, 3}},
		// More than 10 blocks in an MCU, which the specification forbids.
		{"22-22-22", []int{2, 2, 2, 2, 2, 2}}, {"33-11-11", []int{3, 3, 1, 1, 1, 1}}, {"44-11-11", []int{4, 4, 1, 1, 1, 1}},
		// Rejected: "#unsupported fractional sampling".
		{"32-21-11", []int{3, 2, 2, 1, 1, 1}}, {"21-31-11", []int{2, 1, 3, 1, 1, 1}},
	}
	sizes := [][2]int{{1, 1}, {7, 5}, {17, 9}, {33, 31}, {64, 48}}
	for i, s := range subs {
		for j, size := range sizes {
			if j == 4 && i%3 != 0 {
				continue
			}
			o := jpegOpts{w: size[0], h: size[1], comps: ycc(s.hv...), jfif: true, adobe: -1, sof: 0xC0,
				interleaved: true, model: "ycbcr", seed: uint32(i*7 + j), quality: 60 + 5*j}
			add1(fmt.Sprintf("enc-%s-%dx%d.jpeg", s.name, size[0], size[1]), o)
			if j == 2 || j == 3 {
				o.sof = 0xC2
				o.dcAl = j - 2
				o.optimize = j == 3
				add1(fmt.Sprintf("enc-%s-%dx%d-prog.jpeg", s.name, size[0], size[1]), o)
			}
		}
	}

	// Colour models.
	gray := []jcomp{{id: 1, h: 1, v: 1}}
	for _, size := range [][2]int{{1, 1}, {9, 7}, {50, 3}, {3, 50}} {
		add1(fmt.Sprintf("enc-gray-%dx%d.jpeg", size[0], size[1]),
			jpegOpts{w: size[0], h: size[1], comps: gray, jfif: true, adobe: -1, sof: 0xC0, interleaved: true, model: "gray"})
	}
	add1("enc-gray-h2v2.jpeg", jpegOpts{w: 21, h: 13, comps: []jcomp{{id: 1, h: 2, v: 2}}, adobe: -1, sof: 0xC0,
		interleaved: true, model: "gray"})
	add1("enc-gray-prog.jpeg", jpegOpts{w: 27, h: 19, comps: gray, adobe: -1, sof: 0xC2, dcAl: 1, model: "gray"})
	rgbIDs := []jcomp{{id: 'R', h: 1, v: 1}, {id: 'G', h: 1, v: 1}, {id: 'B', h: 1, v: 1}}
	add1("enc-rgb-ids.jpeg", jpegOpts{w: 23, h: 17, comps: rgbIDs, adobe: -1, sof: 0xC0, interleaved: true, model: "rgb"})
	add1("enc-rgb-ids-jfif.jpeg", jpegOpts{w: 23, h: 17, comps: rgbIDs, jfif: true, adobe: -1, sof: 0xC0,
		interleaved: true, model: "ycbcr"})
	add1("enc-rgb-adobe0.jpeg", jpegOpts{w: 19, h: 23, comps: ycc(1, 1, 1, 1, 1, 1), adobe: 0, sof: 0xC0,
		interleaved: true, model: "rgb"})
	add1("enc-rgb-adobe0-sub.jpeg", jpegOpts{w: 19, h: 23, comps: ycc(2, 2, 1, 1, 1, 1), adobe: 0, sof: 0xC0,
		interleaved: true, model: "rgb"})
	add1("enc-ycc-noapp.jpeg", jpegOpts{w: 19, h: 23, comps: ycc(2, 1, 1, 1, 1, 1), adobe: -1, sof: 0xC0,
		interleaved: true, model: "ycbcr"})
	add1("enc-ycc-adobe1.jpeg", jpegOpts{w: 19, h: 23, comps: ycc(2, 2, 1, 1, 1, 1), adobe: 1, sof: 0xC0,
		interleaved: true, model: "ycbcr"})
	four := func(hv ...int) []jcomp {
		cs := ycc(hv[:6]...)
		return append(cs, jcomp{id: 4, h: hv[6], v: hv[7], tq: 2, td: 0, ta: 0})
	}
	for i, hv := range [][]int{{1, 1, 1, 1, 1, 1, 1, 1}, {2, 2, 1, 1, 1, 1, 2, 2}, {2, 1, 1, 1, 1, 1, 1, 1}, {1, 1, 1, 1, 1, 1, 2, 2}} {
		for _, size := range [][2]int{{1, 1}, {13, 11}, {40, 24}} {
			add1(fmt.Sprintf("enc-cmyk-%d-%dx%d.jpeg", i, size[0], size[1]), jpegOpts{w: size[0], h: size[1],
				comps: four(hv...), adobe: 0, sof: 0xC0, interleaved: true, model: "cmyk", seed: uint32(i)})
			add1(fmt.Sprintf("enc-ycck-%d-%dx%d.jpeg", i, size[0], size[1]), jpegOpts{w: size[0], h: size[1],
				comps: four(hv...), adobe: 2, sof: 0xC0, interleaved: true, model: "ycck", seed: uint32(i)})
		}
		add1(fmt.Sprintf("enc-cmyk-%d-noadobe.jpeg", i), jpegOpts{w: 13, h: 11, comps: four(hv...), adobe: -1,
			sof: 0xC0, interleaved: true, model: "cmyk"})
		add1(fmt.Sprintf("enc-ycck-%d-prog.jpeg", i), jpegOpts{w: 29, h: 21, comps: four(hv...), adobe: 2,
			sof: 0xC2, dcAl: i % 2, model: "ycck", optimize: true})
		add1(fmt.Sprintf("enc-cmyk-%d-seq.jpeg", i), jpegOpts{w: 29, h: 21, comps: four(hv...), adobe: 0,
			sof: 0xC0, model: "cmyk"})
	}

	// Restart intervals: every MCU, odd intervals, longer than the image, in
	// progressive scans, and changing between scans.
	for _, r := range []int{1, 2, 3, 7, 64, 1000} {
		add1(fmt.Sprintf("enc-rst%d-420.jpeg", r), jpegOpts{w: 45, h: 37, comps: ycc(2, 2, 1, 1, 1, 1), jfif: true,
			adobe: -1, sof: 0xC0, interleaved: true, restart: r, model: "ycbcr"})
		add1(fmt.Sprintf("enc-rst%d-gray.jpeg", r), jpegOpts{w: 45, h: 37, comps: gray, adobe: -1, sof: 0xC0,
			interleaved: true, restart: r, model: "gray"})
	}
	add1("enc-rst2-prog.jpeg", jpegOpts{w: 45, h: 37, comps: ycc(2, 1, 1, 1, 1, 1), jfif: true, adobe: -1,
		sof: 0xC2, restart: 2, model: "ycbcr", dcAl: 1})
	add1("enc-rst3-dri-each-prog.jpeg", jpegOpts{w: 45, h: 37, comps: ycc(1, 2, 1, 1, 1, 1), jfif: true, adobe: -1,
		sof: 0xC2, restart: 3, driEach: true, model: "ycbcr"})
	add1("enc-rst5-dri-each-seq.jpeg", jpegOpts{w: 45, h: 37, comps: ycc(2, 2, 1, 1, 1, 1), jfif: true, adobe: -1,
		sof: 0xC0, restart: 5, driEach: true, model: "ycbcr"})
	add1("enc-rst4-cmyk.jpeg", jpegOpts{w: 45, h: 37, comps: four(2, 2, 1, 1, 1, 1, 2, 2), adobe: 0, sof: 0xC0,
		interleaved: true, restart: 4, model: "cmyk"})

	// Sequential images in several scans, optimized tables, tables before
	// each scan, quantization, fill bytes, SOF1.
	add1("enc-multiscan-420.jpeg", jpegOpts{w: 35, h: 26, comps: ycc(2, 2, 1, 1, 1, 1), jfif: true, adobe: -1,
		sof: 0xC0, model: "ycbcr"})
	add1("enc-multiscan-444-dht-each.jpeg", jpegOpts{w: 35, h: 26, comps: ycc(1, 1, 1, 1, 1, 1), jfif: true,
		adobe: -1, sof: 0xC0, model: "ycbcr", dhtEach: true, optimize: true})
	add1("enc-multiscan-rst.jpeg", jpegOpts{w: 35, h: 26, comps: ycc(1, 2, 1, 1, 1, 1), jfif: true, adobe: -1,
		sof: 0xC0, model: "ycbcr", restart: 3})
	add1("enc-dht-first.jpeg", jpegOpts{w: 35, h: 26, comps: ycc(2, 1, 1, 1, 1, 1), jfif: true, adobe: -1,
		sof: 0xC0, interleaved: true, dhtFirst: true, model: "ycbcr"})
	add1("enc-dht-first-prog.jpeg", jpegOpts{w: 35, h: 26, comps: ycc(2, 1, 1, 1, 1, 1), jfif: true, adobe: -1,
		sof: 0xC2, dhtFirst: true, model: "ycbcr"})
	add1("enc-dht-each-prog.jpeg", jpegOpts{w: 35, h: 26, comps: ycc(1, 1, 2, 2, 1, 1), jfif: true, adobe: -1,
		sof: 0xC2, dhtEach: true, optimize: true, model: "ycbcr"})
	add1("enc-optimized-420.jpeg", jpegOpts{w: 61, h: 41, comps: ycc(2, 2, 1, 1, 1, 1), jfif: true, adobe: -1,
		sof: 0xC0, interleaved: true, optimize: true, model: "ycbcr"})
	add1("enc-sof1.jpeg", jpegOpts{w: 21, h: 13, comps: ycc(2, 1, 1, 1, 1, 1), jfif: true, adobe: -1, sof: 0xC1,
		interleaved: true, model: "ycbcr"})
	for _, q := range []int{1, 2, 255} {
		add1(fmt.Sprintf("enc-qflat%d.jpeg", q), jpegOpts{w: 30, h: 22, comps: ycc(2, 1, 1, 1, 1, 1), jfif: true,
			adobe: -1, sof: 0xC0, interleaved: true, qflat: q, model: "ycbcr"})
	}
	for _, q := range []int{1, 10, 100} {
		add1(fmt.Sprintf("enc-quality%d.jpeg", q), jpegOpts{w: 30, h: 22, comps: ycc(2, 2, 1, 1, 1, 1), jfif: true,
			adobe: -1, sof: 0xC0, interleaved: true, quality: q, model: "ycbcr"})
	}
	add1("enc-tq3.jpeg", jpegOpts{w: 30, h: 22, comps: []jcomp{{id: 1, h: 1, v: 1, tq: 3}, {id: 2, h: 1, v: 1, tq: 2,
		td: 1, ta: 1}, {id: 3, h: 1, v: 1, tq: 2, td: 1, ta: 1}}, jfif: true, adobe: -1, sof: 0xC0, interleaved: true,
		model: "ycbcr"})
	add1("enc-fill.jpeg", jpegOpts{w: 30, h: 22, comps: ycc(2, 2, 1, 1, 1, 1), jfif: true, adobe: -1, sof: 0xC0,
		interleaved: true, fill: true, model: "ycbcr"})

	// Odd sizes: very wide, very tall.
	for _, size := range [][2]int{{1000, 1}, {1, 1000}, {2000, 3}, {3, 700}, {257, 1}} {
		add1(fmt.Sprintf("enc-420-%dx%d.jpeg", size[0], size[1]), jpegOpts{w: size[0], h: size[1],
			comps: ycc(2, 2, 1, 1, 1, 1), jfif: true, adobe: -1, sof: 0xC0, interleaved: true, model: "ycbcr"})
	}
	add1("enc-gray-1x1000-prog.jpeg", jpegOpts{w: 1, h: 1000, comps: gray, adobe: -1, sof: 0xC2, model: "gray"})
	add1("enc-411-1000x2-prog.jpeg", jpegOpts{w: 1000, h: 2, comps: ycc(4, 1, 1, 1, 1, 1), jfif: true, adobe: -1,
		sof: 0xC2, model: "ycbcr"})

	// Metadata and trailing data.
	exif := appSegment(0xE1, append([]byte("Exif\x00\x00MM\x00\x2a\x00\x00\x00\x08"), make([]byte, 40)...))
	icc := appSegment(0xE2, append([]byte("ICC_PROFILE\x00\x01\x01"), make([]byte, 300)...))
	com := appSegment(0xFE, []byte("a comment"))
	app15 := appSegment(0xEF, []byte("whatever"))
	empty := []byte{0xFF, 0xE5, 0x00, 0x00} // An APPn length below 2, which libjpeg-turbo allows.
	notJFIF := appSegment(0xE0, []byte("JFXX\x00\x10"))
	notAdobe := appSegment(0xEE, []byte("Adobx\x00\x64\x00\x00\x00\x00\x02"))
	shortAdobe := appSegment(0xEE, []byte("Adobe"))
	add1("enc-metadata.jpeg", jpegOpts{w: 25, h: 18, comps: ycc(2, 2, 1, 1, 1, 1), jfif: true, adobe: -1, sof: 0xC0,
		interleaved: true, model: "ycbcr", segments: [][]byte{exif, icc, com, app15, empty, notJFIF, notAdobe, shortAdobe},
		trailing: []byte("trailing data after EOI \xFF\xD8\xFF")})
	add1("enc-metadata-prog.jpeg", jpegOpts{w: 25, h: 18, comps: ycc(2, 1, 1, 1, 1, 1), jfif: true, adobe: -1,
		sof: 0xC2, model: "ycbcr", segments: [][]byte{com, exif}, trailing: make([]byte, 100)})

	// Rejected kinds of frames and tables.
	for _, sof := range []byte{0xC3, 0xC5, 0xC6, 0xC7, 0xC9, 0xCA, 0xCB, 0xCD, 0xCE, 0xCF} {
		add1(fmt.Sprintf("enc-sof%02x.jpeg", sof), jpegOpts{w: 9, h: 9, comps: gray, adobe: -1, sof: sof,
			interleaved: true, model: "gray"})
	}
	add1("enc-dqt16.jpeg", jpegOpts{w: 9, h: 9, comps: gray, adobe: -1, sof: 0xC0, interleaved: true, q16: true,
		model: "gray"})

	// Many scans: 22 (accepted), 33 and 64 ("#unsupported scan count" from
	// the 33rd on).
	for _, band := range []int{3, 2, 1} {
		add1(fmt.Sprintf("enc-band%d-prog.jpeg", band), jpegOpts{w: 20, h: 12, comps: gray, adobe: -1, sof: 0xC2,
			band: band, model: "gray"})
	}

	// Frame headers that std/jpeg rejects: 12-bit, 16-bit and other
	// precisions, no height (it would come in a DNL segment), no width.
	plain := encodeJPEG(jpegOpts{w: 9, h: 7, comps: ycc(1, 1, 1, 1, 1, 1), jfif: true, adobe: -1, sof: 0xC0,
		interleaved: true, model: "ycbcr", quality: 75})
	sof := bytes.Index(plain, []byte{0xFF, 0xC0})
	for _, p := range []struct {
		name  string
		at    int
		value byte
	}{{"precision12", 4, 12}, {"precision16", 4, 16}, {"precision7", 4, 7}, {"height0", 6, 0}, {"width0", 8, 0}} {
		d := append([]byte(nil), plain...)
		d[sof+p.at] = p.value
		if p.name == "height0" || p.name == "width0" {
			d[sof+p.at-1] = 0
		}
		add("jpeg", "enc-sof-"+p.name+".jpeg", d, nil)
		n++
	}
	return n, addCheckedInJPEGs(dir)
}

// addJPEG adds a JPEG to the corpus, with Go's pixels as the reference
// (twice: for Wuffs' default chroma upsampling and for the box filter that
// base.QUIRK_QUALITY selects).
func addJPEG(name string, data []byte) {
	setJPEGReference(add("jpeg", name, data, nil), name)
}

// setJPEGReference gives the JPEG f its reference pixels, if Go decodes it.
func setJPEGReference(f *file, name string) {
	data := f.data
	if ref, cat, tol := jpegReference(data, false); ref != nil {
		f.expected = writeReference(name, ref)
		f.jpegCat, f.jpegTol = cat, tol
		if _, boxCat, boxTol := jpegReference(data, true); boxCat != cat {
			f.jpegBoxCat, f.jpegBoxTol = boxCat, boxTol
		}
		if strings.Contains(f.path, ".scan00") {
			// Upstream's peacock.progressive.scan00N.jpeg: the first N
			// scans of a progressive image. Wuffs smooths the blocks of an
			// incomplete progressive image, as libjpeg-turbo does, and Go
			// does not: the pixels are only reported.
			f.jpegCat, f.jpegTol, f.jpegBoxCat, f.jpegBoxTol = "progressive-partial", 255, "", 0
		}
		// Only a sequential image in one scan can be converted MCU by MCU
		// (with lower quality and a short work buffer).
		sof, _, _ := jpegHeader(data)
		f.jpegWholeWorkbuf = sof == 0xC2 || bytes.Count(data, []byte{0xFF, 0xDA}) > 1
	}
}

// addCheckedInJPEGs adds the JPEG files of dir (see its make.py).
func addCheckedInJPEGs(dir string) int {
	paths := []string(nil)
	filepath.WalkDir(dir, func(path string, d fs.DirEntry, err error) error {
		if err == nil && !d.IsDir() && strings.HasSuffix(path, ".jpeg") {
			paths = append(paths, path)
		}
		return nil
	})
	sort.Strings(paths)
	for _, p := range paths {
		data, err := os.ReadFile(p)
		if err != nil {
			log.Fatal(err)
		}
		addJPEG("pil-"+filepath.Base(p), data)
	}
	return len(paths)
}

// jpegDamage writes damaged copies of a JPEG: at its markers (the marker
// byte, the length, the first payload bytes), and with markers inserted into
// its entropy-coded data. It returns their paths.
func jpegDamage(base string, data []byte) []string {
	paths := []string(nil)
	write := func(suffix string, d []byte) {
		p := filepath.Join(outDir, base+suffix)
		if err := os.WriteFile(p, d, 0o644); err != nil {
			log.Fatal(err)
		}
		paths = append(paths, p)
	}
	k := 0
	for i := 0; i+1 < len(data) && k < 40; i++ {
		if data[i] != 0xFF || data[i+1] == 0 || data[i+1] == 0xFF {
			continue
		}
		k++
		for j, delta := range []int{1, 2, 3, 5} {
			if i+delta >= len(data) {
				continue
			}
			d := append([]byte(nil), data...)
			switch j {
			case 0:
				d[i+1] ^= byte(1 << uint(k%8))
			case 1:
				d[i+2] ^= 0x80
			case 2:
				d[i+3] = byte(k * 7)
			default:
				d[i+delta] = 0xFF
			}
			write(fmt.Sprintf("-m%d-%d", i, j), d)
		}
	}
	// A marker in the middle of the entropy-coded data of the first scan.
	if sos := bytes.Index(data, []byte{0xFF, 0xDA}); sos >= 0 && sos+20 < len(data) {
		for _, m := range []byte{0xD0, 0xD3, 0xD7, 0xD9, 0xC4, 0xDB, 0xDD, 0xE0, 0x01} {
			at := sos + 14 + (len(data)-sos-16)*int(m)/256
			if at+2 > len(data) {
				continue
			}
			d := append(append(append([]byte(nil), data[:at]...), 0xFF, m), data[at:]...)
			write(fmt.Sprintf("-i%02x", m), d)
		}
	}
	return paths
}
