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
//     lossless, and exact for lossy too (category webp-lossy-libwebp):
//     std/vp8 follows libwebp's arithmetic, its loop filters and its
//     "fancy" upsampling. (Before the fork fixed std/vp8's clip_m16_p15,
//     which let a loop filter adjustment of 16 through where libwebp
//     clamps to 15, pixels next to filtered sub-block edges differed by 1
//     or more on a few files; it was not the upsampling.) For an
//     animation, libwebp's WebPAnimDecoder: the canvas after each frame,
//     which test_image.adb (flag A) composites from Wuffs' frames and frame
//     configs as a caller would (categories webp-anim-lossless-libwebp and
//     webp-anim-lossy-libwebp, both exact).

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
// hundredths) of the lossy comparisons with Go's decoder, a little above
// what was measured (Go's conversion here: 3 and 0.30). The comparisons with
// libwebp, lossy or lossless, are exact.
const (
	webpLossyGoTol       = 4
	webpLossyGoMean      = 40
	webpLossyLibwebpTol  = 0
	webpLossyLibwebpMean = 0

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
	anim     bool // An animation: test_image.adb's flag A.
}

var (
	webpRefs         []webpRef
	libwebpPaths     map[string]string // File path to libwebp reference file.
	libwebpAnimPaths map[string]string // The same, for animations.
)

// loadLibwebpRefs reads the listing that webpref printed into dir/list.out.
func loadLibwebpRefs(dir string) {
	libwebpPaths = map[string]string{}
	libwebpAnimPaths = map[string]string{}
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
		} else if len(fields) == 3 && fields[2] == "anim" {
			libwebpAnimPaths[fields[1]] = filepath.Join(dir, fields[0]+".libwebpanim")
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

// webpCOnly lists the files that are compared with upstream's C only (not
// with Go's or libwebp's pixels), and why: legitimate differences between
// decoders, mostly in how they treat invalid files that they all accept.
// (A file that a reference decoder rejects, or that Wuffs rejects, needs no
// entry: there is nothing to compare.)
var webpCOnly = map[string]string{
	// The VP8 chunk is three bytes shorter than its partitions say: the
	// decoders fill the missing bytes differently.
	"container-vp8-chunk-short": "truncated partition",
	// The VP8L frame's alpha_is_used bit is 0, yet its pixels are not all
	// opaque. libwebp's WebPAnimDecoder believes the bit (the frame is a
	// "key frame", drawn without blending); std/webp follows the VP8L
	// spec ("a hint only") and its frame_config does not carry the bit.
	"container-anim-2frames": "alpha_is_used hint",

	// std/webp is stricter than libwebp or Go (or both) about these: it
	// requires the VP8X flags of the ICCP, EXIF, XMP and ALPH chunks and no
	// reserved flags, the chunk order of the container specification, a
	// canvas size that the image (or an ANMF chunk's header) matches, an
	// ANIM chunk of at least 6 bytes, an image in every ANMF chunk and no
	// ANMF inside one; and it rejects (as libwebp does) a VP8 frame of zero
	// width, a VP8X canvas over 16383 pixels wide or high, a RIFF size that
	// exceeds the file and an odd one. Go decodes them; libwebp some.
	"container-vp8x-vp8-noexifflag":      "VP8X flags",
	"container-vp8x-vp8-noiccflag":       "VP8X flags",
	"container-vp8x-vp8-noxmpflag":       "VP8X flags",
	"container-vp8x-vp8l-noexifflag":     "VP8X flags",
	"container-vp8x-vp8l-noiccflag":      "VP8X flags",
	"container-vp8x-vp8l-noxmpflag":      "VP8X flags",
	"container-vp8x-flags-reserved":      "VP8X flags",
	"container-vp8x-vp8-iccp-late":       "chunk order",
	"container-vp8x-vp8l-iccp-late":      "chunk order",
	"container-alph-before-iccp":         "chunk order",
	"container-vp8x-vp8-bigger-canvas":   "canvas size",
	"container-vp8x-vp8-smaller-canvas":  "canvas size",
	"container-vp8x-vp8l-bigger-canvas":  "canvas size",
	"container-vp8x-vp8l-smaller-canvas": "canvas size",
	"container-vp8x-huge":                "canvas size",
	"container-vp8-zerowidth":            "zero width",
	"container-vp8l-riff-long":           "RIFF size",
	"container-vp8-riff-odd":             "RIFF size",
	"anim-bad-too-wide":                  "ANMF size",
	"anim-bad-size-mismatch":             "ANMF size",
	"anim-bad-size-mismatch-lossy":       "ANMF size",
	"anim-bad-anim-short":                "ANIM size",
	"anim-bad-nested-anmf":               "ANMF contents",
	"anim-bad-alph-noflag":               "VP8X flags",
}

// webpReferencePolicy says whether the file at path is compared with Go's
// and with libwebp's pixels.
func webpReferencePolicy(path string, data []byte) (goRef, libwebpRef bool) {
	name := strings.TrimSuffix(filepath.Base(path), ".webp")
	switch {
	case webpCOnly[name] != "":
		return false, false
	case webpAnimated(data):
		// An animation: Go's x/image/webp does not decode animations (and
		// may decode an image chunk outside of the ANMF chunks instead).
		return false, true
	case name == "vp8l-simple-reversed":
		// A simple two-symbol Huffman code whose first symbol is the larger
		// one: Wuffs (and Go) give the first symbol the code 0, libwebp
		// gives it to the smaller one.
		return true, false
	}
	return true, true
}

// webpAnimated says whether data is a WebP file with the VP8X animation
// flag.
func webpAnimated(data []byte) bool {
	return len(data) >= 21 && string(data[12:16]) == "VP8X" && data[20]&0x02 != 0
}

// emitWebPAnim emits more runs of an animation: restarts at a later frame
// (script op L) and at a bogus position (B), frames skipped (C without F),
// mixed with the other call sequences, in pieces of every size.
func emitWebPAnim(f *file, i int) {
	for j, script := range []string{"I*L*", "ICCL*", "ICFCLF*", "I*B*", "ICFB*", "IBC*", "ICCCC*", "IF*L*R*"} {
		sched := []string{"W", "C1", "C7", "K61", "C97", "K1"}[(i+j)%6]
		emit(f, pixfmts[(i+j)%len(pixfmts)], j%2, sched, "-", script, false)
	}
	emit(f, bgraNonpremul, 1, "C3", "p", "I*L*", false)
	emit(f, 0x80000565, 0, "K7", "w", "I*", false)
}

// addWebP adds a WebP file to the corpus, with its references.
func addWebP(f *file) {
	files = append(files, f)
	goRef, libwebpRef := webpReferencePolicy(f.path, f.data)
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
	if p := libwebpAnimPaths[f.path]; p != "" && libwebpRef {
		// Any VP8 chunk (in any ANMF chunk) makes it lossy.
		r := webpRef{f: f, expected: p, cat: "webp-anim-lossless-libwebp", anim: true}
		if bytes.Contains(f.data, []byte("VP8 ")) {
			r.cat, r.tol, r.mean = "webp-anim-lossy-libwebp", webpLossyLibwebpTol, webpLossyLibwebpMean
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
		if r.tol == 0 {
			flags = fmt.Sprintf("t0,a0,k%s", r.cat)
		}
		if r.anim {
			flags += ",A"
		}
		fmt.Printf("%s %08X %d %s %s %s %s %s\n", r.f.format, bgraNonpremul, 0, "W", flags, "I*", r.expected, r.f.path)
		if len(r.f.data) <= 3000 {
			fmt.Printf("%s %08X %d %s %s %s %s %s\n", r.f.format, bgraNonpremul, 0, "C1", flags, "I*", r.expected,
				r.f.path)
		}
	}
}
