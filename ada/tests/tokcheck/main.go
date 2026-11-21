// Part of wuffada (wuffs-ada: Wuffs to Ada).
// SPDX-License-Identifier: Apache-2.0 OR MIT

// tokcheck compares the tokens that the Ada json and cbor decoders wrote
// (ada/tests/test_tokens.adb, after a "dump DIR" manifest line) with
// references that do not come from Wuffs:
//
//   - jsonref: Go's encoding/json. The verdict (valid or not) must agree,
//     allowing for what std/json rejects by design and Go accepts: nesting
//     deeper than 1024 (DECODER_DEPTH_MAX_INCL), numbers longer than 99
//     bytes ("#unsupported number length"), invalid UTF-8 (which Go's
//     json.Valid does not look at) and \u escapes that are lone surrogates
//     (which Go turns into U+FFFD). For a valid input, the strings, numbers,
//     literals and brackets that the tokens spell out must be those of
//     Go's json.Decoder.Token, one for one. The decoder must have consumed
//     everything but trailing whitespace.
//   - cborref: the CBOR walker below, written from RFC 8949 for this test
//     (well-formedness, UTF-8 in text strings, and std/cbor's documented
//     depth limit of 1024). The verdict, the number of bytes consumed and
//     the data items that the tokens spell out (integers, strings, tags,
//     simple values, floats, brackets) must agree.
//   - golden=PATH: one of upstream's golden token files, in the 16 bytes per
//     token format of upstream's test/c/testlib/testlib.c.
//
// For every case it also checks that the tokens' lengths add up to the
// number of bytes consumed (tokens partition the input).
//
// Usage: tokcheck DIR
//
// Prints a summary; exits with status 1 if anything disagrees.
package main

import (
	"bytes"
	"encoding/binary"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"math/big"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"unicode/utf8"
)

// Token layout (wuffs/internal/cgen/base/token-public.h).
const (
	vbcFiller   = 0
	vbcStruct   = 1
	vbcString   = 2
	vbcCodePt   = 3
	vbcLiteral  = 4
	vbcNumber   = 5
	vbcIntSign  = 6
	vbcIntUnsig = 7

	cborValueMajor = 0x0B29FA
)

type token uint64

func (t token) length() int        { return int(t & 0xFFFF) }
func (t token) continued() bool    { return t&0x10000 != 0 }
func (t token) value() int64       { return int64(t) >> 17 }
func (t token) valueMajor() int64  { return int64(t) >> 42 }
func (t token) valueMinor() uint64 { return (uint64(t) >> 17) & 0x1FF_FFFF }
func (t token) vbc() int64         { return int64(t) >> 38 }
func (t token) vbd() uint64        { return (uint64(t) >> 17) & 0x1F_FFFF }
func (t token) valueExtension() uint64 {
	return uint64((^int64(t))>>17) & (1<<46 - 1)
}

type result struct {
	n         string
	format    string
	quirks    uint64
	input     string
	check     string
	category  int
	code      int
	consumed  int
	tokens    []token
	src       []byte
	positions []int // Where each token starts in src.
}

var (
	failures int
	counts   = map[string]int{}
	notes    = map[string]int{}
)

func fail(r *result, format string, args ...interface{}) {
	failures++
	if failures <= 50 {
		fmt.Printf("tokcheck: FAIL: case %s (%s %s, %s): %s\n", r.n, r.format, r.input, r.check,
			fmt.Sprintf(format, args...))
	}
}

func main() {
	if len(os.Args) != 2 {
		fmt.Fprintln(os.Stderr, "usage: tokcheck DIR")
		os.Exit(2)
	}
	dir := os.Args[1]
	index, err := os.ReadFile(filepath.Join(dir, "index.txt"))
	if err != nil {
		fmt.Fprintln(os.Stderr, "tokcheck:", err)
		os.Exit(2)
	}
	for _, line := range strings.Split(string(index), "\n") {
		f := strings.Fields(line)
		if len(f) == 0 {
			continue
		}
		if len(f) != 8 {
			fmt.Fprintf(os.Stderr, "tokcheck: bad index line %q\n", line)
			os.Exit(2)
		}
		r := &result{n: f[0], format: f[1], input: f[3], check: f[4]}
		r.quirks, _ = strconv.ParseUint(f[2], 16, 32)
		r.category, _ = strconv.Atoi(f[5])
		r.code, _ = strconv.Atoi(f[6])
		r.consumed, _ = strconv.Atoi(f[7])
		raw, err := os.ReadFile(filepath.Join(dir, f[0]+".tok"))
		if err == nil {
			r.src, err = os.ReadFile(r.input)
		}
		if err != nil {
			fmt.Fprintln(os.Stderr, "tokcheck:", err)
			os.Exit(2)
		}
		pos := 0
		for i := 0; i+8 <= len(raw); i += 8 {
			t := token(binary.LittleEndian.Uint64(raw[i:]))
			r.tokens = append(r.tokens, t)
			r.positions = append(r.positions, pos)
			pos += t.length()
		}
		counts["cases"]++
		if pos != r.consumed {
			fail(r, "the tokens' lengths add up to %d, but %d bytes were consumed", pos, r.consumed)
		}
		if r.consumed > len(r.src) {
			fail(r, "consumed %d bytes of %d", r.consumed, len(r.src))
			continue
		}
		switch {
		case r.check == "jsonref":
			checkJSON(r)
		case r.check == "cborref":
			checkCBOR(r)
		case strings.HasPrefix(r.check, "golden="):
			checkGolden(r, strings.TrimPrefix(r.check, "golden="))
		default:
			fail(r, "unknown check")
		}
	}
	fmt.Printf("tokcheck: %d cases: %d jsonref (%d valid), %d cborref (%d valid), %d golden\n",
		counts["cases"], counts["jsonref"], counts["jsonvalid"], counts["cborref"], counts["cborvalid"],
		counts["golden"])
	for _, k := range sortedKeys(notes) {
		if strings.HasPrefix(k, "upstream") {
			fmt.Printf("tokcheck: %s: %d cases\n", k, notes[k])
		} else {
			fmt.Printf("tokcheck: as expected, std/json rejects what Go accepts: %s: %d cases\n", k, notes[k])
		}
	}
	if failures > 0 || counts["cases"] == 0 {
		fmt.Printf("tokcheck: %d failures\n", failures)
		os.Exit(1)
	}
	fmt.Println("tokcheck: PASS")
}

func sortedKeys(m map[string]int) []string {
	keys := []string{}
	for k := range m {
		keys = append(keys, k)
	}
	for i := range keys {
		for j := i + 1; j < len(keys); j++ {
			if keys[j] < keys[i] {
				keys[i], keys[j] = keys[j], keys[i]
			}
		}
	}
	return keys
}

// ---- golden

func checkGolden(r *result, path string) {
	counts["golden"]++
	want, err := os.ReadFile(path)
	if err != nil {
		fail(r, "%v", err)
		return
	}
	var have bytes.Buffer
	for i, t := range r.tokens {
		if t.value() == 0 {
			continue
		}
		rec := make([]byte, 16)
		binary.BigEndian.PutUint32(rec[0:], uint32(r.positions[i]))
		binary.BigEndian.PutUint16(rec[4:], uint16(t.length()))
		if t.continued() {
			binary.BigEndian.PutUint16(rec[6:], 1)
		}
		switch vmajor := t.valueMajor(); {
		case vmajor > 0:
			binary.BigEndian.PutUint32(rec[8:], uint32(vmajor))
			binary.BigEndian.PutUint32(rec[12:], uint32(t.valueMinor()))
		case vmajor == 0:
			rec[12] = byte(t.vbc())
			rec[13] = byte(t.vbd() >> 16)
			rec[14] = byte(t.vbd() >> 8)
			rec[15] = byte(t.vbd())
		default:
			rec[8] = 1
			v := uint64((^int64(t)) >> 17)
			for k := 0; k < 7; k++ {
				rec[9+k] = byte(v >> (8 * (6 - k)))
			}
		}
		have.Write(rec)
	}
	if !bytes.Equal(have.Bytes(), want) {
		fail(r, "the tokens differ from %s (%d bytes, want %d)", path, have.Len(), len(want))
	}
	if r.category != 0 {
		fail(r, "status %d:%d, not ok", r.category, r.code)
	}
}

// ---- JSON

func isJSONSpace(c byte) bool { return c == ' ' || c == '\t' || c == '\n' || c == '\r' }

func checkJSON(r *result) {
	counts["jsonref"]++
	if r.quirks != 0 {
		fail(r, "jsonref with quirks")
		return
	}
	wuffsValid := r.category == 0
	for _, c := range r.src[r.consumed:] {
		if !isJSONSpace(c) {
			wuffsValid = false
		}
	}

	goValid := json.Valid(r.src)
	expected, why := goValid, ""
	var goTokens []string
	if goValid {
		toks, depth, maxNum, err := goJSONTokens(r.src)
		switch {
		case err != nil:
			fail(r, "Go: json.Valid but not json.Decoder: %v", err)
			return
		case !utf8.Valid(r.src):
			expected, why = false, "invalid UTF-8"
		case loneSurrogate(r.src):
			expected, why = false, "a \\u escape that is a lone surrogate"
		case depth > 1024:
			expected, why = false, "nesting deeper than 1024"
		case maxNum > 99:
			expected, why = false, "a number longer than 99 bytes"
		}
		goTokens = toks
	}
	if wuffsValid != expected {
		fail(r, "std/json says valid=%v (status %d:%d, %d of %d bytes), Go says valid=%v %s",
			wuffsValid, r.category, r.code, r.consumed, len(r.src), goValid, why)
		return
	}
	if why != "" {
		notes[why]++
	}
	if !wuffsValid {
		return
	}
	counts["jsonvalid"]++
	have, err := wuffsJSONTokens(r)
	if err != nil {
		fail(r, "%v", err)
		return
	}
	if len(have) != len(goTokens) {
		fail(r, "%d values from the tokens, %d from Go", len(have), len(goTokens))
		return
	}
	for i := range have {
		if have[i] != goTokens[i] {
			fail(r, "value %d: %q from the tokens, %q from Go", i, have[i], goTokens[i])
			return
		}
	}
}

// goJSONTokens returns Go's json.Decoder.Token sequence, as strings, the
// nesting depth and the length of the longest number.
func goJSONTokens(src []byte) ([]string, int, int, error) {
	d := json.NewDecoder(bytes.NewReader(src))
	d.UseNumber()
	var out []string
	depth, maxDepth, maxNum := 0, 0, 0
	for {
		t, err := d.Token()
		if err == io.EOF {
			break
		}
		if err != nil {
			return nil, 0, 0, err
		}
		switch v := t.(type) {
		case json.Delim:
			out = append(out, v.String())
			if v == '[' || v == '{' {
				depth++
				if depth > maxDepth {
					maxDepth = depth
				}
			} else {
				depth--
			}
		case string:
			out = append(out, "s:"+v)
		case json.Number:
			out = append(out, "n:"+string(v))
			if len(v) > maxNum {
				maxNum = len(v)
			}
		case bool:
			out = append(out, fmt.Sprint(v))
		case nil:
			out = append(out, "null")
		default:
			return nil, 0, 0, fmt.Errorf("unexpected token %T", t)
		}
	}
	return out, maxDepth, maxNum, nil
}

// loneSurrogate reports whether a JSON string in src has a \u escape of a
// surrogate that is not half of a high-low pair.
func loneSurrogate(src []byte) bool {
	hex4 := func(i int) (int, bool) {
		if i+6 > len(src) || src[i] != '\\' || src[i+1] != 'u' {
			return 0, false
		}
		v, err := strconv.ParseUint(string(src[i+2:i+6]), 16, 16)
		return int(v), err == nil
	}
	in := false
	for i := 0; i < len(src); i++ {
		c := src[i]
		if !in {
			in = c == '"'
			continue
		}
		switch c {
		case '"':
			in = false
		case '\\':
			v, ok := hex4(i)
			if !ok {
				i++
				continue
			}
			switch {
			case 0xD800 <= v && v < 0xDC00:
				w, ok := hex4(i + 6)
				if !ok || w < 0xDC00 || w > 0xDFFF {
					return true
				}
				i += 11
			case 0xDC00 <= v && v < 0xE000:
				return true
			default:
				i += 5
			}
		}
	}
	return false
}

// wuffsJSONTokens spells out the values that std/json's tokens describe, in
// the form of goJSONTokens.
func wuffsJSONTokens(r *result) ([]string, error) {
	var out []string
	var str []byte
	inString := false
	for i, t := range r.tokens {
		if t.valueMajor() != 0 {
			return nil, fmt.Errorf("token %d: value_major %d", i, t.valueMajor())
		}
		text := r.src[r.positions[i] : r.positions[i]+t.length()]
		vbd := t.vbd()
		switch t.vbc() {
		case vbcFiller:
			if inString {
				return nil, fmt.Errorf("token %d: filler in a string", i)
			}
		case vbcStruct:
			switch {
			case vbd&1 != 0 && vbd&0x2000 != 0:
				out = append(out, "[")
			case vbd&1 != 0 && vbd&0x4000 != 0:
				out = append(out, "{")
			case vbd&2 != 0 && vbd&0x20 != 0:
				out = append(out, "]")
			case vbd&2 != 0 && vbd&0x40 != 0:
				out = append(out, "}")
			default:
				return nil, fmt.Errorf("token %d: structure 0x%X", i, vbd)
			}
		case vbcString:
			inString = true
			switch {
			case vbd&0x100 != 0:
			case vbd&0x200 != 0:
				str = append(str, text...)
			default:
				return nil, fmt.Errorf("token %d: string conversion 0x%X", i, vbd)
			}
		case vbcCodePt:
			inString = true
			str = utf8.AppendRune(str, rune(vbd))
		case vbcLiteral:
			switch vbd {
			case 2:
				out = append(out, "null")
			case 4:
				out = append(out, "false")
			case 8:
				out = append(out, "true")
			default:
				return nil, fmt.Errorf("token %d: literal 0x%X", i, vbd)
			}
		case vbcNumber:
			if t.continued() {
				return nil, fmt.Errorf("token %d: a continued number", i)
			}
			out = append(out, "n:"+string(text))
		default:
			return nil, fmt.Errorf("token %d: category %d", i, t.vbc())
		}
		if inString && !t.continued() {
			out = append(out, "s:"+string(str))
			str, inString = nil, false
		}
	}
	if inString {
		return nil, errors.New("an unfinished string")
	}
	return out, nil
}

// ---- CBOR

func checkCBOR(r *result) {
	counts["cborref"]++
	w := &walker{src: r.src}
	err := w.item(0, false)
	if w.sawEmptyChunk {
		// Upstream std/cbor (decode_cbor.wuffs, major types 2 and 3) takes
		// an empty definite-length chunk inside an indefinite-length string
		// for the end of a string item, and goes on from there in a way
		// that is not worth imitating here. The trace comparison with
		// upstream's C covers these cases.
		notes["upstream std/cbor: an empty chunk inside an indefinite-length string (not compared)"]++
		return
	}
	if w.sawZeroLength {
		// Upstream std/cbor (major types 4 and 5) tests c_minor == 0, not the
		// length, for an empty container: an array or map whose zero length
		// is encoded in 1, 2, 4 or 8 bytes (98 00, B9 00 00, ...) is taken
		// for an indefinite-length one, which a break code closes. Compare
		// with a walk that does the same.
		notes["upstream std/cbor: a zero-length array or map whose length is not inline is indefinite-length"]++
		w = &walker{src: r.src, zeroLengthIsIndefinite: true}
		err = w.item(0, false)
	}
	wuffsOK := r.category == 0
	if wuffsOK != (err == nil) {
		fail(r, "std/cbor: status %d:%d; walker: %v", r.category, r.code, err)
		return
	}
	if err != nil {
		if r.category != 3 {
			fail(r, "status %d:%d for an input that is not well-formed (%v)", r.category, r.code, err)
		}
		return
	}
	counts["cborvalid"]++
	if w.pos != r.consumed {
		fail(r, "consumed %d bytes, the walker %d", r.consumed, w.pos)
		return
	}
	have, err := wuffsCBORItems(r)
	if err != nil {
		fail(r, "%v", err)
		return
	}
	if len(have) != len(w.out) {
		fail(r, "%d items from the tokens, %d from the walker", len(have), len(w.out))
		return
	}
	for i := range have {
		if have[i] != w.out[i] {
			fail(r, "item %d: %q from the tokens, %q from the walker", i, have[i], w.out[i])
			return
		}
	}
}

// walker decodes CBOR (RFC 8949) into a list of items, as strings.
type walker struct {
	src []byte
	pos int
	out []string

	// What it has seen that upstream std/cbor does not handle per RFC 8949
	// (see checkCBOR), and whether to imitate upstream for the second.
	sawEmptyChunk          bool
	sawZeroLength          bool
	zeroLengthIsIndefinite bool
}

var errBreak = errors.New("break")

func (w *walker) arg(ai byte) (uint64, error) {
	n := 0
	switch {
	case ai < 24:
		return uint64(ai), nil
	case ai == 24:
		n = 1
	case ai == 25:
		n = 2
	case ai == 26:
		n = 4
	case ai == 27:
		n = 8
	default:
		return 0, fmt.Errorf("additional information %d", ai)
	}
	if w.pos+n > len(w.src) {
		return 0, errors.New("truncated argument")
	}
	v := uint64(0)
	for i := 0; i < n; i++ {
		v = v<<8 | uint64(w.src[w.pos+i])
	}
	w.pos += n
	return v, nil
}

// item reads one data item at nesting depth depth. If breakOK, a break code
// is returned as errBreak (and consumed).
func (w *walker) item(depth int, breakOK bool) error {
	if w.pos >= len(w.src) {
		return errors.New("truncated")
	}
	ib := w.src[w.pos]
	w.pos++
	major, ai := ib>>5, ib&0x1F
	if ib == 0xFF {
		if breakOK {
			return errBreak
		}
		return errors.New("unexpected break")
	}
	if major == 4 || major == 5 {
		if ai >= 24 && ai <= 27 && w.pos+(1<<(ai-24)) <= len(w.src) &&
			allZero(w.src[w.pos:w.pos+(1<<(ai-24))]) {
			w.sawZeroLength = true
			if w.zeroLengthIsIndefinite {
				w.pos += 1 << (ai - 24)
				ai = 31
			}
		}
	}
	if ai == 31 {
		switch major {
		case 2, 3:
			var s []byte
			for {
				if w.pos >= len(w.src) {
					return errors.New("truncated indefinite string")
				}
				c := w.src[w.pos]
				w.pos++
				if c == 0xFF {
					break
				}
				if c>>5 != major || c&0x1F == 31 {
					return errors.New("bad chunk")
				}
				n, err := w.arg(c & 0x1F)
				if err != nil {
					return err
				}
				chunk, err := w.bytes(n)
				if err != nil {
					return err
				}
				if n == 0 {
					w.sawEmptyChunk = true
				}
				if major == 3 && !utf8.Valid(chunk) {
					return errors.New("invalid UTF-8")
				}
				s = append(s, chunk...)
			}
			w.str(major, s)
			return nil
		case 4, 5:
			if depth >= 1024 {
				return errors.New("too deep")
			}
			open, close := "[", "]"
			if major == 5 {
				open, close = "{", "}"
			}
			w.out = append(w.out, open)
			for k := 0; ; k++ {
				err := w.item(depth+1, true)
				if err == errBreak {
					if major == 5 && k%2 == 1 {
						return errors.New("break after a key")
					}
					break
				}
				if err != nil {
					return err
				}
			}
			w.out = append(w.out, close)
			return nil
		}
		return fmt.Errorf("indefinite length for major type %d", major)
	}
	v, err := w.arg(ai)
	if err != nil {
		return err
	}
	switch major {
	case 0:
		w.out = append(w.out, "i:"+new(big.Int).SetUint64(v).String())
	case 1:
		x := new(big.Int).SetUint64(v)
		w.out = append(w.out, "i:"+x.Neg(x).Sub(x, big.NewInt(1)).String())
	case 2, 3:
		s, err := w.bytes(v)
		if err != nil {
			return err
		}
		if major == 3 && !utf8.Valid(s) {
			return errors.New("invalid UTF-8")
		}
		w.str(major, s)
	case 4, 5:
		if depth >= 1024 {
			return errors.New("too deep")
		}
		n := v
		open, close := "[", "]"
		if major == 5 {
			open, close = "{", "}"
			if n > 1<<62 {
				return errors.New("truncated map")
			}
			n *= 2
		}
		w.out = append(w.out, open)
		for k := uint64(0); k < n; k++ {
			if err := w.item(depth+1, false); err != nil {
				return err
			}
		}
		w.out = append(w.out, close)
	case 6:
		w.out = append(w.out, "tag:"+strconv.FormatUint(v, 10))
		return w.item(depth, false)
	case 7:
		switch {
		case ai < 20:
			w.out = append(w.out, "simple:"+strconv.FormatUint(v, 10))
		case ai == 20:
			w.out = append(w.out, "false")
		case ai == 21:
			w.out = append(w.out, "true")
		case ai == 22:
			w.out = append(w.out, "null")
		case ai == 23:
			w.out = append(w.out, "undefined")
		case ai == 24:
			if v < 32 {
				return errors.New("two-byte simple value below 32")
			}
			w.out = append(w.out, "simple:"+strconv.FormatUint(v, 10))
		case ai == 25:
			w.out = append(w.out, fmt.Sprintf("f16:%04X", v))
		case ai == 26:
			w.out = append(w.out, fmt.Sprintf("f32:%08X", v))
		case ai == 27:
			w.out = append(w.out, fmt.Sprintf("f64:%016X", v))
		}
	}
	return nil
}

func allZero(b []byte) bool {
	for _, c := range b {
		if c != 0 {
			return false
		}
	}
	return true
}

func (w *walker) bytes(n uint64) ([]byte, error) {
	if n > uint64(len(w.src)-w.pos) {
		return nil, errors.New("truncated string")
	}
	s := w.src[w.pos : w.pos+int(n)]
	w.pos += int(n)
	return s, nil
}

func (w *walker) str(major byte, s []byte) {
	if major == 3 {
		w.out = append(w.out, fmt.Sprintf("text:%x", s))
	} else {
		w.out = append(w.out, fmt.Sprintf("bytes:%x", s))
	}
}

// wuffsCBORItems spells out the items that std/cbor's tokens describe, in
// the form of the walker's.
func wuffsCBORItems(r *result) ([]string, error) {
	var out []string
	toks := r.tokens
	for i := 0; i < len(toks); i++ {
		t := toks[i]
		text := r.src[r.positions[i] : r.positions[i]+t.length()]
		// extend combines a continued token's value with the next token's
		// value_extension.
		extend := func(v *big.Int) error {
			if !t.continued() {
				return nil
			}
			if i+1 >= len(toks) || toks[i+1].valueMajor() >= 0 {
				return fmt.Errorf("token %d: no extended token after a continued one", i)
			}
			i++
			v.Lsh(v, 46)
			v.Or(v, new(big.Int).SetUint64(toks[i].valueExtension()))
			return nil
		}
		switch vmajor := t.valueMajor(); {
		case vmajor == cborValueMajor:
			minor := t.valueMinor()
			switch {
			case minor&0x100_0000 != 0:
				if len(text) != 9 {
					return nil, fmt.Errorf("token %d: MINUS_1_MINUS_X of length %d", i, len(text))
				}
				x := new(big.Int).SetUint64(binary.BigEndian.Uint64(text[1:]))
				out = append(out, "i:"+x.Neg(x).Sub(x, big.NewInt(1)).String())
			case minor&0x80_0000 != 0:
				out = append(out, "simple:"+strconv.FormatUint(minor&0xFF, 10))
			case minor&0x40_0000 != 0:
				v := new(big.Int).SetUint64(minor & 0x3_FFFF)
				if err := extend(v); err != nil {
					return nil, err
				}
				out = append(out, "tag:"+v.String())
			default:
				return nil, fmt.Errorf("token %d: cbor value_minor 0x%X", i, minor)
			}
		case vmajor != 0:
			return nil, fmt.Errorf("token %d: value_major %d", i, vmajor)
		default:
			vbd := t.vbd()
			switch t.vbc() {
			case vbcStruct:
				switch {
				case vbd&1 != 0 && vbd&0x2000 != 0:
					out = append(out, "[")
				case vbd&1 != 0 && vbd&0x4000 != 0:
					out = append(out, "{")
				case vbd&2 != 0 && vbd&0x20 != 0:
					out = append(out, "]")
				case vbd&2 != 0 && vbd&0x40 != 0:
					out = append(out, "}")
				default:
					return nil, fmt.Errorf("token %d: structure 0x%X", i, vbd)
				}
			case vbcString:
				isText := vbd&0x2 != 0
				var s []byte
				for {
					t = toks[i]
					if t.valueMajor() != 0 || t.vbc() != vbcString {
						return nil, fmt.Errorf("token %d: not a string token in a string chain", i)
					}
					switch {
					case t.vbd()&0x100 != 0:
					case t.vbd()&0x200 != 0:
						s = append(s, r.src[r.positions[i]:r.positions[i]+t.length()]...)
					default:
						return nil, fmt.Errorf("token %d: string conversion 0x%X", i, t.vbd())
					}
					if !t.continued() {
						break
					}
					i++
					if i >= len(toks) {
						return nil, errors.New("an unfinished string chain")
					}
				}
				if isText {
					out = append(out, fmt.Sprintf("text:%x", s))
				} else {
					out = append(out, fmt.Sprintf("bytes:%x", s))
				}
			case vbcLiteral:
				name := map[uint64]string{1: "undefined", 2: "null", 4: "false", 8: "true"}[vbd]
				if name == "" {
					return nil, fmt.Errorf("token %d: literal 0x%X", i, vbd)
				}
				out = append(out, name)
			case vbcNumber:
				switch len(text) {
				case 3:
					out = append(out, fmt.Sprintf("f16:%04X", binary.BigEndian.Uint16(text[1:])))
				case 5:
					out = append(out, fmt.Sprintf("f32:%08X", binary.BigEndian.Uint32(text[1:])))
				case 9:
					out = append(out, fmt.Sprintf("f64:%016X", binary.BigEndian.Uint64(text[1:])))
				default:
					return nil, fmt.Errorf("token %d: a float of length %d", i, len(text))
				}
			case vbcIntUnsig:
				v := new(big.Int).SetUint64(vbd)
				if err := extend(v); err != nil {
					return nil, err
				}
				out = append(out, "i:"+v.String())
			case vbcIntSign:
				d := int64(vbd)
				if d >= 1<<20 {
					d -= 1 << 21
				}
				v := big.NewInt(d)
				if err := extend(v); err != nil {
					return nil, err
				}
				out = append(out, "i:"+v.String())
			default:
				return nil, fmt.Errorf("token %d: category %d", i, t.vbc())
			}
		}
	}
	return out, nil
}
