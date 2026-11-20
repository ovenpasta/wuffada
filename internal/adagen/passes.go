// Part of wuffada (wuffs-ada: Wuffs to Ada).
// SPDX-License-Identifier: Apache-2.0 OR MIT

package adagen

import (
	"fmt"
	"strings"
)

// This file holds the passes that run on a function's IR between lowering
// and printing. For now there is one, countUses. The coroutine lowering of
// the next milestone (flattening every construct that contains a suspension
// point into labels and gotos, and saving the locals that are live across
// one in the receiver) belongs here too: it is a []stmt to []stmt rewrite.

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
		// (S : a slice handle; I : Wuffs.Index).
		"Wuffs.Runtime.Get":        true,
		"Wuffs.Runtime.Subslice_I": true,
		"Wuffs.Runtime.Subslice_J": true,
		// (Data : Wuffs.Bytes; M : Buffer_Meta).
		"Wuffs.Runtime.Valid_Buffer": true,
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
