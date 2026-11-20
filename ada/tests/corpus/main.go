// Part of wuffada (wuffs-ada: Wuffs to Ada).
// SPDX-License-Identifier: Apache-2.0 OR MIT

// corpus builds the test corpus for the generated lzw, deflate, zlib and
// gzip decoders, with independent implementations (Go's compress/* packages)
// of the compressors and, for upstream's fixtures, of the decompressors.
//
// Usage: corpus -data wuffs/test/data -out DIR > manifest
//
// It writes compressed inputs and their expected decompressed outputs to
// DIR and prints a manifest, one line per test case:
//
//	FORMAT INPUT EXPECTED
//
// FORMAT is lzw, deflate, zlib or gzip, or one of the variants that tell the
// drivers to do more than call transform_io: lzw2 .. lzw7 (set the literal
// width), zlibdict and zlibwrongdict (add a dictionary when asked) and
// gzipmulti (decode member after member). EXPECTED is "-" for the inputs that
// are deliberately truncated or corrupted (and for upstream fixtures that
// Go's decompressor rejects): for those, the only expectation is that the
// Ada decoder behaves exactly as upstream's C decoder does.
package main

import (
	"bytes"
	"compress/bzip2"
	"compress/flate"
	"compress/gzip"
	"compress/lzw"
	"compress/zlib"
	"errors"
	"flag"
	"fmt"
	"io"
	"math/rand"
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"strings"
)

var (
	dataDir = flag.String("data", "wuffs/test/data", "the directory of Wuffs' test data")
	outDir  = flag.String("out", "", "the directory to write the corpus to")

	nFiles = 0
)

func main() {
	flag.Parse()
	if *outDir == "" {
		fatal(fmt.Errorf("missing -out"))
	}
	fixtures()
	compressed()
	tools()
	mutations()
}

func fatal(err error) {
	fmt.Fprintln(os.Stderr, "corpus:", err)
	os.Exit(1)
}

func read(name string) []byte {
	b, err := os.ReadFile(filepath.Join(*dataDir, filepath.FromSlash(name)))
	if err != nil {
		fatal(err)
	}
	return b
}

// write saves b in the corpus directory and returns its path.
func write(desc string, b []byte) string {
	nFiles++
	name := filepath.Join(*outDir, fmt.Sprintf("%04d_%s", nFiles, desc))
	if err := os.WriteFile(name, b, 0644); err != nil {
		fatal(err)
	}
	return name
}

// emit adds a test case. A nil expected means "no expectation".
func emit(format string, desc string, input []byte, expected []byte) {
	in := write(desc+"."+format, input)
	want := "-"
	if expected != nil {
		want = write(desc+".expected", expected)
	}
	fmt.Printf("%s %s %s\n", format, in, want)
}

// decoders are Go's decompressors, the independent implementations.
var decoders = map[string]func(b []byte) ([]byte, error){
	"deflate": func(b []byte) ([]byte, error) {
		return io.ReadAll(flate.NewReader(bytes.NewReader(b)))
	},
	"zlib": func(b []byte) ([]byte, error) {
		r, err := zlib.NewReader(bytes.NewReader(b))
		if err != nil {
			return nil, err
		}
		return io.ReadAll(r)
	},
	"gzip": func(b []byte) ([]byte, error) {
		r, err := gzip.NewReader(bytes.NewReader(b))
		if err != nil {
			return nil, err
		}
		r.Multistream(false)
		return io.ReadAll(r)
	},
	"bzip2": func(b []byte) ([]byte, error) {
		return io.ReadAll(bzip2.NewReader(bytes.NewReader(b)))
	},
	// Go's library has no LZMA or lzip decoder: the expectation is the plain
	// file that upstream keeps next to the fixture (see fixtures), or the
	// data that the system's xz compressed (see tools).
	"lzma": func(b []byte) ([]byte, error) { return nil, errors.New("no decoder") },
	"lzip": func(b []byte) ([]byte, error) { return nil, errors.New("no decoder") },
	"xz":   func(b []byte) ([]byte, error) { return nil, errors.New("no decoder") },
	"lzw": func(b []byte) ([]byte, error) {
		return io.ReadAll(lzw.NewReader(bytes.NewReader(b), lzw.LSB, 8))
	},
}

// fixtures adds upstream's own compressed test files.
func fixtures() {
	add := func(format string, name string) {
		input := read(name)
		if format == "lzw" {
			// A .giflzw file is a literal width byte (8) and then GIF's
			// length-prefixed sub-blocks.
			if len(input) == 0 || input[0] != 8 {
				fatal(fmt.Errorf("%s: unexpected literal width", name))
			}
			raw := []byte(nil)
			for p := 1; p < len(input); {
				n := int(input[p])
				p++
				if n == 0 || p+n > len(input) {
					break
				}
				raw = append(raw, input[p:p+n]...)
				p += n
			}
			input = raw
		}
		expected, err := decoders[format](input)
		if err != nil {
			expected = nil
		} else if expected == nil {
			expected = []byte{}
		}
		// Where upstream says what the output is, it must agree with Go.
		if want, err := os.ReadFile(filepath.Join(*dataDir, filepath.FromSlash(name)+".decompressed")); err == nil {
			if expected != nil && !bytes.Equal(want, expected) {
				fatal(fmt.Errorf("%s: Go's output differs from the .decompressed file", name))
			}
		}
		// Upstream's plain file, for a fixture named after it.
		if plain, err := os.ReadFile(filepath.Join(*dataDir, strings.TrimSuffix(name, filepath.Ext(name)))); err == nil &&
			(format == "bzip2" || format == "lzma" || format == "lzip" || format == "xz") {
			if expected != nil && !bytes.Equal(plain, expected) {
				fatal(fmt.Errorf("%s: Go's output differs from the plain file", name))
			}
			expected = nonNil(plain)
		}
		desc := "fixture_" + strings.NewReplacer("/", "_", ".", "_").Replace(name)
		emit(format, desc, input, expected)
	}
	for _, name := range []string{"256.bytes.gz", "archive.tar.gz", "midsummer.txt.gz", "pi.txt.gz", "romeo.txt.gz"} {
		add("gzip", name)
	}
	for _, name := range []string{"DCI-P3-D65.icc.zlib", "midsummer.txt.zlib", "pi.txt.zlib", "romeo.txt.zlib"} {
		add("zlib", name)
	}
	for _, name := range []string{
		"256.bytes.bz2", "abraca.txt.bz2", "archive.tar.bz2", "midsummer.txt.bz2", "pi.txt.bz2", "romeo.txt.bz2",
	} {
		add("bzip2", name)
	}
	for _, name := range []string{"enwik5.lzma", "romeo.txt.lzma"} {
		add("lzma", name)
	}
	add("lzip", "romeo.txt.lz")
	for _, name := range []string{
		"256.bytes.two-concatenated-streams.xz", "enwik5.block-size-32k.xz", "enwik5.lzma2-chunk-max-1-13.xz",
		"enwik5.xz", "romeo.txt.delta1.xz", "romeo.txt.xz",
	} {
		add("xz", name)
	}
	for _, name := range []string{"romeo.txt.deflate", "romeo.txt.fixed-huff.deflate"} {
		add("deflate", name)
	}
	artificial, err := filepath.Glob(filepath.Join(*dataDir, "artificial-deflate", "*.deflate"))
	if err != nil {
		fatal(err)
	}
	sort.Strings(artificial)
	for _, name := range artificial {
		add("deflate", "artificial-deflate/"+filepath.Base(name))
	}
	for _, name := range []string{
		"bricks-dither.indexes.giflzw", "bricks-gray.indexes.giflzw",
		"bricks-nodither.indexes.giflzw", "pi.txt.giflzw",
	} {
		add("lzw", name)
	}
}

func deflate(b []byte, level int) []byte {
	buf := &bytes.Buffer{}
	w, err := flate.NewWriter(buf, level)
	if err != nil {
		fatal(err)
	}
	w.Write(b)
	w.Close()
	return buf.Bytes()
}

func zlibCompress(b []byte, level int) []byte {
	buf := &bytes.Buffer{}
	w, err := zlib.NewWriterLevel(buf, level)
	if err != nil {
		fatal(err)
	}
	w.Write(b)
	w.Close()
	return buf.Bytes()
}

func gzipCompress(b []byte, level int, header bool) []byte {
	buf := &bytes.Buffer{}
	w, err := gzip.NewWriterLevel(buf, level)
	if err != nil {
		fatal(err)
	}
	if header {
		// Every optional header field: FEXTRA, FNAME and FCOMMENT.
		w.Extra = []byte("extra field data")
		w.Name = "a-file-name.txt"
		w.Comment = "a comment"
	}
	w.Write(b)
	w.Close()
	return buf.Bytes()
}

func lzwCompress(b []byte) []byte {
	buf := &bytes.Buffer{}
	w := lzw.NewWriter(buf, lzw.LSB, 8)
	w.Write(b)
	w.Close()
	return buf.Bytes()
}

type source struct {
	name string
	data []byte
}

// sources returns the plain data to compress.
func sources() []source {
	rng := rand.New(rand.NewSource(1))
	random := func(n int) []byte {
		b := make([]byte, n)
		rng.Read(b)
		return b
	}
	ret := []source{}
	for _, name := range []string{"0.bytes", "abraca.txt", "256.bytes", "romeo.txt", "midsummer.txt", "pi.txt", "bricks-color.png"} {
		ret = append(ret, source{strings.ReplaceAll(name, ".", "_"), read(name)})
	}
	// A match at the maximum distance, 32768: the first bytes come back
	// exactly one window later.
	far := random(32768)
	far = append(far, far[:1500]...)
	ret = append(ret, source{"distance_32768", far})
	// Long runs: distance 1 with the maximum match length, over and over.
	ret = append(ret, source{"zeroes", make([]byte, 100000)})
	// Incompressible: stored blocks, whatever the level.
	ret = append(ret, source{"random", random(70000)})
	// More than the 32 KiB window of varied but compressible text.
	big := []byte(nil)
	for len(big) < 300000 {
		big = append(big, read("midsummer.txt")...)
		big = append(big, random(64)...)
	}
	ret = append(ret, source{"big", big})
	return ret
}

var levels = []struct {
	name  string
	level int
}{
	{"stored", flate.NoCompression},
	{"l1", flate.BestSpeed},
	{"l6", 6},
	{"l9", flate.BestCompression},
	{"huffman", flate.HuffmanOnly},
}

// compressed adds data that this program compresses itself.
func compressed() {
	for _, s := range sources() {
		for _, lv := range levels {
			emit("deflate", s.name+"_"+lv.name, deflate(s.data, lv.level), nonNil(s.data))
			emit("zlib", s.name+"_"+lv.name, zlibCompress(s.data, lv.level), nonNil(s.data))
			emit("gzip", s.name+"_"+lv.name, gzipCompress(s.data, lv.level, false), nonNil(s.data))
		}
		emit("gzip", s.name+"_header", gzipCompress(s.data, 6, true), nonNil(s.data))
		emit("lzw", s.name, lzwCompress(s.data), nonNil(s.data))
	}

	// A multi-member gzip file. Like upstream's C, the decoder stops after
	// the first member; the rest of the input is left unread.
	first, second := read("romeo.txt"), read("abraca.txt")
	multi := append(gzipCompress(first, 6, false), gzipCompress(second, 6, false)...)
	emit("gzip", "multi_member", multi, first)

	// A zlib stream that needs a preset dictionary, which the test drivers
	// do not supply: the decoder stops with the note "dictionary required".
	dict := &bytes.Buffer{}
	if w, err := zlib.NewWriterLevelDict(dict, 6, []byte("Romeo and Juliet")); err != nil {
		fatal(err)
	} else {
		w.Write(first)
		w.Close()
	}
	emit("zlib", "preset_dictionary", dict.Bytes(), nil)

	// The drivers decode a "gzipmulti" input member after member (starting
	// again, after each ok, on the rest of the input). The second file has
	// an empty member in the middle.
	emit("gzipmulti", "multi_member", multi, append(append([]byte(nil), first...), second...))
	three := append(gzipCompress(second, 9, true), gzipCompress(nil, 6, false)...)
	three = append(three, gzipCompress(first, 1, false)...)
	emit("gzipmulti", "three_members", three, append(append([]byte(nil), second...), first...))

	// zlib streams with a preset dictionary that the drivers do supply
	// ("zlibdict": after the decoder asks for it, they add driverDictionary)
	// or supply wrongly ("zlibwrongdict": they add other bytes).
	withDict := &bytes.Buffer{}
	if w, err := zlib.NewWriterLevelDict(withDict, 9, driverDictionary()); err != nil {
		fatal(err)
	} else {
		w.Write(read("midsummer.txt"))
		w.Close()
	}
	zd := withDict.Bytes()
	emit("zlibdict", "dictionary", zd, read("midsummer.txt"))
	emit("zlibwrongdict", "dictionary_wrong", zd, nil)
	emit("zlib", "dictionary_missing", zd, nil)
	for _, cut := range []int{1, 2, 3, 5, 6, 7, len(zd) / 2, len(zd) - 4, len(zd) - 1} {
		emit("zlibdict", fmt.Sprintf("dictionary_truncated_%d", cut), zd[:cut], nil)
	}
	for _, pos := range []int{2, 3, 5, 6, len(zd) / 2, len(zd) - 4, len(zd) - 1} {
		c := append([]byte(nil), zd...)
		c[pos] ^= 0x10
		emit("zlibdict", fmt.Sprintf("dictionary_corrupt_%d", pos), c, nil)
	}

	// LZW with literal widths other than 8 ("lzwN": the drivers set the
	// decoder's literal width quirk to N + 1).
	for width := 2; width <= 7; width++ {
		data := append([]byte(nil), read("midsummer.txt")...)
		for i := range data {
			data[i] &= byte(1<<uint(width) - 1)
		}
		buf := &bytes.Buffer{}
		w := lzw.NewWriter(buf, lzw.LSB, width)
		w.Write(data)
		w.Close()
		emit(fmt.Sprintf("lzw%d", width), fmt.Sprintf("literal_width_%d", width), buf.Bytes(), data)
		emit(fmt.Sprintf("lzw%d", width), fmt.Sprintf("literal_width_%d_truncated", width),
			buf.Bytes()[:buf.Len()/2], nil)
	}

	// Trailing garbage after a complete stream is likewise left unread.
	emit("deflate", "trailing_garbage", append(deflate(first, 6), "garbage"...), first)
	emit("zlib", "trailing_garbage", append(zlibCompress(first, 6), "garbage"...), first)
}

// driverDictionary is the preset dictionary that the test drivers add for a
// "zlibdict" input: 1000 bytes, byte i being (7 * i + i / 13) mod 256. (For
// "zlibwrongdict" they add 1000 bytes of (3 * i + 1) mod 256.)
func driverDictionary() []byte {
	b := make([]byte, 1000)
	for i := range b {
		b[i] = byte(7*i + i/13)
	}
	return b
}

func nonNil(b []byte) []byte {
	if b == nil {
		return []byte{}
	}
	return b
}

// tool runs a compressor of this system, if it has it, over b.
func tool(b []byte, name string, args ...string) []byte {
	path, err := exec.LookPath(name)
	if err != nil {
		return nil
	}
	cmd := exec.Command(path, args...)
	cmd.Stdin = bytes.NewReader(b)
	out, err := cmd.Output()
	if err != nil {
		fatal(fmt.Errorf("%s: %v", name, err))
	}
	return out
}

// tools adds what the system's bzip2 and xz (as an LZMA compressor) make of
// the sources, where those programs are installed.
func tools() {
	n := 0
	for _, s := range sources() {
		for _, level := range []string{"-1", "-9"} {
			if c := tool(s.data, "bzip2", "-c", level); c != nil {
				emit("bzip2", s.name+"_tool"+level, c, nonNil(s.data))
				n++
			}
		}
		for i, check := range []string{"none", "crc32", "crc64", "sha256"} {
			level := []string{"-0", "-6", "-3", "-1"}[i]
			if c := tool(s.data, "xz", "--format=xz", "--check="+check, "-c", level); c != nil {
				emit("xz", s.name+"_tool"+level+"_"+check, c, nonNil(s.data))
				n++
			}
		}
		for _, level := range []string{"-0", "-6"} {
			if c := tool(s.data, "xz", "--format=lzma", "-c", level); c != nil {
				emit("lzma", s.name+"_tool"+level, c, nonNil(s.data))
				n++
			}
		}
	}
	fmt.Fprintf(os.Stderr, "corpus: %d inputs from the system's bzip2 and xz\n", n)
}

// mutations adds truncated and corrupted inputs. What the decoder must do
// with them is whatever upstream's C does.
func mutations() {
	romeo := read("romeo.txt")
	midsummer := read("midsummer.txt")
	bases := []struct {
		format string
		name   string
		data   []byte
	}{
		{"deflate", "romeo_l6", deflate(romeo, 6)},
		{"deflate", "romeo_stored", deflate(romeo, flate.NoCompression)},
		{"deflate", "midsummer_l9", deflate(midsummer, 9)},
		{"zlib", "romeo_l6", zlibCompress(romeo, 6)},
		{"gzip", "romeo_l6", gzipCompress(romeo, 6, false)},
		{"gzip", "romeo_header", gzipCompress(romeo, 6, true)},
		{"lzw", "romeo", lzwCompress(romeo)},
		{"lzw", "midsummer", lzwCompress(midsummer)},
		{"bzip2", "romeo_fixture", read("romeo.txt.bz2")},
		{"bzip2", "256_fixture", read("256.bytes.bz2")},
		{"lzma", "romeo_fixture", read("romeo.txt.lzma")},
		{"lzip", "romeo_fixture", read("romeo.txt.lz")},
		{"xz", "romeo_fixture", read("romeo.txt.xz")},
		{"xz", "delta_fixture", read("romeo.txt.delta1.xz")},
	}
	for _, b := range bases {
		n := len(b.data)
		for _, cut := range []int{0, 1, 2, 3, 5, 10, 11, 20, n / 3, n / 2, n - 9, n - 8, n - 5, n - 4, n - 1} {
			if cut < 0 || cut >= n {
				continue
			}
			emit(b.format, fmt.Sprintf("%s_truncated_%d", b.name, cut), b.data[:cut], nil)
		}
		for _, pos := range []int{0, 1, 2, 3, 4, 9, 10, 12, 20, 33, n / 4, n / 3, n / 2, (2 * n) / 3, n - 9, n - 8, n - 5, n - 4, n - 2, n - 1} {
			if pos < 0 || pos >= n {
				continue
			}
			for _, mask := range []byte{0x01, 0x80, 0xFF} {
				c := append([]byte(nil), b.data...)
				c[pos] ^= mask
				emit(b.format, fmt.Sprintf("%s_corrupt_%d_%02x", b.name, pos, mask), c, nil)
			}
		}
	}
}
