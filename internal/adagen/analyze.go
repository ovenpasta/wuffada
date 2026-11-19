// Part of wuffada (wuffs-ada: Wuffs to Ada).
// SPDX-License-Identifier: Apache-2.0 OR MIT

package adagen

import (
	"fmt"
	"strings"

	"github.com/google/wuffs/lang/builtin"

	a "github.com/google/wuffs/lang/ast"
	t "github.com/google/wuffs/lang/token"
)

type fieldInfo struct {
	id   t.ID
	name string // Ada name.
	typ  *adaType
}

type structInfo struct {
	// pkg is the used package that the struct belongs to, or nil for a
	// struct of the package being generated.
	pkg    *usedPkg
	classy bool

	ast *a.Struct

	// extra are the record components that the generator adds, for
	// coroutine state. hasActiveCoroutine means that one of them is
	// activeCoroutineField.
	extra              []fieldInfo
	hasActiveCoroutine bool

	name   string // Ada name.
	typ    *adaType
	fields []fieldInfo

	// interfaces are the Ada names of the interfaces that the struct
	// implements and interfaceMethods are those interfaces' (Wuffs) method
	// names.
	interfaces       []string
	interfaceMethods map[string]bool
}

func (s *structInfo) field(id t.ID) *fieldInfo {
	for i := range s.fields {
		if s.fields[i].id == id {
			return &s.fields[i]
		}
	}
	return nil
}

type constInfo struct {
	// used means that generated code refers to the constant by name.
	used bool
	ast  *a.Const
	name string // Ada name.
	typ  *adaType
}

type statusInfo struct {
	ast      *a.Status
	name     string // Ada name.
	category string // "Note", "Suspension" or "Error".
	code     uint32
	msg      string
}

// argInfo is how one Wuffs argument appears among a function's Ada
// parameters.
type argInfo struct {
	id  t.ID
	typ *adaType

	// v is the parameter: for a slice, the Ada array; for an io_reader or
	// io_writer, the Ada array of the buffer's data, and then meta is the
	// second parameter, the buffer's Wuffs.Base.IO.Buffer_Meta.
	v    *variable
	meta *variable
}

type funcInfo struct {
	ast  *a.Func
	recv *structInfo
	ir   *fn
	args []*argInfo

	// skipped means that no Ada is generated for the function.
	skipped bool

	// sigErr is why a function of a used package has no Ada signature. It is
	// reported only if the function is called.
	sigErr error

	// number is the function's 1-based position among the functions that
	// are generated for this package. It makes the names of the function's
	// coroutine state unambiguous: see lowerer.stateName.
	number int

	// coroutine means that the function is a Wuffs coroutine ("?"). coroID
	// is the 1-based number of a public coroutine among its receiver's.
	coroutine bool
	coroID    int

	// argChecks are the public function's parameters that have a refinement
	// type, which is checked at run time (as the caller is not Wuffs code).
	argChecks []*variable
	argBounds []*adaType
}

// supportedInterfaces maps a Wuffs base interface to its Ada equivalent.
var supportedInterfaces = map[string]string{
	"hasher_u32":     "Wuffs.Runtime.Hasher_U32",
	"io_transformer": "Wuffs.Runtime.IO_Transformer",
}

func (g *gen) analyze() error {
	// Check the kinds of top-level declarations.
	for _, file := range g.files {
		for _, n := range file.TopLevelDecls() {
			switch n.Kind() {
			case a.KConst, a.KFunc, a.KStatus, a.KStruct, a.KUse:
				// No-op.
			default:
				return fmt.Errorf("unrecognized top-level declaration kind %s", n.Kind())
			}
		}
	}

	if err := g.analyzeUses(); err != nil {
		return err
	}
	if err := g.analyzeStatuses(); err != nil {
		return err
	}
	if err := g.analyzeStructs(); err != nil {
		return err
	}
	if err := g.analyzeConsts(); err != nil {
		return err
	}
	return g.analyzeFuncs()
}

func (g *gen) analyzeStatuses() error {
	for _, file := range g.files {
		for _, n := range file.TopLevelDecls() {
			if n.Kind() != a.KStatus {
				continue
			}
			n := n.AsStatus()
			msg, ok := t.Unescape(n.QID()[1].Str(g.tm))
			if !ok || msg == "" {
				return fmt.Errorf("bad status %s", n.QID().Str(g.tm))
			}
			name, err := mangleMessage(msg)
			if err != nil {
				return err
			}
			if err := g.declareName(name, "status "+n.QID()[1].Str(g.tm)); err != nil {
				return err
			}
			if g.opts.PackageID == 0 || g.opts.PackageID > 0xFFFF {
				return fmt.Errorf("package declares statuses, which needs a package id in the range 1 ..= 65535")
			}
			if len(g.statusList) >= 0xFFFF {
				return fmt.Errorf("too many statuses")
			}
			category := "Note"
			switch msg[0] {
			case '#':
				category = "Error"
			case '$':
				category = "Suspension"
			}
			z := &statusInfo{
				ast:      n,
				name:     name,
				category: category,
				code:     g.opts.PackageID<<16 | uint32(len(g.statusList)+1),
				msg:      msg,
			}
			g.statuses[n.QID()[1]] = z
			g.statusList = append(g.statusList, z)
		}
	}
	return nil
}

func (g *gen) analyzeStructs() error {
	unsorted := []*a.Struct(nil)
	for _, file := range g.files {
		for _, n := range file.TopLevelDecls() {
			if n.Kind() == a.KStruct {
				unsorted = append(unsorted, n.AsStruct())
			}
		}
	}
	sorted, ok := a.TopologicalSortStructs(unsorted)
	if !ok {
		return fmt.Errorf("cyclical struct definitions")
	}

	for _, n := range sorted {
		what := "struct " + n.QID().Str(g.tm)
		if !n.Classy() {
			return errNotYet("%s: non-classy structs (those without a \"?\")", what)
		}
		if !n.Public() {
			return errNotYet("%s: private structs", what)
		}
		s := &structInfo{
			classy:           true,
			ast:              n,
			name:             mangleGlobal(n.QID()[1].Str(g.tm)),
			interfaceMethods: map[string]bool{},
		}
		if err := g.declareName(s.name, what); err != nil {
			return err
		}
		s.typ = &adaType{kind: kStruct, name: s.name, st: s}

		for _, o := range n.Implements() {
			qid := o.AsTypeExpr().QID()
			iName := qid[1].Str(g.tm)
			adaName := supportedInterfaces[iName]
			if qid[0] != t.IDBase || adaName == "" {
				return errNotYet("%s: implements %s", what, qid.Str(g.tm))
			}
			s.interfaces = append(s.interfaces, adaName)
			for _, f := range builtin.InterfaceFuncs {
				// Each f looks like "hasher_u32.update!(x: roslice u8)".
				if !strings.HasPrefix(f, iName+".") {
					continue
				}
				f = f[len(iName)+1:]
				if i := strings.IndexAny(f, "!?("); i >= 0 {
					f = f[:i]
				}
				s.interfaceMethods[f] = true
			}
		}

		for _, o := range n.Fields() {
			o := o.AsField()
			typ, err := g.typeOf(o.XType(), false)
			if err != nil {
				return fmt.Errorf("%s: field %s: %v", what, o.Name().Str(g.tm), err)
			}
			switch typ.kind {
			case kNum, kBool, kArray:
				// No-op.
			case kStruct:
				if !typ.st.classy {
					return errNotYet("%s: field %s of a non-classy struct type", what, o.Name().Str(g.tm))
				}
			case kUtility:
				// An empty struct: it needs no Ada component.
			default:
				return errNotYet("%s: field %s of type %q", what, o.Name().Str(g.tm), o.XType().Str(g.tm))
			}
			if typ.excludesZero() {
				return fmt.Errorf("%s: field %s: type %q excludes the zero value",
					what, o.Name().Str(g.tm), o.XType().Str(g.tm))
			}
			fieldName := prefixField + mangle(o.Name().Str(g.tm))
			for _, prev := range s.fields {
				if strings.EqualFold(prev.name, fieldName) {
					return fmt.Errorf("%s: fields %s and %s have the same Ada name %q",
						what, prev.id.Str(g.tm), o.Name().Str(g.tm), fieldName)
				}
			}
			s.fields = append(s.fields, fieldInfo{
				id:   o.Name(),
				name: fieldName,
				typ:  typ,
			})
		}

		g.structs[n.QID()[1]] = s
		g.structList = append(g.structList, s)
	}
	return nil
}

func (g *gen) analyzeConsts() error {
	for _, file := range g.files {
		for _, n := range file.TopLevelDecls() {
			if n.Kind() != a.KConst {
				continue
			}
			n := n.AsConst()
			what := "const " + n.QID().Str(g.tm)
			c := &constInfo{ast: n, name: mangleGlobal(n.QID()[1].Str(g.tm))}
			if err := g.declareName(c.name, what); err != nil {
				return err
			}
			typ, err := g.typeOf(n.XType(), n.Public())
			if err != nil {
				return fmt.Errorf("%s: %v", what, err)
			}
			switch typ.kind {
			case kNum, kArray:
				// No-op.
			default:
				return errNotYet("%s: of type %q", what, n.XType().Str(g.tm))
			}
			c.typ = typ
			g.consts[n.QID()[1]] = c
			g.constList = append(g.constList, c)
		}
	}
	return nil
}

func (g *gen) analyzeFuncs() error {
	nPublicCoroutines := map[t.ID]int{}
	for _, file := range g.files {
		for _, n := range file.TopLevelDecls() {
			if n.Kind() != a.KFunc {
				continue
			}
			n := n.AsFunc()
			fi := &funcInfo{ast: n}
			g.funcs[n.QQID()] = fi

			// As in the C back-end, a receiver's public coroutines are
			// numbered in declaration order, whether or not they are
			// generated.
			if n.Public() && n.Effect().Coroutine() {
				nPublicCoroutines[n.Receiver()[1]]++
				fi.coroID = nPublicCoroutines[n.Receiver()[1]]
			}

			// The rule for what is skipped: exactly those functions that
			// carry a "choose cpu_arch >= etc" assertion, which the parser
			// records as ast.FlagsHasChooseCPUArch. See also the lowering of
			// the choose statement.
			if n.HasChooseCPUArch() {
				fi.skipped = true
				g.skipped = append(g.skipped, n.QQID().Str(g.tm))
				continue
			}
			recv := n.Receiver()
			if recv[0] != 0 || g.structs[recv[1]] == nil {
				return fmt.Errorf("func %s (at %s:%d): %v", n.QQID().Str(g.tm), n.Filename(), n.Line(),
					errNotYet("functions whose receiver is not a struct of this package"))
			}
			fi.recv = g.structs[recv[1]]
			if err := g.analyzeFunc(fi, ""); err != nil {
				return fmt.Errorf("func %s (at %s:%d): %v", n.QQID().Str(g.tm), n.Filename(), n.Line(), err)
			}

			// Ada overloads subprograms on the receiver's type, so two
			// structs can have a method of the same name, but a method
			// cannot share a name with anything else.
			what := "func " + fi.ir.name
			if prev, ok := g.names[strings.ToLower(fi.ir.name)]; !ok || prev != what {
				if err := g.declareName(fi.ir.name, what); err != nil {
					return fmt.Errorf("func %s (at %s:%d): %v", n.QQID().Str(g.tm), n.Filename(), n.Line(), err)
				}
			}
			g.funcList = append(g.funcList, fi)
			fi.number = len(g.funcList)
		}
	}
	return nil
}

// analyzeFunc computes the Ada signature of fi, whose receiver is fi.recv.
// For a function of a used package, pkgPrefix is that Ada package's name and
// a dot.
func (g *gen) analyzeFunc(fi *funcInfo, pkgPrefix string) error {
	n := fi.ast
	for _, o := range n.Asserts() {
		// The Wuffs compiler itself rejects these (lang/check: "function
		// assertions are not supported yet"), except for the "choose
		// cpu_arch" ones.
		return errNotYet("function assertion %q", o.AsAssert().Condition().Str(g.tm))
	}

	f := &fn{
		name:      pkgPrefix + mangleGlobal(n.FuncName().Str(g.tm)),
		wuffsName: n.QQID().Str(g.tm),
		public:    n.Public(),
		recvType:  fi.recv.name,
		self:      &variable{kind: varSelf, name: "Self", typ: fi.recv.typ},
		selfInOut: !n.Effect().Pure(),
	}
	fi.ir = f
	fi.coroutine = n.Effect().Coroutine()
	f.overriding = f.public && fi.recv.interfaceMethods[n.FuncName().Str(g.tm)]

	for _, o := range n.In().Fields() {
		o := o.AsField()
		name := prefixArg + mangle(o.Name().Str(g.tm))
		for _, prev := range f.params {
			if strings.EqualFold(prev.name, name) || strings.EqualFold(prev.name, name+"_Meta") ||
				strings.EqualFold(prev.name+"_Meta", name) {
				return fmt.Errorf("two parameters have the same Ada name %q", name)
			}
		}
		arg := &argInfo{id: o.Name()}
		fi.args = append(fi.args, arg)

		if f.public && uintBits(o.XType().QID()) != 0 && o.XType().Decorator() == 0 {
			// The caller is not Wuffs code, so nothing has proved that the
			// argument is within any refinement, and Ada's range checks are
			// off in the release profile. Take the unrefined type and check
			// explicitly, as the C back-end does.
			lo, hi, err := g.refinement(o.XType())
			if err != nil {
				return fmt.Errorf("parameter %s: %v", o.Name().Str(g.tm), err)
			}
			typ := numType(uintBits(o.XType().QID()))
			v := &variable{kind: varParam, name: name, typ: typ, decl: typ.name}
			if lo != nil {
				if n.Effect().Pure() || n.Out() != nil || fi.coroutine {
					return errNotYet("refined parameter %s of a public function that is pure, "+
						"returns a value or is a coroutine", o.Name().Str(g.tm))
				}
				fi.argChecks = append(fi.argChecks, v)
				fi.argBounds = append(fi.argBounds, &adaType{kind: kNum, bits: typ.bits, lo: lo, hi: hi})
			}
			arg.typ, arg.v = typ, v
			f.params = append(f.params, v)
			continue
		}

		typ, err := g.typeOf(o.XType(), f.public)
		if err != nil {
			return fmt.Errorf("parameter %s: %v", o.Name().Str(g.tm), err)
		}
		arg.typ = typ
		switch typ.kind {
		case kNum, kBool, kStatus:
			arg.v = &variable{kind: varParam, name: name, typ: typ, decl: typ.name}
		case kROSliceU8:
			// A slice parameter is a plain Ada array: its bounds travel with
			// it. The body makes a handle from it only if it needs one.
			arg.typ = typBytes
			arg.v = &variable{kind: varParam, name: name, typ: typBytes, decl: typBytes.name}
		case kSliceU8:
			arg.typ = typBytesVar
			arg.v = &variable{kind: varParam, name: name, typ: typBytesVar, decl: typBytesVar.name, mode: "in out"}
		case kIOReader:
			arg.v = &variable{kind: varParam, name: name, typ: typBytes, decl: typBytes.name}
			arg.meta = &variable{kind: varParam, name: name + "_Meta", typ: typMeta, decl: typMeta.name, mode: "in out"}
		case kIOWriter:
			arg.v = &variable{kind: varParam, name: name, typ: typBytesVar, decl: typBytesVar.name, mode: "in out"}
			arg.meta = &variable{kind: varParam, name: name + "_Meta", typ: typMeta, decl: typMeta.name, mode: "in out"}
		default:
			return errNotYet("parameter %s of type %q", o.Name().Str(g.tm), o.XType().Str(g.tm))
		}
		f.params = append(f.params, arg.v)
		if arg.meta != nil {
			f.params = append(f.params, arg.meta)
		}
	}
	if !f.selfInOut {
		for _, o := range f.params {
			if o.mode != "" {
				return errNotYet("a pure function with a writable slice or an I/O parameter")
			}
		}
	}

	if fi.coroutine {
		if n.Out() != nil {
			return errNotYet("a coroutine with an explicit return type")
		}
		f.ret = typStatus
		return nil
	}
	if out := n.Out(); out != nil {
		typ, err := g.typeOf(out, f.public)
		if err != nil {
			return fmt.Errorf("return type: %v", err)
		}
		switch typ.kind {
		case kNum, kBool, kStatus, kOpaque:
			// No-op.
		default:
			return errNotYet("return type %q", out.Str(g.tm))
		}
		if f.public {
			// A public function returns the zero value if Initialize was
			// not called. Like the C back-end (writeOutParamZeroValue: for
			// "cannot write the zero value of type base.bool"), accept only
			// the types that upstream can do that for, so that everything
			// generated here can be cross-checked against upstream's C. As
			// in C, the Ada result type is the unrefined one.
			if typ.kind == kBool {
				return fmt.Errorf("public function returns %q, which upstream's wuffs-c also rejects "+
					"(it cannot write that type's zero value)", out.Str(g.tm))
			}
			typ = typ.unrefined()
		}
		f.ret = typ
	}
	return nil
}
