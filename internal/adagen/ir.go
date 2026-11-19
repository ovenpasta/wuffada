// Part of wuffada (wuffs-ada: Wuffs to Ada).
// SPDX-License-Identifier: Apache-2.0 OR MIT

package adagen

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
)

type ifBranch struct {
	cond expr
	body []stmt
}

func (sAssign) isStmt()  {}
func (sCall) isStmt()    {}
func (sIf) isStmt()      {}
func (sLoop) isStmt()    {}
func (sExit) isStmt()    {}
func (sLabel) isStmt()   {}
func (sGoto) isStmt()    {}
func (sReturn) isStmt()  {}
func (sPragma) isStmt()  {}
func (sComment) isStmt() {}

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
