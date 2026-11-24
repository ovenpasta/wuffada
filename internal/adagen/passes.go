// Part of wuffada (wuffs-ada: Wuffs to Ada).
// SPDX-License-Identifier: Apache-2.0 OR MIT

package adagen

import (
	"fmt"
	"strings"
)

// This file holds the passes that run on a function's IR between lowering
// and printing: countUses, the checks of calls, and isolateCursors (which
// lowerFunc runs on the finished body, coroutine or not).

// countUses counts the reads and writes of each parameter and local
// variable. The printer uses the counts to drop unused locals, to declare
// never-assigned ones constant and to mark unused parameters as unreferenced:
// all things that GNAT otherwise warns about.
//
// It adds to the counts that lowering already made (for writes that the IR
// does not show, such as passing Self as an "in out" parameter).
func countUses(f *fn) {
	countStmts(f.body)
	// A local's initial value is only evaluated if the local is declared.
	// Later locals can only refer to parameters and earlier locals, so go
	// backwards.
	for i := len(f.locals) - 1; i >= 0; i-- {
		if o := f.locals[i]; o.init != nil && (o.reads != 0 || o.writes != 0) {
			countExpr(o.init)
		}
	}
}

func countStmts(ss []stmt) {
	for _, s := range ss {
		switch s := s.(type) {
		case sAssign:
			countLHS(s.lhs)
			countExpr(s.rhs)
		case sCall:
			countExpr(s.call)
		case sIf:
			for _, br := range s.branches {
				countExpr(br.cond)
				countStmts(br.body)
			}
			countStmts(s.els)
		case sLoop:
			if s.cond != nil {
				countExpr(s.cond)
			}
			countStmts(s.body)
		case sExitWhen:
			countExpr(s.cond)
		case sReturn:
			if s.value != nil {
				countExpr(s.value)
			}
		case sPragma:
			for _, o := range s.args {
				countExpr(o)
			}
		case sResume:
			if !s.labelOnly {
				s.susp.writes++
			}
		case sCase:
			countExpr(s.sel)
			for _, arm := range s.arms {
				countStmts(arm.body)
			}
			countStmts(s.others)
		}
	}
}

// countLHS counts an assignment's target: a write of the variable at its
// root, and reads of whatever its indexes mention.
func countLHS(e expr) {
	switch e := e.(type) {
	case eVar:
		e.v.writes++
	case eSel:
		countLHS(e.x)
	case eCall:
		countLHS(e.fn)
		for _, o := range e.args {
			countExpr(o)
		}
	default:
		countExpr(e)
	}
}

func countExpr(e expr) {
	switch e := e.(type) {
	case eVar:
		e.v.reads++
	case eSel:
		countExpr(e.x)
	case eAttr:
		countExpr(e.x)
	case eCall:
		countExpr(e.fn)
		for _, o := range e.args {
			countExpr(o)
		}
	case eSlice:
		countExpr(e.x)
		countExpr(e.lo)
		countExpr(e.hi)
	case eQual:
		countExpr(e.x)
	case eNamed:
		countExpr(e.x)
	case eRel:
		countExpr(e.l)
		countExpr(e.r)
	case eOut:
		countLHS(e.x)
	case eUn:
		countExpr(e.x)
	case eBin:
		for _, o := range e.args {
			countExpr(o)
		}
	case eAgg:
		for _, o := range e.vals {
			countExpr(o)
		}
	case eIf:
		countExpr(e.cond)
		countExpr(e.yes)
		countExpr(e.no)
	}
}

// ---- Positional calls.

// positionalCalls are the subprograms that generated code may call with two
// or more positional arguments: no two of their parameters have the same
// type, so the compiler rejects arguments in the wrong order. Every other
// call with two or more arguments must name them all (see checkCalls).
var positionalCalls = func() map[string]bool {
	m := map[string]bool{
		// (M : in out Buffer_Meta; R : Reader) or (...; W : Writer), and
		// the reverse.
		ioPkg + ".Save":   true,
		ioPkg + ".Reload": true,
		// (M : in out Token_Buffer_Meta; W : Token_Writer), and the reverse.
		tokensPkg + ".Save":   true,
		tokensPkg + ".Reload": true,
		// (S : a slice handle; I : Wuffs.Index).
		"Wuffs.Runtime.Get":        true,
		"Wuffs.Runtime.Subslice_I": true,
		"Wuffs.Runtime.Subslice_J": true,
		// (Data : Wuffs.Bytes; M : Buffer_Meta).
		"Wuffs.Runtime.Valid_Buffer": true,
		// (Data : Wuffs.U64_Array; M : Token_Buffer_Meta).
		"Wuffs.Runtime.Valid_Token_Buffer": true,
	}
	// (Data : Wuffs.Bytes; R : Reader).
	for _, bits := range []string{"8", "16", "24", "32", "40", "48", "56", "64"} {
		for _, endian := range []string{"", "LE", "BE"} {
			m[ioPkg+".Peek_U"+bits+endian] = true
		}
	}
	return m
}()

// walkExpr calls f for e and for every expression in it.
func walkExpr(e expr, f func(expr)) {
	if e == nil {
		return
	}
	f(e)
	switch e := e.(type) {
	case eSel:
		walkExpr(e.x, f)
	case eAttr:
		walkExpr(e.x, f)
	case eCall:
		walkExpr(e.fn, f)
		for _, o := range e.args {
			walkExpr(o, f)
		}
	case eSlice:
		walkExpr(e.x, f)
		walkExpr(e.lo, f)
		walkExpr(e.hi, f)
	case eQual:
		walkExpr(e.x, f)
	case eNamed:
		walkExpr(e.x, f)
	case eRel:
		walkExpr(e.l, f)
		walkExpr(e.r, f)
	case eOut:
		walkExpr(e.x, f)
	case eUn:
		walkExpr(e.x, f)
	case eBin:
		for _, o := range e.args {
			walkExpr(o, f)
		}
	case eAgg:
		for _, o := range e.vals {
			walkExpr(o, f)
		}
	case eIf:
		walkExpr(e.cond, f)
		walkExpr(e.yes, f)
		walkExpr(e.no, f)
	}
}

// walkStmts calls f for every expression in ss.
func walkStmts(ss []stmt, f func(expr)) {
	for _, s := range ss {
		switch s := s.(type) {
		case sAssign:
			walkExpr(s.lhs, f)
			walkExpr(s.rhs, f)
		case sCall:
			walkExpr(s.call, f)
		case sIf:
			for _, br := range s.branches {
				walkExpr(br.cond, f)
				walkStmts(br.body, f)
			}
			walkStmts(s.els, f)
		case sLoop:
			walkExpr(s.cond, f)
			walkStmts(s.body, f)
		case sExitWhen:
			walkExpr(s.cond, f)
		case sReturn:
			walkExpr(s.value, f)
		case sPragma:
			for _, o := range s.args {
				walkExpr(o, f)
			}
		case sCase:
			walkExpr(s.sel, f)
			for _, arm := range s.arms {
				walkStmts(arm.body, f)
			}
			walkStmts(s.others, f)
		}
	}
}

// checkCalls enforces the rule that a call of a subprogram with two or more
// parameters names its arguments, unless the subprogram is one whose
// parameters all have different types (positionalCalls): swapped arguments
// of one type would compile and be wrong.
func checkCalls(ss []stmt) error {
	err := error(nil)
	walkStmts(ss, func(e expr) {
		c, ok := e.(eCall)
		if !ok || len(c.args) < 2 || err != nil {
			return
		}
		fn, ok := c.fn.(eRaw)
		if !ok {
			// An indexed component, not a call.
			return
		}
		// The proved base, the pixel library and the runtime shell. (A call
		// of a generated function names its arguments when two parameters
		// have the same type: userCall knows the callee's signature.)
		if !strings.HasPrefix(fn.s, "Wuffs.") || strings.HasPrefix(fn.s, "Wuffs.Std.") {
			return
		}
		for _, o := range c.args {
			if _, ok := o.(eNamed); !ok && !positionalCalls[fn.s] {
				err = fmt.Errorf("internal error: a call of %s with positional arguments", fn.s)
				return
			}
		}
	})
	return err
}

// ---- Cursor isolation.

// inlinedCursorProcs are the procedures of the proved base that take an I/O
// or token cursor and are declared Inline_Always (wuffs-base-io.ads,
// wuffs-base-tokens.ads): GCC inlines every call of them, so passing a
// cursor to them does not take its address. TestInlinedCursorProcs checks
// the list against the specs.
var inlinedCursorProcs = func() map[string]bool {
	m := map[string]bool{
		ioPkg + ".Save":          true,
		ioPkg + ".Reload":        true,
		ioPkg + ".Skip_U32_Fast": true,
		ioPkg + ".Undo_Byte":     true,
		ioPkg + ".Read_U8":       true,
		ioPkg + ".Write_U8_Fast": true,

		tokensPkg + ".Save":                      true,
		tokensPkg + ".Reload":                    true,
		tokensPkg + ".Write_Simple_Token_Fast":   true,
		tokensPkg + ".Write_Extended_Token_Fast": true,
	}
	for _, bits := range []string{"16", "24", "32", "40", "48", "56", "64"} {
		for _, endian := range []string{"LE", "BE"} {
			m[ioPkg+".Write_U"+bits+endian+"_Fast"] = true
		}
	}
	return m
}()

// outOfLineCursorFuncs are the functions of the proved base that take a
// cursor and are not expression functions (which GNAT inlines). Every other
// function with a cursor parameter in those specs is an expression function:
// TestInlinedCursorProcs checks that too.
var outOfLineCursorFuncs = map[string]bool{
	ioPkg + ".Match7":                    true,
	"Wuffs.Base.UTF8.Valid_UTF_8_Length": true,
}

// isolateCursors gives every other procedure call that is passed a cursor a
// copy of it: "G_Tn := C; P (..., G_Tn, ...); C := G_Tn;". So too for a
// call of one of outOfLineCursorFuncs in the value of an assignment or in
// the conditions of an if statement: "G_Tn := C;" before the statement.
// (Its cursor parameter has mode "in": nothing to copy back. The conditions
// of an if statement do not change the cursor, so one copy before the
// statement serves all of them.)
//
// A cursor (Reader, Writer, Token_Writer) is a record that GNAT passes by
// reference. Once one out-of-line call has its address, GCC must keep the
// whole record in memory for the whole function, and reload and store its
// fields around every store through the destination array, which might
// alias it: the hot loops then pay a load and a store of the cursor per
// byte written, where upstream's C keeps iop in a register. A copy confines
// the address to the temporary. The effect is the same: the callee is
// given the cursor's value and its result becomes the cursor's value, and
// nothing else can see the cursor during the call (it is a local of the
// function, not reachable from any argument).
func (l *lowerer) isolateCursors(ss []stmt) []stmt {
	out := make([]stmt, 0, len(ss))
	for _, s := range ss {
		switch s := s.(type) {
		case sCall:
			out = append(out, l.isolateCall(s)...)
			continue
		case sAssign:
			var before []stmt
			rhs := l.isolateFuncCalls(s.rhs, &before)
			out = append(append(out, before...), sAssign{s.lhs, rhs})
			continue
		case sIf:
			var before []stmt
			brs := make([]ifBranch, len(s.branches))
			for i, br := range s.branches {
				brs[i] = ifBranch{cond: l.isolateFuncCalls(br.cond, &before), body: l.isolateCursors(br.body)}
			}
			out = append(append(out, before...), sIf{branches: brs, els: l.isolateCursors(s.els)})
			continue
		case sLoop:
			out = append(out, sLoop{name: s.name, cond: s.cond, body: l.isolateCursors(s.body)})
			continue
		case sCase:
			arms := make([]caseArm, len(s.arms))
			for i, arm := range s.arms {
				arms[i] = caseArm{value: arm.value, body: l.isolateCursors(arm.body)}
			}
			out = append(out, sCase{sel: s.sel, arms: arms, others: l.isolateCursors(s.others)})
			continue
		}
		out = append(out, s)
	}
	return out
}

// isolateFuncCalls returns e with the cursor arguments of the calls of
// outOfLineCursorFuncs in it replaced by copies, and appends the copying
// assignments to before.
func (l *lowerer) isolateFuncCalls(e expr, before *[]stmt) expr {
	switch x := e.(type) {
	case eCall:
		args := make([]expr, len(x.args))
		for i, o := range x.args {
			args[i] = l.isolateFuncCalls(o, before)
		}
		if fn, ok := x.fn.(eRaw); ok && outOfLineCursorFuncs[fn.s] {
			for i, o := range args {
				name, y := "", o
				if n, ok := o.(eNamed); ok {
					name, y = n.name, n.x
				}
				v, ok := y.(eVar)
				if !ok || v.v.typ.kind != kCursor || v.v.kind != varLocal {
					continue
				}
				tmp := l.cursorCopy(v.v)
				*before = append(*before, sAssign{eVar{tmp}, eVar{v.v}})
				var arg expr = eVar{tmp}
				if name != "" {
					arg = eNamed{name, arg}
				}
				args[i] = arg
			}
		}
		return eCall{fn: x.fn, args: args}
	case eNamed:
		return eNamed{x.name, l.isolateFuncCalls(x.x, before)}
	case eBin:
		args := make([]expr, len(x.args))
		for i, o := range x.args {
			args[i] = l.isolateFuncCalls(o, before)
		}
		return eBin{x.op, args}
	case eRel:
		return eRel{op: x.op, l: l.isolateFuncCalls(x.l, before), r: l.isolateFuncCalls(x.r, before),
			li: x.li, ri: x.ri}
	case eUn:
		return eUn{x.op, l.isolateFuncCalls(x.x, before)}
	}
	return e
}

// isolateCall is isolateCursors for one call statement.
func (l *lowerer) isolateCall(s sCall) []stmt {
	c, ok := s.call.(eCall)
	if !ok {
		return []stmt{s}
	}
	fn, ok := c.fn.(eRaw)
	if !ok || inlinedCursorProcs[fn.s] {
		return []stmt{s}
	}
	before, after := []stmt(nil), []stmt(nil)
	args := make([]expr, len(c.args))
	for i, o := range c.args {
		args[i] = o
		name, x := "", o
		if n, ok := o.(eNamed); ok {
			name, x = n.name, n.x
		}
		out := false
		if e, ok := x.(eOut); ok {
			out, x = true, e.x
		}
		v, ok := x.(eVar)
		if !ok || v.v.typ.kind != kCursor || v.v.kind != varLocal {
			continue
		}
		tmp := l.cursorCopy(v.v)
		before = append(before, sAssign{eVar{tmp}, eVar{v.v}})
		// Copied back whatever the formal's mode: for an "in" formal it
		// is a no-op.
		after = append(after, sAssign{eVar{v.v}, eVar{tmp}})
		var arg expr = eVar{tmp}
		if out {
			arg = eOut{arg}
		}
		if name != "" {
			arg = eNamed{name, arg}
		}
		args[i] = arg
	}
	if before == nil {
		return []stmt{s}
	}
	ret := append(before, sCall{eCall{fn: c.fn, args: args}})
	return append(ret, after...)
}

// cursorCopy returns the temporary that isolateCursors copies cursor v to,
// one per cursor and function.
func (l *lowerer) cursorCopy(v *variable) *variable {
	if l.cursorCopies == nil {
		l.cursorCopies = map[*variable]*variable{}
	}
	if tmp := l.cursorCopies[v]; tmp != nil {
		return tmp
	}
	tmp := l.newTemp(v.typ)
	l.cursorCopies[v] = tmp
	return tmp
}
