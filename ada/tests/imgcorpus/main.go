// Part of wuffada (wuffs-ada: Wuffs to Ada).
// SPDX-License-Identifier: Apache-2.0 OR MIT

// imgcorpus builds the test corpus for the generated image decoders
// (netpbm, bmp, gif, png, and without images of this program's own: wbmp,
// nie, targa).
//
// Usage: imgcorpus -data wuffs/test/data -out DIR [-chaos FILE] > manifest
//
// It takes every image of those formats in upstream's test data, writes
// images of its own to DIR (PNGs of every colour type and bit depth,
// interlaced or not, from an encoder in this file and from Go's image/png;
// animated GIFs from Go's image/gif; BMP and Netpbm variants; and truncated
// and corrupted copies), and prints a manifest, one line per run:
//
//	FORMAT PIXFMT BLEND SCHEDULE FLAGS SCRIPT EXPECTED PATH
//
// See ada/tests/test_image.adb for what the fields mean. EXPECTED is "-" or
// a file of the first frame's pixels as an independent decoder gives them:
// Go's image/png and image/gif for PNG and GIF, and for the BMP and Netpbm
// images that this program writes, the pixels that it encoded. Every run
// must also behave exactly as upstream's C decoder does, which is all there
// is to check for the truncated and corrupted inputs.
package main

import (
	"bytes"
	"compress/zlib"
	"encoding/binary"
	"flag"
	"fmt"
	"hash/crc32"
	"image"
	"image/color"
	"image/gif"
	"image/png"
	"io/fs"
	"log"
	"os"
	"path/filepath"
	"sort"
	"strings"
)

const (
	maxFileSize = 4 * 1024 * 1024

	bgraNonpremul = 0x81008888
)

// The destination pixel formats.
var pixfmts = []uint32{
	bgraNonpremul,
	0x82008888, // BGRA_PREMUL
	0xA1008888, // RGBA_NONPREMUL
	0xA2008888, // RGBA_PREMUL
	0xA0000888, // RGB
	0x80000888, // BGR
	0x90008888, // BGRX
	0x80000565, // BGR_565
	0x20000008, // Y
	0x8100BBBB, // BGRA_NONPREMUL_4X16LE
	0x81040008, // INDEXED__BGRA_NONPREMUL
	0x83040008, // INDEXED__BGRA_BINARY
}

var gifQuirks = []uint32{983928832, 983928833, 983928834, 983928835, 983928836, 983928837, 983928838}

// The call sequences other than the usual one.
var scripts = []string{
	"F", "FF*", "CF", "C*", "*", "II", "IFF", "ICC*", "iC*", "Ic*", "icF", "IR*", "I*RR*", "I*r*",
	"T", "IT*", "IFrF", "I*I", "rI*", "RI*", "I*RCRCF", "I*RFC",
}

type file struct {
	format   string
	path     string
	data     []byte
	expected string // The reference pixels' file, or "".
	upstream bool
}

var (
	outDir string
	files  []*file
	rng    = uint32(12345)
)

func rnd() uint32 {
	rng = rng*1664525 + 1013904223
	return rng >> 8
}

func add(format string, name string, data []byte, ref *reference) *file {
	path := filepath.Join(outDir, name)
	if err := os.WriteFile(path, data, 0o644); err != nil {
		log.Fatal(err)
	}
	f := &file{format: format, path: path, data: data}
	if ref != nil {
		f.expected = writeReference(name, ref)
	}
	files = append(files, f)
	return f
}

// reference is a frame's pixels as BGRA (not premultiplied), with its bounds.
type reference struct {
	x0, y0, x1, y1 int
	bgra           []byte
}

func writeReference(name string, r *reference) string {
	b := make([]byte, 16, 16+len(r.bgra))
	binary.LittleEndian.PutUint32(b[0:], uint32(r.x0))
	binary.LittleEndian.PutUint32(b[4:], uint32(r.y0))
	binary.LittleEndian.PutUint32(b[8:], uint32(r.x1))
	binary.LittleEndian.PutUint32(b[12:], uint32(r.y1))
	b = append(b, r.bgra...)
	if len(b) > maxFileSize {
		return ""
	}
	path := filepath.Join(outDir, name+".expected")
	if err := os.WriteFile(path, b, 0o644); err != nil {
		log.Fatal(err)
	}
	return path
}

// exactBGRA returns c as BGRA that is not premultiplied, if that is exact
// (taking the high byte of a 16-bit channel).
func exactBGRA(c color.Color) ([4]byte, bool) {
	switch c := c.(type) {
	case color.NRGBA:
		return [4]byte{c.B, c.G, c.R, c.A}, true
	case color.NRGBA64:
		return [4]byte{byte(c.B >> 8), byte(c.G >> 8), byte(c.R >> 8), byte(c.A >> 8)}, true
	case color.RGBA:
		if c.A == 0xFF {
			return [4]byte{c.B, c.G, c.R, 0xFF}, true
		} else if c.A == 0 {
			return [4]byte{}, true
		}
	case color.RGBA64:
		if c.A == 0xFFFF {
			return [4]byte{byte(c.B >> 8), byte(c.G >> 8), byte(c.R >> 8), 0xFF}, true
		}
	case color.Gray:
		return [4]byte{c.Y, c.Y, c.Y, 0xFF}, true
	case color.Gray16:
		y := byte(c.Y >> 8)
		return [4]byte{y, y, y, 0xFF}, true
	}
	return [4]byte{}, false
}

// referenceOf returns the pixels of m within r, or nil if they are not exact.
func referenceOf(m image.Image, r image.Rectangle) *reference {
	ref := &reference{x0: r.Min.X, y0: r.Min.Y, x1: r.Max.X, y1: r.Max.Y}
	for y := r.Min.Y; y < r.Max.Y; y++ {
		for x := r.Min.X; x < r.Max.X; x++ {
			p, ok := exactBGRA(m.At(x, y))
			if !ok {
				return nil
			}
			ref.bgra = append(ref.bgra, p[:]...)
		}
	}
	return ref
}

// goReference decodes data with Go's decoder for the format.
func goReference(format string, data []byte) *reference {
	switch format {
	case "png":
		if bytes.Contains(data, []byte("acTL")) {
			// An animated PNG: Go decodes the default image, which need not
			// be the first frame.
			return nil
		}
		m, err := png.Decode(bytes.NewReader(data))
		if err != nil {
			return nil
		}
		return referenceOf(m, m.Bounds())
	case "gif":
		g, err := gif.DecodeAll(bytes.NewReader(data))
		if err != nil || len(g.Image) == 0 {
			return nil
		}
		r := g.Image[0].Bounds().Intersect(image.Rect(0, 0, g.Config.Width, g.Config.Height))
		if r.Empty() {
			return nil
		}
		return referenceOf(g.Image[0], r)
	}
	return nil
}

// ---- PNG, by hand: every colour type and bit depth, interlaced or not.

func pngChunk(w *bytes.Buffer, typ string, data []byte) {
	binary.Write(w, binary.BigEndian, uint32(len(data)))
	b := append([]byte(typ), data...)
	w.Write(b)
	binary.Write(w, binary.BigEndian, crc32.ChecksumIEEE(b))
}

func paeth(a, b, c int) int {
	p := a + b - c
	pa, pb, pc := p-a, p-b, p-c
	if pa < 0 {
		pa = -pa
	}
	if pb < 0 {
		pb = -pb
	}
	if pc < 0 {
		pc = -pc
	}
	if pa <= pb && pa <= pc {
		return a
	} else if pb <= pc {
		return b
	}
	return c
}

// pngRows filters the rows of one (sub)image whose rows are stride bytes of
// raw samples each, with filter types that cycle or are fixed.
func pngRows(out *bytes.Buffer, raw []byte, stride int, bpp int, filter int) {
	if stride == 0 {
		return
	}
	prev := make([]byte, stride)
	for y := 0; y*stride < len(raw); y++ {
		cur := raw[y*stride : (y+1)*stride]
		ft := filter
		if ft < 0 {
			ft = y % 5
		}
		out.WriteByte(byte(ft))
		for i := range cur {
			a, b, c := 0, int(prev[i]), 0
			if i >= bpp {
				a, c = int(cur[i-bpp]), int(prev[i-bpp])
			}
			x := int(cur[i])
			switch ft {
			case 1:
				x -= a
			case 2:
				x -= b
			case 3:
				x -= (a + b) / 2
			case 4:
				x -= paeth(a, b, c)
			}
			out.WriteByte(byte(x))
		}
		prev = cur
	}
}

// makePNG encodes a w by h image of random samples. colorType and depth are
// as in the PNG specification; filter is 0 to 4, or -1 to cycle; trns adds a
// tRNS chunk.
func makePNG(w, h int, colorType, depth int, interlace bool, filter int, trns bool, level int) []byte {
	channels := map[int]int{0: 1, 2: 3, 3: 1, 4: 2, 6: 4}[colorType]
	bitsPerPixel := channels * depth
	bpp := (bitsPerPixel + 7) / 8

	// The samples, one per byte (or two for 16 bits), before packing.
	sample := func() uint32 {
		v := rnd()
		if colorType == 3 {
			return v % (1 << uint(depth))
		}
		// Runs of equal values, so that the filters have something to do.
		if v%4 != 0 {
			return (v >> 3) % 3 * ((1 << uint(depth)) - 1) / 2
		}
		return (v >> 3) % (1 << uint(depth))
	}
	px := make([][]uint32, h)
	for y := range px {
		px[y] = make([]uint32, w*channels)
		for i := range px[y] {
			px[y][i] = sample()
		}
	}
	pack := func(xs []int, y int) []byte {
		row := make([]byte, (len(xs)*bitsPerPixel+7)/8)
		bit := 0
		for _, x := range xs {
			for c := 0; c < channels; c++ {
				v := px[y][x*channels+c]
				if depth == 16 {
					row[bit/8] = byte(v >> 8)
					row[bit/8+1] = byte(v)
				} else if depth == 8 {
					row[bit/8] = byte(v)
				} else {
					row[bit/8] |= byte(v) << uint(8-depth-bit%8)
				}
				bit += depth
			}
		}
		return row
	}

	idat := &bytes.Buffer{}
	if !interlace {
		xs := make([]int, w)
		for i := range xs {
			xs[i] = i
		}
		raw := []byte(nil)
		for y := 0; y < h; y++ {
			raw = append(raw, pack(xs, y)...)
		}
		pngRows(idat, raw, (w*bitsPerPixel+7)/8, bpp, filter)
	} else {
		passes := [7][4]int{{0, 0, 8, 8}, {4, 0, 8, 8}, {0, 4, 4, 8}, {2, 0, 4, 4}, {0, 2, 2, 4}, {1, 0, 2, 2}, {0, 1, 1, 2}}
		for _, p := range passes {
			xs := []int(nil)
			for x := p[0]; x < w; x += p[2] {
				xs = append(xs, x)
			}
			raw := []byte(nil)
			for y := p[1]; y < h; y += p[3] {
				raw = append(raw, pack(xs, y)...)
			}
			if len(xs) > 0 {
				pngRows(idat, raw, (len(xs)*bitsPerPixel+7)/8, bpp, filter)
			}
		}
	}

	out := &bytes.Buffer{}
	out.WriteString("\x89PNG\r\n\x1a\n")
	ihdr := make([]byte, 13)
	binary.BigEndian.PutUint32(ihdr[0:], uint32(w))
	binary.BigEndian.PutUint32(ihdr[4:], uint32(h))
	ihdr[8], ihdr[9] = byte(depth), byte(colorType)
	if interlace {
		ihdr[12] = 1
	}
	pngChunk(out, "IHDR", ihdr)
	if colorType == 3 {
		plte := make([]byte, 3*(1<<uint(depth)))
		for i := range plte {
			plte[i] = byte(rnd())
		}
		pngChunk(out, "PLTE", plte)
		if trns {
			t := make([]byte, (1<<uint(depth))/2+1)
			for i := range t {
				t[i] = byte(rnd())
			}
			pngChunk(out, "tRNS", t)
		}
	} else if trns && (colorType == 0 || colorType == 2) {
		// The colour key: the first pixel's colour.
		t := []byte(nil)
		for c := 0; c < channels; c++ {
			t = append(t, byte(px[0][c]>>8), byte(px[0][c]))
		}
		pngChunk(out, "tRNS", t)
	}
	z := &bytes.Buffer{}
	zw, _ := zlib.NewWriterLevel(z, level)
	zw.Write(idat.Bytes())
	zw.Close()
	// Several IDAT chunks, one of them empty.
	zb := z.Bytes()
	n := len(zb) / 3
	pngChunk(out, "IDAT", zb[:n])
	pngChunk(out, "IDAT", nil)
	pngChunk(out, "IDAT", zb[n:])
	pngChunk(out, "IEND", nil)
	return out.Bytes()
}

func makePNGs() {
	type kind struct{ colorType, depth int }
	kinds := []kind{
		{0, 1}, {0, 2}, {0, 4}, {0, 8}, {0, 16},
		{2, 8}, {2, 16},
		{3, 1}, {3, 2}, {3, 4}, {3, 8},
		{4, 8}, {4, 16},
		{6, 8}, {6, 16},
	}
	sizes := [][2]int{{1, 1}, {7, 5}, {33, 19}}
	for _, k := range kinds {
		for i, size := range sizes {
			for _, interlace := range []bool{false, true} {
				for _, trns := range []bool{false, true} {
					if trns && (k.colorType == 4 || k.colorType == 6) {
						continue
					}
					filter := -1
					if i == 0 {
						filter = int(rnd() % 5)
					}
					level := []int{zlib.NoCompression, zlib.BestSpeed, zlib.BestCompression}[i]
					name := fmt.Sprintf("gen-c%d-d%d-%dx%d", k.colorType, k.depth, size[0], size[1])
					if interlace {
						name += "-i"
					}
					if trns {
						name += "-t"
					}
					data := makePNG(size[0], size[1], k.colorType, k.depth, interlace, filter, trns, level)
					add("png", name+".png", data, goReference("png", data))
				}
			}
		}
	}
	// Each filter type alone, at each filter distance (bytes per pixel).
	for _, k := range []kind{{0, 8}, {4, 8}, {2, 8}, {6, 8}, {2, 16}, {6, 16}} {
		for filter := 0; filter <= 4; filter++ {
			data := makePNG(41, 9, k.colorType, k.depth, false, filter, false, zlib.DefaultCompression)
			add("png", fmt.Sprintf("gen-filter%d-c%d-d%d.png", filter, k.colorType, k.depth),
				data, goReference("png", data))
		}
	}

	// From Go's encoder.
	encode := func(name string, m image.Image) {
		b := &bytes.Buffer{}
		if err := png.Encode(b, m); err != nil {
			log.Fatal(err)
		}
		add("png", name, b.Bytes(), goReference("png", b.Bytes()))
	}
	r := image.Rect(0, 0, 70, 50)
	gray, gray16 := image.NewGray(r), image.NewGray16(r)
	nrgba, nrgba64, opaque := image.NewNRGBA(r), image.NewNRGBA64(r), image.NewNRGBA(r)
	pal := color.Palette{}
	for i := 0; i < 200; i++ {
		pal = append(pal, color.NRGBA{byte(rnd()), byte(rnd()), byte(rnd()), byte(0xFF * (rnd() % 4) / 3)})
	}
	paletted := image.NewPaletted(r, pal)
	for y := 0; y < 50; y++ {
		for x := 0; x < 70; x++ {
			v := byte(x*3 + y*5)
			gray.SetGray(x, y, color.Gray{v})
			gray16.SetGray16(x, y, color.Gray16{uint16(x*900 + y*1300)})
			nrgba.SetNRGBA(x, y, color.NRGBA{v, byte(x * 4), byte(y * 5), byte(x*y + 7)})
			opaque.SetNRGBA(x, y, color.NRGBA{v, byte(x * 4), byte(y * 5), 0xFF})
			nrgba64.SetNRGBA64(x, y, color.NRGBA64{uint16(x * 931), uint16(y * 1301), uint16(x * y * 17), uint16(x*700 + y*300)})
			paletted.SetColorIndex(x, y, uint8((x*7+y*11)%200))
		}
	}
	encode("gen-go-gray.png", gray)
	encode("gen-go-gray16.png", gray16)
	encode("gen-go-nrgba.png", nrgba)
	encode("gen-go-opaque.png", opaque)
	encode("gen-go-nrgba64.png", nrgba64)
	encode("gen-go-paletted.png", paletted)
}

// ---- GIF, from Go's encoder.

func makeGIFs() {
	palette := func(n int, transparent bool) color.Palette {
		p := color.Palette{}
		for i := 0; i < n; i++ {
			p = append(p, color.RGBA{byte(rnd()), byte(rnd()), byte(rnd()), 0xFF})
		}
		if transparent {
			p[n/2] = color.RGBA{}
		}
		return p
	}
	frame := func(r image.Rectangle, p color.Palette) *image.Paletted {
		m := image.NewPaletted(r, p)
		for i := range m.Pix {
			if rnd()%3 != 0 && i > 0 {
				m.Pix[i] = m.Pix[i-1]
			} else {
				m.Pix[i] = uint8(rnd() % uint32(len(p)))
			}
		}
		return m
	}
	encode := func(name string, g *gif.GIF) {
		b := &bytes.Buffer{}
		if err := gif.EncodeAll(b, g); err != nil {
			log.Fatal(err)
		}
		add("gif", name, b.Bytes(), goReference("gif", b.Bytes()))
	}

	for _, n := range []int{2, 4, 16, 256} {
		for _, size := range [][2]int{{1, 1}, {9, 6}, {80, 40}} {
			p := palette(n, n == 16)
			encode(fmt.Sprintf("gen-still-%d-%dx%d.gif", n, size[0], size[1]), &gif.GIF{
				Image: []*image.Paletted{frame(image.Rect(0, 0, size[0], size[1]), p)},
				Delay: []int{0},
			})
		}
	}
	// Animations: frames with their own bounds, palettes, delays and
	// disposal methods, with and without transparency.
	for i, loop := range []int{0, 3, -1} {
		global := palette(64, i != 1)
		g := &gif.GIF{
			LoopCount:       loop,
			BackgroundIndex: 5,
			Config:          image.Config{ColorModel: global, Width: 60, Height: 44},
		}
		rects := []image.Rectangle{
			image.Rect(0, 0, 60, 44), image.Rect(10, 5, 30, 25), image.Rect(0, 20, 60, 44),
			image.Rect(59, 43, 60, 44), image.Rect(3, 3, 57, 9), image.Rect(0, 0, 60, 44),
		}
		for j, r := range rects {
			p := global
			if (i+j)%3 == 1 {
				p = palette(8<<uint(j%3), j%2 == 0)
			}
			g.Image = append(g.Image, frame(r, p))
			g.Delay = append(g.Delay, j*7)
			g.Disposal = append(g.Disposal, byte([]int{0, gif.DisposalNone, gif.DisposalBackground, gif.DisposalPrevious}[(i+j)%4]))
		}
		encode(fmt.Sprintf("gen-animated-%d.gif", i), g)
	}
}

// ---- BMP, by hand.

func makeBMPs() {
	le16 := func(b *bytes.Buffer, v int) { binary.Write(b, binary.LittleEndian, uint16(v)) }
	le32 := func(b *bytes.Buffer, v int) { binary.Write(b, binary.LittleEndian, uint32(int32(v))) }

	// header writes the file header and a BITMAPINFOHEADER (or, with masks,
	// a BITMAPV4HEADER), then the palette.
	header := func(w, h, bits, compression int, palette []byte, masks []uint32, pixels int) *bytes.Buffer {
		infoSize := 40
		if masks != nil {
			infoSize = 108
		}
		off := 14 + infoSize + len(palette)
		b := &bytes.Buffer{}
		b.WriteString("BM")
		le32(b, off+pixels)
		le32(b, 0)
		le32(b, off)
		le32(b, infoSize)
		le32(b, w)
		le32(b, h)
		le16(b, 1)
		le16(b, bits)
		le32(b, compression)
		le32(b, pixels)
		le32(b, 2835)
		le32(b, 2835)
		le32(b, len(palette)/4)
		le32(b, 0)
		if masks != nil {
			for _, m := range masks {
				binary.Write(b, binary.LittleEndian, m)
			}
			b.Write(make([]byte, 108-40-16))
		}
		b.Write(palette)
		return b
	}
	palette := func(n int) []byte {
		p := make([]byte, 4*n)
		for i := 0; i < n; i++ {
			p[4*i], p[4*i+1], p[4*i+2] = byte(rnd()), byte(rnd()), byte(rnd())
		}
		return p
	}

	for _, size := range [][2]int{{1, 1}, {5, 3}, {34, 21}} {
		w, h := size[0], size[1]
		for _, topDown := range []bool{false, true} {
			suffix := fmt.Sprintf("%dx%d", w, h)
			hh := h
			if topDown {
				suffix += "-topdown"
				hh = -h
			}
			// fileRow maps a row of the file to a row of the image.
			imageRow := func(fileRow int) int {
				if topDown {
					return fileRow
				}
				return h - 1 - fileRow
			}

			// 24 and 32 bits per pixel.
			for _, bits := range []int{24, 32} {
				stride := (w*bits/8 + 3) &^ 3
				pix := make([]byte, stride*h)
				ref := &reference{x1: w, y1: h, bgra: make([]byte, 4*w*h)}
				for fy := 0; fy < h; fy++ {
					for x := 0; x < w; x++ {
						o := ref.bgra[4*(imageRow(fy)*w+x):]
						for c := 0; c < bits/8; c++ {
							v := byte(rnd())
							pix[fy*stride+x*bits/8+c] = v
							o[c] = v
						}
						o[3] = 0xFF
					}
				}
				b := header(w, hh, bits, 0, nil, nil, len(pix))
				b.Write(pix)
				add("bmp", fmt.Sprintf("gen-%d-%s.bmp", bits, suffix), b.Bytes(), ref)
			}

			// 1, 4 and 8 bits per pixel, with a palette.
			for _, bits := range []int{1, 4, 8} {
				stride := ((w*bits+7)/8 + 3) &^ 3
				pal := palette(1 << uint(bits))
				pix := make([]byte, stride*h)
				ref := &reference{x1: w, y1: h, bgra: make([]byte, 4*w*h)}
				for fy := 0; fy < h; fy++ {
					for x := 0; x < w; x++ {
						v := int(rnd() % (1 << uint(bits)))
						pix[fy*stride+x*bits/8] |= byte(v << uint(8-bits-(x*bits)%8))
						o := ref.bgra[4*(imageRow(fy)*w+x):]
						copy(o, pal[4*v:4*v+3])
						o[3] = 0xFF
					}
				}
				b := header(w, hh, bits, 0, pal, nil, len(pix))
				b.Write(pix)
				add("bmp", fmt.Sprintf("gen-%d-%s.bmp", bits, suffix), b.Bytes(), ref)
			}

			// 16 and 32 bits per pixel with bit fields.
			for _, masks := range [][]uint32{
				{0xF800, 0x07E0, 0x001F, 0},
				{0x7C00, 0x03E0, 0x001F, 0x8000},
				{0x00FF0000, 0x0000FF00, 0x000000FF, 0xFF000000},
				{0x000000FF, 0x0000FF00, 0x00FF0000, 0xFF000000},
				{0x3FF00000, 0x000FFC00, 0x000003FF, 0xC0000000},
			} {
				bits := 16
				if masks[0] > 0xFFFF || masks[2] > 0xFFFF {
					bits = 32
				}
				stride := (w*bits/8 + 3) &^ 3
				pix := make([]byte, stride*h)
				for i := range pix {
					pix[i] = byte(rnd())
				}
				b := header(w, hh, bits, 3, nil, masks, len(pix))
				b.Write(pix)
				add("bmp", fmt.Sprintf("gen-bitfields-%08x-%s.bmp", masks[0], suffix), b.Bytes(), nil)
			}
		}

		// Run-length encodings (compression 1 and 2): encoded runs,
		// absolute runs, deltas, end of line and end of bitmap.
		for _, bits := range []int{8, 4} {
			pal := palette(1 << uint(bits))
			rle := []byte(nil)
			for y := 0; y < h; y++ {
				for x := 0; x < w; {
					n := int(rnd()%5) + 1
					if n > w-x {
						n = w - x
					}
					switch {
					case rnd()%4 == 0 && n >= 3:
						rle = append(rle, 0, byte(n))
						for i := 0; i < (n*bits+7)/8; i++ {
							rle = append(rle, byte(rnd()))
						}
						if ((n*bits+7)/8)%2 == 1 {
							rle = append(rle, 0)
						}
					case rnd()%9 == 0 && x+n < w:
						rle = append(rle, 0, 2, byte(n), 0)
					default:
						rle = append(rle, byte(n), byte(rnd()))
					}
					x += n
				}
				rle = append(rle, 0, 0)
			}
			rle = append(rle, 0, 1)
			b := header(w, h, bits, map[int]int{8: 1, 4: 2}[bits], pal, nil, len(rle))
			b.Write(rle)
			add("bmp", fmt.Sprintf("gen-rle%d-%dx%d.bmp", bits, w, h), b.Bytes(), nil)
		}
	}
}

// ---- Netpbm, by hand.

func makeNetpbms() {
	for _, size := range [][2]int{{1, 1}, {6, 4}, {40, 30}} {
		w, h := size[0], size[1]
		for _, kind := range []struct {
			magic    string
			channels int
			maxval   int
			ext      string
		}{
			{"P5", 1, 255, "pgm"}, {"P6", 3, 255, "ppm"}, {"P5", 1, 65535, "pgm"}, {"P6", 3, 65535, "ppm"},
			{"P5", 1, 100, "pgm"}, {"P4", 1, 1, "pbm"}, {"P2", 1, 255, "pgm"}, {"P3", 3, 255, "ppm"}, {"P1", 1, 1, "pbm"},
		} {
			b := &bytes.Buffer{}
			var ref *reference
			switch {
			case kind.magic == "P4":
				fmt.Fprintf(b, "P4\n%d %d\n", w, h)
				for i := 0; i < (w+7)/8*h; i++ {
					b.WriteByte(byte(rnd()))
				}
			case kind.magic < "P4":
				fmt.Fprintf(b, "%s\n# a comment\n%d %d\n", kind.magic, w, h)
				if kind.maxval != 1 {
					fmt.Fprintf(b, "%d\n", kind.maxval)
				}
				for i := 0; i < w*h*kind.channels; i++ {
					fmt.Fprintf(b, "%d ", rnd()%uint32(kind.maxval+1))
				}
			default:
				fmt.Fprintf(b, "%s\n# a comment\n%d   %d\n%d\n", kind.magic, w, h, kind.maxval)
				if kind.maxval == 255 || kind.maxval == 65535 {
					ref = &reference{x1: w, y1: h}
				}
				for i := 0; i < w*h; i++ {
					p := [4]byte{0, 0, 0, 0xFF}
					for c := 0; c < kind.channels; c++ {
						v := byte(rnd())
						b.WriteByte(v)
						if kind.maxval > 255 {
							b.WriteByte(byte(rnd()))
						}
						if kind.channels == 1 {
							p[0], p[1], p[2] = v, v, v
						} else {
							p[2-c] = v
						}
					}
					if ref != nil {
						ref.bgra = append(ref.bgra, p[:]...)
					}
				}
			}
			add("netpbm", fmt.Sprintf("gen-%s-%d-%dx%d.%s", kind.magic, kind.maxval, w, h, kind.ext), b.Bytes(), ref)
		}
	}
}

// ---- The manifest.

func emit(f *file, pixfmt uint32, blend int, sched string, flags string, script string, expected bool) {
	e := "-"
	if expected && f.expected != "" {
		e = f.expected
	}
	fmt.Printf("%s %08X %d %s %s %s %s %s\n", f.format, pixfmt, blend, sched, flags, script, e, f.path)
}

// positions returns up to n positions in a file of the given size: all of
// the first few, then spread evenly.
func positions(size int, n int) []int {
	seen := map[int]bool{}
	ret := []int(nil)
	for i := 0; i < size && len(ret) < n/2; i++ {
		seen[i] = true
		ret = append(ret, i)
	}
	for i := 0; i < n/2; i++ {
		p := size * i / (n / 2)
		if p < size && !seen[p] {
			seen[p] = true
			ret = append(ret, p)
		}
	}
	sort.Ints(ret)
	return ret
}

func main() {
	dataDir := flag.String("data", "wuffs/test/data", "upstream's test data")
	flag.StringVar(&outDir, "out", "", "the directory to write files to")
	chaosName := flag.String("chaos", "", "a file to write the manifest of chaos runs to")
	flag.Parse()
	if outDir == "" {
		log.Fatal("imgcorpus: -out is required")
	}

	formats := map[string]string{
		".bmp": "bmp", ".gif": "gif", ".png": "png", ".pbm": "netpbm", ".pgm": "netpbm", ".ppm": "netpbm",
		".pnm": "netpbm", ".pam": "netpbm",
		".wbmp": "wbmp", ".nie": "nie", ".tga": "targa",
		".qoi": "qoi", ".pkm": "etc2", ".th": "thumbhash", ".handsum": "handsum",
	}
	paths := []string(nil)
	filepath.WalkDir(*dataDir, func(path string, d fs.DirEntry, err error) error {
		if err == nil && !d.IsDir() && formats[strings.ToLower(filepath.Ext(path))] != "" {
			paths = append(paths, path)
		}
		return nil
	})
	sort.Strings(paths)
	for _, path := range paths {
		data, err := os.ReadFile(path)
		if err != nil {
			log.Fatal(err)
		}
		if len(data) > maxFileSize {
			continue
		}
		f := &file{format: formats[strings.ToLower(filepath.Ext(path))], path: path, data: data, upstream: true}
		if ref := goReference(f.format, data); ref != nil {
			f.expected = writeReference(fmt.Sprintf("upstream-%d", len(files)), ref)
		}
		files = append(files, f)
	}
	nUpstream := len(files)
	makePNGs()
	makeGIFs()
	makeBMPs()
	makeNetpbms()
	whole := append([]*file(nil), files...)

	// The chaos runs (see test_image.adb): Ada only, so in a manifest of
	// their own. Many small pieces of source, so that there are many
	// suspensions to change the arguments at.
	if *chaosName != "" {
		chaos := &bytes.Buffer{}
		seed := 0
		for i, f := range whole {
			if len(f.data) > 20000 {
				continue
			}
			for j := 0; j < 8; j++ {
				seed++
				sched := []string{"C7", "C97", "K61", "C1", "K1", "C3", "C31", "K509"}[j]
				if len(f.data) > 3000 && (sched == "C1" || sched == "K1") {
					sched = "C13"
				}
				flags := fmt.Sprintf("x%d", seed)
				if j%3 == 0 {
					flags += ",m"
				}
				fmt.Fprintf(chaos, "%s %08X %d %s %s %s - %s\n", f.format, pixfmts[(i+j)%len(pixfmts)], j%2,
					sched, flags, []string{"I*R*", "I*", "F*", "IFF*"}[j%4], f.path)
			}
		}
		if err := os.WriteFile(*chaosName, chaos.Bytes(), 0o644); err != nil {
			log.Fatal(err)
		}
	}

	damaged := 0
	for i, f := range whole {
		// Every destination format and both blends.
		for _, pixfmt := range pixfmts {
			for blend := 0; blend <= 1; blend++ {
				emit(f, pixfmt, blend, "W", "-", "I*R*", blend == 0 && pixfmt == bgraNonpremul)
			}
		}
		// The source in pieces, and pixel rows that are not adjacent.
		emit(f, bgraNonpremul, 0, "C97", "l", "I*R*", true)
		emit(f, bgraNonpremul, 1, "K1000", "-", "I*R*", false)
		if len(f.data) <= 65536 {
			emit(f, 0xA0000888, 0, "K509", "l", "I*R*", false)
		}
		if len(f.data) <= 3000 {
			emit(f, bgraNonpremul, 0, "C1", "-", "I*R*", true)
			emit(f, 0x80000565, 1, "K1", "l", "I*R*", false)
		}
		// Metadata.
		if f.format == "png" || f.format == "gif" {
			emit(f, bgraNonpremul, 0, "W", "m", "I*R*", false)
			emit(f, bgraNonpremul, 0, "C97", "m", "I*", false)
			if len(f.data) <= 3000 {
				emit(f, bgraNonpremul, 0, "K1", "m", "I*", false)
			}
		}
		// Buffers that are too small.
		emit(f, 0x80000888, 1, "W", "p", "I*", false)
		emit(f, 0x80000888, 0, "W", "w", "I*", false)
		emit(f, 0x81040008, 0, "C97", "p,w,l", "I*", false)
		// Quirks.
		switch f.format {
		case "gif":
			all := ""
			for _, q := range gifQuirks {
				emit(f, bgraNonpremul, 0, "W", fmt.Sprintf("q%d", q), "I*R*", false)
				all += fmt.Sprintf("q%d,", q)
			}
			emit(f, 0x82008888, 1, "C97", all+"m", "I*R*", false)
		case "png":
			emit(f, bgraNonpremul, 0, "W", "q1", "I*R*", false)
		}
		emit(f, bgraNonpremul, 0, "W", "q1,q2,q3,q12345", "I*", false)
		// Other call sequences.
		if len(f.data) <= 20000 && (f.upstream || i%4 == 0) {
			for j, script := range scripts {
				emit(f, pixfmts[(i+j)%len(pixfmts)], j%2, []string{"W", "C97", "K61"}[(i+j)%3], "m", script, false)
			}
		}

		// Truncated and corrupted copies of some of the small files.
		if len(f.data) > 6000 || (!f.upstream && i%7 != 0) || (f.upstream && damaged >= 40 && i%3 != 0) {
			continue
		}
		damaged++
		base := fmt.Sprintf("damaged-%d", i)
		for _, p := range positions(len(f.data), 60) {
			t := &file{format: f.format, path: filepath.Join(outDir, fmt.Sprintf("%s-t%d", base, p))}
			if err := os.WriteFile(t.path, f.data[:p], 0o644); err != nil {
				log.Fatal(err)
			}
			emit(t, bgraNonpremul, 0, "W", "-", "I*", false)
			emit(t, 0xA0000888, 1, "C7", "m", "I*", false)
		}
		for k, p := range positions(len(f.data), 80) {
			d := append([]byte(nil), f.data...)
			switch k % 3 {
			case 0:
				d[p] ^= 0xFF
			case 1:
				d[p]++
			default:
				d[p] ^= 1 << (uint(k) % 8)
			}
			c := &file{format: f.format, path: filepath.Join(outDir, fmt.Sprintf("%s-c%d", base, p))}
			if err := os.WriteFile(c.path, d, 0o644); err != nil {
				log.Fatal(err)
			}
			emit(c, bgraNonpremul, 0, "W", "-", "I*R*", false)
			if f.format == "png" {
				// Past the checksums.
				emit(c, bgraNonpremul, 1, "C97", "q1,m", "I*", false)
			}
		}
	}
	fmt.Fprintf(os.Stderr, "imgcorpus: %d upstream images, %d generated images, %d of them damaged in turn\n",
		nUpstream, len(whole)-nUpstream, damaged)
}
