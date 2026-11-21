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

// ioArg is an io_reader, io_writer or token_writer argument of the function
// being lowered.
type ioArg struct {
	arg    *argInfo // nil for a local variable bound by io_bind.
	writer bool

	// tokens means that it is a token_writer (writer is then true too): data
	// is a Wuffs.U64_Array, meta a Wuffs.Base.Tokens.Token_Buffer_Meta and
	// cursor a Wuffs.Base.Tokens.Token_Writer, and the protocols are those of
	// wuffs-base-tokens.ads (the same as for byte buffers).
	tokens bool

	// data is the buffer's array and meta is its Buffer_Meta.
	data expr
	meta *variable

	// forgotten is the saved state of the io_forget_history block that the
	// statements being lowered are in, if any.
	forgotten *variable

	// cursor is the function's Wuffs.Base.IO.Reader or Writer for the
	// buffer (C: the iop, io0, io1 and io2 "derived variables"), or nil if
	// the function only passes the buffer on.
	cursor *variable
}

// lowerer lowers one function.
type lowerer struct {
	g  *gen
	fi *funcInfo
	f  *fn

	locals map[t.ID]*variable
	args   map[t.ID]*variable // What a non-I/O "args.foo" denotes: a parameter or its mutable copy.
	ios    map[t.ID]*ioArg
	ioList []*ioArg
	nBinds int

	// ptrs are the pointer-typed arguments: nullable pointers and pixel
	// buffers. tableOf says which array each table-typed local variable's
	// offsets count in (the one array that it is ever assigned a table of).
	ptrs    map[t.ID]*argInfo
	tableOf map[*variable]*variable

	// rowOf says which receiver field (an array of arrays) each row-pointer
	// local variable (kRowPtr) points into: see rowPtr.
	rowOf map[*variable]*fieldInfo

	// ioLocals are the local variables of an I/O type and bound are those
	// that an enclosing io_bind block gives a buffer.
	ioLocals map[t.ID]bool
	bound    map[t.ID]*ioArg
	loops    map[a.Loop]*loopInfo

	// pre holds statements that must run before the statement that is
	// currently being lowered: they assign temporaries that its expressions
	// use. post holds statements that must run right after it.
	pre  []stmt
	post []stmt

	nLoops, nIterates, nTemps int

	// temps are the generator temporaries (made by newTemp).
	temps map[*variable]bool

	// inAssertion means that the expression being lowered is the condition
	// of an assertion (assert, or a loop's pre, inv or post).
	inAssertion bool

	// For a coroutine: see coroutine.go.
	status     *variable // G_Status.
	susp       *variable // G_Susp, the current suspension point.
	nSusp      int
	resumables map[t.ID]bool
	scratch    expr // Self.G_Scratch_Func, once something needs it.
	pfield     expr // Self.G_P_Func, once something needs it.
}

func (g *gen) lowerFunc(fi *funcInfo) error {
	l := &lowerer{
		g:      g,
		fi:     fi,
		f:      fi.ir,
		locals: map[t.ID]*variable{},
		args:   map[t.ID]*variable{},
		ios:    map[t.ID]*ioArg{},
		loops:  map[a.Loop]*loopInfo{},

		ptrs:     map[t.ID]*argInfo{},
		tableOf:  map[*variable]*variable{},
		rowOf:    map[*variable]*fieldInfo{},
		ioLocals: map[t.ID]bool{},
		bound:    map[t.ID]*ioArg{},
	}
	n := fi.ast

	if fi.coroutine {
		l.status = l.newLocal(prefixGen+"Status", typStatus, raw("Wuffs.Ok_Status"))
		var err error
		if l.resumables, err = findResumables(g.tm, n); err != nil {
			return err
		}
	}
	if err := l.declareArgs(); err != nil {
		return err
	}
	if err := l.declareLocals(); err != nil {
		return err
	}

	head := []stmt(nil)
	if l.f.public {
		ss, err := l.prologue()
		if err != nil {
			return err
		}
		head = append(head, ss...)
	}
	for _, io := range l.ioList {
		if io.cursor == nil {
			continue
		}
		data, meta := io.data, eVar{io.meta}
		if io.writer {
			head = append(head, sAssign{eVar{io.cursor},
				callNamed(io.pkg()+".To_Writer", "M", meta, "Data_Length", eAttr{data, "Length"})})
		} else {
			head = append(head, sAssign{eVar{io.cursor}, call(ioPkg+".To_Reader", meta)})
		}
	}

	body, err := l.block(n.Body())
	if err != nil {
		return err
	}

	if fi.coroutine {
		l.f.body = l.assembleCoroutine(head, body)
		return nil
	}
	l.f.body = append(head, body...)
	if a.Terminates(n.Body()) {
		// The body ends with a return, or with an if-else chain or a "while
		// true" loop (without a break) that cannot fall through.
		return nil
	}
	l.f.body = append(l.f.body, l.saveCursors()...)
	switch {
	case l.f.ret == nil:
		// No-op.
	case l.f.ret.kind == kStatus:
		// Falling off the end of a function that returns a status returns
		// ok: in C, the function's status variable is still NULL. (Upstream
		// does not check that a body ends with a return.)
		l.f.body = append(l.f.body, sReturn{raw("Wuffs.Ok_Status")})
	default:
		return fmt.Errorf("body of a function with a return type can fall off its end")
	}
	return nil
}

// saveCursors returns the statements that store every I/O cursor back in
// its buffer's meta: what the C back-end's writeFinalSaveDerivedVar emits.
func (l *lowerer) saveCursors() []stmt {
	ret := []stmt(nil)
	for _, io := range l.ioList {
		if io.cursor != nil {
			io.meta.writes++
			ret = append(ret, sCall{call(io.pkg()+".Save", eVar{io.meta}, eVar{io.cursor})})
		}
	}
	return ret
}

// pkg returns the proved package of the buffer's cursor and meta.
func (io *ioArg) pkg() string {
	if io.tokens {
		return tokensPkg
	}
	return ioPkg
}

func (l *lowerer) newLocal(name string, typ *adaType, init expr) *variable {
	v := &variable{kind: varLocal, name: name, typ: typ, decl: typ.name, init: init}
	l.f.locals = append(l.f.locals, v)
	return v
}

// newTemp makes a generator temporary.
func (l *lowerer) newTemp(typ *adaType) *variable {
	l.nTemps++
	v := l.newLocal(fmt.Sprintf("%sT%d", prefixGen, l.nTemps), typ, nil)
	if l.temps == nil {
		l.temps = map[*variable]bool{}
	}
	l.temps[v] = true
	// Whatever asked for a temporary assigns it, possibly as an "out"
	// parameter, which the IR does not show.
	v.writes++
	return v
}

// declareArgs fills in l.args and l.ios. A parameter that the body assigns
// to gets a local, mutable copy, since Ada "in" parameters are constants.
// For a slice, that copy is a slice handle, and the parameter stays a plain
// array.
func (l *lowerer) declareArgs() error {
	assigned := map[t.ID]bool{}
	if err := l.walkBody(func(o *a.Node) error {
		if o.Kind() == a.KAssign {
			// Only "args.foo = etc" re-assigns the argument. "args.foo[i] =
			// etc" writes through a slice argument, to the caller's memory.
			if lhs := o.AsAssign().LHS(); lhs != nil {
				if foo := lhs.IsArgsDotFoo(); foo != 0 {
					assigned[foo] = true
				}
			}
		}
		return nil
	}); err != nil {
		return err
	}

	for _, arg := range l.fi.args {
		id := arg.id
		switch arg.typ.kind {
		case kIOReader, kIOWriter, kTokenWriter:
			if assigned[id] {
				return errNotYet("assigning to args.%s", id.Str(l.g.tm))
			}
			io := &ioArg{arg: arg, writer: arg.typ.kind != kIOReader, tokens: arg.typ.kind == kTokenWriter,
				data: eVar{arg.v}, meta: arg.meta}
			need, err := l.needCursor(id)
			if err != nil {
				return err
			}
			if need {
				typ, prefix := typReader, "R_"
				switch {
				case io.tokens:
					typ, prefix = typTokenCursor, "TW_"
				case io.writer:
					typ, prefix = typWriter, "W_"
				}
				io.cursor = l.newLocal(prefixGen+prefix+mangle(id.Str(l.g.tm)), typ, nil)
			}
			l.ios[id] = io
			l.ioList = append(l.ioList, io)
			continue
		case kNptr, kPixBuf, kNptrPixBuf:
			if assigned[id] {
				return errNotYet("assigning to args.%s", id.Str(l.g.tm))
			}
			l.ptrs[id] = arg
			continue
		}
		if !assigned[id] {
			l.args[id] = arg.v
			continue
		}
		name := prefixArgCopy + mangle(id.Str(l.g.tm))
		switch arg.typ.kind {
		case kBytes:
			l.args[id] = l.newLocal(name, typROSliceU8, bytesToHandle(eVar{arg.v}))
		case kBytesVar:
			l.args[id] = l.newLocal(name, typSliceU8, bytesToHandle(eVar{arg.v}))
		case kNum, kBool, kStatus:
			l.args[id] = l.newLocal(name, arg.typ, eVar{arg.v})
		default:
			return errNotYet("assigning to args.%s", id.Str(l.g.tm))
		}
		if l.fi.coroutine {
			// The C back-end does not save arguments across a suspension
			// either, but there the caller passes them again. A modified
			// copy would be lost.
			return errNotYet("assigning to args.%s in a coroutine", id.Str(l.g.tm))
		}
	}
	return nil
}

// needCursor reports whether the function needs its own cursor for the I/O
// argument called name, as opposed to only passing the buffer on. It is the
// C back-end's needDerivedVar: true if the body calls a method on args.name
// (other than is_closed) or hands args.name to a built-in method.
func (l *lowerer) needCursor(name t.ID) (bool, error) {
	need := false
	err := l.walkBody(func(o *a.Node) error {
		switch o.Kind() {
		case a.KExpr:
			recv, meth, args, ok := o.AsExpr().IsMethodCall()
			if !ok {
				return nil
			}
			if recv.IsArgsDotFoo() == name {
				if meth != t.IDIsClosed {
					need = true
				}
				return nil
			}
			if rt := recv.MType(); rt.IsIOType() ||
				(rt.Decorator() == 0 && rt.QID() == t.QID{t.IDBase, t.IDPixelSwizzler}) {
				for _, x := range args {
					if x.AsArg().Value().IsArgsDotFoo() == name {
						need = true
					}
				}
			}
		case a.KIOManip:
			if o.AsIOManip().IO().IsArgsDotFoo() == name {
				need = true
			}
		}
		return nil
	})
	return need, err
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
			// In a coroutine a local's value can come back from a previous
			// call, which the bounds of the assignments in this call do not
			// cover in any obvious way: keep the declared type.
			if !l.fi.coroutine {
				if err := l.narrow(v, id); err != nil {
					return err
				}
			}
			l.locals[id] = v
		case kBool, kStatus, kOpaque:
			l.locals[id] = l.newLocal(name, typ, typ.zeroValue())
		case kIOReader, kIOWriter:
			// It means something only inside an io_bind block.
			l.ioLocals[id] = true
		case kX86Util:
			// An empty struct: only its methods are used, and they are
			// lowered without it (x86Method).
		case kVec:
			// Only SIMD implementations have vectors, and they are never
			// coroutines (analyzeFuncs): a vector is never live across a
			// suspension point. (Upstream's C would save it in the struct.)
			if l.fi.simd == "" || l.fi.coroutine {
				return fmt.Errorf("var %s: a vector outside of a SIMD function", id.Str(l.g.tm))
			}
			zero := x86Pkg + ".Zero_M128I"
			if typ.bits == 256 {
				zero = x86Pkg + ".Zero_M256I"
			}
			l.locals[id] = l.newLocal(name, typ, raw(zero))
		case kTable:
			// The default initial value is the empty table. Like a slice, a
			// table is not saved across a suspension.
			l.locals[id] = l.newLocal(name, typ, nil)
		case kROSliceU8, kSliceU8:
			// The default initial value is the empty slice.
			l.locals[id] = l.newLocal(name, typ, nil)
		case kRowPtr:
			if l.fi.coroutine && l.resumables[id] {
				// C does not save a pointer across a suspension: after one,
				// it would be null. Wuffs code that relies on that is not
				// worth supporting.
				return errNotYet("var %s: a pointer that is live across a suspension point", id.Str(l.g.tm))
			}
			v := l.newLocal(name, typ, raw("-1"))
			f, err := l.rowPtrField(id, typ)
			if err != nil {
				return fmt.Errorf("var %s: %v", id.Str(l.g.tm), err)
			}
			l.rowOf[v] = f
			l.locals[id] = v
		case kArray:
			// DESIGN.md: no local array above 1 KiB.
			if typ.elem.kind != kNum {
				return errNotYet("var %s of type %q", id.Str(l.g.tm), o.XType().Str(l.g.tm))
			}
			size := big.NewInt(int64(typ.elem.bits / 8))
			size.Mul(size, typ.length)
			if size.Cmp(big.NewInt(1024)) > 0 {
				return errNotYet("var %s: a local array of more than 1024 bytes (it has to move into the receiver)",
					id.Str(l.g.tm))
			}
			l.locals[id] = l.newLocal(name, typ, raw("[others => 0]"))
		default:
			return errNotYet("var %s of type %q", id.Str(l.g.tm), o.XType().Str(l.g.tm))
		}
	}
	return nil
}

// rowPtrField finds the receiver field that the pointer-to-array local
// variable id (of type typ) points into, from the assignments to it, which
// must all be "id = nullptr" or "id = this.f[i][..] as ptr array[N] T" for
// one field f, an array of rows of type array[N] T.
//
// Such a pointer is then the row's index: id[j] is this.f[i][j], and
// "id == nullptr" is "index = -1". That is what C does (a pointer to the row,
// which follows the row's contents, not a copy) with every access checked.
// As C does not save a pointer across a suspension, neither does this
// (assembleCoroutine).
func (l *lowerer) rowPtrField(id t.ID, typ *adaType) (*fieldInfo, error) {
	found := (*fieldInfo)(nil)
	err := l.walkBody(func(o *a.Node) error {
		if o.Kind() != a.KAssign {
			return nil
		}
		n := o.AsAssign()
		if lhs := n.LHS(); lhs == nil || lhs.Operator() != 0 || lhs.Ident() != id {
			return nil
		}
		rhs := n.RHS()
		if n.Operator() != t.IDEq {
			return errNotYet("assigning to a pointer with %q", n.Operator().Str(l.g.tm))
		}
		if rhs.Operator() == 0 && rhs.Ident() == t.IDNullptr {
			return nil
		}
		f, _, err := l.rowPtrSource(rhs)
		if err != nil {
			return err
		}
		if found != nil && found != f {
			return errNotYet("a pointer variable that points into two different fields")
		}
		if f.typ.kind != kArray || f.typ.elem.kind != kArray || f.typ.elem.length.Cmp(typ.length) != 0 ||
			f.typ.elem.elem.kind != kNum || f.typ.elem.elem.bits != typ.elem.bits {
			return fmt.Errorf("%q: the field's rows are not of the pointer's type", rhs.Str(l.g.tm))
		}
		found = f
		return nil
	})
	if err != nil {
		return nil, err
	}
	if found == nil {
		return nil, errNotYet("a pointer variable that is only ever null")
	}
	return found, nil
}

// rowPtrSource matches "this.f[i][..] as ptr array[N] T" and returns the
// field f and the expression i.
func (l *lowerer) rowPtrSource(rhs *a.Expr) (*fieldInfo, *a.Expr, error) {
	bad := errNotYet("a pointer to %q (only \"this.field[i][..] as ptr array[N] T\" is supported)", rhs.Str(l.g.tm))
	if rhs.Operator() != t.IDXBinaryAs {
		return nil, nil, bad
	}
	arr, lo, hi, ok := rhs.LHS().AsExpr().IsSlice()
	if !ok || lo != nil || hi != nil || arr.Operator() != t.IDOpenBracket {
		return nil, nil, bad
	}
	field := arr.LHS().AsExpr()
	if field.Operator() != t.IDDot || field.LHS().AsExpr().Operator() != 0 ||
		field.LHS().AsExpr().Ident() != t.IDThis {
		return nil, nil, bad
	}
	f := l.fi.recv.field(field.Ident())
	if f == nil {
		return nil, nil, bad
	}
	return f, arr.RHS().AsExpr(), nil
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
	// What is known about the variable's values (for comparisons: see
	// eRel.adaOp) is now this range.
	v.typ = &adaType{kind: kNum, name: v.typ.unrefined().name, bits: v.typ.bits, lo: lo, hi: hi}
	return nil
}

// prologue emits what the C back-end's writeFuncImplPrologue does for a
// public function: check that Initialize was called (and that no previous
// call disabled the object) and check the arguments that Wuffs code would
// have had to prove in range.
func (l *lowerer) prologue() ([]stmt, error) {
	out := []stmt(nil)
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
				yes:  raw(basePkg + ".Error_Disabled_By_Previous_Error"),
				no:   raw(basePkg + ".Error_Initialize_Not_Called"),
			}
		default:
			ret.value = l.f.ret.zeroValue()
		}
	}
	out = append(out, sIf{branches: []ifBranch{{cond, []stmt{ret}}}})

	// The argument checks. C checks that an io_buffer pointer is not NULL.
	// An Ada array cannot be null, but its Buffer_Meta comes from outside
	// of Wuffs code and everything after this trusts it, so check here that
	// it describes the array (which C leaves to the caller).
	conds := []expr(nil)
	// First, before anything looks at an argument's value: every Boolean
	// that the caller supplies holds False or True, and no array argument,
	// written or only read, lies in the storage of the receiver itself
	// (what the function writes to its state would change the array, or
	// the reverse). See "Arguments" in wuffs-runtime.ads.
	for _, arg := range l.fi.args {
		for _, v := range arg.vars() {
			switch {
			case v.typ.kind == kBool:
				conds = append(conds, eUn{"not", eAttr{eVar{v}, "Valid"}})
			case v.typ.kind == kStatus:
				conds = append(conds, eUn{"not", eAttr{eSel{eVar{v}, "Category"}, "Valid"}})
			}
		}
	}
	sharesSelf := func(v *variable) expr {
		return callNamed("Wuffs.Runtime.Shares_Storage",
			"A", expr(eVar{v}),
			"Address", expr(eAttr{eVar{l.f.self}, "Address"}),
			"Size_In_Bits", expr(eAttr{eVar{l.f.self}, "Size"}))
	}
	for _, arg := range l.fi.args {
		if arg.typ.kind == kNptrPixBuf {
			// Its arrays are checked below, if it is not null.
			continue
		}
		for _, v := range arg.vars() {
			if v.typ.kind == kBytes || v.typ.kind == kBytesVar || v.typ.kind == kTokenArray {
				conds = append(conds, sharesSelf(v))
			}
		}
	}
	for _, io := range l.ioList {
		fn := "Wuffs.Runtime.Valid_Buffer"
		if io.tokens {
			fn = "Wuffs.Runtime.Valid_Token_Buffer"
		}
		conds = append(conds, eUn{"not", call(fn, io.data, eVar{io.meta})})
	}
	// A token array must share no storage with any byte array argument (a
	// source buffer, a work buffer, a slice): an array of tokens and an
	// array of bytes are never parts of one Ada array, so nothing could
	// make sense of an overlap (see "Token buffers" in wuffs-runtime.ads).
	for _, arg := range l.fi.args {
		if arg.typ.kind != kTokenWriter {
			continue
		}
		for _, other := range l.fi.args {
			switch other.typ.kind {
			case kBytes, kBytesVar, kIOReader, kIOWriter:
				conds = append(conds, callNamed("Wuffs.Runtime.Tokens_Share_Storage",
					"Tokens", expr(eVar{arg.v}), "B", expr(eVar{other.v})))
			case kTokenWriter:
				if other != arg {
					return nil, errNotYet("a function with two token_writer arguments")
				}
			case kPixBuf, kNptrPixBuf:
				return nil, errNotYet("a function with a token_writer and a pixel buffer argument")
			}
		}
	}
	// A pixel buffer must be valid for its two arrays, and those two arrays
	// (which pixel operations write) must be apart from each other and from
	// every other array argument: see "Aliasing" in wuffs-runtime.ads.
	arrays := []*variable(nil)
	for _, arg := range l.fi.args {
		switch arg.typ.kind {
		case kBytes, kBytesVar, kIOReader, kIOWriter:
			arrays = append(arrays, arg.v)
		}
	}
	// A nullable pixel buffer (kNptrPixBuf) is checked like that only if
	// it is not null: if it is, nothing reads its descriptor or arrays (as
	// C does not dereference a NULL pointer), so there is nothing to check
	// about them, and its null flag was checked above. Two pixel buffers'
	// arrays must be apart from each other's too (when neither is null).
	notNull := func(arg *argInfo, e expr) expr {
		if arg.null == nil {
			return e
		}
		return bin("and then", eUn{"not", eVar{arg.null}}, e)
	}
	for i, arg := range l.fi.args {
		if arg.typ.kind != kPixBuf && arg.typ.kind != kNptrPixBuf {
			continue
		}
		pixels, palette := eVar{arg.pixels}, eVar{arg.palette}
		own := []expr{
			eUn{"not", callNamed("Wuffs.Runtime.Valid_Pixel_Buffer",
				"PB", expr(eVar{arg.v}), "Pixels", expr(pixels), "Palette", expr(palette))},
			callNamed("Wuffs.Runtime.Share_An_Element", "A", expr(pixels), "B", expr(palette)),
		}
		if arg.typ.kind == kNptrPixBuf {
			own = append(own, sharesSelf(arg.pixels), sharesSelf(arg.palette))
		}
		for _, written := range []eVar{pixels, palette} {
			for _, other := range arrays {
				own = append(own,
					callNamed("Wuffs.Runtime.Share_An_Element", "A", expr(written), "B", expr(eVar{other})))
			}
		}
		if arg.typ.kind == kPixBuf {
			conds = append(conds, own...)
		} else {
			conds = append(conds, notNull(arg, bin("or else", own...)))
		}
		for _, prev := range l.fi.args[:i] {
			if prev.typ.kind != kPixBuf && prev.typ.kind != kNptrPixBuf {
				continue
			}
			for _, x := range []*variable{arg.pixels, arg.palette} {
				for _, y := range []*variable{prev.pixels, prev.palette} {
					conds = append(conds, notNull(arg, notNull(prev,
						callNamed("Wuffs.Runtime.Share_An_Element", "A", expr(eVar{x}), "B", expr(eVar{y})))))
				}
			}
		}
	}
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
	if len(conds) > 0 {
		cond = conds[0]
		if len(conds) > 1 {
			cond = bin("or else", conds...)
		}
		// C: the object is disabled and the function returns "#bad
		// argument" or, if it does not return a status, zero. (A function
		// that cannot change the object just returns zero.)
		ret := sReturn{}
		switch {
		case l.f.ret == nil:
			// No-op.
		case l.f.ret.kind == kStatus:
			ret.value = raw(basePkg + ".Error_Bad_Argument")
		default:
			if ret.value = l.f.ret.zeroValue(); ret.value == nil {
				return nil, errNotYet("a public function with arguments to check that returns %s", l.f.ret.name)
			}
		}
		body := []stmt{ret}
		if l.f.selfInOut {
			l.f.self.writes++
			body = []stmt{sAssign{magic, raw(rtMagicDisabled)}, ret}
		}
		out = append(out, sIf{branches: []ifBranch{{cond, body}}})
	}

	// A public coroutine refuses to run while another one of the same
	// object is suspended.
	if l.fi.coroutine {
		l.fi.recv.hasActiveCoroutine = true
		active := eSel{eVar{l.f.self}, activeCoroutineField}
		id := raw(fmt.Sprint(l.fi.coroID))
		l.f.self.writes++
		out = append(out,
			sIf{branches: []ifBranch{{
				bin("and then", bin("/=", active, raw("0")), bin("/=", active, id)),
				[]stmt{
					sAssign{magic, raw(rtMagicDisabled)},
					sReturn{raw(basePkg + ".Error_Interleaved_Coroutine_Calls")},
				}}}},
			sAssign{active, raw("0")})
	}
	return out, nil
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

// flush returns the pending prelude statements, then ss, then the pending
// postlude statements.
func (l *lowerer) flush(ss ...stmt) []stmt {
	ret := append(l.pre, ss...)
	ret = append(ret, l.post...)
	l.pre, l.post = nil, nil
	return ret
}

// noPrelude fails if lowering an expression needed prelude statements in a
// context that cannot have them (they would have to be re-evaluated).
func (l *lowerer) noPrelude(what string) error {
	if len(l.pre) != 0 || len(l.post) != 0 {
		return errNotYet("a temporary in %s", what)
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
	if l.fi.coroutine {
		if err := l.checkTemps(ss); err != nil {
			return nil, err
		}
	}
	return ss, nil
}

// locatedError is an error that already says where in the Wuffs source it
// arose.
type locatedError struct{ s string }

func (e *locatedError) Error() string { return e.s }

func (l *lowerer) statement1(n *a.Node) ([]stmt, error) {
	if len(l.pre) != 0 || len(l.post) != 0 {
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
		return l.ioManip(n.AsIOManip())
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
	l.inAssertion = true
	cond, err := l.condition(n.Condition())
	l.inAssertion = false
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

	// A call of a coroutine of this or of a used package.
	if rhs.Operator() == a.ExprOperatorCall && rhs.Effect().Coroutine() && !isIOMethodCall(rhs) {
		if !l.fi.coroutine {
			return nil, fmt.Errorf("coroutine call %q outside of a coroutine", rhs.Str(l.g.tm))
		}
		v, err := l.expr(rhs)
		if err != nil {
			return nil, err
		}
		if op == t.IDEqQuestion {
			// "x =? f?()" just delivers the callee's status.
			lv, err := l.expr(lhs)
			if err != nil {
				return nil, err
			}
			if lv.typ == nil || lv.typ.kind != kStatus {
				return nil, fmt.Errorf("left-hand side of %q is not a status", "=?")
			}
			return l.flush(sAssign{lv.e, v.e}), nil
		}
		if lhs != nil {
			return nil, errNotYet("assigning the result of a coroutine call, other than with \"=?\"")
		}
		// As the C back-end's writeStatementAssign: the callee's own
		// suspension state makes it continue where it stopped when this
		// function is resumed at the suspension point just before the call.
		//
		// Everything that the call needs (the saving of I/O cursors, and
		// above all the temporaries that hold its slice arguments) comes
		// after the resume label, so that it is evaluated again on resume,
		// as C evaluates the call's arguments again after its case label.
		pre, post := l.pre, l.post
		l.pre, l.post = nil, nil
		ret := append([]stmt{l.suspPoint()}, pre...)
		ret = append(ret, sAssign{eVar{l.status}, v.e})
		ret = append(ret, post...)
		return append(ret, sIf{branches: []ifBranch{{
			eUn{"not", call("Wuffs.Is_Ok", eVar{l.status})}, []stmt{sGoto{labelSuspend}}}}}), nil
	}
	if op == t.IDEqQuestion {
		return nil, errNotYet("the \"=?\" operator on %q", rhs.Str(l.g.tm))
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
			if v.e == nil {
				// Everything was in the prelude.
				return l.flush(), nil
			}
			return l.flush(sCall{v.e}), nil
		}
		if x, ok := v.e.(eVar); ok && x.v.kind == varLocal && strings.HasPrefix(x.v.name, prefixGen+"T") {
			// The result is already in a temporary that nothing else reads.
			x.v.quiet = true
			return l.flush(), nil
		}
		// Ada cannot ignore a function's result.
		l.nTemps++
		discard := l.newLocal(fmt.Sprintf("%sDiscard_%d", prefixGen, l.nTemps), v.typ.unrefined(), nil)
		discard.quiet = true
		return l.flush(sAssign{eVar{discard}, v.e}), nil
	}

	// A pointer to a row: its index. (rowPtrField has checked the form.)
	if lhs.Operator() == 0 && l.locals[lhs.Ident()] != nil && l.locals[lhs.Ident()].typ.kind == kRowPtr {
		v := l.locals[lhs.Ident()]
		if op != t.IDEq {
			return nil, fmt.Errorf("unrecognized assignment operator %q", op.Str(l.g.tm))
		}
		if rhs.Operator() == 0 && rhs.Ident() == t.IDNullptr {
			return l.flush(sAssign{eVar{v}, raw("-1")}), nil
		}
		f, i, err := l.rowPtrSource(rhs)
		if err != nil {
			return nil, err
		}
		if f != l.rowOf[v] {
			return nil, fmt.Errorf("internal error: pointer %q into another field", lhs.Str(l.g.tm))
		}
		iv, err := l.index(i)
		if err != nil {
			return nil, err
		}
		return l.flush(sAssign{eVar{v}, iv}), nil
	}

	// An assignment to a slice element goes through the slice handle.
	if lhs.Operator() == t.IDOpenBracket && lhs.LHS().AsExpr().MType().IsEitherSliceType() {
		return l.assignSliceElement(n)
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
	case kOpaque, kVec:
		if rv.typ != lv.typ {
			return nil, fmt.Errorf("cannot assign %q to %q: different types", rhs.Str(l.g.tm), lhs.Str(l.g.tm))
		}
	case kTable:
		// A table's offsets count in one particular array, which the Ada
		// Table value does not name. So a table variable is tied, when the
		// function is generated, to the one array that every table assigned
		// to it lives in.
		x, ok := lv.e.(eVar)
		if !ok || rv.typ.kind != kTable || rv.tableArr == nil {
			return nil, errNotYet("assigning %q to %q", rhs.Str(l.g.tm), lhs.Str(l.g.tm))
		}
		if prev := l.tableOf[x.v]; prev != nil && prev != rv.tableArr {
			return nil, errNotYet("the table variable %q holding tables of different arrays", lhs.Str(l.g.tm))
		}
		l.tableOf[x.v] = rv.tableArr
	case kROSliceU8, kSliceU8:
		rv, err = l.toHandle(rv, lv.typ.kind == kSliceU8)
		if err != nil {
			return nil, err
		}
	case kRowPtr:
		return nil, fmt.Errorf("internal error: pointer assignment %q", lhs.Str(l.g.tm))
	case kArray:
		// An Ada array assignment copies in place, whatever the overlap.
		if rv.typ.kind != kArray || rv.typ.name != lv.typ.name {
			return nil, fmt.Errorf("cannot assign %q to %q: different types", rhs.Str(l.g.tm), lhs.Str(l.g.tm))
		}
	default:
		return nil, errNotYet("assigning to %q, of type %q", lhs.Str(l.g.tm), lhs.MType().Str(l.g.tm))
	}
	return l.flush(sAssign{lv.e, rv.e}), nil
}

// assignSliceElement lowers "s[i] = v" and "s[i] op= v" for a slice s.
func (l *lowerer) assignSliceElement(n *a.Assign) ([]stmt, error) {
	lhs := n.LHS()
	sv, err := l.expr(lhs.LHS().AsExpr())
	if err != nil {
		return nil, err
	}
	i, err := l.index(lhs.RHS().AsExpr())
	if err != nil {
		return nil, err
	}
	if sv.typ != nil && sv.typ.kind == kBytesVar && sv.lo == nil && sv.hi == nil {
		// A whole Ada array (a writable slice parameter): its own bounds
		// are the slice's, so this is an ordinary element assignment.
		if !sv.zeroBased {
			i = bin("+", eAttr{sv.arr, "First"}, i)
		}
		elem := val{e: eCall{sv.arr, []expr{i}}, typ: typU8}
		rv, err := l.expr(n.RHS())
		if err != nil {
			return nil, err
		}
		if rv.typ == nil {
			return nil, fmt.Errorf("%q has no value", n.RHS().Str(l.g.tm))
		}
		if n.Operator() != t.IDEq {
			xop, ok := assignOpToBinaryOp[n.Operator()]
			if !ok {
				return nil, fmt.Errorf("unrecognized assignment operator %q", n.Operator().Str(l.g.tm))
			}
			if rv, err = l.numBinaryOp(xop, elem, rv, 8); err != nil {
				return nil, err
			}
		} else if err := checkNum(rv, 8); err != nil {
			return nil, err
		}
		return l.flush(sAssign{elem.e, rv.e}), nil
	}
	if sv.typ == nil || !sv.typ.isSlice() {
		return nil, fmt.Errorf("%q is not a slice", lhs.LHS().AsExpr().Str(l.g.tm))
	}
	if sv, err = l.toHandle(sv, true); err != nil {
		return nil, err
	}
	rv, err := l.expr(n.RHS())
	if err != nil {
		return nil, err
	}
	if rv.typ == nil {
		return nil, fmt.Errorf("%q has no value", n.RHS().Str(l.g.tm))
	}
	if n.Operator() != t.IDEq {
		xop, ok := assignOpToBinaryOp[n.Operator()]
		if !ok {
			return nil, fmt.Errorf("unrecognized assignment operator %q", n.Operator().Str(l.g.tm))
		}
		old := val{e: call("Wuffs.Runtime.Get", sv.e, i), typ: typU8}
		if rv, err = l.numBinaryOp(xop, old, rv, 8); err != nil {
			return nil, err
		}
	} else if err := checkNum(rv, 8); err != nil {
		return nil, err
	}
	return l.flush(sCall{callNamed("Wuffs.Runtime.Set", "S", sv.e, "I", i, "V", rv.e)}), nil
}

// choose lowers a choose statement. A candidate that has a "choose cpu_arch"
// assertion is skipped if it was not generated (an ARM capability, or any
// capability in a build without SIMD), as if the CPU lacked the capability;
// a SIMD implementation is taken if Wuffs.Runtime.CPU says that the CPU has
// its capability. The first other candidate is always taken. That is what
// the C back-end does (writeStatementChoose: a chain of
// wuffs_base__cpu_arch__have_etc() ? &f : ..., ending with the first
// candidate without a requirement, or, if there is none, with the current
// choice). If no candidate can ever be taken, the statement does nothing
// and the choosy function keeps its current choice.
func (l *lowerer) choose(n *a.Choose) ([]stmt, error) {
	recv := l.fi.ast.Receiver()
	target := l.g.funcs[t.QQID{recv[0], recv[1], n.Name()}]
	names := ""
	branches := []ifBranch(nil)
	for i, o := range n.Args() {
		id := o.AsExpr().Ident()
		callee := l.g.funcs[t.QQID{recv[0], recv[1], id}]
		if callee == nil || target == nil {
			return nil, fmt.Errorf("choose: no such function %q", id.Str(l.g.tm))
		}
		if !callee.skipped {
			// C stores a pointer to it; here, its number (see findChoices).
			if target.choiceField == "" {
				if callee != target || len(branches) != 0 {
					return nil, fmt.Errorf("internal error: choose %q was not analyzed", id.Str(l.g.tm))
				}
				return []stmt{sComment{fmt.Sprintf(
					"Wuffs: choose %s = [..., %s]\nNothing to do: it is the only implementation.",
					n.Name().Str(l.g.tm), id.Str(l.g.tm))}}, nil
			}
			number := 0
			for j, c := range target.candidates {
				if c == callee {
					number = j + 1
				}
			}
			if number == 0 && callee != target {
				return nil, fmt.Errorf("internal error: choose %q was not analyzed", id.Str(l.g.tm))
			}
			l.f.self.writes++
			assign := []stmt{sAssign{eSel{eVar{l.f.self}, target.choiceField}, raw(fmt.Sprint(number))}}
			if callee.simd != "" {
				branches = append(branches, ifBranch{call(haveFeature(callee.simd)), assign})
				continue
			}
			if len(branches) == 0 {
				return assign, nil
			}
			return []stmt{sIf{branches: branches, els: assign}}, nil
		}
		if i != 0 {
			names += ", "
		}
		names += id.Str(l.g.tm)
	}
	if len(branches) != 0 {
		return []stmt{sIf{branches: branches}}, nil
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
		l.inAssertion = true
		cond, err := l.condition(o.Condition())
		l.inAssertion = false
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
	for o := n; o != nil; o = o.ElseIterate() {
		if len(o.Asserts()) != 0 {
			return nil, errNotYet("iterate loops with assertions")
		}
	}
	o := assigns[0].AsAssign()
	if o.Operator() != t.IDEq || o.LHS().Operator() != 0 {
		return nil, fmt.Errorf("unexpected form of iterate assignment")
	}
	ps := []*variable(nil)
	for _, x := range assigns {
		x := x.AsAssign()
		if x.Operator() != t.IDEq || x.LHS().Operator() != 0 {
			return nil, fmt.Errorf("unexpected form of iterate assignment")
		}
		p := l.locals[x.LHS().Ident()]
		if p == nil || (p.typ.kind != kROSliceU8 && p.typ.kind != kSliceU8) {
			return nil, errNotYet("iterate variable %q of type %q", x.LHS().Str(l.g.tm), x.LHS().MType().Str(l.g.tm))
		}
		ps = append(ps, p)
	}
	iterVars := map[t.ID]bool{}
	for _, x := range assigns {
		iterVars[x.AsAssign().LHS().Ident()] = true
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
				// (Assigning to an element of it is fine.)
				if lhs := y.AsAssign().LHS(); lhs.Operator() == 0 && iterVars[lhs.Ident()] {
					return errNotYet("assigning to the iterate variable %q inside its iterate loop",
						lhs.Str(l.g.tm))
				}
				return nil
			}); err != nil {
				return nil, err
			}
		}
	}
	l.nIterates++
	prefix := fmt.Sprintf("%sI%d_", prefixGen, l.nIterates)
	srcs := []eVar(nil)
	init := []stmt(nil)
	for i, x := range assigns {
		rv, err := l.expr(x.AsAssign().RHS())
		if err != nil {
			return nil, err
		}
		if rv, err = l.toHandle(rv, ps[i].typ.kind == kSliceU8); err != nil {
			return nil, fmt.Errorf("%q: %v", x.AsAssign().RHS().Str(l.g.tm), err)
		}
		name := prefix + "Src"
		if i > 0 {
			name = fmt.Sprintf("%sSrc_%d", prefix, i)
		}
		src := eVar{l.newLocal(name, ps[i].typ, nil)}
		srcs = append(srcs, src)
		init = append(init, sAssign{src, rv.e})
	}
	pos := eVar{l.newLocal(prefix+"Pos", typIndex, raw("0"))}
	end := eVar{l.newLocal(prefix+"End", typIndex, raw("0"))}
	// With several variables, the loops run over the shortest slice.
	srcLen := expr(eSel{srcs[0], "Length"})
	if len(srcs) > 1 {
		shortest := eVar{l.newLocal(prefix+"Len", typIndex, raw("0"))}
		init = append(init, sAssign{shortest, srcLen})
		for _, src := range srcs[1:] {
			init = append(init, sIf{branches: []ifBranch{{
				rel("<", eSel{src, "Length"}, shortest), []stmt{sAssign{shortest, eSel{src, "Length"}}}}}})
		}
		srcLen = shortest
	}
	init = append(init, sAssign{pos, raw("0")})
	ret := l.flush(init...)

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
				ret = append(ret, sAssign{end, bin("+", pos, callNamed(slicesPkg+".Iterate_Total_Advance",
					"Total_Length", remaining,
					"Iter_Length", lit(length+(advance*(unroll-1))),
					"Iter_Advance", lit(advance*unroll)))})
			}

			loop := sLoop{cond: bin("<", pos, end)}
			for i := 0; i < unroll; i++ {
				for j, p := range ps {
					loop.body = append(loop.body, sAssign{eVar{p}, callNamed("Wuffs.Runtime.Subslice_IJ",
						"S", srcs[j], "I", pos, "J", bin("+", pos, lit(length)))})
				}
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
	for j, p := range ps {
		if l.readOutsideItsIterates(assigns[j].AsAssign().LHS().Ident()) {
			ret = append(ret, sAssign{eVar{p},
				callNamed("Wuffs.Runtime.Subslice_IJ", "S", srcs[j], "I", pos, "J", pos)})
		}
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

// statusLiteralKind classifies a status-typed expression that is a literal:
// 'o' for ok, '#' for an error, '$' for a suspension, '@' for a note. It is 0
// for anything else.
func (l *lowerer) statusLiteralKind(n *a.Expr) byte {
	if n.Operator() == 0 && n.Ident() == t.IDOk {
		return 'o'
	}
	if op := n.Operator(); (op == 0 || op == t.IDDot) && n.Ident().IsDQStrLiteral(l.g.tm) {
		msg, _ := t.Unescape(n.Ident().Str(l.g.tm))
		if msg == "" {
			return 0
		}
		switch msg[0] {
		case '#', '$':
			return msg[0]
		}
		return '@'
	}
	return 0
}

func (l *lowerer) ret(n *a.Ret) ([]stmt, error) {
	if l.fi.coroutine {
		return l.coroutineRet(n)
	}
	if n.Keyword() != t.IDReturn {
		return nil, fmt.Errorf("%s statement outside of a coroutine", n.Keyword().Str(l.g.tm))
	}
	value := n.Value()
	if l.f.ret == nil {
		if value != nil && (value.Operator() != 0 || value.Ident() != t.IDNothing) {
			return nil, fmt.Errorf("return of a value from a function without a return type")
		}
		return append(l.saveCursors(), sReturn{}), nil
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
	case kOpaque:
		if v.typ != l.f.ret {
			return nil, fmt.Errorf("cannot return %q: wrong type", value.Str(l.g.tm))
		}
	case kStatus:
		if v.typ.kind != kStatus {
			return nil, fmt.Errorf("cannot return %q: wrong type", value.Str(l.g.tm))
		}
		// As the C back-end: a function that is not a coroutine cannot
		// return a suspension.
		switch l.statusLiteralKind(value) {
		case 'o', '#', '@':
			// No-op.
		default:
			v.e = call(basePkg+".Ensure_Not_A_Suspension", v.e)
		}
	default:
		return nil, fmt.Errorf("internal error: unexpected return type")
	}
	return l.flush(append(l.saveCursors(), sReturn{v.e})...), nil
}

// ioManip lowers an io_bind or io_limit block, by the protocols of
// wuffs-base-io.ads ("Protocols for generated code").
func (l *lowerer) ioManip(n *a.IOManip) ([]stmt, error) {
	keyword := n.Keyword().Str(l.g.tm)
	switch n.Keyword() {
	case t.IDIOBind:
		// io_bind (io: x, data: d, history_position: h) { body }: for the
		// body, the local variable x is a new buffer whose data is d.
		x := n.IO()
		id := x.Ident()
		if x.Operator() != 0 || !l.ioLocals[id] {
			return nil, errNotYet("io_bind of %q, which is not a local variable", x.Str(l.g.tm))
		}
		if l.bound[id] != nil {
			return nil, errNotYet("io_bind of %q inside an io_bind of it", x.Str(l.g.tm))
		}
		writer := x.MType().QID() == t.QID{t.IDBase, t.IDIOWriter}
		dv, err := l.expr(n.Arg1())
		if err != nil {
			return nil, err
		}
		if !dv.typ.isSlice() {
			return nil, fmt.Errorf("io_bind: %q is not a slice", n.Arg1().Str(l.g.tm))
		}
		hv, err := l.expr(n.HistoryPosition())
		if err != nil {
			return nil, err
		}
		if err := checkNum(hv, 64); err != nil {
			return nil, fmt.Errorf("io_bind: history_position: %v", err)
		}
		// The data, held in a handle for the body.
		h, err := l.toHandle(dv, writer)
		if err != nil {
			return nil, fmt.Errorf("io_bind: %q: %v", n.Arg1().Str(l.g.tm), err)
		}
		// (Not a temporary, which may not live from one statement to the
		// next: the body has no suspension point, which is checked below.)
		l.nBinds++
		handle := eVar{l.newLocal(fmt.Sprintf("%sBound_%d", prefixGen, l.nBinds), h.typ, nil)}
		data, err := l.toBytes(val{e: handle, typ: h.typ}, writer)
		if err != nil {
			return nil, err
		}
		io := &ioArg{writer: writer, data: data.e}
		length := expr(eSel{handle, "Length"})
		setup := []stmt(nil)
		if writer {
			io.meta = l.newLocal(fmt.Sprintf("%sW_Meta_%d", prefixGen, l.nBinds), typMeta, nil)
			io.cursor = l.newLocal(fmt.Sprintf("%sW_Bound_%d", prefixGen, l.nBinds), typWriter, nil)
			setup = append(setup,
				sAssign{eVar{io.meta}, callNamed(ioPkg+".Writer_Meta", "History_Position", hv.e)},
				sAssign{eVar{io.cursor},
					callNamed(ioPkg+".Writer_Set", "Data_Length", length, "History_Position", hv.e)})
		} else {
			io.meta = l.newLocal(fmt.Sprintf("%sR_Meta_%d", prefixGen, l.nBinds), typMeta, nil)
			io.cursor = l.newLocal(fmt.Sprintf("%sR_Bound_%d", prefixGen, l.nBinds), typReader, nil)
			setup = append(setup,
				sAssign{eVar{io.meta}, callNamed(ioPkg+".Reader_Meta",
					"Data_Length", length, "Closed", expr(raw("False")), "History_Position", hv.e)},
				sAssign{eVar{io.cursor},
					callNamed(ioPkg+".Reader_Set", "Data_Length", length, "History_Position", hv.e)})
		}
		out := l.flush(sAssign{handle, h.e})
		out = append(out, setup...)

		l.bound[id] = io
		body, err := l.block(n.Body())
		delete(l.bound, id)
		if err != nil {
			return nil, err
		}
		if anyResume(body) {
			return nil, errNotYet("a suspension inside an %s block", keyword)
		}
		// Nothing is copied back at the end: the bound buffer is a local.
		return append(out, body...), nil

	case t.IDIOLimit:
		// io_limit (io: r, limit: n) { body }, for a reader.
		rv, err := l.expr(n.IO())
		if err != nil {
			return nil, err
		}
		io := rv.io
		if io == nil || io.cursor == nil || io.tokens {
			return nil, errNotYet("io_limit of %q", n.IO().Str(l.g.tm))
		}
		if io.writer {
			return nil, errNotYet("io_limit of a writer")
		}
		// The limit ends where the block ends (End_Limit below). Any other
		// way out of the block would leave the limit in place (as it does
		// in upstream's C), so there must be none.
		if err := l.noExits(n.Body(), keyword); err != nil {
			return nil, err
		}
		lv, err := l.expr(n.Arg1())
		if err != nil {
			return nil, err
		}
		if err := checkNum(lv, 64); err != nil {
			return nil, fmt.Errorf("io_limit: limit: %v", err)
		}
		meta, cursor := expr(eVar{io.meta}), expr(eVar{io.cursor})
		saved := eVar{l.newTemp(typReaderLimit)}
		io.meta.writes++
		out := l.flush(sCall{callNamed(ioPkg+".Begin_Limit",
			"M", expr(eOut{meta}), "R", expr(eOut{cursor}), "Up_To", lv.e, "Saved", expr(eOut{saved}))})
		body, err := l.block(n.Body())
		if err != nil {
			return nil, err
		}
		if anyResume(body) {
			return nil, errNotYet("a suspension inside an %s block", keyword)
		}
		out = append(out, body...)
		return append(out, sCall{callNamed(ioPkg+".End_Limit",
			"M", expr(eOut{meta}), "R", expr(eOut{cursor}), "Saved", expr(saved))}), nil

	case t.IDIOForgetHistory:
		// io_forget_history (io: w) { body }, for a writer: inside the
		// body its history is empty, and a callee gets the buffer from the
		// old write position on (see userCall).
		wv, err := l.expr(n.IO())
		if err != nil {
			return nil, err
		}
		io := wv.io
		if io == nil || io.cursor == nil || !io.writer || io.tokens {
			return nil, errNotYet("io_forget_history of %q", n.IO().Str(l.g.tm))
		}
		if io.forgotten != nil {
			return nil, errNotYet("io_forget_history inside io_forget_history")
		}
		if err := l.noExits(n.Body(), keyword); err != nil {
			return nil, err
		}
		// (Not a temporary: see io_bind. The body has no suspension point.)
		l.nBinds++
		saved := l.newLocal(fmt.Sprintf("%sForgotten_%d", prefixGen, l.nBinds), typForgetState, nil)
		meta, cursor := expr(eVar{io.meta}), expr(eVar{io.cursor})
		io.meta.writes++
		out := l.flush(sCall{callNamed(ioPkg+".Begin_Forget_History",
			"M", expr(eOut{meta}), "W", expr(eOut{cursor}), "Saved", expr(eOut{eVar{saved}}))})
		io.forgotten = saved
		body, err := l.block(n.Body())
		io.forgotten = nil
		if err != nil {
			return nil, err
		}
		if anyResume(body) {
			return nil, errNotYet("a suspension inside an %s block", keyword)
		}
		out = append(out, body...)
		return append(out, sCall{callNamed(ioPkg+".End_Forget_History",
			"M", expr(eOut{meta}), "W", expr(eOut{cursor}), "Saved", expr(eVar{saved}))}), nil
	}
	return nil, errNotYet("%s blocks", keyword)
}

// noExits fails if the block has a way out other than falling off its end:
// a return or a yield, a break or continue of a loop around the block, or a
// call that can suspend or fail (a "?" call whose status is not assigned).
func (l *lowerer) noExits(body []*a.Node, keyword string) error {
	inside := map[a.Loop]bool{}
	for _, o := range body {
		o.Walk(func(o *a.Node) error {
			switch o.Kind() {
			case a.KWhile:
				inside[o.AsWhile()] = true
			case a.KIterate:
				inside[o.AsIterate()] = true
			}
			return nil
		})
	}
	// The call in "status =? f?()" does not leave the block: its status,
	// whatever it is, is assigned.
	assigned := map[*a.Expr]bool{}
	for _, o := range body {
		if err := o.Walk(func(o *a.Node) error {
			switch o.Kind() {
			case a.KAssign:
				if o.AsAssign().Operator() == t.IDEqQuestion {
					assigned[o.AsAssign().RHS()] = true
				}
			case a.KRet:
				return errNotYet("a %s out of an %s block", o.AsRet().Keyword().Str(l.g.tm), keyword)
			case a.KJump:
				if !inside[o.AsJump().JumpTarget()] {
					return errNotYet("a %s out of an %s block", o.AsJump().Keyword().Str(l.g.tm), keyword)
				}
			case a.KExpr:
				if x := o.AsExpr(); x.Operator() == t.IDOpenParen && x.Effect().Coroutine() && !assigned[x] {
					return errNotYet("a suspension inside an %s block", keyword)
				}
			}
			return nil
		}); err != nil {
			return err
		}
	}
	return nil
}
