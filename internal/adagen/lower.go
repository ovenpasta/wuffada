// Part of wuffada (wuffs-ada: Wuffs to Ada).
// SPDX-License-Identifier: Apache-2.0 OR MIT

package adagen

import (
	"fmt"
	"math/big"
	"strconv"
	"strings"

	a "github.com/google/wuffs/lang/ast"
	t "github.com/google/wuffs/lang/token"
)

// This file lowers a function's Wuffs AST to IR: declarations and
// statements. lower_expr.go lowers expressions.

const (
	rtMagicInitialized = "Wuffs.Runtime.Magic_Initialized"
	rtMagicDisabled    = "Wuffs.Runtime.Magic_Disabled"
)

type loopInfo struct {
	name          string // The Ada loop name, if anything exits it by name.
	continueLabel string
	isIterate     bool
}

// lowerer lowers one function.
type lowerer struct {
	g  *gen
	fi *funcInfo
	f  *fn

	locals map[t.ID]*variable
	args   map[t.ID]*variable // What "args.foo" denotes: a parameter or its mutable copy.
	loops  map[a.Loop]*loopInfo

	// pre holds statements that must run before the statement that is
	// currently being lowered: they assign temporaries that its expressions
	// use.
	pre []stmt

	nLoops, nIterates, nTemps int
}

func (g *gen) lowerFunc(fi *funcInfo) error {
	l := &lowerer{
		g:      g,
		fi:     fi,
		f:      fi.ir,
		locals: map[t.ID]*variable{},
		args:   map[t.ID]*variable{},
		loops:  map[a.Loop]*loopInfo{},
	}
	n := fi.ast

	if err := l.declareArgs(); err != nil {
		return err
	}
	if err := l.declareLocals(); err != nil {
		return err
	}

	if l.f.public {
		if err := l.prologue(); err != nil {
			return err
		}
	}
	body, err := l.block(n.Body())
	if err != nil {
		return err
	}
	l.f.body = append(l.f.body, body...)

	if l.f.ret != nil && !a.Terminates(n.Body()) {
		// Upstream accepts a body that ends with a return, or with an
		// if-else chain or a "while true" loop (without a break) that cannot
		// fall through: ast.Terminates.
		return fmt.Errorf("body of a function with a return type can fall off its end")
	}
	return nil
}

func (l *lowerer) newLocal(name string, typ *adaType, init expr) *variable {
	v := &variable{kind: varLocal, name: name, typ: typ, decl: typ.name, init: init}
	l.f.locals = append(l.f.locals, v)
	return v
}

// declareArgs fills in l.args. A parameter that the body assigns to gets a
// local, mutable copy, since Ada "in" parameters are constants. For a slice,
// that copy is a slice handle, and the parameter stays a plain array.
func (l *lowerer) declareArgs() error {
	assigned := map[t.ID]bool{}
	if err := l.walkBody(func(o *a.Node) error {
		if o.Kind() == a.KAssign {
			if lhs := o.AsAssign().LHS(); lhs != nil {
				for ; lhs != nil; lhs = lhsBase(lhs) {
					if foo := lhs.IsArgsDotFoo(); foo != 0 {
						assigned[foo] = true
					}
				}
			}
		}
		return nil
	}); err != nil {
		return err
	}

	for i, o := range l.fi.ast.In().Fields() {
		id := o.AsField().Name()
		param := l.f.params[i]
		if !assigned[id] {
			l.args[id] = param
			continue
		}
		name := prefixArgCopy + mangle(id.Str(l.g.tm))
		switch param.typ.kind {
		case kBytes:
			l.args[id] = l.newLocal(name, typROSliceU8, bytesToHandle(eVar{param}))
		case kNum, kBool, kStatus:
			l.args[id] = l.newLocal(name, param.typ, eVar{param})
		default:
			return errNotYet("assigning to args.%s", id.Str(l.g.tm))
		}
	}
	return nil
}

// lhsBase returns the x in "x[i]" or "x.f", or nil.
func lhsBase(n *a.Expr) *a.Expr {
	switch n.Operator() {
	case t.IDOpenBracket, t.IDDot:
		return n.LHS().AsExpr()
	}
	return nil
}

func (l *lowerer) walkBody(f func(*a.Node) error) error {
	for _, o := range l.fi.ast.Body() {
		if err := o.Walk(f); err != nil {
			return err
		}
	}
	return nil
}

// declareLocals declares the Wuffs local variables, zero-initialized.
func (l *lowerer) declareLocals() error {
	vars := []*a.Var(nil)
	if err := l.walkBody(func(o *a.Node) error {
		if o.Kind() == a.KVar {
			vars = append(vars, o.AsVar())
		}
		return nil
	}); err != nil {
		return err
	}

	for _, o := range vars {
		id := o.Name()
		if l.locals[id] != nil {
			return fmt.Errorf("duplicate var %s", id.Str(l.g.tm))
		}
		typ, err := l.g.typeOf(o.XType(), false)
		if err != nil {
			return fmt.Errorf("var %s: %v", id.Str(l.g.tm), err)
		}
		if typ.excludesZero() {
			return fmt.Errorf("var %s: type %q excludes the zero value", id.Str(l.g.tm), o.XType().Str(l.g.tm))
		}
		name := prefixLocal + mangle(id.Str(l.g.tm))
		for _, prev := range l.f.locals {
			if strings.EqualFold(prev.name, name) {
				return fmt.Errorf("var %s: another local variable has the same Ada name %q", id.Str(l.g.tm), name)
			}
		}
		switch typ.kind {
		case kNum:
			v := l.newLocal(name, typ, typ.zeroValue())
			if err := l.narrow(v, id); err != nil {
				return err
			}
			l.locals[id] = v
		case kBool, kStatus:
			l.locals[id] = l.newLocal(name, typ, typ.zeroValue())
		case kROSliceU8:
			// The default initial value is the empty slice.
			l.locals[id] = l.newLocal(name, typ, nil)
		default:
			return errNotYet("var %s of type %q", id.Str(l.g.tm), o.XType().Str(l.g.tm))
		}
	}
	return nil
}

// narrow gives the numeric local variable v (Wuffs name id) a narrower Ada
// subtype than its Wuffs type, if the bounds that the Wuffs compiler deduced
// (ast.Expr.MBounds) for everything assigned to it allow that cheaply: when
// every assignment to the variable is a plain "=".
func (l *lowerer) narrow(v *variable, id t.ID) error {
	lo, hi := big.NewInt(0), big.NewInt(0) // The zero value is always possible.
	ok := true
	if err := l.walkBody(func(o *a.Node) error {
		if o.Kind() != a.KAssign {
			return nil
		}
		o1 := o.AsAssign()
		lhs := o1.LHS()
		if lhs == nil || lhs.Operator() != 0 || lhs.Ident() != id {
			return nil
		}
		b := o1.RHS().MBounds()
		if o1.Operator() != t.IDEq || b[0] == nil || b[1] == nil {
			ok = false
			return nil
		}
		if b[0].Cmp(lo) < 0 {
			lo = b[0]
		}
		if b[1].Cmp(hi) > 0 {
			hi = b[1]
		}
		return nil
	}); err != nil {
		return err
	}

	tLo, tHi := zero, numTypeMax(v.typ.bits)
	if v.typ.lo != nil {
		tLo, tHi = v.typ.lo, v.typ.hi
	}
	if !ok || lo.Cmp(tLo) < 0 || hi.Cmp(tHi) > 0 {
		// The second and third conditions should not happen: they would mean
		// that the Wuffs compiler deduced bounds that do not fit the type.
		return nil
	}
	if lo.Cmp(tLo) == 0 && hi.Cmp(tHi) == 0 {
		return nil
	}
	v.decl = fmt.Sprintf("%s range %s .. %s", v.typ.unrefined().name, lo, hi)
	v.init = raw(lo.String())
	return nil
}

// prologue emits what the C back-end's writeFuncImplPrologue does for a
// public function: check that Initialize was called (and that no previous
// call disabled the object) and check the arguments that Wuffs code would
// have had to prove in range.
func (l *lowerer) prologue() error {
	l.g.useType[32] = true
	magic := eSel{eVar{l.f.self}, "Magic"}
	cond := bin("/=", magic, raw(rtMagicInitialized))
	if !l.f.selfInOut {
		cond = bin("and then", cond, bin("/=", magic, raw(rtMagicDisabled)))
	}
	ret := sReturn{}
	if l.f.ret != nil {
		switch l.f.ret.kind {
		case kStatus:
			ret.value = eIf{
				cond: bin("=", magic, raw(rtMagicDisabled)),
				yes:  raw(l.g.basePkg + ".Error_Disabled_By_Previous_Error"),
				no:   raw(l.g.basePkg + ".Error_Initialize_Not_Called"),
			}
		default:
			ret.value = l.f.ret.zeroValue()
		}
	}
	l.f.body = append(l.f.body, sIf{branches: []ifBranch{{cond, []stmt{ret}}}})

	if len(l.fi.argChecks) == 0 {
		return nil
	}
	conds := []expr(nil)
	for i, v := range l.fi.argChecks {
		b := l.fi.argBounds[i]
		l.g.useType[b.bits] = true
		if b.lo.Sign() > 0 {
			conds = append(conds, bin("<", eVar{v}, raw(b.lo.String())))
		}
		if b.hi.Cmp(numTypeMax(b.bits)) < 0 {
			conds = append(conds, bin(">", eVar{v}, raw(b.hi.String())))
		}
	}
	cond = conds[0]
	if len(conds) > 1 {
		cond = bin("or else", conds...)
	}
	l.f.self.writes++
	l.f.body = append(l.f.body, sIf{branches: []ifBranch{{cond, []stmt{
		sAssign{magic, raw(rtMagicDisabled)},
		sReturn{},
	}}}})
	return nil
}

func (l *lowerer) block(nodes []*a.Node) ([]stmt, error) {
	ret := []stmt(nil)
	for _, o := range nodes {
		ss, err := l.statement(o)
		if err != nil {
			return nil, err
		}
		ret = append(ret, ss...)
	}
	return ret, nil
}

// flush returns the pending prelude statements followed by ss.
func (l *lowerer) flush(ss ...stmt) []stmt {
	ret := append(l.pre, ss...)
	l.pre = nil
	return ret
}

// noPrelude fails if lowering an expression needed prelude statements in a
// context that cannot have them (they would have to be re-evaluated).
func (l *lowerer) noPrelude(what string) error {
	if len(l.pre) != 0 {
		return errNotYet("a slice-valued temporary in %s", what)
	}
	return nil
}

func (l *lowerer) statement(n *a.Node) ([]stmt, error) {
	ss, err := l.statement1(n)
	if err != nil {
		filename, line := n.AsRaw().FilenameLine()
		if _, ok := err.(*locatedError); !ok {
			err = &locatedError{fmt.Sprintf("%v (at %s:%d)", err, filename, line)}
		}
		return nil, err
	}
	return ss, nil
}

// locatedError is an error that already says where in the Wuffs source it
// arose.
type locatedError struct{ s string }

func (e *locatedError) Error() string { return e.s }

func (l *lowerer) statement1(n *a.Node) ([]stmt, error) {
	if len(l.pre) != 0 {
		return nil, fmt.Errorf("internal error: prelude statements left over")
	}
	switch n.Kind() {
	case a.KAssert:
		return l.assert(n.AsAssert())
	case a.KAssign:
		return l.assign(n.AsAssign())
	case a.KChoose:
		return l.choose(n.AsChoose())
	case a.KIOManip:
		return nil, errNotYet("%s blocks", n.AsIOManip().Keyword().Str(l.g.tm))
	case a.KIf:
		return l.ifStmt(n.AsIf())
	case a.KIterate:
		return l.iterate(n.AsIterate())
	case a.KJump:
		return l.jump(n.AsJump())
	case a.KRet:
		return l.ret(n.AsRet())
	case a.KVar:
		// Local variables were declared by declareLocals.
		return nil, nil
	case a.KWhile:
		return l.while(n.AsWhile())
	}
	return nil, fmt.Errorf("unrecognized statement kind %s", n.Kind())
}

func (l *lowerer) condition(n *a.Expr) (expr, error) {
	v, err := l.expr(n)
	if err != nil {
		return nil, err
	}
	if v.typ == nil || v.typ.kind != kBool {
		return nil, fmt.Errorf("condition %q is not a bool", n.Str(l.g.tm))
	}
	return v.e, nil
}

func (l *lowerer) assert(n *a.Assert) ([]stmt, error) {
	if n.Keyword() != t.IDAssert {
		return nil, fmt.Errorf("unexpected %q assertion as a statement", n.Keyword().Str(l.g.tm))
	}
	cond, err := l.condition(n.Condition())
	if err != nil {
		return nil, err
	}
	return l.flush(sPragma{"Assert", []expr{cond}, true}), nil
}

// assignOpToBinaryOp maps "x op= y" to the "op" of "x = x op y".
var assignOpToBinaryOp = map[t.ID]t.ID{
	t.IDPlusEq:           t.IDXBinaryPlus,
	t.IDMinusEq:          t.IDXBinaryMinus,
	t.IDStarEq:           t.IDXBinaryStar,
	t.IDSlashEq:          t.IDXBinarySlash,
	t.IDShiftLEq:         t.IDXBinaryShiftL,
	t.IDShiftREq:         t.IDXBinaryShiftR,
	t.IDAmpEq:            t.IDXBinaryAmp,
	t.IDPipeEq:           t.IDXBinaryPipe,
	t.IDHatEq:            t.IDXBinaryHat,
	t.IDPercentEq:        t.IDXBinaryPercent,
	t.IDTildeModPlusEq:   t.IDXBinaryTildeModPlus,
	t.IDTildeModMinusEq:  t.IDXBinaryTildeModMinus,
	t.IDTildeModStarEq:   t.IDXBinaryTildeModStar,
	t.IDTildeModShiftLEq: t.IDXBinaryTildeModShiftL,
	t.IDTildeSatPlusEq:   t.IDXBinaryTildeSatPlus,
	t.IDTildeSatMinusEq:  t.IDXBinaryTildeSatMinus,
}

func (l *lowerer) assign(n *a.Assign) ([]stmt, error) {
	op, lhs, rhs := n.Operator(), n.LHS(), n.RHS()
	if rhs.Effect().Coroutine() {
		return nil, errNotYet("coroutine calls")
	}
	if op == t.IDEqQuestion {
		return nil, errNotYet("the \"=?\" operator")
	}

	if lhs == nil {
		// A call, for its side effects.
		if rhs.Operator() != a.ExprOperatorCall {
			return nil, fmt.Errorf("expression statement %q is not a call", rhs.Str(l.g.tm))
		}
		v, err := l.expr(rhs)
		if err != nil {
			return nil, err
		}
		if v.typ == nil {
			return l.flush(sCall{v.e}), nil
		}
		// Ada cannot ignore a function's result.
		l.nTemps++
		discard := l.newLocal(fmt.Sprintf("%sDiscard_%d", prefixGen, l.nTemps), v.typ.unrefined(), nil)
		return l.flush(sAssign{eVar{discard}, v.e}), nil
	}

	if lhs.Operator() == t.IDOpenBracket && lhs.LHS().AsExpr().MType().IsEitherSliceType() {
		return nil, errNotYet("assigning to a slice element")
	}
	lv, err := l.expr(lhs)
	if err != nil {
		return nil, err
	}
	if lv.typ == nil || lv.cv != nil {
		return nil, fmt.Errorf("cannot assign to %q", lhs.Str(l.g.tm))
	}
	rv, err := l.expr(rhs)
	if err != nil {
		return nil, err
	}
	if rv.typ == nil {
		return nil, fmt.Errorf("%q has no value", rhs.Str(l.g.tm))
	}

	if op != t.IDEq {
		xop, ok := assignOpToBinaryOp[op]
		if !ok || lv.typ.kind != kNum {
			return nil, fmt.Errorf("unrecognized assignment operator %q", op.Str(l.g.tm))
		}
		rv, err = l.numBinaryOp(xop, val{e: lv.e, typ: lv.typ.unrefined()}, rv, lv.typ.bits)
		if err != nil {
			return nil, err
		}
		return l.flush(sAssign{lv.e, rv.e}), nil
	}

	switch lv.typ.kind {
	case kNum:
		if rv.typ.kind != kIdeal && (rv.typ.kind != kNum || rv.typ.bits != lv.typ.bits) {
			return nil, fmt.Errorf("cannot assign %q to %q: different types", rhs.Str(l.g.tm), lhs.Str(l.g.tm))
		}
	case kBool, kStatus:
		if rv.typ.kind != lv.typ.kind {
			return nil, fmt.Errorf("cannot assign %q to %q: different types", rhs.Str(l.g.tm), lhs.Str(l.g.tm))
		}
	case kROSliceU8:
		rv, err = l.toHandle(rv)
		if err != nil {
			return nil, err
		}
	default:
		return nil, errNotYet("assigning to %q, of type %q", lhs.Str(l.g.tm), lhs.MType().Str(l.g.tm))
	}
	return l.flush(sAssign{lv.e, rv.e}), nil
}

// choose lowers a choose statement, statically. A candidate that has a
// "choose cpu_arch" assertion is never chosen, as if the CPU lacked the
// capability (the C back-end guards each such candidate with a
// wuffs_base__cpu_arch__have_etc call). If every candidate is like that,
// which is the only case handled so far, the statement does nothing and the
// choosy function keeps its default body.
func (l *lowerer) choose(n *a.Choose) ([]stmt, error) {
	recv := l.fi.ast.Receiver()
	names := ""
	for i, o := range n.Args() {
		id := o.AsExpr().Ident()
		callee := l.g.funcs[t.QQID{recv[0], recv[1], id}]
		if callee == nil {
			return nil, fmt.Errorf("choose: no such function %q", id.Str(l.g.tm))
		}
		if !callee.skipped {
			return nil, errNotYet("choose with an alternative (%s) that has no cpu_arch requirement",
				id.Str(l.g.tm))
		}
		if i != 0 {
			names += ", "
		}
		names += id.Str(l.g.tm)
	}
	return []stmt{sComment{fmt.Sprintf(
		"Wuffs: choose %s = [%s]\nNothing to do: every alternative needs a cpu_arch (SIMD) capability.",
		n.Name().Str(l.g.tm), names)}}, nil
}

func (l *lowerer) ifStmt(n *a.If) ([]stmt, error) {
	// For an "if true { etc }", just emit the "etc".
	if cv := n.Condition().ConstValue(); cv != nil && cv.Cmp(one) == 0 &&
		n.ElseIf() == nil && len(n.BodyIfFalse()) == 0 {
		return l.block(n.BodyIfTrue())
	}

	ret := sIf{}
	pre := []stmt(nil)
	for first := true; n != nil; n, first = n.ElseIf(), false {
		cond, err := l.condition(n.Condition())
		if err != nil {
			return nil, err
		}
		if first {
			pre = l.flush()
		} else if err := l.noPrelude("an else-if condition"); err != nil {
			return nil, err
		}
		body, err := l.block(n.BodyIfTrue())
		if err != nil {
			return nil, err
		}
		ret.branches = append(ret.branches, ifBranch{cond, body})
		if bif := n.BodyIfFalse(); len(bif) > 0 {
			ret.els, err = l.block(bif)
			if err != nil {
				return nil, err
			}
			break
		}
	}
	return append(pre, ret), nil
}

// loopAsserts lowers the assertions of a loop whose keyword is one of
// keywords, as pragmas called pragma.
func (l *lowerer) loopAsserts(asserts []*a.Node, pragma string, keywords ...t.ID) ([]stmt, error) {
	ret := []stmt(nil)
	for _, o := range asserts {
		o := o.AsAssert()
		match := false
		for _, k := range keywords {
			match = match || o.Keyword() == k
		}
		if !match {
			continue
		}
		cond, err := l.condition(o.Condition())
		if err != nil {
			return nil, err
		}
		if err := l.noPrelude("a loop assertion"); err != nil {
			return nil, err
		}
		ret = append(ret, sPragma{pragma, []expr{cond}, true})
	}
	return ret, nil
}

func (l *lowerer) while(n *a.While) ([]stmt, error) {
	for _, o := range n.Asserts() {
		switch o.AsAssert().Keyword() {
		case t.IDPre, t.IDInv, t.IDPost:
			// No-op.
		default:
			return nil, fmt.Errorf("unexpected loop assertion keyword %q", o.AsAssert().Keyword().Str(l.g.tm))
		}
	}

	l.nLoops++
	suffix := strconv.Itoa(l.nLoops)
	if n.Label() != 0 {
		suffix += "_" + mangle(n.Label().Str(l.g.tm))
	}
	info := &loopInfo{}
	if n.HasBreak() {
		info.name = prefixGen + "Loop_" + suffix
	}
	if n.HasContinue() {
		info.continueLabel = prefixGen + "Continue_" + suffix
	}
	l.loops[n] = info

	loop := sLoop{name: info.name}
	if !n.IsWhileTrue() {
		cond, err := l.condition(n.Condition())
		if err != nil {
			return nil, err
		}
		if err := l.noPrelude("a while condition"); err != nil {
			return nil, err
		}
		loop.cond = cond
	}

	// The "pre" and "inv" conditions hold whenever the loop condition is
	// evaluated, and so at the start of every iteration, which is the only
	// place in a loop that pragma Loop_Invariant is certain to be legal.
	invs, err := l.loopAsserts(n.Asserts(), "Loop_Invariant", t.IDPre, t.IDInv)
	if err != nil {
		return nil, err
	}
	body, err := l.block(n.Body())
	if err != nil {
		return nil, err
	}
	loop.body = append(invs, body...)
	if info.continueLabel != "" {
		loop.body = append(loop.body, sLabel{info.continueLabel})
	}

	// The "inv" and "post" conditions hold on exit, whether by the loop
	// condition or by a break.
	posts, err := l.loopAsserts(n.Asserts(), "Assert", t.IDInv, t.IDPost)
	if err != nil {
		return nil, err
	}
	delete(l.loops, n)
	return append([]stmt{loop}, posts...), nil
}

func (l *lowerer) jump(n *a.Jump) ([]stmt, error) {
	info := l.loops[n.JumpTarget()]
	if info == nil {
		return nil, fmt.Errorf("internal error: jump to an unknown loop")
	}
	if info.isIterate {
		return nil, errNotYet("%s out of an iterate loop", n.Keyword().Str(l.g.tm))
	}
	switch n.Keyword() {
	case t.IDBreak:
		if info.name == "" {
			return nil, fmt.Errorf("internal error: break out of an unnamed loop")
		}
		return []stmt{sExit{info.name}}, nil
	case t.IDContinue:
		if info.continueLabel == "" {
			return nil, fmt.Errorf("internal error: continue in a loop without a continue label")
		}
		return []stmt{sGoto{info.continueLabel}}, nil
	}
	return nil, fmt.Errorf("unrecognized jump keyword %q", n.Keyword().Str(l.g.tm))
}

// iterate lowers an iterate loop, following the C back-end's
// writeStatementIterate: for each "round" (each link of the iterate ... else
// ... chain and, for an unroll count above 1, a second round for what the
// unrolled loop leaves over), loop while a whole iteration's worth of the
// slice remains.
//
// In Ada, the slice being iterated over is held in a temporary handle
// (In_Src), In_Pos is the offset in it of the current iteration and In_End
// is the exclusive upper bound for In_Pos in the current round.
func (l *lowerer) iterate(n *a.Iterate) ([]stmt, error) {
	assigns := n.Assigns()
	if len(assigns) == 0 {
		return nil, nil
	}
	if len(assigns) != 1 {
		return nil, errNotYet("iterate loops over more than one slice")
	}
	for o := n; o != nil; o = o.ElseIterate() {
		if len(o.Asserts()) != 0 {
			return nil, errNotYet("iterate loops with assertions")
		}
	}
	o := assigns[0].AsAssign()
	if o.Operator() != t.IDEq || o.LHS().Operator() != 0 {
		return nil, fmt.Errorf("unexpected form of iterate assignment")
	}
	p := l.locals[o.LHS().Ident()]
	if p == nil || p.typ.kind != kROSliceU8 {
		return nil, errNotYet("iterate variable %q of type %q", o.LHS().Str(l.g.tm), o.LHS().MType().Str(l.g.tm))
	}
	// The C back-end advances the iterate variable itself, so assigning to
	// it in the loop body changes where later iterations look (and can run
	// past the end of the slice). Here it is re-derived from a counter
	// instead, which would silently behave differently, so reject that.
	for i := n; i != nil; i = i.ElseIterate() {
		for _, x := range i.Body() {
			if err := x.Walk(func(y *a.Node) error {
				if y.Kind() != a.KAssign || y.AsAssign().LHS() == nil {
					return nil
				}
				for lhs := y.AsAssign().LHS(); lhs != nil; lhs = lhsBase(lhs) {
					if lhs.Operator() == 0 && lhs.Ident() == o.LHS().Ident() {
						return errNotYet("assigning to the iterate variable %q inside its iterate loop",
							lhs.Str(l.g.tm))
					}
				}
				return nil
			}); err != nil {
				return nil, err
			}
		}
	}
	rv, err := l.expr(o.RHS())
	if err != nil {
		return nil, err
	}
	if rv, err = l.toHandle(rv); err != nil {
		return nil, err
	}

	l.nIterates++
	prefix := fmt.Sprintf("%sI%d_", prefixGen, l.nIterates)
	src := eVar{l.newLocal(prefix+"Src", typROSliceU8, nil)}
	pos := eVar{l.newLocal(prefix+"Pos", typIndex, raw("0"))}
	end := eVar{l.newLocal(prefix+"End", typIndex, raw("0"))}
	srcLen := eSel{src, "Length"}

	ret := l.flush(sAssign{src, rv.e}, sAssign{pos, raw("0")})

	for ; n != nil; n = n.ElseIterate() {
		info := &loopInfo{isIterate: true}
		l.loops[n] = info

		length, err1 := strconv.Atoi(n.Length().Str(l.g.tm))
		advance, err2 := strconv.Atoi(n.Advance().Str(l.g.tm))
		unroll, err3 := strconv.Atoi(n.Unroll().Str(l.g.tm))
		if err1 != nil || err2 != nil || err3 != nil ||
			length < 1 || advance < 1 || advance > length || unroll < 1 {
			return nil, fmt.Errorf("bad iterate length, advance or unroll")
		}

		for {
			ret = append(ret, sComment{fmt.Sprintf(
				"Wuffs: iterate (length: %d, advance: %d, unroll: %d)", length, advance, unroll)})

			lit := func(i int) expr { return raw(strconv.Itoa(i)) }
			remaining := bin("-", srcLen, pos)
			if length == 1 && advance == 1 && unroll == 1 {
				ret = append(ret, sAssign{end, srcLen})
			} else if length == advance {
				ret = append(ret, sAssign{end, bin("+", pos,
					bin("*", bin("/", remaining, lit(length*unroll)), lit(length*unroll)))})
			} else {
				ret = append(ret, sAssign{end, bin("+", pos, callNamed(l.g.basePkg+".Iterate_Total_Advance",
					"Total_Len", remaining,
					"Iter_Len", lit(length+(advance*(unroll-1))),
					"Iter_Advance", lit(advance*unroll)))})
			}

			loop := sLoop{cond: bin("<", pos, end)}
			for i := 0; i < unroll; i++ {
				loop.body = append(loop.body, sAssign{eVar{p},
					callNamed("Wuffs.Runtime.Subslice_IJ", "S", src, "I", pos, "J", bin("+", pos, lit(length)))})
				body, err := l.block(n.Body())
				if err != nil {
					return nil, err
				}
				loop.body = append(loop.body, body...)
				loop.body = append(loop.body, sAssign{pos, bin("+", pos, lit(advance))})
			}
			ret = append(ret, loop)

			if unroll == 1 {
				break
			}
			unroll = 1
		}
		delete(l.loops, n)
	}

	// The C back-end leaves the iterate variable as an empty slice. That is
	// only observable if something reads the variable outside of the loops
	// that bind it; otherwise, omit the dead store (which GNAT warns about).
	if l.readOutsideItsIterates(o.LHS().Ident()) {
		ret = append(ret, sAssign{eVar{p}, callNamed("Wuffs.Runtime.Subslice_IJ", "S", src, "I", pos, "J", pos)})
	}
	return ret, nil
}

// readOutsideItsIterates reports whether the function mentions the local
// variable id anywhere other than in the body of an iterate loop that binds
// it (or as the binding itself).
func (l *lowerer) readOutsideItsIterates(id t.ID) bool {
	exempt := map[*a.Expr]bool{}
	mark := func(o *a.Node) error {
		if o.Kind() == a.KExpr {
			exempt[o.AsExpr()] = true
		}
		return nil
	}
	l.walkBody(func(o *a.Node) error {
		if o.Kind() != a.KIterate {
			return nil
		}
		binds := false
		for _, x := range o.AsIterate().Assigns() {
			if lhs := x.AsAssign().LHS(); lhs.Operator() == 0 && lhs.Ident() == id {
				exempt[lhs] = true
				binds = true
			}
		}
		if binds {
			for i := o.AsIterate(); i != nil; i = i.ElseIterate() {
				for _, x := range i.Body() {
					x.Walk(mark)
				}
			}
		}
		return nil
	})
	found := false
	l.walkBody(func(o *a.Node) error {
		if o.Kind() == a.KExpr {
			if e := o.AsExpr(); e.Operator() == 0 && e.Ident() == id && !exempt[e] {
				found = true
			}
		}
		return nil
	})
	return found
}

func (l *lowerer) ret(n *a.Ret) ([]stmt, error) {
	if n.Keyword() != t.IDReturn {
		return nil, errNotYet("%s statements", n.Keyword().Str(l.g.tm))
	}
	value := n.Value()
	if l.f.ret == nil {
		if value != nil && (value.Operator() != 0 || value.Ident() != t.IDNothing) {
			return nil, fmt.Errorf("return of a value from a function without a return type")
		}
		return []stmt{sReturn{}}, nil
	}
	if value == nil {
		return nil, fmt.Errorf("return without a value from a function with a return type")
	}
	v, err := l.expr(value)
	if err != nil {
		return nil, err
	}
	if v.typ == nil {
		return nil, fmt.Errorf("%q has no value", value.Str(l.g.tm))
	}
	switch l.f.ret.kind {
	case kNum:
		if v.typ.kind != kIdeal && (v.typ.kind != kNum || v.typ.bits != l.f.ret.bits) {
			return nil, fmt.Errorf("cannot return %q: wrong type", value.Str(l.g.tm))
		}
	case kBool:
		if v.typ.kind != kBool {
			return nil, fmt.Errorf("cannot return %q: wrong type", value.Str(l.g.tm))
		}
	case kStatus:
		// The C back-end wraps a status that could be a suspension in
		// wuffs_private_impl__status__ensure_not_a_suspension. Until the
		// base library provides that, accept only what cannot be one.
		isLiteral := value.ConstValue() != nil
		if op := value.Operator(); (op == 0 || op == t.IDDot) && value.Ident().IsDQStrLiteral(l.g.tm) {
			msg, _ := t.Unescape(value.Ident().Str(l.g.tm))
			isLiteral = msg != "" && msg[0] != '$'
		}
		if v.typ.kind != kStatus || !isLiteral {
			return nil, errNotYet("returning a status that is not an ok, error or note literal")
		}
	default:
		return nil, fmt.Errorf("internal error: unexpected return type")
	}
	return l.flush(sReturn{v.e}), nil
}
