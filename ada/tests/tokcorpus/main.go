// Part of wuffada (wuffs-ada: Wuffs to Ada).
// SPDX-License-Identifier: Apache-2.0 OR MIT

// tokcorpus builds the test corpus for the generated token decoders, json
// and cbor.
//
// Usage: tokcorpus -data wuffs/test/data -out DIR > manifest
//
// It writes generated inputs to DIR and prints a manifest, one line per test
// case:
//
//	FORMAT QUIRKS INPUT CHECK
//
// FORMAT is json or cbor. QUIRKS is a hexadecimal mask of the json quirks to
// enable: bit I is the quirk 0x4599_0800 | I (std/json's decode_quirks.wuffs;
// I = 8 is reserved there, and setting it changes nothing). CHECK says what
// ada/tests/tokcheck compares the decoder's tokens with, besides upstream's
// C (which every case is compared with, by trace): "-" for nothing more,
// "jsonref" for Go's encoding/json (quirks must be 0), "cborref" for
// tokcheck's own CBOR walker, or "golden=PATH" for one of upstream's golden
// token files.
//
// The inputs: every JSON and CBOR file in Wuffs' test data; JSON and CBOR
// written to exercise every token kind, every escape and quirk, the depth
// limits, invalid UTF-8 of every class, long strings and numbers, and so on;
// and truncations and corruptions of those, at many offsets. Everything is
// deterministic (seeded).
package main

import (
	"bytes"
	"encoding/binary"
	"flag"
	"fmt"
	"math"
	"math/rand"
	"os"
	"path/filepath"
	"sort"
	"strings"
)

var (
	dataDir = flag.String("data", "wuffs/test/data", "the directory of Wuffs' test data")
	outDir  = flag.String("out", "", "the directory to write the corpus to")

	nFiles = 0
	rng    = rand.New(rand.NewSource(20261121))
)

// The json quirks, by their offset from QUIRKS_BASE (decode_quirks.wuffs).
const (
	qControl          = 0x00
	qBackslashA       = 0x01
	qBackslashCapU    = 0x02
	qBackslashE       = 0x03
	qBackslashNewLine = 0x04
	qBackslashQMark   = 0x05
	qBackslashSQuote  = 0x06
	qBackslashV       = 0x07
	qReserved8        = 0x08
	qBackslashX       = 0x09
	qBackslashZero    = 0x0A
	qCommentBlock     = 0x0B
	qCommentLine      = 0x0C
	qExtraComma       = 0x0D
	qInfNan           = 0x0E
	qLeadingRS        = 0x0F
	qLeadingBOM       = 0x10
	qTrailingFiller   = 0x11
	qExpectTrailingNL = 0x12
	qJSONPointer      = 0x13
	qReplaceInvalid   = 0x14
	numQuirks         = 0x15

	allQuirks = 1<<numQuirks - 1
	// QUIRK_EXPECT_TRAILING_NEW_LINE_OR_EOF "cannot be combined" with the
	// comment and trailing filler quirks: this is every quirk but it.
	allButExpectNL = allQuirks &^ (1 << qExpectTrailingNL)
)

func main() {
	flag.Parse()
	if *outDir == "" {
		fatal(fmt.Errorf("missing -out"))
	}
	fixtures()
	jsonCases()
	cborCases()
}

func fatal(err error) {
	fmt.Fprintln(os.Stderr, "tokcorpus:", err)
	os.Exit(1)
}

// emit writes data to a new file and prints its manifest line.
func emit(format string, quirks uint32, data []byte, check string) {
	nFiles++
	name := filepath.Join(*outDir, fmt.Sprintf("%s%05d.%s", format[:1], nFiles, format))
	if err := os.WriteFile(name, data, 0o644); err != nil {
		fatal(err)
	}
	fmt.Printf("%s %08X %s %s\n", format, quirks, name, check)
}

// ---- Upstream's test data.

func fixtures() {
	golden := map[string]string{
		"australian-abc-local-stations.json": "australian-abc-local-stations.tokens",
		"json-things.unformatted.json":       "json-things.unformatted.tokens",
		"cbor-rfc-7049-examples.cbor":        "cbor-rfc-7049-examples.tokens",
	}
	var names []string
	for _, pattern := range []string{"*.json", "*.cbor"} {
		m, err := filepath.Glob(filepath.Join(*dataDir, pattern))
		if err != nil {
			fatal(err)
		}
		names = append(names, m...)
	}
	sort.Strings(names)
	if len(names) < 10 {
		fatal(fmt.Errorf("only %d JSON and CBOR files in %s", len(names), *dataDir))
	}
	for _, name := range names {
		base := filepath.Base(name)
		if strings.HasSuffix(name, ".cbor") {
			check := "cborref"
			if g := golden[base]; g != "" {
				check = "golden=" + filepath.Join(*dataDir, g)
			}
			fmt.Printf("cbor %08X %s %s\n", 0, name, check)
			data, err := os.ReadFile(name)
			if err != nil {
				fatal(err)
			}
			truncations("cbor", 0, data, 37)
			corruptions("cbor", 0, data, 29, []byte{0x00, 0x18, 0x1F, 0x5F, 0x7F, 0x9F, 0xBF, 0xFF})
			continue
		}
		check := "jsonref"
		if g := golden[base]; g != "" {
			check = "golden=" + filepath.Join(*dataDir, g)
		}
		fmt.Printf("json %08X %s %s\n", 0, name, check)
		fmt.Printf("json %08X %s %s\n", allButExpectNL, name, "-")
		fmt.Printf("json %08X %s %s\n", allQuirks, name, "-")
		fmt.Printf("json %08X %s %s\n", uint32(1<<qExpectTrailingNL), name, "-")
	}
	// upstream's json-quirks test (test/c/std/json.c): these quirks.
	q := uint32(0)
	for _, i := range []int{qBackslashA, qBackslashCapU, qBackslashE, qBackslashQMark, qBackslashSQuote,
		qBackslashV, qBackslashX, qBackslashZero, qCommentBlock, qCommentLine, qExtraComma, qInfNan,
		qLeadingRS, qLeadingBOM, qTrailingFiller, qReplaceInvalid} {
		q |= 1 << i
	}
	fmt.Printf("json %08X %s golden=%s\n", q, filepath.Join(*dataDir, "json-quirks.json"),
		filepath.Join(*dataDir, "json-quirks.tokens"))
}

// truncations emits data cut short at every offset (for short data) or at
// every step'th offset and the last few (for longer data).
func truncations(format string, quirks uint32, data []byte, step int) {
	check := refCheck(format, quirks)
	for n := 0; n < len(data); n++ {
		if len(data) <= 300 || n%step == 0 || n >= len(data)-4 || n < 8 {
			emit(format, quirks, data[:n], check)
		}
	}
}

// corruptions emits data with one byte replaced, at every step'th offset
// (from a seeded start), by each of the given bytes.
func corruptions(format string, quirks uint32, data []byte, step int, with []byte) {
	if len(data) == 0 {
		return
	}
	check := refCheck(format, quirks)
	for i := rng.Intn(step); i < len(data); i += step {
		for _, b := range with {
			if data[i] == b {
				continue
			}
			c := append([]byte(nil), data...)
			c[i] = b
			emit(format, quirks, c, check)
		}
	}
}

func refCheck(format string, quirks uint32) string {
	switch {
	case format == "cbor":
		return "cborref"
	case quirks == 0:
		return "jsonref"
	}
	return "-"
}

// ---- JSON.

// jsonStrict are inputs about which the quirks have nothing to say: they
// are run with no quirks (and compared with Go's encoding/json) and with
// all of them.
var jsonStrict = []string{
	``, ` `, "\n", `null`, `true`, `false`, `nul`, `nulll`, `True`, `tru`, `fals`, `n`,
	`0`, `-0`, `1`, `-1`, `9`, `10`, `123456789`, `1.5`, `-1.5`, `0.0`, `1e5`, `1E5`, `1e+5`,
	`1e-5`, `1E-05`, `-1.5e-10`, `0e0`, `0.000001`, `123.456e789`,
	`01`, `00`, `-`, `+1`, `.5`, `1.`, `1e`, `1e+`, `1E-`, `--1`, `0x10`, `1.5.5`, `1e5e5`,
	`-a`, `1a`, `0-`, `- 1`, `1 .5`, `007`, `1 2`, `[] []`, `{} x`, `"a" "b"`,
	`""`, `"a"`, `"abc"`, `"\""`, `"\\"`, `"\/"`, `"\b"`, `"\f"`, `"\n"`, `"\r"`, `"\t"`,
	`"\u0000"`, `"\u001F"`, `"\u001f"`, `"\u007F"`, `"\u0080"`, `"߿"`, `"ࠀ"`,
	`"퟿"`, `""`, `"�"`, `"￿"`, `"ꯍ"`, `"ꯍ"`,
	`"😀"`, `"𐀀"`, `"􏿿"`, `"😀"`,
	`"\uD800"`, `"\uDC00"`, `"\uDFFF"`, `"\uD800x"`, `"\uD800A"`, `"\uD800\uD800"`,
	`"\uDC00\uD800"`, `"\uD800𐀀"`, `"\uD800\"`, `"\uD800\u"`, `"\uD800\uDC0"`,
	`"\u"`, `"\u1"`, `"\u12"`, `"\u123"`, `"\u123g"`, `"\uG000"`, `"\U00000041"`,
	`"\a"`, `"\e"`, `"\v"`, `"\?"`, `"\'"`, `"\0"`, `"\x41"`, `"\ "`, `"\`, `"abc`, `"`,
	"\"a\x01b\"", "\"\x00\"", "\"\x1f\"", "\"\t\"", "\"\x7f\"", "\"\n\"",
	`[]`, `[1]`, `[1,2]`, `[1,2,3]`, `[[]]`, `[[1],[2]]`, `[1,]`, `[,1]`, `[,]`, `[1 2]`,
	`[`, `]`, `[1`, `[1,`, `[1}`, `{]`, `[{]`, `[null,true,false]`,
	`{}`, `{"a":1}`, `{"a":1,"b":2}`, `{"a":{"b":{"c":[1,2,{"d":null}]}}}`, `{"a"}`,
	`{"a":}`, `{"a" 1}`, `{1:2}`, `{"a":1,}`, `{,}`, `{"a":1 "b":2}`, `{"a":1,"a":2}`,
	`{`, `}`, `{"`, `{"a`, `{"a"`, `{"a":`, `{"a":1`, `{"a":1,`, `{"":""}`,
	" [ 1 , 2 ] ", "\t[\n1\r,\r\n2\t]\n", "\r\n\r\n{}\r\n", "[1\v]", "[1\f]", " [1]",
	"[\"\xc3\xa9\"]", `["é", "日本", "😀"]`, "{\"\xe2\x82\xac\":\"\xf0\x9f\x98\x80\"}",
	`[1.0, -2.5e3, 0.25, 1e-300, 1e300, 12345678901234567890123]`,
	`[-0.0, 0.5, 100, -100, 1E10]`, `{"key with spaces":"value with \"quotes\""}`,
	"\xef\xbb\xbf[1]", "\x1e[1]", "/* c */[1]", "[1]//c", "[1]\n", "1\n2", "[inf]", "nan",
}

// invalidUTF8 are byte sequences that are not valid UTF-8 (RFC 3629), of
// every class: lone continuation bytes, overlong forms, surrogates, values
// above U+10FFFF, bytes that never appear, and truncated sequences.
var invalidUTF8 = [][]byte{
	{0x80}, {0xBF}, {0x80, 0x80}, {0xC0, 0x80}, {0xC1, 0xBF}, {0xC0, 0xAF},
	{0xE0, 0x80, 0x80}, {0xE0, 0x9F, 0xBF}, {0xF0, 0x80, 0x80, 0x80}, {0xF0, 0x8F, 0xBF, 0xBF},
	{0xED, 0xA0, 0x80}, {0xED, 0xBF, 0xBF}, {0xED, 0xAF, 0xBF, 0xED, 0xBF, 0xBF},
	{0xF4, 0x90, 0x80, 0x80}, {0xF5, 0x80, 0x80, 0x80}, {0xF7, 0xBF, 0xBF, 0xBF},
	{0xF8, 0x88, 0x80, 0x80, 0x80}, {0xFC, 0x84, 0x80, 0x80, 0x80, 0x80}, {0xFE}, {0xFF},
	{0xC2}, {0xDF}, {0xE0, 0xA0}, {0xE1}, {0xEF, 0xBF}, {0xF0, 0x90, 0x80}, {0xF4, 0x8F},
	{0xC2, 0x41}, {0xE0, 0xA0, 0x41}, {0xF0, 0x90, 0x80, 0x41}, {0xE0, 0x41, 0x80},
}

// validUTF8 are valid sequences at the edges of each length.
var validUTF8 = [][]byte{
	{0x7F}, {0xC2, 0x80}, {0xDF, 0xBF}, {0xE0, 0xA0, 0x80}, {0xED, 0x9F, 0xBF},
	{0xEE, 0x80, 0x80}, {0xEF, 0xBF, 0xBF}, {0xEF, 0xBF, 0xBD}, {0xF0, 0x90, 0x80, 0x80},
	{0xF4, 0x8F, 0xBF, 0xBF}, {0xF3, 0xBF, 0xBF, 0xBF},
}

// quirkCases are inputs for one quirk each.
var quirkCases = map[int][]string{
	qControl:    {"\"a\x01b\"", "\"\x00\"", "\"\x1f\"", "\"\t\"", "\"\x7f\"", "[\"\x0b\"]", "\"\n\""},
	qBackslashA: {`"\a"`, `"x\ay"`, `"\A"`},
	qBackslashCapU: {`"\U0001F600"`, `"\U0010FFFF"`, `"\U00110000"`, `"\U0000D800"`, `"\U00000041"`,
		`"\U0001F60"`, `"\U0001F60G"`, `"\UFFFFFFFF"`, `"\U00000000"`},
	qBackslashE:       {`"\e"`, `"\E"`},
	qBackslashNewLine: {"\"\\\n\"", "\"a\\\nb\"", "\"\\\r\n\""},
	qBackslashQMark:   {`"\?"`, `"??\?"`},
	qBackslashSQuote:  {`"\'"`, `"it\'s"`},
	qBackslashV:       {`"\v"`, `"\V"`},
	qReserved8:        {`"\x41"`},
	qBackslashX: {`"\x41"`, `"abc\xeFz"`, `"\x00"`, `"\xff"`, `"\x"`, `"\x9"`, `"\x9$"`, `"\X99"`,
		`"\x80\x80"`},
	qBackslashZero: {`"\0"`, `"a\0b"`, `"\00"`},
	qCommentBlock: {"/* c */[1]", "[1 /* c */,2]", "/**/1", "/* unterminated", "/*/ */0", "/* \n */0",
		"[1]/* trailing */", "/ x", "/*", "/* * / */1", "/*\xff*/1"},
	qCommentLine: {"// line\n[1]", "//\n1", "//\r\n1", "[1, // c\n 2]", "1 // trailing", "//", "// x",
		"/\n1", "//\xff\n1"},
	qExtraComma: {`[1,]`, `{"a":1,}`, `[,]`, `[1,,]`, `[[],]`, `{,}`, `[1,] `, `{"a":[1,],}`},
	qInfNan: {`inf`, `-inf`, `+inf`, `Infinity`, `-Infinity`, `+Infinity`, `nan`, `-nan`, `+nan`, `NaN`,
		`INF`, `Inf`, `infinity`, `infx`, `[nan]`, `-Inf`, `NAN`, `-NaN`, `infinit`, `[inf,-inf,nan]`,
		`in`, `-i`, `+`, `+1`, `infinityx`},
	qLeadingRS:  {"\x1e[1]", "\x1e\x1e[1]", "\x1e 1", " \x1e1", "\x1e"},
	qLeadingBOM: {"\xef\xbb\xbf[1]", "\xef\xbb[1]", " \xef\xbb\xbf1", "\xef\xbb\xbf\xef\xbb\xbf1", "\xef\xbb\xbf"},
	qTrailingFiller: {"1 \n\n x", "[1]/*c*/ // x\n z", "1 garbage", "[1]   ", "{} \t\r\n", "1\n\n",
		"[1]/* unterminated"},
	qExpectTrailingNL: {"1\n", "1 \n", "1 x", "1", "1\nx", "1\r\n", "[1] \t\n\n", "[1]\n[2]", "1 \t",
		"\"a\"\n\n", "007", "007\n"},
	qJSONPointer:    {`"~n~r~t"`, `"~0~1"`, `"/a~1b"`},
	qReplaceInvalid: {`"\uD800"`, `"\uDC00"`, `"\uD800A"`, `"\uD800𐀀"`, "\"\xff\"", "\"\xc0\x80\""},
}

func jsonCases() {
	// The strict inputs: no quirks, all quirks, and all but one.
	for _, s := range jsonStrict {
		emit("json", 0, []byte(s), "jsonref")
		emit("json", allButExpectNL, []byte(s), "-")
		emit("json", allQuirks, []byte(s), "-")
	}

	// Each quirk's inputs: with no quirks, that quirk alone, that quirk and
	// replace-invalid-unicode, all of them, and all but one.
	quirks := []int{}
	for q := range quirkCases {
		quirks = append(quirks, q)
	}
	sort.Ints(quirks)
	for _, q := range quirks {
		for _, s := range quirkCases[q] {
			for _, mask := range []uint32{0, 1 << q, 1<<q | 1<<qReplaceInvalid, allQuirks, allButExpectNL} {
				emit("json", mask, []byte(s), refCheck("json", mask))
			}
		}
	}

	// Every quirk alone, on a document that has a little of everything.
	everything := []byte("\xef\xbb\xbf\x1e /* block */ // line\n [1, -2.5e3, inf, -nan, \"\\a\\e\\v\\?\\'\\0\\x41" +
		"\\U0001F600\\uD800\\\n\x01\xff\", {\"k\": [true, false, null,],}, ] \n /* x */ \n")
	for q := 0; q < numQuirks; q++ {
		emit("json", 1<<q, everything, "-")
		emit("json", allQuirks&^(1<<q), everything, "-")
	}
	emit("json", 0, everything, "jsonref")
	emit("json", allQuirks, everything, "-")
	emit("json", allButExpectNL, everything, "-")
	// Seeded random combinations of quirks, on everything and on a sample
	// of the quirk inputs.
	for i := 0; i < 64; i++ {
		mask := uint32(rng.Int63()) & allQuirks
		emit("json", mask, everything, "-")
		q := quirks[rng.Intn(len(quirks))]
		s := quirkCases[q][rng.Intn(len(quirkCases[q]))]
		emit("json", mask, []byte(s), "-")
	}

	// UTF-8, inside a string and outside of one, with and without the
	// replace-invalid-unicode quirk.
	for _, seq := range append(append([][]byte(nil), invalidUTF8...), validUTF8...) {
		for _, form := range []string{"\"%s\"", "[\"a%sb\"]", "\"%s%s\"", "%s", "[1]%s", "{\"%s\":1}"} {
			parts := []interface{}{}
			for i := 0; i < strings.Count(form, "%s"); i++ {
				parts = append(parts, string(seq))
			}
			s := []byte(fmt.Sprintf(form, parts...))
			emit("json", 0, s, "jsonref")
			emit("json", 1<<qReplaceInvalid, s, "-")
			emit("json", allButExpectNL, s, "-")
		}
	}

	// Depth: the limit is 1024 (DECODER_DEPTH_MAX_INCL).
	for _, d := range []int{1, 2, 31, 32, 33, 100, 1023, 1024, 1025, 1100} {
		emit("json", 0, []byte(strings.Repeat("[", d)+strings.Repeat("]", d)), "jsonref")
		emit("json", 0, []byte(strings.Repeat(`{"a":`, d)+"1"+strings.Repeat("}", d)), "jsonref")
		emit("json", 0, []byte(strings.Repeat(`[{"a":`, d/2)+"1"+strings.Repeat("}]", d/2)), "jsonref")
		emit("json", 0, []byte(strings.Repeat("[", d)), "jsonref")
		emit("json", 0, []byte(strings.Repeat("[", d)+strings.Repeat("]", d-1)+"}"), "jsonref")
		emit("json", allButExpectNL, []byte(strings.Repeat("[1,", d)+strings.Repeat("],", d)), "-")
	}

	// Long strings and numbers, across the 0xFFFF maximum token length and
	// across source chunk boundaries.
	emit("json", 0, []byte(`"`+strings.Repeat("a", 70000)+`"`), "jsonref")
	emit("json", 0, []byte(`"`+strings.Repeat("a", 65535)+`"`), "jsonref")
	emit("json", 0, []byte(`"`+strings.Repeat("a", 65534)+"\xc3\xa9"+`"`), "jsonref")
	emit("json", 0, []byte(`"`+strings.Repeat("日", 30000)+`"`), "jsonref")
	emit("json", 0, []byte(`"`+strings.Repeat("😀", 20000)+`"`), "jsonref")
	emit("json", 0, []byte(`"`+strings.Repeat(`ab\né😀`, 3000)+`"`), "jsonref")
	emit("json", 0, []byte(`"`+strings.Repeat("a", 5000)+"\xff"+`"`), "jsonref")
	emit("json", 1<<qReplaceInvalid, []byte(`"`+strings.Repeat("a\xffb\xed\xa0\x80", 3000)+`"`), "-")
	for _, n := range []int{1, 2, 98, 99, 100, 101, 200} {
		emit("json", 0, []byte(strings.Repeat("7", n)), "jsonref")
		emit("json", 0, []byte("-"+strings.Repeat("7", n)), "jsonref")
		emit("json", 0, []byte("1."+strings.Repeat("5", n)), "jsonref")
		emit("json", 0, []byte("[1e"+strings.Repeat("9", n)+"]"), "jsonref")
	}
	var b bytes.Buffer
	b.WriteString("[")
	for i := 0; i < 20000; i++ {
		if i > 0 {
			b.WriteString(",")
		}
		switch i % 5 {
		case 0:
			fmt.Fprintf(&b, "%d", rng.Int63()>>uint(rng.Intn(60)))
		case 1:
			fmt.Fprintf(&b, "%g", rng.NormFloat64()*math.Pow(10, float64(rng.Intn(40)-20)))
		case 2:
			fmt.Fprintf(&b, "%q", strings.Repeat("x", rng.Intn(30)))
		case 3:
			b.WriteString(`{"k":[true,null]}`)
		case 4:
			fmt.Fprintf(&b, "-%d.%de-%d", rng.Intn(1000), rng.Intn(1000), rng.Intn(30))
		}
	}
	b.WriteString("]")
	emit("json", 0, b.Bytes(), "jsonref")

	// Truncations and corruptions of documents.
	doc := []byte(`{"a": [1, -2.5e-3, true, false, null, "s\"t\\ué😀"], "b": {"c": {}, "d": []},` +
		` "e": "` + "\xc3\xa9\xe6\x97\xa5\xf0\x9f\x98\x80" + `", "f": 1234567890123456789}`)
	truncations("json", 0, doc, 1)
	truncations("json", allButExpectNL, everything, 1)
	corruptions("json", 0, doc, 3, []byte{'"', '\\', 0x80, 0xFF, '}', ']', ',', ':', '0', ' ', 0x00, '/'})
	corruptions("json", allButExpectNL, everything, 7, []byte{'"', '\\', 0x80, '*', '/', '\n', 0x00})
	data, err := os.ReadFile(filepath.Join(*dataDir, "json-quirks.json"))
	if err != nil {
		fatal(err)
	}
	truncations("json", allButExpectNL, data, 1)
	corruptions("json", allButExpectNL, data, 5, []byte{'"', '\\', 0x80, '*', '/'})
	data, err = os.ReadFile(filepath.Join(*dataDir, "github-tags.json"))
	if err != nil {
		fatal(err)
	}
	truncations("json", 0, data, 13)
	corruptions("json", 0, data, 41, []byte{'"', '\\', 0xC3, '}'})
}

// ---- CBOR.

// head encodes a CBOR head with the given major type and argument, with
// additional information ai (which says how the argument is encoded: 0 ..=
// 23 inline, 24 ..= 27 in 1, 2, 4 or 8 bytes).
func head(major byte, ai byte, arg uint64) []byte {
	out := []byte{major<<5 | ai}
	switch ai {
	case 24:
		out = append(out, byte(arg))
	case 25:
		out = binary.BigEndian.AppendUint16(out, uint16(arg))
	case 26:
		out = binary.BigEndian.AppendUint32(out, uint32(arg))
	case 27:
		out = binary.BigEndian.AppendUint64(out, arg)
	}
	return out
}

// minHead encodes a head in the shortest form.
func minHead(major byte, arg uint64) []byte {
	switch {
	case arg < 24:
		return head(major, byte(arg), 0)
	case arg <= 0xFF:
		return head(major, 24, arg)
	case arg <= 0xFFFF:
		return head(major, 25, arg)
	case arg <= 0xFFFF_FFFF:
		return head(major, 26, arg)
	}
	return head(major, 27, arg)
}

func cat(parts ...[]byte) []byte {
	return bytes.Join(parts, nil)
}

func cborCases() {
	emitC := func(data []byte) { emit("cbor", 0, data, "cborref") }

	// Every major type with every additional information value, with an
	// argument of 0, 5 and the largest value for its width, followed by
	// what it says comes next (when that is short).
	for major := byte(0); major < 8; major++ {
		for ai := byte(0); ai < 32; ai++ {
			args := []uint64{0, 5}
			switch ai {
			case 24:
				args = append(args, 0xFF, 0x17, 0x20)
			case 25:
				args = append(args, 0xFFFF, 0x3C00, 0x7C00, 0xFC00, 0x7E00, 0x8000)
			case 26:
				args = append(args, 0xFFFF_FFFF, 0x3F80_0000, 0x7F80_0000, 0x7FC0_0000)
			case 27:
				args = append(args, 0xFFFF_FFFF_FFFF_FFFF, 0x8000_0000_0000_0000, 0x7FFF_FFFF_FFFF_FFFF,
					0x3FF0_0000_0000_0000, 0x7FF8_0000_0000_0000, 0x4_0000, 0x3_FFFF)
			}
			if ai < 24 {
				args = []uint64{0}
			}
			for _, arg := range args {
				h := head(major, ai, arg)
				n := uint64(ai)
				if ai >= 24 && ai <= 27 {
					n = arg
				}
				var rest []byte
				switch major {
				case 2, 3:
					if n <= 64 {
						rest = bytes.Repeat([]byte{'a'}, int(n))
					}
				case 4:
					if n <= 64 {
						rest = bytes.Repeat([]byte{0x01}, int(n))
					}
				case 5:
					if n <= 64 {
						rest = bytes.Repeat([]byte{0x01, 0x02}, int(n))
					}
				case 6:
					rest = []byte{0x01}
				}
				if ai == 31 {
					switch major {
					case 2:
						rest = []byte{0x41, 'x', 0xFF}
					case 3:
						rest = []byte{0x61, 'x', 0xFF}
					case 4:
						rest = []byte{0x01, 0xFF}
					case 5:
						rest = []byte{0x01, 0x02, 0xFF}
					}
				}
				emitC(cat(h, rest))
				if len(rest) > 0 {
					emitC(h)
				}
			}
		}
	}

	// Integers at the edges of each width, positive and negative.
	for _, v := range []uint64{0, 1, 23, 24, 0xFF, 0x100, 0xFFFF, 0x1_0000, 0xFFFF_FFFF, 0x1_0000_0000,
		0x3FFF_FFFF_FFFF, 0x4000_0000_0000, 0x7FFF_FFFF_FFFF_FFFF, 0x8000_0000_0000_0000,
		0xFFFF_FFFF_FFFF_FFFF} {
		emitC(minHead(0, v))
		emitC(minHead(1, v))
		emitC(head(0, 27, v))
		emitC(head(1, 27, v))
	}

	// Floats of each width.
	for _, h := range []uint16{0, 0x8000, 0x3C00, 0x7BFF, 0x0001, 0x7C00, 0xFC00, 0x7E00, 0x7C01} {
		emitC(cat([]byte{0xF9}, binary.BigEndian.AppendUint16(nil, h)))
	}
	for _, f := range []float32{0, -0, 1.5, float32(math.Inf(1)), float32(math.Inf(-1)), float32(math.NaN()),
		math.MaxFloat32, math.SmallestNonzeroFloat32} {
		emitC(cat([]byte{0xFA}, binary.BigEndian.AppendUint32(nil, math.Float32bits(f))))
	}
	for _, f := range []float64{0, math.Copysign(0, -1), 1.1, math.Inf(1), math.Inf(-1), math.NaN(),
		math.MaxFloat64, math.SmallestNonzeroFloat64, -4.1} {
		emitC(cat([]byte{0xFB}, binary.BigEndian.AppendUint64(nil, math.Float64bits(f))))
	}

	// Simple values, one byte and two bytes (two-byte ones below 32 are
	// not well-formed).
	for v := 0; v < 256; v++ {
		if v < 32 {
			emitC([]byte{0xE0 | byte(v)})
		}
		emitC([]byte{0xF8, byte(v)})
	}

	// Strings.
	for _, s := range [][]byte{{}, []byte("a"), []byte("hello"), []byte("\x00\xff"), []byte("é日😀")} {
		emitC(cat(minHead(2, uint64(len(s))), s))
		emitC(cat(minHead(3, uint64(len(s))), s))
		emitC(cat(head(3, 27, uint64(len(s))), s))
	}
	for _, seq := range append(append([][]byte(nil), invalidUTF8...), validUTF8...) {
		emitC(cat(minHead(3, uint64(len(seq))), seq))
		emitC(cat(minHead(3, uint64(len(seq)+2)), []byte("a"), seq, []byte("b")))
		emitC(cat(minHead(2, uint64(len(seq))), seq))
		emitC(cat([]byte{0x7F}, minHead(3, uint64(len(seq))), seq, []byte{0xFF}))
		// A string that ends in the middle of a code point that the next
		// item completes.
		if len(seq) >= 2 {
			emitC(cat([]byte{0x82}, minHead(3, 1), seq[:1], minHead(3, uint64(len(seq)-1)), seq[1:]))
		}
	}
	for _, n := range []int{0xFFFE, 0xFFFF, 0x10000, 70000} {
		emitC(cat(minHead(2, uint64(n)), bytes.Repeat([]byte{0xAB}, n)))
		emitC(cat(minHead(3, uint64(n)), bytes.Repeat([]byte{'z'}, n)))
	}
	emitC(cat(minHead(3, 3*30000), bytes.Repeat([]byte("日"), 30000)))
	emitC(cat(minHead(3, 4*20000), bytes.Repeat([]byte("😀"), 20000)))
	emitC(cat(minHead(3, 0xFFFF+3), bytes.Repeat([]byte{'z'}, 0xFFFF-1), []byte("😀")))
	// Lengths that the input cannot have.
	emitC(head(2, 27, 0xFFFF_FFFF_FFFF_FFFF))
	emitC(cat(head(3, 27, 0x8000_0000_0000_0000), []byte("abc")))
	emitC(cat(head(4, 27, 0xFFFF_FFFF_FFFF_FFFF), []byte{0x01, 0x02}))
	emitC(cat(head(5, 26, 0xFFFF_FFFF), []byte{0x01, 0x02}))

	// Indefinite-length strings, arrays and maps.
	for _, s := range [][]byte{
		{0x5F, 0xFF}, {0x7F, 0xFF}, {0x5F, 0x41, 'a', 0x42, 'b', 'c', 0xFF}, {0x7F, 0x61, 'a', 0x60, 0x62, 'b', 'c', 0xFF},
		{0x5F, 0x61, 'a', 0xFF}, {0x7F, 0x41, 'a', 0xFF}, {0x5F, 0x5F, 0xFF, 0xFF}, {0x7F, 0x7F, 0xFF, 0xFF},
		{0x5F, 0x01, 0xFF}, {0x7F, 0x81, 0x01, 0xFF}, {0x5F, 0x41, 'a'}, {0x5F}, {0x7F, 0x61},
		{0x9F, 0xFF}, {0x9F, 0x01, 0x02, 0xFF}, {0x9F, 0x9F, 0xFF, 0x9F, 0x01, 0xFF, 0xFF},
		{0xBF, 0xFF}, {0xBF, 0x01, 0x02, 0xFF}, {0xBF, 0x01, 0xFF}, {0xBF, 0x01, 0x02, 0x03, 0xFF},
		{0x9F, 0x81, 0x9F, 0xFF, 0xFF}, {0x82, 0x9F, 0xFF, 0x01}, {0xA1, 0x9F, 0xFF, 0xBF, 0xFF},
		{0xBF, 0x61, 'k', 0x5F, 0x41, 'v', 0xFF, 0xFF}, {0x9F, 0x01}, {0x9F}, {0xBF, 0x01},
		{0x81, 0x9F, 0x80, 0xA0, 0xFF},
	} {
		emitC(s)
	}

	// Break codes where they are not allowed.
	for _, s := range [][]byte{
		{0xFF}, {0x81, 0xFF}, {0xA1, 0x01, 0xFF}, {0x9F, 0xC1, 0xFF}, {0xC1, 0xFF}, {0x82, 0x01, 0xFF},
		{0x9F, 0x81, 0xFF, 0xFF}, {0xBF, 0x01, 0xC1, 0xFF}, {0x5F, 0xC1, 0x41, 'a', 0xFF},
	} {
		emitC(s)
	}

	// Tags.
	for _, ai := range []byte{0, 23, 24, 25, 26, 27} {
		for _, v := range []uint64{0, 1, 0x3_FFFF, 0x4_0000, 0xFFFF_FFFF, 0xFFFF_FFFF_FFFF_FFFF} {
			emitC(cat(head(6, ai, v), []byte{0x01}))
		}
	}
	emitC(cat(bytes.Repeat([]byte{0xC1}, 100), []byte{0x01}))
	emitC(cat(bytes.Repeat(head(6, 27, 0x123456789ABCDEF), 20), []byte{0x80}))
	emitC([]byte{0xC1})
	emitC([]byte{0x81, 0xC1})
	emitC([]byte{0xD8, 0x20, 0x63, 'u', 'r', 'l'})
	emitC([]byte{0xBF, 0xC1, 0x01, 0xC2, 0x02, 0xFF})

	// Depth: the limit is 1024 (DECODER_DEPTH_MAX_INCL).
	for _, d := range []int{1, 15, 16, 17, 100, 1023, 1024, 1025, 1100} {
		emitC(cat(bytes.Repeat([]byte{0x81}, d), []byte{0x00}))
		emitC(cat(bytes.Repeat([]byte{0x9F}, d), bytes.Repeat([]byte{0xFF}, d)))
		emitC(cat(bytes.Repeat([]byte{0xA1, 0x01}, d), []byte{0x00}))
		emitC(cat(bytes.Repeat([]byte{0xBF, 0x01}, d), []byte{0x00}, bytes.Repeat([]byte{0xFF}, d)))
		emitC(cat(bytes.Repeat([]byte{0x81, 0xC1}, d), []byte{0x80}))
		emitC(bytes.Repeat([]byte{0x81}, d))
	}

	// What upstream std/cbor does not handle as RFC 8949 says (see
	// ada/tests/tokcheck): a zero length that is not inline, for an array
	// or a map, and an empty chunk inside an indefinite-length string.
	for _, s := range [][]byte{
		{0x98, 0x00}, {0x98, 0x00, 0xFF}, {0xB8, 0x00, 0xFF}, {0x99, 0x00, 0x00, 0x01, 0xFF},
		{0x9B, 0, 0, 0, 0, 0, 0, 0, 0, 0x01, 0xFF}, {0x81, 0x98, 0x00, 0xFF},
		{0x7F, 0x60, 0xFF}, {0x5F, 0x40, 0x41, 'a', 0xFF}, {0x82, 0x7F, 0x60, 0xFF, 0x01}, {0x7F, 0x61, 'a', 0x60},
	} {
		emitC(s)
	}

	// Several top-level items: the decoder stops after the first.
	emitC([]byte{0x01, 0x02})
	emitC([]byte{0x80, 0xFF})
	emitC([]byte{0x61, 'a', 0x61})

	// A document with a little of everything, and its truncations and
	// corruptions.
	var doc bytes.Buffer
	doc.Write([]byte{0xBF})
	doc.Write(cat(minHead(3, 1), []byte("a"), minHead(0, 1000000)))
	doc.Write(cat(minHead(3, 1), []byte("b"), minHead(1, 0x1_0000_0000)))
	doc.Write(cat(minHead(3, 1), []byte("c"), []byte{0x9F, 0xF4, 0xF5, 0xF6, 0xF7, 0xF0, 0xF8, 0xFF, 0xFF}))
	doc.Write(cat(minHead(3, 1), []byte("d"), []byte{0x5F, 0x42, 1, 2, 0x41, 3, 0xFF}))
	doc.Write(cat(minHead(3, 1), []byte("e"), []byte{0x7F, 0x62, 0xC3, 0xA9, 0x61, 'x', 0xFF}))
	doc.Write(cat(minHead(3, 1), []byte("f"), []byte{0xF9, 0x3C, 0x00}))
	doc.Write(cat(minHead(3, 1), []byte("g"), []byte{0xFA, 0x47, 0xC3, 0x50, 0x00}))
	doc.Write(cat(minHead(3, 1), []byte("h"), []byte{0xFB, 0x3F, 0xF1, 0x99, 0x99, 0x99, 0x99, 0x99, 0x9A}))
	doc.Write(cat(minHead(3, 1), []byte("i"), head(6, 26, 0x1_0000), []byte{0xA2, 1, 2, 3, 4}))
	doc.Write(cat(minHead(3, 1), []byte("j"), head(1, 27, 0x8000_0000_0000_0001)))
	doc.Write(cat(minHead(3, 1), []byte("k"), minHead(3, 12), []byte("日本語 😀")))
	doc.Write([]byte{0xFF})
	emitC(doc.Bytes())
	truncations("cbor", 0, doc.Bytes(), 1)
	corruptions("cbor", 0, doc.Bytes(), 1, []byte{0x00, 0x18, 0x1C, 0x1F, 0x5F, 0x7F, 0x80, 0x9F, 0xBF, 0xFF})
}
