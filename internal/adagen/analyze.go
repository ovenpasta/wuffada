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
	ast    *a.Struct
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

type funcInfo struct {
	ast  *a.Func
	recv *structInfo
	ir   *fn

	// skipped means that no Ada is generated for the function.
	skipped bool

	// argChecks are the public function's parameters that have a refinement
	// type, which is checked at run time (as the caller is not Wuffs code).
	argChecks []*variable
	argBounds []*adaType
}

// supportedInterfaces maps a Wuffs base interface to its Ada equivalent.
var supportedInterfaces = map[string]string{
	"hasher_u32": "Wuffs.Runtime.Hasher_U32",
}

func (g *gen) analyze() error {
	// Check the kinds of top-level declarations.
	for _, file := range g.files {
		for _, n := range file.TopLevelDecls() {
			switch n.Kind() {
			case a.KConst, a.KFunc, a.KStatus, a.KStruct:
				// No-op.
			case a.KUse:
				return errNotYet("\"use\" declarations (at %s:%d)", n.AsUse().Filename(), n.AsUse().Line())
			default:
				return fmt.Errorf("unrecognized top-level declaration kind %s", n.Kind())
			}
		}
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
			ast:              n,
			name:             mangleGlobal(n.QID()[1].Str(g.tm)),
			interfaceMethods: map[string]bool{},
		}
		if err := g.declareName(s.name, what); err != nil {
			return err
		}
		s.typ = &adaType{kind: kStruct, name: s.name}

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
	for _, file := range g.files {
		for _, n := range file.TopLevelDecls() {
			if n.Kind() != a.KFunc {
				continue
			}
			n := n.AsFunc()
			fi := &funcInfo{ast: n}
			g.funcs[n.QQID()] = fi

			// The rule for what is skipped: exactly those functions that
			// carry a "choose cpu_arch >= etc" assertion, which the parser
			// records as ast.FlagsHasChooseCPUArch. See also the lowering of
			// the choose statement.
			if n.HasChooseCPUArch() {
				fi.skipped = true
				g.skipped = append(g.skipped, n.QQID().Str(g.tm))
				continue
			}
			if err := g.analyzeFunc(fi); err != nil {
				return fmt.Errorf("func %s (at %s:%d): %v", n.QQID().Str(g.tm), n.Filename(), n.Line(), err)
			}
			g.funcList = append(g.funcList, fi)
		}
	}
	return nil
}

// analyzeFunc computes fi's Ada signature.
func (g *gen) analyzeFunc(fi *funcInfo) error {
	n := fi.ast
	if n.Effect().Coroutine() {
		return errNotYet("coroutines (functions marked with \"?\")")
	}
	for _, o := range n.Asserts() {
		// The Wuffs compiler itself rejects these (lang/check: "function
		// assertions are not supported yet"), except for the "choose
		// cpu_arch" ones.
		return errNotYet("function assertion %q", o.AsAssert().Condition().Str(g.tm))
	}
	recv := n.Receiver()
	if recv[0] != 0 || g.structs[recv[1]] == nil {
		return errNotYet("functions whose receiver is not a struct of this package")
	}
	fi.recv = g.structs[recv[1]]

	f := &fn{
		name:      mangleGlobal(n.FuncName().Str(g.tm)),
		wuffsName: n.QQID().Str(g.tm),
		public:    n.Public(),
		recvType:  fi.recv.name,
		self:      &variable{kind: varSelf, name: "Self", typ: fi.recv.typ},
		selfInOut: !n.Effect().Pure(),
	}
	fi.ir = f

	// Ada overloads subprograms on the receiver's type, so two structs can
	// have a method of the same name, but a method cannot share a name with
	// anything else.
	what := "func " + f.name
	if prev, ok := g.names[strings.ToLower(f.name)]; !ok || prev != what {
		if err := g.declareName(f.name, what); err != nil {
			return err
		}
	}
	f.overriding = f.public && fi.recv.interfaceMethods[n.FuncName().Str(g.tm)]

	for _, o := range n.In().Fields() {
		o := o.AsField()
		name := prefixArg + mangle(o.Name().Str(g.tm))
		for _, prev := range f.params {
			if strings.EqualFold(prev.name, name) {
				return fmt.Errorf("two parameters have the same Ada name %q", name)
			}
		}
		if o.XType().IsEitherSliceType() {
			if o.XType().Decorator() != t.IDRoslice || uintBits(o.XType().Inner().QID()) != 8 ||
				o.XType().Inner().IsRefined() {
				return errNotYet("parameter %s of type %q", o.Name().Str(g.tm), o.XType().Str(g.tm))
			}
			f.params = append(f.params, &variable{kind: varParam, name: name, typ: typBytes, decl: typBytes.name})
			continue
		}
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
				if n.Effect().Pure() || n.Out() != nil {
					return errNotYet("refined parameter %s of a public function that is pure or returns a value",
						o.Name().Str(g.tm))
				}
				fi.argChecks = append(fi.argChecks, v)
				fi.argBounds = append(fi.argBounds, &adaType{kind: kNum, bits: typ.bits, lo: lo, hi: hi})
			}
			f.params = append(f.params, v)
			continue
		}
		typ, err := g.typeOf(o.XType(), f.public)
		if err != nil {
			return fmt.Errorf("parameter %s: %v", o.Name().Str(g.tm), err)
		}
		switch typ.kind {
		case kNum, kBool, kStatus:
			// No-op.
		default:
			return errNotYet("parameter %s of type %q", o.Name().Str(g.tm), o.XType().Str(g.tm))
		}
		v := &variable{kind: varParam, name: name, typ: typ, decl: typ.name}
		f.params = append(f.params, v)
	}

	if out := n.Out(); out != nil {
		typ, err := g.typeOf(out, f.public)
		if err != nil {
			return fmt.Errorf("return type: %v", err)
		}
		switch typ.kind {
		case kNum, kBool, kStatus:
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
