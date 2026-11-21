// Part of wuffada (wuffs-ada: Wuffs to Ada).
// SPDX-License-Identifier: Apache-2.0 OR MIT

package main

// WebP (std/webp) and raw VP8 (std/vp8) runs for the corpus: upstream's
// WebP files, the checked-in synthetic ones under ada/tests/webpcorpus (see
// make.py there), the VP8 payloads of every lossy one (std/vp8 on its own,
// with QUIRK_SOURCE_LENGTH set through a "vK:V" flag), and truncated and
// corrupted copies at the places that matter (the RIFF header, chunk
// headers and sizes, the VP8X and ALPH headers, the VP8 frame header, the
// first partition and the partition size table, the VP8L header and the
// Huffman codes that follow it).
//
// Two independent decoders give reference pixels:
//
//   - golang.org/x/image/webp: exact for lossless (VP8L). For lossy (VP8)
//     it returns Y'CbCr planes; this file converts them with "fancy"
//     (triangle filter) chroma upsampling and BT.601 studio-range
//     arithmetic in floating point, its own implementation, so the
//     comparison has a small tolerance (category webp-lossy-go).
//   - libwebp (the reference implementation, through the program
//     ada/tests/crosscheck/webpref.c that test.sh builds): exact for
//     lossless, a small tolerance for lossy (category webp-lossy-libwebp:
//     std/vp8 claims libwebp's upsampling, and on most files the two agree
//     exactly; on a few, a handful of pixels round differently).

import (
	"bufio"
	"bytes"
	"encoding/binary"
	"fmt"
	"image"
	"io/fs"
	"log"
	"os"
	"path/filepath"
	"sort"
	"strings"

	"golang.org/x/image/webp"

	"wuffada/ada/tests/webpconv"
)

// The tolerances (largest per-channel difference) and mean limits (in
// hundredths) of the lossy comparisons, a little above what was measured
// (Go's conversion here: 3 and 0.30; libwebp: 3 and 0.01, on a few files
// with segments or an automatic filter). Lossless ones are exact.
const (
	webpLossyGoTol       = 4
	webpLossyGoMean      = 40
	webpLossyLibwebpTol  = 3
	webpLossyLibwebpMean = 5

	quirkSourceLength = 3
	quirkVP8Alpha     = 0x6D7BF800
	quirkVP8WH        = 0x6D7BF801
)

// webpRef is a second reference (libwebp's) for a file: a run of its own.
type webpRef struct {
	f        *file
	expected string
	cat      string
	tol      int
	mean     int
}

var (
	webpRefs     []webpRef
	libwebpPaths map[string]string // File path to libwebp reference file.
)

// loadLibwebpRefs reads the listing that webpref printed into dir/list.out.
func loadLibwebpRefs(dir string) {
	libwebpPaths = map[string]string{}
	if dir == "" {
		return
	}
	f, err := os.Open(filepath.Join(dir, "list.out"))
	if err != nil {
		log.Fatal(err)
	}
	defer f.Close()
	s := bufio.NewScanner(f)
	for s.Scan() {
		fields := strings.Fields(s.Text())
		if len(fields) == 3 && fields[2] == "ok" {
			libwebpPaths[fields[1]] = filepath.Join(dir, fields[0]+".libwebp")
		}
	}
}

// webpGoReference returns Go's reference pixels for data and whether it is
// "lossless" or "lossy" ("" if Go cannot decode it).
func webpGoReference(data []byte) (*reference, string) {
	m, err := webp.Decode(bytes.NewReader(data))
	if err != nil {
		return nil, ""
	}
	b := m.Bounds()
	ref := &reference{x1: b.Dx(), y1: b.Dy()}
	switch m := m.(type) {
	case *image.NRGBA:
		for y := b.Min.Y; y < b.Max.Y; y++ {
			for x := b.Min.X; x < b.Max.X; x++ {
				c := m.NRGBAAt(x, y)
				ref.bgra = append(ref.bgra, c.B, c.G, c.R, c.A)
			}
		}
		return ref, "lossless"
	case *image.YCbCr:
		ref.bgra = webpconv.FancyBGRA(m, nil, 0)
		return ref, "lossy"
	case *image.NYCbCrA:
		ref.bgra = webpconv.FancyBGRA(&m.YCbCr, m.A, m.AStride)
		return ref, "lossy"
	}
	return nil, ""
}

// webpChunks returns the chunks of a RIFF WebP file: their fourccs, the
// offsets of their headers and their payloads.
func webpChunks(data []byte) (fourccs []string, offsets []int, payloads [][]byte) {
	for i := 12; i+8 <= len(data); {
		n := int(binary.LittleEndian.Uint32(data[i+4:]))
		end := i + 8 + n
		if n < 0 || end > len(data) || end < i {
			end = len(data)
		}
		fourccs = append(fourccs, string(data[i:i+4]))
		offsets = append(offsets, i)
		payloads = append(payloads, data[i+8:end])
		i += 8 + n + n&1
		if n > len(data) {
			break
		}
	}
	return
}

// Which files are compared with the reference decoders. The others are
// compared with upstream's C only: there, std/webp legitimately rejects
// what libwebp or Go accept (it is stricter about chunk order and VP8X
// flags), or upstream's behaviour differs from libwebp's (see
// webpReferencePolicy).
var webpContainerRefs = map[string]bool{
	"container-vp8-simple-odd-pad": true, "container-vp8l-simple-odd-pad": true,
	"container-vp8x-vp8": true, "container-vp8x-vp8-meta": true, "container-vp8x-vp8-meta-before": true,
	"container-vp8x-vp8-unknown": true, "container-vp8-trailing": true, "container-vp8l-trailing": true,
	"container-alph-after-iccp": true, "container-alph-flag-noalph": true, "container-alph-long": true,
	"container-alph-preprocessing": true,
}

// vp8FrameHeader decodes the start of a VP8 key frame's first partition
// (RFC 6386, sections 7 and 9.2 to 9.6) far enough to return the loop
// filter's level and sharpness.
func vp8FrameHeader(d []byte) (level int, sharpness int, ok bool) {
	if len(d) < 12 || d[0]&1 != 0 {
		return 0, 0, false
	}
	p := d[10:]
	value, rng, count, pos := uint32(p[0])<<8|uint32(p[1]), uint32(255), 0, 2
	bit := func(prob uint32) int {
		split := 1 + ((rng-1)*prob)>>8
		ret := 0
		if value >= split<<8 {
			ret, rng, value = 1, rng-split, value-split<<8
		} else {
			rng = split
		}
		for rng < 128 {
			value, rng = value<<1, rng<<1
			if count++; count == 8 {
				count = 0
				if pos < len(p) {
					value |= uint32(p[pos])
				}
				pos++
			}
		}
		return ret
	}
	lit := func(n int) int {
		v := 0
		for i := 0; i < n; i++ {
			v = v<<1 | bit(128)
		}
		return v
	}
	lit(2) // Colour space, clamping type.
	if lit(1) == 1 {
		// Segmentation.
		updateMap, updateData := lit(1), lit(1)
		if updateData == 1 {
			lit(1)
			for i := 0; i < 4; i++ {
				if lit(1) == 1 {
					lit(8)
				}
			}
			for i := 0; i < 4; i++ {
				if lit(1) == 1 {
					lit(7)
				}
			}
		}
		if updateMap == 1 {
			for i := 0; i < 3; i++ {
				if lit(1) == 1 {
					lit(8)
				}
			}
		}
	}
	lit(1) // Filter type.
	level = lit(6)
	sharpness = lit(3)
	return level, sharpness, pos <= len(p)
}

// webpReferencePolicy says whether the file at path, whose chunks are
// given, is compared with Go's and with libwebp's pixels.
func webpReferencePolicy(path string, data []byte, fourccs []string, payloads [][]byte) (goRef, libwebpRef bool) {
	name := strings.TrimSuffix(filepath.Base(path), ".webp")
	vp8x, vp8l, alph := false, false, false
	var vp8 []byte
	for j, fc := range fourccs {
		vp8x = vp8x || fc == "VP8X"
		vp8l = vp8l || fc == "VP8L"
		alph = alph || fc == "ALPH"
		if fc == "VP8 " && vp8 == nil {
			vp8 = payloads[j]
		}
	}
	if vp8 != nil {
		if _, sharpness, ok := vp8FrameHeader(vp8); !ok || sharpness != 0 {
			// Upstream's std/vp8 clamps the loop filter's interior limit
			// with "ilevel.max(no_less_than: 9 - sharpness)" where RFC 6386
			// (and libwebp, and Go) take the minimum: with a sharpness above
			// zero its pixels differ (in our corpus by up to 15).
			return false, false
		}
	}
	if vp8x && alph && vp8 != nil && len(data) >= 30 {
		// Upstream's workbuf_len (after decode_image_config) does not count
		// the alpha plane of VP8X+ALPH+VP8 (std/vp8 learns of it only in
		// decode_frame), so a decode_frame with that much work buffer can
		// fail with "#bad workbuf length": the arithmetic of decode_webp.wuffs
		// and decode_vp8.wuffs.
		w := int(binary.LittleEndian.Uint32(append(data[24:27:27], 0))) + 1
		h := int(binary.LittleEndian.Uint32(append(data[27:30:30], 0))) + 1
		riffLen := int(binary.LittleEndian.Uint32(data[4:]))
		mbw, mbh := (w+15)/16, (h+15)/16
		yuv := mbw*16*mbh*16 + 2*(mbw*8*mbh*8)
		ts := 4 * ((w + 3) >> 2) * ((h + 3) >> 2)
		reported := 4*w*h + 3*ts
		if r := yuv + riffLen - 10 + 8; r > reported {
			reported = r
		}
		if w*h+yuv+len(vp8)-10+8 > reported {
			return false, false
		}
	}
	switch {
	case vp8x && vp8l:
		// Upstream's std/webp cannot decode VP8X+VP8L at this commit: it
		// rejects one with the VP8X alpha flag ("#bad ALPH+VP8L
		// combination"), which libwebp sets for every lossless image with
		// alpha, and on one without it does not skip the VP8L chunk's
		// five-byte header ("#bad Huffman code").
		return false, false
	case name == "vp8l-narrow-clamped":
		// Plane codes whose distance is below 1 (an image 5 pixels wide):
		// RFC 9649, libwebp and Go take the distance as 1; upstream's
		// std/webp (decode_pixels_slow.wuffs) does not clamp, its distance
		// wraps around, and it reports "#bad back-reference".
		return false, false
	case name == "vp8l-simple-reversed":
		// A simple two-symbol Huffman code whose first symbol is the larger
		// one: Wuffs (and Go) give the first symbol the code 0, libwebp
		// gives it to the smaller one.
		return true, false
	case strings.HasPrefix(name, "container-"):
		return webpContainerRefs[name], webpContainerRefs[name]
	}
	return true, true
}

// addWebP adds a WebP file to the corpus, with its references.
func addWebP(f *file) {
	files = append(files, f)
	fourccs, _, payloads := webpChunks(f.data)
	for j, fc := range fourccs {
		if fc == "ALPH" && len(payloads[j]) > 0 && payloads[j][0]&3 == 0 {
			// Upstream's std/webp copies an uncompressed ALPH chunk with a
			// copy that does not suspend: from a source buffer that holds
			// only a part of it, it takes that part, and the decoding goes
			// on out of step. Only a run with the whole file in the
			// buffer can be compared with the references.
			f.rawAlpha = true
		}
	}
	goRef, libwebpRef := webpReferencePolicy(f.path, f.data, fourccs, payloads)
	ref, kind := webpGoReference(f.data)
	if !goRef {
		ref = nil
	}
	name := fmt.Sprintf("webp-%d", len(files))
	if ref != nil {
		f.expected = writeReference(name, ref)
		if kind == "lossless" {
			f.refCat, f.refTol, f.refMean = "webp-lossless-go", 0, 0
		} else {
			f.refCat, f.refTol, f.refMean = "webp-lossy-go", webpLossyGoTol, webpLossyGoMean
		}
	}
	if p := libwebpPaths[f.path]; p != "" && kind != "" && libwebpRef {
		r := webpRef{f: f, expected: p, cat: "webp-lossless-libwebp"}
		if kind == "lossy" {
			r.cat, r.tol, r.mean = "webp-lossy-libwebp", webpLossyLibwebpTol, webpLossyLibwebpMean
		}
		webpRefs = append(webpRefs, r)
	}
}

func addWebPs(dir string) int {
	paths := []string(nil)
	filepath.WalkDir(dir, func(path string, d fs.DirEntry, err error) error {
		if err == nil && !d.IsDir() && strings.HasSuffix(path, ".webp") {
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
		addWebP(&file{format: "webp", path: p, data: data})
	}
	return len(paths)
}

// sourceLengthFlag is the flag that sets std/vp8's QUIRK_SOURCE_LENGTH to n
// (a has-value bit and n).
func sourceLengthFlag(n int) string {
	return fmt.Sprintf("v%d:%d", quirkSourceLength, uint64(n)<<1|1)
}

// vp8Payloads writes the VP8 payload of each lossy WebP file (without
// alpha) as a file of its own, for std/vp8, with the WebP file's reference
// pixels.
func vp8Payloads(webps []*file) []*file {
	out := []*file(nil)
	for i, f := range webps {
		fourccs, _, payloads := webpChunks(f.data)
		hasAlpha := false
		var vp8 []byte
		for j, fc := range fourccs {
			if fc == "ALPH" {
				hasAlpha = true
			}
			if fc == "VP8 " && vp8 == nil {
				vp8 = payloads[j]
			}
		}
		if vp8 == nil || len(vp8) < 10 {
			continue
		}
		p := filepath.Join(outDir, fmt.Sprintf("vp8-%d.vp8", i))
		if err := os.WriteFile(p, vp8, 0o644); err != nil {
			log.Fatal(err)
		}
		g := &file{format: "vp8", path: p, data: vp8, upstream: f.upstream}
		if !hasAlpha && f.expected != "" {
			g.expected, g.refCat, g.refTol, g.refMean = f.expected, f.refCat, f.refTol, f.refMean
		}
		out = append(out, g)
	}
	return out
}

// emitVP8 emits the runs of a raw VP8 stream.
func emitVP8(f *file, i int) {
	sl := sourceLengthFlag(len(f.data))
	for _, pixfmt := range pixfmts {
		for blend := 0; blend <= 1; blend++ {
			emit(f, pixfmt, blend, "W", sl, "I*R*", blend == 0 && pixfmt == bgraNonpremul)
		}
	}
	emit(f, bgraNonpremul, 0, "C97", sl+",l", "I*R*", true)
	emit(f, 0xA0000888, 1, "K61", sl, "I*R*", false)
	if len(f.data) <= 3000 {
		emit(f, bgraNonpremul, 0, "C1", sl, "I*", true)
		emit(f, 0x80000565, 1, "K1", sl+",l", "I*", false)
	}
	emit(f, 0x80000888, 1, "W", sl+",p", "I*", false)
	emit(f, 0x80000888, 0, "W", sl+",w", "I*", false)
	for j, script := range []string{"F", "CF", "C*", "IFF", "icF", "I*RR*", "I*r*", "T", "IFrF", "I*RFC"} {
		emit(f, pixfmts[(i+j)%len(pixfmts)], j%2, []string{"W", "C97", "K61"}[(i+j)%3], sl, script, false)
	}
	// The quirks: none (#missing QUIRK_SOURCE_LENGTH), bad values, values
	// out of range, a source length that is too short or too long, the
	// alpha side channel (with and without the width and height).
	emit(f, bgraNonpremul, 0, "W", "-", "I*", false)
	for _, flags := range []string{
		fmt.Sprintf("v%d:2", quirkSourceLength), fmt.Sprintf("v%d:21", quirkSourceLength),
		fmt.Sprintf("v%d:0", quirkSourceLength), sourceLengthFlag(0x08FF_FFF7 + 11),
		sourceLengthFlag(0x08FF_FFF7 + 10), sourceLengthFlag(10), sourceLengthFlag(len(f.data) / 2),
		sourceLengthFlag(len(f.data) + 100), sl + fmt.Sprintf(",v%d:1", quirkVP8Alpha),
		sl + fmt.Sprintf(",v%d:%d", quirkVP8WH, 5|7<<32), sl + fmt.Sprintf(",v%d:0", quirkVP8WH),
		sl + fmt.Sprintf(",v%d:%d", quirkVP8WH, 0x4000|1<<32),
	} {
		emit(f, bgraNonpremul, 0, "W", flags, "I*", false)
	}
	// The alpha side channel with the right width and height: the alpha
	// plane is whatever the work buffer holds (std/vp8 leaves it to the
	// caller, std/webp puts the ALPH chunk there).
	if w, h, ok := vp8Size(f.data); ok {
		wh := sl + fmt.Sprintf(",v%d:1,v%d:%d", quirkVP8Alpha, quirkVP8WH, uint64(w)|uint64(h)<<32)
		emit(f, bgraNonpremul, 0, "W", wh, "I*R*", false)
		emit(f, 0xA2008888, 1, "C97", wh+",w", "I*", false)
		emit(f, 0x81040008, 1, "K61", wh, "I*", false)
	}
}

// vp8Size returns the width and height from a VP8 key frame's header.
func vp8Size(d []byte) (int, int, bool) {
	if len(d) < 10 || d[0]&1 != 0 || d[3] != 0x9D || d[4] != 0x01 || d[5] != 0x2A {
		return 0, 0, false
	}
	return int(binary.LittleEndian.Uint16(d[6:]) & 0x3FFF), int(binary.LittleEndian.Uint16(d[8:]) & 0x3FFF), true
}

// webpDamage writes truncated and corrupted copies of a WebP (or, with
// vp8, raw VP8) file at the places that matter, and returns their paths and
// whether each is a truncation.
func webpDamage(base string, data []byte, vp8 bool, many bool) ([]string, []bool) {
	paths, truncs := []string(nil), []bool(nil)
	seenT, seenC := map[int]bool{}, map[int]bool{}
	trunc := func(n int) {
		if n < 0 || n >= len(data) || seenT[n] {
			return
		}
		seenT[n] = true
		p := filepath.Join(outDir, fmt.Sprintf("%s-t%d", base, n))
		if err := os.WriteFile(p, data[:n], 0o644); err != nil {
			log.Fatal(err)
		}
		paths, truncs = append(paths, p), append(truncs, true)
	}
	corrupt := func(at int, how int) {
		if at < 0 || at >= len(data) || seenC[at] {
			return
		}
		seenC[at] = true
		d := append([]byte(nil), data...)
		switch how % 4 {
		case 0:
			d[at] ^= 0xFF
		case 1:
			d[at]++
		case 2:
			d[at] ^= 1 << uint(at%8)
		default:
			d[at] = 0
		}
		p := filepath.Join(outDir, fmt.Sprintf("%s-c%d", base, at))
		if err := os.WriteFile(p, d, 0o644); err != nil {
			log.Fatal(err)
		}
		paths, truncs = append(paths, p), append(truncs, false)
	}
	// region marks the bytes of a header (or other structure) at off: all
	// of them, or (if not many) some.
	region := func(off, n int) {
		for k := 0; k < n; k++ {
			if many || k%3 == 0 {
				corrupt(off+k, k)
			}
			if many || k%4 == 0 {
				trunc(off + k)
			}
		}
	}
	vp8Header := func(off int, payload []byte) {
		// Frame tag (3), start code (3), width and height (4), then the
		// first partition (its header: colour space, segmentation, filter,
		// quantizers, ...).
		region(off, 24)
		if len(payload) < 3 {
			return
		}
		first := int(binary.LittleEndian.Uint32(append(payload[:3:3], 0)) >> 5)
		end := off + 10 + first
		// The token partitions' sizes follow the first partition.
		region(end-2, 12)
		for _, frac := range []int{1, 3} {
			corrupt(off+10+first*frac/4, frac)
		}
	}
	if vp8 {
		vp8Header(0, data)
	} else {
		region(0, 20) // RIFF, size, WEBP, the first chunk's header.
		fourccs, offsets, payloads := webpChunks(data)
		for j, fc := range fourccs {
			off := offsets[j]
			region(off, 8)
			switch fc {
			case "VP8 ":
				vp8Header(off+8, payloads[j])
			case "VP8L":
				region(off+8, 5) // Signature, width, height, alpha, version.
				region(off+13, 40)
			case "VP8X":
				region(off+8, 10)
			case "ALPH":
				region(off+8, 12)
			}
		}
	}
	// And spread evenly.
	n := 8
	if many {
		n = 30
	}
	for k := 1; k < n; k++ {
		trunc(len(data) * k / n)
		corrupt(len(data)*k/n+k, k)
	}
	return paths, truncs
}

// emitWebPDamage emits the runs of the damaged copies of the WebP and VP8
// files.
func emitWebPDamage(webps []*file, vp8s []*file) int {
	n := 0
	for i, f := range webps {
		// Upstream's files: all of them (the largest ones less); the
		// checked-in ones: every sixth thoroughly and every sixth others a
		// little (they are many, and similar).
		many := len(f.data) <= 30000 && (f.upstream || i%6 == 0)
		if len(f.data) > 300000 || (!many && !f.upstream && i%6 != 3) {
			continue
		}
		paths, truncs := webpDamage(fmt.Sprintf("wdamaged-%d", i), f.data, false, many)
		for k, p := range paths {
			d := &file{format: "webp", path: p}
			emit(d, bgraNonpremul, 0, "W", "-", "I*R*", false)
			if truncs[k] && k%3 == 0 {
				emit(d, 0xA0000888, 1, "C7", "-", "I*", false)
			} else if !truncs[k] && k%4 == 0 {
				emit(d, 0x81040008, 1, "K61", "w", "I*", false)
			}
			n++
		}
	}
	for i, f := range vp8s {
		if len(f.data) > 30000 || (!f.upstream && i%6 != 0) {
			continue
		}
		paths, _ := webpDamage(fmt.Sprintf("vdamaged-%d", i), f.data, true, true)
		for _, p := range paths {
			data, err := os.ReadFile(p)
			if err != nil {
				log.Fatal(err)
			}
			d := &file{format: "vp8", path: p}
			// The source length is that of the original, as it would be
			// in a WebP file whose VP8 chunk is damaged.
			emit(d, bgraNonpremul, 0, "W", sourceLengthFlag(len(f.data)), "I*", false)
			if len(data) != len(f.data) {
				emit(d, bgraNonpremul, 0, "W", sourceLengthFlag(len(data)), "I*", false)
			}
			n++
		}
	}
	return n
}

// emitWebPRefs emits the runs compared with libwebp's pixels.
func emitWebPRefs() {
	for _, r := range webpRefs {
		flags := fmt.Sprintf("t%d,a%d,k%s", r.tol, r.mean, r.cat)
		if r.cat == "webp-lossless-libwebp" {
			flags = fmt.Sprintf("t0,a0,k%s", r.cat)
		}
		fmt.Printf("%s %08X %d %s %s %s %s %s\n", r.f.format, bgraNonpremul, 0, "W", flags, "I*", r.expected, r.f.path)
		if len(r.f.data) <= 3000 && !r.f.rawAlpha {
			fmt.Printf("%s %08X %d %s %s %s %s %s\n", r.f.format, bgraNonpremul, 0, "C1", flags, "I*", r.expected,
				r.f.path)
		}
	}
}
