// Part of wuffada (wuffs-ada: Wuffs to Ada).
// SPDX-License-Identifier: Apache-2.0 OR MIT

package adagen

import (
	"fmt"
	"math/big"

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
}

// bin makes an eBin, flattening chains of one associative operator.
func bin(op string, args ...expr) expr {
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
// Wuffs.Bytes object. The fat pointer that 'Unrestricted_Access makes here
// must not outlive that object's bounds: see wuffs-runtime.ads.
func bytesToHandle(e expr) expr {
	return eAgg{
		names: []string{"Base", "First", "Length"},
		vals:  []expr{eAttr{e, "Unrestricted_Access"}, eAttr{e, "First"}, eAttr{e, "Length"}},
	}
}

// toHandle converts a slice-typed value to a slice handle.
func (l *lowerer) toHandle(v val) (val, error) {
	switch v.typ.kind {
	case kROSliceU8:
		return v, nil
	case kBytes:
		return val{e: bytesToHandle(v.e), typ: typROSliceU8}, nil
	}
	return val{}, fmt.Errorf("internal error: toHandle of a non-slice")
}

// toBytes converts a slice-typed value to an Ada array (a view, not a copy),
// to pass it as a parameter.
func (l *lowerer) toBytes(v val) (val, error) {
	switch v.typ.kind {
	case kBytes:
		return v, nil
	case kROSliceU8:
		h := v.e
		if _, ok := h.(eVar); !ok {
			// The handle is used three times below. Evaluate it once.
			l.nTemps++
			tmp := eVar{l.newLocal(fmt.Sprintf("%sT%d", prefixGen, l.nTemps), typROSliceU8, nil)}
			l.pre = append(l.pre, sAssign{tmp, h})
			h = tmp
		}
		return val{
			e:   eSlice{eSel{h, "Base"}, eSel{h, "First"}, call("Wuffs.Runtime.Last", h)},
			typ: typBytes,
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
	name, err := mangleMessage(msg)
	if err != nil {
		return val{}, err
	}
	return val{e: raw(l.g.basePkg + "." + name), typ: typStatus}, nil
}

// expr lowers an expression.
func (l *lowerer) expr(n *a.Expr) (val, error) {
	// A reference to a named constant stays a reference, for readability,
	// where the C back-end substitutes the value.
	if n.Operator() == 0 && l.locals[n.Ident()] == nil {
		if c := l.g.consts[n.Ident()]; c != nil {
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
		if v := l.locals[id]; v != nil {
			return val{e: eVar{v}, typ: v.typ}, nil
		}
		if id.IsDQStrLiteral(l.g.tm) {
			if z := l.g.statuses[id]; z != nil {
				return val{e: raw(z.name), typ: typStatus}, nil
			}
			return val{}, fmt.Errorf("unrecognized status %s", n.Str(l.g.tm))
		}
		switch id {
		case t.IDThis:
			return val{}, errNotYet("\"this\" other than as \"this.field\" or \"this.method(etc)\"")
		case t.IDCoroutineResumed:
			return val{}, errNotYet("coroutine_resumed")
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
			return val{e: eCall{lv.e, []expr{i}}, typ: lv.typ.elem}, nil
		case kROSliceU8:
			return val{e: call("Wuffs.Runtime.Get", lv.e, i), typ: typU8}, nil
		case kBytes:
			return val{e: eCall{lv.e, []expr{bin("+", eAttr{lv.e, "First"}, i)}}, typ: typU8}, nil
		}
		return val{}, errNotYet("indexing %q, of type %q", lhs.Str(l.g.tm), lhs.MType().Str(l.g.tm))

	case t.IDDotDot:
		lhs := n.LHS().AsExpr()
		if !lhs.MType().IsEitherSliceType() {
			return val{}, errNotYet("slicing %q, of type %q", lhs.Str(l.g.tm), lhs.MType().Str(l.g.tm))
		}
		lv, err := l.expr(lhs)
		if err != nil {
			return val{}, err
		}
		if lv.typ == nil {
			return val{}, fmt.Errorf("%q has no value", lhs.Str(l.g.tm))
		}
		mhs, rhs := n.MHS().AsExpr(), n.RHS().AsExpr()
		if mhs == nil && rhs == nil {
			return lv, nil
		}
		if lv, err = l.toHandle(lv); err != nil {
			return val{}, err
		}
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
		switch {
		case rhs == nil:
			return val{e: call("Wuffs.Runtime.Subslice_I", lv.e, i), typ: typROSliceU8}, nil
		case mhs == nil:
			return val{e: call("Wuffs.Runtime.Subslice_J", lv.e, j), typ: typROSliceU8}, nil
		}
		return val{e: callNamed("Wuffs.Runtime.Subslice_IJ", "S", lv.e, "I", i, "J", j), typ: typROSliceU8}, nil

	case t.IDDot:
		lhs := n.LHS().AsExpr()
		if lhs.Operator() == 0 {
			switch lhs.Ident() {
			case t.IDArgs:
				if v := l.args[n.Ident()]; v != nil {
					return val{e: eVar{v}, typ: v.typ}, nil
				}
				return val{}, fmt.Errorf("unrecognized argument %q", n.Str(l.g.tm))
			case t.IDThis:
				if f := l.fi.recv.field(n.Ident()); f != nil {
					return val{e: eSel{eVar{l.f.self}, f.name}, typ: f.typ}, nil
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
		return val{e: bin(adaOp, lv.e, rv.e), typ: typBool}, nil
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
		return val{e: callNamed(fmt.Sprintf("%s.Sat_Add_U%d", l.g.basePkg, bits), "X", lv.e, "Y", rv.e), typ: typ}, nil
	case t.IDXBinaryTildeSatMinus:
		return val{e: callNamed(fmt.Sprintf("%s.Sat_Sub_U%d", l.g.basePkg, bits), "X", lv.e, "Y", rv.e), typ: typ}, nil
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

// call lowers a method call.
func (l *lowerer) call(n *a.Expr) (val, error) {
	if n.Effect().Coroutine() {
		return val{}, errNotYet("coroutine call %q", n.Str(l.g.tm))
	}
	method := n.LHS().AsExpr()
	recv := method.LHS().AsExpr()
	recvTyp := recv.MType()
	args := n.Args()

	if recv.Operator() == 0 && recv.Ident() == t.IDThis {
		return l.userCall(n, method.Ident(), args)
	}

	switch {
	case recvTyp.IsEitherSliceType():
		if method.Ident() != t.IDLength || len(args) != 0 {
			break
		}
		rv, err := l.expr(recv)
		if err != nil {
			return val{}, err
		}
		switch rv.typ.kind {
		case kBytes:
			return val{e: call("Wuffs.U64", eAttr{rv.e, "Length"}), typ: typU64}, nil
		case kROSliceU8:
			return val{e: call("Wuffs.U64", eSel{rv.e, "Length"}), typ: typU64}, nil
		}

	case recvTyp.Decorator() == 0 && uintBits(recvTyp.QID()) != 0:
		bits := uintBits(recvTyp.QID())
		if (method.Ident() != t.IDLowBits && method.Ident() != t.IDHighBits) || len(args) != 1 {
			break
		}
		cv := args[0].AsArg().Value().ConstValue()
		if cv == nil || cv.Sign() < 0 || cv.Cmp(big.NewInt(int64(bits))) > 0 {
			return val{}, errNotYet("%q with a non-constant argument", n.Str(l.g.tm))
		}
		rv, err := l.expr(recv)
		if err != nil {
			return val{}, err
		}
		if rv.typ == nil || rv.typ.kind != kNum {
			// A constant receiver would have made the whole call constant.
			return val{}, errNotYet("%q", n.Str(l.g.tm))
		}
		nBits := int(cv.Int64())
		if method.Ident() == t.IDLowBits {
			// C: ((recv) & mask).
			mask := big.NewInt(1)
			mask.Lsh(mask, uint(nBits))
			mask.Sub(mask, one)
			l.g.useType[bits] = true
			return val{e: bin("and", rv.e, raw(numLiteral(mask, 1))), typ: numType(bits)}, nil
		}
		// C: ((recv) >> (8*sizeof(recv) - (n))). In Ada, as in Wuffs but
		// unlike C, shifting by the full width is well defined, giving zero.
		return val{
			e:   call("Interfaces.Shift_Right", rv.e, raw(fmt.Sprint(bits-nBits))),
			typ: numType(bits),
		}, nil
	}
	return val{}, errNotYet("method call %q on a receiver of type %q", n.Str(l.g.tm), recvTyp.Str(l.g.tm))
}

// userCall lowers a call of a method of the current function's receiver.
func (l *lowerer) userCall(n *a.Expr, method t.ID, args []*a.Node) (val, error) {
	recv := l.fi.ast.Receiver()
	callee := l.g.funcs[t.QQID{recv[0], recv[1], method}]
	if callee == nil {
		return val{}, errNotYet("method call %q", n.Str(l.g.tm))
	}
	if callee.skipped {
		return val{}, fmt.Errorf("call %q of a function that was skipped as it needs a cpu_arch capability", n.Str(l.g.tm))
	}
	f := callee.ir
	if len(args) != len(f.params) {
		return val{}, fmt.Errorf("call %q: wrong number of arguments", n.Str(l.g.tm))
	}

	es := []expr{eVar{l.f.self}}
	if f.selfInOut {
		if !l.f.selfInOut {
			return val{}, fmt.Errorf("call %q of an impure function from a pure function", n.Str(l.g.tm))
		}
		l.f.self.writes++
	}
	for i, o := range args {
		arg := o.AsArg().Value()
		v, err := l.expr(arg)
		if err != nil {
			return val{}, err
		}
		if v.typ == nil {
			return val{}, fmt.Errorf("argument %q has no value", arg.Str(l.g.tm))
		}
		want := f.params[i].typ
		switch want.kind {
		case kBytes:
			if v.typ.kind != kBytes && v.typ.kind != kROSliceU8 {
				return val{}, fmt.Errorf("argument %q is not a slice", arg.Str(l.g.tm))
			}
			if v, err = l.toBytes(v); err != nil {
				return val{}, err
			}
		case kNum:
			if err := checkNum(v, want.bits); err != nil {
				return val{}, fmt.Errorf("argument %q: %v", arg.Str(l.g.tm), err)
			}
		case kBool, kStatus:
			if v.typ.kind != want.kind {
				return val{}, fmt.Errorf("argument %q has the wrong type", arg.Str(l.g.tm))
			}
		default:
			return val{}, fmt.Errorf("internal error: unexpected parameter type")
		}
		es = append(es, v.e)
	}
	ret := val{e: eCall{eRaw{f.name}, es}}
	if f.ret != nil {
		ret.typ = f.ret
	}
	return ret, nil
}
