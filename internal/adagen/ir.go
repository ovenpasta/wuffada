// Part of wuffada (wuffs-ada: Wuffs to Ada).
// SPDX-License-Identifier: Apache-2.0 OR MIT

package adagen

import "math/big"

// This file defines the per-function intermediate representation: a small
// Ada-shaped tree of statements and expressions. Functions are lowered from
// the Wuffs AST to this IR (lower_*.go), transformed by passes (passes.go)
// and then printed (emit.go).
//
// Keeping an IR between the AST walk and the printer is what lets later
// milestones rewrite control flow (the coroutine lowering turns every
// construct that contains a suspension point into sLabel/sGoto form plus a
// case dispatch) without touching expression lowering or printing.

// expr is an Ada expression.
type expr interface{ isExpr() }

type (
	// eRaw is literal Ada text that never needs parentheses: a literal or an
	// expanded name.
	eRaw struct{ s string }

	// eVar is a reference to a parameter or local variable.
	eVar struct{ v *variable }

	// eSel is a selected component: x.field.
	eSel struct {
		x     expr
		field string
	}

	// eAttr is an attribute reference: x'attr.
	eAttr struct {
		x    expr
		attr string
	}

	// eCall is a function call, type conversion, array indexing or anything
	// else of the form "fn (args)".
	eCall struct {
		fn   expr
		args []expr
	}

	// eSlice is an array slice: x (lo .. hi).
	eSlice struct {
		x      expr
		lo, hi expr
	}

	// eQual is a qualified expression: typ'(x).
	eQual struct {
		typ string
		x   expr
	}

	// eUn is a unary operator applied to x.
	eUn struct {
		op string
		x  expr
	}

	// eBin is a binary operator, or a chain of one associative operator,
	// applied to two or more args.
	eBin struct {
		op   string
		args []expr
	}

	// eRel is a comparison: l op r, for one of Ada's relational operators.
	// Every comparison in the IR is an eRel (bin makes one too), and the
	// operator that is printed is always adaOp's: see there.
	//
	// li and ri say what is known about the operands' values, if anything.
	eRel struct {
		op     string
		l, r   expr
		li, ri operandInfo
	}

	// eOut marks an actual parameter of a procedure call whose formal has
	// mode "out" (or "in out"): the call assigns x. It prints as x.
	eOut struct{ x expr }

	// eAgg is a record aggregate with named components.
	eAgg struct {
		names []string
		vals  []expr
	}

	// eNamed is a named parameter association, "name => x", in an eCall's
	// args. Calls into the base library and the runtime glue use it whenever
	// two parameters have the same type, so that swapped arguments cannot
	// compile.
	eNamed struct {
		name string
		x    expr
	}

	// eIf is an if-expression.
	eIf struct {
		cond, yes, no expr
	}
)

func (eRaw) isExpr()   {}
func (eVar) isExpr()   {}
func (eSel) isExpr()   {}
func (eAttr) isExpr()  {}
func (eCall) isExpr()  {}
func (eSlice) isExpr() {}
func (eQual) isExpr()  {}
func (eUn) isExpr()    {}
func (eBin) isExpr()   {}
func (eAgg) isExpr()   {}
func (eIf) isExpr()    {}
func (eRel) isExpr()   {}
func (eOut) isExpr()   {}
func (eNamed) isExpr() {}

func raw(s string) expr { return eRaw{s} }

func call(fn string, args ...expr) expr { return eCall{eRaw{fn}, args} }

// callNamed makes a call whose arguments are all named: namesAndArgs
// alternates parameter names (strings) and argument values (exprs).
func callNamed(fn string, namesAndArgs ...interface{}) expr {
	args := []expr(nil)
	for i := 0; i+1 < len(namesAndArgs); i += 2 {
		args = append(args, eNamed{namesAndArgs[i].(string), namesAndArgs[i+1].(expr)})
	}
	return eCall{eRaw{fn}, args}
}

// stmt is an Ada statement (or pragma, or comment, in a statement list).
type stmt interface{ isStmt() }

type (
	sAssign struct{ lhs, rhs expr }

	// sCall is a procedure call statement.
	sCall struct{ call expr }

	sIf struct {
		branches []ifBranch // if, elsif, elsif...
		els      []stmt
	}

	// sLoop is "[name :] [while cond] loop body end loop [name];".
	sLoop struct {
		name string
		cond expr
		body []stmt
	}

	// sExit is "exit [name];".
	sExit struct{ name string }

	// sExitWhen is "exit when cond;", for the innermost loop.
	sExitWhen struct{ cond expr }

	// sLabel is "<<name>> null;".
	sLabel struct{ name string }

	sGoto struct{ label string }

	// sReturn is "return [value];".
	sReturn struct{ value expr }

	// sPragma is "pragma name (args);".
	//
	// If proved is set, the pragma states a condition that the Wuffs
	// compiler proved. GNAT can often see that such a condition is constant
	// (it is implied by the subtypes that the same proof produced), so the
	// printer turns off that one class of warning (-gnatwc) around it, and
	// only around it.
	sPragma struct {
		name   string
		args   []expr
		proved bool
	}

	sComment struct{ text string }

	// sResume is a coroutine's suspension point number n: "G_Susp := n;"
	// followed by the label that the coroutine's dispatch jumps to when it
	// is resumed at n. See coroutine.go.
	//
	// If labelOnly, it is just the label: the statements before it have
	// already set G_Susp and jumped away.
	sResume struct {
		n         int
		susp      *variable
		labelOnly bool
	}

	// sCase is "case sel is when value => body ... when others => others
	// end case;".
	sCase struct {
		sel    expr
		arms   []caseArm
		others []stmt
	}
)

type caseArm struct {
	value string
	body  []stmt
}

type ifBranch struct {
	cond expr
	body []stmt
}

func (sAssign) isStmt()   {}
func (sCall) isStmt()     {}
func (sIf) isStmt()       {}
func (sLoop) isStmt()     {}
func (sExit) isStmt()     {}
func (sExitWhen) isStmt() {}
func (sLabel) isStmt()    {}
func (sGoto) isStmt()     {}
func (sReturn) isStmt()   {}
func (sPragma) isStmt()   {}
func (sComment) isStmt()  {}
func (sResume) isStmt()   {}
func (sCase) isStmt()     {}

type varKind uint8

const (
	varSelf  = varKind(iota) // The receiver.
	varParam                 // A formal parameter.
	varLocal                 // A Wuffs local variable or a generator temporary.
)

// variable is a parameter or local variable of a function.
type variable struct {
	kind varKind
	name string   // Ada name.
	typ  *adaType // Ada type.

	// mode is a parameter's mode: "" (in) or "in out".
	mode string

	// quiet means that the variable only exists to receive a value that
	// nothing reads (a discarded result), so GNAT's warnings about it are
	// turned off.
	quiet bool

	// decl is the subtype indication to declare the variable with (which may
	// be narrower than typ.name) and init is its initial value, if any.
	decl string
	init expr

	// reads and writes are computed by the countUses pass.
	reads, writes int
}

// fn is a function in IR form.
type fn struct {
	name       string // Ada name.
	wuffsName  string // E.g. "hasher.update".
	public     bool
	overriding bool
	recvType   string    // Ada name of the receiver's type.
	self       *variable // The receiver.
	selfInOut  bool
	params     []*variable
	ret        *adaType // nil for a procedure.
	locals     []*variable
	body       []stmt
}

// operandInfo is what is known about a comparison's operand: that it is the
// literal lit, or that it has an Ada subtype whose bounds are lo and hi.
// The zero value means that nothing is known.
type operandInfo struct {
	lit    *big.Int
	lo, hi *big.Int
}

var relationalInverse = map[string]string{
	"=": "/=", "/=": "=", "<": ">=", ">=": "<", ">": "<=", "<=": ">",
}

func isRelational(op string) bool {
	_, ok := relationalInverse[op]
	return ok
}

// rel makes a comparison about whose operands nothing is known.
func rel(op string, l expr, r expr) expr { return eRel{op: op, l: l, r: r} }

// negated returns the comparison that is true exactly when e is false.
func (e eRel) negated() eRel {
	e.op = relationalInverse[e.op]
	return e
}

// adaOp returns the operator to print for e. It is e.op, except that a
// comparison of a value with a literal that is a bound of the value's
// subtype is normalised:
//
//	x <= lowest   becomes   x = lowest
//	x >= highest  becomes   x = highest
//
// (and likewise with the literal on the left). They are equivalent, since
// x cannot be below lowest or above highest, and GNAT warns that the former
// "can never be less than" (an error in this project's builds). Wuffs code
// often says "x <= 0" for an unsigned x or "x >= 9" for an x whose
// refinement stops at 9, and negating "x < 10" for an x in 0 .. 10 (which
// flattening a loop does) gives such a comparison too. Because this is the
// only place that chooses the printed operator, every comparison gets the
// same treatment however it came about.
func (e eRel) adaOp() string {
	atBound := func(op string, v operandInfo, lit operandInfo) bool {
		if lit.lit == nil || v.lo == nil || v.hi == nil {
			return false
		}
		return (op == "<=" && lit.lit.Cmp(v.lo) == 0) || (op == ">=" && lit.lit.Cmp(v.hi) == 0)
	}
	if atBound(e.op, e.li, e.ri) {
		return "="
	}
	// Literal on the left: "lit >= x" is "x <= lit".
	mirrored := map[string]string{"<=": ">=", ">=": "<="}[e.op]
	if mirrored != "" && atBound(mirrored, e.ri, e.li) {
		return "="
	}
	return e.op
}
