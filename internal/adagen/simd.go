// Part of wuffada (wuffs-ada: Wuffs to Ada).
// SPDX-License-Identifier: Apache-2.0 OR MIT

package adagen

import (
	"fmt"
	"sort"
	"strings"

	a "github.com/google/wuffs/lang/ast"
	t "github.com/google/wuffs/lang/token"
)

// This file is the SIMD part of the generator (Options.SIMD): which
// functions become SIMD implementations, the methods of the x86 cpu_arch
// types, and the child units that hold the implementations.
//
// A function with a "choose cpu_arch >= x86_etc" assertion is generated
// into the private child unit of its feature (simdUnitName), which is
// compiled with the -m options of upstream's target attribute for that
// feature, and nothing else is. It is only ever called by the dispatcher
// of a choosy function (findChoices), after a choose statement has asked
// Wuffs.Runtime.CPU whether the CPU has the feature (choose), as upstream's
// C calls it through a function pointer that only such a choose statement
// sets.

// simdSwitches maps each supported cpu_arch capability to the suffix of its
// child unit. ARM capabilities (arm_crc32, arm_neon) are not supported:
// their functions are skipped.
var simdSwitches = map[string]string{
	"x86_sse42": "X86_SSE42",
	"x86_avx2":  "X86_AVX2",
	"x86_bmi2":  "X86_BMI2",
}

// cpuArchOf returns the capability that a function's "choose cpu_arch >=
// etc" assertion names, such as "x86_sse42".
func (g *gen) cpuArchOf(n *a.Func) (string, error) {
	ret := ""
	for _, o := range n.Asserts() {
		o := o.AsAssert()
		if !o.IsChooseCPUArch() {
			continue
		}
		if ret != "" {
			// As upstream's C back-end (cpuArchCNames).
			return "", fmt.Errorf("too many choose-cpu_arch preconditions")
		}
		ret = o.Condition().RHS().AsExpr().Ident().Str(g.tm)
	}
	if ret == "" {
		return "", fmt.Errorf("internal error: no choose-cpu_arch precondition")
	}
	return ret, nil
}

// simdUnitName returns the name of the child unit for a feature.
func (g *gen) simdUnitName(feature string) string {
	return g.adaPkgName + "." + simdSwitches[feature]
}

// haveFeature returns the Wuffs.Runtime.CPU function that says whether the
// CPU has the feature.
func haveFeature(feature string) string {
	return cpuPkg + ".Have_" + strings.ToUpper(feature[:3]) + feature[3:4] + strings.ToUpper(feature[4:])
}

// qualifiedName is the name by which the package body calls f.
func (g *gen) qualifiedName(fi *funcInfo, f *fn) string {
	if fi != nil && fi.simd != "" {
		return g.simdUnitName(fi.simd) + "." + f.name
	}
	return f.name
}

// ---------------------------------------------------------------------------
// The methods of the x86 cpu_arch types.

type x86ArgKind uint8

const (
	xaVec128   x86ArgKind = iota // A base.x86_m128i.
	xaVec256                     // A base.x86_m256i.
	xaNum                        // A base.u8 .. base.u64 (bits).
	xaBytes                      // A roslice base.u8 (or slice base.u8, if writable).
	xaU16Slice                   // A roslice base.u16: an array of u16 sliced with [lo .. hi].
	xaImm                        // A constant, lo ..= hi.
)

type x86Arg struct {
	name     string // The Wuffs argument name, such as "imm8".
	kind     x86ArgKind
	bits     int  // For xaNum.
	lo, hi   int  // For xaImm.
	writable bool // For xaBytes.
}

type x86Method struct {
	pkg  string // sse42Pkg or avx2Pkg.
	args []x86Arg
	ret  *adaType // nil for a procedure.
}

// adaName is the name of the Ada subprogram for the Wuffs method, such as
// Mm_Add_Epi8 for _mm_add_epi8: see ada/src/simd/wuffs-runtime-x86-sse42.ads.
func x86AdaName(method string) string {
	return mangle(strings.TrimLeft(method, "_"))
}

func numArgs(bits int, names ...string) []x86Arg {
	ret := []x86Arg(nil)
	for _, n := range names {
		ret = append(ret, x86Arg{name: n, kind: xaNum, bits: bits})
	}
	return ret
}

func aNNs(n int) []string {
	ret := []string(nil)
	for i := 0; i < n; i++ {
		ret = append(ret, fmt.Sprintf("a%02d", i))
	}
	return ret
}

var (
	argB128 = x86Arg{name: "b", kind: xaVec128}
	argB256 = x86Arg{name: "b", kind: xaVec256}
)

func imm(name string, lo, hi int) x86Arg {
	return x86Arg{name: name, kind: xaImm, lo: lo, hi: hi}
}

// x86Methods are the supported methods, keyed by "receiver_type.method".
// Each is one Ada subprogram of Wuffs.Runtime.X86.SSE42 or AVX2. The ranges
// of the immediate arguments are those that GCC accepts for the intrinsic
// that upstream's C back-end calls. Every other method of the x86 types in
// wuffs/lang/builtin/builtin.go is rejected (errNotYet): none of Wuffs'
// standard library calls it.
var x86Methods = map[string]x86Method{}

func init() {
	add := func(key string, pkg string, ret *adaType, args ...x86Arg) {
		x86Methods[key] = x86Method{pkg: pkg, args: args, ret: ret}
	}
	u := "x86_sse42_utility."
	add(u+"make_m128i_multiple_u8", sse42Pkg, typM128I, numArgs(8, aNNs(16)...)...)
	add(u+"make_m128i_multiple_u32", sse42Pkg, typM128I, numArgs(32, aNNs(4)...)...)
	add(u+"make_m128i_repeat_u8", sse42Pkg, typM128I, numArgs(8, "a")...)
	add(u+"make_m128i_repeat_u16", sse42Pkg, typM128I, numArgs(16, "a")...)
	add(u+"make_m128i_single_u32", sse42Pkg, typM128I, numArgs(32, "a")...)
	add(u+"make_m128i_single_u64", sse42Pkg, typM128I, numArgs(64, "a")...)
	add(u+"make_m128i_slice128", sse42Pkg, typM128I, x86Arg{name: "a", kind: xaBytes})
	add(u+"make_m128i_slice_u16lex8", sse42Pkg, typM128I, x86Arg{name: "a", kind: xaU16Slice})
	add(u+"make_m128i_zeroes", sse42Pkg, typM128I)
	add(u+"make_u64_slice_u16lex4", sse42Pkg, typU64, x86Arg{name: "a", kind: xaU16Slice})

	m := "x86_m128i."
	add(m+"store_slice128", sse42Pkg, nil, x86Arg{name: "a", kind: xaBytes, writable: true})
	add(m+"truncate_u32", sse42Pkg, typU32)
	add(m+"truncate_u64", sse42Pkg, typU64)
	add(m+"_mm_abs_epi16", sse42Pkg, typM128I)
	for _, o := range []string{"_mm_add_epi8", "_mm_add_epi16", "_mm_add_epi32", "_mm_and_si128",
		"_mm_avg_epu8", "_mm_cmpeq_epi16", "_mm_madd_epi16", "_mm_maddubs_epi16", "_mm_min_epi16",
		"_mm_or_si128", "_mm_packs_epi16", "_mm_packus_epi16", "_mm_sad_epu8", "_mm_sub_epi8",
		"_mm_sub_epi16", "_mm_unpacklo_epi8", "_mm_xor_si128"} {
		add(m+o, sse42Pkg, typM128I, argB128)
	}
	add(m+"_mm_blendv_epi8", sse42Pkg, typM128I, argB128, x86Arg{name: "mask", kind: xaVec128})
	add(m+"_mm_clmulepi64_si128", sse42Pkg, typM128I, argB128, imm("imm8", 0, 255))
	add(m+"_mm_extract_epi32", sse42Pkg, typU32, imm("imm8", 0, 3))
	add(m+"_mm_extract_epi64", sse42Pkg, typU64, imm("imm8", 0, 1))
	add(m+"_mm_shuffle_epi32", sse42Pkg, typM128I, imm("imm8", 0, 255))
	add(m+"_mm_slli_epi32", sse42Pkg, typM128I, imm("imm8", 0, 255))
	add(m+"_mm_slli_si128", sse42Pkg, typM128I, imm("imm8", 0, 255))

	u = "x86_avx2_utility."
	add(u+"make_m256i_multiple_u16", avx2Pkg, typM256I, numArgs(16, aNNs(16)...)...)
	add(u+"make_m256i_slice_u16lex16", avx2Pkg, typM256I, x86Arg{name: "a", kind: xaU16Slice})
	add(u+"make_u64_slice_u16lex4", avx2Pkg, typU64, x86Arg{name: "a", kind: xaU16Slice})

	m = "x86_m256i."
	for _, o := range []string{"_mm256_add_epi8", "_mm256_add_epi16", "_mm256_add_epi32",
		"_mm256_madd_epi16", "_mm256_mullo_epi16", "_mm256_packs_epi16", "_mm256_packs_epi32",
		"_mm256_sign_epi16", "_mm256_sub_epi32", "_mm256_unpackhi_epi16", "_mm256_unpackhi_epi64",
		"_mm256_unpacklo_epi16", "_mm256_unpacklo_epi64"} {
		add(m+o, avx2Pkg, typM256I, argB256)
	}
	add(m+"_mm256_castsi256_si128", avx2Pkg, typM128I)
	add(m+"_mm256_extract_epi64", avx2Pkg, typU64, imm("index", 0, 3))
	add(m+"_mm256_inserti128_si256", avx2Pkg, typM256I, argB128, imm("imm8", 0, 1))
	add(m+"_mm256_permute2x128_si256", avx2Pkg, typM256I, argB256, imm("imm8", 0, 255))
	add(m+"_mm256_permute4x64_epi64", avx2Pkg, typM256I, imm("imm8", 0, 255))
	add(m+"_mm256_shuffle_epi32", avx2Pkg, typM256I, imm("imm8", 0, 255))
	add(m+"_mm256_slli_epi16", avx2Pkg, typM256I, imm("imm8", 0, 255))
	add(m+"_mm256_srai_epi32", avx2Pkg, typM256I, imm("imm8", 0, 255))
}

// X86MethodNames returns the keys of the supported methods, sorted, for
// ada/src/simd/METHODS.md and its test.
func X86MethodNames() []string {
	ret := []string(nil)
	for k := range x86Methods {
		ret = append(ret, k)
	}
	sort.Strings(ret)
	return ret
}

// featureCovers reports whether a function of the feature (compiled with
// that feature's options) may call a method of the package pkg.
func featureCovers(feature string, pkg string) bool {
	switch pkg {
	case sse42Pkg:
		// Upstream's target attributes: "pclmul,popcnt,sse4.2" for
		// x86_sse42 and "pclmul,popcnt,sse4.2,avx2" for x86_avx2.
		return feature == "x86_sse42" || feature == "x86_avx2"
	case avx2Pkg:
		return feature == "x86_avx2"
	}
	return false
}

// isX86Type reports whether typ is one of the four x86 cpu_arch types.
func isX86Type(typ *a.TypeExpr) bool {
	if typ.Decorator() != 0 || typ.QID()[0] != t.IDBase {
		return false
	}
	switch typ.QID()[1] {
	case t.IDX86M128I, t.IDX86M256I, t.IDX86SSE42Utility, t.IDX86AVX2Utility:
		return true
	}
	return false
}

// x86Method lowers a method call on an x86 cpu_arch value or utility.
func (l *lowerer) x86Method(n *a.Expr, recv *a.Expr, name string, args []*a.Node) (val, error) {
	recvTyp := recv.MType()
	if !isX86Type(recvTyp) {
		return val{}, errNotYet("method %q of the cpu_arch type %q", name, recvTyp.Str(l.g.tm))
	}
	if l.fi.simd == "" {
		return val{}, fmt.Errorf("call %q: a cpu_arch method outside of a SIMD function", n.Str(l.g.tm))
	}
	key := recvTyp.QID()[1].Str(l.g.tm) + "." + name
	m, ok := x86Methods[key]
	if !ok {
		return val{}, errNotYet("the cpu_arch method %s", key)
	}
	if !featureCovers(l.fi.simd, m.pkg) {
		return val{}, fmt.Errorf("call %q: method %s needs more than %s", n.Str(l.g.tm), key, l.fi.simd)
	}

	names, values := []string(nil), []expr(nil)
	switch recvTyp.QID()[1] {
	case t.IDX86M128I, t.IDX86M256I:
		rv, err := l.expr(recv)
		if err != nil {
			return val{}, err
		}
		if rv.typ == nil || rv.typ.kind != kVec {
			return val{}, fmt.Errorf("internal error: receiver of %q is not a vector", n.Str(l.g.tm))
		}
		names, values = append(names, "X"), append(values, l.flatVec(rv))
	}
	if len(args) != len(m.args) {
		return val{}, fmt.Errorf("call %q: wrong number of arguments", n.Str(l.g.tm))
	}
	for i, o := range args {
		want := m.args[i]
		if got := o.AsArg().Name().Str(l.g.tm); got != want.name {
			return val{}, fmt.Errorf("call %q: argument %d is %q, not %q", n.Str(l.g.tm), i, got, want.name)
		}
		arg := o.AsArg().Value()
		var e expr
		switch want.kind {
		case xaImm:
			// Upstream's C passes the value to the intrinsic, which GCC
			// accepts only as a constant in the intrinsic's range.
			cv := arg.ConstValue()
			if cv == nil || !cv.IsInt64() || cv.Int64() < int64(want.lo) || cv.Int64() > int64(want.hi) {
				return val{}, fmt.Errorf("call %q: argument %s must be a constant in %d ..= %d",
					n.Str(l.g.tm), want.name, want.lo, want.hi)
			}
			e = raw(cv.String())
		case xaU16Slice:
			var err error
			if e, err = l.u16Slice(arg); err != nil {
				return val{}, fmt.Errorf("call %q: %v", n.Str(l.g.tm), err)
			}
		default:
			v, err := l.expr(arg)
			if err != nil {
				return val{}, err
			}
			if v.typ == nil {
				return val{}, fmt.Errorf("argument %q has no value", arg.Str(l.g.tm))
			}
			switch want.kind {
			case xaVec128, xaVec256:
				bits := 128
				if want.kind == xaVec256 {
					bits = 256
				}
				if v.typ.kind != kVec || v.typ.bits != bits {
					return val{}, fmt.Errorf("call %q: argument %s has the wrong type", n.Str(l.g.tm), want.name)
				}
				v.e = l.flatVec(v)
			case xaNum:
				if err := l.numArg(n, v, want.bits); err != nil {
					return val{}, err
				}
			case xaBytes:
				if !v.typ.isSlice() {
					return val{}, fmt.Errorf("call %q: argument %s is not a slice of bytes", n.Str(l.g.tm), want.name)
				}
				if v, err = l.toBytes(v, want.writable); err != nil {
					return val{}, fmt.Errorf("call %q: %v", n.Str(l.g.tm), err)
				}
			}
			e = v.e
		}
		names, values = append(names, mangle(want.name)), append(values, e)
	}

	fn := m.pkg + "." + x86AdaName(name)
	var c expr
	switch len(values) {
	case 0:
		c = raw(fn)
	case 1:
		c = call(fn, values[0])
	default:
		namesAndArgs := []interface{}(nil)
		for i := range values {
			namesAndArgs = append(namesAndArgs, names[i], values[i])
		}
		c = callNamed(fn, namesAndArgs...)
	}
	if m.ret == nil {
		l.pre = append(l.pre, sCall{c})
		return val{}, nil
	}
	return val{e: c, typ: m.ret}, nil
}

// flatVec returns a vector operand of a method call: v itself if it is a
// variable, else a temporary that is assigned v (a call of another method)
// before the statement. Wuffs SIMD code chains method calls deeply
// (x._mm_or_si128(b: y)._mm_or_si128(b: z)...), and the nested Ada calls
// would not fit the line length; the methods are pure functions, so
// evaluating the inner calls first, once each, is what C does too.
func (l *lowerer) flatVec(v val) expr {
	if _, ok := v.e.(eVar); ok {
		return v.e
	}
	tmp := eVar{l.newTemp(v.typ)}
	l.pre = append(l.pre, sAssign{tmp, v.e})
	return tmp
}

// u16Slice lowers a roslice base.u16 argument, which must be a slice
// expression arr[lo .. hi] of a (constrained, zero-based) array of u16, to
// the Ada slice of that array.
func (l *lowerer) u16Slice(n *a.Expr) (expr, error) {
	arr, lo, hi, ok := n.IsSlice()
	if !ok {
		return nil, errNotYet("a slice of u16 other than an array sliced with [lo .. hi]: %q", n.Str(l.g.tm))
	}
	av, err := l.expr(arr)
	if err != nil {
		return nil, err
	}
	if av.typ == nil || av.typ.kind != kArray || av.typ.elem.kind != kNum || av.typ.elem.bits != 16 {
		return nil, errNotYet("a slice of u16 of something other than an array of u16: %q", n.Str(l.g.tm))
	}
	first, last := expr(raw("0")), expr(eAttr{av.e, "Last"})
	if lo != nil {
		if first, err = l.index(lo); err != nil {
			return nil, err
		}
	}
	if hi != nil {
		h, err := l.index(hi)
		if err != nil {
			return nil, err
		}
		last = indexMinus1(h)
	}
	return eSlice{av.e, first, last}, nil
}

// funcOfIR returns the function whose own body is f, or nil.
func (g *gen) funcOfIR(f *fn) *funcInfo {
	for _, fi := range g.funcList {
		if fi.ir == f {
			return fi
		}
	}
	return nil
}

// genSIMDUnit makes the private child unit that holds the SIMD
// implementations of one feature. Its spec declares them (the package's
// spec does not: only the package body, which withs the child, calls them)
// and its body defines them. The child sees the private part of the
// package's spec, so the receiver's components, the private subprograms
// and the constants that the implementations use (constInfo.inSpec).
func (g *gen) genSIMDUnit(feature string) *Unit {
	name := g.simdUnitName(feature)
	file := strings.ToLower(strings.ReplaceAll(name, ".", "-"))

	p := &printer{}
	p.comment("A private child unit: the SIMD implementations that need the cpu_arch\n" +
		"capability " + feature + ". It must be compiled with the -m options of that\n" +
		"capability (see ada/wuffs_simd.gpr), and nothing calls into it before a\n" +
		"choose statement has found that the CPU has it.")
	p.line("")
	p.line("private package " + name + " with Preelaborate is")
	p.indent += indentStep
	for _, fi := range g.funcList {
		if fi.simd == feature {
			p.line("")
			p.comment("Wuffs: func " + fi.ir.wuffsName)
			p.fnSpec(fi.ir)
		}
	}
	p.indent -= indentStep
	p.line("")
	p.line("end " + name + ";")
	spec := p.b.String()

	useType := map[int]bool{}
	for _, fi := range g.funcList {
		if fi.simd == feature {
			for b, ok := range fi.useType {
				useType[b] = useType[b] || ok
			}
		}
	}
	p = &printer{}
	p.line("package body " + name + " is")
	p.indent += indentStep
	bits := []int(nil)
	for b, ok := range useType {
		if ok {
			bits = append(bits, b)
		}
	}
	sort.Ints(bits)
	if len(bits) > 0 {
		p.line("")
	}
	for _, b := range bits {
		p.line("use type " + numType(b).name + ";")
	}
	for _, fi := range g.funcList {
		if fi.simd == feature {
			p.line("")
			p.fnBody(fi.ir)
		}
	}
	p.indent -= indentStep
	p.line("")
	p.line("end " + name + ";")
	body := p.b.String()

	return &Unit{
		UnitName: name,
		SpecFile: file + ".ads",
		BodyFile: file + ".adb",
		Spec:     []byte(g.header() + g.withClauses(spec, "") + spec),
		Body:     []byte(g.header() + g.withClauses(body, spec) + body),
	}
}
