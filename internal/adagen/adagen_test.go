// Part of wuffada (wuffs-ada: Wuffs to Ada).
// SPDX-License-Identifier: Apache-2.0 OR MIT

package adagen

import (
	"bytes"
	"flag"
	"fmt"
	"math/big"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"testing"

	"github.com/google/wuffs/lang/check"
	"github.com/google/wuffs/lang/parse"

	a "github.com/google/wuffs/lang/ast"
	t "github.com/google/wuffs/lang/token"
)

var update = flag.Bool("update", false, "rewrite the golden files in testdata")

// generate runs the Wuffs front end and then Generate on in-memory sources.
// names and srcs are parallel.
func generate(opts Options, names []string, srcs [][]byte) (*Output, error) {
	tm := &t.Map{}
	files := []*a.File(nil)
	for i, src := range srcs {
		tokens, _, err := t.Tokenize(tm, names[i], src)
		if err != nil {
			return nil, err
		}
		f, err := parse.Parse(tm, names[i], tokens, nil)
		if err != nil {
			return nil, err
		}
		files = append(files, f)
	}
	resolveUse := opts.ResolveUse
	if resolveUse == nil {
		resolveUse = func(usePath string) ([]byte, error) {
			return nil, fmt.Errorf("no such use path %q", usePath)
		}
	}
	if _, err := check.Check(tm, files, resolveUse); err != nil {
		return nil, err
	}
	opts.ResolveUse = resolveUse
	return Generate(tm, files, opts)
}

func generateFiles(opts Options, names ...string) (*Output, error) {
	srcs := [][]byte(nil)
	for _, name := range names {
		src, err := os.ReadFile(name)
		if err != nil {
			return nil, err
		}
		srcs = append(srcs, src)
	}
	return generate(opts, names, srcs)
}

func compareGolden(tt *testing.T, got []byte, goldenFile string) {
	tt.Helper()
	if *update {
		if err := os.WriteFile(goldenFile, got, 0644); err != nil {
			tt.Fatal(err)
		}
		return
	}
	want, err := os.ReadFile(goldenFile)
	if err != nil {
		tt.Fatalf("%v (run \"go test -update\" to create it)", err)
	}
	if !bytes.Equal(got, want) {
		tt.Errorf("output differs from %s (run \"go test -update\", or ./gen.sh, and review the diff)\ngot:\n%s",
			goldenFile, got)
	}
}

func TestGolden(tt *testing.T) {
	out, err := generateFiles(Options{PackageName: "tiny", PackageID: 7}, "testdata/tiny.wuffs")
	if err != nil {
		tt.Fatal(err)
	}
	if out.UnitName != "Wuffs.Std.Tiny" || out.SpecFile != "wuffs-std-tiny.ads" || out.BodyFile != "wuffs-std-tiny.adb" {
		tt.Errorf("unexpected names: %q, %q, %q", out.UnitName, out.SpecFile, out.BodyFile)
	}
	compareGolden(tt, out.Spec, "testdata/tiny.ads.golden")
	compareGolden(tt, out.Body, "testdata/tiny.adb.golden")
}

func TestDeterministic(tt *testing.T) {
	first, err := generateFiles(Options{PackageName: "m1test", PackageID: 65535}, "testdata/m1test.wuffs")
	if err != nil {
		tt.Fatal(err)
	}
	for i := 0; i < 5; i++ {
		again, err := generateFiles(Options{PackageName: "m1test", PackageID: 65535}, "testdata/m1test.wuffs")
		if err != nil {
			tt.Fatal(err)
		}
		if !bytes.Equal(first.Spec, again.Spec) || !bytes.Equal(first.Body, again.Body) {
			tt.Fatalf("output differs between runs")
		}
	}
}

// TestCheckedIn checks that the generated Ada that is checked in (under
// ada/gen and ada/tests) is what the generator produces now.
func TestCheckedIn(tt *testing.T) {
	root := filepath.Join("..", "..")
	testCases := []struct {
		name   string
		outDir string
		files  []string
	}{{
		name:   "adler32",
		outDir: "ada/gen",
		files: []string{
			"wuffs/std/adler32/common_adler32.wuffs",
			"wuffs/std/adler32/common_up_arm_neon.wuffs",
			"wuffs/std/adler32/common_up_x86_sse42.wuffs",
		},
	}, {
		name:   "crc32",
		outDir: "ada/gen",
		files: []string{
			"wuffs/std/crc32/common_crc32.wuffs",
			"wuffs/std/crc32/common_up_arm_crc32.wuffs",
			"wuffs/std/crc32/common_up_x86_sse42.wuffs",
		},
	}, {
		name:   "lzw",
		outDir: "ada/gen",
		files: []string{
			"wuffs/std/lzw/decode_lzw.wuffs",
			"wuffs/std/lzw/decode_quirks.wuffs",
		},
	}, {
		name:   "deflate",
		outDir: "ada/gen",
		files: []string{
			"wuffs/std/deflate/common_consts.wuffs",
			"wuffs/std/deflate/decode_deflate.wuffs",
			"wuffs/std/deflate/decode_huffman_bmi2.wuffs",
			"wuffs/std/deflate/decode_huffman_fast32.wuffs",
			"wuffs/std/deflate/decode_huffman_fast64.wuffs",
			"wuffs/std/deflate/decode_huffman_slow.wuffs",
		},
	}, {
		name:   "zlib",
		outDir: "ada/gen",
		files: []string{
			"wuffs/std/zlib/decode_quirks.wuffs",
			"wuffs/std/zlib/decode_zlib.wuffs",
		},
	}, {
		name:   "gzip",
		outDir: "ada/gen",
		files:  []string{"wuffs/std/gzip/decode_gzip.wuffs"},
	}, {
		name:   "netpbm",
		outDir: "ada/gen",
		files:  []string{"wuffs/std/netpbm/decode_netpbm.wuffs"},
	}, {
		name:   "bmp",
		outDir: "ada/gen",
		files:  []string{"wuffs/std/bmp/decode_bmp.wuffs"},
	}, {
		name:   "gif",
		outDir: "ada/gen",
		files: []string{
			"wuffs/std/gif/common_consts.wuffs",
			"wuffs/std/gif/decode_gif.wuffs",
			"wuffs/std/gif/decode_lzw.wuffs",
			"wuffs/std/gif/decode_quirks.wuffs",
		},
	}, {
		name:   "png",
		outDir: "ada/gen",
		files: []string{
			"wuffs/std/png/common_consts.wuffs",
			"wuffs/std/png/decode_filter_arm_neon.wuffs",
			"wuffs/std/png/decode_filter_fallback.wuffs",
			"wuffs/std/png/decode_filter_x86_sse42.wuffs",
			"wuffs/std/png/decode_png.wuffs",
			"wuffs/std/png/decode_swizzle_default.wuffs",
			"wuffs/std/png/decode_swizzle_tricky.wuffs",
		},
	}, {
		name:   "wbmp",
		outDir: "ada/gen",
		files:  []string{"wuffs/std/wbmp/decode_wbmp.wuffs"},
	}, {
		name:   "nie",
		outDir: "ada/gen",
		files:  []string{"wuffs/std/nie/decode_nie.wuffs"},
	}, {
		name:   "targa",
		outDir: "ada/gen",
		files:  []string{"wuffs/std/targa/decode_targa.wuffs"},
	}, {
		name:   "qoi",
		outDir: "ada/gen",
		files: []string{
			"wuffs/std/qoi/decode_qoi.wuffs",
		},
	}, {
		name:   "xxhash32",
		outDir: "ada/gen",
		files: []string{
			"wuffs/std/xxhash32/common_xxhash32.wuffs",
		},
	}, {
		name:   "xxhash64",
		outDir: "ada/gen",
		files: []string{
			"wuffs/std/xxhash64/common_xxhash64.wuffs",
		},
	}, {
		name:   "crc64",
		outDir: "ada/gen",
		files: []string{
			"wuffs/std/crc64/common_crc64.wuffs",
			"wuffs/std/crc64/common_up_x86_sse42.wuffs",
		},
	}, {
		name:   "bzip2",
		outDir: "ada/gen",
		files: []string{
			"wuffs/std/bzip2/decode_bzip2.wuffs",
			"wuffs/std/bzip2/decode_flush_fast.wuffs",
			"wuffs/std/bzip2/decode_flush_slow.wuffs",
			"wuffs/std/bzip2/decode_huffman_fast.wuffs",
			"wuffs/std/bzip2/decode_huffman_slow.wuffs",
		},
	}, {
		name:   "lzma",
		outDir: "ada/gen",
		files: []string{
			"wuffs/std/lzma/decode_bitstream_fast.wuffs",
			"wuffs/std/lzma/decode_bitstream_slow.wuffs",
			"wuffs/std/lzma/decode_lzma.wuffs",
			"wuffs/std/lzma/decode_quirks.wuffs",
		},
	}, {
		name:   "lzip",
		outDir: "ada/gen",
		files: []string{
			"wuffs/std/lzip/decode_lzip.wuffs",
		},
	}, {
		name:   "thumbhash",
		outDir: "ada/gen",
		files: []string{
			"wuffs/std/thumbhash/decode_quirks.wuffs",
			"wuffs/std/thumbhash/decode_thumbhash.wuffs",
		},
	}, {
		name:   "etc2",
		outDir: "ada/gen",
		files: []string{
			"wuffs/std/etc2/decode_etc2.wuffs",
		},
	}, {
		name:   "handsum",
		outDir: "ada/gen",
		files: []string{
			"wuffs/std/handsum/decode_handsum.wuffs",
		},
	}, {
		name:   "sha256",
		outDir: "ada/gen",
		files: []string{
			"wuffs/std/sha256/common_sha256.wuffs",
		},
	}, {
		name:   "xz",
		outDir: "ada/gen",
		files: []string{
			"wuffs/std/xz/decode_filter.wuffs",
			"wuffs/std/xz/decode_quirks.wuffs",
			"wuffs/std/xz/decode_xz.wuffs",
		},
	}, {
		name:   "jpeg",
		outDir: "ada/gen",
		files: []string{
			"wuffs/std/jpeg/common_consts.wuffs",
			"wuffs/std/jpeg/decode_idct_default.wuffs",
			"wuffs/std/jpeg/decode_idct_x86_avx2.wuffs",
			"wuffs/std/jpeg/decode_jpeg.wuffs",
			"wuffs/std/jpeg/decode_load_smooth.wuffs",
			"wuffs/std/jpeg/decode_mcu_default.wuffs",
			"wuffs/std/jpeg/decode_mcu_progressive_ac_high_bits.wuffs",
			"wuffs/std/jpeg/decode_mcu_progressive_ac_low_bit.wuffs",
			"wuffs/std/jpeg/decode_mcu_progressive_dc_high_bits.wuffs",
			"wuffs/std/jpeg/decode_mcu_progressive_dc_low_bit.wuffs",
			"wuffs/std/jpeg/decode_quirks.wuffs",
		},
	}, {
		name:   "vp8",
		outDir: "ada/gen",
		files: []string{
			"wuffs/std/vp8/common_consts.wuffs",
			"wuffs/std/vp8/decode_bitstream.wuffs",
			"wuffs/std/vp8/decode_coefficients.wuffs",
			"wuffs/std/vp8/decode_filter_default.wuffs",
			"wuffs/std/vp8/decode_header_partition.wuffs",
			"wuffs/std/vp8/decode_idct_default.wuffs",
			"wuffs/std/vp8/decode_macroblocks.wuffs",
			"wuffs/std/vp8/decode_predict_default.wuffs",
			"wuffs/std/vp8/decode_quirks.wuffs",
			"wuffs/std/vp8/decode_reconstruct.wuffs",
			"wuffs/std/vp8/decode_vp8.wuffs",
		},
	}, {
		name:   "webp",
		outDir: "ada/gen",
		files: []string{
			"wuffs/std/webp/decode_alph_default.wuffs",
			"wuffs/std/webp/decode_huffman.wuffs",
			"wuffs/std/webp/decode_pixels_slow.wuffs",
			"wuffs/std/webp/decode_transform.wuffs",
			"wuffs/std/webp/decode_vp8l.wuffs",
			"wuffs/std/webp/decode_webp.wuffs",
		},
	}, {
		name:   "json",
		outDir: "ada/gen",
		files: []string{
			"wuffs/std/json/common_consts.wuffs",
			"wuffs/std/json/decode_json.wuffs",
			"wuffs/std/json/decode_quirks.wuffs",
		},
	}, {
		name:   "cbor",
		outDir: "ada/gen",
		files:  []string{"wuffs/std/cbor/decode_cbor.wuffs"},
	}, {
		name:   "m1test",
		outDir: "ada/tests",
		files:  []string{"internal/adagen/testdata/m1test.wuffs"},
	}, {
		name:   "tokadv",
		outDir: "ada/tests",
		files:  []string{"internal/adagen/testdata/tokadv.wuffs"},
	}, {
		name:   "advtest",
		outDir: "ada/tests",
		files:  []string{"internal/adagen/testdata/advtest.wuffs"},
	}}

	for _, tc := range testCases {
		srcs := [][]byte(nil)
		missing := false
		for _, name := range tc.files {
			src, err := os.ReadFile(filepath.Join(root, filepath.FromSlash(name)))
			if os.IsNotExist(err) {
				missing = true
				break
			} else if err != nil {
				tt.Fatal(err)
			}
			srcs = append(srcs, src)
		}
		if missing {
			tt.Logf("%s: skipped: no Wuffs checkout at ./wuffs", tc.name)
			continue
		}
		id, err := PackageID(tc.name)
		if err != nil || id == 0 {
			tt.Errorf("%s: no package id: %v", tc.name, err)
			continue
		}
		// A std package is generated with and without SIMD (gen.sh): a file
		// that is the same both ways is in ada/gen, the two versions of
		// one that is not are in ada/gen/scalar and ada/gen/simd.
		modes := []string{"scalar"}
		if tc.outDir == "ada/gen" {
			modes = append(modes, "simd")
		}
		for _, mode := range modes {
			out, err := generate(Options{
				PackageName: tc.name,
				PackageID:   id,
				ResolveUse:  UseResolver(filepath.Join(root, "wuffs")),
				SIMD:        mode == "simd",
			}, tc.files, srcs)
			if err != nil {
				tt.Errorf("%s (%s): %v", tc.name, mode, err)
				continue
			}
			type genFile struct {
				file string
				got  []byte
			}
			files := []genFile{{out.SpecFile, out.Spec}, {out.BodyFile, out.Body}}
			for _, c := range out.Children {
				files = append(files, genFile{c.SpecFile, c.Spec}, genFile{c.BodyFile, c.Body})
			}
			for _, x := range files {
				filename := filepath.Join(root, filepath.FromSlash(tc.outDir), x.file)
				if _, err := os.Stat(filename); err != nil && tc.outDir == "ada/gen" {
					filename = filepath.Join(root, filepath.FromSlash(tc.outDir), mode, x.file)
				}
				want, err := os.ReadFile(filename)
				if err != nil {
					tt.Errorf("%s: %v (run ./gen.sh)", tc.name, err)
				} else if !bytes.Equal(x.got, want) {
					tt.Errorf("%s: %s is stale (run ./gen.sh)", tc.name, filename)
				}
			}
		}
	}
}

func TestSkipsCPUArchFunctions(tt *testing.T) {
	root := filepath.Join("..", "..", "wuffs", "std", "adler32")
	names := []string{"common_adler32.wuffs", "common_up_arm_neon.wuffs", "common_up_x86_sse42.wuffs"}
	srcs := [][]byte(nil)
	for _, name := range names {
		src, err := os.ReadFile(filepath.Join(root, name))
		if os.IsNotExist(err) {
			tt.Skip("no Wuffs checkout at ./wuffs")
		} else if err != nil {
			tt.Fatal(err)
		}
		srcs = append(srcs, src)
	}
	out, err := generate(Options{PackageName: "adler32"}, names, srcs)
	if err != nil {
		tt.Fatal(err)
	}
	if got, want := strings.Join(out.Skipped, " "), "hasher.up_arm_neon hasher.up_x86_sse42"; got != want {
		tt.Errorf("skipped: got %q, want %q", got, want)
	}
	// The comments legitimately name the skipped functions, in Wuffs
	// spelling. No Ada entity may be generated for them.
	all := string(out.Spec) + string(out.Body)
	for _, s := range []string{"Up_Arm_Neon", "Up_X86_Sse42", "M128i", "Arm_Neon_U", "Cpu_Arch"} {
		if strings.Contains(all, s) {
			tt.Errorf("output mentions %q", s)
		}
	}
	for _, s := range []string{"procedure Up (Self : in out Hasher; A_X : Wuffs.Bytes) is"} {
		if !strings.Contains(all, s) {
			tt.Errorf("output does not mention %q", s)
		}
	}
}

// TestRejects checks that unsupported constructs are errors, not silently
// wrong output. Each source passes the Wuffs compiler's own checks.
func TestRejects(tt *testing.T) {
	const prelude = "pub struct foo? (\n    x : base.u32,\n    a : array[4] base.u8,\n)\n"
	testCases := []struct {
		what string
		src  string
		opts Options
		want string
	}{{
		what: "io_bind",
		src: prelude + `
			pub func foo.bar?(src: base.io_reader) {
				var r : base.io_reader
				var c : base.u8
				io_bind (io: r, data: this.a[..], history_position: 0) {
					c = r.read_u8?()
				}
				this.x = c as base.u32
			}`,
		want: "not yet supported: a suspension inside an io_bind block",
	}, {
		what: "io_limit with a suspension",
		src: prelude + `
			pub func foo.bar?(src: base.io_reader) {
				var c : base.u8
				io_limit (io: args.src, limit: 4 as base.u64) {
					c = args.src.read_u8?()
				}
				this.x = c as base.u32
			}`,
		want: "not yet supported: a suspension inside an io_limit block",
	}, {
		what: "return out of io_limit",
		src: prelude + `
			pub func foo.bar?(src: base.io_reader) {
				var i : base.u32
				while i < 4 {
					io_limit (io: args.src, limit: 4 as base.u64) {
						if args.src.length() > 2 {
							return ok
						}
					}
					i += 1
				}
			}`,
		want: "not yet supported: a return out of an io_limit block",
	}, {
		what: "break out of io_limit",
		src: prelude + `
			pub func foo.bar?(src: base.io_reader) {
				var i : base.u32
				while i < 4 {
					io_limit (io: args.src, limit: 4 as base.u64) {
						if args.src.length() > 2 {
							break
						}
					}
					i += 1
				}
			}`,
		want: "not yet supported: a break out of an io_limit block",
	}, {
		what: "continue out of io_limit",
		src: prelude + `
			pub func foo.bar?(src: base.io_reader) {
				var i : base.u32
				while i < 4 {
					io_limit (io: args.src, limit: 4 as base.u64) {
						if args.src.length() > 2 {
							continue
						}
					}
					i += 1
				}
			}`,
		want: "not yet supported: a continue out of an io_limit block",
	}, {
		what: "yield out of io_limit",
		src: prelude + `
			pub func foo.bar?(src: base.io_reader) {
				io_limit (io: args.src, limit: 4 as base.u64) {
					yield? base."$short read"
				}
			}`,
		want: "out of an io_limit block",
	}, {
		what: "io_limit of a writer",
		src: prelude + `
			pub func foo.bar?(dst: base.io_writer) {
				io_limit (io: args.dst, limit: 4 as base.u64) {
					if args.dst.length() > 0 {
						args.dst.write_u8_fast!(a: 1)
					}
				}
			}`,
		want: "not yet supported: io_limit of a writer",
	}, {
		what: "io_forget_history",
		src: prelude + `
			pub func foo.bar?(dst: base.io_writer) {
				io_forget_history (io: args.dst) {
					if args.dst.length() > 0 {
						args.dst.write_u8_fast!(a: 1)
						return ok
					}
				}
			}`,
		want: "not yet supported: a return out of an io_forget_history block",
	}, {
		what: "an I/O variable outside of io_bind",
		src: prelude + `
			pub func foo.bar?(src: base.io_reader) {
				var r : base.io_reader
				this.x = (r.length() & 0xFF) as base.u32
			}`,
		want: "is used outside of an io_bind block",
	}, {
		what: "a plane other than plane 0",
		src: prelude + `
			pub func foo.bar!(dst: ptr base.pixel_buffer) {
				var tab : table base.u8
				tab = args.dst.plane(p: 1)
				this.x = (tab.width() & 0xFF) as base.u32
			}`,
		want: "not yet supported",
	}, {
		what: "a pointer to something else",
		src: prelude + `
			pub func foo.bar!(dst: nptr base.pixel_config) {
				this.x = 1
			}`,
		want: "is not yet supported",
	}, {
		what: "assigning to an argument in a coroutine",
		src: prelude + `
			pub func foo.bar?(n: base.u32) {
				args.n = args.n ~mod+ 1
				this.x = args.n
				yield? base."$short read"
			}`,
		want: "not yet supported: assigning to args.n in a coroutine",
	}, {
		what: "a local array of more than 1 KiB",
		src: prelude + `
			pub func foo.bar!() {
				var big : array[1025] base.u8
				big[0] = 1
				this.x = big[0] as base.u32
			}`,
		want: "not yet supported: var big: a local array of more than 1024 bytes",
	}, {
		what: "a slice of something other than bytes",
		src: prelude + `
			pub func foo.bar!(s: roslice base.u16) {
				this.x = (args.s.length() & 0xFF) as base.u32
			}`,
		want: "slice type \"roslice base.u16\" is not yet supported",
	}, {
		what: "non-classy struct",
		src:  "pub struct foo(\n    x : base.u32,\n)\n",
		want: "not yet supported: struct foo: non-classy structs",
	}, {
		what: "private struct",
		src:  "pri struct foo?(\n    x : base.u32,\n)\n",
		want: "not yet supported: struct foo: private structs",
	}, {
		what: "statuses without a package id",
		src:  "pub status \"#bad\"\n" + prelude,
		want: "needs a package id",
	}, {
		what: "Ada reserved word as a function name",
		src: prelude + `
			pub func foo.entry!() {
				this.x = 1
			}`,
		want: "\"Entry\" is not usable as an Ada identifier",
	}, {
		what: "names that differ only by case",
		src:  "pub const FOO : base.u32 = 1\n" + prelude,
		want: "collides with struct foo (Ada is case-insensitive)",
	}, {
		what: "assigning to an iterate variable in its loop",
		src: prelude + `
			pub func foo.bar!(s: roslice base.u8) {
				var p : roslice base.u8
				iterate (p = args.s)(length: 2, advance: 2, unroll: 1) {
					this.x = p[0] as base.u32
					p = p[1 ..]
				}
			}`,
		want: "not yet supported: assigning to the iterate variable \"p\" inside its iterate loop",
	}, {
		what: "public function returning a bool",
		src: prelude + `
			pub func foo.bar() base.bool {
				return this.x == 0
			}`,
		want: "public function returns \"base.bool\", which upstream's wuffs-c also rejects",
	}, {
		what: "a token_reader argument",
		src: prelude + `
			pub func foo.bar?(src: base.token_reader) {
				this.x = 1
			}`,
		want: "not yet supported: type \"base.token_reader\"",
	}, {
		what: "two token_writer arguments",
		src: prelude + `
			pub func foo.bar?(a: base.token_writer, b: base.token_writer) {
				if args.a.length() > 0 {
					args.a.write_simple_token_fast!(value_major: 0, value_minor: 0, continued: 0, length: 0)
				}
				if args.b.length() > 0 {
					args.b.write_simple_token_fast!(value_major: 0, value_minor: 0, continued: 0, length: 0)
				}
			}`,
		want: "not yet supported: a function with two token_writer arguments",
	}, {
		what: "a token_writer and a pixel buffer",
		src: prelude + `
			pub func foo.bar!(a: base.token_writer, dst: ptr base.pixel_buffer) {
				if args.a.length() > 0 {
					args.a.write_simple_token_fast!(value_major: 0, value_minor: 0, continued: 0, length: 0)
				}
			}`,
		want: "not yet supported: a function with a token_writer and a pixel buffer argument",
	}, {
		what: "a constant value_extension below 2**32",
		src: prelude + `
			pub func foo.bar!(a: base.token_writer) {
				if args.a.length() > 0 {
					args.a.write_extended_token_fast!(value_extension: 7, continued: 1, length: 0)
				}
			}`,
		want: "a constant value_extension below 2**32",
	}, {
		what: "io_limit of a token_writer",
		src: prelude + `
			pub func foo.bar!(a: base.token_writer) {
				io_limit (io: args.a, limit: 1 as base.u64) {
					if args.a.length() > 0 {
						args.a.write_simple_token_fast!(value_major: 0, value_minor: 0, continued: 0, length: 0)
					}
				}
			}`,
		want: "io_limit",
	}, {
		what: "local variables that differ only by case",
		src: prelude + `
			pub func foo.bar!() {
				var abc : base.u32
				var aBC : base.u32
				abc = 1
				aBC = 2
				this.x = abc ~mod+ aBC
			}`,
		want: "another local variable has the same Ada name \"V_ABC\"",
	}}

	for _, tc := range testCases {
		out, err := generate(tc.opts.withName("pkg"), []string{"test.wuffs"}, [][]byte{[]byte(tc.src + "\n")})
		if err == nil {
			tt.Errorf("%s: got no error, want one containing %q. Output:\n%s", tc.what, tc.want, out.Body)
		} else if !strings.Contains(err.Error(), tc.want) {
			tt.Errorf("%s: got error %q, want one containing %q", tc.what, err, tc.want)
		}
	}
}

func (o Options) withName(name string) Options {
	o.PackageName = name
	return o
}

func TestMangle(tt *testing.T) {
	testCases := []struct{ in, want string }{
		{"update_u32", "Update_U32"},
		{"ieee_hasher", "Ieee_Hasher"},
		{"IEEE_TABLE", "IEEE_TABLE"},
		{"p__left", "P_U_Left"},
		{"x_", "X_U"},
		{"s1", "S1"},
	}
	for _, tc := range testCases {
		if got := mangle(tc.in); got != tc.want {
			tt.Errorf("mangle(%q): got %q, want %q", tc.in, got, tc.want)
		}
	}

	msgCases := []struct{ in, want string }{
		{"#unsupported option", "Error_Unsupported_Option"},
		{"$short read", "Suspension_Short_Read"},
		{"@end of data", "Note_End_Of_Data"},
		{"#bad argument (length too short)", "Error_Bad_Argument_Length_Too_Short"},
		{"#bad I/O position", "Error_Bad_I_O_Position"},
	}
	for _, tc := range msgCases {
		if got, err := mangleMessage(tc.in); err != nil || got != tc.want {
			tt.Errorf("mangleMessage(%q): got %q, %v, want %q", tc.in, got, err, tc.want)
		}
	}
}

func TestNumLiteral(tt *testing.T) {
	testCases := []struct {
		x    int64
		src  string
		want string
	}{
		{65521, "65521", "65521"},
		{0xFFFF, "0xFFFF", "16#FFFF#"},
		{0xFFFFFFFF, "0xFFFF_FFFF", "16#FFFF_FFFF#"},
		{0x0F, "0x0F", "16#0F#"},
		{0x10000, "", "16#1_0000#"},
		{12, "", "12"},
	}
	for _, tc := range testCases {
		if got := sourceLiteral(big.NewInt(tc.x), tc.src); got != tc.want {
			tt.Errorf("sourceLiteral(%d, %q): got %q, want %q", tc.x, tc.src, got, tc.want)
		}
	}
}

func TestWrap(tt *testing.T) {
	// A long chain breaks before each operator, and nothing exceeds maxCol.
	args := []expr(nil)
	for i := 0; i < 12; i++ {
		args = append(args, call("Some_Table", raw(fmt.Sprint(i)), call("Wuffs.Index", raw("V_Value"))))
	}
	p := &printer{indent: 6}
	p.stmt(sAssign{raw("V_Result"), bin("xor", args...)})
	lines := strings.Split(strings.TrimRight(p.b.String(), "\n"), "\n")
	if len(lines) != 13 {
		tt.Errorf("got %d lines, want 13:\n%s", len(lines), p.b.String())
	}
	for _, s := range lines {
		if len(s) > maxCol {
			tt.Errorf("line too long: %q", s)
		}
	}

	// Parentheses follow Ada's precedence rules.
	e := bin("or else", bin("and then", bin("<", raw("A"), raw("B")), raw("C")), eUn{"not", raw("D")})
	if got, want := flat(e), "(A < B and then C) or else not D"; got != want {
		tt.Errorf("flat: got %q, want %q", got, want)
	}
	e = bin("+", bin("*", raw("A"), raw("B")), bin("-", raw("C"), raw("D")))
	if got, want := flat(e), "A * B + (C - D)"; got != want {
		tt.Errorf("flat: got %q, want %q", got, want)
	}
}

// mustGenerate generates Ada for one in-memory source that must be accepted.
func mustGenerate(tt *testing.T, src string) string {
	tt.Helper()
	out, err := generate(Options{PackageName: "pkg", PackageID: 3}, []string{"test.wuffs"}, [][]byte{[]byte(src + "\n")})
	if err != nil {
		tt.Fatal(err)
	}
	return string(out.Spec) + string(out.Body)
}

func wantContains(tt *testing.T, got string, wants ...string) {
	tt.Helper()
	for _, want := range wants {
		if !strings.Contains(got, want) {
			tt.Errorf("output does not contain %q:\n%s", want, got)
		}
	}
}

func wantNotContains(tt *testing.T, got string, unwanted ...string) {
	tt.Helper()
	for _, s := range unwanted {
		if strings.Contains(got, s) {
			tt.Errorf("output contains %q:\n%s", s, got)
		}
	}
}

// The TestNames tests check that a Wuffs name cannot collide with, or be
// hidden by, a generator-made Ada name. The same sources are in
// testdata/m1test.wuffs, which GNAT compiles and test_m1 runs.

func TestNamesIterateTemporaries(tt *testing.T) {
	got := mustGenerate(tt, `
		pri const I1_END : base.u32 = 7
		pri const I1_POS : base.u32 = 3
		pri const G_I1_POS : base.u32 = 5
		pub struct foo? (
			h : array[8] base.u8,
		)
		pub func foo.bar!(x: roslice base.u8) base.u64 {
			var p : roslice base.u8
			var s : base.u64
			var t : base.u32
			iterate (p = args.x)(length: 1, advance: 1, unroll: 1) {
				t = (p[0] as base.u32) ~mod+ I1_END
				s ~mod+= (t as base.u64) ~mod+ (this.h[I1_POS] as base.u64)
				s ~mod+= this.h[G_I1_POS] as base.u64
			}
			return s
		}`)
	wantContains(tt, got,
		"   I1_END : constant Wuffs.U32 := 7;",
		"   I1_POS : constant Wuffs.U32 := 3;",
		"   W_G_I1_POS : constant Wuffs.U32 := 5;",
		"      G_I1_Pos : Wuffs.Index := 0;",
		"      G_I1_End : Wuffs.Index := 0;",
		"Wuffs.U32 (Wuffs.Runtime.Get (V_P, 0)) + I1_END;",
		"Self.F_H (Wuffs.Index (I1_POS))",
		"Self.F_H (Wuffs.Index (W_G_I1_POS))",
		"while G_I1_Pos < G_I1_End loop")
	wantNotContains(tt, got, " I1_Pos ", " I1_End ", " I1_Src ")
}

func TestNamesSliceTemporary(tt *testing.T) {
	got := mustGenerate(tt, `
		pri const T1 : roarray[4] base.u8 = [10, 20, 30, 40]
		pri const G_T1 : roarray[4] base.u8 = [50, 60, 70, 80]
		pub struct foo? (
			x : base.u32,
		)
		pri func foo.baz(s: roslice base.u8) base.u32 {
			return (args.s.length() & 0xFF) as base.u32
		}
		pub func foo.bar!(x: roslice base.u8) base.u32 {
			var s : base.u32
			s = this.baz(s: args.x.suffix(up_to: 2))
			s ~mod+= T1[s & 3] as base.u32
			s ~mod+= G_T1[s & 3] as base.u32
			return s
		}`)
	wantContains(tt, got,
		"   T1 : constant Wuffs.Bytes (0 .. 3) :=",
		"   W_G_T1 : constant Wuffs.Bytes (0 .. 3) :=",
		"      G_T1 : Wuffs.Runtime.RO_Slice_U8;",
		"Baz (Self, G_T1.Base (G_T1.First .. Wuffs.Runtime.Last (G_T1)))",
		"Wuffs.U32 (T1 (Wuffs.Index (V_S and 3)))",
		"Wuffs.U32 (W_G_T1 (Wuffs.Index (V_S and 3)))")
}

func TestNamesLoopName(tt *testing.T) {
	got := mustGenerate(tt, `
		pub struct foo? (
			x : base.u32,
		)
		pri func foo.loop_1!() base.u32 {
			this.x ~mod+= 1
			return this.x
		}
		pri func foo.g_loop_1!() base.u32 {
			this.x ~mod+= 2
			return this.x
		}
		pub func foo.bar!(n: base.u32) base.u32 {
			var s : base.u32
			while true {
				s ~mod+= this.loop_1!()
				s ~mod+= this.g_loop_1!()
				if s > args.n {
					break
				}
			}
			return s
		}`)
	wantContains(tt, got,
		"   function Loop_1 (Self : in out Foo) return Wuffs.U32;",
		"   function W_G_Loop_1 (Self : in out Foo) return Wuffs.U32;",
		"      G_Loop_1 :\n      loop",
		"V_S := V_S + Loop_1 (Self);",
		"V_S := V_S + W_G_Loop_1 (Self);",
		"exit G_Loop_1;")
}

func TestMangleGlobal(tt *testing.T) {
	testCases := []struct{ in, want string }{
		{"update", "Update"},
		{"IEEE_TABLE", "IEEE_TABLE"},
		{"v", "W_V"},
		{"V_S", "W_V_S"},
		{"a_x", "W_A_X"},
		{"m_n", "W_M_N"},
		{"f_state", "W_F_State"},
		{"g_loop_1", "W_G_Loop_1"},
		{"w_v_s", "W_W_V_S"},
		{"value", "Value"},
		{"global", "Global"},
	}
	for _, tc := range testCases {
		if got := mangleGlobal(tc.in); got != tc.want {
			tt.Errorf("mangleGlobal(%q): got %q, want %q", tc.in, got, tc.want)
		}
	}
}

// TestProvedPragmas checks that the constant-condition warning is turned off
// around lowered assertions only.
func TestProvedPragmas(tt *testing.T) {
	got := mustGenerate(tt, `
		pub struct foo? (
			x : base.u32,
		)
		pub func foo.bar!(n: base.u32) {
			var i : base.u32[..= 10]
			while i < 10,
				inv i <= 10,
			{
				assert i < 10
				i += 1
			}
			this.x = i
		}`)
	wantContains(tt, got, ""+
		"      while V_I < 10 loop\n"+
		"         pragma Warnings (\"C\");\n"+
		"         pragma Loop_Invariant (V_I <= 10);\n"+
		"         pragma Assert (V_I < 10);\n"+
		"         pragma Warnings (\"c\");\n"+
		"         V_I := V_I + 1;\n"+
		"      end loop;\n"+
		"      pragma Warnings (\"C\");\n"+
		"      pragma Assert (V_I <= 10);\n"+
		"      pragma Warnings (\"c\");\n")
	if n := strings.Count(got, "pragma Warnings"); n != 4 {
		tt.Errorf("got %d pragma Warnings, want 4", n)
	}
}

// TestNoFinalReturn checks that a value-returning function may end with a
// "while true" loop or an if-else chain that cannot fall through.
func TestNoFinalReturn(tt *testing.T) {
	got := mustGenerate(tt, `
		pub struct foo? (
			x : base.u32,
		)
		pub func foo.find(v: base.u32) base.u32 {
			var i : base.u32
			while true {
				if (i ~mod* i) >= args.v {
					return i
				}
				i ~mod+= 1
			}
		}`)
	wantContains(tt, got, ""+
		"      loop\n"+
		"         if V_I * V_I >= A_V then\n"+
		"            return V_I;\n"+
		"         end if;\n"+
		"         V_I := V_I + 1;\n"+
		"      end loop;\n"+
		"   end Find;\n")
}

// TestLongSourceName checks that the header stays within the line length
// limit whatever the source files are called.
func TestLongSourceName(tt *testing.T) {
	name := strings.Repeat("a/very/long/directory/name/", 8) + "file.wuffs"
	out, err := generate(Options{PackageName: "pkg"}, []string{name},
		[][]byte{[]byte("pub struct foo? (\n    x : base.u32,\n)\n")})
	if err != nil {
		tt.Fatal(err)
	}
	for _, text := range [][]byte{out.Spec, out.Body} {
		joined := ""
		for _, line := range strings.Split(string(text), "\n") {
			if len(line) > maxCol {
				tt.Errorf("line too long (%d): %q", len(line), line)
			}
			if strings.HasPrefix(line, "--") {
				joined += strings.TrimSpace(strings.TrimPrefix(line, "--"))
			}
		}
		if !strings.Contains(joined, name) {
			tt.Errorf("header does not name the source file:\n%s", text)
		}
	}
}

func TestPackageIDs(tt *testing.T) {
	for name, want := range map[string]uint32{
		"adler32": 1, "crc32": 2, "lzw": 3, "deflate": 4, "zlib": 5, "gzip": 6, "m1test": 65535, "nosuch": 0,
	} {
		if got, err := PackageID(name); err != nil || got != want {
			tt.Errorf("PackageID(%q): got %d, %v, want %d", name, got, err, want)
		}
	}
}

// ---- Coroutines.

// TestCoroutineGolden checks the whole lowering of a coroutine with
// suspension points inside nested loops and inside an if-else chain, and
// with a labelled break and continue that leave flattened loops.
func TestCoroutineGolden(tt *testing.T) {
	out, err := generateFiles(Options{PackageName: "coro", PackageID: 9}, "testdata/coro.wuffs")
	if err != nil {
		tt.Fatal(err)
	}
	compareGolden(tt, out.Spec, "testdata/coro.ads.golden")
	compareGolden(tt, out.Body, "testdata/coro.adb.golden")

	body := string(out.Body)
	wantContains(tt, body,
		// The dispatch.
		"      case G_Susp is\n         when 0 =>\n            null;\n         when 1 =>\n            goto G_Resume_1;\n",
		// A suspension point inside two loops is a top-level label.
		"\n      G_Susp := 1;\n      <<G_Resume_1>>\n",
		// "break.outer" and "continue.outer" out of flattened loops.
		"      goto G_Done_2;\n",
		"      goto G_Continue_1_Outer;\n",
		// A yield inside an if-else chain.
		"      G_Susp := 2;\n      goto G_Suspend;\n      <<G_Resume_2>>\n",
		// The loop invariant of a flattened loop is an assertion.
		"      pragma Assert (V_I < 4);\n",
		// Only the locals that are live across a suspension are saved.
		"      Self.G_S_1_Run_I := V_I;\n      Self.G_S_1_Run_J := V_J;\n      Self.G_S_1_Run_Keep := V_Keep;\n")
	wantNotContains(tt, body, "Loop_Invariant", "Run_C ", "Run_Scratch", "end loop")
}

// findResumablesIn parses and checks src, and returns the names of the
// resumable locals of its function called name, sorted.
func findResumablesIn(tt *testing.T, src string, name string) string {
	tt.Helper()
	tm := &t.Map{}
	tokens, _, err := t.Tokenize(tm, "test.wuffs", []byte(src+"\n"))
	if err != nil {
		tt.Fatal(err)
	}
	f, err := parse.Parse(tm, "test.wuffs", tokens, nil)
	if err != nil {
		tt.Fatal(err)
	}
	if _, err := check.Check(tm, []*a.File{f}, nil); err != nil {
		tt.Fatal(err)
	}
	for _, n := range f.TopLevelDecls() {
		if n.Kind() != a.KFunc || n.AsFunc().FuncName().Str(tm) != name {
			continue
		}
		m, err := findResumables(tm, n.AsFunc())
		if err != nil {
			tt.Fatal(err)
		}
		names := []string(nil)
		for id, resumable := range m {
			if resumable {
				names = append(names, id.Str(tm))
			}
		}
		sort.Strings(names)
		return strings.Join(names, " ")
	}
	tt.Fatalf("no function %q", name)
	return ""
}

// TestLiveness checks the port of upstream's liveness analysis: which
// locals have to survive a suspension.
func TestLiveness(tt *testing.T) {
	const prelude = "pub struct foo? (\n    x : base.u32,\n)\n"
	testCases := []struct {
		what string
		body string
		want string
	}{{
		what: "read after a suspension",
		body: `
			var a : base.u32
			var b : base.u32
			a = 1
			b = 2
			yield? base."$short read"
			this.x = a`,
		want: "a",
	}, {
		what: "assigned again before being read",
		body: `
			var a : base.u32
			a = 1
			yield? base."$short read"
			a = 2
			this.x = a`,
		want: "",
	}, {
		what: "live around a loop",
		body: `
			var i : base.u32
			var c : base.u8
			var t : base.u32
			while i < 10 {
				c = args.src.read_u8?()
				t = c as base.u32
				this.x ~mod+= t
				i ~mod+= 1
			}`,
		want: "i",
	}, {
		what: "live in one branch only",
		body: `
			var a : base.u32
			var b : base.u32
			a = this.x
			b = this.x
			if a > 3 {
				yield? base."$short read"
				this.x = b
			} else {
				this.x = a
			}`,
		want: "b",
	}, {
		what: "the argument of a coroutine call",
		body: `
			var a : base.u32
			a = this.x
			this.other?(n: a)`,
		want: "a",
	}, {
		what: "not across a built-in I/O call that it is assigned from",
		body: `
			var c : base.u8
			c = args.src.read_u8?()
			this.x = c as base.u32
			c = args.src.read_u8?()
			this.x ~mod+= c as base.u32`,
		want: "",
	}}
	for _, tc := range testCases {
		src := prelude +
			"pri func foo.other?(n: base.u32) {\n    this.x = args.n\n    yield? base.\"$short read\"\n}\n" +
			"pub func foo.bar?(src: base.io_reader) {\n" + tc.body + "\n}\n"
		if got := findResumablesIn(tt, src, "bar"); got != tc.want {
			tt.Errorf("%s: got %q, want %q", tc.what, got, tc.want)
		}
	}
}

// TestFlatten checks the flattening pass on hand-made IR.
func TestFlatten(tt *testing.T) {
	susp := &variable{name: "G_Susp"}
	cond := func(s string) expr { return raw(s) }
	body := []stmt{
		sCall{raw("Before")},
		// A loop without a suspension point stays a loop, but its exit
		// from the enclosing (flattened) loop becomes a goto.
		sLoop{name: "G_Loop_1", cond: cond("A"), body: []stmt{
			sPragma{name: "Loop_Invariant", args: []expr{raw("Inv")}},
			sLoop{cond: cond("B"), body: []stmt{
				sPragma{name: "Loop_Invariant", args: []expr{raw("Inner_Inv")}},
				sIf{branches: []ifBranch{{cond("C"), []stmt{sExit{"G_Loop_1"}}}}},
			}},
			sIf{
				branches: []ifBranch{
					{cond("D"), []stmt{sResume{n: 1, susp: susp}, sCall{raw("After_Resume")}}},
					{cond("E"), []stmt{sGoto{"G_Exit"}}},
				},
				els: []stmt{sCall{raw("Else_Part")}},
			},
		}},
		sCall{raw("After")},
	}
	p := &printer{}
	p.stmts(dropUnusedLabels(flatten(body)))
	want := `Before;
<<G_Head_1>>
if not A then
   goto G_Done_2;
end if;
pragma Assert (Inv);
while B loop
   pragma Loop_Invariant (Inner_Inv);
   if C then
      goto G_Done_2;
   end if;
end loop;
if not D then
   goto G_Else_4;
end if;
G_Susp := 1;
<<G_Resume_1>>
After_Resume;
goto G_Fi_3;
<<G_Else_4>>
if not E then
   goto G_Else_5;
end if;
goto G_Exit;
<<G_Else_5>>
Else_Part;
<<G_Fi_3>>
goto G_Head_1;
<<G_Done_2>>
After;
`
	if got := p.b.String(); got != want {
		tt.Errorf("got:\n%s\nwant:\n%s", got, want)
	}

	// Nothing to flatten: nothing changes.
	plain := []stmt{sLoop{cond: cond("A"), body: []stmt{sCall{raw("X")}}}}
	p = &printer{}
	p.stmts(flatten(plain))
	if got, want := p.b.String(), "while A loop\n   X;\nend loop;\n"; got != want {
		tt.Errorf("got:\n%s\nwant:\n%s", got, want)
	}
}

func TestUseResolver(tt *testing.T) {
	root := filepath.Join("..", "..", "wuffs")
	if _, err := os.Stat(root); err != nil {
		tt.Skip("no Wuffs checkout at ./wuffs")
	}
	src, err := UseResolver(root)("std/adler32.wuffs")
	if err != nil {
		tt.Fatal(err)
	}
	wantContains(tt, string(src),
		"pub struct hasher? implements base.hasher_u32()\n",
		"pub func hasher.update_u32!(x: roslice base.u8) base.u32 { }\n")
	wantNotContains(tt, string(src), "up_arm_neon", "pri ")
	if _, err := UseResolver(root)("std/no_such_package.wuffs"); err == nil {
		tt.Errorf("no error for a missing package")
	}
}

// TestSliceArgumentOfCoroutineCall is the reviewer's repro for a slice
// argument that was evaluated before the resume label (so that the callee
// got an empty slice when the caller was resumed): the temporary that holds
// the slice must be assigned after the label.
func TestSliceArgumentOfCoroutineCall(tt *testing.T) {
	got := mustGenerate(tt, `
		pub struct foo? (
			sum : base.u32,
			buf : array[16] base.u8,
		)
		pri func foo.eat?(s: roslice base.u8, src: base.io_reader) {
			var c : base.u8
			c = args.src.read_u8?()
			this.sum ~mod+= (args.s.length() & 0xFF) as base.u32
			c = args.src.read_u8?()
			this.sum ~mod+= c as base.u32
		}
		pub func foo.bar?(src: base.io_reader) {
			var c : base.u8
			c = args.src.read_u8?()
			this.buf[12] = c
			this.eat?(s: this.buf[..].suffix(up_to: 4), src: args.src)
		}`)
	// In Bar (the last function): the label, then the temporary, then the
	// saving of the cursor, then the call.
	wantContains(tt, got, ""+
		"      G_Susp := 2;\n"+
		"      <<G_Resume_2>>\n"+
		"      G_T2 :=\n"+
		"        Wuffs.Runtime.Suffix (S => (Base => Self.F_Buf'Unrestricted_Access,\n")
	label, tmp, callee := strings.LastIndex(got, "<<G_Resume_2>>"), strings.LastIndex(got, "G_T2 :="),
		strings.LastIndex(got, "Eat (Self,")
	if label < 0 || tmp < label || callee < tmp {
		tt.Errorf("the slice temporary is not assigned between the resume label and the call:\n%s", got)
	}
}

// TestCheckTemps checks the structural guard behind that: IR in which a
// temporary is computed before a resume label and read after it is refused.
func TestCheckTemps(tt *testing.T) {
	tmp := &variable{name: "G_T1"}
	other := &variable{name: "V_X"}
	susp := &variable{name: "G_Susp"}
	l := &lowerer{temps: map[*variable]bool{tmp: true}}
	use := sAssign{eVar{other}, eVar{tmp}}
	def := sAssign{eVar{tmp}, raw("1")}
	resume := sResume{n: 1, susp: susp}

	good := [][]stmt{
		{def, use},
		{resume, def, use},
		{def, use, resume},
		// Defined on every path after the label.
		{resume, sIf{branches: []ifBranch{{raw("C"), []stmt{def}}}, els: []stmt{def}}, use},
		// As an "out" parameter.
		{resume, sCall{callNamed("P", "N", expr(eOut{eVar{tmp}}))}, use},
		// The read_u16le? shape: both branches define it, one after a label.
		{sIf{branches: []ifBranch{{raw("C"), []stmt{def}}}, els: []stmt{resume, def}}, use},
	}
	for i, ss := range good {
		if err := l.checkTemps(ss); err != nil {
			tt.Errorf("good #%d: %v", i, err)
		}
	}
	bad := [][]stmt{
		{def, resume, use},
		{def, sIf{branches: []ifBranch{{raw("C"), []stmt{resume}}}}, use},
		{resume, sIf{branches: []ifBranch{{raw("C"), []stmt{def}}}}, use},
		{def, sLoop{cond: raw("C"), body: []stmt{use, resume}}},
		{def, resume, sCall{call("P", bin("+", eVar{tmp}, raw("1")))}},
		// Passed directly, but as an "in" parameter: a read.
		{def, resume, sCall{callNamed("P", "X", expr(eVar{tmp}))}},
		{resume, sCall{callNamed("P", "X", expr(eVar{tmp}), "N", expr(eOut{eVar{tmp}}))}},
	}
	for i, ss := range bad {
		if err := l.checkTemps(ss); err == nil {
			tt.Errorf("bad #%d: no error", i)
		}
	}
}

// TestAssertionsAreReads is the reviewer's repro for a local that only a
// loop invariant mentions after a suspension: lowered assertions are
// evaluated (in the checked profile), so the local has to be saved, unlike
// in upstream's liveness analysis.
func TestAssertionsAreReads(tt *testing.T) {
	const src = `
		pub struct foo? (
			x : base.u32,
		)
		pub func foo.bar?(src: base.io_reader) {
			var c : base.u8
			var n : base.u32[..= 10]
			var m : base.u32[..= 10]
			var i : base.u32
			n = 5
			m = 6
			this.x ~mod+= n
			while i < 3,
					inv n == 5,
					inv m == 6,
			{
				c = args.src.read_u8?()
				this.x ~mod+= c as base.u32
				i ~mod+= 1
			}
		}`
	if got, want := findResumablesIn(tt, src, "bar"), "i m n"; got != want {
		tt.Errorf("resumables: got %q, want %q", got, want)
	}
	got := mustGenerate(tt, src)
	wantContains(tt, got,
		"      Self.G_S_1_Bar_N := V_N;\n",
		"         V_N := Self.G_S_1_Bar_N;\n",
		"      Self.G_S_1_Bar_M := V_M;\n",
		"      pragma Assert (V_N = 5);\n",
		"      pragma Assert (V_M = 6);\n")
}

// TestLivenessThroughOutput targets two rules of the liveness analysis by
// what they do to the generated code: the state at a "continue" is merged
// into the loop's entry state, and the arguments of a coroutine call are
// live at once.
func TestLivenessThroughOutput(tt *testing.T) {
	// x is read at the top of the loop body. It is only live there, after
	// a suspension, on the path through "continue": the other path assigns
	// it first.
	got := mustGenerate(tt, `
		pub struct foo? (
			x : base.u32,
		)
		pub func foo.bar?(src: base.io_reader) {
			var x : base.u32
			var i : base.u32
			var c : base.u8
			x = this.x
			while i < 3 {
				this.x ~mod+= x
				c = args.src.read_u8?()
				i ~mod+= 1
				if c == 0 {
					continue
				}
				x = 5
			}
		}`)
	wantContains(tt, got,
		"      Self.G_S_1_Bar_X := V_X;\n",
		"         V_X := Self.G_S_1_Bar_X;\n",
		"      Self.G_S_1_Bar_I := V_I;\n")
	wantNotContains(tt, got, "_Bar_C ")

	// a is an argument of a coroutine call and never mentioned again. The
	// call is made again when the caller is resumed, so a must be saved. b
	// is assigned after the call and not live across anything.
	got = mustGenerate(tt, `
		pub struct foo? (
			x : base.u32,
		)
		pri func foo.other?(n: base.u32, src: base.io_reader) {
			var c : base.u8
			c = args.src.read_u8?()
			this.x ~mod+= args.n ~mod+ (c as base.u32)
		}
		pub func foo.bar?(src: base.io_reader) {
			var a : base.u32
			var b : base.u32
			a = this.x ~mod+ 1
			this.other?(n: a, src: args.src)
			b = this.x
			this.x = b ~mod* 3
		}`)
	wantContains(tt, got,
		"      Self.G_S_2_Bar_A := V_A;\n",
		"         V_A := Self.G_S_2_Bar_A;\n",
		"Other (Self, A_N => V_A, A_Src => A_Src, A_Src_Meta => A_Src_Meta);\n")
	wantNotContains(tt, got, "_Bar_B ")
}

// TestSliceActuals checks the rule for slice arguments of Wuffs function
// calls: only a whole slice parameter of the caller is passed directly;
// anything else (here, parts of a field of the receiver, which GNAT would
// reject next to the receiver itself) goes through a slice handle.
func TestSliceActuals(tt *testing.T) {
	got := mustGenerate(tt, `
		pub struct foo? (
			sum : base.u32,
			buf : array[16] base.u8,
		)
		pri func foo.g!(s: slice base.u8) base.u32 {
			if args.s.length() > 0 {
				args.s[0] = 1
			}
			return this.sum
		}
		pri func foo.h!(s: slice base.u8) {
			if args.s.length() > 0 {
				args.s[0] ~mod+= 2
			}
		}
		pub func foo.bar!(w: slice base.u8) base.u32 {
			var x : base.u32
			this.h!(s: this.buf[2 .. 8])
			x = this.g!(s: this.buf[..])
			this.h!(s: args.w)
			return x
		}`)
	wantContains(tt, got,
		// Through handles.
		"H (Self, G_T1.Base (G_T1.First .. Wuffs.Runtime.Last (G_T1)));\n",
		"G (Self, G_T2.Base (G_T2.First .. Wuffs.Runtime.Last (G_T2)))",
		// The caller's own parameter, whole.
		"H (Self, A_W);\n",
		// Element writes through a slice parameter.
		"A_S (A_S'First + 0) := 1;\n",
		"A_S (A_S'First + 0) := A_S (A_S'First + 0) + 2;\n")
	wantNotContains(tt, got, "(Self, Self.")
}

// TestComparisonsAtBounds checks that a comparison with a bound of its
// operand's subtype is normalised wherever it comes from: written in the
// source, or produced by negating a loop or if condition when a coroutine
// is flattened (GNAT rejects "V_I >= 10" for a V_I in 0 .. 10: "can never
// be greater than"). The first source is the reviewer's repro; test.sh
// compiles the same shapes (advtest.wuffs has them).
func TestComparisonsAtBounds(tt *testing.T) {
	got := mustGenerate(tt, `
		pub struct foo? (
			sum : base.u32,
		)
		pub func foo.w?(src: base.io_reader) {
			var c : base.u8
			var i : base.u32[..= 10]
			var j : base.u32[..= 7]
			while i < 10 {
				c = args.src.read_u8?()
				this.sum ~mod+= c as base.u32
				if c > 0 {
					c = args.src.read_u8?()
				}
				if 7 > j {
					c = args.src.read_u8?()
				}
				i += 1
			}
		}`)
	wantContains(tt, got,
		"      if V_I = 10 then\n         goto G_Done_2;\n",
		"      if V_C = 0 then\n",
		"      if 7 = V_J then\n")
	wantNotContains(tt, got, ">= 10", "<= 0", "7 <= V_J")

	// Directly, and with a narrowed local.
	got = mustGenerate(tt, `
		pub struct foo? (
			sum : base.u32,
		)
		pub func foo.bar!(v: base.u32) {
			var a : base.u32
			var i : base.u32[..= 9]
			a = args.v & 0xFF
			i = args.v % 10
			if a >= 255 {
				this.sum = 1
			}
			if i <= 0 {
				this.sum = 2
			}
			if 9 <= i {
				this.sum = 3
			}
			if a >= 254 {
				this.sum = 4
			}
		}`)
	wantContains(tt, got, "if V_A = 255 then", "if V_I = 0 then", "if 9 = V_I then", "if V_A >= 254 then")

	// The operator is chosen in one place, also for a negated comparison.
	e := eRel{op: "<", l: raw("X"), r: raw("10"),
		li: operandInfo{lo: big.NewInt(0), hi: big.NewInt(10)}, ri: operandInfo{lit: big.NewInt(10)}}
	if got, want := flat(negate(e)), "X = 10"; got != want {
		tt.Errorf("negated: got %q, want %q", got, want)
	}
	if got, want := flat(negate(negate(e))), "X < 10"; got != want {
		tt.Errorf("negated twice: got %q, want %q", got, want)
	}
	if got, want := flat(negate(rel(">", raw("X"), raw("0")))), "X <= 0"; got != want {
		tt.Errorf("without knowing the operand's type: got %q, want %q", got, want)
	}
}

// TestStateNames checks that the record components for coroutine state are
// unambiguous: func "p_q" with a local "r" and func "p" with a local "q_r"
// (the reviewer's repro, which used to give two components G_S_P_Q_R).
func TestStateNames(tt *testing.T) {
	got := mustGenerate(tt, `
		pub struct foo? (
			sum : base.u32,
		)
		pub func foo.p_q?(src: base.io_reader) {
			var r : base.u8
			r = args.src.read_u8?()
			this.sum = args.src.read_u32le?()
			this.sum ~mod+= r as base.u32
		}
		pub func foo.p?(src: base.io_reader) {
			var q_r : base.u8
			q_r = args.src.read_u8?()
			this.sum = args.src.read_u32le?()
			this.sum ~mod+= q_r as base.u32
		}`)
	wantContains(tt, got,
		"      G_P_1_P_Q : Wuffs.U32 := 0;\n",
		"      G_Scratch_1_P_Q : Wuffs.U64 := 0;\n",
		"      G_S_1_P_Q_R : Wuffs.U8 := 0;\n",
		"      G_P_2_P : Wuffs.U32 := 0;\n",
		"      G_Scratch_2_P : Wuffs.U64 := 0;\n",
		"      G_S_2_P_Q_R : Wuffs.U8 := 0;\n")
}

// TestLabelsAndLoopNames checks that the labels of flattened statements
// cannot clash with Ada loop names: a loop with a break that stays a loop,
// followed by a loop that is flattened (the reviewer's repro, which used to
// give both a loop and a label called G_Loop_1).
func TestLabelsAndLoopNames(tt *testing.T) {
	got := mustGenerate(tt, `
		pub struct foo? (
			sum : base.u32,
		)
		pub func foo.z?(src: base.io_reader) {
			var c : base.u8
			var i : base.u32
			while true {
				i ~mod+= 1
				if i > 3 {
					break
				}
			}
			while i < 10 {
				c = args.src.read_u8?()
				i ~mod+= 1
			}
			this.sum ~mod+= (c as base.u32) ~mod+ i
		}`)
	wantContains(tt, got, "      G_Loop_1 :\n      loop\n", "      <<G_Head_1>>\n", "      goto G_Head_1;\n")
	wantNotContains(tt, got, "<<G_Loop_")
}

// TestDuplicateNameChecks checks the backstop: a clash of names in a record
// or in a subprogram is a generation error.
func TestDuplicateNameChecks(tt *testing.T) {
	s := &structInfo{
		fields: []fieldInfo{{name: "F_X", typ: typU32}},
		extra:  []fieldInfo{{name: "G_P_1_A", typ: typU32}, {name: "g_p_1_a", typ: typU32}},
	}
	if err := checkRecordNames(s); err == nil || !strings.Contains(err.Error(), "is used for") {
		tt.Errorf("record: got %v", err)
	}
	s.extra = s.extra[:1]
	if err := checkRecordNames(s); err != nil {
		tt.Errorf("record: got %v", err)
	}

	f := &fn{
		name:   "F",
		self:   &variable{name: "Self"},
		params: []*variable{{name: "A_X"}},
		locals: []*variable{{name: "V_X"}, {name: "G_T1"}},
		body: []stmt{
			sLoop{name: "G_Loop_1", body: []stmt{sLabel{"G_Continue_1"}}},
			sLabel{"G_Head_1"},
			sResume{n: 1, susp: &variable{name: "G_Susp"}},
		},
	}
	if err := checkSubprogramNames(f); err != nil {
		tt.Errorf("subprogram: got %v", err)
	}
	for _, extra := range []stmt{sLabel{"G_Loop_1"}, sLabel{"g_head_1"}, sLabel{"V_X"}, sLabel{"G_Resume_1"},
		sLoop{name: "A_X"}, sLabel{"not an identifier"}} {
		g := *f
		g.body = append(append([]stmt(nil), f.body...), extra)
		if err := checkSubprogramNames(&g); err == nil {
			tt.Errorf("subprogram with %v: no error", extra)
		}
	}
}

// A call of a library subprogram with two or more arguments must name them,
// unless the subprogram is on the list of those whose parameter types differ.
func TestCheckCalls(tt *testing.T) {
	ok := []stmt{
		sCall{callNamed("Wuffs.Runtime.Copy_Message", "Text", raw("T"), "Buffer", raw("B"), "Length", raw("L"))},
		sCall{call("Wuffs.Base.IO.Save", raw("M"), raw("R"))},
		sAssign{raw("X"), call("Wuffs.U64", raw("Y"))},
		sAssign{raw("X"), call("Local_Function", raw("Self"), raw("Y"))},
		sAssign{raw("X"), call("Wuffs.Std.Zlib.Something", raw("Self"), raw("Y"))},
		sIf{branches: []ifBranch{{call("Wuffs.Runtime.Valid_Buffer", raw("D"), raw("M")), nil}}},
	}
	if err := checkCalls(ok); err != nil {
		tt.Errorf("unexpected error: %v", err)
	}
	for _, bad := range []stmt{
		sCall{call("Wuffs.Runtime.Copy_Message", raw("T"), raw("B"), raw("L"))},
		sAssign{raw("X"), call("Wuffs.Base.Ints.Min_U64", raw("A"), raw("B"))},
		sIf{branches: []ifBranch{{raw("C"), []stmt{
			sLoop{body: []stmt{sReturn{call("Wuffs.Base.Slices.Peek_U8", raw("A"), raw("I"))}}}}}}},
		sCall{eCall{eRaw{"Wuffs.Runtime.Set"}, []expr{eNamed{"M", raw("M")}, raw("F")}}},
	} {
		if err := checkCalls([]stmt{bad}); err == nil {
			tt.Errorf("no error for a positional call: %#v", bad)
		}
	}
}

// Every public function checks, before anything else, that no array argument
// lies in the receiver, and every tagged type has the do-nothing Put_Image.
func TestEntryChecks(tt *testing.T) {
	src := `
		pub struct bar? implements base.hasher_u32(
			x : base.u32,
		)
		pub func bar.get_quirk(key: base.u32) base.u64 {
			return 0
		}
		pub func bar.set_quirk!(key: base.u32, value: base.u64) base.status {
			return base."#unsupported option"
		}
		pub func bar.update!(x: roslice base.u8) {
			this.x = (args.x.length() & 0xFF) as base.u32
		}
		pub func bar.update_u32!(x: roslice base.u8) base.u32 {
			return this.x
		}
		pub func bar.checksum_u32() base.u32 {
			return this.x
		}
	`
	out, err := generate(Options{PackageName: "foo", PackageID: 60000}, []string{"test.wuffs"}, [][]byte{[]byte(src)})
	if err != nil {
		tt.Fatal(err)
	}
	body := string(out.Body)
	if n := strings.Count(body, "Wuffs.Runtime.Shares_Storage (A => A_X, Address => Self'Address,"); n != 2 {
		tt.Errorf("%d receiver-overlap checks, want 2:\n%s", n, body)
	}
	if !strings.Contains(body, "Self.Magic := Wuffs.Runtime.Magic_Disabled;\n         return 0;") {
		tt.Errorf("update_u32 does not disable and return zero:\n%s", body)
	}
	if !strings.Contains(string(out.Spec), "with Put_Image => G_Put_Image;") {
		tt.Errorf("no Put_Image aspect:\n%s", out.Spec)
	}
}

// Token I/O: a token_writer argument is a token array and its meta, with a
// cursor that is built at entry, stored back at exit and around callees,
// and whose methods are calls into Wuffs.Base.Tokens; the struct implements
// Wuffs.Runtime.Token_Decoder; the reader methods that the token decoders
// use are calls into Wuffs.Base.IO and Wuffs.Base.UTF8.
func TestTokenWriter(tt *testing.T) {
	got := mustGenerate(tt, `
		pub struct foo? implements base.token_decoder(util : base.utility, x : base.u32)
		pub func foo.get_quirk(key: base.u32) base.u64 {
			return 0
		}
		pub func foo.set_quirk!(key: base.u32, value: base.u64) base.status {
			return ok
		}
		pub func foo.workbuf_len() base.range_ii_u64 {
			return this.util.empty_range_ii_u64()
		}
		pri func foo.put!(dst: base.token_writer, v: base.u32) {
			if args.dst.length() > 0 {
				args.dst.write_extended_token_fast!(value_extension: 0x3FFF_FFFF_FFFF, continued: 0, length: 3)
			}
		}
		pub func foo.decode_tokens?(dst: base.token_writer, src: base.io_reader, workbuf: slice base.u8) {
			var m : base.u32[..= 2]
			var n : base.u64
			var y : base.u64
			while args.dst.length() <= 0,
					post args.dst.length() > 0,
			{
				yield? base."$short write"
			}
			args.dst.write_simple_token_fast!(value_major: 0x0B_29FA, value_minor: 7, continued: 1, length: 0xFFFF)
			this.put!(dst: args.dst, v: 1)
			if args.src.length() >= 12 {
				m = args.src.match7(a: 0x6162_02)
				y = args.src.peek_u64le_at(offset: 4)
				n = args.src.valid_utf_8_length(up_to: 12)
				this.x = (m as base.u32) ~mod+ (((n ~mod+ y) & 0xFF) as base.u32)
			}
		}`)
	wantContains(tt, got,
		"type Foo is limited new Wuffs.Runtime.Token_Decoder with private;",
		"A_Dst : in out Wuffs.U64_Array;",
		"A_Dst_Meta : in out Wuffs.Base.Tokens.Token_Buffer_Meta;",
		"G_TW_Dst : Wuffs.Base.Tokens.Token_Writer;",
		"G_TW_Dst := Wuffs.Base.Tokens.To_Writer (M => A_Dst_Meta, Data_Length => A_Dst'Length);",
		"Wuffs.Runtime.Shares_Storage (A => A_Dst,",
		"not Wuffs.Runtime.Valid_Token_Buffer (A_Dst, A_Dst_Meta)",
		"Wuffs.Runtime.Tokens_Share_Storage (Tokens => A_Dst, B => A_Src)",
		"Wuffs.Runtime.Tokens_Share_Storage (Tokens => A_Dst, B => A_Workbuf)",
		"Wuffs.Base.Tokens.Length (G_TW_Dst)",
		"Value_Major => 16#0B_29FA#",
		"Continued => 1",
		"Length => 16#FFFF#",
		"Value_Extension => 16#3FFF_FFFF_FFFF#",
		"Wuffs.Base.Tokens.Save (A_Dst_Meta, G_TW_Dst);\n      Put (Self, A_Dst => A_Dst, A_Dst_Meta => A_Dst_Meta, A_V => 1);\n      Wuffs.Base.Tokens.Reload (G_TW_Dst, A_Dst_Meta);",
		"Wuffs.Base.IO.Match7 (Data => A_Src, R => G_R_Src, A => 16#61_6202#)",
		"Wuffs.Base.IO.Peek_U64LE_At (Data => A_Src, R => G_R_Src, Offset => 4)",
		"Wuffs.Base.UTF8.Valid_UTF_8_Length (Data => A_Src, R => G_R_Src, Up_To => 12)",
		"return Wuffs.Base.Ranges.Empty_Range_II_U64;",
	)
	if n := strings.Count(got, "Wuffs.Base.Tokens.Write_Simple_Token_Fast\n"); n != 1 {
		tt.Errorf("%d calls of Write_Simple_Token_Fast, want 1", n)
	}
}

func TestCheckCallsTokens(tt *testing.T) {
	ok := []stmt{
		sCall{call("Wuffs.Base.Tokens.Save", raw("M"), raw("W"))},
		sCall{call("Wuffs.Base.Tokens.Reload", raw("W"), raw("M"))},
		sIf{branches: []ifBranch{{call("Wuffs.Runtime.Valid_Token_Buffer", raw("D"), raw("M")), nil}}},
	}
	if err := checkCalls(ok); err != nil {
		tt.Errorf("unexpected error: %v", err)
	}
	for _, bad := range []stmt{
		sCall{call("Wuffs.Base.Tokens.Write_Simple_Token_Fast", raw("D"), raw("W"), raw("0"), raw("1"), raw("0"), raw("1"))},
		sCall{call("Wuffs.Base.Tokens.Write_Extended_Token_Fast", raw("D"), raw("W"), raw("0"), raw("0"), raw("1"))},
		sAssign{raw("X"), call("Wuffs.Runtime.Tokens_Share_Storage", raw("T"), raw("B"))},
		sAssign{raw("X"), call("Wuffs.Base.UTF8.Valid_UTF_8_Length", raw("D"), raw("R"), raw("N"))},
	} {
		if err := checkCalls([]stmt{bad}); err == nil {
			tt.Errorf("no error for a positional call: %#v", bad)
		}
	}
}
