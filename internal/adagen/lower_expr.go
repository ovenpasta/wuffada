// Part of wuffada (wuffs-ada: Wuffs to Ada).
// SPDX-License-Identifier: Apache-2.0 OR MIT

package adagen

import (
	"fmt"
	"math/big"
	"strconv"

	a "github.com/google/wuffs/lang/ast"
	t "github.com/google/wuffs/lang/token"
)

// val is a lowered expression: Ada text plus the Ada type that it has. Ada is
// strongly typed where Wuffs (and C) are not, so every conversion between
// the modular value types and the signed Wuffs.Index is explicit, and is made
// by one of the helpers below.
type val struct {
	e   expr
	typ *adaType // nil for a call to a procedure.
	cv  *big.Int // The value, if typ is typIdeal.

	// For a kBytes or kBytesVar value, e is derived from these: arr names
	// the whole underlying Ada array object, and lo and hi (if not nil) are
	// the offsets from arr'First of the view's first element and of the
	// element after its last one. A slice handle is only ever made from arr,
	// never from the Ada slice e: see wuffs-runtime.ads.
	arr    expr
	lo, hi expr

	// zeroBased means that arr'First is known to be 0 (a constrained array).
	zeroBased bool

	// io is the argument, for a kIOReader or kIOWriter value.
	io *ioArg

	// variable means that e names an Ada variable (something assignable).
	variable bool

	// parg is the argument, for a kNptr or kPixBuf value. isNull means that
	// the value is the literal nullptr.
	parg   *argInfo
	isNull bool

	// tableArr is the array that a kTable value's offsets count in.
	tableArr *variable
}

// bin makes an eBin, flattening chains of one associative operator.
func bin(op string, args ...expr) expr {
	if isRelational(op) && len(args) == 2 {
		return rel(op, args[0], args[1])
	}
	if !isAssociative(op) {
		return eBin{op, args}
	}
	flattened := []expr(nil)
	for _, o := range args {
		if b, ok := o.(eBin); ok && b.op == op {
			flattened = append(flattened, b.args...)
		} else {
			flattened = append(flattened, o)
		}
	}
	return eBin{op, flattened}
}

// bytesToHandle makes a slice handle from an expression that names a whole
// array object. The fat pointer that 'Unrestricted_Access makes here must
// not outlive that object's bounds: see wuffs-runtime.ads.
func bytesToHandle(e expr) expr {
	return eAgg{
		names: []string{"Base", "First", "Length"},
		vals:  []expr{eAttr{e, "Unrestricted_Access"}, eAttr{e, "First"}, eAttr{e, "Length"}},
	}
}

// bytesVal makes the value for the bytes of the whole Ada array object arr,
// or for its elements at offsets lo (inclusive, nil for 0) to hi (exclusive,
// nil for the length).
func bytesVal(arr expr, lo expr, hi expr, writable bool, zeroBased bool) val {
	v := val{typ: typBytes, arr: arr, lo: lo, hi: hi, zeroBased: zeroBased}
	if writable {
		v.typ = typBytesVar
	}
	if lo == nil && hi == nil {
		v.e = arr
		return v
	}
	first, last := expr(nil), expr(nil)
	if zeroBased {
		first = raw("0")
		if lo != nil {
			first = lo
		}
		last = eAttr{arr, "Last"}
		if hi != nil {
			last = indexMinus1(hi)
		}
	} else {
		first = eAttr{arr, "First"}
		if lo != nil {
			first = bin("+", first, lo)
		}
		last = eAttr{arr, "Last"}
		if hi != nil {
			last = bin("-", bin("+", eAttr{arr, "First"}, hi), raw("1"))
		}
	}
	v.e = eSlice{arr, first, last}
	return v
}

// indexMinus1 returns e - 1, folded if e is a decimal literal.
func indexMinus1(e expr) expr {
	if r, ok := e.(eRaw); ok {
		if n, err := strconv.ParseInt(r.s, 10, 64); err == nil {
			return raw(strconv.FormatInt(n-1, 10))
		}
	}
	return bin("-", e, raw("1"))
}

// markWritten records that something may write to the variable that the
// name e is a part of, in a way that the IR does not show (it is passed as
// an "in out" parameter, or a writable handle is made from it).
func markWritten(e expr) {
	if e == nil {
		return
	}
	if v := rootVariable(e); v != nil {
		v.writes++
	}
}

// toHandle converts a slice-typed value to a slice handle: a writable one
// (Slice_U8) or a read-only one (RO_Slice_U8).
func (l *lowerer) toHandle(v val, writable bool) (val, error) {
	want := typROSliceU8
	if writable {
		want = typSliceU8
	}
	switch v.typ.kind {
	case kROSliceU8:
		if writable {
			return val{}, fmt.Errorf("a read-only slice where a writable one is needed")
		}
		return v, nil
	case kSliceU8:
		if !writable {
			return val{e: call("Wuffs.Runtime.To_RO", v.e), typ: want}, nil
		}
		return v, nil
	case kBytes, kBytesVar:
		if writable && v.typ.kind == kBytes {
			return val{}, fmt.Errorf("a read-only slice where a writable one is needed")
		}
		if writable {
			markWritten(v.arr)
		}
		h := bytesToHandle(v.arr)
		switch {
		case v.lo == nil && v.hi == nil:
			// No-op.
		case v.hi == nil:
			h = call("Wuffs.Runtime.Subslice_I", h, v.lo)
		case v.lo == nil:
			h = call("Wuffs.Runtime.Subslice_J", h, v.hi)
		default:
			h = callNamed("Wuffs.Runtime.Subslice_IJ", "S", h, "I", v.lo, "J", v.hi)
		}
		return val{e: h, typ: want}, nil
	}
	return val{}, fmt.Errorf("internal error: toHandle of a non-slice")
}

// toBytes converts a slice-typed value to an Ada array (a view, not a copy),
// to pass it as a parameter.
func (l *lowerer) toBytes(v val, writable bool) (val, error) {
	want := typBytes
	if writable {
		want = typBytesVar
	}
	switch v.typ.kind {
	case kBytes, kBytesVar:
		if writable && v.typ.kind == kBytes {
			return val{}, fmt.Errorf("a read-only slice where a writable one is needed")
		}
		if writable {
			markWritten(v.arr)
		}
		return v, nil
	case kROSliceU8, kSliceU8:
		if writable && v.typ.kind == kROSliceU8 {
			return val{}, fmt.Errorf("a read-only slice where a writable one is needed")
		}
		h := v.e
		if _, ok := h.(eVar); !ok {
			// The handle is used three times below. Evaluate it once.
			tmp := eVar{l.newTemp(v.typ)}
			l.pre = append(l.pre, sAssign{tmp, h})
			h = tmp
		}
		return val{
			e:   eSlice{eSel{h, "Base"}, eSel{h, "First"}, call("Wuffs.Runtime.Last", h)},
			typ: want,
		}, nil
	}
	return val{}, fmt.Errorf("internal error: toBytes of a non-slice")
}

// toIndex converts a numeric value to a Wuffs.Index.
func (l *lowerer) toIndex(v val, n *a.Expr) (expr, error) {
	switch v.typ.kind {
	case kIdeal, kIndex:
		return v.e, nil
	case kNum:
		return call("Wuffs.Index", v.e), nil
	}
	return nil, fmt.Errorf("index %q is not numeric", n.Str(l.g.tm))
}

func (l *lowerer) index(n *a.Expr) (expr, error) {
	v, err := l.expr(n)
	if err != nil {
		return nil, err
	}
	if v.typ == nil {
		return nil, fmt.Errorf("%q has no value", n.Str(l.g.tm))
	}
	return l.toIndex(v, n)
}

// constant lowers an expression that has a constant value.
func (l *lowerer) constant(n *a.Expr, cv *big.Int) (val, error) {
	typ := n.MType()
	switch {
	case typ.IsNullptr():
		return val{typ: &adaType{kind: kNptr}, isNull: true}, nil
	case typ.IsNumTypeOrIdeal():
		if cv.Sign() < 0 {
			return val{}, errNotYet("negative constant %q", n.Str(l.g.tm))
		}
		src := ""
		if n.Operator() == 0 {
			src = n.Ident().Str(l.g.tm)
		}
		return val{e: raw(sourceLiteral(cv, src)), typ: typIdeal, cv: cv}, nil
	case typ.IsBool():
		if cv.Sign() == 0 {
			return val{e: raw("False"), typ: typBool}, nil
		} else if cv.Cmp(one) == 0 {
			return val{e: raw("True"), typ: typBool}, nil
		}
	case typ.IsStatus():
		return val{e: raw("Wuffs.Ok_Status"), typ: typStatus}, nil
	}
	return val{}, fmt.Errorf("cannot generate Ada for the constant %q of type %q", n.Str(l.g.tm), typ.Str(l.g.tm))
}

func (l *lowerer) baseStatus(id t.ID) (val, error) {
	msg, ok := t.Unescape(id.Str(l.g.tm))
	if !ok {
		return val{}, fmt.Errorf("bad status %s", id.Str(l.g.tm))
	}
	name, err := baseStatusName(msg)
	if err != nil {
		return val{}, err
	}
	return val{e: raw(basePkg + "." + name), typ: typStatus}, nil
}

// expr lowers an expression.
func (l *lowerer) expr(n *a.Expr) (val, error) {
	// A reference to a named constant stays a reference, for readability,
	// where the C back-end substitutes the value.
	if n.Operator() == 0 && l.locals[n.Ident()] == nil {
		if c := l.g.consts[n.Ident()]; c != nil {
			c.used = true
			return val{e: raw(c.name), typ: c.typ}, nil
		}
	}
	if cv := n.ConstValue(); cv != nil {
		return l.constant(n, cv)
	}

	switch op := n.Operator(); {
	case op.IsXUnaryOp():
		return l.unaryOp(n)
	case op.IsXBinaryOp():
		return l.binaryOp(n)
	case op.IsXAssociativeOp():
		return l.associativeOp(n)
	}

	switch n.Operator() {
	case 0:
		id := n.Ident()
		if io := l.bound[id]; io != nil {
			typ := typIOReader
			if io.writer {
				typ = typIOWriter
			}
			return val{typ: typ, io: io}, nil
		}
		if l.ioLocals[id] {
			return val{}, fmt.Errorf("the I/O variable %q is used outside of an io_bind block", n.Str(l.g.tm))
		}
		if v := l.locals[id]; v != nil {
			return val{e: eVar{v}, typ: v.typ, variable: true, tableArr: l.tableOf[v]}, nil
		}
		if id.IsDQStrLiteral(l.g.tm) {
			if z := l.g.statuses[id]; z != nil {
				return val{e: raw(z.name), typ: typStatus}, nil
			}
			return val{}, fmt.Errorf("unrecognized status %s", n.Str(l.g.tm))
		}
		switch id {
		case t.IDNullptr:
			return val{typ: &adaType{kind: kNptr}, isNull: true}, nil
		case t.IDThis:
			return val{e: eVar{l.f.self}, typ: l.fi.recv.typ, variable: l.f.selfInOut}, nil
		case t.IDCoroutineResumed:
			// C: (self->private_impl.p_func != 0), the stored suspension
			// point, which is only reset when the coroutine completes.
			if !l.fi.coroutine {
				return val{e: raw("False"), typ: typBool}, nil
			}
			l.g.useType[32] = true
			return val{e: bin("/=", l.pField(), raw("0")), typ: typBool}, nil
		}
		return val{}, fmt.Errorf("unrecognized identifier %q", n.Str(l.g.tm))

	case a.ExprOperatorCall:
		return l.call(n)

	case t.IDOpenBracket:
		lhs := n.LHS().AsExpr()
		lv, err := l.expr(lhs)
		if err != nil {
			return val{}, err
		}
		if lv.typ == nil {
			return val{}, fmt.Errorf("%q has no value", lhs.Str(l.g.tm))
		}
		i, err := l.index(n.RHS().AsExpr())
		if err != nil {
			return val{}, err
		}
		switch lv.typ.kind {
		case kArray:
			return val{e: eCall{lv.e, []expr{i}}, typ: lv.typ.elem, variable: lv.variable}, nil
		case kROSliceU8, kSliceU8:
			return val{e: call("Wuffs.Runtime.Get", lv.e, i), typ: typU8}, nil
		case kBytes, kBytesVar:
			if lv.lo == nil && lv.hi == nil {
				// The whole Ada array: its own bounds are the slice's.
				if !lv.zeroBased {
					i = bin("+", eAttr{lv.arr, "First"}, i)
				}
				return val{e: eCall{lv.arr, []expr{i}}, typ: typU8}, nil
			}
			h, err := l.toHandle(lv, false)
			if err != nil {
				return val{}, err
			}
			return val{e: call("Wuffs.Runtime.Get", h.e, i), typ: typU8}, nil
		}
		return val{}, errNotYet("indexing %q, of type %q", lhs.Str(l.g.tm), lhs.MType().Str(l.g.tm))

	case t.IDDotDot:
		lhs := n.LHS().AsExpr()
		lv, err := l.expr(lhs)
		if err != nil {
			return val{}, err
		}
		if lv.typ == nil {
			return val{}, fmt.Errorf("%q has no value", lhs.Str(l.g.tm))
		}
		mhs, rhs := n.MHS().AsExpr(), n.RHS().AsExpr()
		i, j := expr(nil), expr(nil)
		if mhs != nil {
			if i, err = l.index(mhs); err != nil {
				return val{}, err
			}
		}
		if rhs != nil {
			if j, err = l.index(rhs); err != nil {
				return val{}, err
			}
		}
		switch lv.typ.kind {
		case kArray:
			// A slice of an array of bytes is an Ada slice of it (or, if it
			// has to become a handle, a part of the whole array).
			if lv.typ.elem.kind != kNum || lv.typ.elem.bits != 8 {
				return val{}, errNotYet("slicing %q, of type %q", lhs.Str(l.g.tm), lhs.MType().Str(l.g.tm))
			}
			return bytesVal(lv.e, i, j, lv.variable, true), nil
		case kBytes, kBytesVar:
			if lv.lo == nil && lv.hi == nil {
				return bytesVal(lv.arr, i, j, lv.typ.kind == kBytesVar, lv.zeroBased), nil
			}
		case kROSliceU8, kSliceU8:
			// Handled below.
		default:
			return val{}, errNotYet("slicing %q, of type %q", lhs.Str(l.g.tm), lhs.MType().Str(l.g.tm))
		}
		if mhs == nil && rhs == nil {
			return lv, nil
		}
		writable := lv.typ.kind == kSliceU8 || lv.typ.kind == kBytesVar
		if lv, err = l.toHandle(lv, writable); err != nil {
			return val{}, err
		}
		switch {
		case rhs == nil:
			return val{e: call("Wuffs.Runtime.Subslice_I", lv.e, i), typ: lv.typ}, nil
		case mhs == nil:
			return val{e: call("Wuffs.Runtime.Subslice_J", lv.e, j), typ: lv.typ}, nil
		}
		return val{e: callNamed("Wuffs.Runtime.Subslice_IJ", "S", lv.e, "I", i, "J", j), typ: lv.typ}, nil

	case t.IDDot:
		lhs := n.LHS().AsExpr()
		if lhs.Operator() == 0 {
			switch lhs.Ident() {
			case t.IDArgs:
				if arg := l.ptrs[n.Ident()]; arg != nil {
					return val{e: eVar{arg.v}, typ: arg.typ, parg: arg}, nil
				}
				if io := l.ios[n.Ident()]; io != nil {
					typ := typIOReader
					if io.writer {
						typ = typIOWriter
					}
					return val{typ: typ, io: io}, nil
				}
				if v := l.args[n.Ident()]; v != nil {
					switch v.typ.kind {
					case kBytes, kBytesVar:
						return bytesVal(eVar{v}, nil, nil, v.typ.kind == kBytesVar, false), nil
					}
					return val{e: eVar{v}, typ: v.typ, variable: v.kind == varLocal}, nil
				}
				return val{}, fmt.Errorf("unrecognized argument %q", n.Str(l.g.tm))
			case t.IDThis:
				if f := l.fi.recv.field(n.Ident()); f != nil {
					if f.typ.kind == kUtility {
						return val{typ: typUtility}, nil
					}
					return val{e: eSel{eVar{l.f.self}, f.name}, typ: f.typ, variable: l.f.selfInOut}, nil
				}
				return val{}, fmt.Errorf("unrecognized field %q", n.Str(l.g.tm))
			}
			if n.Ident().IsDQStrLiteral(l.g.tm) {
				if lhs.Ident() == t.IDBase {
					return l.baseStatus(n.Ident())
				}
				return val{}, errNotYet("status %s of another package", n.Str(l.g.tm))
			}
		}
		return val{}, errNotYet("selector expression %q", n.Str(l.g.tm))
	}
	return val{}, fmt.Errorf("unrecognized expression %q (operator 0x%X)", n.Str(l.g.tm), uint32(n.Operator()))
}

func (l *lowerer) unaryOp(n *a.Expr) (val, error) {
	rhs := n.RHS().AsExpr()
	if n.Operator() != t.IDXUnaryNot {
		return val{}, errNotYet("unary operator in %q", n.Str(l.g.tm))
	}
	v, err := l.expr(rhs)
	if err != nil {
		return val{}, err
	}
	if v.typ == nil || v.typ.kind != kBool {
		return val{}, fmt.Errorf("operand of \"not\" in %q is not a bool", n.Str(l.g.tm))
	}
	return val{e: eUn{"not", v.e}, typ: typBool}, nil
}

var comparisonOps = map[t.ID]string{
	t.IDXBinaryNotEq:       "/=",
	t.IDXBinaryLessThan:    "<",
	t.IDXBinaryLessEq:      "<=",
	t.IDXBinaryEqEq:        "=",
	t.IDXBinaryGreaterEq:   ">=",
	t.IDXBinaryGreaterThan: ">",
}

// numOps maps the Wuffs operators whose Ada equivalent is an operator of the
// modular types. Wuffs' checked "+", "-" and "*" have been proved not to
// overflow by the Wuffs compiler, so the wrapping Ada operators compute the
// same values.
var numOps = map[t.ID]string{
	t.IDXBinaryPlus:          "+",
	t.IDXBinaryMinus:         "-",
	t.IDXBinaryStar:          "*",
	t.IDXBinarySlash:         "/",
	t.IDXBinaryPercent:       "mod",
	t.IDXBinaryAmp:           "and",
	t.IDXBinaryPipe:          "or",
	t.IDXBinaryHat:           "xor",
	t.IDXBinaryTildeModPlus:  "+",
	t.IDXBinaryTildeModMinus: "-",
	t.IDXBinaryTildeModStar:  "*",
	t.IDXAssociativePlus:     "+",
	t.IDXAssociativeStar:     "*",
	t.IDXAssociativeAmp:      "and",
	t.IDXAssociativePipe:     "or",
	t.IDXAssociativeHat:      "xor",
}

func (l *lowerer) operands(n *a.Expr, nodes ...*a.Node) ([]val, error) {
	ret := []val(nil)
	for _, o := range nodes {
		v, err := l.expr(o.AsExpr())
		if err != nil {
			return nil, err
		}
		if v.typ == nil {
			return nil, fmt.Errorf("operand %q of %q has no value", o.AsExpr().Str(l.g.tm), n.Str(l.g.tm))
		}
		ret = append(ret, v)
	}
	return ret, nil
}

// checkNum checks that v can be an operand of an operator of the bits-wide
// modular type.
func checkNum(v val, bits int) error {
	if v.typ.kind == kIdeal || (v.typ.kind == kNum && v.typ.bits == bits) {
		return nil
	}
	return fmt.Errorf("operand %q is not a %d-bit unsigned integer", flat(v.e), bits)
}

// infoOf returns what a comparison can know about the operand v.
func infoOf(v val) operandInfo {
	switch v.typ.kind {
	case kIdeal:
		return operandInfo{lit: v.cv}
	case kNum:
		if v.typ.lo != nil {
			return operandInfo{lo: v.typ.lo, hi: v.typ.hi}
		}
		return operandInfo{lo: zero, hi: numTypeMax(v.typ.bits)}
	}
	return operandInfo{}
}

func (l *lowerer) binaryOp(n *a.Expr) (val, error) {
	op := n.Operator()
	if op == t.IDXBinaryAs {
		return l.as(n)
	}
	vs, err := l.operands(n, n.LHS(), n.RHS())
	if err != nil {
		return val{}, err
	}
	lv, rv := vs[0], vs[1]

	if adaOp, ok := comparisonOps[op]; ok {
		// "p == nullptr" and "p <> nullptr" test the pointer's null flag.
		if lv.typ.kind == kNptr || rv.typ.kind == kNptr {
			p := lv
			if lv.isNull {
				p = rv
			}
			if lv.isNull == rv.isNull || p.parg == nil || p.parg.null == nil || (adaOp != "=" && adaOp != "/=") {
				return val{}, errNotYet("comparison %q", n.Str(l.g.tm))
			}
			null := expr(eVar{p.parg.null})
			if adaOp == "/=" {
				null = eUn{"not", null}
			}
			return val{e: null, typ: typBool}, nil
		}
		switch {
		case lv.typ.kind == kNum:
			if err := checkNum(rv, lv.typ.bits); err != nil {
				return val{}, fmt.Errorf("%q: %v", n.Str(l.g.tm), err)
			}
			l.g.useType[lv.typ.bits] = true
		case rv.typ.kind == kNum:
			if err := checkNum(lv, rv.typ.bits); err != nil {
				return val{}, fmt.Errorf("%q: %v", n.Str(l.g.tm), err)
			}
			l.g.useType[rv.typ.bits] = true
		case lv.typ.kind == kStatus && rv.typ.kind == kStatus && (adaOp == "=" || adaOp == "/="):
			// No-op: Wuffs.Status' operators are directly visible in a child
			// of package Wuffs. (The Wuffs compiler rejects comparing bools.)
		default:
			return val{}, errNotYet("comparison %q", n.Str(l.g.tm))
		}
		return val{e: eRel{op: adaOp, l: lv.e, r: rv.e, li: infoOf(lv), ri: infoOf(rv)}, typ: typBool}, nil
	}

	switch op {
	case t.IDXBinaryAnd, t.IDXBinaryOr:
		if lv.typ.kind != kBool || rv.typ.kind != kBool {
			return val{}, fmt.Errorf("operands of %q are not bools", n.Str(l.g.tm))
		}
		// Short-circuit, as the C back-end's "&&" and "||" do. (Wuffs
		// expressions have no side effects and the Wuffs compiler proves each
		// operand safe on its own, so this only affects what is evaluated.)
		adaOp := "and then"
		if op == t.IDXBinaryOr {
			adaOp = "or else"
		}
		return val{e: bin(adaOp, lv.e, rv.e), typ: typBool}, nil
	}

	bits := uintBits(n.MType().Unrefined().QID())
	if bits == 0 {
		return val{}, errNotYet("operator in %q, of type %q", n.Str(l.g.tm), n.MType().Str(l.g.tm))
	}
	ret, err := l.numBinaryOp(op, lv, rv, bits)
	if err != nil {
		return val{}, fmt.Errorf("%q: %v", n.Str(l.g.tm), err)
	}
	return ret, nil
}

// numBinaryOp lowers "lv op rv", whose result is the bits-wide modular type.
func (l *lowerer) numBinaryOp(op t.ID, lv val, rv val, bits int) (val, error) {
	typ := numType(bits)
	if err := checkNum(lv, bits); err != nil {
		return val{}, err
	}

	switch op {
	case t.IDXBinaryShiftL, t.IDXBinaryShiftR, t.IDXBinaryTildeModShiftL:
		// Wuffs' "<<" has been proved not to overflow, so it and "~mod<<"
		// are both Shift_Left, which discards the bits shifted out.
		amount := expr(nil)
		switch rv.typ.kind {
		case kIdeal:
			if rv.cv.Sign() == 0 && lv.typ.kind != kIdeal {
				return val{e: lv.e, typ: typ}, nil
			}
			amount = rv.e
		case kNum:
			amount = call("Natural", rv.e)
		default:
			return val{}, fmt.Errorf("shift amount is not numeric")
		}
		x := lv.e
		if lv.typ.kind == kIdeal {
			// Shift_Left etc are overloaded, so a literal is ambiguous.
			x = eQual{typ.name, x}
		}
		fn := "Interfaces.Shift_Left"
		if op == t.IDXBinaryShiftR {
			fn = "Interfaces.Shift_Right"
		}
		return val{e: call(fn, x, amount), typ: typ}, nil
	}

	if err := checkNum(rv, bits); err != nil {
		return val{}, err
	}
	if lv.typ.kind == kIdeal && rv.typ.kind == kIdeal {
		return val{}, fmt.Errorf("internal error: operator applied to two constants")
	}

	switch op {
	case t.IDXBinaryTildeSatPlus:
		return val{e: callNamed(fmt.Sprintf("%s.Sat_Add_U%d", intsPkg, bits), "X", lv.e, "Y", rv.e), typ: typ}, nil
	case t.IDXBinaryTildeSatMinus:
		return val{e: callNamed(fmt.Sprintf("%s.Sat_Sub_U%d", intsPkg, bits), "X", lv.e, "Y", rv.e), typ: typ}, nil
	}
	if adaOp, ok := numOps[op]; ok {
		l.g.useType[bits] = true
		return val{e: bin(adaOp, lv.e, rv.e), typ: typ}, nil
	}
	return val{}, fmt.Errorf("unrecognized operator %q", op.AmbiguousForm().Str(l.g.tm))
}

func (l *lowerer) associativeOp(n *a.Expr) (val, error) {
	op := n.Operator()
	vs, err := l.operands(n, n.Args()...)
	if err != nil {
		return val{}, err
	}
	es := []expr(nil)
	for _, v := range vs {
		es = append(es, v.e)
	}

	switch op {
	case t.IDXAssociativeAnd, t.IDXAssociativeOr:
		for _, v := range vs {
			if v.typ.kind != kBool {
				return val{}, fmt.Errorf("operands of %q are not bools", n.Str(l.g.tm))
			}
		}
		adaOp := "and then"
		if op == t.IDXAssociativeOr {
			adaOp = "or else"
		}
		return val{e: bin(adaOp, es...), typ: typBool}, nil
	}

	adaOp, ok := numOps[op]
	bits := uintBits(n.MType().Unrefined().QID())
	if !ok || bits == 0 {
		return val{}, errNotYet("operator in %q, of type %q", n.Str(l.g.tm), n.MType().Str(l.g.tm))
	}
	allIdeal := true
	for _, v := range vs {
		if err := checkNum(v, bits); err != nil {
			return val{}, fmt.Errorf("%q: %v", n.Str(l.g.tm), err)
		}
		allIdeal = allIdeal && v.typ.kind == kIdeal
	}
	if allIdeal {
		return val{}, fmt.Errorf("internal error: operator applied to only constants in %q", n.Str(l.g.tm))
	}
	l.g.useType[bits] = true
	return val{e: bin(adaOp, es...), typ: numType(bits)}, nil
}

// as lowers a conversion between numeric types. A narrowing conversion is
// range-checked by Ada (in the checked profile); the Wuffs compiler has
// proved that the check passes.
func (l *lowerer) as(n *a.Expr) (val, error) {
	lhs, rhs := n.LHS().AsExpr(), n.RHS().AsTypeExpr()
	bits := uintBits(rhs.QID())
	if rhs.Decorator() != 0 || bits == 0 {
		return val{}, errNotYet("conversion %q", n.Str(l.g.tm))
	}
	lv, err := l.expr(lhs)
	if err != nil {
		return val{}, err
	}
	typ := numType(bits)
	switch {
	case lv.typ == nil:
		// Fall through.
	case lv.typ.kind == kIdeal:
		return val{e: eQual{typ.name, lv.e}, typ: typ}, nil
	case lv.typ.kind == kNum && lv.typ.bits == bits:
		return val{e: lv.e, typ: typ}, nil
	case lv.typ.kind == kNum:
		return val{e: call(typ.name, lv.e), typ: typ}, nil
	}
	return val{}, errNotYet("conversion %q", n.Str(l.g.tm))
}
