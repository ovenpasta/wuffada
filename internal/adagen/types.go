// Part of wuffada (wuffs-ada: Wuffs to Ada).
// SPDX-License-Identifier: Apache-2.0 OR MIT

package adagen

import (
	"fmt"
	"math/big"
	"sort"
	"strings"

	a "github.com/google/wuffs/lang/ast"
	t "github.com/google/wuffs/lang/token"
)

type typeKind uint8

const (
	kInvalid = typeKind(iota)
	kIdeal   // A universal integer literal.
	kNum     // Wuffs.U8, U16, U32 or U64, or a subtype of one.
	kIndex   // Wuffs.Index.
	kBool
	kStatus
	kROSliceU8 // Wuffs "roslice base.u8", as a re-assignable handle.
	kSliceU8   // Wuffs "slice base.u8", as a re-assignable handle.
	kBytes     // A read-only view of bytes, as an Ada array (object or slice).
	kBytesVar  // A writable view of bytes, as an Ada array (object or slice).
	kArray
	kStruct
	kUtility  // Wuffs "base.utility": an empty struct with built-in methods.
	kOpaque   // A base library value type (optional_u63, range_ii_u64).
	kIOReader // Wuffs "base.io_reader": an Ada array plus a Buffer_Meta.
	kIOWriter // Wuffs "base.io_writer": likewise, writable.
	kMeta     // Wuffs.Base.IO.Buffer_Meta.
	kCursor   // Wuffs.Base.IO.Reader or Writer.
	kNptr     // A nullable pointer to a base value type: an object plus a "null" flag.
	kPixBuf   // Wuffs "ptr base.pixel_buffer": a descriptor plus two arrays.

	// kNptrPixBuf is Wuffs "nptr base.pixel_buffer": what kPixBuf is, plus
	// a "null" flag (as for kNptr). When the flag is set, nothing reads the
	// descriptor or either array: the Wuffs compiler proves a nullable
	// pointer non-null before any method call on it, and method calls are
	// the only way to the arrays.
	kNptrPixBuf
	kTable    // Wuffs "table base.u8": a Pixel_Buffers.Table, bound to an array.
	kSwizzler // Wuffs "base.pixel_swizzler".

	// kRowPtr is a local variable of type "nptr roarray[N] T" or "ptr
	// array[N] T" (only that), which points at one row of a receiver field
	// that is an array of such arrays: see rowPtr in lower.go. In Ada it is
	// the row's index (a Wuffs.Offset), -1 for nullptr. elem and length are
	// the row's element type and length.
	kRowPtr

	// kTokenWriter is Wuffs "base.token_writer": an Ada array of tokens
	// (Wuffs.U64_Array) plus a Wuffs.Base.Tokens.Token_Buffer_Meta, as
	// kIOWriter is a byte array plus a Buffer_Meta.
	kTokenWriter
	kTokenArray // Wuffs.U64_Array: the array of a token buffer.
	kTokenMeta  // Wuffs.Base.Tokens.Token_Buffer_Meta.
)

// adaType is the Ada type of a Wuffs type, variable or expression.
type adaType struct {
	kind typeKind

	// name is a subtype_mark, or (for some arrays) a subtype_indication that
	// is usable in an object or component declaration.
	name string

	// For kNum.
	bits   int
	lo, hi *big.Int // The refinement's inclusive bounds; nil if unrefined.

	// For kArray.
	elem   *adaType
	length *big.Int

	// For kStruct: the struct, of this package or of a used one.
	st *structInfo

	// For kOpaque: the Ada expression for the zero value.
	zero string
}

var (
	zero = big.NewInt(0)
	one  = big.NewInt(1)

	typIdeal  = &adaType{kind: kIdeal, name: "universal_integer"}
	typIndex  = &adaType{kind: kIndex, name: "Wuffs.Index"}
	typOffset = &adaType{kind: kIndex, name: "Wuffs.Offset"}
	typBool   = &adaType{kind: kBool, name: "Boolean"}
	typStatus = &adaType{kind: kStatus, name: "Wuffs.Status"}
	typU8     = &adaType{kind: kNum, name: "Wuffs.U8", bits: 8}
	typU16    = &adaType{kind: kNum, name: "Wuffs.U16", bits: 16}
	typU32    = &adaType{kind: kNum, name: "Wuffs.U32", bits: 32}
	typU64    = &adaType{kind: kNum, name: "Wuffs.U64", bits: 64}

	typROSliceU8 = &adaType{kind: kROSliceU8, name: "Wuffs.Runtime.RO_Slice_U8"}
	typSliceU8   = &adaType{kind: kSliceU8, name: "Wuffs.Runtime.Slice_U8"}
	typBytes     = &adaType{kind: kBytes, name: "Wuffs.Bytes"}
	typBytesVar  = &adaType{kind: kBytesVar, name: "Wuffs.Bytes"}
	typUtility   = &adaType{kind: kUtility, name: "base.utility"}
	typIOReader  = &adaType{kind: kIOReader, name: "base.io_reader"}
	typIOWriter  = &adaType{kind: kIOWriter, name: "base.io_writer"}
	typMeta      = &adaType{kind: kMeta, name: ioPkg + ".Buffer_Meta"}
	typReader    = &adaType{kind: kCursor, name: ioPkg + ".Reader"}
	typWriter    = &adaType{kind: kCursor, name: ioPkg + ".Writer"}

	typTokenWriter = &adaType{kind: kTokenWriter, name: "base.token_writer"}
	typTokenArray  = &adaType{kind: kTokenArray, name: "Wuffs.U64_Array"}
	typTokenMeta   = &adaType{kind: kTokenMeta, name: tokensPkg + ".Token_Buffer_Meta"}
	typTokenCursor = &adaType{kind: kCursor, name: tokensPkg + ".Token_Writer"}

	typPixelFormat = &adaType{kind: kOpaque, name: formatsPkg + ".Pixel_Format",
		zero: formatsPkg + ".Make_Pixel_Format (Repr => 0)"}
	typPixelBlend = &adaType{kind: kOpaque, name: formatsPkg + ".Pixel_Blend", zero: "0"}
	typRectIEU32  = &adaType{kind: kOpaque, name: rangesPkg + ".Rect_IE_U32",
		zero: rangesPkg + ".Empty_Rect_IE_U32"}
	typReaderLimit = &adaType{kind: kOpaque, name: ioPkg + ".Reader_Limit_State"}
	typForgetState = &adaType{kind: kOpaque, name: ioPkg + ".Forget_State"}
	typTable       = &adaType{kind: kTable, name: buffersPkg + ".Table"}
	typSwizzler    = &adaType{kind: kSwizzler, name: swizzlerPkg + ".Swizzler"}
	typPixBuf      = &adaType{kind: kPixBuf, name: buffersPkg + ".Pixel_Buffer"}
	typNptrPixBuf  = &adaType{kind: kNptrPixBuf, name: buffersPkg + ".Pixel_Buffer"}

	// The nullable pointers.
	typNptrImageConfig = &adaType{kind: kNptr, name: formatsPkg + ".Image_Config"}
	typNptrFrameConfig = &adaType{kind: kNptr, name: formatsPkg + ".Frame_Config"}
	typNptrMoreInfo    = &adaType{kind: kNptr, name: "Wuffs.Runtime.More_Information"}
	typNptrFrameOpts   = &adaType{kind: kNptr, name: "Wuffs.Runtime.Decode_Frame_Options"}

	typBitvec256 = &adaType{kind: kOpaque, name: intsPkg + ".Bitvec256",
		zero: "[others => 0]"}
	typOptionalU63 = &adaType{kind: kOpaque, name: intsPkg + ".Optional_U63",
		zero: intsPkg + ".Make_Optional_U63 (Has_Value => False, Value => 0)"}
	typRangeIIU64 = &adaType{kind: kOpaque, name: rangesPkg + ".Range_II_U64",
		zero: rangesPkg + ".Empty_Range_II_U64"}
)

func numType(bits int) *adaType {
	switch bits {
	case 8:
		return typU8
	case 16:
		return typU16
	case 32:
		return typU32
	case 64:
		return typU64
	}
	return nil
}

func numTypeMax(bits int) *big.Int {
	x := big.NewInt(1)
	x.Lsh(x, uint(bits))
	return x.Sub(x, one)
}

// unrefined returns the base type of a kNum type.
func (x *adaType) unrefined() *adaType {
	if x.kind == kNum {
		return numType(x.bits)
	}
	return x
}

// sameAdaType reports whether x and y denote the same Ada type. typeOf makes
// a new adaType for each refined numeric type that it meets, so two
// parameters declared "base.u32[..= 9]" have equal but distinct adaTypes.
func sameAdaType(x, y *adaType) bool {
	if x == y {
		return true
	}
	if x == nil || y == nil || x.kind != y.kind || x.name != y.name {
		return false
	}
	switch x.kind {
	case kNum:
		return x.bits == y.bits && cmpBig(x.lo, y.lo) && cmpBig(x.hi, y.hi)
	case kArray:
		return x.length.Cmp(y.length) == 0 && sameAdaType(x.elem, y.elem)
	}
	// Every other kind has one adaType per Ada type (see the variables
	// above, and structInfo.typ).
	return false
}

func cmpBig(x, y *big.Int) bool {
	if x == nil || y == nil {
		return x == nil && y == nil
	}
	return x.Cmp(y) == 0
}

// excludesZero reports whether x is a numeric refinement that zero is not in.
// The Wuffs compiler rejects such a type for anything that is
// zero-initialized (fields and local variables), so only parameters can have
// one.
func (x *adaType) excludesZero() bool {
	return x.kind == kNum && x.lo != nil && x.lo.Sign() > 0
}

// zeroValue returns the Ada expression for the Wuffs zero value of x, or nil
// if objects of that type are default-initialized. Callers have checked
// !x.excludesZero().
func (x *adaType) zeroValue() expr {
	switch x.kind {
	case kNum:
		return raw("0")
	case kBool:
		return raw("False")
	case kStatus:
		return raw("Wuffs.Ok_Status")
	case kOpaque:
		return raw(x.zero)
	}
	return nil
}

// isSlice reports whether x is one of the four representations of a slice
// of bytes.
func (x *adaType) isSlice() bool {
	switch x.kind {
	case kROSliceU8, kSliceU8, kBytes, kBytesVar:
		return true
	}
	return false
}

func uintBits(qid t.QID) int {
	if qid[0] == t.IDBase {
		switch qid[1] {
		case t.IDU8:
			return 8
		case t.IDU16:
			return 16
		case t.IDU32:
			return 32
		case t.IDU64:
			return 64
		}
	}
	return 0
}

// namedType is a type or subtype declaration that the generated package
// needs.
type namedType struct {
	name   string
	decl   string // The complete declaration.
	public bool
	order  int
}

// typeOf maps a Wuffs type to an Ada type. If public, any Ada declarations
// that the type needs go in the visible part of the package spec.
func (g *gen) typeOf(x *a.TypeExpr, public bool) (*adaType, error) {
	switch x.Decorator() {
	case 0:
		qid := x.QID()
		if qid[0] == t.IDBase {
			switch qid[1] {
			case t.IDUtility:
				return typUtility, nil
			case t.IDOptionalU63:
				return typOptionalU63, nil
			case t.IDBitvec256:
				return typBitvec256, nil
			case t.IDRangeIIU64:
				return typRangeIIU64, nil
			case t.IDIOReader:
				return typIOReader, nil
			case t.IDIOWriter:
				return typIOWriter, nil
			case t.IDTokenWriter:
				return typTokenWriter, nil
			case t.IDTokenReader:
				// Wuffs has no token_reader methods and no package of
				// Wuffs' standard library takes one.
				return nil, errNotYet("type %q", x.Str(g.tm))
			case t.IDPixelFormat:
				return typPixelFormat, nil
			case t.IDPixelBlend:
				return typPixelBlend, nil
			case t.IDRectIEU32:
				return typRectIEU32, nil
			case t.IDPixelSwizzler:
				return typSwizzler, nil
			}
		}
		if x.IsCPUArchType() || x.IsEtcUtilityType() {
			return nil, fmt.Errorf("cpu_arch type %q is not supported: SIMD is out of scope", x.Str(g.tm))
		}
		if bits := uintBits(qid); bits != 0 {
			base := numType(bits)
			lo, hi, err := g.refinement(x)
			if err != nil {
				return nil, err
			}
			if lo == nil {
				return base, nil
			}
			name := fmt.Sprintf("%sU%d_Range_%s_%s", prefixGen, bits, lo, hi)
			if err := g.addNamedType(name, public, fmt.Sprintf(
				"subtype %s is %s range %s .. %s;", name, base.name, lo, hi)); err != nil {
				return nil, err
			}
			return &adaType{kind: kNum, name: name, bits: bits, lo: lo, hi: hi}, nil
		}
		if qid[0] == t.IDBase {
			switch qid[1] {
			case t.IDBool:
				return typBool, nil
			case t.IDStatus:
				return typStatus, nil
			}
		}
		if qid[0] == 0 {
			if s := g.structs[qid[1]]; s != nil {
				return s.typ, nil
			}
		} else if u := g.uses[qid[0]]; u != nil {
			if s := u.structs[qid[1]]; s != nil {
				return s.typ, nil
			}
		}
		return nil, fmt.Errorf("type %q is not yet supported", x.Str(g.tm))

	case t.IDRoslice:
		if uintBits(x.Inner().QID()) == 8 && x.Inner().Decorator() == 0 && !x.Inner().IsRefined() {
			return typROSliceU8, nil
		}
		return nil, fmt.Errorf("slice type %q is not yet supported (only \"roslice base.u8\" is)", x.Str(g.tm))

	case t.IDSlice:
		if uintBits(x.Inner().QID()) == 8 && x.Inner().Decorator() == 0 && !x.Inner().IsRefined() {
			return typSliceU8, nil
		}
		return nil, fmt.Errorf("slice type %q is not yet supported (only \"slice base.u8\" is)", x.Str(g.tm))

	case t.IDNptr:
		if in := x.Inner(); in.Decorator() == 0 && in.QID()[0] == t.IDBase {
			switch in.QID()[1] {
			case t.IDImageConfig:
				return typNptrImageConfig, nil
			case t.IDFrameConfig:
				return typNptrFrameConfig, nil
			case t.IDMoreInformation:
				return typNptrMoreInfo, nil
			case t.IDDecodeFrameOptions:
				return typNptrFrameOpts, nil
			case t.IDPixelBuffer:
				return typNptrPixBuf, nil
			}
		}
		if in := x.Inner(); in.IsEitherArrayType() {
			return g.rowPtrType(x, public)
		}
		return nil, fmt.Errorf("pointer type %q is not yet supported", x.Str(g.tm))

	case t.IDPtr:
		if in := x.Inner(); in.Decorator() == 0 && in.QID() == (t.QID{t.IDBase, t.IDPixelBuffer}) {
			return typPixBuf, nil
		}
		if in := x.Inner(); in.IsEitherArrayType() {
			return g.rowPtrType(x, public)
		}
		return nil, fmt.Errorf("pointer type %q is not yet supported", x.Str(g.tm))

	case t.IDTable:
		if uintBits(x.Inner().QID()) == 8 && x.Inner().Decorator() == 0 && !x.Inner().IsRefined() {
			return typTable, nil
		}
		return nil, fmt.Errorf("table type %q is not yet supported", x.Str(g.tm))

	case t.IDArray, t.IDRoarray:
		length := x.ArrayLength().ConstValue()
		if length == nil || length.Sign() <= 0 || !length.IsInt64() {
			return nil, fmt.Errorf("bad array length in %q", x.Str(g.tm))
		}
		elem, err := g.typeOf(x.Inner(), public)
		if err != nil {
			return nil, err
		}
		last := big.NewInt(0).Sub(length, one)
		ret := &adaType{kind: kArray, elem: elem, length: length}
		switch elem.kind {
		case kNum:
			// These are constrained subtypes of the root package's array
			// types, so that (sub)arrays can be passed to the base library.
			// That loses an element type's refinement: the elements are of
			// the unrefined type.
			elem = elem.unrefined()
			ret.elem = elem
			root := map[int]string{8: "Bytes", 16: "U16_Array", 32: "U32_Array", 64: "U64_Array"}[elem.bits]
			ret.name = fmt.Sprintf("Wuffs.%s (0 .. %s)", root, last)
			return ret, nil
		case kArray, kBool:
			ret.name = prefixGen + "Array_" + length.String() + "_Of_" + arrayTypeSuffix(elem)
			if err := g.addNamedType(ret.name, public, fmt.Sprintf(
				"type %s is array (Wuffs.Index range 0 .. %s) of %s;", ret.name, last, elem.name)); err != nil {
				return nil, err
			}
			return ret, nil
		}
		return nil, fmt.Errorf("array type %q is not yet supported", x.Str(g.tm))
	}
	return nil, fmt.Errorf("type %q is not yet supported", x.Str(g.tm))
}

// rowPtrType maps "nptr roarray[N] T" (or ptr, or array) to a kRowPtr type.
func (g *gen) rowPtrType(x *a.TypeExpr, public bool) (*adaType, error) {
	arr, err := g.typeOf(x.Inner(), public)
	if err != nil {
		return nil, err
	}
	if arr.kind != kArray || arr.elem.kind != kNum {
		return nil, fmt.Errorf("pointer type %q is not yet supported", x.Str(g.tm))
	}
	return &adaType{kind: kRowPtr, name: "Wuffs.Offset", elem: arr.elem, length: arr.length}, nil
}

// refinement returns the inclusive bounds of the numeric type x, or nils if
// they are just those of its unrefined type.
func (g *gen) refinement(x *a.TypeExpr) (lo *big.Int, hi *big.Int, err error) {
	bits := uintBits(x.QID())
	if bits == 0 || x.Decorator() != 0 {
		return nil, nil, fmt.Errorf("internal error: refinement of non-numeric type %q", x.Str(g.tm))
	}
	if !x.IsRefined() {
		return nil, nil, nil
	}
	lo, hi = zero, numTypeMax(bits)
	if o := x.Min(); o != nil {
		if o.ConstValue() == nil {
			return nil, nil, fmt.Errorf("non-constant refinement in %q", x.Str(g.tm))
		}
		lo = o.ConstValue()
	}
	if o := x.Max(); o != nil {
		if o.ConstValue() == nil {
			return nil, nil, fmt.Errorf("non-constant refinement in %q", x.Str(g.tm))
		}
		hi = o.ConstValue()
	}
	if lo.Sign() < 0 || hi.Cmp(numTypeMax(bits)) > 0 || lo.Cmp(hi) > 0 {
		return nil, nil, fmt.Errorf("bad refinement in %q", x.Str(g.tm))
	}
	if lo.Sign() == 0 && hi.Cmp(numTypeMax(bits)) == 0 {
		return nil, nil, nil
	}
	return lo, hi, nil
}

// arrayTypeSuffix returns an identifier fragment that names an array type.
func arrayTypeSuffix(x *adaType) string {
	if x.kind == kArray {
		return "Array_" + x.length.String() + "_Of_" + arrayTypeSuffix(x.elem)
	}
	return strings.TrimPrefix(x.name, "Wuffs.")
}

func (g *gen) addNamedType(name string, public bool, decl string) error {
	if o := g.namedTypes[name]; o != nil {
		if o.decl != decl {
			return fmt.Errorf("internal error: inconsistent declarations of %q", name)
		}
		o.public = o.public || public
		return nil
	}
	if err := g.declareName(name, "generated type "+name); err != nil {
		return err
	}
	g.namedTypes[name] = &namedType{name: name, decl: decl, public: public, order: len(g.namedTypes)}
	return nil
}

// sortedNamedTypes returns the public or private named types, in the order
// that they were first needed (which is deterministic, and puts an array's
// element type before the array type).
func (g *gen) sortedNamedTypes(public bool) (ret []*namedType) {
	for _, o := range g.namedTypes {
		if o.public == public {
			ret = append(ret, o)
		}
	}
	sort.Slice(ret, func(i, j int) bool { return ret[i].order < ret[j].order })
	return ret
}

// numLiteral formats a non-negative constant as an Ada literal: in base 16
// (zero-padded to hexDigits digits) if hexDigits is non-zero, in base 10
// otherwise.
func numLiteral(x *big.Int, hexDigits int) string {
	if hexDigits == 0 {
		return x.String()
	}
	s := strings.ToUpper(x.Text(16))
	for len(s) < hexDigits {
		s = "0" + s
	}
	// Group the digits in fours.
	b := []byte(nil)
	for i := 0; i < len(s); i++ {
		if i != 0 && (len(s)-i)%4 == 0 {
			b = append(b, '_')
		}
		b = append(b, s[i])
	}
	return "16#" + string(b) + "#"
}

// sourceLiteral formats the constant cv, preferring the radix of the Wuffs
// source text src (if src is a numeric literal).
func sourceLiteral(cv *big.Int, src string) string {
	if cv.Sign() < 0 {
		return cv.String()
	}
	if len(src) > 2 && src[0] == '0' && (src[1] == 'x' || src[1] == 'X') {
		digits := 0
		for i := 2; i < len(src); i++ {
			if src[i] != '_' {
				digits++
			}
		}
		return numLiteral(cv, digits)
	}
	if len(src) > 0 && '0' <= src[0] && src[0] <= '9' {
		return cv.String()
	}
	// A folded constant expression.
	if cv.BitLen() > 16 {
		return numLiteral(cv, 1)
	}
	return cv.String()
}
