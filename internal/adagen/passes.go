// Part of wuffada (wuffs-ada: Wuffs to Ada).
// SPDX-License-Identifier: Apache-2.0 OR MIT

package adagen

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
		case sReturn:
			if s.value != nil {
				countExpr(s.value)
			}
		case sPragma:
			for _, o := range s.args {
				countExpr(o)
			}
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
